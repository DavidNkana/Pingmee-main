import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';

class ProfileProgressBar extends StatelessWidget {
  final int step;       // 1-based
  final int totalSteps; // e.g. 8

  const ProfileProgressBar({
    super.key,
    required this.step,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    final clampedStep = step.clamp(1, totalSteps);
    final progress = clampedStep / totalSteps;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Colors.grey.shade200,
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              // The round progress bar fill. Switched to a
            // black-on-black gradient (was the brand green)
            // so the bar reads as a single dark unit, matching
            // the round "Next" button in the main onboarding
            // flow.
            gradient: LinearGradient(
                colors: [
                  Colors.black,
                  Colors.black.withOpacity(.6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
