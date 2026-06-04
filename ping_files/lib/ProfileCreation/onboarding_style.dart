import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';

/// Shared tokens for profile onboarding.
/// Green is reserved for progress bars and vertical accent lines only.
abstract final class OnboardingStyle {
  static const Color progress = AppColors.brandGreen;
  static const Color accentLine = AppColors.brandGreen;
  static const Color action = Colors.black;
  static const Color onAction = Colors.white;

  static Color optionIconBackground(bool selected) =>
      selected ? action : Colors.white;

  static Color optionIconForeground(bool selected) =>
      selected ? onAction : action;
}
