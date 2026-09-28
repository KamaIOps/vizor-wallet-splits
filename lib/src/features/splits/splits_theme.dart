/// The bills screens in this wallet's own design.
///
/// The screens under `ui/` are built from stock Material widgets, so one
/// [ThemeData] drawn from the wallet's tokens gives every one of them the
/// wallet's look: centred serif titles, pill buttons, and white rounded
/// fields and cards on the window background. Light and dark both follow
/// [AppColors], so switching the wallet's theme switches these too.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// [base] restyled with the wallet's tokens.
ThemeData splitsTheme(ThemeData base, AppColors c) {
  final primary = c.button.primary;
  final secondary = c.button.secondary;
  final disabled = c.button.disabled;
  const pill = StadiumBorder();
  const pillPadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: AppSpacing.s,
  );
  const minSize = Size(64, AppButtonSizing.largeHeight);
  final label = AppTypography.labelLarge;
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadii.large),
  );
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadii.medium),
    borderSide: BorderSide.none,
  );

  final text = base.textTheme
      .apply(
        fontFamily: AppTypography.bodyMedium.fontFamily,
        bodyColor: c.text.primary,
        displayColor: c.text.primary,
      )
      .copyWith(
        titleLarge: AppTypography.headlineSmall.copyWith(
          color: c.text.primary,
        ),
        titleMedium: AppTypography.labelLarge.copyWith(color: c.text.primary),
        titleSmall: AppTypography.labelLarge.copyWith(
          color: c.text.secondary,
        ),
        bodyLarge: AppTypography.bodyLarge.copyWith(color: c.text.primary),
        bodyMedium: AppTypography.bodyMedium.copyWith(color: c.text.primary),
        bodySmall: AppTypography.bodySmall.copyWith(color: c.text.secondary),
      );

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: c.background.window,
    canvasColor: c.background.window,
    colorScheme: base.colorScheme.copyWith(
      primary: primary.bg,
      onPrimary: primary.label,
      secondary: primary.bg,
      onSecondary: primary.label,
      surface: c.background.window,
      onSurface: c.text.primary,
      onSurfaceVariant: c.text.secondary,
      surfaceContainerLowest: c.background.ground,
      surfaceContainerLow: c.background.ground,
      surfaceContainer: c.background.ground,
      surfaceContainerHigh: c.background.ground,
      surfaceContainerHighest: c.background.ground,
      outline: c.border.regular,
      outlineVariant: c.border.subtle,
      error: c.text.destructive,
      errorContainer: c.background.utilityDestructiveSubtle,
      // The tint carries the alarm; the text stays at body contrast.
      onErrorContainer: c.text.primary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background.window,
      foregroundColor: c.text.primary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: AppTypography.headlineLarge.copyWith(
        color: c.text.primary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary.bg,
        foregroundColor: primary.label,
        disabledBackgroundColor: disabled.bg,
        disabledForegroundColor: disabled.label,
        shape: pill,
        padding: pillPadding,
        minimumSize: minSize,
        textStyle: label,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: secondary.bg,
        foregroundColor: secondary.label,
        side: BorderSide.none,
        shape: pill,
        padding: pillPadding,
        minimumSize: minSize,
        textStyle: label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.text.primary,
        shape: pill,
        textStyle: label,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary.bg,
      foregroundColor: primary.label,
      elevation: 0,
      highlightElevation: 0,
      shape: pill,
      extendedTextStyle: label,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.icon.regular),
    ),
    cardTheme: CardThemeData(
      color: c.background.ground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      shape: rounded,
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: AppTypography.labelLarge.copyWith(color: c.text.primary),
      subtitleTextStyle: AppTypography.bodyMedium.copyWith(
        color: c.text.secondary,
      ),
      leadingAndTrailingTextStyle: AppTypography.bodyMedium.copyWith(
        color: c.text.primary,
      ),
      iconColor: c.icon.regular,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.background.ground,
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(
        borderSide: BorderSide(color: c.border.strong, width: 1.5),
      ),
      errorBorder: field.copyWith(
        borderSide: BorderSide(color: c.border.utilityDestructive),
      ),
      focusedErrorBorder: field.copyWith(
        borderSide: BorderSide(color: c.border.utilityDestructive, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      hintStyle: AppTypography.bodyMedium.copyWith(color: c.text.muted),
      labelStyle: AppTypography.bodyMedium.copyWith(color: c.text.secondary),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.background.ground,
      selectedColor: primary.bg,
      secondarySelectedColor: primary.bg,
      checkmarkColor: primary.label,
      // Resolved by state (chip.dart resolves the label colour), so a
      // selected FilterChip reads on the dark fill as a ChoiceChip does.
      labelStyle: AppTypography.bodyMedium.copyWith(
        color: WidgetStateColor.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? primary.label
              : c.text.primary,
        ),
      ),
      secondaryLabelStyle: AppTypography.bodyMedium.copyWith(
        color: primary.label,
      ),
      side: BorderSide.none,
      shape: pill,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.xs,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? primary.bg : null,
      ),
      checkColor: WidgetStatePropertyAll(primary.label),
    ),
    dividerTheme: DividerThemeData(color: c.border.subtle, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: c.background.ground,
      surfaceTintColor: Colors.transparent,
      shape: rounded,
      titleTextStyle: AppTypography.headlineSmall.copyWith(
        color: c.text.primary,
      ),
      contentTextStyle: AppTypography.bodyMedium.copyWith(
        color: c.text.secondary,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.background.inverse,
      contentTextStyle: AppTypography.bodyMedium.copyWith(
        color: c.text.inverse,
      ),
      shape: rounded,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary.bg),
  );
}
