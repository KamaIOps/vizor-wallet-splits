/// How this wallet reads a bill: naming, and who opened it.
///
/// None of this is a rule two wallets must agree on — every permission on a
/// bill is decided by participant id, and nothing here feeds into that — so it
/// stays out of the protocol and lives with the app that renders it.
library;

import 'package:splitz_core/splitz_core.dart' as protocol;

import 'currency_exponents.dart';

extension BillNaming on protocol.Bill {
  /// A participant's name, made unambiguous when more than one answers to it.
  ///
  /// A display name is chosen by whoever joins and can be chosen twice — by two
  /// friends both called Ana, or by somebody who read the invite and picked a
  /// name already on the bill. A collision cannot move money. What it can do is
  /// make the record of who did what unreadable, which is where the record's
  /// whole value is.
  ///
  /// Only a colliding name is qualified, so the ordinary case stays plain.
  String displayNameOf(String id, {String? creatorId}) {
    final person = participant(id);
    if (person == null) return shortId(id);
    final name = person.name.isEmpty ? shortId(id) : person.name;
    if (participants.where((p) => p.name == person.name).length < 2) {
      return name;
    }
    // The one who opened the bill is named as the organiser rather than by a
    // fragment of an id, because that is the half a reader can act on. Eight
    // characters otherwise: a key's id is a digest (§10.7), and matching
    // eight of its characters takes 2^48 tries where four take 2^24.
    return id == creatorId
        ? '$name (organiser)'
        : '$name (${shortId(id, length: 8)})';
  }

  /// Every display name more than one participant answers to, in order.
  List<String> get sharedNames {
    final seen = <String>{};
    final shared = <String>{};
    for (final p in participants) {
      if (p.name.isEmpty) continue;
      if (!seen.add(p.name)) shared.add(p.name);
    }
    return shared.toList()..sort();
  }

  /// The tail of an id, for a reader who needs to tell two apart.
  static String shortId(String id, {int length = 4}) =>
      id.length <= length + 2 ? id : '…${id.substring(id.length - length)}';
}

/// Renders [minorUnits] of [currency] as a figure a person reads.
///
/// Integer arithmetic throughout. The protocol's amounts are minor units and
/// no floating point touches one: a double cannot hold every cent of a large
/// bill exactly, and the rounding it would introduce is money.
/// With [withCurrency] false the code is left off, which is what an input
/// field wants: the figure goes back through `parseMinorUnits`, and that
/// reads digits rather than a rendered label.
///
/// [exponent] defaults to [currency]'s ISO 4217 exponent. A code the register
/// gives none (§2.1) is shown as the count of minor units it is, never scaled
/// by a guess.
String formatAmount(
  int minorUnits,
  String currency, {
  int? exponent,
  bool withCurrency = true,
}) {
  final negative = minorUnits < 0;
  // Negated as a BigInt: the smallest 64-bit value has no positive twin.
  final magnitude = BigInt.from(minorUnits).abs();
  final suffix = withCurrency ? ' $currency' : '';
  final scaleBy = exponent ?? currencyExponent(currency);
  if (scaleBy == null) {
    return '${negative ? '-' : ''}$magnitude minor units$suffix';
  }
  if (scaleBy == 0) return '${negative ? '-' : ''}$magnitude$suffix';
  final exponentUsed = scaleBy;
  final scale = BigInt.from(10).pow(exponentUsed);
  final whole = magnitude ~/ scale;
  final fraction = (magnitude % scale).toString().padLeft(exponentUsed, '0');
  return '${negative ? '-' : ''}$whole.$fraction$suffix';
}

/// [base] units of a token with [decimals] places, as whole tokens.
///
/// By string arithmetic: a base-unit figure for an 18- or 24-decimal token
/// passes 2^63, and a double would round it. A figure that is not a plain
/// run of digits is shown as it came, labelled as base units.
String formatBaseUnits(String base, int decimals) {
  if (!RegExp(r'^[0-9]+$').hasMatch(base)) return '$base base units';
  final digits = base.replaceFirst(RegExp(r'^0+(?=.)'), '');
  if (decimals == 0) return digits;
  final padded = digits.padLeft(decimals + 1, '0');
  final whole = padded.substring(0, padded.length - decimals);
  final fraction = padded
      .substring(padded.length - decimals)
      .replaceAll(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}
