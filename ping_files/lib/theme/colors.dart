import 'package:flutter/material.dart';

class AppColors {
  // 🔸 Primary Brand Colors
  static const Color orange = Color(
    0xFFFC9E4F,
  ); // Vibrant Orange (primary action)
  static const Color magenta = Color(0xFFFF3CAC); // Magenta (secondary brand)
  static const Color purple = Color(
    0xFF784BA0,
  ); // Purple (used in gradients, accents)

  // 🔹 Gradients
  static const LinearGradient logoGradient = LinearGradient(
    colors: [magenta, purple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // 🟡 Accents and Neutrals
  static const Color peach = Color(0xFFFFD6A5); // Light background accent
  static const Color lightPink = Color(0xFFFFB5E8); // Optional subtle accent
  static const Color lightPeach = Color(0xFFFDE9E4); // Background from image

  // ⚪ Text Colors
  static const Color heading = Color(0xFF111111);
  static const Color body = Color(0xFF5F5F5F);
  static const Color caption = Color(0xFF9E9E9E);

  // ⚫ Backgrounds
  static const Color background = Color(0xFFF9F9F9); // App background
  static const Color backgroundWhite = Color(0xFFFFFFFF); // White background
  static const Color card = Color(
    0xFFFFFFFF,
  ); // Card background (can be same as white)

  // 🟩 Input Fields & UI Components
  static const Color inputFill = Color(0xFFF1F1F1); // Input field background
  static const Color inputBorder = Color(0xFFE0E0E0); // Input field border
  static const Color inputText = Color(0xFF333333); // Input text color
  static const Color cardShadow = Color(0x1A000000); // Light shadow for cards

  // 🔲 Utility Colors
  static const Color border = Color(0xFFE0E0E0);
  static const Color shadow = Colors.black26;
  static const Color overlay = Color.fromRGBO(0, 0, 0, 0.3);

  // ✅ Status Colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFC107);
  static const Color error = Color(0xFFF44336);
}
