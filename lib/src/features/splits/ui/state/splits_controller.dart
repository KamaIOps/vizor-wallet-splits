/// The state every splits screen reads, and the one place that changes it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:splitz_core/host.dart' as splitz;
import 'package:splitz_core/splitz_core.dart' as protocol;

import 'package:splitz_host/splitz_host.dart';

import '../view/naming.dart' show formatBaseUnits;

/// The transactions this account received, each with the zatoshi it brought.
///
/// Only those that are mined: one still in the mempool may never land.
typedef ReceivedTransactions =
    Future<List<splitz.IncomingTransaction>> Function();

Future<List<splitz.IncomingTransaction>> _noneReceived() async => const [];

/// When each received transaction was mined, by transaction id.
///
/// A transaction id proves money arrived, not that it was sent for this
/// bill: a payer may name one they sent for something else (§14.7). The
/// date beside it is what lets the payee tell.
typedef ReceivedTimes = Future<Map<String, DateTime>> Function();

Future<Map<String, DateTime>> _noTimes() async => const {};

/// The text memos each of [txids] brought this account, by transaction id;
/// an id missing from the answer is one the wallet could not read (§14.7).
typedef ReceivedMemos =
    Future<Map<String, List<String>>> Function(Set<String> txids);

Future<Map<String, List<String>>> _noMemos(Set<String> txids) async => const {};

/// Every transaction id this wallet's history holds, lower-case, in the
/// byte order a send reports and a payment record carries.
typedef KnownTransactions = Future<Set<String>> Function();

Future<Set<String>> _noneKnown() async => const {};

/// Where a transaction this wallet built stands in its history.
enum HeldTransaction {
  /// In a block: it went through.
  mined,

  /// Not mined and not expired: the wallet may still broadcast it.
  waiting,

  /// Expired unmined: it can no longer go through.
  expired,
}

/// Where each transaction this wallet's history holds stands, by id in the
/// byte order a send reports.
typedef HeldTransactions = Future<Map<String, HeldTransaction>> Function();

Future<Map<String, HeldTransaction>> _noneHeld() async => const {};

/// The transactions this wallet built itself, with when it built each:
/// what a person's word that a send left nothing is checked against (§14.3).
typedef OwnTransactions = Future<List<OwnTransaction>> Function();

Future<List<OwnTransaction>> _noneOwn() async => const [];

/// Whether this wallet's ZIP 321 reader reads [address] on the network it
/// sends on (§14.6).
typedef ReadsAddress = Future<bool> Function(String address);

Future<bool> _readsAll(String _) async => true;

/// One bill as a screen needs it: the folded state, and what the fold refused.
class BillView {
  const BillView({
    required this.bill,
    required this.creatorId,
    required this.setAside,
    required this.replacedAddresses,
    required this.identities,
    required this.entryCount,
    this.activity = const [],
    this.expenseEntries = const {},
    this.rateSetBy,
    this.rateEntry,
    this.paymentEntries = const {},
    this.expenseAuthors = const {},
    this.paymentDigests = const {},
    this.paymentAuthors = const {},
  });

  final protocol.Bill bill;

  /// Who wrote each payment record on the bill, by payment id: what §14.4
  /// counts as on its way is what its payer recorded.
  final Map<String, String> paymentAuthors;

  /// Who opened it. §10.8 decides withdrawals by this, and a reader is told
  /// who the organiser is rather than shown a fragment of an id.
  final String creatorId;

  /// Entries the fold would not apply. Shown, never dropped: an entry that
  /// vanished silently is indistinguishable from one that was never sent.
  final List<protocol.SetAside> setAside;

  /// Every pay-to address that changed. §13 says a wallet MUST put one in
  /// front of a payer before settling to it.
  final List<protocol.ReplacedAddress> replacedAddresses;

  /// The [replacedAddresses] that moved money away from an address somebody
  /// had: the ones a payer is warned about. A first address, where there was
  /// none, redirects nothing; an unbound person's is flagged on the send
  /// review instead (`splits_review_unbound_`).
  List<protocol.ReplacedAddress> get redirectedAddresses => [
    for (final r in replacedAddresses)
      if (r.from != null) r,
  ];

  /// Which keys §10.7 binds, and which ids two keys each claim.
  final protocol.Identities identities;

  /// How many entries this device holds for the bill.
  final int entryCount;

  /// The entry that introduced each expense, by the expense's own id.
  ///
  /// An expense carries the id its author chose; an amendment names the
  /// **entry** it replaces (§10.4). The two are different strings, and a
  /// screen holding only the first cannot correct anything.
  ///
  /// An amended expense still maps to the entry that introduced it, because
  /// that is what every later amendment targets.
  final Map<String, String> expenseEntries;

  /// The log read as a history, newest first.
  ///
  /// Carried on the view rather than derived per screen: it is a function of
  /// the same entries the fold read, and computing it somewhere else would be
  /// a second reading of one log.
  final List<BillEvent> activity;

  /// Who wrote each expense, by the expense's own id: the author of the entry
  /// that introduced it.
  ///
  /// §10.8 decides who may correct or withdraw an expense by this, not by who
  /// paid for it — one person often enters what another paid.
  final Map<String, String> expenseAuthors;

  /// What each payment record says, by the payment's own id: the digest a
  /// confirmation of it carries (§10.5).
  final Map<String, String> paymentDigests;

  /// The entry that recorded each payment, by the payment's own id.
  ///
  /// Withdrawing a record that never landed voids its entry (§10.8), and a
  /// payment carries its own id rather than its entry's.
  final Map<String, String> paymentEntries;

  /// Who wrote the rate the bill carries, or null when it carries none.
  ///
  /// §14.2 puts this in front of a payer: a participant owed money can set
  /// the rate, and the rate decides how much ZEC a request asks for.
  final String? rateSetBy;

  /// The `setRate` entry whose rate the bill carries, or null. What the
  /// creator withdraws to take a rate off the bill (§10.8).
  final String? rateEntry;

  String get id => bill.id;
}

/// Where a bill's sync has got to.
enum SplitsSyncPhase {
  /// No relay in this build, so a bill stays on this device and travels by
  /// code. **Not a failure**, and said plainly rather than shown as a sync
  /// that never resolves.
  noRelay,

  /// Nothing has been tried yet.
  idle,
  syncing,
  synced,

  /// The last attempt did not get through. The bill is intact; what failed is
  /// reaching the others.
  failed,
}

/// What one bill's last sync did.
class SplitsSyncState {
  const SplitsSyncState({
    required this.phase,
    this.at,
    this.received = 0,
    this.unopenable = 0,
    this.detail,
  });

  final SplitsSyncPhase phase;

  /// When the last attempt finished, successful or not.
  final DateTime? at;

  /// Entries this device did not hold before. Measured, not reported by the
  /// relay: a sync returns the whole merged log rather than what it added.
  final int received;

  /// Blobs on the channel that would not open under this bill's key.
  ///
  /// A channel where every blob is unopenable is a key that is wrong, which
  /// looks identical to a quiet relay unless it is counted.
  final int unopenable;

  /// What to put in front of a person when [phase] is
  /// [SplitsSyncPhase.failed].
  final String? detail;
}

/// Drives every splits screen.
///
/// One object because the screens share one question — what does this device
/// hold, and what does it say — and two copies of that answer would disagree.
/// Nothing here caches a folded bill across a change: a bill is a function of
/// its entries, and a cached one is a second source of truth.
class SplitsController extends ChangeNotifier {
  SplitsController({
    required SplitsWallet wallet,
    required BillStore store,
    required SplitsKeys keys,
    SplitsRelay relay = const UnconfiguredSplitsRelay(),
    ZecPrices prices = const NoZecPrices(),
    SwapProvider swaps = const UnconfiguredSwaps(),
    SplitsSigner? signer,
    ReceivedTransactions received = _noneReceived,
    ReceivedTimes receivedTimes = _noTimes,
    ReceivedMemos receivedMemos = _noMemos,
    KnownTransactions known = _noneKnown,
    HeldTransactions held = _noneHeld,
    OwnTransactions own = _noneOwn,
    ReadsAddress readsAddress = _readsAll,
  }) : _wallet = wallet,
       _own = own,
       _readsAddress = readsAddress,
       _received = received,
       _receivedTimes = receivedTimes,
       _receivedMemos = receivedMemos,
       _known = known,
       _held = held,
       _store = store,
       _keys = keys,
       _relay = relay,
       _prices = prices,
       _swaps = swaps,
       _signer = signer ?? SplitsSigner() {
    _sync = SplitsSync(store: _store, keys: _keys, relay: _relay);
  }

  final SplitsWallet _wallet;
  final ReceivedTransactions _received;
  final ReceivedTimes _receivedTimes;
  final ReceivedMemos _receivedMemos;
  Map<String, DateTime> _times = const {};
  final KnownTransactions _known;
  final HeldTransactions _held;
  final OwnTransactions _own;
  final ReadsAddress _readsAddress;
  final BillStore _store;
  final SplitsKeys _keys;
  final SplitsRelay _relay;
  final ZecPrices _prices;
  final SwapProvider _swaps;
  late final SwapWatchList _watches = SwapWatchList(_store.storage);
  late final PendingSends _sends = PendingSends(_store.storage);

  /// Bills a send is being made from right now. Checked and set before the
  /// first await, so two taps cannot both pass the check for a stored intent
  /// before either has written one.
  final Set<String> _sending = {};

  /// Marks a bill part-way through being forgotten. Written before the key
  /// goes and deleted after the entries do, so a process killed in between
  /// finishes the job on the next [load] rather than leaving a bill listed
  /// with no key to read it.
  static const String _forgetting = 'forgetting/';
  final SplitsSigner _signer;
  late final SplitsSync _sync;

  List<BillView> _bills = const [];
  List<splitz.Arrival> _arrived = const [];
  List<splitz.Arrival> _disputed = const [];
  List<splitz.Arrival> _underpriced = const [];
  List<splitz.Arrival> _unbound = const [];
  List<int>? _identitySeed;
  String? _identityKey;

  /// The participant id [_identityKey] derives (§10.7), once it is loaded.
  String? _participant;
  String? _lastError;

  /// Actions in flight. A count, not a flag: two that overlap would otherwise
  /// report the device idle when the first of them finishes.
  int _running = 0;

  /// Every bill this device holds, newest first.
  List<BillView> get bills => _bills;

  /// [billId] folded from what the store holds now, published first.
  ///
  /// [bills] can trail the store while a merge waits to be published; a
  /// screen that shows a figure next to one priced from the store reads the
  /// view here, or the two can disagree. The published view when the store
  /// cannot be read.
  Future<BillView?> currentView(String billId) async {
    try {
      await _refresh();
    } on Object {
      // What is published is still the best there is to show.
    }
    return _bills.where((b) => b.id == billId).firstOrNull;
  }

  /// Payments to this device whose transaction the wallet has received, with
  /// at least the ZEC each states, across every bill (§14.7). Each is shown
  /// to the person before [confirmArrivals] writes anything (§14.2).
  List<splitz.Arrival> get arrived => _arrived;

  /// Whether this wallet's history holds [txid], compared as §14.7 compares
  /// it; null when the history cannot be read.
  Future<bool?> hasReceived(String txid) async {
    try {
      final key = splitz.txidKey(txid);
      return (await _received()).any((t) => splitz.txidKey(t.txid) == key);
    } on Object {
      return null;
    }
  }

  /// Payments to this device naming a transaction that another payer's
  /// record also names (§14.7). None is proposed: which of them the money
  /// came from is for the person to settle before confirming any by hand.
  List<splitz.Arrival> get disputed => _disputed;

  /// Payments to this device whose ZEC arrived but, at the bill's price, is
  /// worth under 95% of what they settle, or whose bill has no price to say
  /// (§14.7). Never in a one-tap confirmation: each is confirmed by hand,
  /// after the person has read what it is short of.
  List<splitz.Arrival> get underpriced => _underpriced;

  /// Payments to this device whose transaction's memo names another bill,
  /// or none (§14.7). Never in a one-tap confirmation: the money arrived, and
  /// nothing says it was sent for this bill.
  List<splitz.Arrival> get unbound => _unbound;

  /// Where this device stands with each person, per currency, across every
  /// bill it holds.
  splitz.Totals get totals => splitz.totalsAcross(_folded, me);

  /// [totals] over [billId] alone: where this device stands with each
  /// person on that one bill, with what it has sent and not had confirmed.
  splitz.Totals totalsOn(String billId) => splitz.totalsAcross([
    for (final f in _folded)
      if (f.bill.id == billId) f,
  ], me);

  /// What this device has recorded sending on [billId] that its payees have
  /// not confirmed, in the bill's minor units; null when the sum passes what
  /// an amount can hold.
  ///
  /// Still owed (§10.5) and already on its way: §14.4 reports the two as
  /// separate quantities.
  int? sentOn(String billId) {
    var sent = 0;
    try {
      for (final s in totalsOn(billId).standings) {
        sent = protocol.checkedAdd(sent, s.sentAwaiting);
      }
    } on protocol.SplitError {
      return null;
    }
    return sent;
  }

  /// The bills as the host layer folds them, from what each view holds.
  List<splitz.FoldedBill> get _folded => [
    for (final v in _bills)
      splitz.FoldedBill(
        bill: v.bill,
        setAside: v.setAside,
        withdrawn: const [],
        replacedAddresses: v.replacedAddresses,
        identities: v.identities,
        paymentDigests: v.paymentDigests,
        paymentAuthors: v.paymentAuthors,
      ),
  ];

  /// What the last action could not do, or null. Cleared by the next one.
  ///
  /// The last action of any screen, or of none: a screen shows what
  /// [failureOf] returns for its own actions, and [loadError] is what the
  /// bills list shows.
  String? get lastError => _lastError;

  /// What the last [load] could not do, or null.
  String? get loadError => _loadError;
  String? _loadError;

  /// Runs [action] and returns what the actions it started could not do, or
  /// null when they did all of it.
  ///
  /// As [lastError] would read after [action], counting only the actions
  /// [action] itself starts: one running alongside it, from another screen
  /// or in the background, neither sets nor clears the answer.
  Future<String?> failureOf(Future<void> Function() action) async {
    final outcome = _Outcome();
    await runZoned(action, zoneValues: {_Outcome: outcome});
    return outcome.failure;
  }

  /// Records [failure] as the outcome of the action now running: on
  /// [lastError], and on the [failureOf] that started it.
  void _report(String? failure) {
    _lastError = failure;
    if (Zone.current[_Outcome] case final _Outcome outcome) {
      outcome.failure = failure;
    }
  }

  /// Whether an action is in flight. A screen shows it rather than letting a
  /// second tap start the same work twice.
  bool get busy => _running > 0;

  /// This account's public signing key, once [load] has run.
  String? get identityKey => _identityKey;

  /// Whether this account's identity would survive a restore from its
  /// mnemonic. False when it was drawn at random for want of a secret.
  bool get identityIsRecoverable =>
      SplitsKeys.identityIsRecoverable(_wallet.account);

  /// The participant id this device speaks as: the one its identity key
  /// derives (§10.7), or the account's own id before an identity is loaded.
  ///
  /// A join written under any other id with this device's key is set aside
  /// with `participant_id_not_derived`, so every entry is written as this.
  String get me => _participant ?? _wallet.account.id;

  /// This device's clock.
  DateTime now() => _wallet.now();

  /// Loads this account's identity and every bill on the device.
  Future<void> load() async {
    _loadError = await failureOf(
      () => _guard(() async {
        _identitySeed = await _keys.ensureIdentitySeed(_wallet.account);
        _identityKey = await _signer.publicKeyFromSeed(_identitySeed!);
        _participant = protocol.participantId(_identityKey!);
        // Once, at the start: a write interrupted by the app being killed leaves
        // a temporary beside its target, already invisible to a listing, and
        // this is what stops them accumulating.
        await _store.sweepUnfinishedWrites();
        await _moveLegacySendNotes();
        await _finishForgets();
        await _refresh();
      }),
    );
    // Also the outcome of whatever action this load is part of.
    _report(_loadError);
    notifyListeners();
    // Not awaited: a slow feed must not hold the bills back.
    unawaited(_priceAsCreator(_bills.map((b) => b.id)));
  }

  final Set<String> _creatorPriceTried = {};

  /// Writes the creator's rate on each of [billIds] this device created and
  /// has not priced, from the wallet's feed, once per bill per session.
  ///
  /// The creator's latest rate decides (§7); while there is none, the latest
  /// by anybody does, and `at` is whatever its author wrote, so one dated far
  /// ahead outranks every correction after it. A creator's rate closes that.
  /// With no live figure the bill stays as it is, and is tried again on the
  /// next start.
  Future<void> _priceAsCreator(Iterable<String> billIds) async {
    for (final id in billIds.toList()) {
      final view = _bills.where((b) => b.id == id).firstOrNull;
      if (view == null || view.creatorId != me) continue;
      if (view.rateSetBy == view.creatorId) continue;
      if (!_creatorPriceTried.add(id)) continue;
      int? live;
      try {
        live = await quoteZec(view.bill.currency);
      } on Object catch (error) {
        debugPrint('splits: no feed price to set on $id: $error');
      }
      if (live == null || live <= 0) continue;
      // Asked before the answer came: the organiser may have priced the bill
      // by hand meanwhile, and a feed answer written now would order after
      // that price (§10.2) and replace it.
      final now = _bills.where((b) => b.id == id).firstOrNull;
      if (now == null || now.rateSetBy == now.creatorId) continue;
      await setRate(
        billId: id,
        currency: view.bill.currency,
        minorUnitsPerZec: live,
        source: 'feed',
      );
    }
  }

  /// Moves the send notes an earlier version of this screen kept under
  /// `payintent/` to where [PendingSends] reads them.
  ///
  /// The two write the same fields, and a bill id is base64url so its key is
  /// the same either way: this is a rename. It is moved byte for byte, a
  /// damaged note included, because a note that does not read still blocks —
  /// dropping one would let the send it stands for go out again.
  Future<void> _moveLegacySendNotes() async {
    const legacy = 'payintent/';
    const surfaced = 'payintent-surfaced/';
    final storage = _store.storage;
    for (final key in await storage.keys(legacy)) {
      final billId = key.substring(legacy.length);
      final note = 'pendingsend/${Uri.encodeComponent(billId)}';
      final String? raw;
      try {
        raw = await storage.read(key);
      } on BillStorageUnreadable {
        // Left where it is, so a later load that can read it still moves the
        // details across. Until then a damaged note blocks in its place —
        // written once, so a person who resolves it is not blocked again by
        // the same unreadable file on every start.
        if (await storage.read('$surfaced$billId') == null) {
          await storage.write(note, '');
          await storage.write('$surfaced$billId', '1');
        }
        continue;
      }
      if (raw == null) continue;
      await storage.write(note, raw);
      await storage.delete(key);
      await storage.delete('$surfaced$billId');
    }
  }

  /// Opens a bill, joining it as this account in the same breath.
  ///
  /// The creator is bound by the invite rather than by a join: §9.4 makes the
  /// bill's id the digest of the entry that states the creator's key, so it
  /// needs no prior acquaintance. The join that follows is what carries a
  /// display name and a payout address.
  Future<String?> createBill({
    required String name,
    required String currency,
    String? displayName,
  }) async {
    String? billId;
    await _guard(() async {
      final seed = await _requireIdentity();
      final key = await _signer.publicKeyFromSeed(seed);
      final host = _host(seed);

      // The bill's key first: the create commits to it (§9.4), so a joiner
      // refuses an invite carrying any other.
      final billKey = _keys.generateKey();
      final unsigned = splitz.createBill(
        host: host,
        name: name,
        currency: currency,
        creatorKey: key,
        billKey: billKey,
      );
      billId = unsigned['id'] as String;
      // A create is signed on its own id: it is the bill (§10.6).
      final create = await splitz.signEntry(
        host: host,
        entry: unsigned,
        billId: billId!,
      );
      await _keys.storeBillKey(billId!, billKey);

      final join = await splitz.signEntry(
        host: host,
        entry: splitz.joinBill(
          host: host,
          name: _named(displayName),
          payTo: _wallet.sender.payToAddress,
          identityKey: key,
        ),
        billId: billId!,
      );
      await _store.merge(billId!, [create, join]);
      await _refresh();
    });
    // Not awaited: a slow feed must not hold the new bill back.
    if (billId != null) unawaited(_priceAsCreator([billId!]));
    return billId;
  }

  /// Joins a bill this device already holds entries for.
  Future<void> join(String billId, {String? displayName}) async {
    await _guard(() async {
      final seed = await _requireIdentity();
      final host = _host(seed);
      final join = await splitz.signEntry(
        host: host,
        entry: splitz.joinBill(
          host: host,
          name: _named(displayName),
          payTo: _wallet.sender.payToAddress,
          identityKey: await _signer.publicKeyFromSeed(seed),
        ),
        billId: billId,
      );
      if (!await _mergeWhileHeld(billId, [join])) throw _removed;
      await _refresh();
    });
  }

  /// Adds an expense somebody covered.
  ///
  /// [amountMinorUnits] is minor units of the bill's currency (§2.1), and
  /// [among] is who shares it. Nothing here invents a split method the
  /// specification does not define.
  /// [split] is §4's own shape and is passed through untouched; nothing here
  /// invents a split method the specification does not define. Leaving it out
  /// splits [amountMinorUnits] equally across [among].
  Future<void> addExpense({
    required String billId,
    required String paidBy,
    required int amountMinorUnits,
    List<String> among = const [],
    Map<String, dynamic>? split,
    String? description,
  }) async {
    await _guard(() async {
      // Written by somebody who is not on the bill, the fold sets it aside
      // (§10.1): said before anything is written, in words that name the fix.
      final view = _bills.where((b) => b.id == billId).firstOrNull;
      if (view != null && view.bill.participant(me) == null) {
        throw const SplitsRefusal('Join this bill before adding to it.');
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.addExpense(
          host: host,
          expenseId: _expenseId(),
          paidBy: paidBy,
          amount: amountMinorUnits,
          split: split ?? <String, dynamic>{'type': 'equal', 'among': among},
          description: description,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Snapshots a price onto the bill, which is what makes it settleable.
  ///
  /// A bill with no rate is an ordinary bill and not an error — there is no
  /// §12 code for unpriced. The organiser's device prices its own bills from
  /// the feed ([_priceAsCreator]); a payer's device prices one only on the
  /// settle screen, beside the send.
  Future<void> setRate({
    required String billId,
    required String currency,
    required int minorUnitsPerZec,
    String? source,
  }) async {
    await _guard(() async {
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.setRate(
          host: host,
          currency: currency,
          minorUnitsPerZec: minorUnitsPerZec,
          source: source,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Corrects an expense this device wrote (§10.4).
  ///
  /// **An amendment replaces its target wholesale**, so the payload is built
  /// from the entry as it stands and then changed — anything left out is
  /// deleted rather than kept. Only the author may amend, and the fold sets
  /// aside anybody else's attempt with `unauthorized_entry`.
  Future<void> editExpense({
    required String billId,
    required String entryId,
    String? paidBy,
    int? amountMinorUnits,
    Map<String, dynamic>? split,
    String? description,
  }) async {
    await _guard(() async {
      final held = await _store.read(billId);
      final target = held.where((e) => e['id'] == entryId).firstOrNull;
      if (target == null || target['kind'] != 'addExpense') {
        throw protocol.SplitError(
          protocol.SplitCode.unknownEntry,
          'This device does not hold the expense being corrected',
        );
      }
      final current = Map<String, dynamic>.from(
        target['expense'] as Map<String, dynamic>,
      );
      if (paidBy != null) current['paidBy'] = paidBy;
      if (amountMinorUnits != null) current['amount'] = amountMinorUnits;
      if (split != null) current['split'] = split;
      if (description != null) current['description'] = description;

      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.amendEntry(
          host: host,
          targetId: entryId,
          member: protocol.payloadForKind['addExpense']!,
          payload: current,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// What taking [id] off [billId] needs, read from the store as it stands
  /// (see [planRemoval]); null when this device holds no such bill.
  Future<RemovalPlan?> removalPlan(String billId, String id) async {
    final log = await _store.read(billId);
    if (log.isEmpty) return null;
    return _removalPlanOver(billId, log, id);
  }

  Future<RemovalPlan> _removalPlanOver(
    String billId,
    List<Map<String, dynamic>> log,
    String id,
  ) async {
    final seed = _identitySeed;
    final folded = seed == null
        ? foldUnverified(_wallet, log, billId: billId)
        : await foldVerified(
            _wallet,
            log,
            billId: billId,
            signer: _signer,
            seed: seed,
          );
    return planRemoval(
      folded: folded,
      creatorId: _creatorOf(log),
      log: log,
      id: id,
      me: me,
    );
  }

  /// Writes each expense in [confirmed] again without [without], withdrawing
  /// the one it replaces (§10.8).
  ///
  /// A withdrawal and a new expense rather than an amendment: §10.8 counts a
  /// person as named while either an amendment or the entry it corrects names
  /// them, so only this lets somebody come off the bill afterwards. The new
  /// expense is this device's, so its author can no longer correct it
  /// (§10.4); an amendment cannot be written for them, and an expense written
  /// under their id is one they never signed.
  ///
  /// [confirmed] is the plan the person agreed to. It is planned again from
  /// the store before anything is signed, and once more inside the store's
  /// turn for this bill, where nothing else writes it; when either reading
  /// differs — an amendment synced in, the same removal already written —
  /// nothing is written and they are told. Every pair goes in one write, so
  /// the bill never holds an expense twice or loses one between them.
  Future<void> restateExpenses({
    required String billId,
    required String without,
    required RemovalPlan confirmed,
  }) async {
    await _guard(() async {
      const changed = SplitsRefusal(
        'The bill changed since you looked. Check who is on what, then try '
        'again.',
      );
      final held = await _store.read(billId);
      final plan = await _removalPlanOver(billId, held, without);
      if (!plan.sameAs(confirmed)) throw changed;
      final seed = await _requireIdentity();
      final host = _host(seed);
      final written = <Map<String, dynamic>>[];
      for (final edit in plan.edits) {
        final expense = edit.seen;
        written
          ..add(
            await splitz.signEntry(
              host: host,
              entry: splitz.addExpense(
                host: host,
                expenseId: _expenseId(),
                paidBy: expense.paidBy,
                amount: expense.amount,
                split: edit.split,
                description: expense.description.isEmpty
                    ? null
                    : expense.description,
              ),
              billId: billId,
            ),
          )
          ..add(
            await splitz.signEntry(
              host: host,
              entry: splitz.voidEntry(host: host, targetId: edit.entryId),
              billId: billId,
            ),
          );
      }
      // Folded first, and written only when every entry applies: a new
      // expense whose withdrawal was refused would count it twice.
      final trial = await foldVerified(
        _wallet,
        [...held, ...written],
        billId: billId,
        signer: _signer,
        seed: seed,
      );
      final refused = trial.setAside
          .where((a) => written.any((w) => w['id'] == a.id))
          .firstOrNull;
      if (refused != null) {
        throw SplitsRefusal(
          protocol.describeCode(refused.code) ??
              'Not applied: ${refused.code}.',
        );
      }
      var stale = false;
      final applied = await _mergeWhileHeld(
        billId,
        written,
        andIf: () async {
          final now = await _removalPlanOver(
            billId,
            await _store.read(billId),
            without,
          );
          stale = !now.sameAs(confirmed);
          return !stale;
        },
      );
      if (stale) throw changed;
      if (!applied) throw _removed;
      await _refresh();
    });
  }

  /// Withdraws an entry (§10.8).
  ///
  /// It stays in the log and comes off the bill: removing it outright would
  /// leave a reader unable to see it was ever written, and two devices
  /// disagreeing about whether it existed.
  ///
  /// Refused for this device's own shielded payment whose transaction this
  /// wallet's history shows mined or still sending: withdrawn, the debt is
  /// offered again while the first payment has reached, or may yet reach,
  /// the payee.
  Future<void> withdraw({
    required String billId,
    required String entryId,
  }) async {
    await _guard(() async {
      final folded = await _storedFold(billId);
      for (final p in folded.bill.payments) {
        final reference = p.reference;
        if (folded.paymentEntries[p.id] != entryId || reference == null) {
          continue;
        }
        // §14.4: the rule is the host's; this wallet supplies where its own
        // history shows the transaction.
        final refusal = ownPaymentWithdrawalRefusal(
          p,
          me: me,
          state: switch (await _heldState(reference)) {
            HeldTransaction.mined => TransactionState.mined,
            HeldTransaction.waiting => TransactionState.waiting,
            HeldTransaction.expired => TransactionState.expired,
            null => null,
          },
        );
        switch (refusal) {
          case OwnPaymentWithdrawal.mined:
            throw const SplitsRefusal(
              'Your wallet shows this payment went through. Ask them to '
              'check their wallet rather than paying again.',
            );
          case OwnPaymentWithdrawal.waiting:
            throw const SplitsRefusal(
              'Your wallet still holds this transaction and may send it. '
              'Wait until it goes through or expires.',
            );
          case null:
            break;
        }
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.voidEntry(host: host, targetId: entryId),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Puts somebody on the bill who is not here to join it themselves.
  ///
  /// The entry is written by **this** device, so §10.7 binds it to this key
  /// and not to theirs: what it creates is a name to split an expense
  /// against, not a claim about who they are. They bind their own identity by
  /// joining from their own device, with their own key.
  ///
  /// [id] is theirs on this bill and must not already be taken.
  Future<void> addPerson({
    required String billId,
    required String id,
    required String name,
  }) async {
    await _guard(() async {
      final view = bills.where((b) => b.id == billId).firstOrNull;
      if (view != null && view.bill.participant(id) != null) {
        throw protocol.SplitError(
          protocol.SplitCode.duplicateParticipant,
          'Somebody on this bill already goes by that',
        );
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      // Written as them, because `joinBill` takes the participant id from
      // the host. **Deliberately unsigned**: this device holds no key of
      // theirs, and signing an entry authored by them with this device's key
      // would assert something false. §10.7 binds nothing here, which is the
      // honest state — they bind their own identity by joining from their
      // own device with their own key.
      final entry = splitz.joinBill(host: _HostAs(host, id), name: name);
      await _mergeChecked(billId, entry);
    });
  }

  /// Sets where [id] is paid in ZEC, for somebody who has not joined from a
  /// device of their own.
  ///
  /// Written as them and unsigned, as [addPerson] writes them: their record
  /// is one anyone on the bill can write until §10.7 binds a key to it, and a
  /// payer is told so before sending. Once they have joined themselves, the
  /// address is theirs to set and this refuses.
  ///
  /// The address becomes their first payout, in place of any Zcash one they
  /// had; every other way they are paid stays after it, in their order.
  Future<void> setAddressFor({
    required String billId,
    required String id,
    required String address,
  }) async {
    await _guard(() async {
      final view = bills.where((b) => b.id == billId).firstOrNull;
      final who = view?.bill.participant(id);
      if (view == null || who == null) {
        throw const SplitsRefusal('That person is not on this bill.');
      }
      if (view.identities.bound.containsKey(id)) {
        throw SplitsRefusal('${who.name} sets their own address.');
      }
      final trimmed = address.trim();
      if (trimmed.isEmpty) {
        throw const SplitsRefusal('Nobody can be paid without an address.');
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final rest = rankedPayouts(
        who,
        splitz.Payout(type: 'zec', address: trimmed),
      ).skip(1).toList();
      final entry = splitz.joinBill(
        host: _HostAs(host, id),
        name: who.name,
        payTo: trimmed,
        // An address alone is written as one, as it always was.
        payouts: rest.isEmpty
            ? null
            : [
                _payoutJson(splitz.Payout(type: 'zec', address: trimmed)),
                for (final p in rest) _payoutJson(p),
              ],
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Asks for [id]'s debts to be paid by [payout] — USDC swapped from ZEC, or
  /// cash (§9.1) — for somebody added by name.
  ///
  /// Written as [setAddressFor] writes an address: their record, rewritten
  /// with [payout] as the first way to pay them, in place of one of its kind.
  /// Every other way they are paid, a Zcash address among them, stays after
  /// it in their order, so a payer who cannot reach that way may still pay
  /// another (§14.8). Refused for somebody bound to a key, who says this
  /// themselves.
  Future<void> setPayoutFor({
    required String billId,
    required String id,
    required splitz.Payout payout,
  }) async {
    await _guard(() async {
      final view = bills.where((b) => b.id == billId).firstOrNull;
      final who = view?.bill.participant(id);
      if (view == null || who == null) {
        throw const SplitsRefusal('That person is not on this bill.');
      }
      if (view.identities.bound.containsKey(id)) {
        throw SplitsRefusal('${who.name} sets how they get paid.');
      }
      if (payout.type == 'swap' && (payout.address ?? '').trim().isEmpty) {
        throw const SplitsRefusal('Nobody can be paid without an address.');
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = splitz.joinBill(
        host: _HostAs(host, id),
        name: who.name,
        payTo: who.payTo,
        payouts: [for (final p in rankedPayouts(who, payout)) _payoutJson(p)],
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Takes somebody off the bill (§10.8).
  ///
  /// Refused with `participant_still_named` while any surviving entry names
  /// them — an expense they paid, a split they are in, a payment either way.
  /// **That refusal is the feature**: the fold cannot apply an entry naming
  /// somebody who is not on the bill, so removing the person who spent the
  /// most would otherwise drop every expense they paid for and zero the bill.
  ///
  /// Withdrawing their expenses first and then removing them is permitted,
  /// and is two visible acts rather than one silent one.
  Future<void> removePerson({
    required String billId,
    required String id,
  }) async {
    await _guard(() async {
      final held = await _store.read(billId);
      final joins = protocol
          .orderEntries(held)
          .where(
            (e) =>
                e['kind'] == 'joinBill' &&
                (e['participant'] as Map<String, dynamic>?)?['id'] == id,
          )
          .toList();
      if (joins.isEmpty) {
        throw protocol.SplitError(
          protocol.SplitCode.unknownParticipant,
          'Nobody by that name is on this bill',
        );
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      // Every join they wrote, not only the first: one left standing puts
      // them back on the bill.
      final voids = <Map<String, dynamic>>[];
      for (final join in joins) {
        voids.add(
          await splitz.signEntry(
            host: host,
            entry: splitz.voidEntry(host: host, targetId: join['id'] as String),
            billId: billId,
          ),
        );
      }
      // Folded first, and written only when they come off. A withdrawal the
      // fold sets aside stays in the log, and applies unannounced on the day
      // nothing names them any more.
      final trial = await foldVerified(
        _wallet,
        [...held, ...voids],
        billId: billId,
        signer: _signer,
        seed: seed,
      );
      if (trial.bill.participant(id) != null) {
        final refused = trial.setAside
            .where((a) => voids.any((v) => v['id'] == a.id))
            .map((a) => a.code)
            .toSet();
        throw SplitsRefusal(
          refused.contains(protocol.SplitCode.participantStillNamed)
              ? 'They’re on an expense. Remove that first.'
              : 'Only the bill’s creator can remove them.',
        );
      }
      if (!await _mergeWhileHeld(billId, voids)) throw _removed;
      await _refresh();
    });
  }

  /// Declares how this device wants to be paid (§9.1).
  ///
  /// The order IS the preference order and is written as given: a reader that
  /// reordered it would settle to an address ranked lower. The first entry
  /// decides which lane §8.5 puts this participant in — a Zcash address goes
  /// into the payment request, a swap or cash is reported instead.
  ///
  /// Writing a join again is how a participant amends their own record; §10.7
  /// binds it to this device's key, so nobody else can redirect the payout.
  /// This wallet's own Zcash address, which it is paid to by default, or null
  /// when it has none to give.
  String? get payToAddress => _wallet.sender.payToAddress;

  Future<void> setPayouts({
    required String billId,
    required List<splitz.Payout> payouts,
    String? displayName,
  }) async {
    await _guard(() async {
      // A payout saved by somebody not yet on the bill would join them with
      // no name, and every device would show an id where the person was. One
      // already on it keeps the record they have.
      final name = _named(displayName) ?? _nameOnBill(billId);
      final view = _bills.where((b) => b.id == billId).firstOrNull;
      if (name == null && view?.bill.participant(me) == null) {
        throw const SplitsRefusal('Join this bill with a name first.');
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.joinBill(
          host: host,
          // A join replaces this participant's record wholesale, so the name
          // already on the bill is written again rather than dropped.
          name: name,
          payTo: _wallet.sender.payToAddress,
          identityKey: await _signer.publicKeyFromSeed(seed),
          payouts: [for (final p in payouts) _payoutJson(p)],
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// [displayName] trimmed, or null when it says nothing.
  ///
  /// Never the account id in its place: that is the wallet's own handle, and
  /// written as a name it reaches every device on the bill.
  static String? _named(String? displayName) {
    final name = displayName?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// The name this device goes by on [billId], or null when it has none.
  String? _nameOnBill(String billId) {
    final view = _bills.where((b) => b.id == billId).firstOrNull;
    final name = view?.bill.participant(me)?.name;
    return name == null || name.isEmpty ? null : name;
  }

  static Map<String, dynamic> _payoutJson(splitz.Payout p) => <String, dynamic>{
    'type': p.type,
    if (p.address != null) 'address': p.address,
    if (p.asset != null) 'asset': p.asset,
    if (p.chain != null) 'chain': p.chain,
  };

  /// Records a debt settled in cash (§9.2).
  ///
  /// Nothing is sent and nothing is verified: cash moved outside this
  /// protocol, and the only evidence it ever has is the recipient's
  /// confirmation (§10.5). **A screen must not present this with the
  /// confidence of an on-chain payment** — anyone on the bill can write one.
  Future<void> recordCash({
    required String billId,
    required String to,
    required int amountMinorUnits,
    String? note,
  }) async {
    await _guard(() async {
      // §14.8: nothing changes how a debt is paid while a send from its bill
      // may still land, or the one debt is recorded paid twice.
      await _refuseWhileSending(billId);
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.recordPayment(
          host: host,
          // No transaction exists to take an id from, so one is minted. It
          // must be unique on the bill: two cash payments sharing an id are
          // one payment to every reader that folds the log.
          paymentId: _cashId(),
          to: to,
          amount: amountMinorUnits,
          method: 'cash',
          note: note,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Records a debt settled by a swap off this chain (§9.2).
  ///
  /// [reference] is the provider's own identifier for the swap — **not a
  /// Zcash txid**, and a screen that renders it as one is wrong for every
  /// swap. [zatoshi] is what left this wallet, which is the only half the
  /// bill can see.
  ///
  /// **Not a confirmation.** That the deposit was sent is not that the
  /// recipient was paid, and only they can say the latter (§10.5).
  Future<void> recordSwap({
    required String billId,
    required String reference,
    required String to,
    required int amountMinorUnits,
    int? zatoshi,
    String? note,
  }) async {
    await _guard(() async {
      // §14.8: nothing changes how a debt is paid while a send from its bill
      // may still land, or the one debt is recorded paid twice.
      await _refuseWhileSending(billId);
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.recordPayment(
          host: host,
          // The swap's own identifier is what a reader checks the record
          // against, so it is the payment id as well as the reference.
          paymentId: reference,
          to: to,
          amount: amountMinorUnits,
          method: 'swap',
          reference: reference,
          zatoshi: zatoshi,
          note: note,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Says a payment arrived (§10.5).
  ///
  /// A payment record is a claim; this is what settles the debt. Only the
  /// payee can write it, and §10.5 decides which methods it may name.
  Future<void> confirmPayment({
    required String billId,
    required String paymentId,
    required String method,
    String? reference,
  }) async {
    await _guard(() async {
      // §10.5: a confirmation binds the record as it stands now.
      final record = _bills
          .where((b) => b.id == billId)
          .firstOrNull
          ?.paymentDigests[paymentId];
      if (record == null) {
        throw const SplitsRefusal('Payment not found. Sync and try again.');
      }
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.confirmPayment(
          host: host,
          paymentId: paymentId,
          method: method,
          reference: reference,
          record: record,
        ),
        billId: billId,
      );
      await _mergeChecked(billId, entry);
    });
  }

  /// Confirms [arrivals] as `walletReceived` (§10.5), each against the
  /// transaction it names and the record as it stood when it was found.
  ///
  /// Only after the person has seen them (§14.2): what each says was sent,
  /// the rate it was priced at, and the transaction.
  Future<void> confirmArrivals(List<splitz.Arrival> arrivals) async {
    await _guard(() async {
      final seed = await _requireIdentity();
      final host = _host(seed);
      final byBill = <String, List<Map<String, dynamic>>>{};
      for (final a in arrivals) {
        final entry = await splitz.signEntry(
          host: host,
          entry: splitz.confirmPayment(
            host: host,
            paymentId: a.payment.id,
            method: 'walletReceived',
            reference: a.txid,
            record: a.record,
          ),
          billId: a.billId,
        );
        byBill.putIfAbsent(a.billId, () => []).add(entry);
      }
      // A bill forgotten meanwhile has nothing left to confirm.
      for (final e in byBill.entries) {
        await _mergeWhileHeld(e.key, e.value);
      }
      await _refresh();
    });
  }

  /// Reads what the wallet received and matches it to the bills.
  ///
  /// A history that cannot be read proposes nothing: every payment stays one
  /// the person confirms by hand, which is how it was before.
  ///
  /// Kept only while no newer refresh has started: the history read is
  /// awaited, and one computed against older bills would re-offer a payment
  /// that has since been confirmed.
  Future<void> _findArrivals() async {
    final generation = _refreshes;
    final folded = _folded;
    splitz.Arrivals found;
    try {
      found = splitz.arrivalsFor(folded, me, await _withMemos(folded));
    } on Object catch (error) {
      debugPrint('splits: received transactions did not read: $error');
      found = const splitz.Arrivals(arrived: [], short: [], unstated: []);
    }
    if (generation != _refreshes) return;
    _arrived = found.arrived;
    _disputed = found.disputed;
    _underpriced = found.underpriced;
    _unbound = found.unbound;
    try {
      final times = await _receivedTimes();
      if (generation != _refreshes) return;
      _times = {for (final e in times.entries) splitz.txidKey(e.key): e.value};
    } on Object catch (error) {
      debugPrint('splits: when transactions arrived did not read: $error');
    }
  }

  /// What the wallet received, each transaction a payment record to this
  /// device names carrying the memos it brought (§14.7). Only those: reading
  /// a memo is a read per transaction.
  Future<List<splitz.IncomingTransaction>> _withMemos(
    List<splitz.FoldedBill> folded,
  ) async {
    final received = await _received();
    final named = <String>{
      for (final f in folded)
        for (final p in f.bill.payments)
          if (p.to == me &&
              p.method == 'shieldedZec' &&
              p.reference != null &&
              !f.bill.confirmedPayments.contains(p.id))
            splitz.txidKey(p.reference!),
    };
    final asked = {
      for (final t in received)
        if (named.contains(splitz.txidKey(t.txid))) t.txid,
    };
    Map<String, List<String>> read = const {};
    if (asked.isNotEmpty) {
      try {
        read = {
          for (final e in (await _receivedMemos(asked)).entries)
            splitz.txidKey(e.key): e.value,
        };
      } on Object catch (error) {
        debugPrint('splits: memos did not read: $error');
      }
    }
    return [
      for (final t in received)
        splitz.IncomingTransaction(
          t.txid,
          t.zatoshi,
          memos: read[splitz.txidKey(t.txid)],
        ),
    ];
  }

  /// When the wallet's history says [txid] was mined, or null when it does
  /// not say.
  DateTime? receivedAt(String txid) => _times[splitz.txidKey(txid)];

  /// Merges entries that arrived from a scan or a relay.
  ///
  /// Written only while this device holds the bill's key, as every other
  /// write is: a bill forgotten between taking its key and merging would
  /// otherwise be stored without one.
  Future<void> accept(String billId, List<Map<String, dynamic>> entries) async {
    await _guard(() async {
      if (!await _mergeWhileHeld(billId, entries)) throw _removed;
      await _refresh();
    });
  }

  final Map<String, SplitsSyncState> _syncStates = {};

  /// Whether this build has anywhere to sync to.
  bool get hasRelay => _relay is! UnconfiguredSplitsRelay;

  /// Where [billId]'s sync has got to.
  SplitsSyncState syncStateOf(String billId) =>
      _syncStates[billId] ??
      SplitsSyncState(
        phase: hasRelay ? SplitsSyncPhase.idle : SplitsSyncPhase.noRelay,
      );

  /// Pushes and pulls through the relay.
  ///
  /// **Never throws.** A sync that could not reach the relay is a state to
  /// show, not a reason to take a bill down: everything on it is already on
  /// this device, and what failed is telling the others.
  Future<SyncResult?> syncBill(String billId) async {
    if (!hasRelay) {
      // Asked for explicitly, so it answers: an action that quietly did
      // nothing looks exactly like one that worked. The phase stays
      // `noRelay`, because a build with nowhere to sync to has not failed at
      // anything.
      _syncStates[billId] = const SplitsSyncState(
        phase: SplitsSyncPhase.noRelay,
      );
      _report('This build has no bill relay. Share by code.');
      notifyListeners();
      return null;
    }
    _syncStates[billId] = const SplitsSyncState(phase: SplitsSyncPhase.syncing);
    notifyListeners();

    // Counted before and after, because a sync returns the whole merged log
    // rather than what it added. Saying "3 new" from a figure nothing
    // measured would be a number the screen cannot back.
    final before =
        _bills.where((b) => b.id == billId).firstOrNull?.entryCount ?? 0;

    // The key this sync opens and seals under. A key replaced while the sync
    // is in flight is not the one a mismatch below is about.
    String? used;
    try {
      used = await _keys.readBillKey(billId);
    } on StateError {
      used = null;
    }

    SyncResult? result;
    try {
      result = await _sync.sync(billId);
      await _refresh();
      final after =
          _bills.where((b) => b.id == billId).firstOrNull?.entryCount ?? 0;
      _syncStates[billId] = SplitsSyncState(
        phase: SplitsSyncPhase.synced,
        at: _wallet.now(),
        received: after - before,
        // A channel where every blob is unopenable is a key that is wrong,
        // and that looks identical to a quiet relay unless it is said.
        unopenable: result.unopenable,
      );
      notifyListeners();
    } on Object catch (e) {
      if (e is SplitsSyncException &&
          e.code == protocol.SplitCode.inviteKeyMismatch) {
        // §9.4: the key held for this bill is not the one it was made with,
        // so it opens only what its maker sealed for this device. Kept, it
        // would also refuse the bill's real invite as a conflict. Nothing
        // the bill's own create commits to can be forged under its id, so
        // this never drops the key of a bill that is genuine. Only the key
        // the sync used is dropped: one chosen since then stays.
        String? held;
        try {
          held = await _keys.readBillKey(billId);
        } on StateError {
          held = null;
        }
        if (used != null && held == used) await _keys.forgetBill(billId);
      }
      // A sync pulls and merges before it pushes, so a push the relay
      // refused still leaves what the others wrote in the store: shown, not
      // held back until the next sync that fully succeeds.
      try {
        await _refresh();
      } on Object {
        // The failure being reported is the sync's.
      }
      _syncStates[billId] = SplitsSyncState(
        phase: SplitsSyncPhase.failed,
        at: _wallet.now(),
        detail: _describe(e),
      );
      notifyListeners();
    }
    return result;
  }

  Timer? _poller;

  /// Syncs [billId] every [every] until [stopPolling].
  ///
  /// One timer, whichever bill is open: two would race on one relay and each
  /// would refresh over the other's answer.
  void pollBill(String billId, {Duration every = const Duration(seconds: 5)}) {
    _polled.add((billId, every));
    _pollTop();
  }

  /// Stops the poll [pollBill] started for [billId], and polls the bill a
  /// screen still open beneath it asked for. Stops every poll when [billId]
  /// is null.
  ///
  /// One timer serves the screen on top. A screen closing stops only its own
  /// request: stopping whatever was running would leave a bill still on
  /// screen unpolled while its notice says it is up to date.
  void stopPolling([String? billId]) {
    if (billId == null) {
      _polled.clear();
    } else {
      final at = _polled.lastIndexWhere((p) => p.$1 == billId);
      if (at >= 0) _polled.removeAt(at);
    }
    _pollTop();
  }

  /// The bills screens asked to poll, oldest first; the last is polled.
  final List<(String, Duration)> _polled = [];

  void _pollTop() {
    _poller?.cancel();
    _poller = null;
    if (_polled.isEmpty || !hasRelay) return;
    final (billId, every) = _polled.last;
    // Out of the current turn: a screen starts this from
    // `didChangeDependencies`, which runs during build, and notifying
    // listeners there marks a widget dirty while the framework is building
    // it.
    unawaited(Future<void>.microtask(() => syncBill(billId)));
    _poller = Timer.periodic(every, (_) => unawaited(syncBill(billId)));
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  /// What this device owes on [billId], or null when the bill has no rate.
  ///
  /// [via] is the payer's choice of payout for recipients it names, as
  /// indices into what each declared (§14.8); [payoutIndexes] builds it from
  /// the payouts a person picked.
  Future<splitz.PayerObligation?> obligation(
    String billId, {
    Map<String, int> via = const {},
  }) async {
    final view = _bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) return null;
    final folded = await _storedFold(billId);
    final unread = await _unreadAddresses(folded);
    return splitz.obligationVia(
      _host(_identitySeed, unread: unread),
      folded,
      via,
    );
  }

  /// Every Zcash address [folded] could put in a request that this wallet's
  /// reader refuses. A request is read whole, so one such address would stop
  /// the payment to everybody else; the obligation reports it unpayable
  /// instead (§14.6).
  Future<Set<String>> _unreadAddresses(splitz.FoldedBill folded) async {
    final addresses = <String>{
      for (final p in folded.bill.participants) ...[
        ?p.payTo,
        for (final o in p.payouts)
          if (o.type == 'zec') ?o.address,
      ],
    };
    return {
      for (final a in addresses)
        if (!await _readsAddress(a)) a,
    };
  }

  /// [billId] as the store holds it now, folded as [_refresh] folds it: what
  /// a send checks against, rather than a published view a merge has not
  /// reached yet.
  Future<splitz.FoldedBill> _storedFold(String billId) async {
    final seed = _identitySeed;
    final entries = await _store.read(billId);
    return seed == null
        ? foldUnverified(_wallet, entries, billId: billId)
        : await foldVerified(
            _wallet,
            entries,
            billId: billId,
            signer: _signer,
            seed: seed,
          );
  }

  /// Where each payout in [chosen] now sits in its participant's declared
  /// list on [bill], keyed by participant id.
  ///
  /// A choice is held as the payout itself and not its position: a payee who
  /// edits their list moves every position after the edit, and an index kept
  /// across that would pay an address nobody picked. A choice [bill] no longer
  /// declares is left out, so the payee's first preference applies again.
  static Map<String, int> payoutIndexes(
    protocol.Bill bill,
    Map<String, protocol.Payout> chosen,
  ) => {
    for (final MapEntry(key: id, value: payout) in chosen.entries)
      id: ?_declaredAt(bill.participant(id), payout),
  };

  /// [to] on [bill] as a payment to them reads them: with [chosen] first
  /// when the payer picked it (§14.8), and null when [to] is not on the bill
  /// or no longer declares [chosen].
  static protocol.Participant? _paidBy(
    protocol.Bill bill,
    String to,
    protocol.Payout? chosen,
  ) {
    if (chosen == null) return bill.participant(to);
    final via = payoutIndexes(bill, {to: chosen});
    if (via.isEmpty) return null;
    return protocol.choosePayouts(bill, via).participant(to);
  }

  static int? _declaredAt(protocol.Participant? who, protocol.Payout payout) =>
      declaredPayoutIndex(who?.payouts ?? const <protocol.Payout>[], payout);

  /// Sends what this device owes and records that it did.
  ///
  /// [owed] is what the payer was shown. It is read again from the bill
  /// before anything is sent, and a difference refuses the send: entries that
  /// arrived since — a payment recorded, a rate changed — would otherwise go
  /// out under figures nobody looked at.
  ///
  /// **Written down before the wallet is called.** A send the wallet reports
  /// as pending, or one the app died during, leaves a [PendingSend] behind, and
  /// no further send from this bill goes out until [resolveSend] settles
  /// which way it went.
  ///
  /// [via] is the payout choice [owed] was read with (§14.8).
  Future<splitz.Settled?> settle(
    String billId,
    splitz.PayerObligation owed, {
    Map<String, int> via = const {},
  }) async {
    splitz.Settled? settled;
    await _guard(() async {
      if (!_sending.add(billId)) {
        throw const SplitsRefusal(
          'A send from this bill is already under way.',
        );
      }
      try {
        settled = await _settle(billId, owed, via);
      } finally {
        _sending.remove(billId);
      }
      await _refresh();
    });
    return settled;
  }

  Future<splitz.Settled> _settle(
    String billId,
    splitz.PayerObligation owed,
    Map<String, int> via,
  ) async {
    {
      if (await _sends.of(billId) != null) {
        throw const SplitsRefusal(
          'An earlier send isn’t resolved. Check your wallet.',
        );
      }
      final now = await obligation(billId, via: via);
      if (now?.uri != owed.uri) {
        throw const SplitsRefusal('The bill changed. Check the amounts.');
      }
      final seed = _identitySeed;
      final entries = await _store.read(billId);
      final log = splitz.BillLog(_host(seed), entries: entries, billId: billId);
      final uri = owed.uri;
      final carried = owed.carriedTo;
      if (uri == null || carried.isEmpty) {
        // Nothing a wallet can be handed: `settle` answers failed without
        // calling it, so there is nothing to write down.
        return splitz.settle(_host(seed), log, owed);
      }
      final note = PendingSend(
        billId: billId,
        uri: uri,
        carried: carried,
        at: protocol.canonicalInstant(_wallet.now().toUtc().toIso8601String()),
        sent: owed.carriedZatoshi,
        rate: owed.rate,
      );
      try {
        await _sends.begin(note);
      } on SendInFlight {
        throw const SplitsRefusal(
          'An earlier send isn’t resolved. Check your wallet.',
        );
      }
      // Until the wallet answers, which way it went is unknown (§14.3).
      var how = SendEnded.unresolved;
      String? txid;
      var recorded = false;
      try {
        final settled = await splitz.settle(_host(seed), log, owed);
        txid = settled.txid;
        switch (settled.result) {
          case splitz.SendResult.sent:
            how = SendEnded.reachedNetwork;
            // False when the bill was forgotten while the money went out:
            // the note then stays, with the transaction, so the record can
            // be written once the bill is back.
            recorded = await _mergeWhileHeld(billId, settled.records);
          case splitz.SendResult.failed:
            how = SendEnded.refused;
          case splitz.SendResult.pending:
            how = SendEnded.unresolved;
        }
        return settled;
      } finally {
        await _sends.end(
          billId,
          how,
          txid: txid,
          recorded: recorded,
          wrote: note,
        );
      }
    }
  }

  /// What a write into a bill forgotten while it was being written says.
  static const _removed = SplitsRefusal(
    'This bill was removed from this phone.',
  );

  /// Merges [entries] into [billId] only while this device still holds its
  /// key, and says whether they were written.
  ///
  /// A bill forgotten while a write was on its way must not be written back
  /// without its key: it would sit in storage, unlisted and unreadable. A
  /// keychain that refuses to read while the session is locked has not said
  /// the key is gone, and the write goes ahead.
  ///
  /// [andIf], when given, is asked inside the same turn, after the key: a
  /// write that depends on what the bill holds decides it where no other
  /// write to the bill can come between the reading and the write.
  Future<bool> _mergeWhileHeld(
    String billId,
    List<Map<String, dynamic>> entries, {
    Future<bool> Function()? andIf,
  }) async {
    if (entries.isEmpty) return true;
    final merged = await _store.merge(
      billId,
      entries,
      onlyIf: () async {
        try {
          if (await _keys.readBillKey(billId) == null) return false;
        } on StateError {
          // A locked keychain has not said the key is gone.
        }
        return andIf == null || await andIf();
      },
    );
    return merged.applied;
  }

  /// The send from [billId] this device started and has not seen resolved.
  Future<PendingSend?> pendingSend(String billId) => _sends.of(billId);

  /// Settles which way an unresolved send went.
  ///
  /// [landed] says it reached the network. A payment request is then
  /// recorded from [txid] — the transaction the wallet shows for it — exactly
  /// as a send that succeeded at once would have been, so a payee confirms
  /// the same payment either way; a swap is recorded by its provider
  /// reference. Not [landed], the person is saying nothing left the wallet,
  /// and the debt can be sent again.
  Future<void> resolveSend(
    String billId, {
    bool landed = false,
    String? txid,
  }) async {
    await _guard(() async {
      // Until the wallet answers, nobody knows that nothing left it: a note
      // cleared now lets the same debt go out twice.
      if (_sending.contains(billId) || _sends.underWay(billId)) {
        throw const SplitsRefusal(
          'That send is still with the wallet. Wait for it to answer.',
        );
      }
      final intent = await _sends.of(billId);
      if (intent == null) return;
      final built = intent.txid;
      if (!landed && built != null) {
        switch (await _heldState(built)) {
          case HeldTransaction.waiting:
            throw const SplitsRefusal(
              'Your wallet still holds this transaction and may send it. '
              'Wait until it goes through or expires.',
            );
          case HeldTransaction.mined:
            throw const SplitsRefusal(
              'Your wallet shows this transaction went through. Record it '
              'instead.',
            );
          case HeldTransaction.expired || null:
            break;
        }
      }
      if (!landed && built == null) {
        // No id to look for: the app stopped before the wallet answered.
        // §14.3 decides from what the wallet is still sending and what it
        // has built since the note was written.
        final Map<String, HeldTransaction> held;
        final List<OwnTransaction> own;
        try {
          held = await _held();
          own = await _own();
        } on Object {
          throw const SplitsRefusal(
            'Your wallet’s history could not be read to check this send. '
            'Try again in a moment.',
          );
        }
        final refusal = unsentClaimRefusal(
          intent,
          stillSending: held.values.contains(HeldTransaction.waiting),
          own: own,
        );
        switch (refusal?.claim) {
          case UnsentClaim.stillSending:
            throw const SplitsRefusal(
              'Your wallet is still sending a transaction, and it may be this '
              'one. Wait until it goes through or expires.',
            );
          case UnsentClaim.builtSince:
            final txid = refusal!.txid!;
            throw SplitsRefusal(
              'Your wallet sent ${txid.substring(0, 8)}… after this payment '
              'started. If it was this payment, record it with that id '
              'instead.',
            );
          case null:
            break;
        }
      }
      final swap = intent.swap;
      if (landed && swap != null) {
        // The provider's reference identifies it; no transaction id needed.
        final amount = intent.carried[swap.to];
        if (amount == null) {
          throw const SplitsRefusal('Send details lost. Record it by hand.');
        }
        if (!await _recordSwap(swap, amount, intent.zatoshi, intent.rate)) {
          throw const SplitsRefusal('Bill not on this phone. Open it again.');
        }
      } else if (landed) {
        final given = (txid == null || txid.trim().isEmpty)
            ? intent.txid
            : txid;
        if (given == null) {
          throw const SplitsRefusal(
            'Copy the 64-character transaction id from the wallet’s history.',
          );
        }
        final seed = await _requireIdentity();
        final host = _host(seed);
        final log = splitz.BillLog(
          host,
          entries: await _store.read(billId),
          billId: billId,
        );
        final List<Map<String, dynamic>> records;
        try {
          records = await _sends.recordsFor(
            host,
            log,
            intent,
            await _inSendOrder(given),
          );
        } on Unrecordable catch (e) {
          throw SplitsRefusal(switch (e.reason) {
            UnrecordableReason.notATransactionId =>
              'Not a transaction id. Copy the 64-character one.',
            UnrecordableReason.detailsLost =>
              'Send details lost. Record each payment by hand.',
            UnrecordableReason.isASwap =>
              'Send details lost. Record it by hand.',
          });
        }
        if (!await _mergeWhileHeld(billId, records)) {
          throw const SplitsRefusal('Bill not on this phone. Open it again.');
        }
      }
      try {
        await _sends.resolve(billId, seen: intent);
      } on SendInFlight {
        throw const SplitsRefusal(
          'A newer send replaced this one. Open the bill again.',
        );
      }
      await _refresh();
    });
  }

  /// Merges this device's own [entry] into [billId] and reads the bill again,
  /// throwing when the fold set it aside.
  ///
  /// An action whose entry the fold refused did nothing, and a screen that
  /// closes as if it worked says otherwise. The refusal is given in the
  /// protocol's own words (§1).
  Future<void> _mergeChecked(String billId, Map<String, dynamic> entry) async {
    // Folded first. A refusal the entry's own content or author decides is
    // never written: written, it would reach every device on the next sync
    // and be reported there as set aside for good. One that waits on an entry
    // this device has not yet seen is written as before, since it applies
    // once that entry arrives.
    final trial = await foldVerified(
      _wallet,
      [...await _store.read(billId), entry],
      billId: billId,
      signer: _signer,
      seed: await _requireIdentity(),
    );
    final refusedFirst = trial.setAside
        .where((a) => a.id == entry['id'] && !_waitsOnOthers.contains(a.code))
        .firstOrNull;
    if (refusedFirst != null) {
      throw SplitsRefusal(
        protocol.describeCode(refusedFirst.code) ??
            'Not applied: ${refusedFirst.code}.',
      );
    }
    if (!await _mergeWhileHeld(billId, [entry])) throw _removed;
    await _refresh();
    final view = _bills.where((b) => b.id == billId).firstOrNull;
    final refused = view?.setAside
        .where((a) => a.id == entry['id'])
        .firstOrNull;
    if (refused != null) {
      throw SplitsRefusal(
        protocol.describeCode(refused.code) ?? 'Not applied: ${refused.code}.',
      );
    }
  }

  /// Refusals an entry can outgrow: each names something this device may not
  /// hold yet, and the entry applies once a sync brings it.
  static const Set<String> _waitsOnOthers = {
    protocol.SplitCode.unknownParticipant,
    protocol.SplitCode.unknownEntry,
    protocol.SplitCode.unknownPayment,
  };

  /// Throws while a send from [billId] is under way or unresolved.
  Future<void> _refuseWhileSending(String billId) async {
    if (_sending.contains(billId) ||
        _sends.underWay(billId) ||
        await _sends.of(billId) != null) {
      throw const SplitsRefusal(
        'An earlier send isn’t resolved. Check your wallet.',
      );
    }
  }

  /// Where [txid] stands in this wallet's history, or null when it is not
  /// there or the history cannot be read.
  Future<HeldTransaction?> _heldState(String txid) async {
    try {
      final key = splitz.txidKey(txid);
      for (final e in (await _held()).entries) {
        if (splitz.txidKey(e.key) == key) return e.value;
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// [txid] in the byte order a send reports, when this wallet's history can
  /// say which order it was written in.
  ///
  /// A transaction id can be copied in either order — an explorer shows the
  /// send's order, the wallet's status screen copies the stored one — and a
  /// record in the wrong order never matches the payment on the payee's side.
  /// When the history holds the id reversed and not as given, the reverse is
  /// the one; when it holds neither yet, it is kept as given.
  Future<String> _inSendOrder(String txid) async {
    final id = txid.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) return txid;
    final Set<String> known;
    try {
      known = await _known();
    } on Object {
      return id;
    }
    if (known.contains(id)) return id;
    final reversed = [
      for (var i = id.length - 2; i >= 0; i -= 2) id.substring(i, i + 2),
    ].join();
    return known.contains(reversed) ? reversed : id;
  }

  /// Quotes settling [to]'s debt in the asset they asked for (§9.2).
  ///
  /// Returns null when this bill carries no rate — there is no ZEC figure to
  /// quote without one — or when [to] did not ask for a swap.
  ///
  /// **The asset and the chain are matched together.** One symbol exists on
  /// many chains, and a provider matched on the symbol alone delivers the
  /// right token to a network the recipient cannot reach.
  ///
  /// [payout] is a lower preference [to] declared, chosen by the payer
  /// (§14.8); absent, their first decides.
  Future<SwapQuote?> quoteSwap({
    required String billId,
    required String to,
    required int amountMinorUnits,
    protocol.Payout? payout,
  }) async {
    SwapQuote? quote;
    await _guard(() async {
      final view = bills.where((b) => b.id == billId).firstOrNull;
      final rate = view?.bill.rate;
      if (view == null || rate == null) return;

      final payee = _paidBy(view.bill, to, payout);
      if (payee == null || splitz.laneFor(payee) != splitz.SettleLane.swap) {
        return;
      }
      final chosen = payee.payouts.first;
      final asset = chosen.asset;
      final chain = chosen.chain;
      final address = chosen.address;
      if (asset == null || chain == null || address == null) {
        throw const SwapException(
          'That payout has no asset, chain or address.',
        );
      }

      final carried = await _swaps.tradableAssets();
      final match = carried.where((a) => a.answers(asset, chain)).firstOrNull;
      if (match == null) {
        throw SwapException('This provider does not deliver $asset on $chain');
      }

      // The bill's own rate, not a live one: §7 snapshots a price so every
      // device converts the same debt to the same ZEC figure.
      final zatoshi = protocol.fiatToZatoshi(
        amountMinorUnits,
        rate,
        amountCurrency: view.bill.currency,
      );
      final refundTo = _wallet.sender.payToAddress;
      if (refundTo == null) {
        // A failed swap with nowhere to send the ZEC back to is the one
        // failure a payer cannot recover from.
        throw const SwapException(
          'This wallet has no address a refund could return to',
        );
      }

      final quoted = await _swaps.quote(
        asset: match,
        amountInZatoshi: zatoshi,
        recipient: address,
        refundTo: refundTo,
      );
      _refuseMemo(quoted);
      quote = quoted;
    });
    return quote;
  }

  /// Sends the ZEC leg of [quote] and records the swap (§9.2).
  ///
  /// **Everything the record needs is read before the send.** A deposit that
  /// lands while its record is lost leaves the bill showing a debt that is
  /// paid and the payee never seeing it, and the transaction cannot be
  /// unsent.
  ///
  /// A send that did not land records nothing: §14.3 gives three outcomes,
  /// and a pending one is neither paid nor free to retry.
  ///
  /// The record is a claim, not a settlement. That the deposit was sent is
  /// not that the recipient was paid — only they can say that (§10.5).
  ///
  /// [payout] is the one [quote] was asked for, as [quoteSwap] took it.
  Future<WalletSendOutcome?> sendSwap({
    required String billId,
    required String to,
    required int amountMinorUnits,
    required SwapQuote quote,
    protocol.Payout? payout,
  }) async {
    WalletSendOutcome? outcome;
    await _guard(() async {
      if (!_sending.add(billId)) {
        throw const SplitsRefusal(
          'A send from this bill is already under way.',
        );
      }
      try {
        outcome = await _sendSwap(billId, to, amountMinorUnits, quote, payout);
      } finally {
        _sending.remove(billId);
      }
      await _refresh();
    });
    return outcome;
  }

  Future<WalletSendOutcome> _sendSwap(
    String billId,
    String to,
    int amountMinorUnits,
    SwapQuote quote,
    protocol.Payout? chosen,
  ) async {
    {
      // Every check reads the bill the store holds now: a merge not yet
      // published would otherwise pass the address against one bill and the
      // amount against another. What is checked, and in which order, is
      // §15.7's; this maps each refusal to what the payer is told.
      final held = (await _storedFold(billId)).bill;
      final via = chosen == null
          ? const <String, int>{}
          : payoutIndexes(held, {to: chosen});
      final refusal = swapSendRefusal(
        quote,
        now: protocol.canonicalInstant(_wallet.now().toUtc().toIso8601String()),
        bill: held,
        obligation: await obligation(billId, via: via),
        to: to,
        amountMinorUnits: amountMinorUnits,
        chosen: chosen,
      );
      if (refusal != null) throw _swapRefusal(refusal, held);
      // Checked above to be the rate that sized the deposit.
      final rate = held.rate!;
      // Captured first, deliberately: after the wallet is called this device
      // may be anywhere.
      final zatoshi = quote.amountInZatoshi;
      // Remembered locally so this device can ask the provider how it went.
      // The bill carries the reference and nothing else: a deposit address is
      // one provider's routing detail for one swap, not something every
      // participant should hold forever.
      final watch = SwapWatch(
        billId: billId,
        reference: quote.paymentReference,
        to: to,
        depositAddress: quote.depositAddress,
        depositMemo: quote.depositMemo,
        assetSymbol: quote.asset.symbol,
        assetChain: quote.asset.chain,
      );

      // The rate the quote was priced from, carried onto the record: checked
      // above to be the one that sized the deposit.
      final uri = protocol.renderUri([
        protocol.Zip321Payment(
          address: quote.depositAddress,
          zatoshi: zatoshi,
          label: 'swap to ${quote.asset.symbol}',
        ),
      ]);

      final note = PendingSend(
        billId: billId,
        uri: uri,
        carried: {to: amountMinorUnits},
        at: protocol.canonicalInstant(_wallet.now().toUtc().toIso8601String()),
        swap: watch,
        zatoshi: zatoshi,
        rate: rate,
      );
      try {
        await _sends.begin(note);
      } on SendInFlight {
        throw const SplitsRefusal(
          'An earlier send isn’t resolved. Check your wallet.',
        );
      }
      var how = SendEnded.unresolved;
      String? txid;
      var recorded = false;
      try {
        final outcome = await _wallet.sender.send(uri);
        txid = outcome.txid;
        switch (outcome.phase) {
          case WalletSendPhase.succeeded:
            how = SendEnded.reachedNetwork;
            // False if the bill was forgotten meanwhile: the note stays, and
            // once the bill is back the swap is recorded by its reference.
            recorded = await _recordSwap(
              watch,
              amountMinorUnits,
              zatoshi,
              rate,
              guaranteed: quote.minAmountOut == null
                  ? null
                  : formatBaseUnits(quote.minAmountOut!, quote.asset.decimals),
            );
          case WalletSendPhase.failed || WalletSendPhase.aborted:
            how = SendEnded.refused;
          case WalletSendPhase.pendingBroadcast:
            how = SendEnded.unresolved;
        }
        return outcome;
      } finally {
        await _sends.end(
          billId,
          how,
          txid: txid,
          recorded: recorded,
          wrote: note,
        );
      }
    }
  }

  /// What the payer is told when [refusal] stops a deposit on [bill].
  static Exception _swapRefusal(
    SwapSendRefusal refusal,
    protocol.Bill bill,
  ) => switch (refusal.refused) {
    SwapSendRefused.expired => const SwapException(
      'Quote expired. Get a new one.',
    ),
    SwapSendRefused.needsMemo => const SwapException(
      'This swap needs a memo we can’t add. Nothing was sent.',
    ),
    SwapSendRefused.payoutGone => const SplitsRefusal(
      'Their payout changed. Choose again.',
    ),
    // Held, not changed: a payment this payer sent and nobody has
    // confirmed yet covers this debt (§14.4), perhaps to somebody else
    // when netting routed it there (§6.3). Saying who must confirm is
    // what lets the payer act; "the bill changed" sends them looking for
    // an edit.
    SwapSendRefused.held => SplitsRefusal(
      'Held until ${[for (final id in refusal.paidTo) bill.participant(id)?.name ?? id].join(' and ')} '
      'confirms the payment you already sent. Pay this after that.',
    ),
    SwapSendRefused.notOwed => const SplitsRefusal(
      'The bill changed. Check what’s owed.',
    ),
    SwapSendRefused.recipientChanged => const SplitsRefusal(
      'Their address changed. Get a new quote.',
    ),
    SwapSendRefused.assetChanged => const SplitsRefusal(
      'Their payout changed asset or chain. Get a new quote.',
    ),
    SwapSendRefused.rateChanged => const SplitsRefusal(
      'The bill’s price changed. Get a new quote.',
    ),
  };

  /// Refuses a quote whose deposit needs a memo.
  ///
  /// The deposit is sent as a plain payment request, which carries no memo,
  /// and a deposit that arrives without one the provider requires is lost.
  static void _refuseMemo(SwapQuote quote) {
    final memo = quote.depositMemo;
    if (memo != null && memo.isNotEmpty) {
      throw const SwapException(
        'This swap needs a memo we can’t add. Nothing was sent.',
      );
    }
  }

  /// Records the swap [watch] names as sent, and starts following it.
  ///
  /// Says whether the record is on the bill: false when the bill was
  /// forgotten and nothing was written. A payment already recorded under the
  /// swap's reference is not recorded again.
  /// [rate] is the bill's rate the quote was priced from: what the record
  /// states as `paidAtRate`, so the payee confirms against the ZEC figure and
  /// the rate that made it, as for a ZEC payment (§9.2).
  Future<bool> _recordSwap(
    SwapWatch watch,
    int amountMinorUnits,
    int? zatoshi,
    protocol.ExchangeRate? rate, {
    String? guaranteed,
  }) async {
    final held = _bills.where((b) => b.id == watch.billId).firstOrNull;
    // The record's id is the reference under this author (§10.3 step 5).
    final recordId = splitz.authoredId(me, watch.reference);
    if (held?.bill.payments.any((p) => p.id == recordId) ?? false) {
      await _watches.add(watch);
      return true;
    }
    final seed = await _requireIdentity();
    final host = _host(seed);
    final entry = await splitz.signEntry(
      host: host,
      entry: splitz.recordPayment(
        host: host,
        paymentId: watch.reference,
        to: watch.to,
        amount: amountMinorUnits,
        method: 'swap',
        reference: watch.reference,
        zatoshi: zatoshi,
        paidAtRate: rate == null ? null : protocol.rateToJson(rate),
        // What the recipient is guaranteed, when the quote said: the record
        // claims the whole debt, and the payee confirming it is shown what
        // was due to arrive (§14.2).
        note: guaranteed == null
            ? '${watch.assetSymbol} on ${watch.assetChain}'
            : 'at least $guaranteed ${watch.assetSymbol} on ${watch.assetChain}',
      ),
      billId: watch.billId,
    );
    if (!await _mergeWhileHeld(watch.billId, [entry])) return false;
    await _watches.add(watch);
    return true;
  }

  /// The swaps this device sent and has not seen finish.
  Future<List<SwapWatch>> swapsInFlight(String billId) =>
      _watches.held(billId: billId);

  /// Asks the provider how [watch]'s swap went.
  ///
  /// **A provider saying `delivered` does not settle the debt.** §10.5 gives
  /// that to the payee alone: this says the asset was sent, and only they can
  /// say it arrived. What it does decide is whether this device keeps asking.
  Future<SwapState?> checkSwap(SwapWatch watch) async {
    SwapState? state;
    await _guard(() async {
      final status = await _swaps.statusOf(watch.asQuote);
      state = status.state;
      // Stop following a swap that has finished either way. A list that only
      // grows is one nobody reads, and a failed swap is followed up by the
      // refund reaching the wallet rather than by asking again.
      if (status.state == SwapState.failed) {
        // The deposit came back or never went through: the record saying the
        // debt was paid by this swap is not true, and while it stands the
        // debt reads as paid and waiting and nothing can pay it again. Its
        // author may take it back (§10.8), and does, before the watch goes.
        await _withdrawSwapRecord(watch);
      }
      if (status.state == SwapState.delivered ||
          status.state == SwapState.failed) {
        await _watches.forget(watch.reference);
      }
      await _refresh();
    });
    return state;
  }

  /// Withdraws this device's unconfirmed record of the swap [watch] follows
  /// (§15.7).
  Future<void> _withdrawSwapRecord(SwapWatch watch) async {
    final folded = await _storedFold(watch.billId);
    for (final target in failedSwapWithdrawals(
      folded,
      me: me,
      reference: watch.reference,
    )) {
      final seed = await _requireIdentity();
      final host = _host(seed);
      final entry = await splitz.signEntry(
        host: host,
        entry: splitz.voidEntry(host: host, targetId: target),
        billId: watch.billId,
      );
      // Not written into a bill forgotten while the provider answered.
      if (!await _mergeWhileHeld(watch.billId, [entry])) return;
    }
  }

  /// Stops following a swap without asking about it again.
  Future<void> forgetSwap(String reference) async {
    await _guard(() async {
      await _watches.forget(reference);
      await _refresh();
    });
  }

  /// What one ZEC costs in [currency], or null when nothing can price it.
  ///
  /// A suggestion, not a decision. Nothing prices a bill behind a person's
  /// back: the figure is shown, and putting it on the bill is a separate act.
  Future<int?> quoteZec(String currency) => _prices.minorUnitsPerZec(currency);

  /// The chains the swap provider delivers [symbol] on, one asset each.
  ///
  /// A chain the provider lists [symbol] on more than once is left out: a
  /// payout names an asset by symbol and chain together (§9.1), and two
  /// matches would leave the payer's swap to pick one of them.
  Future<List<TradableAsset>> deliverableOn(String symbol) async {
    final all = await _swaps.tradableAssets();
    final bySymbol = [
      for (final a in all)
        if (a.symbol.toLowerCase() == symbol.toLowerCase()) a,
    ];
    final counts = <String, int>{};
    for (final a in bySymbol) {
      counts[a.chain.toLowerCase()] = (counts[a.chain.toLowerCase()] ?? 0) + 1;
    }
    return [
      for (final a in bySymbol)
        if (counts[a.chain.toLowerCase()] == 1) a,
    ];
  }

  /// Why this device cannot settle to [payout], or null when it can.
  ///
  /// `zec` needs an address a payment request can carry (§8.3) that this
  /// wallet's reader reads on the network it sends on (§14.6); `swap` needs
  /// its asset, chain and address, and a provider that delivers that asset on
  /// that chain; `cash` is always payable. Null as well when the provider
  /// cannot be asked: not knowing is no reason to pass over a payee's
  /// preference.
  Future<String?> cannotPayBy(protocol.Payout payout) async {
    switch (payout.type) {
      case 'zec':
        final payable = protocol.Participant(
          id: '',
          name: '',
          payouts: [payout],
        ).payableAddress;
        if (payable == null) return 'their Zcash address can’t be paid';
        // Read by the reader [obligation] holds every request's addresses
        // to (§14.6): one it refuses is reported unpayable there, so it is
        // passed over here by the same answer.
        return await _readsAddress(payable)
            ? null
            : 'their Zcash address isn’t one this wallet can send to';
      case 'swap':
        final (asset, chain) = (payout.asset, payout.chain);
        bool blank(String? s) => s == null || s.trim().isEmpty;
        if (asset == null ||
            chain == null ||
            blank(asset) ||
            blank(chain) ||
            blank(payout.address)) {
          return 'their ${blank(asset) ? 'swap' : asset} payout is incomplete';
        }
        final List<TradableAsset> carried;
        try {
          carried = await _swaps.tradableAssets();
        } on Object {
          return null;
        }
        return carried.any((a) => a.answers(asset, chain))
            ? null
            : '$asset on $chain can’t be delivered';
      case 'cash':
        return null;
      default:
        return 'this app can’t pay by ${payout.type}';
    }
  }

  /// The key this bill's contents are sealed under, creating one if this
  /// device opened the bill and has not needed it yet.
  Future<String> billKey(String billId) => _keys.ensureBillKey(billId);

  /// Stores a key that arrived with an invite.
  ///
  /// Refused here rather than at the cipher when it is the wrong length: §11.1
  /// checks an invite's `k` for base64url and not for length.
  ///
  /// A key the create already held for this bill refuses (§9.4) is not
  /// stored.
  Future<void> acceptKey(String billId, String key) async {
    await _guard(() async {
      if (await heldBillRefusesKey(billId, key)) {
        throw protocol.SplitError(
          protocol.SplitCode.inviteKeyMismatch,
          'the held create of $billId commits to another key',
        );
      }
      await _keys.storeBillKey(billId, key);
    });
  }

  /// Whether this device holds a key for [billId] other than [key]: what
  /// [acceptKey] refuses, asked first so a person can be shown the choice.
  Future<bool> holdsOtherKey(String billId, String key) async {
    final held = await _keys.readBillKey(billId);
    return held != null && held.isNotEmpty && held != key;
  }

  /// Whether the create this device holds for [billId] commits to a key other
  /// than [key] (§9.4). Such a key is refused without asking anybody.
  Future<bool> heldBillRefusesKey(String billId, String key) async {
    final held = await _store.read(billId);
    return held.any((e) => protocol.createRefusesKey(e, billId, key));
  }

  /// Uses [key] for [billId] in place of the one held, on a person's word.
  ///
  /// The first invite for a bill is not necessarily the genuine one: a link is
  /// text anyone can send. This is the way out of a forged one, and it is
  /// never taken without the person choosing it. A key the held create
  /// refuses (§9.4) is refused here whatever the person chose.
  Future<void> replaceKey(String billId, String key) async {
    await _guard(() async {
      if (_sending.contains(billId) ||
          _sends.underWay(billId) ||
          await _sends.of(billId) != null) {
        throw const SplitsRefusal('Finish the earlier send first.');
      }
      if (await heldBillRefusesKey(billId, key)) {
        throw protocol.SplitError(
          protocol.SplitCode.inviteKeyMismatch,
          'the held create of $billId commits to another key',
        );
      }
      await _keys.replaceBillKey(billId, key);
      await _refresh();
    });
  }

  /// The invite for a bill this device holds, as §11.1 renders one.
  ///
  /// Carries the bill id and the key, and nothing else. The log still has to
  /// arrive from somewhere — a scan of the whole bill, or the relay.
  Future<String> inviteFor(
    String billId, {
    String? name,
    DateTime? expiry,
  }) async {
    final view = _bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) {
      throw StateError('this device holds no bill $billId');
    }
    return splitz.inviteFor(
      bill: view.bill,
      key: await billKey(billId),
      name: name ?? view.bill.name,
      expiry: expiry,
    );
  }

  /// The whole bill as one scannable payload, or null when it has outgrown a
  /// scan (§11.2).
  ///
  /// Null rather than a refusal code, so a caller has a state to show — "too
  /// big for a code, use the relay" — instead of an error to report.
  Future<String?> shareableBill(String billId) async {
    final view = _bills.where((b) => b.id == billId).firstOrNull;
    if (view == null) return null;
    final entries = await _store.read(billId);
    return splitz.shareableBill(
      log: splitz.BillLog(
        _host(_identitySeed),
        entries: entries,
        billId: billId,
      ),
      key: await billKey(billId),
      bill: view.bill,
    );
  }

  /// Forgets a bill and its key.
  ///
  /// The key first. A sync in flight merges only while the key is held, so
  /// with the key gone it cannot write the bill back after the store has
  /// forgotten it — which would leave a bill on the device with no key to
  /// read or share it.
  Future<void> forget(String billId) async {
    await _guard(() async {
      // A send that may still land keeps its bill: forgetting it would
      // forget the only note that the debt is already paid.
      if (_sending.contains(billId) ||
          _sends.underWay(billId) ||
          await _sends.of(billId) != null) {
        throw const SplitsRefusal('Finish the earlier send first.');
      }
      await _forget(billId);
      await _refresh();
    });
  }

  Future<void> _forget(String billId) async {
    final marker = '$_forgetting$billId';
    await _store.storage.write(marker, billId);
    await _keys.forgetBill(billId);
    await _store.forget(billId);
    await _store.storage.delete(marker);
  }

  /// Finishes every forget a killed process left part-way.
  Future<void> _finishForgets() async {
    for (final marker in await _store.storage.keys(_forgetting)) {
      await _forget(marker.substring(_forgetting.length));
    }
  }

  WalletBillHost _host(List<int>? seed, {Set<String> unread = const {}}) =>
      WalletBillHost(
        _wallet,
        me: seed == null ? null : _participant,
        sign: seed == null ? null : _signer.signerFor(seed),
        readsAddress: unread.isEmpty ? null : (a) => !unread.contains(a),
      );

  Future<List<int>> _requireIdentity() async {
    final seed = _identitySeed ??= await _keys.ensureIdentitySeed(
      _wallet.account,
    );
    _identityKey ??= await _signer.publicKeyFromSeed(seed);
    _participant ??= protocol.participantId(_identityKey!);
    return seed;
  }

  /// An expense id nobody else will choose.
  ///
  /// §9.5 derives an entry's id from its content, so two expenses that agree
  /// in every member would otherwise be one entry, and adding the same round
  /// twice would silently record it once.
  String _expenseId() => SplitsSigner.encode(_wallet.randomBytes(16));

  /// An id for a cash payment, which has no transaction to take one from.
  ///
  /// Random rather than derived: two cash payments of the same amount to the
  /// same person on the same day are two payments, and a derived id would
  /// fold them into one.
  String _cashId() => SplitsSigner.encode(_wallet.randomBytes(16));

  /// Counts refreshes started, so one that finishes after a later one does
  /// not publish the older view over it.
  int _refreshes = 0;

  /// The refresh started last.
  Future<void>? _latestRefresh;

  /// Folds every bill the store holds and publishes them.
  ///
  /// Returns once a view at least as new as the store when it was called is
  /// published: one superseded by a later refresh waits for that one, which
  /// read the store after it. A caller that reads [bills] next then sees what
  /// it just merged.
  Future<void> _refresh() {
    final run = _refreshOnce();
    _latestRefresh = run;
    return run;
  }

  Future<void> _refreshOnce() async {
    final generation = ++_refreshes;
    final ids = await _store.billIds();
    final views = <BillView>[];
    for (final id in ids) {
      final entries = await _store.read(id);
      if (entries.isEmpty) continue;
      try {
        final seed = _identitySeed;
        final folded = seed == null
            ? foldUnverified(_wallet, entries, billId: id)
            : await foldVerified(
                _wallet,
                entries,
                billId: id,
                signer: _signer,
                seed: seed,
              );
        views.add(
          BillView(
            bill: folded.bill,
            creatorId: _creatorOf(entries),
            setAside: folded.setAside,
            replacedAddresses: folded.replacedAddresses,
            identities: folded.identities,
            entryCount: entries.length,
            // The fold's own answers: a set-aside entry carrying an expense's
            // id never stands in for the one the fold applied.
            expenseEntries: folded.expenseEntries,
            paymentEntries: folded.paymentEntries,
            expenseAuthors: folded.expenseAuthors,
            paymentDigests: folded.paymentDigests,
            paymentAuthors: folded.paymentAuthors,
            rateSetBy: folded.rateAuthor,
            rateEntry: folded.rateEntry,
            activity: activityOf(
              protocol.orderEntries(entries),
              folded.bill,
              setAside: folded.setAside,
              withdrawn: folded.withdrawn,
            ),
          ),
        );
      } on Object {
        // A log that opens no bill, or one whose history cannot be read, is a
        // state to show elsewhere, not a reason to take the whole list down.
        // Every bill syncs from peers, so one peer's malformed entry would
        // otherwise empty the list of bills they never held a key for. It is
        // left out rather than raised, and the entries stay on disk.
        continue;
      }
    }
    if (generation != _refreshes) {
      try {
        await _latestRefresh;
      } on Object {
        // The later refresh's caller reports its own failure.
      }
      return;
    }
    _bills = List.unmodifiable(views);
    await _findArrivals();
  }

  static String _creatorOf(List<Map<String, dynamic>> entries) {
    for (final entry in entries) {
      if (entry['kind'] == 'createBill') {
        final author = entry['author'];
        return author is String ? author : '';
      }
    }
    return '';
  }

  Future<void> _guard(Future<void> Function() body) async {
    _running++;
    _report(null);
    notifyListeners();
    try {
      await body();
    } on Object catch (e) {
      // Reported, never swallowed: an action that quietly did nothing looks
      // exactly like one that worked.
      _report(_describe(e));
    } finally {
      _running--;
      notifyListeners();
    }
  }

  /// [error] as a sentence for a person.
  static String describe(Object error) => _describe(error);

  static String _describe(Object error) {
    // A sentence a person can read, from the code (§12); the code itself
    // for one this version does not know, which names what to update.
    if (error is protocol.SplitError) {
      return protocol.describeCode(error.code) ?? error.code;
    }
    // Already a sentence for a person: wrapping it in a type name would put
    // `SwapException:` in front of text written to be read.
    if (error is SwapException) return error.message;
    if (error is SplitsRefusal) return error.message;
    if (error is BillKeyConflict) {
      return 'This phone has another key for this bill. Ask which one is current.';
    }
    if (error is SplitsSyncException) {
      return switch (error.kind) {
        SyncFailure.noKey =>
          'This phone doesn’t have this bill’s key. Scan its code again.',
        SyncFailure.keyLocked => 'Unlock the wallet to sync this bill.',
        SyncFailure.forgotten => 'This bill was removed while it synced.',
        SyncFailure.foreignKey =>
          protocol.describeCode(protocol.SplitCode.inviteKeyMismatch) ??
              error.message,
      };
    }
    if (error is SplitsRelayException) {
      // What the relay said is for a developer; a person needs to know
      // whether waiting helps. Nothing is lost either way: the bill is held
      // on this phone and goes out on the next sync that gets through.
      return error.isTransient
          ? 'Couldn’t sync with the bill relay. Your changes are saved on '
                'this phone and will go out when it answers.'
          : 'This build can’t use the bill relay. Share the bill’s code '
                'instead.';
    }
    return error.toString();
  }
}

/// A refusal written to be read by a person.
class SplitsRefusal implements Exception {
  const SplitsRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// A host that writes as somebody else on this bill.
///
/// Used only to put on the bill a person who is not here to join it
/// themselves. The clock and the randomness stay this device's; the entry is
/// written unsigned, because signing as somebody whose key this device does
/// not hold would assert something false.
///
/// No identity key is claimed for them either. §10.7 binds a key only when
/// the entry's author is the participant it names and the signature verifies
/// against it, and nobody here can prove who they are — they bind their own
/// identity by joining from their own device.
class _HostAs implements splitz.BillHost {
  _HostAs(this._inner, this.me);

  final splitz.BillHost _inner;

  @override
  final String me;

  @override
  splitz.Clock get now => _inner.now;

  @override
  splitz.Randomness get randomBytes => _inner.randomBytes;

  @override
  splitz.Broadcast get broadcast => _inner.broadcast;

  /// None: nothing written as somebody else is signed.
  @override
  splitz.SignEntry? get sign => null;

  @override
  splitz.VerifyEntry? get verify => _inner.verify;

  @override
  splitz.ReadsAddress? get readsAddress => _inner.readsAddress;
}

/// What the actions one [SplitsController.failureOf] started could not do.
class _Outcome {
  String? failure;
}
