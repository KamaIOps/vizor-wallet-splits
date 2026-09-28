/// Layout pieces the bills screens share.
///
/// Colours come from the ambient [ThemeData] only, so a screen draws the same
/// under the wallet's theme and under a bare `MaterialApp` in a test.
library;

import 'package:flutter/material.dart';

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
  const SecondaryButton({super.key, required this.onPressed, required this.child});

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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: text.bodyLarge),
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
        // Flexible, and sharing the row with the title: a figure that cannot
        // shrink crushes the name beside it to a letter a line and is clipped
        // itself at a large text size.
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              trailing!,
              style: text.bodyLarge,
              textAlign: TextAlign.end,
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

/// A heading over a group, in the secondary text colour, with an optional
/// figure at the other end.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(
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
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
