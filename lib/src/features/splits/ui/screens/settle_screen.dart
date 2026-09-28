/// Paying what this device owes.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'price_bill_screen.dart';
import 'record_payment_screen.dart';
import 'swap_screen.dart';
import 'splits_scope.dart';

/// What this device owes, what the request will carry, and what it will not.
///
/// Everything held back is shown. A request that covers less than the plan
/// must say so: the payer cannot tell from the URI (§8.5).
class SettleScreen extends StatefulWidget {
  const SettleScreen({super.key, required this.billId});

  final String billId;

  @override
  State<SettleScreen> createState() => _SettleScreenState();
}

class _SettleScreenState extends State<SettleScreen> {
  splitz.PayerObligation? _owed;
  splitz.Settled? _settled;
  PayIntent? _pending;
  String? _loadError;
  bool _unpriced = false;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final controller = SplitsScope.read(context);
    // Read on its own: a bill whose debts cannot be priced still shows the
    // send that may be out.
    final pending = await controller.pendingSend(widget.billId);
    if (!mounted) return;
    setState(() => _pending = pending);
    try {
      final owed = await controller.obligation(widget.billId);
      if (!mounted) return;
      setState(() {
        _owed = owed;
        _unpriced = owed == null;
        _loadError = null;
        _loading = false;
      });
    } on Object catch (e) {
      // A bill whose debts cannot be priced — an amount past what a request
      // can carry, say — is a state to show, not a spinner that never stops.
      if (!mounted) return;
      setState(() {
        _owed = null;
        _unpriced = false;
        _loadError = SplitsController.describe(e);
        _loading = false;
      });
    }
  }

  Future<void> _send(BillView view) async {
    final controller = SplitsScope.read(context);
    // Read again before the review: what it shows must be what the bill says
    // now, not what it said when this screen opened.
    final shown = _owed?.uri;
    await _load();
    if (!mounted) return;
    final owed = _owed;
    if (owed == null || owed.uri == null) return;
    if (owed.uri != shown) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('The bill changed. Check the amounts again.'),
        ),
      );
      return;
    }
    // A live price to hold the bill's rate against, where one is available.
    int? live;
    try {
      live = await controller.quoteZec(view.bill.currency);
    } on Object {
      live = null;
    }
    if (!mounted) return;
    final current =
        controller.bills.where((b) => b.id == widget.billId).firstOrNull ??
        view;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ReviewSend(view: current, owed: owed, live: live),
    );
    if (confirmed != true || !mounted) return;
    final settled = await controller.settle(widget.billId, owed);
    if (!mounted) return;
    setState(() => _settled = settled);
    await _load();
  }

  Future<void> _resolve({bool landed = false, String? txid}) async {
    final controller = SplitsScope.read(context);
    await controller.resolveSend(widget.billId, landed: landed, txid: txid);
    if (!mounted) return;
    if (controller.lastError == null) setState(() => _settled = null);
    await _load();
  }

  /// Withdraws this device's unconfirmed records of payments to [to] (§10.8).
  ///
  /// Only those to [to]: a withheld debt can be held by payments to several
  /// people (§6.3), and one of them may have landed while another did not.
  Future<void> _withdrawRecords(BillView view, String to) async {
    final controller = SplitsScope.read(context);
    final records = [
      for (final p in view.bill.payments)
        if (p.from == controller.me &&
            p.to == to &&
            !view.bill.confirmedPayments.contains(p.id))
          view.paymentEntries[p.id],
    ].whereType<String>().toList();
    if (records.isEmpty) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Withdraw the record?'),
        content: const Text(
          'Do this only if the payment never left your wallet, or came back '
          'to it — a swap that failed and was refunded. The debt is asked for '
          'again, and paying it twice cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('splits_settle_withdraw_confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    for (final entryId in records) {
      await controller.withdraw(billId: widget.billId, entryId: entryId);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    if (view == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settle up')),
        body: const Center(
          child: Text('This device no longer holds this bill.'),
        ),
      );
    }
    final currency = view.bill.currency;
    String who(String id) =>
        view.bill.displayNameOf(id, creatorId: view.creatorId);

    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_loadError != null)
            Text(
              'This bill cannot be settled from here: $_loadError',
              key: const Key('splits_settle_load_error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_pending != null)
            _PendingSend(
              intent: _pending!,
              who: who,
              currency: currency,
              busy: controller.busy,
              onResolve: _resolve,
            ),
          if (_unpriced) ...[
            // Not an error. There is no §12 code for unpriced, and a bill can
            // sit unpriced for as long as it likes — but saying so without a
            // way through would leave a person reading an instruction they
            // cannot follow.
            const Text(
              'This bill has no price on it yet, so there is nothing to send.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PriceBillScreen(billId: widget.billId),
                  ),
                );
                if (mounted) await _load();
              },
              child: const Text('Price it'),
            ),
          ],
          if (_settled != null) _SentResult(settled: _settled!),
          // §14.2: every pay-to address the fold recorded as replaced, in
          // front of the payer BEFORE they settle. The activity feed shows it
          // too, but a person settling is not reading the history — and a
          // redirected address is the one change on a bill that moves money
          // to somebody else's wallet.
          //
          // Only the recipients this request actually pays: an address change
          // for somebody not in it — not in the plan, or settled another way —
          // is history, not a decision about where this money goes.
          for (final replaced in view.replacedAddresses)
            if (_owed?.carriedTo.containsKey(replaced.id) ?? false)
              Card(
                key: Key('splits_settle_replaced_${replaced.id}'),
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  dense: true,
                  title: Text(
                    '${who(replaced.id)} changed where they are '
                    'paid',
                  ),
                  subtitle: Text(
                    'This request sends to the new address. Check it with '
                    'them before paying.\n'
                    'was ${_short(replaced.from)} · now '
                    '${_short(replaced.to)}',
                  ),
                  isThreeLine: true,
                ),
              ),
          if (_owed != null) ...[
            if (_owed!.settlements.isEmpty && _owed!.awaiting.isEmpty)
              const Text('You owe nothing on this bill.'),
            for (final s in _owed!.settlements)
              ListTile(
                dense: true,
                title: Text('Pay ${who(s.to)}'),
                subtitle: _explain(
                  s,
                  who,
                  currency,
                  refundAuthors: _refundAuthors(view),
                  me: controller.me,
                ),
                trailing: Text(formatAmount(s.amount, currency)),
              ),
            for (final a in _owed!.awaiting) ...[
              ListTile(
                key: Key('splits_settle_awaiting_${a.to}'),
                dense: true,
                // Named by who the money went to. Under §6.3 that can be
                // somebody other than who the debt is owed to, and the payer
                // looks for a payment to them.
                title: Text(
                  'Waiting on ${a.paidTo.isEmpty ? who(a.to) : a.paidTo.map(who).join(', ')}',
                ),
                // §10.5: a record does not discharge a debt. Asking again
                // would send the same money twice.
                subtitle: Text(
                  a.paidTo.isEmpty || a.paidTo.every((p) => p == a.to)
                      ? 'already sent, not yet confirmed — not asked for again'
                      : 'already sent for what you owe ${who(a.to)}, not yet '
                            'confirmed — not asked for again',
                ),
                trailing: Text(formatAmount(a.paid, currency)),
              ),
              // The record of a payment that never left the wallet holds the
              // debt forever unless it can be taken back (§10.8). One control
              // per person paid, so a payment that landed is never taken back
              // with one that did not.
              for (final to in a.paidTo.isEmpty ? [a.to] : a.paidTo)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: Key('splits_settle_withdraw_$to'),
                    onPressed: controller.busy
                        ? null
                        : () => _withdrawRecords(view, to),
                    child: Text('It did not reach ${who(to)}'),
                  ),
                ),
            ],
            for (final u in _owed!.unpayable)
              ListTile(
                key: Key('splits_settle_unpayable_${u.id}'),
                dense: true,
                title: Text('Cannot pay ${who(u.id)} here'),
                // Reported, never dropped: a dropped output settles less than
                // the plan says it does, and the payer cannot tell.
                //
                // A recipient excluded for a payout this request cannot carry
                // is still owed, and settling them is a different lane rather
                // than an impossibility. One who has published nothing is a
                // dead end until they do, and is offered nothing.
                subtitle: Text(switch (u.reason) {
                  'no_address' => 'they have not shared an address',
                  'bad_address' =>
                    'the address they shared is not one a wallet can pay — '
                        'ask them to share it again',
                  // §8.5: more than one request can carry at this rate. The
                  // debt stands; settling it is outside this request.
                  'unpriceable' =>
                    'more than one payment request can carry at this price — '
                        'settle it another way',
                  _ =>
                    'they are not paid in shielded ZEC — settle it '
                        'separately',
                }),
                // No address, or one no request can carry: a dead end until
                // they publish one, so nothing is offered.
                trailing:
                    u.reason == 'no_address' ||
                        u.reason == 'bad_address' ||
                        u.reason == 'unpriceable'
                    ? Text(formatAmount(u.minorUnits, currency))
                    : TextButton(
                        key: Key('splits_settle_apart_${u.id}'),
                        // A swap payout goes to the swap flow, which quotes
                        // it and sends the ZEC leg. Cash has nothing to send,
                        // so it goes straight to the record.
                        // Read again on return: a swap or a record made there
                        // changes what is owed here, and a stale screen would
                        // offer the same debt a second time.
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  _lane(view, u.id) == splitz.SettleLane.swap
                                  ? SwapScreen(
                                      billId: widget.billId,
                                      to: u.id,
                                      amountMinorUnits: u.minorUnits,
                                    )
                                  : RecordPaymentScreen(
                                      billId: widget.billId,
                                      to: u.id,
                                      suggestedMinorUnits: u.minorUnits,
                                    ),
                            ),
                          );
                          if (mounted) await _load();
                        },
                        child: Text(formatAmount(u.minorUnits, currency)),
                      ),
              ),
            if (_owed!.uri != null) ...[
              const SizedBox(height: 16),
              if (!_owed!.isComplete)
                Text(
                  'This sends ${formatAmount(_owed!.carriedMinorUnits, currency)} '
                  'and leaves ${formatAmount(_owed!.withheldMinorUnits, currency)} '
                  'outstanding.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              _RateLine(view: view, who: who),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('splits_settle_send'),
                // Nothing goes out while an earlier send is unresolved: it
                // may still land, and this one would pay the same debt again.
                onPressed: controller.busy || _pending != null
                    ? null
                    : () => _send(view),
                child: Text(
                  'Send ${formatAmount(_owed!.carriedMinorUnits, currency)} '
                  'in one transaction',
                ),
              ),
            ],
          ],
          if (controller.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                controller.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// What a send produced, in the three states it can be in.
class _SentResult extends StatelessWidget {
  const _SentResult({required this.settled});

  final splitz.Settled settled;

  @override
  Widget build(BuildContext context) {
    final (String title, String body) = switch (settled.result) {
      splitz.SendResult.sent => (
        'Sent',
        'Transaction ${settled.txid}. It is recorded on the bill and waits '
            'to be confirmed — a record is a claim, not a settlement.',
      ),
      // Neither paid nor unpaid. Nothing was recorded and no retry is safe
      // until the wallet says which way it went.
      splitz.SendResult.pending => (
        'Built, not sent yet',
        settled.detail ??
            'The transaction was created but has not reached the network. '
                'Check it before trying again.',
      ),
      splitz.SendResult.failed => (
        'Not sent',
        settled.detail ?? 'Nothing was spent.',
      ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(body),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// The lane [id] is paid in (§9.1), or none when they are not on the bill.
splitz.SettleLane _lane(BillView view, String id) {
  final who = view.bill.participant(id);
  return who == null ? splitz.SettleLane.none : splitz.laneFor(who);
}

/// Who entered each negative expense on the bill: the refunds §4 admits.
///
/// An expense with no known author counts as nobody's, so it can never make
/// the warning below read as this device's own doing.
Set<String> _refundAuthors(BillView view) => {
  for (final e in view.bill.expenses)
    if (e.amount < 0) view.expenseAuthors[e.id] ?? '',
};

/// Why a payment asks for what it does, when the payee alone does not say.
///
/// §6.3: netting reroutes payments, so a person can be asked to pay somebody
/// they never shared an expense with, and the part of a payment no debt of
/// theirs explains is the part a peer's hostile entry would put there.
///
/// Only a negative expense produces that part. When [me] entered every one
/// on the bill, it is this person's own refund and is stated without alarm;
/// otherwise the warning names who else entered one.
Widget? _explain(
  protocol.Settlement s,
  String Function(String) who,
  String currency, {
  required Set<String> refundAuthors,
  required String me,
}) {
  final elsewhere = <String, int>{};
  for (final c in s.covers) {
    if (c.to != s.to) elsewhere[c.to] = (elsewhere[c.to] ?? 0) + c.amount;
  }
  final lines = <String>[
    for (final e in elsewhere.entries)
      'includes ${formatAmount(e.value, currency)} you owe ${who(e.key)}',
  ];
  final unexplained = s.unexplained;
  if (lines.isEmpty && unexplained == 0) return null;
  final amount = formatAmount(unexplained, currency);
  final others = [
    for (final a in refundAuthors)
      if (a != me) a.isEmpty ? 'somebody unknown' : who(a),
  ]..sort();
  final ownRefund = refundAuthors.isNotEmpty && others.isEmpty;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final l in lines) Text(l),
      if (unexplained > 0)
        Builder(
          builder: (context) => Text(
            ownRefund
                ? 'A refund you entered accounts for $amount of this; no '
                      'shared debt does.'
                : others.isEmpty
                ? 'No debt the bill records for you explains $amount of '
                      'this. A negative expense — a refund — does this; '
                      'check who entered it before paying.'
                : 'No debt the bill records for you explains $amount of '
                      'this. A refund entered by ${others.join(', ')} does '
                      'this; check it before paying.',
            key: Key('splits_settle_unexplained_${s.to}'),
            style: ownRefund
                ? null
                : TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

/// What one ZEC was priced at for this request, and who said so (§14.2).
class _RateLine extends StatelessWidget {
  const _RateLine({required this.view, required this.who});

  final BillView view;
  final String Function(String) who;

  @override
  Widget build(BuildContext context) {
    final rate = view.bill.rate;
    if (rate == null) return const SizedBox.shrink();
    final by = view.rateSetBy;
    return Text(
      '1 ZEC = ${formatAmount(rate.minorUnitsPerZec, view.bill.currency)}, '
      'set by ${by == null ? 'nobody on the bill' : who(by)}',
      key: const Key('splits_settle_rate'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// ZEC, with every digit of the zatoshi figure (§8.2).
String _zec(int zatoshi) =>
    zatoshi > 0 ? '${protocol.renderAmount(zatoshi)} ZEC' : '0 ZEC';

/// The request as the wallet will send it, for the payer to accept (§14.2).
///
/// Every output's ZEC amount and address, the rate that produced them and who
/// set it. A figure in the bill's currency alone hides what the rate did.
class _ReviewSend extends StatelessWidget {
  const _ReviewSend({required this.view, required this.owed, this.live});

  final BillView view;
  final splitz.PayerObligation owed;

  /// A live price for one ZEC in the bill's currency, or null when none can
  /// be had. The bill's rate is held against it rather than against who set
  /// it: anyone holding the invite can join under a second name.
  final int? live;

  @override
  Widget build(BuildContext context) {
    final currency = view.bill.currency;
    String who(String id) =>
        view.bill.displayNameOf(id, creatorId: view.creatorId);
    final unpayable = {for (final u in owed.unpayable) u.id};
    // `renderObligation` emits one payment per carried settlement, in order.
    final carried = [
      for (final s in owed.settlements)
        if (!unpayable.contains(s.to)) s,
    ];
    final payments = owed.request.payments;
    final paired = carried.length == payments.length;
    final total = payments.fold<int>(0, (sum, p) => sum + p.zatoshi);
    final setter = view.rateSetBy;
    final setterIsPaid = setter != null && carried.any((s) => s.to == setter);
    final error = Theme.of(context).colorScheme.error;
    final rate = view.bill.rate?.minorUnitsPerZec;
    final off = _percentOff(rate, live);
    final replaced = {for (final r in view.replacedAddresses) r.id};

    return AlertDialog(
      title: const Text('Send this?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, p) in payments.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paired
                          ? '${who(carried[i].to)} · '
                                '${formatAmount(carried[i].amount, currency)}'
                          : p.label ?? 'Payment ${i + 1}',
                    ),
                    Text(
                      _zec(p.zatoshi),
                      key: Key('splits_review_zec_$i'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SelectableText(
                      p.address,
                      key: Key('splits_review_address_$i'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    // §10.7: an id no key is bound to is a name anyone on
                    // the bill can write for, address included.
                    if (paired &&
                        !view.identities.bound.containsKey(carried[i].to))
                      Text(
                        '${who(carried[i].to)} has not joined from their own '
                        'device, so anyone on the bill could have written '
                        'this address. Check it with them.',
                        key: Key('splits_review_unbound_${carried[i].to}'),
                        style: TextStyle(color: error),
                      ),
                    if (paired && replaced.contains(carried[i].to))
                      Text(
                        'This address replaced an earlier one.',
                        key: Key('splits_review_replaced_${carried[i].to}'),
                        style: TextStyle(color: error),
                      ),
                  ],
                ),
              ),
            Text('Total ${_zec(total)}, one transaction'),
            const SizedBox(height: 8),
            _RateLine(view: view, who: who),
            if (live == null) ...[
              const SizedBox(height: 8),
              Text(
                'No current price for ${view.bill.currency} is available to '
                'check this rate against. Compare it with a price you trust '
                'before sending.',
                key: const Key('splits_review_rate_unchecked'),
                style: TextStyle(color: error),
              ),
            ],
            if (off != null && off.abs() >= 5) ...[
              const SizedBox(height: 8),
              Text(
                'This rate is ${off.abs()}% ${off > 0 ? 'above' : 'below'} '
                'the current price of '
                '${formatAmount(live!, view.bill.currency)} a ZEC, so this '
                'sends ${off > 0 ? 'less' : 'more'} ZEC than the debt is '
                'worth today.',
                key: const Key('splits_review_rate_off'),
                style: TextStyle(color: error),
              ),
            ],
            if (setterIsPaid) ...[
              const SizedBox(height: 8),
              Text(
                '${who(setter)} set this rate and is paid by this request. '
                'Check it against a price you trust.',
                key: const Key('splits_review_setter_paid'),
                style: TextStyle(color: error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('splits_review_send'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

/// A send this device started and has not seen resolved (§14.3).
///
/// It may have landed. Nothing else goes out from this bill until the person
/// says which way it went: with the transaction id the wallet shows, it is
/// recorded; without one, it is cleared and the debt can be sent again.
class _PendingSend extends StatefulWidget {
  const _PendingSend({
    required this.intent,
    required this.who,
    required this.currency,
    required this.busy,
    required this.onResolve,
  });

  final PayIntent intent;
  final String Function(String) who;
  final String currency;
  final bool busy;
  final Future<void> Function({bool landed, String? txid}) onResolve;

  @override
  State<_PendingSend> createState() => _PendingSendState();
}

class _PendingSendState extends State<_PendingSend> {
  // Filled when the wallet already gave one and only the record is missing.
  late final _txid = TextEditingController(text: widget.intent.txid ?? '');

  @override
  void dispose() {
    _txid.dispose();
    super.dispose();
  }

  bool get _unreadable =>
      widget.intent.carried.isEmpty && widget.intent.swap == null;

  Future<void> _clear() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('It did not go through?'),
        content: const Text(
          'Only if the wallet shows no transaction for it. If it lands later '
          'and you send again, the debt is paid twice.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            key: const Key('splits_pending_clear_confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('It did not go through'),
          ),
        ],
      ),
    );
    if (sure == true) await widget.onResolve();
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('splits_pending_send'),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A send from this bill has not been resolved',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          const Text(
            'It may still reach the network. Check the wallet’s history '
            'before doing anything else.',
          ),
          for (final e in widget.intent.carried.entries)
            Text(
              '${widget.who(e.key)} · '
              '${formatAmount(e.value, widget.currency)}',
            ),
          // Stored and no longer readable: what it carried is unknown, so it
          // cannot be recorded from here. The people paid can record what
          // reached them, which is the one record that settles anything.
          if (_unreadable)
            const Text(
              'This device can no longer read what that send carried. If it '
              'went through, ask the people you paid to record it as '
              'received; if it did not, say so below.',
              key: Key('splits_pending_unreadable'),
            ),
          // A swap is recorded by the provider's reference, which this
          // device already holds; a payment request needs the transaction.
          if (widget.intent.swap == null && !_unreadable) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('splits_pending_txid'),
              controller: _txid,
              decoration: const InputDecoration(
                labelText: 'Transaction id, if the wallet shows one',
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('splits_pending_record'),
                onPressed: widget.busy || _unreadable
                    ? null
                    : () => widget.onResolve(
                        landed: true,
                        txid: widget.intent.swap == null ? _txid.text : null,
                      ),
                child: const Text('It went through'),
              ),
              TextButton(
                key: const Key('splits_pending_clear'),
                onPressed: widget.busy ? null : _clear,
                child: const Text('It did not go through'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// An address, short enough to compare by eye.
///
/// Both ends, because a substitution changes the middle: showing a prefix
/// alone would make a swapped address look identical to the one it replaced.
String _short(String? address) {
  if (address == null || address.isEmpty) return 'nothing';
  if (address.length <= 20) return address;
  return '${address.substring(0, 10)}…'
      '${address.substring(address.length - 8)}';
}

/// How far [rate] sits from [live], in whole percent of [live], or null when
/// either is missing. By integer arithmetic: both are minor units per ZEC.
int? _percentOff(int? rate, int? live) {
  if (rate == null || live == null || live <= 0) return null;
  final diff = BigInt.from(rate) - BigInt.from(live);
  return (diff * BigInt.from(100) ~/ BigInt.from(live)).toInt();
}
