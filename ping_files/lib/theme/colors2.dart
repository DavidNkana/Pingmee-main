import 'package:flutter/material.dart';

class AppColors {
  // Brand Color (default event theme green)
  static const Color brandGreen = Color(0xFF16C784);

  // Neutral Base Colors
  static const Color black = Color(0xFF111111);
  static const Color darkGray = Color(0xFF3C3C3C);
  static const Color mediumGray = Color(0xFF7A7A7A);
  static const Color lightGray = Color(0xFFE0E0E0);
  static const Color backgroundWhite = Color(0xFFFFFFFF);

  // UI Element Colors
  static const Color inputFill = Color(0xFFF5F5F5);
  static const Color inputBorder = lightGray;
  static const Color inputText = black;

  // Text Styles
  static const Color heading = black;
  static const Color body = darkGray;
  static const Color caption = mediumGray;

  // Cards and Surfaces
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardShadow = Color(0x1A000000);

  // Utility
  static const Color shadow = Colors.black26;
  static const Color overlay = Color.fromRGBO(0, 0, 0, 0.3);
  static const Color border = lightGray;

  // Status Colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFC107);
  static const Color error = Color(0xFFF44336);

  // Shims so the restructured code still compiles
  static Color get scaffold => const Color(0xFFEFF2F7);
  static Color get surfaceAlt => const Color(0xFFF7F8FA);
  static Color get textHighEmphasis => Colors.black87;
  static Color get textMediumEmphasis => Colors.black54;
  static Color get textLowEmphasis => Colors.black38;
  static Color get iconActive => Colors.black.withOpacity(.84);
  static Color get iconInactive => Colors.black.withOpacity(.35);
  static Color get surfaceBorder => Colors.black.withOpacity(.06);
  static Color get surfaceBorderAlt => Colors.black.withOpacity(.10);
  static Color get frostedSheetBg => Colors.white.withOpacity(.92);
  static Color get frostedBarBg => const Color(0xFFF8FAFC).withOpacity(.92);
  static Color get frostedBarBorder => const Color(0xFFD8E1EA);
  static Color get glassSheetBg => Colors.white.withOpacity(.92);
  static Color get glassSheetBorder => Colors.white.withOpacity(.65);
  static Color onBackground(double opacity) => Colors.black.withOpacity(opacity);
}
