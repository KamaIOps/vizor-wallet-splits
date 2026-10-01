/// Everything that happened on a bill, and the one tap that settles a debt.
///
/// The bill says what is true now. This says how it got there, which is the
/// only place three things are visible: an entry somebody withdrew, an entry
/// the fold refused and why, and a payment that has been claimed and not yet
/// confirmed.
///
/// **The confirmation is not decoration.** A payment record is a claim (§10.5)
/// and the balance does not move until the payee says the money arrived, so
/// until somebody taps here every cash and swap payment on the bill is still
/// outstanding.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import '../state/splits_controller.dart';
import '../view/naming.dart';
import 'arrivals_screen.dart' show disputedConcern, paymentConcerns;
import 'splits_scope.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.billId});

  final String billId;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<SwapWatch> _inFlight = const [];
  final Map<String, SwapState> _states = {};

  String get billId => widget.billId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInFlight());
  }

  Future<void> _loadInFlight() async {
    final held = await SplitsScope.read(context).swapsInFlight(billId);
    if (!mounted) return;
    setState(() => _inFlight = held);
  }

  Future<void> _check(SwapWatch watch) async {
    final state = await SplitsScope.read(context).checkSwap(watch);
    if (!mounted || state == null) return;
    // The row stays for this viewing even when the swap has finished and the
    // controller stopped following it. Reloading the list here would take the
    // answer off the screen at the moment somebody asked for it; reopening
    // the screen is when a finished swap drops off.
    setState(() => _states[watch.reference] = state);
  }

  /// Stops following [watch], after saying that nothing is cancelled.
  Future<void> _forget(SwapWatch watch) async {
    final controller = SplitsScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Stop following this swap?'),
        content: const Text(
          'The swap keeps going. This phone just stops checking it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep following'),
          ),
          FilledButton(
            key: Key('splits_inflight_forget_confirm_${watch.reference}'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Stop following'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await controller.forgetSwap(watch.reference);
    await _loadInFlight();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) {
      return const Scaffold(body: Center(child: Text('This bill is gone')));
    }

    final mine = awaitingConfirmationBy(view.bill, controller.me);
    // Confirmations this device wrote that still stand: each can be taken
    // back by its author (§10.8), which is the only undo a tap here has.
    final confirmed = [
      for (final e in view.activity)
        if (e.kind == BillEventKind.paymentConfirmed &&
            e.author == controller.me &&
            e.applied &&
            !e.withdrawn)
          e,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: ListView(
        children: [
          if (_inFlight.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Swaps you sent'),
            ),
            for (final watch in _inFlight)
              _InFlightTile(
                watch: watch,
                state: _states[watch.reference],
                onCheck: () => _check(watch),
                onForget: () => _forget(watch),
              ),
            const Divider(height: 24),
          ],
          if (mine.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Say it arrived'),
            ),
            for (final payment in mine)
              _AwaitingTile(billId: billId, view: view, payment: payment),
            const Divider(height: 24),
          ],
          if (confirmed.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Payments you said arrived'),
            ),
            for (final event in confirmed)
              _ConfirmedTile(billId: billId, view: view, event: event),
            const Divider(height: 24),
          ],
          for (final event in view.activity)
            _EventTile(event: event, view: view),
        ],
      ),
    );
  }
}

/// A payment somebody says they made to this device.
///
/// Only the payee sees this. A payer who could confirm their own payment
/// would settle a debt by asserting twice that they paid it, which is the one
/// thing a confirmation exists to prevent.
class _AwaitingTile extends StatelessWidget {
  const _AwaitingTile({
    required this.billId,
    required this.view,
    required this.payment,
  });

  final String billId;
  final BillView view;
  final protocol.PaymentRecord payment;

  /// What §10.5 is told about how this device decided.
  ///
  /// A person tapping "it arrived" is attesting from their own side, whatever
  /// the payer used to send it, so the confirmation names that rather than
  /// echoing the payment's method back.
  static const String _recipientConfirmed = 'recipientConfirmed';

  /// What the Payments received screen would hold this record back for
  /// (§14.2), so that confirming it here is no easier than there. Cash
  /// carries no figures to check.
  List<String> _concerns(SplitsController controller) => [
    if (controller.disputed.any(
      (a) => a.billId == billId && a.payment.id == payment.id,
    ))
      disputedConcern,
    if (payment.method != 'cash')
      ...paymentConcerns(payment: payment, view: view, live: null),
  ];

  Future<void> _arrived(
    BuildContext context,
    String who,
    List<String> concerns,
  ) async {
    final controller = SplitsScope.read(context);
    final settles = formatAmount(payment.amount, payment.currency);
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('It arrived?'),
        content: Text(
          concerns.isEmpty
              ? 'This settles $settles for everyone. Check your wallet first.'
              : '${concerns.join('\n\n')}\n\nThis settles $settles of what '
                    '$who owes you, for everyone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            key: Key(
              concerns.isEmpty
                  ? 'splits_confirm_sure_${payment.id}'
                  : 'splits_confirm_anyway_sure_${payment.id}',
            ),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(concerns.isEmpty ? 'It arrived' : 'Confirm anyway'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await controller.confirmPayment(
      billId: billId,
      paymentId: payment.id,
      method: _recipientConfirmed,
    );
  }

  /// Withdraws the record (§10.8 lets the payee void a payment naming them),
  /// so the debt is owed again.
  Future<void> _didNotArrive(BuildContext context, String who) async {
    final controller = SplitsScope.read(context);
    final entry = view.paymentEntries[payment.id];
    if (entry == null) return;
    // A record withdrawn while its transaction is on its way asks the payer
    // to send again, and the first transaction then matches nothing: so the
    // wallet's own history is read first. Only a record §14.7 proposes as
    // arrived is held: a reference anybody can copy off the bill, and one
    // whose transaction brought less than it states, is not evidence.
    final reference = payment.reference;
    final received = payment.method == 'shieldedZec' && reference != null
        ? await controller.hasReceived(reference)
        : false;
    if (!context.mounted) return;
    final covered = controller.arrived.any(
      (a) => a.billId == billId && a.payment.id == payment.id,
    );
    if (received == true && covered) {
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: Key('splits_confirm_refuse_received_${payment.id}'),
          title: const Text('It did arrive'),
          content: Text(
            'Your wallet received this transaction. Check the amount with '
            '$who, then confirm it rather than asking them to pay again.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final unchecked = received == null
        ? ' Your wallet\'s history could not be read to check.'
        : received
        ? ' Your wallet received that transaction, but it does not show this '
              'payment: another payer names it too, or it brought less ZEC '
              'than this states.'
        : payment.method == 'shieldedZec'
        ? ' Your wallet has not seen it yet, and a payment can take minutes '
              'to arrive.'
        : '';
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('It did not arrive?'),
        content: Text(
          '$who will owe ${formatAmount(payment.amount, payment.currency)} '
          'again.$unchecked Tell them first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            key: Key('splits_confirm_refuse_sure_${payment.id}'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('It did not arrive'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await controller.withdraw(billId: billId, entryId: entry);
  }

  @override
  Widget build(BuildContext context) {
    final who = view.bill.displayNameOf(
      payment.from,
      creatorId: view.creatorId,
    );
    final zatoshi = payment.zatoshi;
    final rate = payment.paidAtRate;
    final reference = payment.reference;
    final concerns = _concerns(SplitsScope.of(context));
    final error = Theme.of(context).colorScheme.error;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          key: Key('splits_confirm_${payment.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$who says they paid you '
              '${formatAmount(payment.amount, payment.currency)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(_how(payment)),
            // §14.2: what to hold against the wallet before confirming. A
            // confirmation settles the debt in the bill's currency, so the
            // ZEC the payer's rate made of it is what arrived or did not.
            //
            // A figure a ZEC or swap record does not carry is said to be
            // missing rather than left out: a card without it reads the same
            // as one that needs none. Cash carries none of them.
            if (zatoshi != null)
              Text(
                formatZec(zatoshi),
                key: Key('splits_confirm_zec_${payment.id}'),
              )
            else if (payment.method != 'cash')
              Text(
                'ZEC sent: not recorded',
                key: Key('splits_confirm_zec_${payment.id}'),
              ),
            if (rate != null)
              Text(
                'priced at ${formatAmount(rate.minorUnitsPerZec, rate.currency)} '
                'a ZEC',
                key: Key('splits_confirm_rate_${payment.id}'),
              )
            else if (payment.method != 'cash')
              Text(
                'rate: not recorded',
                key: Key('splits_confirm_rate_${payment.id}'),
              ),
            if (reference == null && payment.method != 'cash')
              Text(
                'reference: not recorded',
                key: Key('splits_confirm_reference_${payment.id}'),
              ),
            if (reference != null)
              SelectableText(
                payment.method == 'swap'
                    ? 'swap reference $reference — not a Zcash transaction'
                    : 'transaction $reference',
                key: Key('splits_confirm_reference_${payment.id}'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            for (final (i, c) in concerns.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  c,
                  key: Key('splits_confirm_concern_${payment.id}_$i'),
                  style: TextStyle(color: error),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: Key('splits_confirm_refuse_${payment.id}'),
                  onPressed: () => _didNotArrive(context, who),
                  child: const Text('It did not arrive'),
                ),
                FilledButton(
                  key: Key('splits_confirm_arrived_${payment.id}'),
                  onPressed: () => _arrived(context, who, concerns),
                  child: const Text('It arrived'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _how(protocol.PaymentRecord payment) =>
      switch (payment.method) {
        'cash' => 'in cash — nothing verifies this but you',
        // Half of a swap is visible and half is not: the ZEC leg left their
        // wallet, and whether the asset reached yours is yours to say.
        'swap' => 'by a swap — check the asset actually arrived',
        _ => 'by a shielded transaction',
      };
}

/// A confirmation this device wrote, and the way to take it back (§10.8).
class _ConfirmedTile extends StatelessWidget {
  const _ConfirmedTile({
    required this.billId,
    required this.view,
    required this.event,
  });

  final String billId;
  final BillView view;
  final BillEvent event;

  Future<void> _takeBack(BuildContext context) async {
    final controller = SplitsScope.read(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Take it back?'),
        content: const Text(
          'It goes back to waiting, and the debt is owed again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Leave it'),
          ),
          FilledButton(
            key: Key('splits_unconfirm_sure_${event.entryId}'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Take it back'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await controller.withdraw(billId: billId, entryId: event.entryId);
  }

  @override
  Widget build(BuildContext context) {
    final payment = view.bill.payments
        .where((p) => p.id == event.subject)
        .firstOrNull;
    final what = payment == null
        ? 'a payment'
        : '${formatAmount(payment.amount, payment.currency)} from '
              '${view.bill.displayNameOf(payment.from, creatorId: view.creatorId)}';
    return ListTile(
      key: Key('splits_confirmed_${event.entryId}'),
      dense: true,
      title: Text('You said $what arrived'),
      trailing: TextButton(
        key: Key('splits_unconfirm_${event.entryId}'),
        onPressed: () => _takeBack(context),
        child: const Text('Take back'),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.view});

  final BillEvent event;
  final BillView view;

  String _who(String? id) => id == null
      ? 'somebody'
      : view.bill.displayNameOf(id, creatorId: view.creatorId);

  String _amount(int? minorUnits) =>
      minorUnits == null ? '' : formatAmount(minorUnits, view.bill.currency);

  String get _sentence => switch (event.kind) {
    BillEventKind.opened =>
      '${_who(event.author)} started ${event.description ?? 'the bill'}',
    BillEventKind.joined => '${_who(event.author)} joined',
    BillEventKind.addressChanged =>
      '${_who(event.author)} changed where they are paid',
    BillEventKind.expenseAdded =>
      '${_who(event.subject)} paid ${_amount(event.amountMinorUnits)}'
          '${event.description == null ? '' : ' for ${event.description}'}',
    BillEventKind.expenseAmended => '${_who(event.author)} changed an expense',
    BillEventKind.entryWithdrawn => '${_who(event.author)} withdrew an entry',
    BillEventKind.paymentRecorded =>
      '${_who(event.author)} paid ${_who(event.subject)} '
          '${_amount(event.amountMinorUnits)}',
    BillEventKind.paymentConfirmed =>
      '${_who(event.author)} confirmed a payment arrived',
    BillEventKind.priced =>
      'priced at ${_amount(event.amountMinorUnits)} '
          'per ZEC${event.description == null ? '' : ' (${event.description})'}',
    BillEventKind.other => 'an entry this version does not read',
  };

  /// What to say under the line, where there is something a reader must know.
  ///
  /// **Every one that applies, not the first.** A swap that is both
  /// unconfirmed and carries a reference needs both sentences: returning at
  /// the first match made the reference line unreachable for exactly the
  /// events that carry one.
  String? get _caveat {
    if (event.refusedCode != null) {
      // Shown, never hidden: an entry that vanished silently is
      // indistinguishable from one that was never sent.
      final code = event.refusedCode!;
      return 'not applied — ${protocol.describeCode(code) ?? code}';
    }
    if (event.withdrawn) return 'withdrawn';

    final lines = <String>[
      // A record is a claim. Saying "paid" without this tells a payer a debt
      // is discharged that the payee has never agreed was paid.
      if (event.kind == BillEventKind.paymentRecorded && !event.confirmed)
        'not confirmed yet — still owed',
      // §13 requires a payer meet this before settling to the new address.
      if (event.kind == BillEventKind.addressChanged)
        'check this with them before paying',
      // Naming what it is not, because a hex string that looks like a txid is
      // exactly what a reader assumes of a swap's reference.
      if (event.reference != null)
        event.method == 'swap'
            ? 'swap reference ${event.reference} — not a Zcash transaction'
            : 'transaction ${event.reference}',
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final struck = event.withdrawn || event.refusedCode != null;
    final caveat = _caveat;

    return ListTile(
      key: Key('splits_event_${event.entryId}'),
      dense: true,
      title: Text(
        _sentence,
        style: struck
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: caveat == null
          ? null
          : Text(
              caveat,
              style: TextStyle(
                color: struck ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
    );
  }
}

/// A swap this device sent and has not seen finish.
class _InFlightTile extends StatelessWidget {
  const _InFlightTile({
    required this.watch,
    required this.state,
    required this.onCheck,
    required this.onForget,
  });

  final SwapWatch watch;

  /// What the provider last said, or null before anybody asked.
  final SwapState? state;

  final VoidCallback onCheck;

  /// Stops following this swap, for one the provider never finishes.
  final VoidCallback onForget;

  /// What the provider's answer means here.
  ///
  /// **`delivered` is not settled.** The provider says the asset was sent;
  /// §10.5 gives the debt to the payee, and only they can say it arrived.
  String get _said => switch (state) {
    null => 'Not checked yet',
    SwapState.awaitingDeposit =>
      'The provider has not seen the whole deposit yet',
    SwapState.processing => 'The provider is working on it',
    SwapState.refunding => 'Didn’t go through. The ZEC is coming back to you.',
    SwapState.delivered => 'Sent. They confirm when it arrives.',
    SwapState.failed => 'Didn’t go through. Any refund comes back to you.',
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: ListTile(
      key: Key('splits_inflight_${watch.reference}'),
      title: Text('${watch.assetSymbol} on ${watch.assetChain}'),
      subtitle: Text(_said),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            key: Key('splits_inflight_check_${watch.reference}'),
            onPressed: onCheck,
            child: const Text('Check'),
          ),
          IconButton(
            key: Key('splits_inflight_forget_${watch.reference}'),
            tooltip: 'Stop following',
            icon: const Icon(Icons.close),
            onPressed: onForget,
          ),
        ],
      ),
      isThreeLine: true,
    ),
  );
}
