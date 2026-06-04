import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:ping_files/AuthScreens/Login/login_screen.dart';
import 'package:ping_files/AuthScreens/Signup/signup_screen.dart';
import 'package:ping_files/AuthScreens/Login/components/background.dart';
import 'package:ping_files/theme/colors2.dart'; // Spotify green palette
import 'package:ping_files/AuthScreens/Welcome/components/rounded_button.dart';

class Body extends StatelessWidget {
  const Body({super.key});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: AppColors.backgroundWhite,
      body: Background(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 64),

              // Lottie Animation
              Lottie.asset(
                'assets/images/welcome.json',
                height: size.height * 0.35,
                fit: BoxFit.contain,
              ),

              const SizedBox(height: 24),

              // Friendly Welcome Text
              const Text(
                "We're glad you're here.\nLet's get you connected.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: AppColors.body,
                  height: 1.6,
                ),
              ),

              const SizedBox(height: 48),

              // Login Button
              RoundedButton(
                text: "Log In",
                color: Colors.black,
                textColor: Colors.white,
                press: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                },
              ),

              const SizedBox(height: 16),

              // Sign Up Button
              RoundedButton(
                text: "Register",
                color: AppColors.inputFill,
                textColor: AppColors.black,
                press: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SignupScreen()),
                  );
                },
              ),

              const SizedBox(height: 64),
            ],
          ),
        ),
      ),
    );
  }
}
