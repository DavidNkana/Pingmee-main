import 'package:flutter/material.dart';
import 'package:ping_files/components/text_field_container.dart';
import 'package:ping_files/theme/colors2.dart';

class RoundedAgeField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool enabled;

  const RoundedAgeField({
    super.key,
    required this.controller,
    this.hintText = "Age",
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextFieldContainer(
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        cursorColor: AppColors.brandGreen,
        decoration: InputDecoration(
          hintText: hintText,
          border: InputBorder.none,
        ),
      ),
    );
  }
}
