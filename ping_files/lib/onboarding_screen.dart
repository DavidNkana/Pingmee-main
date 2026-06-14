import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ping_files/AuthScreens/Login/components/background.dart';
import 'package:ping_files/AuthScreens/Welcome/welcome_screen.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RoundedProgressPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color backgroundColor;
  final Color progressColor;

  _RoundedProgressPainter({
    required this.progress,
    required this.strokeWidth,
    required this.backgroundColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - strokeWidth / 2;

    final backgroundPaint =
        Paint()
          ..color = backgroundColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;

    final progressPaint =
        Paint()
          ..color = progressColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);

    final sweepAngle = 2 * 3.141592653589793 * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.141592653589793 / 2,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RoundedProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.progressColor != progressColor;
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  static const double _horizontalPadding = 24;
  static const double _topContentPadding = 32;
  static const double _bottomButtonSize = 80;
  static const double _bottomButtonBottomOffset = 32;
  static const double _bottomReservedGap = 32;
  static const double _skipTopOffset = 12;

  final List<Map<String, String>> _pages = [
    {
      'image': 'assets/pinglogo.png',
      'title': 'Welcome! 👋',
      'subtitle': 'Meet people, not profiles. Experience real connections.',
    },
    {
      'image': 'assets/intro_1.png',
      'title': 'Feel the Vibe Around You',
      'subtitle':
          'Ping nearby users in real time from anywhere. Discover who’s vibing.',
    },
    {
      'image': 'assets/intro_2.png',
      'title': 'No Numbers. No Pressure.',
      'subtitle': 'Meet and chat freely. You’re in control.',
    },
    {
      'image': 'assets/intro_3.png',
      'title': 'Ping. Share. Repeat.',
      'subtitle':
          'Start real chats and share experiences with real people. Tap to begin!',
    },
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('seen_onboarding', true);

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
    );
  }

  void _onNext() {
    if (_currentPage < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finishOnboarding();
    }
  }

  double _mediaHeight(double availableHeight) {
    // Clamp so it looks good on both short and tall devices.
    return math.max(180, math.min(availableHeight * 0.30, 300));
  }

  Widget _buildMedia(Map<String, String> page, double height) {
    return Image.asset(
      page['image']!,
      height: height,
      fit: BoxFit.contain,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    // Real reserved space so content never sits under the circular next button.
    final reservedBottomSpace =
        _bottomButtonBottomOffset +
        _bottomButtonSize +
        _bottomReservedGap +
        bottomInset;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.white,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: Background(
            child: Stack(
              children: [
                Positioned.fill(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _pages.length,
                    onPageChanged: (index) {
                      setState(() => _currentPage = index);
                    },
                    itemBuilder: (_, index) {
                      final page = _pages[index];

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final mediaHeight = _mediaHeight(constraints.maxHeight);

                          return SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  _horizontalPadding,
                                  _topContentPadding + 28,
                                  _horizontalPadding,
                                  reservedBottomSpace,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      height: mediaHeight,
                                      child: Center(
                                        child: _buildMedia(page, mediaHeight),
                                      ),
                                    ),
                                    const SizedBox(height: 28),

                                    Text(
                                      page['title']!,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontFamily: 'Poppins',
                                        fontSize: 26,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                        height: 1.3,
                                      ),
                                    ),
                                    const SizedBox(height: 14),

                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 420,
                                      ),
                                      child: Text(
                                        page['subtitle']!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontFamily: 'Poppins',
                                          fontSize: 16,
                                          fontWeight: FontWeight.w300,
                                          color: Colors.black54,
                                          height: 1.55,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                Positioned(
                  top: _skipTopOffset,
                  right: 16,
                  child: TextButton(
                    onPressed: _finishOnboarding,
                    child: const Text(
                      'Skip',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.black54,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),

                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _bottomButtonBottomOffset,
                  child: Center(
                    child: SizedBox(
                      width: _bottomButtonSize,
                      height: _bottomButtonSize,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: _bottomButtonSize,
                            height: _bottomButtonSize,
                            child: CustomPaint(
                              painter: _RoundedProgressPainter(
                                progress: (_currentPage + 1) / _pages.length,
                                strokeWidth: 3,
                                backgroundColor: Colors.grey.shade200,
                                // Round progress bar — switched to
                                // black (was AppColors.brandGreen) so
                                // the round button + ring read as a
                                // single dark unit, matching the
                                // search/feed "Connect" button family.
                                progressColor: Colors.black,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _onNext,
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              // Round button with the arrow-forward
                              // icon. Switched to black (was
                              // AppColors.brandGreen) per the
                              // onboarding redesign — the round
                              // button + circular progress bar
                              // now read as a single dark unit.
                              decoration: const BoxDecoration(
                                color: Colors.black,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_forward_ios,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}