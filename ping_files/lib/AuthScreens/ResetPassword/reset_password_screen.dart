import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:lottie/lottie.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/AuthScreens/Welcome/components/rounded_button.dart';
import 'package:ping_files/components/rounded_input_field.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController emailController = TextEditingController();
  bool isLoading = false;
  String? message;
  Color messageColor = Colors.green;

  Future<void> _sendResetLink() async {
    FocusScope.of(context).unfocus();
    final email = emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        messageColor = Colors.redAccent;
        message = "⚠️ Please enter your email address.";
      });
      return;
    }

    setState(() {
      isLoading = true;
      message = null;
    });

    try {
      final resetSettings = ActionCodeSettings(
        url: 'https://pingmee-password-reset.netlify.app/',
        handleCodeInApp: true,
        androidInstallApp: true,
      );

      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: email,
        actionCodeSettings: resetSettings,
      );


      setState(() {
        messageColor = Colors.green;
        message =
            "✅ Password reset link sent!\nCheck your inbox to reset your password.";
      });
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'invalid-email':
          message = "⚠️ Please enter a valid email address.";
          messageColor = Colors.redAccent;
          break;
        case 'user-not-found':
          message = "⚠️ No user found with that email.";
          messageColor = Colors.redAccent;
          break;
        case 'network-request-failed':
          message = "⚠️ Network error. Please check your connection.";
          messageColor = Colors.orangeAccent;
          break;
        default:
          message = "⚠️ Something went wrong. Please try again.";
          messageColor = Colors.redAccent;
      }
    } finally {
      setState(() => isLoading = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.white,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              children: [
                const SizedBox(height: 8),
                const Text(
                  "Forgot your password?",
                  style: TextStyle(
                    fontSize: 22,
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    color: AppColors.heading,
                ),
              ),
              const SizedBox(height: 12),
                const Text(
                  "Enter your email and we’ll send you a link to reset your password.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.darkGray,
                    fontSize: 14,
                    fontFamily: 'Poppins',
                  ),
                ),
                const SizedBox(height: 32),

                // 🌀 Lottie animation
                Lottie.asset(
                  'assets/images/forgot.json',
                  height: size.height * 0.3,
                ),
                const SizedBox(height: 32),

                // 📧 Email field
                RoundedInputField(
                  controller: emailController,
                  hintText: "Enter your email",
                  icon: Icons.email_outlined,
                  onChanged: (_) {},
                ),

                const SizedBox(height: 20),

                // 🔔 Message display
                AnimatedOpacity(
                  opacity: message != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: message == null
                      ? const SizedBox.shrink()
                      : Text(
                          message!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: messageColor,
                            fontSize: 14,
                            fontFamily: 'Poppins',
                            height: 1.3,
                          ),
                        ),
                ),

                const SizedBox(height: 24),

                // 🚀 Send reset link button
                RoundedButton(
                  text: isLoading ? "Sending..." : "Send Reset Link",
                  press: isLoading ? null : _sendResetLink,
                ),

                const SizedBox(height: 24),

                // ⬅️ Back to login
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "Back to Login",
                    style: TextStyle(
                      color: AppColors.brandGreen,
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
