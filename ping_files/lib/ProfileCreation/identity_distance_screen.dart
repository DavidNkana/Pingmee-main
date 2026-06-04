
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ping_files/ProfileCreation/identity_notifications_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class IdentityDistanceScreen extends StatefulWidget {
  const IdentityDistanceScreen({super.key});

  @override
  State<IdentityDistanceScreen> createState() => _IdentityDistanceScreenState();
}

class _IdentityDistanceScreenState extends State<IdentityDistanceScreen> {
  bool saving = false;
  bool loading = true;

  // miles (1..310) ~ 500km max
  static const int minMiles = 1;
  static const int maxMiles = 310;

  double _miles = 10; // default

  @override
  void initState() {
    super.initState();
    _loadPreviousDistance();
  }

  Future<void> _loadPreviousDistance() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final savedMiles = data['distanceMiles'];
        if (savedMiles != null) {
          final int m = (savedMiles as num).toInt();
          _miles = m.clamp(minMiles, maxMiles).toDouble();
        }
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _labelForMiles(int miles) {
    if (miles <= 3) return "Very close";
    if (miles <= 10) return "Nearby";
    if (miles <= 25) return "City-wide";
    if (miles <= 60) return "Regional";
    if (miles <= 120) return "Long-range";
    return "Explorer";
  }

  Future<void> _saveAndContinue() async {
    setState(() => saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final int miles = _miles.round();

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "distanceMiles": miles, // ✅ correct value

        // ✅ delete legacy keys that might be stuck at 100
        "distancePreference": FieldValue.delete(),
        "distanceRange": FieldValue.delete(),
        "distance": FieldValue.delete(),
        "distanceMeters": FieldValue.delete(),
        "maxDistance": FieldValue.delete(),
        "radius": FieldValue.delete(),
        "radiusMeters": FieldValue.delete(),

        "profileLevel": 6,
      }, SetOptions(merge: true));


      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const IdentityNotificationsScreen()),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(OnboardingStyle.progress),
          ),
        ),
      );
    }

    final int milesInt = _miles.round();
    final String vibe = _labelForMiles(milesInt);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 5, totalSteps: 10),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // Pingoo
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_five.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(height: 16),

                    const Text(
                      "How far should your pings reach?",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),

                    const Text(
                      "Slide to set your discovery range. You can change this anytime.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                      ),
                    ),

                    const SizedBox(height: 26),

                    // ✅ Big live value card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.radar_rounded,
                              color: OnboardingStyle.action,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "$milesInt miles",
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    fontFamily: "Nunito",
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  vibe,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey,
                                    fontFamily: "Nunito",
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 26),

                    // ✅ Slider with floating bubble
                    _BubbleSlider(
                      value: _miles,
                      min: minMiles.toDouble(),
                      max: maxMiles.toDouble(),
                      label: "$milesInt mi",
                      onChanged: saving
                          ? null
                          : (v) {
                              setState(() => _miles = v);
                            },
                    ),

                    const SizedBox(height: 12),

                    Text(
                      "Max range: $maxMiles miles (~500 km)",
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                      ),
                    ),

                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),

            /// ✅ NEW PREMIUM BUTTON BAR
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
                  // ✅ Previous icon circle
                  GestureDetector(
                    onTap: saving ? null : () => Navigator.pop(context),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                            color: Colors.black.withOpacity(.06),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.black87,
                        size: 22,
                      ),
                    ),
                  ),

                  const SizedBox(width: 14),

                  // ✅ Next button longer
                  Expanded(
                    child: ElevatedButton(
                      onPressed: saving ? null : _saveAndContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(40),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        saving ? "Saving..." : "Next",
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slider with floating bubble tooltip above thumb
class _BubbleSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double>? onChanged;

  const _BubbleSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final double t = ((value - min) / (max - min)).clamp(0.0, 1.0);

    // Bubble positioning
    final double screenW = MediaQuery.of(context).size.width;
    final double sliderW = screenW - 48; // padding (24*2)
    final double bubbleW = 64;

    final double left = (t * sliderW) - (bubbleW / 2);
    final double clampedLeft = left.clamp(0.0, sliderW - bubbleW);

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: clampedLeft,
                top: 0,
                child: Container(
                  width: bubbleW,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                        color: Colors.black.withOpacity(.10),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontFamily: "Nunito",
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),

        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 10,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
            activeTrackColor: AppColors.brandGreen,
            inactiveTrackColor: Colors.grey.shade200,
            thumbColor: AppColors.brandGreen,
            overlayColor: AppColors.brandGreen.withOpacity(.12),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).toInt(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
