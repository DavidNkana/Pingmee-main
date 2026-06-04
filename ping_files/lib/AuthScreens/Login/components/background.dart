import 'package:flutter/material.dart';

class Background extends StatelessWidget {
  final Widget child; // Accept any widget, not just Column

  const Background({super.key, required this.child}); // Fix constructor syntax

  @override
  Widget build(BuildContext context) {
    Size size = MediaQuery.of(context).size;

    return SizedBox(
      width: double.infinity,
      height: size.height,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            top: 0,
            left: 0,
            child: Image.asset(
              "assets/images/main-top.png",
              width: size.width * 0.35,
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Image.asset(
              "assets/images/main-bottom.png",
              width: size.width * 0.3,
            ),
          ),
          child, // <----- Add this line to show the login form content
        ],
      ),
    );
  }
}
