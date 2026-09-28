/// Settling a debt in the asset the recipient asked for (SPEC.md §9.2).
///
/// A recipient whose first payout is a `swap` cannot be an output of a
/// payment request: §8.5 leaves them out and reports them. This is the other
/// half — quote it, send the ZEC leg, record what was sent.
///
/// **Half of this is visible and half is not.** What leaves this wallet is
/// ZEC and is recorded; what arrives is another asset on another chain, which
/// the bill cannot see. Nothing here says the recipient was paid — only they
/// can say that (§10.5).
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'splits_scope.dart';

class SwapScreen extends StatefulWidget {
  const SwapScreen({
    super.key,
    required this.billId,
    required this.to,
    required this.amountMinorUnits,
  });

  final String billId;

  /// Who is owed, and asked to be paid in something other than ZEC.
  final String to;

  /// Minor units of the bill's currency (§2.1).
  final int amountMinorUnits;

  @override
  State<SwapScreen> createState() => _SwapScreenState();
}

class _SwapScreenState extends State<SwapScreen> {
  SwapQuote? _quote;
  WalletSendOutcome? _outcome;
  bool _working = false;
  String? _message;

  /// A live price for one ZEC in the bill's currency, read with the quote, or
  /// null when none can be had.
  int? _live;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  /// Quotes, unless a send from this bill is still unresolved: a deposit
  /// that may yet land is not followed by a second one.
  Future<void> _start() async {
    final pending = await SplitsScope.read(context).pendingSend(widget.billId);
    if (!mounted) return;
    if (pending != null) {
      setState(
        () => _message =
            'A send from this bill has not been resolved. Settle it on the '
            'settle screen before sending again.',
      );
      return;
    }
    await _quoteIt();
  }

  Future<void> _quoteIt() async {
    setState(() {
      _working = true;
      _message = null;
    });
    final controller = SplitsScope.read(context);
    final quote = await controller.quoteSwap(
      billId: widget.billId,
      to: widget.to,
      amountMinorUnits: widget.amountMinorUnits,
    );
    final currency = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull
        ?.bill
        .currency;
    int? live;
    try {
      live = currency == null ? null : await controller.quoteZec(currency);
    } on Object {
      live = null;
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _quote = quote;
      _live = live;
      // The controller reports rather than throws: an action that quietly
      // did nothing looks exactly like one that worked, so its own sentence
      // is what a person is shown.
      _message =
          controller.lastError ??
          (quote == null
              ? 'This bill has no price on it, or they did not ask to be '
                    'paid in another asset.'
              : null);
    });
  }

  Future<void> _send() async {
    final quote = _quote;
    if (quote == null) return;
    setState(() {
      _working = true;
      _message = null;
    });
    final controller = SplitsScope.read(context);
    final outcome = await controller.sendSwap(
      billId: widget.billId,
      to: widget.to,
      amountMinorUnits: widget.amountMinorUnits,
      quote: quote,
    );
    if (!mounted) return;
    setState(() {
      _working = false;
      _outcome = outcome;
      _message = controller.lastError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    if (view == null) {
      return const Scaffold(body: Center(child: Text('This bill is gone')));
    }
    final who = view.bill.displayNameOf(widget.to, creatorId: view.creatorId);
    final quote = _quote;
    final expired =
        quote != null &&
        quote.hasExpired(
          protocol.canonicalInstant(DateTime.now().toUtc().toIso8601String()),
        );

    return Scaffold(
      appBar: AppBar(title: Text('Pay $who in another asset')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '$who is owed '
            '${formatAmount(widget.amountMinorUnits, view.bill.currency)}.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          if (_outcome != null)
            _Outcome(outcome: _outcome!, who: who)
          else if (quote != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Line(
                      label: 'You send',
                      value: '${_zec(quote.amountInZatoshi)} ZEC',
                    ),
                    _Line(
                      label: '$who receives',
                      // Whole tokens, by the asset's own decimals. The floor,
                      // where the provider states one: the quoted figure is
                      // before slippage, and only the floor is what the
                      // recipient is guaranteed.
                      value: quote.minAmountOut == null
                          ? '${formatBaseUnits(quote.amountOut, quote.asset.decimals)} '
                                '${quote.asset.symbol} on ${quote.asset.chain}'
                          : 'at least '
                                '${formatBaseUnits(quote.minAmountOut!, quote.asset.decimals)} '
                                '${quote.asset.symbol} on ${quote.asset.chain} '
                                '(quoted '
                                '${formatBaseUnits(quote.amountOut, quote.asset.decimals)})',
                    ),
                    _Line(
                      label: 'Deposit address',
                      // The provider's, for this one swap. Not the
                      // recipient's, and not reusable.
                      value: quote.depositAddress,
                      monospace: true,
                    ),
                    if (quote.depositMemo != null)
                      _Line(
                        label: 'Memo',
                        value: quote.depositMemo!,
                        monospace: true,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // §14.2, on this lane as on a payment request: the ZEC above is
            // the bill's rate applied to the debt, and a rate set low by the
            // person being paid sends more ZEC than the debt is worth.
            _SwapRate(view: view, to: widget.to, live: _live),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  expired
                      ? 'This quote has expired. Ask for a new one before '
                            'sending: the price it named is no longer held.'
                      : 'Sending is not the same as them being paid. The ZEC '
                            'leg is all this bill can see — they confirm when '
                            'the asset arrives.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (expired)
              FilledButton(
                key: const Key('splits_swap_requote'),
                onPressed: _working ? null : _quoteIt,
                child: const Text('Get a new quote'),
              )
            else
              FilledButton(
                key: const Key('splits_swap_send'),
                onPressed: _working ? null : _send,
                child: Text(_working ? 'Sending…' : 'Send the ZEC'),
              ),
          ] else if (_working)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _message!,
                key: const Key('splits_swap_message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  /// Zatoshi as ZEC, by integer arithmetic. One ZEC is 100_000_000 zatoshi.
  static String _zec(int zatoshi) {
    final whole = zatoshi ~/ 100000000;
    final fraction = (zatoshi % 100000000)
        .toString()
        .padLeft(8, '0')
        .replaceAll(RegExp(r'0+$'), '');
    return fraction.isEmpty ? '$whole' : '$whole.$fraction';
  }
}

/// The rate the swap's ZEC was priced at, who set it, and how it compares
/// with a live price.
class _SwapRate extends StatelessWidget {
  const _SwapRate({required this.view, required this.to, required this.live});

  final BillView view;
  final String to;
  final int? live;

  @override
  Widget build(BuildContext context) {
    final rate = view.bill.rate;
    if (rate == null) return const SizedBox.shrink();
    final currency = view.bill.currency;
    final error = TextStyle(color: Theme.of(context).colorScheme.error);
    String who(String id) =>
        view.bill.displayNameOf(id, creatorId: view.creatorId);
    final setter = view.rateSetBy;
    final live = this.live;
    final off = live == null || live <= 0
        ? null
        : ((BigInt.from(rate.minorUnitsPerZec) - BigInt.from(live)) *
                  BigInt.from(100) ~/
                  BigInt.from(live))
              .toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1 ZEC = ${formatAmount(rate.minorUnitsPerZec, currency)}, set by '
          '${setter == null ? 'nobody on the bill' : who(setter)}',
          key: const Key('splits_swap_rate'),
        ),
        if (live == null)
          Text(
            'No current price for $currency is available to check this rate '
            'against. Compare it with a price you trust before sending.',
            key: const Key('splits_swap_rate_unchecked'),
            style: error,
          )
        else if (off != null && off.abs() >= 5)
          Text(
            'This rate is ${off.abs()}% ${off > 0 ? 'above' : 'below'} the '
            'current price of ${formatAmount(live, currency)} a ZEC, so this '
            'sends ${off > 0 ? 'less' : 'more'} ZEC than the debt is worth '
            'today.',
            key: const Key('splits_swap_rate_off'),
            style: error,
          ),
        if (setter == to)
          Text(
            '${who(setter!)} set this rate and is paid by this swap. Check it '
            'against a price you trust.',
            key: const Key('splits_swap_setter_paid'),
            style: error,
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        SelectableText(
          value,
          style: monospace
              ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
              : Theme.of(context).textTheme.bodyLarge,
        ),
      ],
    ),
  );
}

/// What the wallet said about the send.
///
/// §14.3: three outcomes, not two. A created-but-unbroadcast transaction may
/// still land, so it is neither recorded as paid nor free to retry.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.outcome, required this.who});

  final WalletSendOutcome outcome;
  final String who;

  @override
  Widget build(BuildContext context) {
    final (title, detail) = switch (outcome.phase) {
      WalletSendPhase.succeeded => (
        'Sent',
        'The ZEC is on its way to the provider. $who confirms once the '
            'asset reaches them — until then the debt stands.',
      ),
      WalletSendPhase.pendingBroadcast => (
        'Not confirmed',
        'The transaction was built but has not reached the network. It may '
            'still land, so nothing was recorded and nothing should be sent '
            'again until it expires.',
      ),
      WalletSendPhase.failed => (
        'Not sent',
        outcome.error ??
            'The wallet could not send it. Nothing was '
                'recorded and nothing was spent.',
      ),
      WalletSendPhase.aborted => (
        'Cancelled',
        'Nothing was sent and nothing was recorded.',
      ),
    };

    return Card(
      key: const Key('splits_swap_outcome'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(detail),
            if (outcome.txid != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                outcome.txid!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
