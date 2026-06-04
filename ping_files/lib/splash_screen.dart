import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ping_files/app_start_router.dart';

class CustomSplashScreen extends StatefulWidget {
  const CustomSplashScreen({super.key});

  @override
  State<CustomSplashScreen> createState() => _CustomSplashScreenState();
}

class _CustomSplashScreenState extends State<CustomSplashScreen> {
  Timer? _routeTimer;
  bool _showOverlayLogo = false;

  @override
  void initState() {
    super.initState();

    // Small delay so the logo softly appears on top of the splash image.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _showOverlayLogo = true);
    });

    // One splash screen only. No second slide screen.
    _routeTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AppStartRouter()),
      );
    });
  }

  @override
  void dispose() {
    _routeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Main splash image stays.
          Image.asset(
            'assets/images/splash.png',
            fit: BoxFit.cover,
          ),

          // Optional dark soft fade at the bottom so the white logo reads well.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: size.height * 0.34,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.18),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Overlay image near the bottom.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 24,
                  right: 24,
                  bottom: 32,
                ),
                child: AnimatedSlide(
                  offset: _showOverlayLogo
                      ? Offset.zero
                      : const Offset(0, 0.08),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _showOverlayLogo ? 1 : 0,
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOut,
                    child: Image.asset(
                      'assets/images/pingmee-white-new.png',
                      width: size.width * 0.90,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}