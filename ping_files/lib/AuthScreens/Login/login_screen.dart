import 'package:flutter/material.dart';
import 'package:ping_files/AuthScreens/Login/components/login_body.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LoginBody(), // ✅ correct usage
    );
  }
}
