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
import 'package:splitz_core/host.dart' show Arrival;
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../activity/activity_feed_sections.dart';
import '../../../activity/activity_row_mapper.dart'
    show formatActivityTimestamp, outgoingAmountColor;
import '../../../activity/models/activity_row_data.dart';
import '../../../activity/widgets/activity_feed.dart'
    show ActivityFeedSectionData;
import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'arrivals_screen.dart'
    show disputedConcern, paymentConcerns, unboundConcern, underpricedConcerns;
import 'splits_scope.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.billId});

  final String billId;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> with SplitsActions {
  List<SwapWatch> _inFlight = const [];
  final Map<String, SwapState> _states = {};

  String get billId => widget.billId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInFlight());
  }

  Future<void> _loadInFlight() async {
    if (!mounted) return;
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
    // Forgotten whether or not the screen is still open: the person asked.
    await act(() => controller.forgetSwap(watch.reference));
    if (!mounted) return;
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
          if (failure case final failed?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                failed,
                key: const Key('splits_activity_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
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
          // Every entry, newest first and grouped by month, drawn as the
          // wallet draws its own activity.
          WalletThemed(
            child: Builder(
              builder: (context) => _History(
                sections: buildActivityFeedSections([
                  for (final event in view.activity)
                    _EventTile(
                      event: event,
                      view: view,
                      me: controller.me,
                    ).entry(context),
                ]),
              ),
            ),
          ),
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
  List<String> _concerns(SplitsController controller) {
    bool held(List<Arrival> list) =>
        list.any((a) => a.billId == billId && a.payment.id == payment.id);
    final figures = payment.method == 'cash'
        ? const <String>[]
        : paymentConcerns(payment: payment, view: view, live: null);
    return [
      if (held(controller.disputed)) disputedConcern,
      if (held(controller.unbound)) unboundConcern,
      ...(held(controller.underpriced)
          ? underpricedConcerns(figures)
          : figures),
    ];
  }

  Future<void> _arrived(
    BuildContext context,
    String who,
    List<String> concerns,
  ) async {
    final controller = SplitsScope.read(context);
    final act = actionsOf(context);
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
    await act(
      () => controller.confirmPayment(
        billId: billId,
        paymentId: payment.id,
        method: _recipientConfirmed,
      ),
    );
  }

  /// Withdraws the record (§10.8 lets the payee void a payment naming them),
  /// so the debt is owed again.
  Future<void> _didNotArrive(BuildContext context, String who) async {
    final controller = SplitsScope.read(context);
    final act = actionsOf(context);
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
    final covered = controller.arrivedCovering(billId, payment.id) != null;
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
    await act(() => controller.withdraw(billId: billId, entryId: entry));
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
              '$who paid you '
              '${formatAmount(payment.amount, payment.currency)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (_how(payment) case final how?) Text(how),
            // §14.2: the ZEC the record says was sent, the rate it was priced
            // at, and its reference, on one line. A figure a ZEC or swap
            // record does not carry is said to be missing, since a card
            // without it reads the same as one that needs none. The
            // reference is shown by its first 14 characters, which
            // `checkPayeeReview` accepts; it is selectable whole.
            Wrap(
              spacing: 6,
              children: [
                if (zatoshi != null)
                  Text(
                    formatZec(zatoshi),
                    key: Key('splits_confirm_zec_${payment.id}'),
                  )
                else if (payment.method != 'cash')
                  Text(
                    'ZEC not recorded',
                    key: Key('splits_confirm_zec_${payment.id}'),
                  ),
                if (rate != null)
                  Text(
                    'at ${formatAmount(rate.minorUnitsPerZec, rate.currency)}'
                    '/ZEC',
                    key: Key('splits_confirm_rate_${payment.id}'),
                  )
                else if (payment.method != 'cash')
                  Text(
                    'rate not recorded',
                    key: Key('splits_confirm_rate_${payment.id}'),
                  ),
                if (reference == null && payment.method != 'cash')
                  Text(
                    'reference not recorded',
                    key: Key('splits_confirm_reference_${payment.id}'),
                  ),
              ],
            ),
            if (reference != null)
              SelectableText(
                '${payment.method == 'swap' ? 'swap' : 'tx'} '
                '${_shortReference(reference)}',
                key: Key('splits_confirm_reference_${payment.id}'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            // A swap's note is what its quote guaranteed would arrive, which
            // can be less than the debt the record settles. It is the
            // payer's word, so it is shown as theirs.
            if (payment.note case final note? when note.trim().isNotEmpty)
              Text(
                payment.method == 'swap' ? 'to deliver $note' : note,
                key: Key('splits_confirm_note_${payment.id}'),
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

  /// How it was paid, where that changes what to check. A shielded payment
  /// says nothing more than its figures do.
  static String? _how(protocol.PaymentRecord payment) =>
      switch (payment.method) {
        'cash' => 'in cash',
        // Half of a swap is visible and half is not: the ZEC leg left their
        // wallet, and whether the asset reached yours is yours to say.
        'swap' => 'by swap — check it arrived',
        _ => null,
      };
}

/// [reference]'s first 14 characters and an ellipsis, or all of it when that
/// saves nothing.
String _shortReference(String reference) =>
    reference.length <= 17 ? reference : '${reference.substring(0, 14)}…';

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
    final act = actionsOf(context);
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
    await act(
      () => controller.withdraw(billId: billId, entryId: event.entryId),
    );
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text('You said $what arrived'),
      trailing: TextButton(
        key: Key('splits_unconfirm_${event.entryId}'),
        onPressed: () => _takeBack(context),
        child: const Text('Take back'),
      ),
    );
  }
}

class _EventTile {
  const _EventTile({required this.event, required this.view, required this.me});

  final BillEvent event;
  final BillView view;

  /// This device's participant: its own payments say what carried them.
  final String me;

  /// [id]'s name. Somebody no longer on the bill is named as they last
  /// joined, not by their id.
  String _who(String? id) {
    if (id == null) return 'somebody';
    if (view.bill.participant(id) != null) {
      return view.bill.displayNameOf(id, creatorId: view.creatorId);
    }
    final joined = view.activity
        .where(
          (e) =>
              e.subject == id &&
              e.description != null &&
              (e.kind == BillEventKind.joined ||
                  e.kind == BillEventKind.addressChanged),
        )
        .firstOrNull;
    return joined?.description ??
        view.bill.displayNameOf(id, creatorId: view.creatorId);
  }

  /// The line an amendment or a withdrawal names, when this device holds it.
  BillEvent? get _target {
    final id = event.subject;
    if (id == null) return null;
    return view.activity.where((e) => e.entryId == id).firstOrNull;
  }

  /// What [target], an expense, was for, as a reader would name it.
  String _expense(BillEvent target) {
    final amount = _amount(target.amountMinorUnits);
    final what = target.description;
    return [
      'the${amount.isEmpty ? '' : ' $amount'} expense',
      if (what != null && what.isNotEmpty) 'for $what',
    ].join(' ');
  }

  /// A withdrawal, said as what it undid (§10.8).
  String get _withdrawal {
    final who = _who(event.author);
    final target = _target;
    if (target == null) return '$who withdrew an entry';
    return switch (target.kind) {
      BillEventKind.expenseAdded => '$who withdrew ${_expense(target)}',
      // Off the bill only once no join of theirs stands: withdrawing one of
      // several leaves them on it.
      BillEventKind.joined =>
        view.bill.participant(target.subject ?? '') == null
            ? '$who took ${_who(target.subject)} off the bill'
            : '$who withdrew a join for ${_who(target.subject)}',
      BillEventKind.addressChanged =>
        '$who withdrew a change to where ${_who(target.subject)} is paid',
      BillEventKind.paymentRecorded =>
        '$who withdrew a payment of ${_amount(target.amountMinorUnits)} '
            'to ${_who(target.subject)}',
      BillEventKind.paymentConfirmed => '$who took back a confirmation',
      BillEventKind.priced => '$who withdrew the rate',
      BillEventKind.entryWithdrawn => '$who undid a withdrawal',
      BillEventKind.expenseAmended => '$who withdrew a change to an expense',
      BillEventKind.closedForSettling => '$who reopened the bill for changes',
      BillEventKind.opened || BillEventKind.other => '$who withdrew an entry',
    };
  }

  /// An address change. §10.7 binds a participant's record to their key
  /// once they join with one; until then anybody holding the invite can
  /// write it, so it is not said to be theirs.
  String get _addressChange {
    final id = event.subject ?? event.author;
    return payoutChangedLine(
      _who(id),
      bound: view.identities.bound.containsKey(id),
    );
  }

  String _amount(int? minorUnits) =>
      minorUnits == null ? '' : formatAmount(minorUnits, view.bill.currency);

  /// A join from somebody whose earlier join was withdrawn: they were taken
  /// off, and taking somebody off does not change the bill's key, so they
  /// could read it all along and came back by joining (§10.8). Said to
  /// everybody, since nobody else is told any other way.
  bool get _rejoined =>
      !event.withdrawn &&
      view.activity.any(
        (e) =>
            e.kind == BillEventKind.joined &&
            e.entryId != event.entryId &&
            e.withdrawn &&
            e.author == event.author &&
            e.at.compareTo(event.at) < 0,
      );

  String get _sentence => switch (event.kind) {
    BillEventKind.opened =>
      '${_who(event.author)} started ${event.description ?? 'the bill'}',
    BillEventKind.joined =>
      _rejoined
          ? '${_who(event.author)} joined again after being taken off'
          : '${_who(event.author)} joined',
    // A join after theirs was withdrawn reads as an address change when it
    // states another payout; it is a return to the bill first.
    BillEventKind.addressChanged =>
      _rejoined
          ? '${_who(event.author)} joined again after being taken off'
          : _addressChange,
    BillEventKind.expenseAdded =>
      '${_who(event.subject)} paid ${_amount(event.amountMinorUnits)}'
          '${event.description == null ? '' : ' for ${event.description}'}',
    BillEventKind.expenseAmended =>
      '${_who(event.author)} changed '
          '${_target == null ? 'an expense' : _expense(_target!)}',
    BillEventKind.entryWithdrawn => _withdrawal,
    BillEventKind.closedForSettling =>
      '${_who(event.author)} closed the bill for settling',
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
        'waiting',
      // §13 requires a payer meet this before settling to the new address.
      if (event.kind == BillEventKind.addressChanged)
        'check with them before paying',
      // A payer's own send, by what carried it, so it can be found in the
      // wallet or with the provider. Nobody else's list carries it.
      if (event.kind == BillEventKind.paymentRecorded &&
          event.author == me &&
          event.reference != null)
        '${event.method == 'swap' ? 'swap' : 'tx'} '
            '${_shortReference(event.reference!)}',
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// The amount an expense or a payment moved, shown on the right.
  String get _figure => switch (event.kind) {
    BillEventKind.expenseAdded ||
    BillEventKind.paymentRecorded => _amount(event.amountMinorUnits),
    _ => '',
  };

  /// The line a row is named by. An expense goes by what it was for and a
  /// payment by who paid whom; everything else by its sentence.
  String get _title => switch (event.kind) {
    BillEventKind.expenseAdded when event.description != null =>
      event.description!,
    BillEventKind.expenseAdded => 'Expense',
    BillEventKind.paymentRecorded =>
      '${_who(event.author)} → ${_who(event.subject)}',
    _ => _sentence,
  };

  /// What is said under the title: who paid an expense, whether a payment
  /// is confirmed, and every caveat a reader must know.
  String? get _subtitle {
    final lead = switch (event.kind) {
      BillEventKind.expenseAdded => '${_who(event.subject)} paid',
      BillEventKind.paymentRecorded when event.confirmed => 'confirmed',
      _ => null,
    };
    final lines = [?lead, ?_caveat];
    return lines.isEmpty ? null : lines.join(' · ').replaceAll('\n', ' · ');
  }

  String get _icon => switch (event.kind) {
    BillEventKind.expenseAdded => AppIcons.coins,
    BillEventKind.paymentRecorded when event.author == me => AppIcons.plane,
    BillEventKind.paymentRecorded when event.subject == me =>
      AppIcons.arrowDownCircle,
    BillEventKind.paymentRecorded => AppIcons.swapArrows,
    BillEventKind.paymentConfirmed => AppIcons.checkCircle,
    BillEventKind.closedForSettling => AppIcons.lock,
    BillEventKind.joined => AppIcons.user,
    BillEventKind.opened => AppIcons.plus,
    BillEventKind.addressChanged => AppIcons.wallet,
    BillEventKind.priced => AppIcons.zcashCurrency,
    BillEventKind.expenseAmended => AppIcons.edit,
    BillEventKind.entryWithdrawn => AppIcons.uturnUp,
    BillEventKind.other => AppIcons.history,
  };

  /// This event as a row of the wallet's activity feed, dated by its §9.3
  /// instant.
  ActivityEntry entry(BuildContext context) {
    final colors = context.colors;
    final struck = event.withdrawn || event.refusedCode != null;
    final at = DateTime.tryParse(event.at);
    return ActivityEntry(
      timestamp: at,
      row: ActivityRowData(
        stableId: 'splits_event_${event.entryId}',
        title: _title,
        subtitle: _subtitle,
        leadingIconName: _icon,
        leadingBackgroundColor: colors.background.neutralSubtleOpacity,
        leadingIconColor: colors.icon.regular,
        amountText: _figure,
        amountColor: struck
            ? colors.text.muted
            : event.kind == BillEventKind.paymentRecorded && event.subject == me
            ? colors.text.positiveStrong
            : event.kind == BillEventKind.paymentRecorded && event.author == me
            ? outgoingAmountColor(colors)
            : null,
        statusText: '',
        timestampText: formatActivityTimestamp(at),
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

/// The bill's history as the wallet draws its own activity: a card per
/// month, each row an icon, what happened, and the figure and the time on
/// the right.
///
/// Built here rather than with the wallet's feed row, which is one
/// fixed-height line that cuts a name or an amount short: every figure on a
/// bill is read whole, at any text size.
class _History extends StatelessWidget {
  const _History({required this.sections});

  final List<ActivityFeedSectionData> sections;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.base),
        child: Text(
          'Nothing on this bill yet',
          style: AppTypography.labelLarge.copyWith(
            color: colors.text.secondary,
          ),
        ),
      );
    }
    return Padding(
      key: const Key('splits_activity_feed'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s,
        AppSpacing.s,
        AppSpacing.s,
        AppSpacing.base,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, section) in sections.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background.ground,
                borderRadius: BorderRadius.circular(AppRadii.large),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.base,
                  AppSpacing.lg,
                  AppSpacing.base,
                  AppSpacing.s,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      section.title,
                      style: AppTypography.labelLarge.copyWith(
                        color: colors.text.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s),
                    for (final row in section.rows) _HistoryRow(row: row),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.row});

  final ActivityRowData row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const line = AppTypography.labelLarge;
    // At large text sizes the figure and the time go under the title rather
    // than beside it: beside it they leave the title too narrow to hold a
    // figure on one line.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 24;
    final figure = <Widget>[
      if (row.amountText.isNotEmpty)
        Text(
          row.amountText,
          style: line.copyWith(color: row.amountColor ?? colors.text.primary),
        ),
      Text(row.timestampText, style: line.copyWith(color: colors.text.muted)),
    ];
    return Padding(
      key: ValueKey(row.stableId),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: stacked
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          // Dropped at large text sizes, where its width is what a figure
          // needs to stay on one line.
          if (!stacked) ...[
            SizedBox.square(
              dimension: AppAssetSize.size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: row.leadingBackgroundColor,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: AppIcon(
                    row.leadingIconName,
                    size: AppAssetSize.icon,
                    color: row.leadingIconColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  key: ValueKey('${row.stableId}_title'),
                  style: line.copyWith(color: colors.text.accent),
                ),
                if (row.subtitle case final subtitle?)
                  Text(
                    subtitle,
                    key: ValueKey('${row.stableId}_subtitle'),
                    style: line.copyWith(
                      color: colors.text.secondary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                if (stacked) ...figure,
              ],
            ),
          ),
          if (!stacked) ...[
            const SizedBox(width: AppSpacing.s),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: figure,
            ),
          ],
        ],
      ),
    );
  }
}
