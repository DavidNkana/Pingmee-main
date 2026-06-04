import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/theme/colors2.dart';

class WordLimitFormatter extends TextInputFormatter {
  final int maxWords;

  WordLimitFormatter(this.maxWords);

  int _countWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final wordCount = _countWords(newValue.text);
    if (wordCount <= maxWords) return newValue;
    return oldValue;
  }
}

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final TextEditingController _headlineCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController birthDateCtrl = TextEditingController();
  final TextEditingController _bioCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  bool _showBirthdayOnProfile = false;
  bool _messageRequestsEnabled = false;

  DateTime? _birthDate;
  String? _gender;
  String? _pronouns;

  double _distanceMiles = 10;

  static const int minMiles = 1;
  static const int maxMiles = 310;

  final List<String> _genders = const [
    "Male",
    "Female",
    "Non-binary",
    "Transgender",
    "Genderfluid",
    "Agender",
    "Intersex",
    "Prefer not to say",
    "Other",
  ];

  final List<String> _pronounList = const [
    "He / Him",
    "She / Her",
    "They / Them",
    "He / They",
    "She / They",
    "Ze / Zir",
    "Prefer not to say",
    "Other",
  ];

  final List<String> _platforms = const [
    "Instagram",
    "TikTok",
    "X",
    "LinkedIn",
    "Facebook",
    "Threads",
    "Website",
  ];

  final Map<String, IconData> _platformIcons = const {
    "Instagram": FontAwesomeIcons.instagram,
    "TikTok": FontAwesomeIcons.tiktok,
    "X": FontAwesomeIcons.xTwitter,
    "LinkedIn": FontAwesomeIcons.linkedin,
    "Facebook": FontAwesomeIcons.facebook,
    "Threads": FontAwesomeIcons.threads,
    "Website": FontAwesomeIcons.globe,
  };

  final Map<String, String> _socialHandles = {};
  final Map<String, String> _socialUrls = {};
  final Map<String, bool> _socialVisibility = {};

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _headlineCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    birthDateCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  int _countWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }

  int _countChars(String text) => text.length;

  String _formatBirthDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    return '$day/$month/$year';
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;

    final hasHadBirthdayThisYear =
        today.month > birthDate.month ||
        (today.month == birthDate.month && today.day >= birthDate.day);

    if (!hasHadBirthdayThisYear) age--;
    return age;
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initialDate =
        _birthDate ?? DateTime(now.year - 18, now.month, now.day);

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(now) ? now : initialDate,
      firstDate: DateTime(1900),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: AppColors.brandGreen,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _birthDate = picked;
        birthDateCtrl.text = _formatBirthDate(picked);
      });
    }
  }

  Future<void> _loadProfile() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      final data = doc.data() ?? {};

      _headlineCtrl.text = (data["intro"] ?? "").toString();
      _emailCtrl.text = (data["email"] ?? "").toString();
      _phoneCtrl.text = (data["phone"] ?? "").toString();
      _bioCtrl.text = (data["bio"] ?? "").toString();

      final birthTs = data["birthDate"];
      if (birthTs is Timestamp) {
        _birthDate = birthTs.toDate();
        birthDateCtrl.text = _formatBirthDate(_birthDate!);
      }

      final profileVisibility = Map<String, dynamic>.from(
        data["profileVisibility"] ?? {},
      );

      final messagePrivacy = Map<String, dynamic>.from(
        data["messagePrivacy"] ?? {},
      );

      _showBirthdayOnProfile =
          profileVisibility["showBirthday"] == true;

      _messageRequestsEnabled =
          messagePrivacy["requireMessageRequests"] == true;

      _gender = (data["gender"] ?? "").toString().trim().isEmpty
          ? null
          : (data["gender"] ?? "").toString();

      _pronouns = (data["pronouns"] ?? "").toString().trim().isEmpty
          ? null
          : (data["pronouns"] ?? "").toString();

      final savedMiles = data["distanceMiles"];
      if (savedMiles is num) {
        _distanceMiles = savedMiles.toDouble().clamp(
          minMiles.toDouble(),
          maxMiles.toDouble(),
        );
      }

      final socials = Map<String, dynamic>.from(data["socials"] ?? {});
      for (final p in _platforms) {
        final raw = socials[p];
        if (raw is Map) {
          _socialHandles[p] = (raw["handle"] ?? "").toString();
          _socialUrls[p] = (raw["url"] ?? "").toString();
          _socialVisibility[p] = (raw["visible"] ?? true) == true;
        } else {
          _socialHandles[p] = "";
          _socialUrls[p] = "";
          _socialVisibility[p] = true;
        }
      }
    } catch (e) {
      debugPrint("Failed to load editable profile data: $e");
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _distanceVibe(int miles) {
    if (miles <= 3) return "Very close";
    if (miles <= 10) return "Nearby";
    if (miles <= 25) return "City-wide";
    if (miles <= 60) return "Regional";
    if (miles <= 120) return "Long-range";
    return "Explorer";
  }

  void _showSelector({
    required String title,
    required List<String> options,
    required String? selected,
    required ValueChanged<String> onSelect,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        final screenHeight = MediaQuery.of(context).size.height;

        return SafeArea(
          top: false,
          child: SizedBox(
            height: screenHeight * 0.52,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        fontFamily: "Nunito",
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      children: options.map((item) {
                        final isSelected = item == selected;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            item,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              fontFamily: "Nunito",
                            ),
                          ),
                          trailing: isSelected
                              ? const Icon(
                                  PhosphorIconsFill.checkCircle,
                                  color: AppColors.brandGreen,
                                )
                              : Icon(
                                  PhosphorIconsRegular.circle,
                                  color: Colors.grey.shade500,
                                ),
                          onTap: () {
                            onSelect(item);
                            Navigator.pop(context);
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openSocialEditor(String platform) {
    final handleCtrl =
        TextEditingController(text: _socialHandles[platform] ?? "");
    final urlCtrl = TextEditingController(text: _socialUrls[platform] ?? "");

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              MediaQuery.of(sheetContext).viewInsets.bottom + 20,
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
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        _platformIcons[platform],
                        color: AppColors.brandGreen,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "Edit $platform",
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (platform != "Website") ...[
                  const _SectionLabel("Username"),
                  const SizedBox(height: 6),
                  TextField(
                    controller: handleCtrl,
                    decoration: _editorInputDecoration("@yourhandle"),
                  ),
                  const SizedBox(height: 14),
                ],
                _SectionLabel(
                  platform == "Website" ? "Website URL" : "Link (optional)",
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: _editorInputDecoration(
                    platform == "Website"
                        ? "https://yourwebsite.com"
                        : "https://",
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _socialHandles[platform] = handleCtrl.text.trim();
                        _socialUrls[platform] = urlCtrl.text.trim();
                      });
                      Navigator.pop(sheetContext);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      "Save",
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _socialHandles[platform] = "";
                      _socialUrls[platform] = "";
                      _socialVisibility[platform] = true;
                    });
                    Navigator.pop(sheetContext);
                  },
                  child: Text(
                    "Remove",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade400,
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

  Future<void> _saveProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final headline = _headlineCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final bio = _bioCtrl.text.trim();
    final selectedBirthDate = _birthDate;

    if (selectedBirthDate == null) {
      _showSnack("Please select your birthdate.");
      return;
    }

    if (_countWords(headline) > 15) {
      _showSnack("Headline must be 15 words or less.");
      return;
    }

    if (bio.length > 500) {
      _showSnack("Bio must be 500 characters or less.");
      return;
    }

    final age = _calculateAge(selectedBirthDate);
    if (age < 13) {
      _showSnack("Too young. Users must be 13 years or older.");
      return;
    }

    if (email.isNotEmpty) {
      final emailOk = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
      if (!emailOk) {
        _showSnack("Enter a valid email address.");
        return;
      }
    }

    final Map<String, dynamic> socialsToSave = {};

    for (final platform in _platforms) {
      final rawHandle = (_socialHandles[platform] ?? "").trim();
      final rawUrl = (_socialUrls[platform] ?? "").trim();
      final visible = _socialVisibility[platform] ?? true;

      if (platform == "Website") {
        if (rawUrl.isEmpty && rawHandle.isEmpty) continue;

        socialsToSave[platform] = {
          "handle": rawHandle,
          "url": rawUrl,
          "visible": visible,
        };
        continue;
      }

      if (rawHandle.isEmpty && rawUrl.isEmpty) continue;

      final handle = rawHandle.isEmpty
          ? ""
          : rawHandle.startsWith("@")
              ? rawHandle
              : "@$rawHandle";

      socialsToSave[platform] = {
        "handle": handle,
        "url": rawUrl,
        "visible": visible,
      };
    }

    setState(() => _saving = true);

    try {
      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "intro": headline.isEmpty ? null : headline,
        "email": email.isEmpty ? null : email,
        "phone": phone.isEmpty ? null : phone,
        "birthDate": Timestamp.fromDate(
          DateTime(
            selectedBirthDate.year,
            selectedBirthDate.month,
            selectedBirthDate.day,
          ),
        ),
        "age": age,
        "gender": _gender,
        "pronouns": _pronouns,
        "bio": bio.isEmpty ? null : bio,
        "distanceMiles": _distanceMiles.round(),
        "socials": socialsToSave,
        "profileVisibility": {
          "showBirthday": _showBirthdayOnProfile,
        },

        "messagePrivacy": {
          "requireMessageRequests": _messageRequestsEnabled,
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      HapticFeedback.mediumImpact();
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(content: Text("Profile updated.")),
      );
    } catch (e) {
      debugPrint("Failed to save profile edits: $e");
      _showSnack("Failed to save changes.");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Widget _buildCounter({
    required int current,
    required int limit,
    String suffix = "",
  }) {
    final over = current > limit;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          "$current/$limit$suffix",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            fontFamily: "Nunito",
            color: over ? Colors.red : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    List<TextInputFormatter>? inputFormatters,
    int? counterLimit,
    bool countWords = false,
    Widget? suffixIcon,
    VoidCallback? onTap,
    bool readOnly = false,
    bool enabled = true,
  }) {
    Widget field() {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F7FA),
          borderRadius: BorderRadius.circular(18),
        ),
        child: TextFormField(
          controller: controller,
          readOnly: readOnly,
          enabled: enabled,
          onTap: onTap,
          keyboardType: keyboardType,
          maxLines: maxLines,
          inputFormatters: inputFormatters,
          cursorColor: AppColors.brandGreen,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            fontFamily: "Nunito",
            color: Colors.black87,
          ),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(
              color: Colors.black.withOpacity(.35),
              fontSize: 14,
              fontWeight: FontWeight.w500,
              fontFamily: "Nunito",
            ),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 14, right: 10),
              child: Icon(
                icon,
                size: 20,
                color: Colors.black.withOpacity(.56),
              ),
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 44,
            ),
            suffixIcon: suffixIcon,
            filled: true,
            fillColor: const Color(0xFFF5F7FA),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: maxLines > 1 ? 16 : 17,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(
                color: Colors.black,
                width: 1.2,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );
    }

    if (counterLimit == null) return field();

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final count = countWords
            ? _countWords(value.text)
            : _countChars(value.text);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCounter(
              current: count,
              limit: counterLimit,
              suffix: countWords ? " words" : "",
            ),
            field(),
          ],
        );
      },
    );
  }

  Widget _buildSelectorField({
    required String hintText,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: IgnorePointer(
        child: _buildInputField(
          controller: TextEditingController(text: hintText),
          hintText: hintText,
          icon: icon,
          readOnly: true,
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Icon(
              PhosphorIconsRegular.caretDown,
              size: 18,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      ),
    );
  }

  static InputDecoration _editorInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontFamily: "Nunito",
        color: Colors.black.withOpacity(.40),
        fontWeight: FontWeight.w500,
      ),
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
          color: AppColors.brandGreen,
          width: 1.2,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAF8),
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
          ),
        ),
      );
    }

    final miles = _distanceMiles.round();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8FAF8),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.black87),
        ),
        title: const Text(
          "Edit profile",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _EditCard(
                    title: "Basic info",
                    child: Column(
                      children: [
                        _buildInputField(
                          controller: _headlineCtrl,
                          hintText: "Headline",
                          icon: PhosphorIconsRegular.identificationCard,
                          counterLimit: 15,
                          countWords: true,
                          inputFormatters: [
                            WordLimitFormatter(15),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildInputField(
                          controller: _emailCtrl,
                          hintText: "Email address",
                          icon: PhosphorIconsRegular.envelopeSimple,
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 16),
                        _buildInputField(
                          controller: _phoneCtrl,
                          hintText: "Phone number",
                          icon: PhosphorIconsRegular.phone,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSelectorField(
                                hintText: _gender ?? "Gender",
                                icon: PhosphorIconsRegular.usersThree,
                                onTap: () => _showSelector(
                                  title: "Select gender",
                                  options: _genders,
                                  selected: _gender,
                                  onSelect: (v) => setState(() => _gender = v),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _buildSelectorField(
                                hintText: _pronouns ?? "Pronouns",
                                icon: PhosphorIconsRegular.chatCircleText,
                                onTap: () => _showSelector(
                                  title: "Select pronouns",
                                  options: _pronounList,
                                  selected: _pronouns,
                                  onSelect: (v) =>
                                      setState(() => _pronouns = v),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildInputField(
                          controller: birthDateCtrl,
                          hintText: "Birthdate *",
                          icon: PhosphorIconsRegular.cake,
                          readOnly: true,
                          onTap: _pickBirthDate,
                          suffixIcon: Padding(
                            padding: const EdgeInsets.only(right: 14),
                            child: Icon(
                              PhosphorIconsRegular.calendarBlank,
                              size: 20,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        _ProfilePrivacyToggle(
                          icon: PhosphorIconsRegular.cake,
                          title: "Show birthday",
                          subtitle: "Show your birthday in the “See more about” sheet.",
                          value: _showBirthdayOnProfile,
                          onChanged: (value) {
                            setState(() {
                              _showBirthdayOnProfile = value;
                            });
                          },
                        ),

                        const SizedBox(height: 10),

                        _ProfilePrivacyToggle(
                          icon: PhosphorIconsRegular.envelopeSimple,
                          title: "Message requests",
                          subtitle: "New people must send a request before they can message you.",
                          value: _messageRequestsEnabled,
                          onChanged: (value) {
                            setState(() {
                              _messageRequestsEnabled = value;
                            });
                          },
                        ),

                        const SizedBox(height: 16),
                        _buildInputField(
                          controller: _bioCtrl,
                          hintText:
                              "Tell people who you are and what makes you unique.",
                          icon: PhosphorIconsRegular.notePencil,
                          maxLines: 4,
                          counterLimit: 500,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(500),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _EditCard(
                    title: "Discovery radius",
                    subtitle: "Choose how far Pingmee should look around you.",
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.radar_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "$miles miles",
                                    style: const TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _distanceVibe(miles),
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black.withOpacity(.55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 7,
                            activeTrackColor: AppColors.brandGreen,
                            inactiveTrackColor: const Color(0xFFE5E7EB),
                            thumbColor: AppColors.brandGreen,
                            overlayColor: Colors.black.withOpacity(.08),
                          ),
                          child: Slider(
                            value: _distanceMiles,
                            min: minMiles.toDouble(),
                            max: maxMiles.toDouble(),
                            divisions: maxMiles - minMiles,
                            onChanged: _saving
                                ? null
                                : (value) =>
                                    setState(() => _distanceMiles = value),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _EditCard(
                    title: "Links",
                    subtitle: "Add the places people can find you outside Pingmee.",
                    child: Column(
                      children: _platforms.map((platform) {
                        final hasValue = platform == "Website"
                            ? ((_socialUrls[platform] ?? "")
                                        .trim()
                                        .isNotEmpty ||
                                    (_socialHandles[platform] ?? "")
                                        .trim()
                                        .isNotEmpty)
                            : ((_socialHandles[platform] ?? "")
                                        .trim()
                                        .isNotEmpty ||
                                    (_socialUrls[platform] ?? "")
                                        .trim()
                                        .isNotEmpty);

                        final display = platform == "Website"
                            ? ((_socialUrls[platform] ?? "")
                                    .trim()
                                    .isNotEmpty
                                ? (_socialUrls[platform] ?? "").trim()
                                : "Add website")
                            : ((_socialHandles[platform] ?? "")
                                    .trim()
                                    .isNotEmpty
                                ? (_socialHandles[platform] ?? "").trim()
                                : "Add handle");

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap:
                                _saving ? null : () => _openSocialEditor(platform),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: hasValue
                                    ? Colors.white
                                    : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.black.withOpacity(.06),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: hasValue
                                          ? AppColors.brandGreen
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Icon(
                                      _platformIcons[platform],
                                      size: 18,
                                      color: hasValue
                                          ? Colors.white
                                          : AppColors.brandGreen,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          platform,
                                          style: const TextStyle(
                                            fontFamily: "Nunito",
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          display,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: "Nunito",
                                            fontWeight: FontWeight.w600,
                                            color:
                                                Colors.black.withOpacity(.55),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _socialVisibility[platform] =
                                            !(_socialVisibility[platform] ?? true);
                                      });
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            (_socialVisibility[platform] ?? true)
                                                ? AppColors.brandGreen
                                                : Colors.transparent,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Icon(
                                        (_socialVisibility[platform] ?? true)
                                            ? Icons.visibility_rounded
                                            : Icons.visibility_off_rounded,
                                        size: 18,
                                        color:
                                            (_socialVisibility[platform] ?? true)
                                                ? Colors.white
                                                : Colors.grey.shade600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAF8).withOpacity(.96),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 18,
                    offset: const Offset(0, -8),
                    color: Colors.black.withOpacity(.045),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        backgroundColor: Colors.white,
                      ),
                      child: const Text(
                        "Cancel",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(
                        _saving ? "Saving..." : "Save changes",
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
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

class _ProfilePrivacyToggle extends StatelessWidget {
  const _ProfilePrivacyToggle({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: value ? Colors.black : Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 21,
              color: value ? Colors.white : Colors.black.withOpacity(.62),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.52),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),

          Switch.adaptive(
            value: value,
            activeColor: Colors.black,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _EditCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _EditCard({
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Color(0xFF111827),
            ),
          ),

          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                fontSize: 12.8,
                height: 1.25,
                color: Colors.black.withOpacity(.48),
              ),
            ),
          ],

          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: Colors.black.withOpacity(.62),
        ),
      ),
    );
  }
}