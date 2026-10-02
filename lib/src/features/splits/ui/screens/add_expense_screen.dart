/// Putting an expense on a bill.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../split_words.dart';

import 'package:splitz_core/splitz_core.dart' as protocol;
import 'package:splitz_host/splitz_host.dart';

import '../state/splits_controller.dart';
import '../view/chrome.dart';
import '../view/naming.dart';
import 'splits_scope.dart';

/// Who paid, how much, and who shares it.
class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({
    super.key,
    required this.billId,
    this.editingEntryId,
  });

  final String billId;

  /// The entry being corrected, or null when this is a new expense.
  ///
  /// §10.4 amends by **entry** id, not by the id the author gave the expense:
  /// the two are different strings, and an amendment naming the wrong one is
  /// `unknown_entry`.
  final String? editingEntryId;

  bool get isEditing => editingEntryId != null;

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen>
    with SplitsActions {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _form = GlobalKey<FormState>();
  String? _paidBy;

  /// What the split will be. A bare set of names is only §4.1's shape; the
  /// other four carry a figure per person.
  final SplitDraft _draft = SplitDraft(kind: SplitKind.equal);

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  /// What the total is worth as the form stands, or null while it is not a
  /// figure yet.
  int? get _total => parseMinorUnits(_amount.text, currency: _currency);

  /// The bill's currency, read once the bill is known. Its exponent is what
  /// a typed figure is scaled by (§2.1).
  String? _currency;

  /// Why the protocol will not take this split yet, or null when it will.
  ///
  /// Asked of the protocol rather than decided here: a form with its own idea
  /// of valid either refuses something §4 allows or admits something the fold
  /// would set aside.
  String? get _splitRefusal {
    final total = _total;
    if (total == null) return null;
    // A field showing text that is not a figure has left the draft holding
    // the last one that was, and a sum quoted from that names numbers
    // nobody can see.
    // Only fields on screen count: one hidden by a switch of kind, an
    // unticked person or a removed item holds nothing the draft keeps.
    _unreadable.retainAll(_shownFields);
    if (_unreadable.isNotEmpty) return 'Fix the figure that is not a number.';
    return splitRefusalSentence(_draft, total, currency: _currency!);
  }

  /// Figure fields whose text does not read as a figure, by field.
  final Set<String> _unreadable = {};

  /// The figure fields the form shows now, named as [_unreadable] names them.
  Set<String> get _shownFields => switch (_draft.kind) {
    SplitKind.equal => const {},
    SplitKind.itemized => {
      for (final item in _draft.items) itemField(item),
      'extra',
    },
    _ => {for (final id in _draft.participants) shareField(_draft.kind, id)},
  };

  void _readable(String field, bool ok) =>
      setState(() => ok ? _unreadable.remove(field) : _unreadable.add(field));

  bool _loaded = false;

  /// Fills the form from the expense being corrected.
  ///
  /// Everything, not only the figure: an amendment replaces its target
  /// wholesale, so a form opened on half the entry would submit a payload
  /// that deletes the other half.
  void _loadOnce(BillView view) {
    if (_loaded || !widget.isEditing) return;
    _loaded = true;
    final expenseId = view.expenseEntries.entries
        .where((e) => e.value == widget.editingEntryId)
        .map((e) => e.key)
        .firstOrNull;
    final current = view.bill.expenses
        .where((e) => e.id == expenseId)
        .firstOrNull;
    if (current == null) return;

    _amount.text = formatAmount(
      current.amount,
      view.bill.currency,
      withCurrency: false,
    );
    _description.text = current.description;
    _paidBy = current.paidBy;
    _loadSplit(current.split);
  }

  /// Reads a §4 payload back into the form.
  void _loadSplit(Map<String, dynamic> split) {
    Map<String, int> ints(Object? raw) => <String, int>{
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.value is int) '${entry.key}': entry.value as int,
    };

    switch (split['type']) {
      case 'exact':
        _draft.kind = SplitKind.exact;
        _draft.amounts.addAll(ints(split['amounts']));
      case 'percentage':
        _draft.kind = SplitKind.percentage;
        _draft.basisPoints.addAll(ints(split['basisPoints']));
      case 'shares':
        _draft.kind = SplitKind.shares;
        _draft.shareCounts.addAll(ints(split['shareCounts']));
      case 'itemized':
        _draft.kind = SplitKind.itemized;
        _draft.extraMinorUnits = split['extraMinorUnits'] as int? ?? 0;
        for (final raw in (split['items'] as List? ?? const [])) {
          if (raw is! Map) continue;
          _draft.items.add(
            DraftItem(
              description: '${raw['description'] ?? ''}',
              minorUnits: raw['minorUnits'] as int? ?? 0,
              sharedBy: <String>{
                for (final who in (raw['sharedBy'] as List? ?? const []))
                  '$who',
              },
            ),
          );
        }
      default:
        _draft.kind = SplitKind.equal;
        for (final who in (split['among'] as List? ?? const [])) {
          _draft.among.add('$who');
        }
    }
  }

  /// Whether an expense is being written. Set before the first await, so a
  /// second tap in the same frame writes nothing.
  bool _adding = false;

  Future<void> _add() async {
    if (_adding) return;
    if (!_form.currentState!.validate()) return;
    if (_splitRefusal != null) return;
    _adding = true;
    try {
      await _write();
    } finally {
      _adding = false;
    }
  }

  Future<void> _write() async {
    final controller = SplitsScope.read(context);
    final navigator = Navigator.of(context);

    if (widget.isEditing) {
      final edited = await act(
        () => controller.editExpense(
          billId: widget.billId,
          entryId: widget.editingEntryId!,
          paidBy: _paidBy,
          amountMinorUnits: _total!,
          split: _draft.toSplit(),
          description: _description.text.trim(),
        ),
      );
      if (!mounted) return;
      if (edited) navigator.pop();
      return;
    }

    final added = await act(
      () => controller.addExpense(
        billId: widget.billId,
        paidBy: _paidBy!,
        amountMinorUnits: _total!,
        split: _draft.toSplit(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
      ),
    );
    if (!mounted) return;
    if (added) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SplitsScope.of(context);
    final view = controller.bills
        .where((b) => b.id == widget.billId)
        .firstOrNull;
    if (view == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.isEditing ? 'Correct this expense' : 'Add expense',
          ),
        ),
        body: const Center(
          child: Text('This device no longer holds this bill.'),
        ),
      );
    }

    _paidBy ??= controller.me;
    _currency ??= view.bill.currency;
    _loadOnce(view);
    if (_draft.participants.isEmpty) {
      for (final p in view.bill.participants) {
        _draft.toggle(p.id);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Correct this expense' : 'Add expense'),
      ),
      bottomNavigationBar: BottomActions(
        children: [
          FilledButton(
            key: const Key('splits_expense_save'),
            onPressed: controller.busy || _splitRefusal != null ? null : _add,
            child: Text(widget.isEditing ? 'Save' : 'Add'),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('splits_description'),
              controller: _description,
              decoration: const InputDecoration(hintText: 'What was it for?'),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('splits_amount'),
              controller: _amount,
              decoration: InputDecoration(
                hintText: 'Amount in ${view.bill.currency}',
                errorMaxLines: fieldNoteLines,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              // Digits and one separator only. A field that accepts a minus
              // sign accepts a refund, and §4 admits one — but not typed in by
              // accident on the screen that adds a round of drinks.
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              validator: (v) {
                final units = parseMinorUnits(
                  v ?? '',
                  currency: view.bill.currency,
                );
                if (units == null) return figureRefusal(view.bill.currency);
                // §2.2: the fold sets aside an expense past the cap, so it is
                // refused here where the person can still change it.
                if (units > protocol.maxEntryAmount) {
                  return 'At most '
                      '${formatAmount(protocol.maxEntryAmount, view.bill.currency)} '
                      'in one expense';
                }
                return null;
              },
            ),
            const SectionLabel('Paid by'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in view.bill.participants)
                  ChoiceChip(
                    key: Key('splits_paid_by_${p.id}'),
                    showCheckmark: false,
                    label: _PersonLabel(
                      view.bill.displayNameOf(p.id, creatorId: view.creatorId),
                    ),
                    selected: _paidBy == p.id,
                    onSelected: (_) => setState(() => _paidBy = p.id),
                  ),
              ],
            ),
            const SectionLabel('How it splits'),
            // One scrolling row, as tall as its chips: at a large text scale a
            // chip is taller than any fixed row height, and clips.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  for (final kind in SplitKind.values)
                    ChoiceChip(
                      key: Key('splits_split_${kind.name}'),
                      label: Text(splitKindLabel(kind)),
                      selected: _draft.kind == kind,
                      onSelected: (_) => setState(() {
                        // The figures belong to the kind that asked for
                        // them: percentages are not share counts, and
                        // carrying them across would build a split nobody
                        // typed.
                        _draft.kind = kind;
                        if (_draft.participants.isEmpty) {
                          for (final p in view.bill.participants) {
                            _draft.toggle(p.id);
                          }
                        }
                      }),
                    ),
                ],
              ),
            ),
            if (_draft.kind == SplitKind.itemized)
              const SizedBox(height: 8)
            else
              SectionLabel(
                'Who shared this?',
                trailing:
                    '${_draft.participants.length} of '
                    '${view.bill.participants.length}',
              ),
            if (_draft.kind == SplitKind.itemized)
              _Items(
                draft: _draft,
                view: view,
                currency: view.bill.currency,
                onChanged: () => setState(() {}),
                onReadable: _readable,
              )
            else
              for (final p in view.bill.participants)
                // Keyed by the kind as well as the person: a figure field
                // reads its initial value once, so without this a switch from
                // exact amounts to shares keeps showing the amount typed under
                // the first kind while the draft holds the second's default,
                // and Add stores a split nobody saw.
                _Sharer(
                  key: ValueKey('${_draft.kind.name}/${p.id}'),
                  draft: _draft,
                  id: p.id,
                  name: view.bill.displayNameOf(
                    p.id,
                    creatorId: view.creatorId,
                  ),
                  currency: view.bill.currency,
                  allocated: _total == null
                      ? null
                      : _draft.allocation(_total!)?[p.id],
                  onChanged: () => setState(() {}),
                  onReadable: _readable,
                ),
            if (_splitRefusal != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _splitRefusal!,
                  key: const Key('splits_split_refusal'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      ),
    );
  }
}

/// The figure field for [id] under [kind]: a switch of kind builds a new one.
String shareField(SplitKind kind, String id) => 'share ${kind.name}/$id';

/// The cost field for [item], whatever its place in the list.
String itemField(DraftItem item) => 'item ${identityHashCode(item)}';

/// Reads a typed figure as minor units, or null when it is not one.
///
/// Integer arithmetic: the string is split on its separator and the two halves
/// are read as whole numbers. Parsing to a double first and multiplying would
/// round — `0.29 * 100` is not 29 in binary floating point — and the rounding
/// would be money.
///
/// [currency], when given, supplies the exponent from its ISO 4217 register
/// (§2.1), and a code the register gives none is refused: there is no scale at
/// which a typed figure means anything. A figure too large for a 64-bit amount
/// is refused rather than wrapped (§2.2).
int? parseMinorUnits(String text, {int exponent = 2, String? currency}) {
  if (currency != null) {
    final registered = currencyExponent(currency);
    if (registered == null) return null;
    exponent = registered;
  }
  final typed = text.trim();
  // "1,000" is a thousand to one reader and one to another, and a currency
  // with three decimals makes both readings well-formed. A comma followed by
  // exactly three digits is refused rather than guessed.
  if (RegExp(r',\d{3}$').hasMatch(typed)) return null;
  final trimmed = typed.replaceAll(',', '.');
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split('.');
  if (parts.length > 2) return null;

  final whole = parts[0].isEmpty ? '0' : parts[0];
  if (!RegExp(r'^\d+$').hasMatch(whole)) return null;

  var fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > exponent) return null;
  if (fraction.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fraction)) return null;
  fraction = fraction.padRight(exponent, '0');

  // In BigInt, then bounded: a long enough figure wraps a 64-bit product to a
  // small positive number that every later check accepts.
  final value =
      BigInt.parse(whole) * BigInt.from(10).pow(exponent) +
      (exponent == 0 ? BigInt.zero : BigInt.parse(fraction));
  if (value > BigInt.parse('9223372036854775807')) return null;
  return value.toInt();
}

/// What to tell somebody whose figure [parseMinorUnits] refused, in
/// [currency].
///
/// Names an accepted figure, and for a currency with no minor unit says why
/// no figure will do.
String figureRefusal(String currency) {
  final exponent = currencyExponent(currency);
  if (exponent == null) {
    return '$currency can’t be split here.';
  }
  final example = exponent == 0 ? '1250' : '12.${'5'.padRight(exponent, '0')}';
  return 'Enter an amount like $example';
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// One participant's place in a split that is not itemized.
///
/// A checkbox for §4.1, and a checkbox plus a figure for the other three. The
/// figure means something different in each — minor units, basis points, a
/// weight — so the label says which rather than leaving a person to guess.
class _Sharer extends StatelessWidget {
  const _Sharer({
    super.key,
    required this.draft,
    required this.id,
    required this.name,
    required this.currency,
    required this.allocated,
    required this.onChanged,
    required this.onReadable,
  });

  /// Told whether this person's figure field reads as a figure.
  final void Function(String field, bool readable) onReadable;

  final SplitDraft draft;
  final String id;
  final String name;
  final String currency;

  /// What the protocol says this person owes as the form stands, or null
  /// while the split is not yet one the protocol accepts.
  final int? allocated;

  final VoidCallback onChanged;

  bool get _sharing => draft.participants.contains(id);

  int? get _figure => switch (draft.kind) {
    SplitKind.equal || SplitKind.itemized => null,
    SplitKind.exact => draft.amounts[id],
    SplitKind.percentage => draft.basisPoints[id],
    SplitKind.shares => draft.shareCounts[id],
  };

  /// [raw] as the figure [draft.kind] stores, or null when it is not one.
  int? _parse(String raw) => switch (draft.kind) {
    SplitKind.exact => parseMinorUnits(raw, currency: currency),
    SplitKind.percentage => parseMinorUnits(raw),
    SplitKind.shares => int.tryParse(raw.trim()),
    _ => null,
  };

  /// Refuses a figure that does not parse. The draft keeps the last one that
  /// did, so a field left showing anything else would disagree with the split
  /// that is saved; the refusal also stops the form being submitted.
  String? _validate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    if (_parse(raw) != null) return null;
    return switch (draft.kind) {
      SplitKind.shares => 'Whole shares only',
      SplitKind.percentage => 'Not a percentage',
      _ => figureRefusal(currency),
    };
  }

  void _set(String raw) {
    if (raw.trim().isEmpty) {
      // A field cleared holds nothing, and neither does the split: keeping
      // the figure it last parsed saves a split the screen no longer shows.
      // The person stays in it, at zero, as the empty field says; taking
      // them out is the checkbox's job.
      onReadable(shareField(draft.kind, id), true);
      switch (draft.kind) {
        case SplitKind.exact:
          draft.amounts[id] = 0;
        case SplitKind.percentage:
          draft.basisPoints[id] = 0;
        case SplitKind.shares:
          draft.shareCounts[id] = 0;
        case SplitKind.equal || SplitKind.itemized:
          return;
      }
      onChanged();
      return;
    }
    final value = switch (draft.kind) {
      // Typed in the currency and stored in minor units, so no double ever
      // touches an amount.
      SplitKind.exact => parseMinorUnits(raw, currency: currency),
      // Typed as a percentage and stored in basis points, for the same
      // reason: 33.33 is 3333.
      SplitKind.percentage => parseMinorUnits(raw),
      SplitKind.shares => int.tryParse(raw.trim()),
      _ => null,
    };
    onReadable(shareField(draft.kind, id), value != null);
    if (value == null) return;
    switch (draft.kind) {
      case SplitKind.exact:
        draft.amounts[id] = value;
      case SplitKind.percentage:
        draft.basisPoints[id] = value;
      case SplitKind.shares:
        draft.shareCounts[id] = value;
      case SplitKind.equal || SplitKind.itemized:
        return;
    }
    onChanged();
  }

  String get _suffix => switch (draft.kind) {
    SplitKind.exact => currency,
    SplitKind.percentage => '%',
    SplitKind.shares => 'shares',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: Key('splits_sharer_$id'),
          dense: true,
          value: _sharing,
          onChanged: (_) {
            draft.toggle(id);
            onChanged();
          },
          title: Text(name),
          subtitle: allocated == null
              ? null
              : Text(formatAmount(allocated!, currency)),
        ),
        // On its own line, the row's whole width: beside the name, a figure
        // of seven characters and its unit do not fit a narrow phone at a
        // large text size, and a figure partly hidden is a figure misread.
        if (_sharing && draft.kind != SplitKind.equal)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextFormField(
              key: Key('splits_figure_$id'),
              initialValue: _initialText,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                suffixText: _suffix,
                isDense: true,
                errorMaxLines: fieldNoteLines,
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: _validate,
              onChanged: _set,
            ),
          ),
      ],
    );
  }

  /// The stored integer, written back as a person typed it.
  String get _initialText {
    final figure = _figure;
    if (figure == null) return '';
    return switch (draft.kind) {
      SplitKind.exact => formatAmount(figure, currency, withCurrency: false),
      SplitKind.percentage => formatAmount(
        figure,
        '%',
        exponent: 2,
        withCurrency: false,
      ),
      _ => '$figure',
    };
  }
}

/// A participant's name on a chip, whole.
///
/// A chip fades the end of a label that does not fit, and the end is where
/// [BillNaming.displayNameOf] puts what tells two people of one name apart:
/// so the name wraps instead, and a chip choosing between them never shows
/// the two the same.
class _PersonLabel extends StatelessWidget {
  const _PersonLabel(this.name);

  final String name;

  @override
  Widget build(BuildContext context) =>
      Text(name, softWrap: true, overflow: TextOverflow.visible);
}

/// The lines of an itemized split (§4.5), and the extra spread over them.
class _Items extends StatelessWidget {
  const _Items({
    required this.draft,
    required this.view,
    required this.currency,
    required this.onChanged,
    required this.onReadable,
  });

  final SplitDraft draft;
  final BillView view;
  final String currency;
  final VoidCallback onChanged;

  /// Told, per field, whether its text reads as a figure.
  final void Function(String field, bool readable) onReadable;

  /// Null for an empty field or a figure in [currency]; the refusal
  /// otherwise.
  String? _figure(String? raw) =>
      raw == null ||
          raw.trim().isEmpty ||
          parseMinorUnits(raw, currency: currency) != null
      ? null
      : figureRefusal(currency);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < draft.items.length; i++)
          // Keyed by the item, not its place: a field reads its initial value
          // once, so after a removal an index key would show the removed
          // item's name and cost over the next item's figures.
          Card(
            key: ObjectKey(draft.items[i]),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: Key('splits_item_name_$i'),
                          initialValue: draft.items[i].description,
                          decoration: const InputDecoration(
                            labelText: 'Item',
                            isDense: true,
                          ),
                          onChanged: (v) {
                            draft.items[i].description = v;
                            onChanged();
                          },
                        ),
                      ),
                      IconButton(
                        key: Key('splits_item_remove_$i'),
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          draft.items.removeAt(i);
                          onChanged();
                        },
                      ),
                    ],
                  ),
                  // Below the name rather than beside it, at the card's
                  // width: a fixed narrow box beside the name hides most of
                  // a figure at a large text size.
                  TextFormField(
                    key: Key('splits_item_cost_$i'),
                    initialValue: draft.items[i].minorUnits == 0
                        ? ''
                        : formatAmount(
                            draft.items[i].minorUnits,
                            currency,
                            withCurrency: false,
                          ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Cost',
                      suffixText: currency,
                      isDense: true,
                      errorMaxLines: fieldNoteLines,
                    ),
                    // What is saved is what the field shows: cleared is
                    // nothing, and text that is not a figure is refused
                    // rather than standing in for the last one that was.
                    validator: _figure,
                    onChanged: (v) {
                      final parsed = v.trim().isEmpty
                          ? 0
                          : parseMinorUnits(v, currency: currency);
                      onReadable(itemField(draft.items[i]), parsed != null);
                      if (parsed == null) return;
                      draft.items[i].minorUnits = parsed;
                      onChanged();
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final p in view.bill.participants)
                        FilterChip(
                          key: Key('splits_item_${i}_${p.id}'),
                          label: _PersonLabel(
                            view.bill.displayNameOf(
                              p.id,
                              creatorId: view.creatorId,
                            ),
                          ),
                          selected: draft.items[i].sharedBy.contains(p.id),
                          onSelected: (on) {
                            if (on) {
                              draft.items[i].sharedBy.add(p.id);
                            } else {
                              draft.items[i].sharedBy.remove(p.id);
                            }
                            onChanged();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          key: const Key('splits_item_add'),
          onPressed: () {
            draft.items.add(DraftItem());
            onChanged();
          },
          icon: const Icon(Icons.add),
          label: const Text('Add an item'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextFormField(
            key: const Key('splits_item_extra'),
            initialValue: draft.extraMinorUnits == 0
                ? ''
                : formatAmount(
                    draft.extraMinorUnits,
                    currency,
                    withCurrency: false,
                  ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Tax, tip or service',
              suffixText: currency,
              // §4.5 spreads it by what each person ate, so somebody who had
              // the cheap thing pays less of it.
              helperText: 'Split in proportion to what each person had',
              helperMaxLines: fieldNoteLines,
              errorMaxLines: fieldNoteLines,
            ),
            validator: _figure,
            onChanged: (v) {
              final parsed = v.trim().isEmpty
                  ? 0
                  : parseMinorUnits(v, currency: currency);
              onReadable('extra', parsed != null);
              if (parsed == null) return;
              draft.extraMinorUnits = parsed;
              onChanged();
            },
          ),
        ),
      ],
    );
  }
}
