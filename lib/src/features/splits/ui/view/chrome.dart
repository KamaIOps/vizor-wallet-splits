/// Layout pieces the bills screens share.
///
/// Colours come from the ambient [ThemeData] only, so a screen draws the same
/// under the wallet's theme and under a bare `MaterialApp` in a test.
library;

import 'package:flutter/material.dart';

/// How many lines a field's helper or refusal may take before it is cut.
///
/// A field's note defaults to one line, which on a narrow phone keeps only
/// its first clause. Enough for the longest note on these screens at 320
/// points wide and twice the text size.
const int fieldNoteLines = 6;

/// The actions at the foot of a screen: centred pills, the first above the
/// rest, clear of the home indicator.
class BottomActions extends StatelessWidget {
  const BottomActions({super.key, required this.children});

  final List<Widget> children;

  /// Lifted by the keyboard's height: a bottom bar is laid out against the
  /// screen's edge, so without this an open keyboard covers the action the
  /// field is being filled in for.
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [for (final c in children) Center(child: c)],
      ),
    ),
  );
}

/// A pill in the secondary style: the page colour's lighter surface, no
/// outline. The quieter of two actions sits in one of these.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.onPressed,
    required this.child,
  });

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      OutlinedButton(onPressed: onPressed, child: child);
}

/// A rounded row on the raised surface, tappable when [onTap] is given.
class RowCard extends StatelessWidget {
  const RowCard({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final Widget child;
  final VoidCallback? onTap;

  /// The fill, when the row carries a warning or an error.
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: color ?? Theme.of(context).colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

/// A row inside a [RowCard]: a title over a line of detail, a figure on the
/// right, and a chevron when the row leads somewhere.
class CardLine extends StatelessWidget {
  const CardLine({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.chevron = false,
    this.leading,
  });

  final String title;
  final Widget? subtitle;
  final String? trailing;
  final bool chevron;
  final Widget? leading;

  /// The narrowest a title is squeezed to beside a figure that needs the room.
  static const double _titleFloor = 48;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) => _row(context, text, scheme, box.maxWidth),
    );
  }

  Widget _row(
    BuildContext context,
    TextTheme text,
    ColorScheme scheme,
    double width,
  ) {
    final figure = trailing;
    final style = DefaultTextStyle.of(context).style.merge(text.bodyLarge);
    var scaler = MediaQuery.textScalerOf(context);
    var cap = width * 0.45;
    if (figure != null) {
      // The box is never narrower than the figure's widest word, so the
      // line breaks between words and never inside the digits; the title
      // wraps instead. A word wider than the row allows is drawn smaller.
      // The leading widget and the chevron are 24-wide icons.
      final room =
          width -
          (leading != null ? 36 : 0) -
          12 -
          (chevron ? 28 : 0) -
          _titleFloor;
      final direction = Directionality.of(context);
      var widest = _widestWord(figure, style, scaler, direction);
      if (widest > room && room > 0) {
        // Re-measured after each step: letter spacing does not scale with
        // the text, so one proportional step can leave the word too wide.
        final size = style.fontSize ?? 14;
        for (var i = 0; i < 4 && widest > room; i++) {
          final shown = scaler.scale(size) * room / widest;
          scaler = TextScaler.linear(shown / size);
          widest = _widestWord(figure, style, scaler, direction);
        }
        cap = room;
      } else if (widest > cap) {
        cap = widest;
      }
    }
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: text.bodyMedium),
              if (subtitle != null)
                DefaultTextStyle.merge(
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  child: subtitle!,
                ),
            ],
          ),
        ),
        // At its own width against the right edge, and no more than 45% of
        // the row unless its figure needs more: a figure that cannot shrink
        // otherwise crushes the name beside it to a letter a line.
        if (figure != null) ...[
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cap),
            child: Text(
              figure,
              style: text.bodyLarge,
              textAlign: TextAlign.end,
              textScaler: scaler,
            ),
          ),
        ],
        if (chevron) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right),
        ],
      ],
    );
  }
}

/// The width of the widest space-separated word of [line], as drawn.
double _widestWord(
  String line,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  var widest = 0.0;
  for (final word in line.split(' ')) {
    if (word.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    // Rounded up: a box exactly as wide as the word can still wrap it on
    // a fractional pixel.
    if (painter.width.ceilToDouble() + 1 > widest) {
      widest = painter.width.ceilToDouble() + 1;
    }
    painter.dispose();
  }
  return widest;
}

/// [text] on as many lines as it needs, broken between words and never
/// inside one.
///
/// A word wider than the line, as a long figure is at a large text size on a
/// narrow phone, would otherwise be broken inside its digits. The whole text
/// is drawn smaller until its widest word fits instead.
class WholeWords extends StatelessWidget {
  const WholeWords(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final drawn = DefaultTextStyle.of(context).style.merge(style);
      final direction = Directionality.of(context);
      var scaler = MediaQuery.textScalerOf(context);
      var widest = _widestWord(text, drawn, scaler, direction);
      final room = box.maxWidth;
      if (room.isFinite && room > 0 && widest > room) {
        // Re-measured after each step: letter spacing does not scale with
        // the text, so one proportional step can leave the word too wide.
        final size = drawn.fontSize ?? 14;
        for (var i = 0; i < 4 && widest > room; i++) {
          final shown = scaler.scale(size) * room / widest;
          scaler = TextScaler.linear(shown / size);
          widest = _widestWord(text, drawn, scaler, direction);
        }
      }
      return Text(text, style: style, textScaler: scaler);
    },
  );
}

/// A heading over a group, in the secondary text colour, with an optional
/// figure at the other end.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: style)),
          if (trailing != null) Text(trailing!, style: style),
        ],
      ),
    );
  }
}

/// One choice of several, drawn as a pill that is outlined when chosen.
///
/// Announced as a selected button, which is what a radio row would have
/// said.
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: scheme.surfaceContainerLowest,
          shape: StadiumBorder(
            side: selected
                ? BorderSide(color: scheme.onSurface, width: 1.5)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A message on the raised surface, tinted for a warning or an error.
class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RowCard(
      color: error ? scheme.errorContainer : null,
      child: Text(
        message,
        style: TextStyle(color: error ? scheme.onErrorContainer : null),
      ),
    );
  }
}
