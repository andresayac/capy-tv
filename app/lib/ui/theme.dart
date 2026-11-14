import 'package:flutter/material.dart';

/// Design tokens. The identity is strictly monochrome: pure black, near-black surfaces,
/// white type and actions. The only hue is functional (the red "live" dot and errors);
/// colour comes from the artwork, never from the chrome.
///
/// Flat, with one exception: a fade to black over artwork and video (the hero, a title's page,
/// Continue watching, the player's controls), only black and only there, so the text over it reads
/// on any poster. Nothing else has a gradient, nor glass; the TV's app keeps to the same rule.
abstract final class AppColors {
  static const black = Color(0xFF000000); // app background
  static const surface = Color(0xFF111111); // cards, rows
  static const surfaceHigh = Color(0xFF1E1E1E); // inputs, secondary buttons, sheets
  static const stroke = Color(0xFF2A2A2A); // hairlines
  static const text = Color(0xFFFFFFFF);
  static const muted = Color(0xFFA3A3A3);
  static const subtle = Color(0xFF8A8A8A); // 6:1 on black, 4.8:1 on surfaceHigh (AA)
  static const scrim = Color(0xD9000000); // controls over video: dark enough on bright footage
  static const live = Color(0xFFE5322D); // dots and lines
  static const errorText = Color(0xFFFF7A75); // what went wrong, in words: 8:1 on black, 6.6:1 on surfaceHigh (AA)
}

abstract final class AppRadius {
  static const button = 8.0;
  static const card = 10.0;
  static const panel = 14.0;
  static const pill = 999.0;
}

const appFont = 'Inter';

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    primary: AppColors.text,
    onPrimary: AppColors.black,
    secondary: AppColors.surfaceHigh,
    onSecondary: AppColors.text,
    surface: AppColors.black,
    onSurface: AppColors.text,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.stroke,
    error: AppColors.errorText,
  );
  final base = ThemeData(brightness: Brightness.dark, colorScheme: scheme, fontFamily: appFont, useMaterial3: true);
  // Remote and keyboard focus gets the same white ring as cards (see Focusable); never after a touch
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused) && FocusManager.instance.highlightMode == FocusHighlightMode.traditional
        ? const BorderSide(color: AppColors.text, width: 2)
        : null,
  );
  final text = base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text);
  // Tight, heavy headings; neutral body
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.black,
    focusColor: const Color(0x33FFFFFF),
    canvasColor: AppColors.black,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.4, height: 1.05),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.0),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      bodyLarge: text.bodyLarge?.copyWith(height: 1.5),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.black,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: appFont,
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        color: AppColors.text,
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.stroke, thickness: 1, space: 1),
    // What an icon alone does, beside it: plain, in the app's black and white
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.stroke),
      ),
      textStyle: const TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w600),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      labelStyle: const TextStyle(color: AppColors.muted),
      hintStyle: const TextStyle(color: AppColors.subtle),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.button), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.text, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.panel)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.panel))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.text,
      contentTextStyle: const TextStyle(fontFamily: appFont, color: AppColors.black, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.button)),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: AppColors.text,
      thumbColor: AppColors.text,
      inactiveTrackColor: Color(0x40FFFFFF),
      secondaryActiveTrackColor: Color(0x80FFFFFF),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.text),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.text).copyWith(side: focusRing),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.text).copyWith(side: focusRing),
    ),
    splashFactory: InkRipple.splashFactory,
  );
}
