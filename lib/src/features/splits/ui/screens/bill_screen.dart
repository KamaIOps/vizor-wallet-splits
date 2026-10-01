/// One bill: who is on it, what was spent, and what everybody owes.
library;

import 'package:flutter/material.dart';
import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'activity_screen.dart';
import 'add_expense_screen.dart';
import 'payout_screen.dart';
import 'people_screen.dart';
import 'price_bill_screen.dart';
import 'settle_screen.dart';
import 'share_bill_screen.dart';
import 'text_entry_screen.dart';
import 'splits_scope.dart';

/// The bill, derived from the entries this device holds.
///
/// Nothing here is cached across a change. The bill is a function of its
/// entries; a stored copy is a second source of truth that goes stale without
/// saying so.
class BillScreen extends StatefulWidget {
  const BillScreen({super.key, required this.billId});

  final String billId;

  @override
  State<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends State<BillScreen> {
  String get billId => widget.billId;

  /// Held rather than looked up in [dispose]: by then the element tree is
  /// being torn down and an ancestor lookup is unsafe.
  SplitsController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = SplitsScope.of(context);
    if (identical(controller, _controller)) return;
    _controller = controller;
    // Sync while the bill is open, and only while it is open: a poll running
    // behind a closed screen spends a person's battery on a bill nobody is
    // looking at.
    controller.pollBill(billId);
  }

  @override
  void dispose() {
    _controller?.stopPolling(billId);
    super.dispose();
  }

  /// Forgets the bill on this device, after saying what that costs.
  ///
  /// Nothing is written to the bill: the others keep it unchanged. What goes
  /// is this device's copy and its key, so coming back needs a fresh invite.
  Future<void> _forget(BuildContext context) async {
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove this bill from this phone?'),
        content: const Text(
          'Others keep it. You’ll need a new invite to see it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('splits_bill_forget_confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await controller.forget(billId);
    if (controller.lastError == null && navigator.mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bill')),
        body: const Center(
          child: Text('This device no longer holds this bill.'),
        ),
      );
    }

    final balances = protocol.netBalances(view.bill);
    final joined = view.bill.participants.any((p) => p.id == controller.me);

    final mine = balances[controller.me] ?? 0;
    final currency = view.bill.currency;
    final total = view.bill.expenses.fold<int>(0, (sum, e) => sum + e.amount);
    final people = view.bill.participants.length;
    String who(String id) =>
        view.bill.displayNameOf(id, creatorId: view.creatorId);

    return Scaffold(
      appBar: AppBar(
        title: Text(view.bill.name.isEmpty ? 'Bill' : view.bill.name),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ShareBillScreen(billId: billId),
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('splits_bill_menu'),
            icon: const Icon(Icons.more_horiz),
            // After the menu has closed, so a dialog is not popped with it.
            onSelected: (choice) {
              Widget? screen;
              switch (choice) {
                case 'people':
                  screen = PeopleScreen(billId: billId);
                case 'activity':
                  screen = ActivityScreen(billId: billId);
                case 'payout':
                  screen = PayoutScreen(billId: billId);
                case 'price':
                  screen = PriceBillScreen(billId: billId);
                case 'sync':
                  controller.syncBill(billId);
                case 'forget':
                  _forget(context);
              }
              if (screen != null) {
                final next = screen;
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => next));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                key: Key('splits_bill_people'),
                value: 'people',
                child: Text('People'),
              ),
              const PopupMenuItem<String>(
                key: Key('splits_bill_activity'),
                value: 'activity',
                child: Text('Activity'),
              ),
              const PopupMenuItem<String>(
                key: Key('splits_bill_payout'),
                value: 'payout',
                child: Text('How you get paid'),
              ),
              const PopupMenuItem<String>(
                key: Key('splits_bill_price'),
                value: 'price',
                child: Text('Price in ZEC'),
              ),
              PopupMenuItem<String>(
                key: const Key('splits_bill_sync_now'),
                value: 'sync',
                enabled: !controller.busy,
                child: const Text('Sync now'),
              ),
              const PopupMenuItem<String>(
                key: Key('splits_bill_forget'),
                value: 'forget',
                child: Text('Remove from this phone'),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_bill_add_expense'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AddExpenseScreen(billId: billId),
              ),
            ),
            child: const Text('Add expense'),
          ),
          SecondaryButton(
            key: const Key('splits_bill_settle'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettleScreen(billId: billId),
              ),
            ),
            child: const Text('Settle up'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Text(
            mine == 0
                ? 'All square'
                : mine > 0
                ? "You're owed ${formatAmount(mine, currency)}"
                : 'You owe ${formatAmount(-mine, currency)}',
            key: const Key('splits_bill_headline'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            '$people ${people == 1 ? 'person' : 'people'} · '
            '${formatAmount(total, currency)} total',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          _SyncNotice(state: controller.syncStateOf(billId)),
          // Until the payee says it arrived, a payment is a claim and the
          // debt stands (§10.5), so the question is put where it is seen.
          if (awaitingConfirmationBy(view.bill, controller.me).isNotEmpty)
            RowCard(
              key: const Key('splits_bill_confirm'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ActivityScreen(billId: billId),
                ),
              ),
              child: CardLine(
                title: _activitySummary(view, controller.me),
                chevron: true,
              ),
            ),
          if (controller.lastError != null)
            NoticeCard(message: controller.lastError!, error: true),
          if (!joined) _JoinPrompt(billId: billId),
          for (final replaced in view.replacedAddresses)
            NoticeCard(
              // §13: a wallet MUST show a changed pay-to address before it
              // settles to one. Buried in a list it is not shown.
              message:
                  '${who(replaced.id)} changed their address. Check with them before paying.',
              error: true,
            ),
          for (final name in view.bill.sharedNames)
            NoticeCard(
              key: Key('splits_bill_shared_name_$name'),
              // Two people answering to one name is how somebody who read the
              // invite passes for a person already on the bill.
              message:
                  'Two people are called $name. Check who’s who before paying.',
            ),
          _People(billId: billId, view: view),
          const SectionLabel('Expenses'),
          if (view.bill.expenses.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Nothing on it yet.'),
            )
          else
            for (final e in view.bill.expenses.reversed)
              _ExpenseTile(
                billId: billId,
                view: view,
                expense: e,
                // §10.4 and §10.8: an expense is corrected by whoever wrote
                // it, and withdrawn by them or the bill's creator — not by
                // whoever paid. One not theirs is shown and not offered,
                // rather than offered and refused by the fold.
                canEdit: view.expenseAuthors[e.id] == controller.me,
                canWithdraw:
                    view.expenseAuthors[e.id] == controller.me ||
                    view.creatorId == controller.me,
              ),
          if (view.bill.payments.isNotEmpty) ...[
            const SectionLabel('Payments'),
            for (final p in view.bill.payments)
              _Line(
                title: '${who(p.from)} → ${who(p.to)}',
                // §10.5: a record is a claim, not a settlement. Saying "paid"
                // here would move money on the screen that has not moved on
                // the bill.
                detail: view.bill.confirmedPayments.contains(p.id)
                    ? 'confirmed'
                    : 'sent, waiting to be confirmed',
                figure: formatAmount(p.amount, currency),
              ),
          ],
          if (view.setAside.isNotEmpty) ...[
            const SectionLabel('Not applied'),
            // Shown rather than dropped: an entry that vanished silently is
            // indistinguishable from one that was never sent.
            for (final aside in view.setAside)
              _Line(
                title: _whyNotApplied(aside.code),
                detail: '${aside.code} · entry ${BillNaming.shortId(aside.id)}',
              ),
          ],
        ],
      ),
    );
  }
}

class _JoinPrompt extends StatelessWidget {
  const _JoinPrompt({required this.billId});

  final String billId;

  /// Asks what to be called, then joins. The name reaches every device on the
  /// bill, so it is asked for rather than filled in from the wallet.
  Future<void> _join(BuildContext context) async {
    final controller = SplitsScope.read(context);
    final name = await askForText(
      context,
      title: 'Your name',
      hint: 'What others see',
      action: 'Join',
      fieldKey: const Key('splits_bill_join_name'),
      actionKey: const Key('splits_bill_join_ok'),
    );
    if (name == null || name.trim().isEmpty) return;
    await controller.join(billId, displayName: name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Expanded(child: Text('You are not on this bill yet.')),
          FilledButton(
            key: const Key('splits_bill_join'),
            onPressed: controller.busy ? null : () => _join(context),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}

/// A plain row: what, a line under it, and a figure on the right.
class _Line extends StatelessWidget {
  const _Line({required this.title, this.detail, this.figure});

  final String title;
  final String? detail;
  final String? figure;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: CardLine(
      title: title,
      subtitle: detail == null ? null : Text(detail!),
      trailing: figure,
    ),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// What the history is worth opening for, in a line.
///
/// A payment waiting on this device outranks the entry count: until it is
/// confirmed the debt is still owed (§10.5), and nothing else on the bill
/// says so.
String _activitySummary(BillView view, String me) {
  final waiting = awaitingConfirmationBy(view.bill, me).length;
  if (waiting > 0) {
    return waiting == 1
        ? 'somebody says they paid you — confirm it'
        : '$waiting people say they paid you — confirm them';
  }
  final refused = view.activity.where((e) => e.refusedCode != null).length;
  if (refused > 0) {
    return '$refused ${refused == 1 ? 'entry' : 'entries'} did not apply';
  }
  return '${view.activity.length} entries';
}

/// One expense, correctable and withdrawable by whoever wrote it.
class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({
    required this.billId,
    required this.view,
    required this.expense,
    required this.canEdit,
    required this.canWithdraw,
  });

  final String billId;
  final BillView view;
  final protocol.Expense expense;
  final bool canEdit;
  final bool canWithdraw;

  /// The entry that introduced this expense, which is what an amendment or a
  /// withdrawal names. Absent when this device holds the bill but not the
  /// entry — a state a screen must not turn into a write.
  String? get _entryId => view.expenseEntries[expense.id];

  Future<void> _withdraw(BuildContext context) async {
    final entryId = _entryId;
    if (entryId == null) return;
    final controller = SplitsScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Take this off the bill?'),
        // Honest about what it does: the entry stays in the log where every
        // device can still see it was written.
        content: const Text('It stops counting, but stays in the history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('splits_expense_withdraw_confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Take it off'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await controller.withdraw(billId: billId, entryId: entryId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entryId = _entryId;
    final tile = InkWell(
      key: Key('splits_expense_${expense.id}'),
      onTap: canEdit && entryId != null
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    AddExpenseScreen(billId: billId, editingEntryId: entryId),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: CardLine(
          title: expense.description.isEmpty ? 'Expense' : expense.description,
          subtitle: Text(
            '${view.bill.displayNameOf(expense.paidBy, creatorId: view.creatorId)}'
            ' paid',
          ),
          trailing: formatAmount(
            expense.amount,
            view.bill.currency,
            withCurrency: false,
          ),
        ),
      ),
    );
    if (!canWithdraw || entryId == null) return tile;

    return Dismissible(
      key: Key('splits_expense_dismiss_${expense.id}'),
      direction: DismissDirection.endToStart,
      // Never dismissed by the gesture alone: the confirmation decides, and
      // the list is rebuilt from the log rather than from the gesture.
      confirmDismiss: (_) async {
        await _withdraw(context);
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Theme.of(context).colorScheme.errorContainer,
        child: const Icon(Icons.delete_outline),
      ),
      child: tile,
    );
  }
}

/// A §12 code the fold sets an entry aside with, as a sentence.
///
/// The code stays beside it: it is what two people compare when their devices
/// disagree.
String _whyNotApplied(String code) => switch (code) {
  'unauthorized_entry' => 'Not allowed, or not signed',
  'participant_still_named' => 'Removes someone still on an expense',
  'participant_id_not_derived' =>
    'A join whose key does not match the person it names',
  'duplicate_expense' => 'A second expense under an id already used',
  'duplicate_payment' => 'A second payment record under an id already used',
  'unknown_participant' => 'Names somebody who is not on the bill',
  'unknown_entry' => 'Changes an entry this bill does not hold',
  // Every other code has the protocol's own sentence (§1): a bare "Not
  // applied" names no fix.
  _ => protocol.describeCode(code) ?? 'Not applied',
};

/// Where this bill's sync stands.
///
/// Said in every state, including the two that are not failures: a build with
/// no relay, and a bill that has simply not synced yet. The alternative is a
/// sync indicator that never resolves, which reads as broken.
class _SyncNotice extends StatelessWidget {
  const _SyncNotice({required this.state});

  final SplitsSyncState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, colour) = switch (state.phase) {
      // Not a failure. A bill travels by code, and saying so is the point.
      SplitsSyncPhase.noRelay => (
        'Not syncing — this bill travels by code',
        scheme.onSurfaceVariant,
      ),
      SplitsSyncPhase.idle => ('Not synced yet', scheme.onSurfaceVariant),
      SplitsSyncPhase.syncing => ('Syncing…', scheme.onSurfaceVariant),
      SplitsSyncPhase.synced => (_synced, scheme.onSurfaceVariant),
      // The bill is intact; what failed is reaching the others.
      SplitsSyncPhase.failed => (
        'Could not reach the others — ${state.detail ?? 'try again'}',
        scheme.error,
      ),
    };

    return Padding(
      key: const Key('splits_bill_sync'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text, style: TextStyle(color: colour, fontSize: 12)),
    );
  }

  String get _synced {
    // A key that is wrong looks identical to a quiet relay unless the
    // unopenable blobs are counted.
    if (state.unopenable > 0) {
      return 'Synced, but ${state.unopenable} '
          '${state.unopenable == 1 ? 'message' : 'messages'} would not open '
          '— somebody may hold a different key';
    }
    if (state.received > 0) {
      return 'Synced — ${state.received} new '
          '${state.received == 1 ? 'entry' : 'entries'}';
    }
    return 'Synced — up to date';
  }
}

/// Who is on the bill, in one sideways row, with + to add somebody and − to
/// take somebody off. Taking off is the creator's alone (§10.8). Tapping a
/// name opens the full list, with how each is paid.
class _People extends StatelessWidget {
  const _People({required this.billId, required this.view});

  final String billId;
  final BillView view;

  String _name(String id, String me) {
    final name = view.bill.displayNameOf(id, creatorId: view.creatorId);
    return id == me ? '$name (you)' : name;
  }

  Future<void> _removeSomebody(BuildContext context) async {
    final controller = SplitsScope.read(context);
    final others = [
      for (final p in view.bill.participants)
        if (p.id != controller.me) p,
    ];
    final canRemove = view.creatorId == controller.me;
    final picked = await showModalBottomSheet<protocol.Participant>(
      context: context,
      useRootNavigator: false,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text(
              canRemove ? 'Remove who?' : 'Only the bill’s creator can remove.',
              style: Theme.of(sheet).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (others.isEmpty) const Text('Nobody else is on the bill.'),
            for (final p in others)
              ListTile(
                key: Key('splits_bill_remove_${p.id}'),
                title: Text(_name(p.id, controller.me)),
                trailing: canRemove
                    ? const Icon(Icons.remove_circle_outline)
                    : null,
                enabled: canRemove,
                onTap: () => Navigator.of(sheet).pop(p),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    await confirmAndRemovePerson(context, billId: billId, participant: picked);
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: SectionLabel('People')),
            IconButton(
              key: const Key('splits_bill_add_person'),
              tooltip: 'Add someone',
              icon: const Icon(Icons.add),
              onPressed: controller.busy
                  ? null
                  : () => askAndAddPerson(context, billId: billId, view: view),
            ),
            IconButton(
              key: const Key('splits_bill_remove_person'),
              tooltip: 'Remove someone',
              icon: const Icon(Icons.remove),
              onPressed: controller.busy
                  ? null
                  : () => _removeSomebody(context),
            ),
          ],
        ),
        SingleChildScrollView(
          key: const Key('splits_bill_people_row'),
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 8,
            children: [
              for (final p in view.bill.participants)
                ActionChip(
                  key: Key('splits_bill_person_${p.id}'),
                  label: Text(_name(p.id, controller.me)),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PeopleScreen(billId: billId),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
