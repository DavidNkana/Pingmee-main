import 'package:flutter/material.dart';
import 'package:ping_files/components/text_field_container.dart';
import 'package:ping_files/theme/colors2.dart';

class RoundedDropdownField<T> extends StatelessWidget {
  final String hintText;
  final IconData? icon;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const RoundedDropdownField({
    super.key,
    required this.hintText,
    this.icon,
    required this.items,
    required this.onChanged,
    this.value,
  });

  @override
  Widget build(BuildContext context) {
    return TextFieldContainer(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down),
          iconEnabledColor: AppColors.brandGreen,

          /// 👇 ICON ONLY IN HINT (SAFE)
          hint: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: AppColors.brandGreen),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  hintText,
                  style: const TextStyle(color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          /// 👇 SIMPLE TEXT ITEMS (NO ROWS)
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item.value,
              child: Text(
                item.child is Text
                    ? (item.child as Text).data ?? ''
                    : item.value.toString(),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),

          onChanged: onChanged,
        ),
      ),
    );
  }
}
