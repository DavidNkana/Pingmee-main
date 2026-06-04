import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_visibility_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class IdentitySkillsScreen extends StatefulWidget {
  final String firstName;

  const IdentitySkillsScreen({
    super.key,
    required this.firstName,
  });

  @override
  State<IdentitySkillsScreen> createState() => _IdentitySkillsScreenState();
}

class _IdentitySkillsScreenState extends State<IdentitySkillsScreen> {
  final List<String> selectedSkills = [];
  bool saving = false;
  bool loading = true;

  String? pressedSkill;

  final List<Map<String, dynamic>> skills = [
    {"label": "Flutter", "icon": PhosphorIconsRegular.code},
    {"label": "Web Development", "icon": PhosphorIconsRegular.globeHemisphereWest},
    {"label": "UI/UX Design", "icon": PhosphorIconsRegular.palette},
    {"label": "Graphic Design", "icon": PhosphorIconsRegular.penNib},
    {"label": "Video Editing", "icon": PhosphorIconsRegular.videoCamera},
    {"label": "Photography", "icon": PhosphorIconsRegular.camera},
    {"label": "Content Creation", "icon": PhosphorIconsRegular.megaphone},
    {"label": "Digital Marketing", "icon": PhosphorIconsRegular.chartLineUp},
    {"label": "Startup Founder", "icon": PhosphorIconsRegular.rocketLaunch},
    {"label": "Business Strategy", "icon": PhosphorIconsRegular.briefcase},
    {"label": "Public Speaking", "icon": PhosphorIconsRegular.microphoneStage},
    {"label": "Writing", "icon": PhosphorIconsRegular.pencilSimpleLine},
    {"label": "Music Production", "icon": PhosphorIconsRegular.musicNotes},
    {"label": "Guitar", "icon": PhosphorIconsRegular.guitar},
    {"label": "Piano", "icon": PhosphorIconsRegular.pianoKeys},
    {"label": "Fitness Coaching", "icon": PhosphorIconsRegular.barbell},
    {"label": "Personal Training", "icon": PhosphorIconsRegular.heartbeat},
    {"label": "Data Analysis", "icon": PhosphorIconsRegular.chartBar},
    {"label": "AI / ML", "icon": PhosphorIconsRegular.brain},
    {"label": "Game Development", "icon": PhosphorIconsRegular.gameController},
    {"label": "3D Design", "icon": PhosphorIconsRegular.cube},
    {"label": "Cybersecurity", "icon": PhosphorIconsRegular.shieldCheck},
  ];

  static const Set<String> _blockedSkillValues = {
    "idk",
    "i dont know",
    "i don't know",
    "anything",
    "nothing",
    "stuff",
    "whatever",
    "random",
    "n/a",
    "na",
    "none",
    "all",
    "everything",
    "lol",
    "hmm",
    "mmm",
    "yes",
    "no",
  };

  @override
  void initState() {
    super.initState();
    _loadPreviousSkills();
  }

  Set<String> get _builtInSkillKeys =>
      skills.map((e) => _skillKey((e["label"] ?? "").toString())).toSet();

  List<String> get _customSelectedSkills {
    return selectedSkills
        .where((item) => !_builtInSkillKeys.contains(_skillKey(item)))
        .toList();
  }

  Future<void> _loadPreviousSkills() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc = await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        final raw = List<String>.from(doc.data()!['skills'] ?? []);
        final seen = <String>{};

        for (final item in raw) {
          final normalized = _normalizeSkill(item);
          if (normalized.isEmpty) continue;

          final key = _skillKey(normalized);
          if (seen.add(key)) {
            selectedSkills.add(normalized);
          }
        }
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  String _skillKey(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s*/\s*'), '/')
        .replaceAll(RegExp(r'\s*\.\s*'), '.');
  }

  String _normalizeSkill(String input) {
    var value = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (value.isEmpty) return '';

    final lower = value.toLowerCase();

    const directMap = {
      "ui/ux": "UI/UX",
      "ui / ux": "UI/UX",
      "ai/ml": "AI / ML",
      "ai / ml": "AI / ML",
      "c++": "C++",
      "c#": "C#",
      "node.js": "Node.js",
      "sql": "SQL",
      "seo": "SEO",
      "qa": "QA",
      "ux": "UX",
      "ui": "UI",
      "ml": "ML",
      "ai": "AI",
      "3d": "3D",
      "2d": "2D",
    };

    if (directMap.containsKey(lower)) {
      return directMap[lower]!;
    }

    value = value.replaceAll(RegExp(r'\s*/\s*'), ' / ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();

    final words = value.split(' ');
    final normalized = words.map((word) {
      if (word.isEmpty) return word;

      final lowerWord = word.toLowerCase();

      const forceUpper = {
        "ui",
        "ux",
        "ai",
        "ml",
        "sql",
        "seo",
        "qa",
        "vr",
        "ar",
        "api",
        "ios",
        "android",
        "3d",
        "2d",
      };

      if (lowerWord == "c++") return "C++";
      if (lowerWord == "c#") return "C#";
      if (lowerWord == "node.js") return "Node.js";

      if (forceUpper.contains(lowerWord)) {
        return lowerWord.toUpperCase();
      }

      if (lowerWord.contains('/')) {
        final parts = lowerWord.split('/');
        return parts.map((part) {
          if (forceUpper.contains(part)) return part.toUpperCase();
          if (part.isEmpty) return part;
          return part[0].toUpperCase() + part.substring(1);
        }).join('/');
      }

      if (lowerWord.contains('.')) {
        final parts = lowerWord.split('.');
        return parts.map((part) {
          if (part == "js") return "js";
          if (part.isEmpty) return part;
          return part[0].toUpperCase() + part.substring(1);
        }).join('.');
      }

      if (word.length == 1) return word.toUpperCase();

      return lowerWord[0].toUpperCase() + lowerWord.substring(1);
    }).toList();

    final out = normalized.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    if (_skillKey(out) == _skillKey("AI/ML")) return "AI / ML";
    if (_skillKey(out) == _skillKey("UI/UX")) return "UI/UX";

    return out;
  }

  String? _validateCustomSkill(String raw) {
    final value = _normalizeSkill(raw);
    final compact = value.replaceAll(' ', '');

    if (value.isEmpty) {
      return "Enter a skill first.";
    }

    if (value.length < 2) {
      return "That’s too short to be a real skill.";
    }

    if (value.length > 28) {
      return "Keep it short. 28 characters max.";
    }

    if (value.split(' ').where((e) => e.trim().isNotEmpty).length > 4) {
      return "Use a short skill name, not a whole sentence.";
    }

    if (!RegExp(r"^[A-Za-z0-9][A-Za-z0-9\s&+\-/.#']*$").hasMatch(value)) {
      return "Use a real skill name. No weird junk.";
    }

    if (!RegExp(r'[A-Za-z0-9]').hasMatch(value)) {
      return "That doesn’t look like a real skill.";
    }

    if (RegExp(r'(.)\1\1\1', caseSensitive: false).hasMatch(compact)) {
      return "No keyboard smash or spammy repetition.";
    }

    final lower = value.toLowerCase();
    if (_blockedSkillValues.contains(lower)) {
      return "Add a real skill, not filler.";
    }

    if (_skillKey(value) == _skillKey("Custom")) {
      return "Add an actual skill.";
    }

    return null;
  }

  void toggleSkill(String skill) {
    final normalized = _normalizeSkill(skill);
    final key = _skillKey(normalized);

    final existingIndex = selectedSkills.indexWhere(
      (e) => _skillKey(e) == key,
    );

    if (existingIndex != -1) {
      setState(() {
        selectedSkills.removeAt(existingIndex);
      });

      try {
        HapticFeedback.selectionClick();
      } catch (_) {}
      return;
    }

    if (selectedSkills.length >= 8) {
      try {
        HapticFeedback.heavyImpact();
      } catch (_) {}
      _showSnack("You can only pick up to 8 skills.");
      return;
    }

    setState(() {
      selectedSkills.add(normalized);
    });

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  String _skillVibe() {
    if (selectedSkills.isEmpty) return "Pick up to 8 — show what you’re about.";
    if (selectedSkills.length <= 2) return "Nice. Add a few more to stand out.";
    if (selectedSkills.length <= 5) return "Clean profile. This is looking strong.";
    if (selectedSkills.length <= 7) return "Almost full. Choose your best ones.";
    return "Perfect. Your top 8 skills are locked in.";
  }

  Future<void> _openCustomSkillSheet() async {
    if (selectedSkills.length >= 8) {
      _showSnack("You already picked 8 skills.");
      return;
    }

    final controller = TextEditingController();
    String? errorText;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAF8),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> submit() async {
              final raw = controller.text;
              final validationError = _validateCustomSkill(raw);

              if (validationError != null) {
                setModalState(() => errorText = validationError);
                return;
              }

              final normalized = _normalizeSkill(raw);
              final key = _skillKey(normalized);

              final duplicate = selectedSkills.any(
                (e) => _skillKey(e) == key,
              );

              if (duplicate) {
                setModalState(() {
                  errorText = "That skill is already selected.";
                });
                return;
              }

              setState(() {
                selectedSkills.add(normalized);
              });

              try {
                HapticFeedback.selectionClick();
              } catch (_) {}

              Navigator.pop(context);
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  16,
                  24,
                  MediaQuery.of(context).viewInsets.bottom + 20,
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
                            color: Colors.black.withOpacity(.08),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            PhosphorIconsBold.plus,
                            color: OnboardingStyle.action,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            "Add custom skill",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
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

                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(28),
                      ],
                      decoration: InputDecoration(
                        hintText: "e.g. C++, SEO, 3D Modeling, DJing",
                        errorText: errorText,
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
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
                      onChanged: (_) {
                        if (errorText != null) {
                          setModalState(() => errorText = null);
                        }
                      },
                      onSubmitted: (_) => submit(),
                    ),

                    const SizedBox(height: 10),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Use a real skill people can actually connect with you for.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.grey.shade600,
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: OnboardingStyle.action,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          "Add skill",
                          style: TextStyle(
                            fontSize: 15,
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
            );
          },
        );
      },
    );
  }

  Widget _buildCustomTile() {
    final bool disabled = selectedSkills.length >= 8;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: saving || disabled ? null : _openCustomSkillSheet,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: disabled ? Colors.grey.shade200 : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: disabled
                ? Colors.grey.shade300
                : Colors.black.withOpacity(.12),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 8),
              color: Colors.black.withOpacity(.06),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                PhosphorIconsRegular.plusCircle,
                size: 28,
                color: disabled ? Colors.grey : Colors.black,
              ),
              const SizedBox(height: 10),
              Text(
                "Custom",
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: disabled ? Colors.grey : Colors.black87,
                  fontFamily: "Nunito",
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCustomSkillChip(String skill) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            PhosphorIconsFill.sparkle,
            size: 14,
            color: OnboardingStyle.action,
          ),
          const SizedBox(width: 6),
          Text(
            skill,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
              color: OnboardingStyle.action,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => toggleSkill(skill),
            child: const Icon(
              PhosphorIconsBold.x,
              size: 16,
              color: OnboardingStyle.action,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndContinue() async {
    if (selectedSkills.isEmpty) {
      _showSnack("Please select at least 1 skill");
      return;
    }

    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "skills": selectedSkills,
        "profileLevel": 3,
      }, SetOptions(merge: true));

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IdentityVisibilityScreen(firstName: widget.firstName),
        ),
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

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 3, totalSteps: 10),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_three.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),

                    const SizedBox(height: 16),

                    const Text(
                      "Choose up to 8 skills people can connect with you for.",
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
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                            child: const Icon(
                              PhosphorIconsFill.sparkle,
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
                                    "${selectedSkills.length}/8 selected",
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
                                    _skillVibe(),
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

                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: OnboardingStyle.action,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              selectedSkills.length == 8 ? "Full" : "Pick",
                              style: const TextStyle(
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
                          "Tap to add / remove",
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

                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          GestureDetector(
                            onTap: saving ? null : _openCustomSkillSheet,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.black.withOpacity(.12),
                                  width: 1.4,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 16,
                                    offset: const Offset(0, 8),
                                    color: Colors.black.withOpacity(.06),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    PhosphorIconsRegular.plusCircle,
                                    size: 18,
                                    color: Colors.black,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    "Custom",
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: "Nunito",
                                      color: Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          ...skills.map((skill) {
                            final String label = (skill["label"] ?? "").toString();
                            final bool isSelected = selectedSkills.any(
                              (e) => _skillKey(e) == _skillKey(label),
                            );

                            return GestureDetector(
                              onTap: saving ? null : () => toggleSkill(label),
                              child: AnimatedScale(
                                duration: const Duration(milliseconds: 140),
                                scale: isSelected ? 1.02 : 1.0,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.grey.shade100
                                        : Colors.black,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        blurRadius: 16,
                                        offset: const Offset(0, 8),
                                        color: Colors.black.withOpacity(.06),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isSelected) ...[
                                        Container(
                                          width: 18,
                                          height: 18,
                                          decoration: const BoxDecoration(
                                            color: Colors.black,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            PhosphorIconsBold.check,
                                            color: Colors.white,
                                            size: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                      ],
                                      Text(
                                        label,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          fontFamily: "Nunito",
                                          color: isSelected
                                              ? Colors.black87
                                              : Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),

                    if (_customSelectedSkills.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "Custom skills",
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w800,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _customSelectedSkills
                            .map(_buildCustomSkillChip)
                            .toList(),
                      ),
                    ],

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
                        Icons.arrow_back_rounded,
                        color: Colors.black87,
                        size: 22,
                      ),
                    ),
                  ),

                  const SizedBox(width: 14),

                  Expanded(
                    child: ElevatedButton(
                      onPressed: saving || selectedSkills.isEmpty ? null : _saveAndContinue,
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