/// Paying what this device owes.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart'
    show
        BillEventKind,
        BillNaming,
        PendingSend,
        payoutFallback,
        ratePercentOff,
        rateWarningPercent,
        refundsBehind;

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import '../view/review_rows.dart';
import 'activity_screen.dart';
import 'arrivals_screen.dart' show shortReference;
import 'price_bill_screen.dart';
import 'record_payment_screen.dart';
import 'swap_screen.dart';
import 'text_entry_screen.dart';
import 'usdc_chains.dart' show usdcChainName;
import 'splits_scope.dart';
import '../../../../core/profile_pictures.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_profile_picture.dart';
import '../../../../core/widgets/mobile/mobile_address_verify_sheet.dart';
import '../../../../core/widgets/review_buttons_stack.dart';
import '../../../../core/widgets/review_list_row.dart';
import '../../../../core/widgets/review_wrap_card.dart';
import '../../../send/widgets/send_review_layout.dart';

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

class _SettleScreenState extends State<SettleScreen> with SplitsActions {
  splitz.PayerObligation? _owed;
  splitz.Settled? _settled;
  PendingSend? _pending;
  String? _loadError;
  bool _unpriced = false;
  bool _loading = true;

  /// The changed-address notices this device closed on this bill.
  Set<String> _closedNotices = const {};

  /// Whether this screen has already tried to price the bill itself. Once:
  /// a feed that has no figure now will not have one on the next rebuild.
  bool _autoPriced = false;

  /// Payouts picked for the payer where a recipient's first one cannot be
  /// paid and a later one can, with why the first cannot. Read again on every
  /// load.
  Map<String, (protocol.Payout, String)> _auto = const {};

  /// True from a tap on Pay until the review it opened is closed and what it
  /// confirmed is sent: the bill is read again and priced before the review
  /// opens, and a second tap meanwhile would open a second review for the
  /// same debt.
  bool _working = false;

  /// Where each payout in effect below the first sat in its payee's list when
  /// [_owed] was read: what the request was rendered with, and what the send
  /// is checked against.
  Map<String, int> _via = const {};

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
    final closed = await controller.closedNotices(widget.billId);
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _closedNotices = closed;
    });
    try {
      final held = controller.bills
          .where((b) => b.id == widget.billId)
          .firstOrNull;
      var via = held == null
          ? const <String, int>{}
          : SplitsController.payoutIndexes(held.bill, const {});
      var owed = await controller.obligation(widget.billId, via: via);
      if (!mounted) return;
      // An unpriced bill is priced here from the wallet's live feed, so
      // settling needs no separate step (§7). The figure is written onto the
      // bill like any other rate, set by this device, and shown beside the
      // send. With no live figure for the bill's currency it stays unpriced
      // and a price is asked for.
      if (owed == null && !_autoPriced) {
        _autoPriced = true;
        final view = controller.bills
            .where((b) => b.id == widget.billId)
            .firstOrNull;
        final live = view == null
            ? null
            : await controller.quoteZec(view.bill.currency);
        if (!mounted) return;
        if (view != null && live != null) {
          await act(
            () => controller.setRate(
              billId: widget.billId,
              currency: view.bill.currency,
              minorUnitsPerZec: live,
              source: 'feed',
            ),
          );
          if (!mounted) return;
          owed = await controller.obligation(widget.billId, via: via);
          if (!mounted) return;
        }
      }
      // A first payout this device cannot pay by — an address no request can
      // carry, an asset the provider does not deliver — is passed over for
      // the next one it can, in the payee's order, and shown.
      final auto = <String, (protocol.Payout, String)>{};
      if (owed != null && held != null) {
        for (final u in owed.unpayable) {
          if (u.reason == 'unpriceable') continue;
          final payouts = held.bill.participant(u.id)?.payouts ?? const [];
          if (payouts.length < 2) continue;
          // What this wallet can pay is its own to say; which payout that
          // makes it is §14.8's, the host's.
          final pick = payoutFallback([
            for (final p in payouts) await controller.cannotPayBy(p),
          ]);
          if (pick != null) auto[u.id] = (payouts[pick.index], pick.passedOver);
        }
        if (!mounted) return;
        if (auto.isNotEmpty) {
          via = SplitsController.payoutIndexes(held.bill, {
            for (final MapEntry(:key, :value) in auto.entries) key: value.$1,
          });
          owed = await controller.obligation(widget.billId, via: via);
          if (!mounted) return;
        }
      }
      setState(() {
        _auto = auto;
        _via = via;
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
    if (_working) return;
    setState(() => _working = true);
    try {
      await _review(view);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _review(BillView view) async {
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
    // The review's rate, its setter and its warnings come from this view, so
    // it is folded from the same store the request was priced from. A rate
    // that moved after the pricing is a bill that changed.
    final current = await controller.currentView(widget.billId) ?? view;
    if (!mounted) return;
    final rate = current.bill.rate;
    if (rate == null ||
        rate.currency != owed.rate.currency ||
        rate.minorUnitsPerZec != owed.rate.minorUnitsPerZec ||
        rate.at != owed.rate.at) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('The bill changed. Check the amounts again.'),
        ),
      );
      await _load();
      return;
    }
    final via = _via;
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => _ReviewSend(
          view: current,
          owed: owed,
          live: live,
          via: via,
          me: controller.me,
          preview: controller.previewSend(owed),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    splitz.Settled? settled;
    await act(() async {
      settled = await controller.settle(widget.billId, owed, via: via);
    });
    if (!mounted) return;
    setState(() => _settled = settled);
    await _load();
  }

  /// Opens the swap or cash lane for [id], paid by [payout] when the payer
  /// chose one and by their first otherwise.
  ///
  /// Read again on return: a swap or a record made there changes what is
  /// owed here. A swap that could not be quoted or sent comes back asking for
  /// another way, and gets the sheet.
  Future<void> _openLane(String id, int amount, protocol.Payout? payout) async {
    final view = SplitsScope.read(
      context,
    ).bills.where((b) => b.id == widget.billId).firstOrNull;
    if (view == null) return;
    final swap = (payout?.type ?? _payoutAt(view, id, 0)?.type) == 'swap';
    await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => swap
            ? SwapScreen(
                billId: widget.billId,
                to: id,
                amountMinorUnits: amount,
                payout: payout,
              )
            : RecordPaymentScreen(
                billId: widget.billId,
                to: id,
                suggestedMinorUnits: amount,
              ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _resolve({bool landed = false, String? txid}) async {
    final controller = SplitsScope.read(context);
    final resolved = await act(
      () => controller.resolveSend(widget.billId, landed: landed, txid: txid),
    );
    if (!mounted) return;
    if (resolved) setState(() => _settled = null);
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
        // The ones this device wrote: only those are its payments in flight
        // (§14.4), and only those it may withdraw. A record the payee wrote
        // in its name is theirs.
        if (view.paymentAuthors[p.id] == controller.me &&
            p.from == controller.me &&
            p.to == to &&
            !view.bill.confirmedPayments.contains(p.id))
          view.paymentEntries[p.id],
    ].whereType<String>().toList();
    if (records.isEmpty) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Withdraw the record?'),
        content: const Text('Only if it never left your wallet.'),
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
    // Stops at the first refusal and leaves it on screen, so it is read
    // before anything else is withdrawn.
    for (final entryId in records) {
      if (!await act(
        () => controller.withdraw(billId: widget.billId, entryId: entryId),
      )) {
        break;
      }
    }
    if (mounted) await _load();
  }

  /// The address the request pays [to] at, or null when it carries nothing
  /// to them. `request.recipients` and `request.payments` are in one order.
  String? _requestAddress(String to) {
    final request = _owed?.request;
    if (request == null) return null;
    for (var i = 0; i < request.payments.length; i++) {
      if (request.recipients[i] == to) return request.payments[i].address;
    }
    return null;
  }

  /// Whether a payer may change how anybody is paid right now. Not while a
  /// send from this bill is unresolved: it may still land, and paying the
  /// same debt another way would pay it twice (§14.3).
  bool _canSwitch(SplitsController controller) =>
      !controller.busy && _pending == null;

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

    // The whole bill's plan, for the payments that come to this device: this
    // screen sends what is owed and shows what is owed in return.
    final plan = protocol.settleBill(view.bill).settlements;
    final owedToMe = [
      for (final s in plan)
        if (s.to == controller.me) s,
    ];
    final between = [
      for (final s in plan)
        if (s.to != controller.me && s.from != controller.me) s,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      bottomNavigationBar: _owed?.uri == null
          ? null
          : BottomActions(
              children: [
                FilledButton(
                  key: const Key('splits_settle_send'),
                  // Nothing goes out while an earlier send is unresolved: it
                  // may still land, and this one would pay the same debt
                  // again.
                  onPressed: controller.busy || _pending != null || _working
                      ? null
                      : () => _send(view),
                  child: Text(
                    'Pay ${formatAmount(_owed!.carriedMinorUnits, currency)} '
                    'in ZEC',
                  ),
                ),
              ],
            ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (!_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                plan.isEmpty
                    ? 'Everyone on this bill is square'
                    : plan.length == 1
                    ? 'One payment settles this bill'
                    : '${plan.length} payments settle this bill',
                key: const Key('splits_settle_plan'),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if ((_owed == null ? null : payerSummary(_owed!, view, via: _via))
              case final line?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                line,
                key: const Key('splits_settle_summary'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          if (_loadError != null)
            NoticeCard(
              key: const Key('splits_settle_load_error'),
              message: 'This bill cannot be settled from here: $_loadError',
              error: true,
            ),
          // A payment this device recorded and somebody withdrew: asked again
          // for the same debt, the payer is told the first may have landed
          // before sending a second.
          for (final e in view.activity)
            if (e.kind == BillEventKind.paymentRecorded &&
                e.withdrawn &&
                e.author == controller.me &&
                e.method == 'shieldedZec')
              NoticeCard(
                key: Key('splits_settle_withdrawn_${e.entryId}'),
                message:
                    'Your payment of '
                    '${formatAmount(e.amountMinorUnits ?? 0, currency)} to '
                    '${who(e.subject ?? '')}'
                    '${e.reference == null ? '' : ' (transaction ${shortReference(e.reference!)})'} '
                    'was withdrawn. Check your wallet\'s history before '
                    'paying again: if it went out, ask them to look again '
                    'rather than sending twice.',
                error: true,
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
            NoticeCard(message: 'This bill has no price on it yet.'),
            const SizedBox(height: 8),
            Center(
              child: FilledButton(
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
            ),
          ],
          if (_settled != null) _SentResult(settled: _settled!),
          // §14.2: every pay-to address the fold recorded as replaced, in
          // front of the payer BEFORE they settle. The activity feed shows it
          // too, but a person settling is not reading the history — and a
          // redirected address is the one change on a bill that moves money
          // to somebody else's wallet.
          //
          // Every one the fold recorded, as §14.2 asks: whether this request
          // pays them or not, the payer is told before deciding anything. One
          // card a person, every change of theirs on it in order.
          for (final id in {for (final r in view.replacedAddresses) r.id})
            if (!SplitsController.noticeClosed(view, id, _closedNotices))
              RowCard(
                key: Key('splits_settle_replaced_$id'),
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      // Said to be their doing only when a key binds them
                      // (§10.7); otherwise anyone with the invite could have.
                      child: Text(
                        view.identities.bound.containsKey(id)
                            ? '${payoutChangedLine(who(id), bound: true)}.'
                            : '${payoutChangedLine(who(id), bound: false)}. '
                                  'Check with them.',
                      ),
                    ),
                    // The send review says it again for every output it
                    // pays, so closing this hides nothing a payer needs.
                    IconButton(
                      key: Key('splits_settle_replaced_close_$id'),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () async {
                        final controller = SplitsScope.read(context);
                        await controller.closeNotice(view, id);
                        final closed = await controller.closedNotices(
                          widget.billId,
                        );
                        if (mounted) setState(() => _closedNotices = closed);
                      },
                    ),
                  ],
                ),
              ),
          if (_owed != null) ...[
            if (_owed!.settlements.isEmpty && _owed!.awaiting.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('You owe nothing on this bill.'),
              ),
            for (final s in _owed!.settlements)
              if (!_owed!.unpayable.any((u) => u.id == s.to)) ...[
                RowCard(
                  key: Key('splits_settle_pay_${s.to}'),
                  child: CardLine(
                    title: 'You → ${who(s.to)}',
                    subtitle: switch (_explanation(
                      s,
                      view,
                      who,
                      controller.me,
                    )) {
                      final why? => Text(
                        why.text,
                        key: Key('splits_settle_unexplained_${s.to}'),
                        style: why.own
                            ? null
                            : TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                      ),
                      // A lower choice is said by the `_Passed` line under
                      // the row and on the review (§14.8).
                      null => Text(zecLane(_requestAddress(s.to))),
                    },
                    trailing: formatAmount(s.amount, currency),
                  ),
                ),
                if (_auto[s.to] case (_, final why))
                  _Passed(id: s.to, why: why),
              ],
            for (final a in _owed!.awaiting) ...[
              RowCard(
                key: Key('splits_settle_awaiting_${a.to}'),
                child: CardLine(
                  // Named by who the money went to. Under §6.3 that can be
                  // somebody other than who the debt is owed to, and the payer
                  // looks for a payment to them.
                  title:
                      'Waiting on ${a.paidTo.isEmpty ? who(a.to) : a.paidTo.map(who).join(', ')}',
                  // §10.5: a record does not discharge a debt. Asking again
                  // would send the same money twice.
                  subtitle: Text(
                    a.paidTo.isEmpty || a.paidTo.every((p) => p == a.to)
                        ? 'Sent, waiting for them'
                        : 'Sent for ${who(a.to)}, waiting for them',
                  ),
                  // What was sent against what is owed: a debt that grew
                  // after the payment is otherwise shown nowhere.
                  trailing: a.owed > a.paid
                      ? '${formatAmount(a.paid, currency)} of '
                            '${formatAmount(a.owed, currency)}'
                      : formatAmount(a.paid, currency),
                ),
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
              _Unpayable(
                billId: widget.billId,
                view: view,
                debt: u,
                who: who,
                inEffect: _via[u.id] ?? 0,
                passed: _auto[u.id]?.$2,
                canSwitch: _canSwitch(controller),
                onOpen: () {
                  final at = _via[u.id] ?? 0;
                  _openLane(
                    u.id,
                    u.minorUnits,
                    at > 0 ? _payoutAt(view, u.id, at) : null,
                  );
                },
                onReturn: () async {
                  if (mounted) await _load();
                },
              ),
            if (_owed!.uri != null) ...[
              const SizedBox(height: 8),
              if (!_owed!.isComplete)
                Text(
                  'Sends ${formatAmount(_owed!.carriedMinorUnits, currency)}, leaves ${formatAmount(_owed!.withheldMinorUnits, currency)} owed.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              _RateLine(view: view),
            ],
          ],
          for (final s in owedToMe)
            RowCard(
              key: Key('splits_settle_owed_${s.from}'),
              // What reaches this device is confirmed in the activity, where
              // each record waits for the person it pays (§10.5).
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ActivityScreen(billId: widget.billId),
                ),
              ),
              child: CardLine(
                title: '${who(s.from)} → you',
                subtitle: const Text(
                  'They owe you — confirm it when it arrives',
                ),
                trailing: formatAmount(s.amount, currency),
                chevron: true,
              ),
            ),
          for (final s in between)
            RowCard(
              key: Key('splits_settle_between_${s.from}_${s.to}'),
              child: CardLine(
                title: '${who(s.from)} → ${who(s.to)}',
                trailing: formatAmount(s.amount, currency),
              ),
            ),
          if (failure case final failed?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                failed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// A debt a payment request cannot carry (§8.5), and the way to settle it when
/// there is one.
///
/// Reported, never dropped: a dropped output settles less than the plan says
/// it does, and the payer cannot tell.
class _Unpayable extends StatelessWidget {
  const _Unpayable({
    required this.billId,
    required this.view,
    required this.debt,
    required this.who,
    required this.inEffect,
    required this.passed,
    required this.canSwitch,
    required this.onOpen,
    required this.onReturn,
  });

  final String billId;
  final BillView view;
  final protocol.Unpayable debt;
  final String Function(String) who;

  /// Which of their declared payouts this row is settled by: 0 unless the
  /// payer chose a lower one or the first cannot be paid (§14.8).
  final int inEffect;

  /// Why their first payout was passed over, when it was.
  final String? passed;

  final bool canSwitch;

  /// Opens the swap or cash lane for the payout in effect.
  final VoidCallback onOpen;

  final Future<void> Function() onReturn;

  @override
  Widget build(BuildContext context) {
    final u = debt;
    final currency = view.bill.currency;
    // No address, or one no request can carry: nothing to send until one is
    // there, so the row offers to add it instead.
    final needsAddress = u.reason == 'no_address' || u.reason == 'bad_address';
    final deadEnd = needsAddress || u.reason == 'unpriceable';
    // Their record is anyone's to write until they join from their own
    // device (§10.7), so an address can be added for them here.
    final canAddAddress =
        needsAddress && !view.identities.bound.containsKey(u.id);
    // How they are paid can be changed here on the same terms as it can be
    // added: their record is still anyone's to write (§10.7), and no send
    // from this bill is unresolved (§14.8).
    final canEdit =
        !deadEnd && canSwitch && !view.identities.bound.containsKey(u.id);
    final method = Text(_unpayableWords(view, u, inEffect));
    final line = CardLine(
      title: 'You → ${who(u.id)}',
      subtitle: !canEdit
          ? method
          : Row(
              children: [
                Flexible(child: method),
                TextButton(
                  key: Key('splits_settle_edit_payout_${u.id}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    await askAndSetAddress(
                      context,
                      billId: billId,
                      id: u.id,
                      name: who(u.id),
                    );
                    await onReturn();
                  },
                  child: const Text('Edit'),
                ),
              ],
            ),
      trailing: formatAmount(u.minorUnits, currency),
      chevron: !deadEnd,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RowCard(
          key: Key('splits_settle_unpayable_${u.id}'),
          // A swap payout goes to the swap flow, which quotes it and sends
          // the ZEC leg. Cash has nothing to send, so it goes straight to the
          // record. Not while a send from this bill is unresolved: paying the
          // same debt another way could pay it twice (§14.8).
          onTap: deadEnd || !canSwitch ? null : onOpen,
          child: deadEnd
              ? line
              : KeyedSubtree(
                  key: Key('splits_settle_apart_${u.id}'),
                  child: line,
                ),
        ),
        if (passed != null) _Passed(id: u.id, why: passed!),
        // Unpriceable is about the amount, which no other payout changes.
        if (canAddAddress)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: Key('splits_settle_add_address_${u.id}'),
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: Text('How ${who(u.id)} gets paid'),
              onPressed: () async {
                await askAndSetAddress(
                  context,
                  billId: billId,
                  id: u.id,
                  name: who(u.id),
                );
                await onReturn();
              },
            ),
          )
        else if (needsAddress)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            // A bad address is one they already gave: what they are asked
            // for is a different one, not a first.
            child: Text(
              u.reason == 'bad_address'
                  ? 'Ask ${who(u.id)} for an address this wallet can pay.'
                  : 'Ask ${who(u.id)} to add one in the app.',
              key: Key('splits_settle_ask_${u.id}'),
            ),
          ),
      ],
    );
  }
}

/// Why a recipient's first payout was passed over for a later one.
class _Passed extends StatelessWidget {
  const _Passed({required this.id, required this.why});

  final String id;
  final String why;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 16, top: 2),
    child: Text(
      'Not their first choice: $why.',
      key: Key('splits_settle_passed_$id'),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

/// How [debt] is settled outside the request, or why it cannot be, in the
/// words the settle screen and the send review both use.
///
/// §8.5's reason when nothing can settle it yet; otherwise the lane of the
/// payout at [inEffect] in their declared order, ranked when it is not their
/// first. A recipient excluded for a payout this request cannot carry is
/// still owed, and settling them is a different lane rather than an
/// impossibility.
String _unpayableWords(BillView view, protocol.Unpayable debt, int inEffect) {
  final payout = _payoutAt(view, debt.id, inEffect);
  final rank = inEffect > 0 ? 'Their ${ordinal(inEffect + 1)} choice · ' : '';
  return switch (debt.reason) {
    'no_address' => 'No Zcash address yet',
    'bad_address' => 'Their address can’t be paid',
    // §8.5: more than one request can carry at this rate.
    'unpriceable' => 'Needs more than one payment request',
    _ =>
      _laneAt(view, debt.id, inEffect) == splitz.SettleLane.swap
          ? '${rank}Pay in ${payout?.asset ?? 'another asset'}'
                '${payout?.chain == null ? '' : ' on ${usdcChainName(payout!.chain!)}'}'
          : '${rank}Cash',
  };
}

/// [id]'s payout at [index] in their declared order, or null.
protocol.Payout? _payoutAt(BillView view, String id, int index) {
  final payouts = view.bill.participant(id)?.payouts ?? const [];
  return index < payouts.length ? payouts[index] : null;
}

/// How a ZEC payment to [address] travels, by the kind §8.6 reads it as.
///
/// Shielded when §8.6 says a memo can reach the recipient — a Sapling address,
/// or a Unified Address, which §8.6 admits only with a Sapling or Orchard
/// receiver; transparent for P2PKH, P2SH and TEX, whose payments are public on
/// the chain. An address §8.6 refuses is said as plain ZEC: nothing is claimed
/// about it.
String zecLane(String? address) =>
    switch (address == null ? null : _parsed(address)?.canReceiveMemo) {
      true => 'Shielded ZEC',
      false => 'Transparent ZEC',
      null => 'ZEC',
    };

/// [address] as §8.6 reads it, or null when it refuses it.
protocol.ParsedAddress? _parsed(String address) {
  try {
    return protocol.parseAddress(address);
  } on protocol.SplitError {
    return null;
  }
}

/// What a send produced, in the three states it can be in.
class _SentResult extends StatelessWidget {
  const _SentResult({required this.settled});

  final splitz.Settled settled;

  @override
  Widget build(BuildContext context) {
    final (String title, String body) = switch (settled.result) {
      splitz.SendResult.sent => ('Sent', 'Sent. Waiting for them to confirm.'),
      // Neither paid nor unpaid. Nothing was recorded and no retry is safe
      // until the wallet says which way it went.
      splitz.SendResult.pending => (
        'Built, not sent yet',
        settled.detail ?? 'Not on the network yet. Check before retrying.',
      ),
      // Nothing left the wallet, so sending again spends nothing twice.
      splitz.SendResult.failed => (
        'Not sent',
        '${describeSendFailure(settled.detail ?? 'Nothing was spent.')} '
            'Send again when that is fixed.',
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

/// Everything this device owes on the bill, by how it travels, in one line:
/// `0.21 ZEC + 9.00 INR by swap + 5.00 INR in cash`.
///
/// The ZEC is what the request sends. A swap's part is in the bill's currency:
/// what arrives in the other asset is only known once it is quoted. Null when
/// everything owed travels one way: the pay button already says what that is.
String? payerSummary(
  splitz.PayerObligation owed,
  BillView view, {
  Map<String, int> via = const {},
}) {
  final currency = view.bill.currency;
  final zatoshi = owed.carriedZatoshi.values.fold(0, (a, b) => a + b);
  var swap = 0;
  var cash = 0;
  var none = 0;
  for (final u in owed.unpayable) {
    switch (_laneAt(view, u.id, via[u.id] ?? 0)) {
      case splitz.SettleLane.swap:
        swap += u.minorUnits;
      case splitz.SettleLane.cash:
        cash += u.minorUnits;
      case splitz.SettleLane.zec || splitz.SettleLane.none:
        none += u.minorUnits;
    }
  }
  final parts = [
    if (zatoshi > 0) formatZec(zatoshi),
    if (swap > 0) '${formatAmount(swap, currency)} by swap',
    if (cash > 0) '${formatAmount(cash, currency)} in cash',
    if (none > 0) '${formatAmount(none, currency)} not payable yet',
  ];
  return parts.length < 2 ? null : parts.join(' + ');
}

/// The lane [id] is paid in when the payout at [index] of theirs is in
/// effect (§9.1, §14.8), or none when they are not on the bill.
splitz.SettleLane _laneAt(BillView view, String id, int index) {
  final who = view.bill.participant(id);
  if (who == null) return splitz.SettleLane.none;
  if (index == 0) return splitz.laneFor(who);
  return switch (_payoutAt(view, id, index)?.type) {
    'zec' => splitz.SettleLane.zec,
    'swap' => splitz.SettleLane.swap,
    'cash' => splitz.SettleLane.cash,
    _ => splitz.SettleLane.none,
  };
}

/// The words a part of a payment no debt explains is shown with: the
/// beginning of every such sentence that warns.
const _unexplainedWords = 'No debt the bill records for you explains';

/// The part of [s] no debt of the payer's explains, as one sentence, and
/// whether it is the payer's own doing; null when every part is explained.
///
/// §6.3: netting reroutes payments, so a person can be asked to pay somebody
/// they never shared an expense with; that rerouting is not called out. The
/// part no debt explains is the part a peer's hostile entry would put there.
///
/// A refund is named as its cause only when the bill holds one that does it:
/// the negative expenses recorded as paid by the payer, each moving its other
/// people's shares onto them, add up to at least the part. When the payer
/// entered every one of those it is their own refund and is stated without
/// alarm; otherwise the sentence names who else entered one. Anything else
/// that raises what the payer owes, a confirmed payment to them above what
/// they were owed among it, is stated without naming a cause.
({String text, bool own})? _explanation(
  protocol.Settlement s,
  BillView view,
  String Function(String) who,
  String me,
) {
  final unexplained = s.unexplained;
  if (unexplained <= 0) return null;
  final amount = formatAmount(unexplained, view.bill.currency);
  // §6.3: only a refund on the bill that moves the whole part onto the payer
  // is named as one; a confirmed payment above what was owed leaves the same
  // figure with no refund behind it.
  final folded = view.folded;
  final behind = folded == null ? null : refundsBehind(s, folded);
  if (behind == null) {
    return (
      text: '$_unexplainedWords $amount of this. Check the bill before paying.',
      own: false,
    );
  }
  final authors = behind.authors;
  final others = [
    for (final a in authors)
      if (a != me) a.isEmpty ? 'somebody unknown' : who(a),
  ]..sort();
  if (others.isEmpty) {
    return (text: 'Includes your refund of $amount.', own: true);
  }
  return (
    text:
        '$_unexplainedWords $amount of this. A refund entered by '
        '${others.join(', ')} does this; check it before paying.',
    own: false,
  );
}

/// What one ZEC was priced at for this request (§14.2).
class _RateLine extends StatelessWidget {
  const _RateLine({required this.view});

  final BillView view;

  @override
  Widget build(BuildContext context) {
    final rate = view.bill.rate;
    if (rate == null) return const SizedBox.shrink();
    return Text(
      '1 ZEC = ${formatAmount(rate.minorUnitsPerZec, view.bill.currency)}',
      key: const Key('splits_settle_rate'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// ZEC, with every digit of the zatoshi figure (§8.2).
String _zec(int zatoshi) => formatZec(zatoshi);

/// The review a settlement is sent from, laid out as the wallet's own send
/// review: per payment its ZEC and what it settles, who it goes to and their
/// address; then the fee, the rate and the total; then Confirm & send.
///
/// What §14.2 requires a payer be shown stays on it: every output's ZEC,
/// payee and address, the rate, a replaced address, a lower preference, any
/// part of a payment no debt explains, and what the request leaves unpaid —
/// who it cannot pay and why, payments still awaiting confirmation, and what
/// is withheld. A rate far from the live price is said, and so is an account
/// that cannot cover the request and its fee, which holds Confirm & send
/// back; so does a fee the wallet has not yet answered with.
class _ReviewSend extends StatefulWidget {
  const _ReviewSend({
    required this.view,
    required this.owed,
    required this.preview,
    required this.me,
    this.live,
    this.via = const {},
  });

  final BillView view;
  final splitz.PayerObligation owed;

  /// This device's participant id: whose own refund a payment may include.
  final String me;

  /// What sending [owed] would take, asked of the wallet as the review opens.
  /// Handed in rather than looked up, so the review reads nothing from the
  /// navigator it is pushed on.
  final Future<SendPreview> preview;

  /// The payout each recipient it names is paid by, when the payer chose one
  /// below their first (§14.8).
  final Map<String, int> via;

  /// A live price for one ZEC in the bill's currency, or null when none can
  /// be had.
  final int? live;

  @override
  State<_ReviewSend> createState() => _ReviewSendState();
}

class _ReviewSendState extends State<_ReviewSend> {
  SendPreview? _preview;

  @override
  void initState() {
    super.initState();
    widget.preview.then((preview) {
      if (mounted) setState(() => _preview = preview);
    });
  }

  // The wallet's own review widgets, under the wallet's theme.
  @override
  Widget build(BuildContext context) =>
      WalletThemed(child: Builder(builder: _page));

  Widget _page(BuildContext context) {
    final view = widget.view;
    final owed = widget.owed;
    final via = widget.via;
    final live = widget.live;
    final currency = view.bill.currency;
    String who(String id) =>
        view.bill.displayNameOf(id, creatorId: view.creatorId);
    final payments = owed.request.payments;
    // Who each output pays, as the request itself says: `recipients` and
    // `payments` are one order, so no row is matched by its position in a
    // second list.
    final recipients = owed.request.recipients;
    String? toOf(int i) => i < recipients.length ? recipients[i] : null;
    protocol.Settlement? settlementOf(String? to) =>
        owed.settlements.where((s) => s.to == to).firstOrNull;
    final total = payments.fold<int>(0, (sum, p) => sum + p.zatoshi);
    final rate = view.bill.rate?.minorUnitsPerZec;
    final off = rate == null || live == null
        ? null
        : ratePercentOff(rate, live);
    final replaced = {for (final r in view.replacedAddresses) r.id};
    final preview = _preview;
    final short = preview?.short ?? false;
    final fee = preview?.feeZatoshi;
    final me = widget.me;

    String toName(int i) => switch (toOf(i)) {
      final to? => who(to),
      null => payments[i].label ?? 'Payment ${i + 1}',
    };

    // §14.2: what this request leaves unpaid, said on the page the payer
    // confirms, from the obligation the settle screen shows.
    final unpaid = <Widget>[
      for (final u in owed.unpayable)
        ReviewNote(
          '${who(u.id)}: ${formatAmount(u.minorUnits, currency)} is not in '
          'this send. ${_unpayableWords(view, u, via[u.id] ?? 0)}.',
          textKey: Key('splits_review_unpayable_${u.id}'),
        ),
      for (final a in owed.awaiting)
        ReviewNote(
          'Waiting on '
          '${a.paidTo.isEmpty ? who(a.to) : a.paidTo.map(who).join(', ')}'
          '${a.paidTo.isEmpty || a.paidTo.every((p) => p == a.to) ? '' : ' for ${who(a.to)}'}: '
          '${formatAmount(a.paid, currency)}'
          '${a.owed > a.paid ? ' of ${formatAmount(a.owed, currency)}' : ''} '
          'sent, not yet confirmed. Not in this send.',
          iconName: AppIcons.time,
          warning: false,
          textKey: Key('splits_review_awaiting_${a.to}'),
        ),
      if (!owed.isComplete)
        ReviewNote(
          'Sends ${formatAmount(owed.carriedMinorUnits, currency)}, leaves '
          '${formatAmount(owed.withheldMinorUnits, currency)} owed.',
          textKey: const Key('splits_review_withheld'),
        ),
    ];

    return Scaffold(
      key: const Key('splits_review'),
      body: SafeArea(
        child: SingleChildScrollView(
          child: SendReviewContentColumn(
            title: 'Review send',
            children: [
              for (final (i, p) in payments.indexed)
                Column(
                  key: Key('splits_review_payment_$i'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SendReviewInfoSection(
                      amountText: _zec(p.zatoshi),
                      recipient: SendReviewAddressRecipient(address: p.address),
                      // Every digit of the ZEC, drawn smaller rather than
                      // cut, over what it settles in the bill's currency.
                      amountRow: ReviewFitRow(
                        label: 'Amount',
                        value: _zec(p.zatoshi),
                        leading: const ReviewZecCoinImage(),
                        oneLine: true,
                        bottom: switch (settlementOf(toOf(i))) {
                          final settled? => formatAmount(
                            settled.amount,
                            currency,
                          ),
                          null => null,
                        },
                      ),
                      // The bill's name for them, whole, and the address as
                      // the review must show it (§14.2: at least its first
                      // ten characters, which the wallet's own short form
                      // cuts).
                      recipientRow: ReviewFitRow(
                        label: 'To',
                        value: toName(i),
                        leading: AppProfilePicture(
                          profilePictureId: kDefaultProfilePictureId,
                          size: AppProfilePictureSize.navLarge,
                        ),
                        bottom: reviewAddress(p.address),
                        actionLabel: 'Show full address',
                        actionKey: Key('splits_review_full_address_$i'),
                        onAction: () => showMobileAddressVerifySheet(
                          context,
                          title: toName(i),
                          address: p.address,
                          leading: AppProfilePicture(
                            profilePictureId: kDefaultProfilePictureId,
                            size: AppProfilePictureSize.large,
                          ),
                        ),
                      ),
                    ),
                    // §14.2: paid somewhere they ranked lower than first.
                    if ((via[toOf(i)] ?? 0) > 0)
                      ReviewNote(
                        'Their ${ordinal(via[toOf(i)]! + 1)} choice, not '
                        'their first.',
                        textKey: Key('splits_review_lower_${toOf(i)}'),
                      ),
                    // §14.2: every pay-to address the fold recorded as
                    // replaced.
                    if (replaced.contains(toOf(i)))
                      ReviewNote(
                        'Address recently changed.',
                        textKey: Key('splits_review_replaced_${toOf(i)}'),
                      ),
                    // §14.2: any part of what they are paid that no debt
                    // explains, in the settle screen's words.
                    if (settlementOf(toOf(i)) case final s?)
                      if (_explanation(s, view, who, me) case final why?)
                        ReviewNote(
                          why.text,
                          warning: !why.own,
                          iconName: why.own
                              ? AppIcons.checkCircle
                              : AppIcons.warning,
                          textKey: Key('splits_review_unexplained_${s.to}'),
                        ),
                  ],
                ),
              if (unpaid.isNotEmpty)
                Column(
                  key: const Key('splits_review_unpaid'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AppSpacing.xs,
                  children: unpaid,
                ),
              ReviewTextScaleCap(
                maxScale: ReviewTextScaleCap.listRow,
                child: ReviewWrapCard(
                  children: [
                    if (fee != null) ...[
                      ReviewListRow(
                        key: const Key('splits_review_fee'),
                        label: 'Tx fee',
                        value: _zec(fee),
                      ),
                      const ReviewWrapDivider(),
                    ] else if (preview == null) ...[
                      // Confirm & send is held until the wallet answers, and
                      // the page says why.
                      ReviewListRow(
                        key: const Key('splits_review_fee_pending'),
                        label: 'Tx fee',
                        value: 'Working out the fee…',
                        valueColor: context.colors.text.secondary,
                        scaleValueToFit: true,
                      ),
                      const ReviewWrapDivider(),
                    ],
                    ReviewListRow(
                      key: const Key('splits_settle_rate'),
                      label: 'Rate',
                      value: view.bill.rate == null
                          ? '—'
                          : '1 ZEC = ${formatAmount(view.bill.rate!.minorUnitsPerZec, currency)}',
                      scaleValueToFit: true,
                    ),
                    if (payments.length > 1) ...[
                      const ReviewWrapDivider(),
                      // With the fee once the wallet has given it; until then
                      // the row says the fee is not in it.
                      ReviewListRow(
                        key: const Key('splits_review_total'),
                        label: fee == null ? 'Total before fee' : 'Total',
                        value: _zec(fee == null ? total : total + fee),
                        scaleValueToFit: true,
                      ),
                    ],
                  ],
                ),
              ),
              if ((off != null && off.abs() >= rateWarningPercent) || short)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AppSpacing.xs,
                  children: [
                    if (off != null && off.abs() >= rateWarningPercent)
                      ReviewNote(
                        'This rate is ${off.abs()}% '
                        '${off > 0 ? 'above' : 'below'} the current price of '
                        '${formatAmount(live!, currency)} a ZEC.',
                        textKey: const Key('splits_review_rate_off'),
                      ),
                    if (short)
                      ReviewNote(
                        switch ((preview!.haveZatoshi, preview.needZatoshi)) {
                          (final have?, final need?) =>
                            'Not enough ZEC: this needs ${_zec(need)} '
                                'including the fee, and the wallet has '
                                '${_zec(have)}.',
                          _ => 'Not enough ZEC to cover this and its fee.',
                        },
                        warning: false,
                        textKey: const Key('splits_review_short'),
                      ),
                  ],
                ),
              ReviewTextScaleCap(
                maxScale: ReviewTextScaleCap.largeButton,
                child: ReviewButtonsStack(
                  primaryKey: const Key('splits_review_send'),
                  // As the wallet's own send says it: the reason on the button
                  // it holds back.
                  primaryLabel: preview == null
                      ? 'Working out the fee…'
                      : short
                      ? 'Not enough ZEC'
                      : 'Confirm & send',
                  primaryLeadingIconName: preview == null || short
                      ? null
                      : AppIcons.plane,
                  // Held while the wallet is asked, and when it says the
                  // account cannot cover the request and its fee: the preview
                  // reads the same settled balance the send does.
                  onPrimaryPressed: preview == null || short
                      ? null
                      : () => Navigator.of(context).pop(true),
                  secondaryLabel: 'Cancel',
                  onSecondaryPressed: () => Navigator.of(context).pop(false),
                ),
              ),
            ],
          ),
        ),
      ),
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

  final PendingSend intent;
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
        content: const Text('Only if your wallet shows no transaction.'),
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
          const Text('It may still go through. Check your wallet first.'),
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
              'Send details lost. Ask who you paid to confirm.',
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

/// [address] as the send review shows it: its first 13 characters, an
/// ellipsis and its last 11, or whole when that would save nothing.
///
/// §14.2 counts an address as shown when its first 10 characters are followed
/// by a character that is not an ASCII letter or digit, which the space
/// before the ellipsis is (`checkPayerReview`). Characters are Unicode scalar
/// values (§2.3).
String reviewAddress(String address) {
  const head = 13, tail = 11;
  final runes = address.runes.toList();
  if (runes.length <= head + tail + 3) return address;
  return '${String.fromCharCodes(runes.take(head))} … '
      '${String.fromCharCodes(runes.skip(runes.length - tail))}';
}
