import 'package:flutter/material.dart';
import 'package:ping_files/ProfileCreation/identity_basic_screen.dart';
import 'package:ping_files/theme/colors2.dart';

class ActivationLevelZeroScreen extends StatelessWidget {
  const ActivationLevelZeroScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: AppColors.brandGreen, // Full screen brand green
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32), // 8pt grid multiple
            child: Column(
              children: [
                const SizedBox(height: 48), // top padding (8*6)

                /// 🐧 Pingoo
                Container(
                  width: 128, // multiple of 8
                  height: 128,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandGreen, // makes Pingoo pop
                    // boxShadow: [
                    //   BoxShadow(
                    //     color: Colors.black.withOpacity(.1),
                    //     blurRadius: 16,
                    //     offset: const Offset(0, 8),
                    //   ),
                    // ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Image.asset(
                      "assets/images/pingoo-white.png",
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                const SizedBox(height: 40), // space to headline

                /// 👋 Headline
                Text(
                  "Hey, I’m Pingooo 👋",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32, // round multiple
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    fontFamily: "Nunito",
                  ),
                ),

                const SizedBox(height: 24), // space to subtext

                /// 🧭 Subtext
                Text(
                  "I’ll help you set up your Pingmee profile. "
                  "A few quick steps so people get you - clearly.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.6, // slightly airy line-height
                    color: Colors.white70,
                    fontFamily: "Nunito",
                  ),
                ),

                const Spacer(), // pushes CTA to bottom

                /// 🚀 Primary CTA
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const IdentityBasicScreen(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 20), // 8*2.5
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(40),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      "Let’s get started",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandGreen,
                        fontFamily: "Nunito",
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16), // space to subtle text

                /// 👀 Subtle reassurance
                Text(
                  "You can edit everything later",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontFamily: "Nunito",
                  ),
                ),

                const SizedBox(height: 32), // bottom padding
              ],
            ),
          ),
        ),
      ),
    );
  }
}
