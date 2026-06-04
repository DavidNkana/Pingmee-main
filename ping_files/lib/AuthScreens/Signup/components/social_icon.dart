import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ping_files/theme/colors2.dart';

class SocialIcon extends StatelessWidget {
  final String iconSrc;
  final VoidCallback? onPressed;

  const SocialIcon({super.key, required this.iconSrc, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(width: 2, color: AppColors.border),
          shape: BoxShape.circle,
        ),
        height: 60,
        width: 60,
        child: SvgPicture.asset(
          iconSrc,
          color: AppColors.brandGreen, // 🍑 Peach color
        ),
      ),
    );
  }
}
