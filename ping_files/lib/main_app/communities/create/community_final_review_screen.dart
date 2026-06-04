import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ping_files/main_app/communities/community_page_screen.dart';

class CommunityFinalReviewScreen extends StatefulWidget {
  const CommunityFinalReviewScreen({
    super.key,
    required this.draft,
    this.onFinish,
  });

  final CreateCommunityDraft draft;
  final Future<void> Function(CreateCommunityDraft draft)? onFinish;

  @override
  State<CommunityFinalReviewScreen> createState() =>
      _CommunityFinalReviewScreenState();
}

class _CommunityFinalReviewScreenState
    extends State<CommunityFinalReviewScreen> {
  bool finishing = false;

  double holdProgress = 0.0;
  Timer? _holdTimer;
  bool isHolding = false;

  static const Color _pageBg = Color(0xFFF5F7FB);
  static const Color _softCard = Colors.white;

  CreateCommunityDraft get draft => widget.draft;

  bool get _hasDirectContactPath {
    return draft.website.trim().isNotEmpty ||
        draft.email.trim().isNotEmpty ||
        draft.phone.trim().isNotEmpty;
  }

  bool get _hasAnySocials {
    return _socialEntries.isNotEmpty;
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

  ImageProvider? get _profileImageProvider {
    if (draft.profilePhotoFile != null) return FileImage(draft.profilePhotoFile!);
    if ((draft.profilePhotoUrl ?? '').trim().isNotEmpty) {
      return NetworkImage(draft.profilePhotoUrl!.trim());
    }
    return null;
  }

  ImageProvider? get _coverImageProvider {
    if (draft.coverPhotoFile != null) return FileImage(draft.coverPhotoFile!);
    if ((draft.coverPhotoUrl ?? '').trim().isNotEmpty) {
      return NetworkImage(draft.coverPhotoUrl!.trim());
    }
    return const AssetImage("assets/images/default_cover_community.png");
  }

  String get _communityName {
    final value = draft.communityName.trim();
    return value.isEmpty ? "Community name" : value;
  }

  String get _headline {
    final value = draft.headline.trim();
    return value.isEmpty ? "Community headline" : value;
  }

  String get _bio {
    final value = draft.shortBio.trim();
    return value.isEmpty
        ? "A simple place for real people to connect, show up, and belong."
        : value;
  }

  String get _category {
    final value = draft.communityCategory.trim();
    return value.isEmpty ? "Not set" : value;
  }

  String get _website {
    final value = draft.website.trim();
    return value.isEmpty ? "Not added" : value;
  }

  String get _email {
    final value = draft.email.trim();
    return value.isEmpty ? "Not added" : value;
  }

  String get _phone {
    final value = draft.phone.trim();
    return value.isEmpty ? "Not added" : value;
  }

  int get _radiusKm => draft.discoveryRadiusKm.round();

  String _radiusLabel(int km) {
    if (km <= 3) return "Ultra local";
    if (km <= 10) return "Nearby";
    if (km <= 25) return "City-wide";
    if (km <= 80) return "Regional";
    if (km <= 180) return "Wide reach";
    return "Explorer";
  }

  String _hoursSummary() {
    switch (draft.hoursMode) {
      case "always_open":
        return "Always open";
      case "selected":
        return _selectedHoursCount > 0
            ? "Selected hours set"
            : "Selected hours incomplete";
      case "none":
      default:
        return "No hours shown";
    }
  }

  int get _selectedHoursCount {
    int count = 0;
    draft.selectedHours.forEach((_, rows) {
      final hasComplete = rows.any((row) {
        final open = (row["open"] ?? "").trim();
        final close = (row["close"] ?? "").trim();
        return open.isNotEmpty && close.isNotEmpty;
      });
      if (hasComplete) count++;
    });
    return count;
  }

  List<CommunitySocialDraft> get _socialEntries {
    final items = draft.socials.values.where((e) => e.hasValue).toList();
    items.sort((a, b) => a.platform.compareTo(b.platform));
    return items;
  }

  int get completedCount {
    int count = 0;

    if (draft.communityName.trim().isNotEmpty &&
        draft.headline.trim().isNotEmpty &&
        draft.shortBio.trim().isNotEmpty) {
      count++;
    }

    if (_profileImageProvider != null) {
      count++;
    }

    if (draft.communityCategory.trim().isNotEmpty && _radiusKm > 0) {
      count++;
    }

    if (draft.hoursMode == "always_open" ||
        draft.hoursMode == "none" ||
        (draft.hoursMode == "selected" && _selectedHoursCount > 0)) {
      count++;
    }

    if (_hasDirectContactPath) {
      count++;
    }

    return count;
  }

  bool get reviewReady {
    if (draft.communityName.trim().isEmpty) return false;
    if (draft.headline.trim().isEmpty) return false;
    if (draft.shortBio.trim().isEmpty) return false;
    if (draft.communityCategory.trim().isEmpty) return false;
    if (draft.discoveryRadiusKm <= 0) return false;
    if (!_hasDirectContactPath) return false;
    if (draft.hoursMode == "selected" && _selectedHoursCount == 0) return false;
    return true;
  }

  List<String> _missingReviewItems() {
    final missing = <String>[];

    if (draft.communityName.trim().isEmpty) {
      missing.add("Add a community name.");
    }

    if (draft.headline.trim().isEmpty) {
      missing.add("Add a headline.");
    }

    if (draft.shortBio.trim().isEmpty) {
      missing.add("Add a short bio.");
    }

    if (_profileImageProvider == null) {
      missing.add("Add a community profile photo.");
    }

    if (draft.communityCategory.trim().isEmpty) {
      missing.add("Choose a category.");
    }

    if (draft.discoveryRadiusKm <= 0) {
      missing.add("Set the discovery radius.");
    }

    final validHours =
        draft.hoursMode == "always_open" ||
        draft.hoursMode == "none" ||
        (draft.hoursMode == "selected" && _selectedHoursCount > 0);

    if (!validHours) {
      missing.add("Complete the hours section.");
    }

    if (!_hasDirectContactPath) {
      missing.add("Add at least one direct contact path: website, email, or phone.");
    }

    return missing;
  }

  Future<void> _showMissingReviewAlert(List<String> missing) async {
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            "Finish these first",
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Your community still has a few missing parts:",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
              const SizedBox(height: 14),
              ...missing.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: Color(0xFFE11D48),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: draft.themeColor,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  "Okay",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _startHold() {
    if (finishing) return;

    final missing = _missingReviewItems();
    if (missing.isNotEmpty) {
      _showMissingReviewAlert(missing);
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

  Future<void> _createCommunityAndOpenPage() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You need to be signed in."),
        ),
      );
      return;
    }

    final communityRef =
        FirebaseFirestore.instance.collection("communities").doc();

    final socialsMap = <String, dynamic>{
      for (final entry in draft.socials.entries) entry.key: entry.value.toMap(),
    };

    await communityRef.set({
      "ownerUid": currentUser.uid,
      "name": draft.communityName.trim(),
      "headline": draft.headline.trim(),
      "bio": draft.shortBio.trim(),
      "category": draft.communityCategory.trim(),
      "photoUrl": (draft.profilePhotoUrl ?? "").trim(),
      "coverUrl": (draft.coverPhotoUrl ?? "").trim(),
      "website": draft.website.trim(),
      "email": draft.email.trim(),
      "phone": draft.phone.trim(),
      "socials": socialsMap,
      "radiusKm": draft.discoveryRadiusKm.round(),
      "hoursMode": draft.hoursMode,
      "hours": draft.selectedHours,
      "themeColorValue": draft.themeColor.value,
      "subscribersCount": 0,
      "eventsCount": 0,
      "tasksCount": 0,
      "postsCount": 0,
      "createdAt": FieldValue.serverTimestamp(),
      "status": "active",
    });

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CommunityPageScreen(
          communityId: communityRef.id,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _finish() async {
    if (finishing) return;

    setState(() => finishing = true);
    _tinyPop();

    try {
      await _createCommunityAndOpenPage();
    } catch (e, st) {
      debugPrint("community finish failed: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Could not finish: $e"),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => finishing = false);
        _stopHold();
      }
    }
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
            fontWeight: FontWeight.w600,
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
        color: bg ?? const Color(0xFFE9F8EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg ?? AppColors.brandGreen,
          fontFamily: "Nunito",
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _progressBar() {
    final percent = (completedCount / 5.0).clamp(0.0, 1.0);

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
              color: draft.themeColor,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBannerCard() {
    final percent = (completedCount / 5.0).clamp(0.0, 1.0);

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
                  color: draft.themeColor.withOpacity(.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  PhosphorIconsRegular.checkCircle,
                  color: draft.themeColor,
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
                        fontWeight: FontWeight.w600,
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
              _tinyChip(text: "$completedCount/5"),
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
              fontWeight: FontWeight.w600,
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
          Icon(icon, size: 15, color: draft.themeColor),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _communityPreviewCard() {
    return _cardShell(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SizedBox(
              height: 164,
              width: double.infinity,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image(
                      image: _coverImageProvider!,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    left: 16,
                    top: 16,
                    child: _CircleIconButton(
                      icon: Icons.arrow_back_rounded,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -24),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: Colors.white, width: 4),
                          image: _profileImageProvider != null
                              ? DecorationImage(
                                  image: _profileImageProvider!,
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _profileImageProvider == null
                            ? Icon(
                                PhosphorIcons.usersThree(
                                  PhosphorIconsStyle.light,
                                ),
                                size: 28,
                                color: draft.themeColor,
                              )
                            : null,
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: draft.themeColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          "Subscribe",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _communityName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.46),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _bio,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.2,
                        height: 1.38,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _statPill(
                        icon: PhosphorIconsRegular.tag,
                        text: _category,
                      ),
                      _statPill(
                        icon: PhosphorIconsRegular.mapPinArea,
                        text: "$_radiusKm km",
                      ),
                      _statPill(
                        icon: PhosphorIconsRegular.clock,
                        text: _hoursSummary(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _reviewCard({
    required IconData icon,
    required String title,
    required String subtitle,
    bool complete = false,
    String? rightPill,
  }) {
    return _cardShell(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F8F3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: draft.themeColor, size: 22),
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
                    fontWeight: FontWeight.w600,
                    fontFamily: "Nunito",
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.grey,
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
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
                  : Icons.radio_button_unchecked_rounded,
              color: complete ? draft.themeColor : Colors.grey.shade400,
              size: 22,
            ),
        ],
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
                      color: draft.themeColor,
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
                          fontWeight: FontWeight.w600,
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

  String _socialSummary() {
    if (_socialEntries.isEmpty) return "No socials added";

    return _socialEntries.map((e) {
      if (e.handle.trim().isNotEmpty) {
        return e.platform;
      }
      if (e.url.trim().isNotEmpty) {
        return e.platform;
      }
      return e.platform;
    }).join(" • ");
  }

  String _contactSummary() {
    final values = <String>[];

    if (draft.website.trim().isNotEmpty) values.add("Website");
    if (draft.email.trim().isNotEmpty) values.add("Email");
    if (draft.phone.trim().isNotEmpty) values.add("Phone");

    if (values.isEmpty) return "No direct contact added";
    return values.join(" • ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: ProfileProgressBar(step: 5, totalSteps: 5),
            ),
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
                      "Final review",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Review the setup, fix anything weak, then finish.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 18),

                    _topBannerCard(),
                    const SizedBox(height: 18),

                    _sectionTitle("Community preview"),
                    const SizedBox(height: 10),
                    _communityPreviewCard(),
                    const SizedBox(height: 20),

                    _sectionTitle("Review sections"),
                    const SizedBox(height: 10),

                    _reviewCard(
                      icon: PhosphorIconsRegular.identificationCard,
                      title: "Identity",
                      subtitle: "$_communityName • $_headline",
                      complete: draft.communityName.trim().isNotEmpty &&
                          draft.headline.trim().isNotEmpty &&
                          draft.shortBio.trim().isNotEmpty,
                      rightPill: draft.communityName.trim().isNotEmpty &&
                              draft.headline.trim().isNotEmpty &&
                              draft.shortBio.trim().isNotEmpty
                          ? "Ready"
                          : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: PhosphorIconsRegular.imageSquare,
                      title: "Branding",
                      subtitle: _profileImageProvider != null
                          ? "Photo added • Theme selected"
                          : "Add a profile image so the page feels real",
                      complete: _profileImageProvider != null,
                      rightPill: _profileImageProvider != null ? "Set" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: PhosphorIconsRegular.mapPinArea,
                      title: "Discovery",
                      subtitle: "$_radiusKm km • ${_radiusLabel(_radiusKm)} • $_category",
                      complete: draft.communityCategory.trim().isNotEmpty &&
                          draft.discoveryRadiusKm > 0,
                      rightPill: draft.communityCategory.trim().isNotEmpty ? "Ready" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: PhosphorIconsRegular.clock,
                      title: "Hours",
                      subtitle: draft.hoursMode == "selected"
                          ? "$_hoursSummary • $_selectedHoursCount day(s)"
                          : _hoursSummary(),
                      complete: draft.hoursMode == "always_open" ||
                          draft.hoursMode == "none" ||
                          (draft.hoursMode == "selected" && _selectedHoursCount > 0),
                      rightPill: draft.hoursMode == "always_open"
                          ? "24/7"
                          : draft.hoursMode == "none"
                              ? "Hidden"
                              : (_selectedHoursCount > 0 ? "$_selectedHoursCount day(s)" : null),
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: PhosphorIconsRegular.linkSimpleHorizontal,
                      title: "Direct contact",
                      subtitle: _contactSummary(),
                      complete: _hasDirectContactPath,
                      rightPill: _hasDirectContactPath ? "Ready" : null,
                    ),
                    const SizedBox(height: 12),

                    _reviewCard(
                      icon: PhosphorIconsRegular.shareNetwork,
                      title: "Social presence",
                      subtitle: _socialEntries.isEmpty
                          ? "Optional"
                          : _socialSummary(),
                      complete: true,
                      rightPill: _socialEntries.isEmpty ? "Optional" : "${_socialEntries.length}",
                    ),

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

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
  });

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 18,
        color: Colors.black87,
      ),
    );
  }
}