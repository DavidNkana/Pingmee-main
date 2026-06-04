import 'package:flutter/material.dart';

class ProfileCreation extends StatelessWidget {
  final String email;

  const ProfileCreation({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile Creation")),
      body: Center(
        child: Text(
          "Welcome $email",
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
