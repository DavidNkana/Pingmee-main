import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
import 'package:ping_files/services/profile_photo_flow.dart';
import 'package:ping_files/main_app/communities/create/community_links_contact_screen.dart';


class CommunityBrandingScreen extends StatefulWidget {
  const CommunityBrandingScreen({
    super.key,
    required this.draft,
  });

  final CreateCommunityDraft draft;

  @override
  State<CommunityBrandingScreen> createState() =>
      _CommunityBrandingScreenState();
}

class _CommunityBrandingScreenState extends State<CommunityBrandingScreen> {
  bool saving = false;
  String? toastLine;

  File? selectedProfileFile;
  String? existingProfileUrl;
  late Color selectedThemeColor;

  static const List<Color> themeColors = [
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFF8B5CF6),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFF14B8A6),
    Color(0xFFEC4899),
    Color(0xFF111827),
  ];

  @override
  void initState() {
    super.initState();
    selectedProfileFile = widget.draft.profilePhotoFile;
    existingProfileUrl = widget.draft.profilePhotoUrl;
    selectedThemeColor = widget.draft.themeColor;
  }

  ImageProvider? get _profileImageProvider {
    if (selectedProfileFile != null) return FileImage(selectedProfileFile!);
    if ((existingProfileUrl ?? '').trim().isNotEmpty) {
      return NetworkImage(existingProfileUrl!);
    }
    return null;
  }

  bool get _hasProfilePhoto => _profileImageProvider != null;

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _tinyPop([String? line]) {
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}

    if (line == null) return;

    setState(() => toastLine = line);
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => toastLine = null);
    });
  }

  Future<void> _chooseProfilePhoto() async {
    if (saving) return;

    setState(() => saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      final url = await updateUserImageFlow(
        context: context,
        uid: uid,
        existingUrl: existingProfileUrl,
        firestoreField: "communitySetupDraft.profilePhotoUrl",
        storageFolder: "community_profile_pictures",
        sheetTitle: "Community profile photo",
      );

      if (!mounted) return;

      if (url != null) {
        setState(() {
          existingProfileUrl = url;
          selectedProfileFile = null;
        });
        _tinyPop("Photo updated");
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _removeProfilePhoto() {
    setState(() {
      selectedProfileFile = null;
      existingProfileUrl = null;
    });
    _tinyPop("Photo removed");
  }

  Future<void> _saveAndContinue() async {
    if (!_hasProfilePhoto) {
      _showSnack("Add a community profile photo to continue.");
      return;
    }

    setState(() => saving = true);

    try {
      widget.draft.profilePhotoFile = selectedProfileFile;
      widget.draft.profilePhotoUrl = existingProfileUrl;
      widget.draft.themeColor = selectedThemeColor;

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CommunityLinksContactScreen(
            draft: widget.draft,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showSnack("Something went wrong. Please try again.");
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final communityName = widget.draft.communityName.trim().isEmpty
        ? "Community name"
        : widget.draft.communityName.trim();

    final headline = widget.draft.headline.trim().isEmpty
        ? "Community headline"
        : widget.draft.headline.trim();

    final shortBio = widget.draft.shortBio.trim().isEmpty
        ? "A simple place for real people to connect, show up, and belong."
        : widget.draft.shortBio.trim();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: saving ? null : () => Navigator.pop(context),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "Create community",
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: ProfileProgressBar(step: 2, totalSteps: 5),
            ),
            const SizedBox(height: 22),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/community_two.png",
                        height: 210,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Shape the first impression",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Choose a clear profile image and a theme color that makes the page feel alive without trying too hard.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w400,
                        fontFamily: "Nunito",
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                    const SizedBox(height: 22),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 36,
                            decoration: BoxDecoration(
                              color: selectedThemeColor,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.lightbulb_outline_rounded,
                            color: selectedThemeColor,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _hasProfilePhoto
                                  ? "This already feels more real. Keep it simple."
                                  : "Use a logo, mark, or strong image people can remember.",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.56),
                              ),
                            ),
                          ),
                          if (toastLine != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: selectedThemeColor,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                toastLine!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontFamily: "Nunito",
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    _OfflineStylePreviewCard(
                      communityName: communityName,
                      headline: headline,
                      shortBio: shortBio,
                      themeColor: selectedThemeColor,
                      profileImage: _profileImageProvider,
                    ),
                    const SizedBox(height: 28),
                    Center(
                      child: GestureDetector(
                        onTap: _chooseProfilePhoto,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 112,
                              height: 112,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(
                                  color: Colors.grey.shade200,
                                  width: 1.2,
                                ),
                                image: _profileImageProvider != null
                                    ? DecorationImage(
                                        image: _profileImageProvider!,
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: _profileImageProvider == null
                                  ? Icon(
                                      PhosphorIcons.imageSquare(
                                        PhosphorIconsStyle.light,
                                      ),
                                      size: 34,
                                      color: Colors.black.withOpacity(.42),
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: selectedThemeColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _hasProfilePhoto
                          ? "Tap the photo to change it"
                          : "Tap to add your community photo",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.62),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Rounded, clean, and easy to recognize.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.45),
                      ),
                    ),
                    if (_hasProfilePhoto) ...[
                      const SizedBox(height: 14),
                      Center(
                        child: TextButton(
                          onPressed: _removeProfilePhoto,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.black.withOpacity(.58),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          child: const Text(
                            "Remove photo",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 30),
                    const Text(
                      "Community theme",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "This color will shape buttons and small accents across the page.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        height: 1.4,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 62,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: themeColors.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final color = themeColors[index];
                          final selected =
                              selectedThemeColor.value == color.value;

                          return GestureDetector(
                            onTap: () {
                              setState(() => selectedThemeColor = color);
                              _tinyPop("Theme updated");
                            },
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(
                                  width: 54,
                                  height: 54,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                        color: color.withOpacity(.18),
                                      ),
                                    ],
                                  ),
                                ),
                                if (selected)
                                  const Icon(
                                    Icons.check_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 130),
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
                    child: ElevatedButton(
                      onPressed: saving ? null : _saveAndContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: selectedThemeColor,
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
                          fontWeight: FontWeight.w600,
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

class _OfflineStylePreviewCard extends StatelessWidget {
  const _OfflineStylePreviewCard({
    required this.communityName,
    required this.headline,
    required this.shortBio,
    required this.themeColor,
    required this.profileImage,
  });

  final String communityName;
  final String headline;
  final String shortBio;
  final Color themeColor;
  final ImageProvider? profileImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 164,
            width: double.infinity,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    "assets/images/default_cover_community.png",
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
                          image: profileImage != null
                              ? DecorationImage(
                                  image: profileImage!,
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: profileImage == null
                            ? Icon(
                                PhosphorIcons.usersThree(
                                  PhosphorIconsStyle.light,
                                ),
                                size: 28,
                                color: themeColor,
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
                          color: themeColor,
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
                      communityName,
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
                      headline,
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
                      shortBio,
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
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
        ],
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