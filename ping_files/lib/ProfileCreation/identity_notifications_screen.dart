import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_social_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class IdentityNotificationsScreen extends StatefulWidget {
  const IdentityNotificationsScreen({super.key});

  @override
  State<IdentityNotificationsScreen> createState() =>
      _IdentityNotificationsScreenState();
}

class _IdentityNotificationsScreenState
    extends State<IdentityNotificationsScreen> {
  final Set<String> selectedNotificationKeys = <String>{};

  bool saving = false;
  bool loading = true;
  String? pressedNotificationKey;

  static const List<Map<String, dynamic>> notificationOptions = [
    {
      "key": "general",
      "name": "General",
      "icon": PhosphorIconsRegular.megaphone,
      "subtitle": "Products and general updates.",
    },
    {
      "key": "activity",
      "name": "Activity",
      "icon": PhosphorIconsRegular.heartStraight,
      "subtitle": "Likes, interactions, updates, and activity.",
    },
    {
      "key": "requests",
      "name": "Requests",
      "icon": PhosphorIconsRegular.userPlus,
      "subtitle": "Friend requests and response alerts.",
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadPreviousNotifications();
  }

  Future<void> _loadPreviousNotifications() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (!doc.exists || doc.data() == null) return;

      final data = doc.data()!;
      final prefs = data["notificationPrefs"];

      if (prefs is Map<String, dynamic>) {
        // New structure
        if (prefs["general"] == true) selectedNotificationKeys.add("general");
        if (prefs["activity"] == true) selectedNotificationKeys.add("activity");
        if (prefs["requests"] == true) selectedNotificationKeys.add("requests");

        // Backward compatibility from older notification keys
        final bool oldGeneral = prefs["nearby_events"] == true ||
            prefs["shared_interest_users"] == true ||
            prefs["verified_users"] == true;

        final bool oldActivity = prefs["friends_activity"] == true;

        final bool oldRequests = prefs["friend_requests"] == true ||
            prefs["friend_request_accepts"] == true;

        if (oldGeneral) selectedNotificationKeys.add("general");
        if (oldActivity) selectedNotificationKeys.add("activity");
        if (oldRequests) selectedNotificationKeys.add("requests");
      } else {
        // Old string-list compatibility
        final old = List<String>.from(data["notifications"] ?? []);

        if (old.contains("General")) selectedNotificationKeys.add("general");
        if (old.contains("Activity")) selectedNotificationKeys.add("activity");
        if (old.contains("Requests")) selectedNotificationKeys.add("requests");

        if (old.contains("Events") ||
            old.contains("Shared-interest users") ||
            old.contains("Verified users")) {
          selectedNotificationKeys.add("general");
        }

        if (old.contains("Friends only")) {
          selectedNotificationKeys.add("activity");
        }

        if (old.contains("Friend requests") ||
            old.contains("Accepted requests")) {
          selectedNotificationKeys.add("requests");
        }
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _toggleNotification(String key) {
    setState(() {
      if (selectedNotificationKeys.contains(key)) {
        selectedNotificationKeys.remove(key);
      } else {
        selectedNotificationKeys.add(key);
      }
    });

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  Map<String, dynamic> _buildNotificationPrefsPayload() {
    return {
      "general": selectedNotificationKeys.contains("general"),
      "activity": selectedNotificationKeys.contains("activity"),
      "requests": selectedNotificationKeys.contains("requests"),
    };
  }

  List<String> _buildLegacyNotificationList() {
    final out = <String>[];

    if (selectedNotificationKeys.contains("general")) out.add("General");
    if (selectedNotificationKeys.contains("activity")) out.add("Activity");
    if (selectedNotificationKeys.contains("requests")) out.add("Requests");

    return out;
  }

  Future<void> _saveAndContinue() async {
    if (selectedNotificationKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pick at least 1 option to continue.")),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final prefs = _buildNotificationPrefsPayload();

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "notificationPrefs": prefs,
        "notifications": _buildLegacyNotificationList(),
        "profileLevel": 7,
        "notificationPrefsUpdatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const IdentitySocialsScreen()),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _vibeTitle(int count) {
    if (count == 0) return "Choose alerts";
    if (count == 1) return "Focused";
    if (count == 2) return "Balanced";
    return "All set";
  }

  String _vibeSubtitle(int count) {
    if (count == 0) return "Tap options to preview what you’ll get.";
    if (count == 1) return "Minimal noise. Only the key stuff.";
    if (count == 2) return "Good balance without too much clutter.";
    return "You’re fully plugged in. Adjust anytime.";
  }

  IconData _vibeIcon(int count) {
    if (count == 0) return PhosphorIconsRegular.bell;
    if (count == 1) return PhosphorIconsRegular.bellSimpleRinging;
    if (count == 2) return PhosphorIconsRegular.bellRinging;
    return PhosphorIconsBold.checkCircle;
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

    final count = selectedNotificationKeys.length;
    final vibeTitle = _vibeTitle(count);
    final vibeSubtitle = _vibeSubtitle(count);
    final vibeIcon = _vibeIcon(count);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 6, totalSteps: 10),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_six.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      "What should Pingmee notify you about?",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Pick what matters. You can change this anytime.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 22),
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "$count/${notificationOptions.length} selected • $vibeTitle",
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
                          if (count > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
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
                                  fontWeight: FontWeight.w700,
                                  fontFamily: "Nunito",
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
                          "Choose",
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
                    ...notificationOptions.map((option) {
                      final key = option["key"] as String;
                      final name = option["name"] as String;
                      final isSelected = selectedNotificationKeys.contains(key);
                      final isPressed = pressedNotificationKey == key;

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: saving
                            ? null
                            : (_) => setState(() => pressedNotificationKey = key),
                        onTapCancel: () =>
                            setState(() => pressedNotificationKey = null),
                        onTapUp: (_) =>
                            setState(() => pressedNotificationKey = null),
                        onTap: saving ? null : () => _toggleNotification(key),
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
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade100,
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
                                    option["icon"] as IconData,
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
                                        name,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          fontFamily: "Nunito",
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        option["subtitle"] as String,
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
                      onPressed:
                          (selectedNotificationKeys.isEmpty || saving)
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