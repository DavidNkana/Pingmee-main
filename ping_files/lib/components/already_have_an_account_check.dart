import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';

class AlreadyHaveAnAccountCheck extends StatelessWidget {
  final bool login;
  final VoidCallback onPress;

  const AlreadyHaveAnAccountCheck({
    super.key,
    this.login = true,
    required this.onPress,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          login ? "Don't have an account? " : "Already have an account? ",
          style: TextStyle(color: AppColors.brandGreen),
        ),
        GestureDetector(
          onTap: onPress,
          child: Text(
            login ? "Sign Up" : "Login",
            style: const TextStyle(
              color: AppColors.brandGreen,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
