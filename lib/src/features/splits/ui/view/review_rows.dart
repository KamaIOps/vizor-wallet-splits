/// Rows of the send review a settlement is paid from, in the wallet's review
/// vocabulary.
library;

import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/review_info_row.dart';
import '../../../../core/widgets/review_list_row.dart';
import 'chrome.dart' show WholeWords;

/// One "Review Info" row — leading slot, small label, serif value, bottom
/// line — drawn with [ReviewInfoRow]'s tokens and at least its height, and
/// taller when what it carries needs the room.
///
/// [ReviewInfoRow] pins its height and its slots and cuts its value and
/// bottom line to one line each, which ellipsizes an amount, a name or an
/// address on a narrow phone or at a large text size. §14.2 requires every
/// output's amount, its payee and at least the first ten characters of its
/// address on the page the payer confirms.
class ReviewFitRow extends StatelessWidget {
  const ReviewFitRow({
    super.key,
    required this.label,
    required this.value,
    required this.leading,
    this.oneLine = false,
    this.bottom,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  });

  /// Small secondary label above the value ("Amount", "To").
  final String label;

  /// The serif headline value.
  final String value;

  /// 32×32 leading slot: the coin image or an avatar.
  final Widget leading;

  /// Keeps [value] on one line, drawn smaller until it fits: an amount, whose
  /// digits are never broken across lines. Otherwise the value wraps between
  /// words and is drawn smaller only when one word is wider than the row.
  final bool oneLine;

  /// The line under the value: a fiat figure or an address.
  final String? bottom;

  /// The ghost action beside or under [bottom]; omitted when null.
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final valueStyle = appSerifDisplayStyle(color: colors.text.accent);
    final secondary = AppTypography.labelSmall.copyWith(
      color: colors.text.secondary,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: ReviewInfoRow.height),
      child: Row(
        children: [
          SizedBox(
            width: AppAssetSize.size,
            height: AppAssetSize.size,
            child: leading,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AppSpacing.md),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(label, style: secondary),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                if (oneLine)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(value, maxLines: 1, style: valueStyle),
                  )
                else
                  WholeWords(_tailsJoined(value), style: valueStyle),
                if (bottom != null || actionLabel != null) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  // The action moves under the line when both do not fit
                  // beside each other, rather than cutting the line.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xxs,
                    children: [
                      if (bottom case final line?)
                        WholeWords(line, style: secondary),
                      if (actionLabel case final action?)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: AppButton(
                            key: actionKey,
                            onPressed: onAction,
                            variant: AppButtonVariant.ghost,
                            size: AppButtonSize.small,
                            growWithContent: true,
                            iconGap: 0,
                            leading: AppIcon(
                              AppIcons.eye,
                              color: colors.button.ghost.label,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xxs,
                              ),
                              child: Text(
                                action,
                                style: AppTypography.labelLarge,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// [text] with a word joiner after each ellipsis that runs into the next
/// character.
///
/// A line may break after an ellipsis, which splits the id's tail of a
/// same-name qualifier (`Priyanka (…aaaaaa01)`) across two lines. The joiner
/// draws nothing.
String _tailsJoined(String text) =>
    text.replaceAllMapped(RegExp(r'…(?=\S)'), (_) => '…\u2060');

/// A line the payer is warned by on the review: the warning glyph and the
/// sentence beside it, in the review's small type.
class ReviewNote extends StatelessWidget {
  const ReviewNote(
    this.message, {
    super.key,
    this.warning = true,
    this.iconName = AppIcons.warning,
    this.textKey,
  });

  final String message;

  /// Key on the sentence's [Text], so a test reads it as a line of text.
  final Key? textKey;

  /// Drawn in the warning colour; otherwise in the secondary text colour, for
  /// a fact the payer is told without alarm.
  final bool warning;

  final String iconName;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppTypography.bodySmall.copyWith(
      color: warning ? colors.text.warning : colors.text.secondary,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: AppIcon(
            iconName,
            size: AppIconSize.medium,
            color: style.color,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(message, key: textKey, style: style),
        ),
      ],
    );
  }
}

/// [child] with its text drawn no larger than [maxScale] times its size, and
/// never held below the size the person chose when that is under 1.
///
/// For the wallet's review pieces whose height is pinned: past the scale
/// their pinned box holds, their text is cut rather than grown.
class ReviewTextScaleCap extends StatelessWidget {
  const ReviewTextScaleCap({
    super.key,
    required this.maxScale,
    required this.child,
  });

  final double maxScale;
  final Widget child;

  /// What a [ReviewListRow] holds: its pinned row less the 4-point inset
  /// above and below its text, over its text's line height; at least 1.
  static double get listRow => _atLeastOne(
    (ReviewListRow.height - 2 * AppSpacing.xxs) /
        _line(AppTypography.bodyMediumStrong),
  );

  /// What a large [AppButton] holds: its pinned pill less the 8-point inset
  /// above and below and the primary pill's border, over its label's line
  /// height; at least 1.
  static double get largeButton => _atLeastOne(
    (AppButtonSizing.largeHeight - 2 * AppSpacing.xs - 4) /
        _line(AppTypography.labelLarge),
  );

  static double _line(TextStyle style) => style.fontSize! * style.height!;

  static double _atLeastOne(double scale) => scale < 1 ? 1 : scale;

  @override
  Widget build(BuildContext context) =>
      MediaQuery.withClampedTextScaling(maxScaleFactor: maxScale, child: child);
}
