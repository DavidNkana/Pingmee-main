import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';

enum ProfileAvatarExpression {
  classic,
  wink,
  soft,
  playful,
  glasses,
  laugh,
  cool,
  surprised,
}

class ProfileAvatarSelection {
  final ProfileAvatarExpression expression;
  final Color backgroundColor;

  const ProfileAvatarSelection({
    required this.expression,
    required this.backgroundColor,
  });
}

const List<Color> kProfileAvatarColors = [
  Color(0xFF3B82F6),
  Color(0xFFEF4444),
  Color(0xFF38BDF8),
  Color(0xFFF59E0B),
  Color(0xFF22C55E),
  Color(0xFFEC4899),
  Color(0xFF8B5CF6),
  Color(0xFF14B8A6),
];

const List<ProfileAvatarExpression> kProfileAvatarExpressions = [
  ProfileAvatarExpression.classic,
  ProfileAvatarExpression.wink,
  ProfileAvatarExpression.soft,
  ProfileAvatarExpression.playful,
  ProfileAvatarExpression.glasses,
  ProfileAvatarExpression.laugh,
  ProfileAvatarExpression.cool,
  ProfileAvatarExpression.surprised,
];

Future<ProfileAvatarSelection?> showProfileAvatarPickerSheet(
  BuildContext context, {
  ProfileAvatarSelection? initial,
}) {
  ProfileAvatarExpression selectedExpression =
      initial?.expression ?? ProfileAvatarExpression.classic;
  Color selectedColor = initial?.backgroundColor ?? kProfileAvatarColors.first;

  String label(ProfileAvatarExpression expression) {
    switch (expression) {
      case ProfileAvatarExpression.classic:
        return "Classic";
      case ProfileAvatarExpression.wink:
        return "Wink";
      case ProfileAvatarExpression.soft:
        return "Soft";
      case ProfileAvatarExpression.playful:
        return "Playful";
      case ProfileAvatarExpression.glasses:
        return "Glasses";
      case ProfileAvatarExpression.laugh:
        return "Laugh";
      case ProfileAvatarExpression.cool:
        return "Cool";
      case ProfileAvatarExpression.surprised:
        return "Surprised";
    }
  }

  return showModalBottomSheet<ProfileAvatarSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final screenHeight = MediaQuery.of(sheetContext).size.height;
      final maxSheetHeight = screenHeight * 0.84;

      return SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                child: Container(
                  width: double.infinity,
                  constraints: BoxConstraints(
                    maxHeight: maxSheetHeight,
                  ),
                  color: Colors.white,
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          "Choose avatar",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          "Pick a color, then tap a face to use it.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          child: Column(
                            children: [
                              Container(
                                width: 132,
                                height: 132,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: selectedColor,
                                ),
                                child: CustomPaint(
                                  painter: PingmeeAvatarPainter(
                                    expression: selectedExpression,
                                    strokeColor: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                height: 64,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: kProfileAvatarColors.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(width: 12),
                                  itemBuilder: (_, index) {
                                    final color = kProfileAvatarColors[index];
                                    final isSelected =
                                        selectedColor.value == color.value;

                                    return GestureDetector(
                                      onTap: () {
                                        setModalState(() {
                                          selectedColor = color;
                                        });
                                      },
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 180),
                                        width: 64,
                                        height: 64,
                                        decoration: BoxDecoration(
                                          color: color,
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color: isSelected
                                                ? AppColors.brandGreen
                                                : Colors.transparent,
                                            width: 3,
                                          ),
                                        ),
                                        child: isSelected
                                            ? const Icon(
                                                Icons.check_rounded,
                                                color: Colors.white,
                                                size: 28,
                                              )
                                            : null,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 20),
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: kProfileAvatarExpressions.length,
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 1.02,
                                ),
                                itemBuilder: (_, index) {
                                  final expression =
                                      kProfileAvatarExpressions[index];
                                  final isSelected =
                                      selectedExpression == expression;

                                  return GestureDetector(
                                    onTap: () {
                                      setModalState(() {
                                        selectedExpression = expression;
                                      });

                                      Navigator.pop(
                                        sheetContext,
                                        ProfileAvatarSelection(
                                          expression: expression,
                                          backgroundColor: selectedColor,
                                        ),
                                      );
                                    },
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF25272B),
                                        borderRadius:
                                            BorderRadius.circular(18),
                                        border: Border.all(
                                          color: isSelected
                                              ? AppColors.brandGreen
                                              : Colors.transparent,
                                          width: 3,
                                        ),
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Expanded(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.all(18),
                                              child: CustomPaint(
                                                painter: PingmeeAvatarPainter(
                                                  expression: expression,
                                                  strokeColor: Colors.white,
                                                ),
                                                child: const SizedBox.expand(),
                                              ),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 12,
                                            ),
                                            child: Text(
                                              label(expression),
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontFamily: "Nunito",
                                                fontWeight: FontWeight.w800,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

Future<Uint8List> renderProfileAvatarPng(
  ProfileAvatarSelection selection, {
  int size = 1024,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
  );

  final bgPaint = Paint()
    ..color = selection.backgroundColor
    ..style = PaintingStyle.fill;

  canvas.drawCircle(
    Offset(size / 2, size / 2),
    size / 2,
    bgPaint,
  );

  final painter = PingmeeAvatarPainter(
    expression: selection.expression,
    strokeColor: Colors.white,
  );
  painter.paint(canvas, Size(size.toDouble(), size.toDouble()));

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

  return byteData!.buffer.asUint8List();
}

class PingmeeAvatarPainter extends CustomPainter {
  final ProfileAvatarExpression expression;
  final Color strokeColor;

  PingmeeAvatarPainter({
    required this.expression,
    required this.strokeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double stroke = w * 0.055;

    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.fill;

    final leftEye = Offset(w * 0.36, h * 0.38);
    final rightEye = Offset(w * 0.64, h * 0.38);
    final mouthRect = Rect.fromCenter(
      center: Offset(w * 0.5, h * 0.60),
      width: w * 0.34,
      height: h * 0.22,
    );

    void drawEyeDot(Offset center, {double rFactor = 0.04}) {
      canvas.drawCircle(center, w * rFactor, fillPaint);
    }

    void drawWink(Offset start, bool leftToRight) {
      final dx = w * 0.05;
      canvas.drawLine(
        Offset(start.dx - dx, start.dy),
        Offset(start.dx + dx, start.dy + (leftToRight ? dx * 0.2 : -dx * 0.2)),
        strokePaint,
      );
    }

    void drawSmile({double start = 0.20, double sweep = 2.75}) {
      canvas.drawArc(mouthRect, start, sweep, false, strokePaint);
    }

    void drawOpenMouth() {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.5, h * 0.62),
          width: w * 0.11,
          height: h * 0.15,
        ),
        strokePaint,
      );
    }

    void drawGlasses() {
      final r = w * 0.08;
      canvas.drawCircle(leftEye, r, strokePaint);
      canvas.drawCircle(rightEye, r, strokePaint);
      canvas.drawLine(
        Offset(leftEye.dx + r, leftEye.dy),
        Offset(rightEye.dx - r, rightEye.dy),
        strokePaint,
      );
      canvas.drawLine(
        Offset(leftEye.dx - r, leftEye.dy - r * 0.1),
        Offset(leftEye.dx - r * 1.8, leftEye.dy - r * 0.4),
        strokePaint,
      );
      canvas.drawLine(
        Offset(rightEye.dx + r, rightEye.dy - r * 0.1),
        Offset(rightEye.dx + r * 1.8, rightEye.dy - r * 0.4),
        strokePaint,
      );
    }

    void drawBrows({bool playful = false, bool angry = false}) {
      final browWidth = w * 0.10;
      final browY = h * 0.23;

      canvas.drawLine(
        Offset(leftEye.dx - browWidth * 0.5, browY + (angry ? w * 0.02 : 0)),
        Offset(leftEye.dx + browWidth * 0.5, browY + (playful ? -w * 0.02 : 0)),
        strokePaint,
      );

      canvas.drawLine(
        Offset(rightEye.dx - browWidth * 0.5, browY + (playful ? -w * 0.02 : 0)),
        Offset(rightEye.dx + browWidth * 0.5, browY + (angry ? w * 0.02 : 0)),
        strokePaint,
      );
    }

    switch (expression) {
      case ProfileAvatarExpression.classic:
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawSmile();
        break;

      case ProfileAvatarExpression.wink:
        drawEyeDot(leftEye);
        drawWink(rightEye, true);
        drawSmile();
        break;

      case ProfileAvatarExpression.soft:
        canvas.drawArc(
          Rect.fromCenter(center: leftEye, width: w * 0.10, height: h * 0.07),
          3.3,
          2.2,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(center: rightEye, width: w * 0.10, height: h * 0.07),
          3.3,
          2.2,
          false,
          strokePaint,
        );
        drawSmile(start: 0.28, sweep: 2.55);
        break;

      case ProfileAvatarExpression.playful:
        drawBrows(playful: true);
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawSmile(start: 0.20, sweep: 2.8);
        break;

      case ProfileAvatarExpression.glasses:
        drawGlasses();
        drawSmile(start: 0.22, sweep: 2.75);
        break;

      case ProfileAvatarExpression.laugh:
        canvas.drawArc(
          Rect.fromCenter(center: leftEye, width: w * 0.10, height: h * 0.07),
          3.25,
          2.0,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(center: rightEye, width: w * 0.10, height: h * 0.07),
          3.25,
          2.0,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(
            center: Offset(w * 0.5, h * 0.60),
            width: w * 0.22,
            height: h * 0.18,
          ),
          0.1,
          3.0,
          false,
          strokePaint,
        );
        break;

      case ProfileAvatarExpression.cool:
        canvas.drawLine(
          Offset(w * 0.27, h * 0.35),
          Offset(w * 0.45, h * 0.35),
          strokePaint,
        );
        canvas.drawLine(
          Offset(w * 0.55, h * 0.35),
          Offset(w * 0.73, h * 0.35),
          strokePaint,
        );
        canvas.drawLine(
          Offset(w * 0.45, h * 0.35),
          Offset(w * 0.55, h * 0.35),
          strokePaint,
        );
        drawSmile(start: 0.18, sweep: 2.65);
        break;

      case ProfileAvatarExpression.surprised:
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawOpenMouth();
        break;
    }
  }

  @override
  bool shouldRepaint(covariant PingmeeAvatarPainter oldDelegate) {
    return oldDelegate.expression != expression ||
        oldDelegate.strokeColor != strokeColor;
  }
}