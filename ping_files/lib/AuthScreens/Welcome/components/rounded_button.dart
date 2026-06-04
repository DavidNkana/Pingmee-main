// components/rounded_button.dart
import 'package:flutter/material.dart';
// for AppColors

class RoundedButton extends StatelessWidget {
  final String text;
  final VoidCallback? press;
  final Color color;
  final Color textColor;

  const RoundedButton({
    super.key,
    required this.text,
    required this.press,
    this.color = Colors.black,
    this.textColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    Size size = MediaQuery.of(context).size;
    return Container(
      margin: EdgeInsets.symmetric(vertical: 8),
      width: size.width * 0.8,
      child: TextButton(
        onPressed: press,
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(vertical: 15),
          backgroundColor: color,
          foregroundColor: textColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(29),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            height: 1.4,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
