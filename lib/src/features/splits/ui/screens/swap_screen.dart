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

import 'dart:async';

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
    this.payout,
  });

  final String billId;

  /// A lower preference of theirs the payer chose (§14.8). Absent, their
  /// first payout is the one quoted.
  final protocol.Payout? payout;

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

  /// Fires at the quote's deadline, so an expired quote is shown as expired
  /// without waiting for a tap.
  Timer? _expiry;

  /// Set when [_expiry] fired for the quote on screen.
  bool _lapsed = false;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// Arms [_expiry] for [quote]'s deadline, by the clock the send checks it
  /// against.
  void _watchExpiry(SwapQuote? quote, DateTime now) {
    _expiry?.cancel();
    _expiry = null;
    _lapsed = false;
    final deadline = quote == null ? null : DateTime.tryParse(quote.deadline);
    if (deadline == null) return;
    final left = deadline.difference(now);
    if (left <= Duration.zero) return;
    _expiry = Timer(left, () {
      if (mounted) setState(() => _lapsed = true);
    });
  }

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
            'An earlier send isn’t resolved. Finish it in Settle up.',
      );
      return;
    }
    await _quoteIt();
  }

  Future<void> _quoteIt() async {
    setState(() {
      _working = true;
      _message = null;
      _outcome = null;
    });
    final controller = SplitsScope.read(context);
    SwapQuote? quote;
    final failed = await controller.failureOf(() async {
      quote = await controller.quoteSwap(
        billId: widget.billId,
        to: widget.to,
        amountMinorUnits: widget.amountMinorUnits,
        payout: widget.payout,
      );
    });
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
    _watchExpiry(quote, controller.now());
    setState(() {
      _working = false;
      _quote = quote;
      _live = live;
      // The controller reports rather than throws: an action that quietly
      // did nothing looks exactly like one that worked, so its own sentence
      // is what a person is shown.
      _message = failed ?? (quote == null ? 'Nothing to swap for them.' : null);
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
    WalletSendOutcome? outcome;
    final failed = await controller.failureOf(() async {
      outcome = await controller.sendSwap(
        billId: widget.billId,
        to: widget.to,
        amountMinorUnits: widget.amountMinorUnits,
        quote: quote,
        payout: widget.payout,
      );
    });
    if (!mounted) return;
    setState(() {
      _working = false;
      _outcome = outcome;
      _message = failed;
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
        (_lapsed ||
            quote.hasExpired(
              protocol.canonicalInstant(
                controller.now().toUtc().toIso8601String(),
              ),
            ));
    // The quote's ZEC is the bill's rate applied to the debt when it was
    // asked. A rate changed since leaves the figure above describing a price
    // the bill no longer holds, so the quote is stale however long it has.
    final rate = view.bill.rate;
    final repriced =
        quote != null &&
        (rate == null ||
            quote.amountInZatoshi !=
                protocol.fiatToZatoshi(
                  widget.amountMinorUnits,
                  rate,
                  amountCurrency: view.bill.currency,
                ));
    final error = Theme.of(context).colorScheme.error;

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
          // §14.2: paid somewhere they ranked lower than first.
          if (widget.payout case final chosen?)
            if (SplitsController.payoutIndexes(view.bill, {
                  widget.to: chosen,
                })[widget.to]
                case final at? when at > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Their ${ordinal(at + 1)} choice, not their first.',
                  key: const Key('splits_swap_lower_choice'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          const SizedBox(height: 16),
          if (_outcome != null) ...[
            _Outcome(outcome: _outcome!, who: who),
            // Nothing left the wallet, so the debt can be quoted and sent
            // again. A pending send may still land and gets no second one.
            if (_outcome!.phase == WalletSendPhase.failed ||
                _outcome!.phase == WalletSendPhase.aborted) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('splits_swap_requote'),
                onPressed: _working ? null : _quoteIt,
                child: const Text('Get a new quote'),
              ),
            ],
          ] else if (quote != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Line(
                      label: 'You send',
                      value: formatZec(quote.amountInZatoshi),
                    ),
                    _Line(
                      label: '$who receives',
                      // Whole tokens, by the asset's own decimals. The floor,
                      // where the provider states one: the quoted figure is
                      // before slippage, and only the floor is what the
                      // recipient is guaranteed.
                      value: quote.minAmountOut == null
                          ? '${tokenAmount(quote.amountOut, quote.asset.decimals)} '
                                '${quote.asset.symbol} on ${quote.asset.chain}'
                          : 'at least '
                                '${tokenAmount(quote.minAmountOut!, quote.asset.decimals)} '
                                '${quote.asset.symbol} on ${quote.asset.chain} '
                                '(quoted '
                                '${tokenAmount(quote.amountOut, quote.asset.decimals)})',
                    ),
                    // What the recipient is guaranteed, against the debt,
                    // where one asset is the bill's currency by another name:
                    // the provider's costs come out of the floor, and the
                    // record still says the whole debt was paid.
                    if (_shortOfDebt(
                          quote,
                          widget.amountMinorUnits,
                          view.bill.currency,
                        )
                        case final short?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '$who is guaranteed '
                          '${formatAmount(widget.amountMinorUnits - short, view.bill.currency)}, '
                          '${formatAmount(short, view.bill.currency)} less than '
                          'the debt: the provider\'s costs come out of what '
                          'they receive.',
                          key: const Key('splits_swap_short'),
                          style: TextStyle(color: error),
                        ),
                      ),
                    if (quote.recipient case final recipient?)
                      _Line(
                        label: '$who receives at',
                        // The payout this swap delivers to, as the bill states
                        // it: what the payer checks with the payee.
                        value: recipient,
                        monospace: true,
                      ),
                    // §10.7: an id no key is bound to is a name anyone on the
                    // bill can write for, payout included.
                    if (!view.identities.bound.containsKey(widget.to))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '$who hasn’t joined on their phone. Check this '
                          'address with them.',
                          key: Key('splits_swap_unbound_${widget.to}'),
                          style: TextStyle(color: error),
                        ),
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
                  repriced
                      ? 'The bill’s price changed since this quote. Get a new one.'
                      : expired
                      ? 'Quote expired. Get a new one.'
                      : 'They confirm once it arrives.',
                  key: const Key('splits_swap_state'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (expired || repriced)
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

  /// How far [quote]'s guaranteed floor falls short of [debt], in minor units
  /// of [currency], when the asset is a dollar token and the bill is in
  /// dollars; null when it does not, or when nothing can be compared.
  ///
  /// A USDC or USDT is read as one US dollar, as the price reader reads it.
  static int? _shortOfDebt(SwapQuote quote, int debt, String currency) {
    final symbol = quote.asset.symbol.toUpperCase();
    if (currency != 'USD' || (symbol != 'USDC' && symbol != 'USDT')) {
      return null;
    }
    final floor = BigInt.tryParse(quote.minAmountOut ?? quote.amountOut);
    final decimals = quote.asset.decimals;
    if (floor == null || decimals < 2) return null;
    // Base units to cents: one token is 10^decimals units and 100 cents.
    final cents = floor ~/ BigInt.from(10).pow(decimals - 2);
    final short = BigInt.from(debt) - cents;
    return short > BigInt.zero ? short.toInt() : null;
  }
}

/// The rate the swap's ZEC was priced at, how it compares with a live price,
/// and whether the payee set it.
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
    final off = live == null
        ? null
        : ratePercentOff(rate.minorUnitsPerZec, live);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '1 ZEC = ${formatAmount(rate.minorUnitsPerZec, currency)}',
          key: const Key('splits_swap_rate'),
        ),
        if (live == null)
          Text(
            'No live price to compare. Check this rate yourself.',
            key: const Key('splits_swap_rate_unchecked'),
            style: error,
          )
        else if (off != null && off.abs() >= rateWarningPercent)
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
            '${who(setter!)} set this rate and gets paid here. Check it.',
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
        'Sent. $who confirms when it arrives.',
      ),
      WalletSendPhase.pendingBroadcast => (
        'Not confirmed',
        'Not on the network yet. Don’t send again until it expires.',
      ),
      WalletSendPhase.failed => (
        'Not sent',
        describeSendFailure(
          outcome.error ?? 'Couldn’t send. Nothing was spent.',
        ),
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
