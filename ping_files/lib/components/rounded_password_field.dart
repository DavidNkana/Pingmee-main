import 'package:flutter/material.dart';
import 'package:ping_files/components/text_field_container.dart';
import 'package:ping_files/theme/colors2.dart';

class RoundedPasswordField extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final List<String>? autofillHints;

  const RoundedPasswordField({
    super.key,
    required this.onChanged,
    this.controller,
    this.autofillHints,
  });

  @override
  State<RoundedPasswordField> createState() => _RoundedPasswordFieldState();
}

class _RoundedPasswordFieldState extends State<RoundedPasswordField> {
  bool _obscureText = true;

  void _toggleVisibility() {
    setState(() {
      _obscureText = !_obscureText;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextFieldContainer(
      child: TextField(
        controller: widget.controller,
        obscureText: _obscureText,
        keyboardType: TextInputType.visiblePassword,
        autofillHints: widget.autofillHints,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          icon: Icon(Icons.lock, color: AppColors.brandGreen),
          hintText: "Password",
          border: InputBorder.none,
          suffixIcon: IconButton(
            icon: Icon(
              _obscureText ? Icons.visibility : Icons.visibility_off,
              color: AppColors.brandGreen,
            ),
            onPressed: _toggleVisibility,
          ),
        ),
      ),
    );
  }
}
