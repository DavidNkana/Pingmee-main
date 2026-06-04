import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ping_files/main_app/main_app_shell.dart';

import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

import 'package:ping_files/ProfileCreation/identity_basic_screen.dart';
import 'package:ping_files/ProfileCreation/identity_interests_screen.dart';
import 'package:ping_files/ProfileCreation/identity_skills_screen.dart';
import 'package:ping_files/ProfileCreation/identity_visibility_screen.dart';
import 'package:ping_files/ProfileCreation/identity_distance_screen.dart';
import 'package:ping_files/ProfileCreation/identity_notifications_screen.dart';
import 'package:ping_files/ProfileCreation/identity_social_screen.dart';
import 'package:ping_files/ProfileCreation/identity_permissions_screen.dart';
import 'package:ping_files/ProfileCreation/identity_profile_photo_screen.dart';

class IdentityFinalReviewScreen extends StatefulWidget {
  const IdentityFinalReviewScreen({super.key});

  @override
  State<IdentityFinalReviewScreen> createState() =>
      _IdentityFinalReviewScreenState();
}

class _IdentityFinalReviewScreenState extends State<IdentityFinalReviewScreen> {
  bool loading = true;
  bool finishing = false;

  // basic
  String fullName = "";
  String username = "";
  String intro = "";
  String coverUrl = "";
  static const String defaultCoverAsset = "assets/images/default_cover.png";
  String bio = "";
  String? email;
  String? phone;
  int? age;
  String? gender;
  String? pronouns;

  // profile
  String? photoUrl;
  DateTime? birthDate;

  // interests/skills
  List<String> interests = [];
  List<String> skills = [];

  // visibility/distance
  String? visibilityMode;
  String? distancePreference;

  // notifications
  List<String> notifications = [];

  // socials
  Map<String, dynamic> socials = {};

  // permissions
  bool permLocation = false;
  bool permNotifications = false;

  // hold-to-confirm state
  double holdProgress = 0.0;
  Timer? _holdTimer;
  bool isHolding = false;

  static const Color _pageBg = Color(0xFFF5F7FB);
  static const Color _softCard = Colors.white;

  String get _reviewFirstName {
    final raw = fullName.trim();
    if (raw.isEmpty) return "Friend";
    return raw.split(RegExp(r'\s+')).first;
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _tinyPop() {
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  String _formatMiles(num miles) {
    final m = miles.round();
    return "$m mi";
  }

  String _metersToMilesLabel(num meters) {
    final miles = meters / 1609.344;
    return _formatMiles(miles);
  }

  String _readDistanceLabel(Map<String, dynamic> data) {
    final dm = data["distanceMiles"];
    if (dm != null && dm is num) return _formatMiles(dm);

    final meters = data["distanceMeters"] ??
        data["radiusMeters"] ??
        data["maxDistance"] ??
        data["radius"] ??
        data["distance"];

    if (meters != null && meters is num) {
      return _metersToMilesLabel(meters);
    }

    final str = data["distancePreference"];
    if (str != null && str is String && str.trim().isNotEmpty) {
      return str.trim();
    }

    return "—";
  }

  int? get derivedAge {
    if (birthDate == null) return age;
    return _calculateAge(birthDate!);
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int years = today.year - birthDate.year;

    final hadBirthdayThisYear =
        today.month > birthDate.month ||
            (today.month == birthDate.month && today.day >= birthDate.day);

    if (!hadBirthdayThisYear) years--;
    return years;
  }

  Future<void> _loadAll() async {
    if (mounted) setState(() => loading = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (!doc.exists || doc.data() == null) return;

      final data = doc.data()!;

      fullName = (data["fullName"] ?? "").toString();
      username = (data["username"] ?? "").toString();
      intro = (data["intro"] ?? "").toString();
      coverUrl = (data["coverUrl"] ?? "").toString();
      bio = (data["bio"] ?? "").toString();
      email = data["email"];
      phone = data["phone"];
      age = data["age"];

      final birthTs = data["birthDate"];
      if (birthTs is Timestamp) {
        birthDate = birthTs.toDate();
      }

      gender = data["gender"];
      pronouns = data["pronouns"];
      photoUrl = data["photoUrl"];

      interests = List<String>.from(data["interests"] ?? []);
      skills = List<String>.from(data["skills"] ?? []);

      visibilityMode = data["visibilityMode"];
      distancePreference = _readDistanceLabel(data);

      notifications = List<String>.from(data["notifications"] ?? []);
      socials = Map<String, dynamic>.from(data["socials"] ?? {});

      final perms = Map<String, dynamic>.from(data["permissions"] ?? {});
      permLocation = perms["location"] == true;
      permNotifications = perms["notifications"] == true;
    } catch (e) {
      debugPrint("❌ Final review load error: $e");
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _visibilityLabel(String? v) {
    switch (v) {
      case "public":
        return "Public";
      case "friends":
        return "Friends";
      case "verified":
        return "Verified";
      // backwards compatibility
      case "interests_only":
        return "Match by interests";
      case "followers_only":
        return "Private circle";
      case "invisible":
        return "Stealth mode";
      default:
        return "Not set";
    }
  }

  String _safe(String? v) => (v == null || v.trim().isEmpty) ? "—" : v.trim();

  String _shortBio(String b) {
    final t = b.trim();
    if (t.isEmpty) return "—";
    if (t.length <= 100) return t;
    return "${t.substring(0, 100)}…";
  }

  bool get basicComplete =>
      fullName.isNotEmpty &&
      username.isNotEmpty &&
      bio.isNotEmpty &&
      (birthDate != null || age != null);

  int get completedCount {
    int c = 0;
    if (basicComplete) c++;
    if (photoUrl != null && photoUrl!.isNotEmpty) c++;
    if (interests.isNotEmpty) c++;
    if (skills.isNotEmpty) c++;
    if (visibilityMode != null) c++;
    if (distancePreference != null && distancePreference != "—") c++;
    if (notifications.isNotEmpty) c++;
    if (socials.isNotEmpty) c++;
    if (permLocation || permNotifications) c++;
    return c;
  }

  void _startHold() {
    if (finishing) return;

    if (!basicComplete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Complete your basic info first.")),
      );
      return;
    }

    final currentAge = derivedAge;

    if (currentAge == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please complete your birthdate first.")),
      );
      return;
    }

    // aligned with your earlier 16+ onboarding rule
    if (currentAge < 16) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Too young. Users must be 16 years or older."),
        ),
      );
      return;
    }

    setState(() => isHolding = true);

    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 14), (t) async {
      if (!mounted) return;

      setState(() {
        holdProgress = (holdProgress + 0.014).clamp(0.0, 1.0);
      });

      if (holdProgress >= 1.0) {
        t.cancel();
        await _finish();
      }
    });
  }

  void _stopHold() {
    _holdTimer?.cancel();
    if (!mounted) return;
    if (!isHolding && holdProgress == 0.0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        isHolding = false;
        holdProgress = 0.0;
      });
    });
  }

  Future<void> _finish() async {
    if (finishing) return;

    setState(() => finishing = true);
    _tinyPop();

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "profileLevel": 10,
        "onboardingComplete": true,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const MainAppShell()),
            (route) => false,
      );
    } catch (e) {
      debugPrint("❌ Finish error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Could not finish. Try again.")),
      );
    } finally {
      if (mounted) {
        setState(() => finishing = false);
        _stopHold();
      }
    }
  }

  Future<void> _goTo(Widget screen) async {
    _tinyPop();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    await _loadAll();
  }

  Widget _sectionTitle(String title) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontFamily: "Nunito",
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade800,
          ),
        ),
      ),
    );
  }

  Widget _cardShell({
    required Widget child,
    EdgeInsetsGeometry padding =
    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: _softCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.035),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _tinyChip({
    required String text,
    Color? bg,
    Color? fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg ?? const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg ?? OnboardingStyle.action,
          fontFamily: "Nunito",
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _progressBar() {
    final percent = (completedCount / 9.0).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 10,
        width: double.infinity,
        color: const Color(0xFFF0F2F5),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: percent,
          child: Container(
            decoration: BoxDecoration(
              color: OnboardingStyle.progress,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBannerCard() {
    final percent = (completedCount / 9.0).clamp(0.0, 1.0);

    return _cardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: OnboardingStyle.action,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  color: OnboardingStyle.onAction,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Final review",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      "Check each section before you finish.",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              _tinyChip(
                text: "$completedCount/9",
              ),
            ],
          ),
          const SizedBox(height: 16),
          _progressBar(),
          const SizedBox(height: 10),
          Text(
            "${(percent * 100).round()}% complete",
            style: const TextStyle(
              fontSize: 13,
              color: Colors.black87,
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statPill({
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: OnboardingStyle.action),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _profilePreviewCard() {
    final hasPhoto = (photoUrl != null && photoUrl!.isNotEmpty);
    final hasCover = coverUrl.trim().isNotEmpty;

    const double coverH = 116;
    const double avatarSize = 76;

    return _cardShell(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SizedBox(
              height: coverH,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasCover)
                    Image.network(coverUrl, fit: BoxFit.cover)
                  else
                    Image.asset(defaultCoverAsset, fit: BoxFit.cover),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.brandGreen.withOpacity(0.18),
                          Colors.black.withOpacity(0.08),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 14,
                    top: 14,
                    child: GestureDetector(
                      onTap: () => _goTo(const IdentityBasicScreen()),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.94),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.edit_rounded,
                              size: 14,
                              color: OnboardingStyle.action,
                            ),
                            SizedBox(width: 6),
                            Text(
                              "Edit",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
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
          Transform.translate(
            offset: const Offset(0, -24),
            child: Padding(
              padding: const EdgeInsets.only(left: 18, right: 18, bottom: 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () => _goTo(const IdentityProfilePhotoScreen()),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: avatarSize,
                          height: avatarSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFF0F2F5),
                            border: Border.all(color: Colors.white, width: 4),
                            image: hasPhoto
                                ? DecorationImage(
                              image: NetworkImage(photoUrl!),
                              fit: BoxFit.cover,
                            )
                                : null,
                          ),
                          child: !hasPhoto
                              ? const Icon(
                            Icons.person_rounded,
                            color: OnboardingStyle.action,
                            size: 34,
                          )
                              : null,
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: OnboardingStyle.action,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            child: const Icon(
                              Icons.camera_alt_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fullName.isNotEmpty ? fullName : "Your profile",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              fontFamily: "Nunito",
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            username.isNotEmpty ? "@$username" : "@username",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (intro.trim().isNotEmpty) ...[
                  Text(
                    intro.trim(),
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.black.withOpacity(0.74),
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  _shortBio(bio),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black87,
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _statPill(
                      icon: Icons.visibility_outlined,
                      text: _visibilityLabel(visibilityMode),
                    ),
                    _statPill(
                      icon: Icons.place_outlined,
                      text: distancePreference ?? "—",
                    ),
                    _statPill(
                      icon: Icons.notifications_none_rounded,
                      text: notifications.isEmpty
                          ? "No alerts"
                          : "${notifications.length} alerts",
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool complete = false,
    String? rightPill,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: _cardShell(
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.06),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: OnboardingStyle.action, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (rightPill != null)
                _tinyChip(text: rightPill)
              else
                Icon(
                  complete
                      ? Icons.check_circle_rounded
                      : Icons.chevron_right_rounded,
                  color:
                  complete ? OnboardingStyle.action : Colors.grey.shade500,
                  size: complete ? 22 : 24,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _holdToConfirmButton() {
    final disabled = finishing;

    return Listener(
      onPointerDown: disabled ? null : (_) => _startHold(),
      onPointerUp: disabled ? null : (_) => _stopHold(),
      onPointerCancel: disabled ? null : (_) => _stopHold(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: Container(
              height: 56,
              width: double.infinity,
              color: const Color(0xFFF0F2F5),
              child: Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 60),
                    width: constraints.maxWidth * holdProgress,
                    decoration: BoxDecoration(
                      color: OnboardingStyle.progress,
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                  Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: Text(
                        finishing
                            ? "Finishing..."
                            : (isHolding ? "Keep holding..." : "Hold to finish"),
                        key: ValueKey("$finishing-$isHolding"),
                        style: TextStyle(
                          fontSize: 16,
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          color:
                          holdProgress > 0.12 ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: _pageBg,
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(OnboardingStyle.progress),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 10, totalSteps: 10),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Image.asset(
                      "assets/images/onboarding_ten.png",
                      height: 180,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "You’re all set",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Review your profile, fix anything weak, then finish.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 18),

                    _topBannerCard(),
                    const SizedBox(height: 18),

                    _sectionTitle("Profile preview"),
                    const SizedBox(height: 10),
                    _profilePreviewCard(),
                    const SizedBox(height: 20),

                    _sectionTitle("Review sections"),
                    const SizedBox(height: 10),

                    _reviewCard(
                      icon: Icons.badge_outlined,
                      title: "Basic info",
                      subtitle:
                      "${_safe(derivedAge?.toString())} • ${_safe(gender)} • ${_safe(pronouns)}",
                      onTap: () => _goTo(const IdentityBasicScreen()),
                      complete: basicComplete,
                      rightPill: basicComplete ? "Ready" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.interests_rounded,
                      title: "Interests",
                      subtitle: interests.isEmpty
                          ? "Pick up to 3 interests"
                          : interests.join(" • "),
                      onTap: () => _goTo(
                        IdentityInterestsScreen(
                          firstName:
                          fullName.isNotEmpty ? fullName : "Friend",
                        ),
                      ),
                      complete: interests.isNotEmpty,
                      rightPill: interests.isNotEmpty ? "${interests.length}/3" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.auto_awesome_rounded,
                      title: "Skills",
                      subtitle: skills.isEmpty
                          ? "Pick up to 8 skills"
                          : skills.join(" • "),
                      onTap: () =>
                          _goTo(IdentitySkillsScreen(firstName: _reviewFirstName)),
                      complete: skills.isNotEmpty,
                      rightPill: skills.isNotEmpty ? "${skills.length}/8" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.visibility_outlined,
                      title: "Visibility",
                      subtitle: _visibilityLabel(visibilityMode),
                      onTap: () => _goTo(
                        IdentityVisibilityScreen(firstName: _reviewFirstName),
                      ),
                      complete: visibilityMode != null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.place_outlined,
                      title: "Distance range",
                      subtitle: distancePreference ?? "—",
                      onTap: () => _goTo(const IdentityDistanceScreen()),
                      complete:
                      distancePreference != null && distancePreference != "—",
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.notifications_none_rounded,
                      title: "Ping notifications",
                      subtitle: notifications.isEmpty
                          ? "Choose what to be notified about"
                          : notifications.join(" • "),
                      onTap: () => _goTo(const IdentityNotificationsScreen()),
                      complete: notifications.isNotEmpty,
                      rightPill: notifications.isNotEmpty
                          ? "${notifications.length}/3"
                          : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.share_rounded,
                      title: "Socials",
                      subtitle: socials.isEmpty
                          ? "Optional"
                          : socials.keys.join(" • "),
                      onTap: () => _goTo(const IdentitySocialsScreen()),
                      complete: true,
                      rightPill: socials.isEmpty ? "Optional" : "${socials.length}",
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.security_rounded,
                      title: "Permissions",
                      subtitle:
                      "Location: ${permLocation ? "On" : "Off"} • Notifications: ${permNotifications ? "On" : "Off"}",
                      onTap: () => _goTo(const IdentityPermissionsScreen()),
                      complete: permLocation && permNotifications,
                      rightPill:
                      permLocation && permNotifications ? "All set" : "Review",
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: Icons.camera_alt_outlined,
                      title: "Profile photo",
                      subtitle: (photoUrl != null && photoUrl!.isNotEmpty)
                          ? "Looking good. Tap to change it."
                          : "Add a photo so people recognize you",
                      onTap: () => _goTo(const IdentityProfilePhotoScreen()),
                      complete: photoUrl != null && photoUrl!.isNotEmpty,
                    ),
                    const SizedBox(height: 20),

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
                    onTap: finishing ? null : () => Navigator.pop(context),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.035),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
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
                  Expanded(
                    child: _holdToConfirmButton(),
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