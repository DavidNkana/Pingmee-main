import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ping_files/theme/colors2.dart';
import 'text_field_container.dart';

class RoundedInputField extends StatelessWidget {
  final String hintText;
  final String? labelText;
  final IconData? icon;
  final Color? iconColor;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final List<String>? autofillHints;
  final TextInputType keyboardType;
  final bool enabled;
  final int maxLines;
  final List<TextInputFormatter>? inputFormatters;

  /// Counter settings
  final int? counterLimit;
  final bool countWords;

  const RoundedInputField({
    super.key,
    required this.hintText,
    this.labelText,
    this.icon,
    this.iconColor,
    this.onChanged,
    this.controller,
    this.autofillHints,
    this.keyboardType = TextInputType.text,
    this.enabled = true,
    this.maxLines = 1,
    this.inputFormatters,
    this.counterLimit,
    this.countWords = false,
  });

  int _countValue(String text) {
    if (!countWords) return text.length;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }

  Widget _buildHeaderRow(BuildContext context, int count) {
    final hasLabel = labelText != null && labelText!.trim().isNotEmpty;
    final hasCounter = counterLimit != null;

    if (!hasLabel && !hasCounter) return const SizedBox.shrink();

    final counterText = hasCounter
        ? countWords
            ? '$count/$counterLimit words'
            : '$count/$counterLimit'
        : null;

    final counterColor = (hasCounter && count > counterLimit!)
        ? Colors.red
        : Colors.grey.shade600;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: hasLabel
                ? Text(
                    labelText!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          if (hasCounter)
            Text(
              counterText!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: counterColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final hasLabel = labelText != null && labelText!.trim().isNotEmpty;
    final hasCounter = counterLimit != null;

    if (!hasLabel && !hasCounter) {
      return const SizedBox.shrink();
    }

    if (controller == null) {
      return _buildHeaderRow(context, 0);
    }

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller!,
      builder: (context, value, _) {
        return _buildHeaderRow(context, _countValue(value.text));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        TextFieldContainer(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            enabled: enabled,
            maxLines: maxLines,
            keyboardType: keyboardType,
            autofillHints: autofillHints,
            inputFormatters: inputFormatters,
            cursorColor: AppColors.brandGreen,
            decoration: InputDecoration(
              prefixIcon: icon != null
                  ? Icon(
                      icon,
                      color: iconColor ??
                          (enabled ? AppColors.brandGreen : Colors.grey),
                    )
                  : null,
              hintText: hintText,
              border: InputBorder.none,
            ),
          ),
        ),
      ],
    );
  }
}