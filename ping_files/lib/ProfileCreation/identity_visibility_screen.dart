import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_distance_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class IdentityVisibilityScreen extends StatefulWidget {
  final String? firstName;

  const IdentityVisibilityScreen({
    super.key,
    this.firstName,
  });

  @override
  State<IdentityVisibilityScreen> createState() =>
      _IdentityVisibilityScreenState();
}

class _IdentityVisibilityScreenState extends State<IdentityVisibilityScreen> {
  String? selectedVisibility;
  bool saving = false;
  bool loading = true;
  String? pressedVisibility;
  String? profileFirstName;

  final List<Map<String, dynamic>> options = [
    {
      "value": "public",
      "icon": PhosphorIconsRegular.globeHemisphereWest,
      "title": "Public",
      "subtitle": "Anyone nearby can discover and ping you.",
    },
    {
      "value": "friends",
      "icon": PhosphorIconsRegular.usersThree,
      "title": "Friends",
      "subtitle": "Only your friends can discover and ping you.",
    },
    {
      "value": "verified",
      "icon": PhosphorIconsRegular.sealCheck,
      "title": "Verified",
      "subtitle": "Only verified people can discover and ping you.",
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadPreviousVisibility();
  }

  Future<void> _loadPreviousVisibility() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        selectedVisibility = data['visibilityMode'] as String?;

        final rawName = (widget.firstName?.trim().isNotEmpty ?? false)
            ? widget.firstName!.trim()
            : ((data['firstName'] ??
                        data['name'] ??
                        data['displayName'] ??
                        '')
                    .toString())
                .trim();

        if (rawName.isNotEmpty) {
          profileFirstName = rawName.split(RegExp(r'\s+')).first;
        }
      }
    } catch (e) {
      debugPrint("Failed to load visibility: $e");
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _selectVisibility(String value) {
    setState(() => selectedVisibility = value);
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  Future<void> _saveAndContinue() async {
    if (selectedVisibility == null) return;

    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "visibilityMode": selectedVisibility,
        "profileLevel": 4,
      }, SetOptions(merge: true));

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const IdentityDistanceScreen(),
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _headerTitle() {
    final raw = (widget.firstName?.trim().isNotEmpty ?? false)
        ? widget.firstName!.trim()
        : (profileFirstName ?? '').trim();

    if (raw.isEmpty) return "How do you want to be seen?";
    final first = raw.split(RegExp(r'\s+')).first;
    return "How do you want to be seen, $first?";
  }

  String _vibeTitle(String? mode) {
    switch (mode) {
      case "public":
        return "Public mode";
      case "friends":
        return "Friends mode";
      case "verified":
        return "Verified mode";
      default:
        return "Choose a mode";
    }
  }

  String _vibeSubtitle(String? mode) {
    switch (mode) {
      case "public":
        return "Best if you want the widest reach.";
      case "friends":
        return "Cleaner, more familiar connections.";
      case "verified":
        return "Tighter trust, less noise.";
      default:
        return "Pick one. You can change this anytime.";
    }
  }

  IconData _vibeIcon(String? mode) {
    switch (mode) {
      case "public":
        return PhosphorIconsFill.globeHemisphereWest;
      case "friends":
        return PhosphorIconsFill.usersThree;
      case "verified":
        return PhosphorIconsFill.sealCheck;
      default:
        return PhosphorIconsFill.eye;
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

    final vibeTitle = _vibeTitle(selectedVisibility);
    final vibeSubtitle = _vibeSubtitle(selectedVisibility);
    final vibeIcon = _vibeIcon(selectedVisibility);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 4, totalSteps: 10),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_four.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),

                    const SizedBox(height: 24),

                    Text(
                      _headerTitle(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),

                    const SizedBox(height: 8),

                    const Text(
                      "Pick one. You can always change this later.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 20),

                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                            color: Colors.black.withOpacity(.06),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 44,
                            decoration: BoxDecoration(
                              color: OnboardingStyle.accentLine,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          const SizedBox(width: 12),

                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: OnboardingStyle.action,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              vibeIcon,
                              color: OnboardingStyle.onAction,
                              size: 20,
                            ),
                          ),

                          const SizedBox(width: 12),

                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    vibeTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: "Nunito",
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    vibeSubtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey,
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          if (selectedVisibility != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: OnboardingStyle.action,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                "Active",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    Row(
                      children: [
                        Expanded(
                          child: Container(height: 1, color: Colors.grey.shade200),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "Choose one",
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(height: 1, color: Colors.grey.shade200),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    ...options.map((option) {
                      final String value = option['value'] as String;
                      final IconData icon = option['icon'] as IconData;
                      final bool isSelected = selectedVisibility == value;
                      final bool isPressed = pressedVisibility == value;

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: saving
                            ? null
                            : (_) => setState(() => pressedVisibility = value),
                        onTapCancel: () => setState(() => pressedVisibility = null),
                        onTapUp: (_) => setState(() => pressedVisibility = null),
                        onTap: saving ? null : () => _selectVisibility(value),
                        child: AnimatedScale(
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOut,
                          scale: isPressed ? 0.985 : 1.0,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                  color: Colors.black.withOpacity(.06),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 6,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? OnboardingStyle.accentLine
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                                const SizedBox(width: 12),

                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    color: OnboardingStyle.optionIconBackground(
                                      isSelected,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    icon,
                                    color: OnboardingStyle.optionIconForeground(
                                      isSelected,
                                    ),
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 14),

                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        option['title'] as String,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          fontFamily: "Nunito",
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        option['subtitle'] as String,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey,
                                          fontFamily: "Nunito",
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? OnboardingStyle.action
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Icon(
                                    isSelected
                                        ? PhosphorIconsBold.check
                                        : PhosphorIconsRegular.circle,
                                    size: 18,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),

                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
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
                        PhosphorIconsBold.arrowLeft,
                        color: Colors.black87,
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: (selectedVisibility == null || saving)
                          ? null
                          : _saveAndContinue,
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