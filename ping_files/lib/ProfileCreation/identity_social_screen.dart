import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_permissions_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class IdentitySocialsScreen extends StatefulWidget {
  const IdentitySocialsScreen({super.key});

  @override
  State<IdentitySocialsScreen> createState() => _IdentitySocialsScreenState();
}

class _IdentitySocialsScreenState extends State<IdentitySocialsScreen> {
  bool saving = false;
  bool loading = true;

  String? pressedPlatform;

  final List<String> platforms = [
    "Instagram",
    "TikTok",
    "X",
    "LinkedIn",
    "Facebook",
    "Threads",
    "Website",
  ];

  final Map<String, IconData> platformIcons = {
    "Instagram": FontAwesomeIcons.instagram,
    "TikTok": FontAwesomeIcons.tiktok,
    "X": FontAwesomeIcons.xTwitter,
    "LinkedIn": FontAwesomeIcons.linkedin,
    "Facebook": FontAwesomeIcons.facebook,
    "Threads": FontAwesomeIcons.threads,
    "Website": FontAwesomeIcons.globe,
  };

  final Map<String, String> usernames = {};
  final Map<String, String> urls = {};
  final Map<String, bool> visibility = {};

  @override
  void initState() {
    super.initState();
    _loadPreviousSocials();
  }

  Future<void> _loadPreviousSocials() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data()?['socials'] != null) {
        final socials = Map<String, dynamic>.from(doc['socials']);
        socials.forEach((platform, data) {
          usernames[platform] = (data['handle'] ?? '').toString();
          urls[platform] = (data['url'] ?? '').toString();
          visibility[platform] = (data['visible'] ?? true) as bool;
        });
      }

      for (final p in platforms) {
        usernames[p] ??= '';
        urls[p] ??= '';
        visibility[p] ??= true;
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _saveAndContinue() async {
    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final Map<String, dynamic> socialsToSave = {};

      for (final platform in platforms) {
        final rawHandle = (usernames[platform] ?? '').trim();
        final rawUrl = (urls[platform] ?? '').trim();

        if (platform == "Website") {
          if (rawUrl.isEmpty) continue;

          socialsToSave[platform] = {
            "handle": rawHandle,
            "url": rawUrl,
            "visible": visibility[platform] ?? true,
          };
          continue;
        }

        if (rawHandle.isEmpty) continue;

        final handle = rawHandle.startsWith('@') ? rawHandle : '@$rawHandle';

        socialsToSave[platform] = {
          "handle": handle,
          "url": rawUrl,
          "visible": visibility[platform] ?? true,
        };
      }

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "socials": socialsToSave,
        "profileLevel": 7,
      }, SetOptions(merge: true));

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const IdentityPermissionsScreen()),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _skipAndContinue() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    await FirebaseFirestore.instance.collection("users").doc(uid).set({
      "profileLevel": 7,
    }, SetOptions(merge: true));

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const IdentityPermissionsScreen()),
    );
  }

  int get _connectedCount => platforms
      .where((p) => _hasValueForPlatform(p))
      .length;

  bool _hasValueForPlatform(String platform) {
    if (platform == "Website") {
      return (urls[platform] ?? '').trim().isNotEmpty;
    }
    return (usernames[platform] ?? '').trim().isNotEmpty;
  }

  String _vibeTitle() {
    if (_connectedCount == 0) return "No socials yet";
    if (_connectedCount == 1) return "1 social connected";
    return "$_connectedCount socials connected";
  }

  String _vibeSubtitle() {
    if (_connectedCount == 0) return "Optional — but it helps people find you.";
    return "Each card opens its own editor.";
  }

  IconData _vibeIcon() {
    if (_connectedCount == 0) return PhosphorIconsRegular.linkSimpleHorizontal;
    return PhosphorIconsBold.checkCircle;
  }

  String _platformHelper(String platform) {
    switch (platform) {
      case "Instagram":
        return "Add your handle or profile link.";
      case "TikTok":
        return "Let people find your content fast.";
      case "X":
        return "Share your handle or profile link.";
      case "LinkedIn":
        return "Useful for more professional connections.";
      case "Facebook":
        return "Add your profile if you still use it.";
      case "Threads":
        return "Connect your Threads profile.";
      case "Website":
        return "Add your personal site or portfolio.";
      default:
        return "Add your social details.";
    }
  }

  String _platformPreview(String platform) {
    if (platform == "Website") {
      final value = (urls[platform] ?? '').trim();
      return value.isEmpty ? "No website added" : value;
    }

    final handle = (usernames[platform] ?? '').trim();
    if (handle.isEmpty) return "No handle added";
    return handle.startsWith('@') ? handle : '@$handle';
  }

  void _openSocialPopup(String platform) {
    final usernameCtrl = TextEditingController(text: usernames[platform]);
    final urlCtrl = TextEditingController(text: urls[platform]);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              left: 24,
              right: 24,
              top: 18,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        platformIcons[platform],
                        color: OnboardingStyle.action,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "Edit $platform",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          fontFamily: "Nunito",
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(PhosphorIconsBold.x),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                if (platform != "Website") ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Username",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: usernameCtrl,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      hintText: "@yourhandle",
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: OnboardingStyle.action,
                          width: 1.2,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    platform == "Website" ? "Website URL" : "Link (optional)",
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: platform == "Website"
                        ? "https://yourwebsite.com"
                        : "https://",
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: OnboardingStyle.action,
                        width: 1.2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        usernames[platform] = usernameCtrl.text.trim();
                        urls[platform] = urlCtrl.text.trim();
                      });
                      Navigator.pop(context);
                      try {
                        HapticFeedback.selectionClick();
                      } catch (_) {}
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: OnboardingStyle.action,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(40),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      "Save",
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                TextButton(
                  onPressed: () {
                    setState(() {
                      usernames[platform] = '';
                      urls[platform] = '';
                    });
                    Navigator.pop(context);
                  },
                  child: Text(
                    "Remove from profile",
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleVisibility(String platform) {
    setState(() {
      visibility[platform] = !(visibility[platform] ?? true);
    });
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  Widget _actionPill({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    required bool filled,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: filled ? OnboardingStyle.action : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: filled
              ? null
              : Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: filled ? Colors.white : OnboardingStyle.action,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontFamily: "Nunito",
                fontWeight: FontWeight.w800,
                color: filled ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _socialCard(String platform) {
    final bool hasValue = _hasValueForPlatform(platform);
    final bool isVisible = visibility[platform] ?? true;
    final bool isPressed = pressedPlatform == platform;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: saving ? null : (_) => setState(() => pressedPlatform = platform),
      onTapCancel: () => setState(() => pressedPlatform = null),
      onTapUp: (_) => setState(() => pressedPlatform = null),
      onTap: saving ? null : () => _openSocialPopup(platform),
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
            color: hasValue ? Colors.white : const Color(0xFFFDFDFD),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: hasValue
                  ? Colors.black.withOpacity(.08)
                  : Colors.grey.shade200,
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.05),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: hasValue
                          ? Colors.black.withOpacity(.08)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      platformIcons[platform],
                      color: OnboardingStyle.action,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          platform,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            fontFamily: "Nunito",
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _platformHelper(platform),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasValue)
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
                        "Added",
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

              const SizedBox(height: 14),
              Container(height: 1, color: Colors.grey.shade200),
              const SizedBox(height: 14),

              Row(
                children: [
                  _actionPill(
                    label: hasValue ? "Edit" : "Add",
                    icon: hasValue
                        ? PhosphorIconsRegular.pencilSimple
                        : PhosphorIconsRegular.plus,
                    onTap: saving ? () {} : () => _openSocialPopup(platform),
                    filled: true,
                  ),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: saving ? null : () => _toggleVisibility(platform),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: isVisible ? OnboardingStyle.action : Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: isVisible
                            ? null
                            : Border.all(color: Colors.grey.shade200),
                      ),
                      child: Icon(
                        isVisible
                            ? PhosphorIconsRegular.eye
                            : PhosphorIconsRegular.eyeSlash,
                        size: 18,
                        color: isVisible ? Colors.white : Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _platformPreview(platform),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: hasValue ? Colors.black87 : Colors.grey.shade500,
                    fontFamily: "Nunito",
                    fontWeight: hasValue ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    final vibeTitle = _vibeTitle();
    final vibeSubtitle = _vibeSubtitle();
    final vibeIcon = _vibeIcon();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 7, totalSteps: 10),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_seven.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 24),

                    const Text(
                      "Add socials (optional)",
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
                      "Help people recognize you outside Pingmee.",
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
                                  vibeTitle,
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
                          if (_connectedCount > 0)
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
                                "Ready",
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
                          "Tap a card to edit",
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

                    ...platforms.map(_socialCard),

                    const SizedBox(height: 90),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: TextButton(
                onPressed: saving ? null : _skipAndContinue,
                child: Text(
                  "Skip for now",
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                  ),
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