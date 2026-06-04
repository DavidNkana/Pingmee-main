import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_interests_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class LowerCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toLowerCase(),
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

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

class IdentityBasicScreen extends StatefulWidget {
  const IdentityBasicScreen({super.key});

  @override
  State<IdentityBasicScreen> createState() => _IdentityBasicScreenState();
}

class _IdentityBasicScreenState extends State<IdentityBasicScreen> {
  final TextEditingController fullNameCtrl = TextEditingController();
  final TextEditingController usernameCtrl = TextEditingController();
  final TextEditingController introCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController phoneCtrl = TextEditingController();
  final TextEditingController bioCtrl = TextEditingController();
  final TextEditingController birthDateCtrl = TextEditingController();

  DateTime? birthDate;
  String? gender;
  String? pronouns;

  bool saving = false;
  bool loading = true;

  final List<String> genders = [
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

  final List<String> pronounList = [
    "He / Him",
    "She / Her",
    "They / Them",
    "He / They",
    "She / They",
    "Ze / Zir",
    "Prefer not to say",
    "Other",
  ];

  @override
  void initState() {
    super.initState();
    _loadPreviousProfile();
  }

  @override
  void dispose() {
    fullNameCtrl.dispose();
    usernameCtrl.dispose();
    introCtrl.dispose();
    emailCtrl.dispose();
    phoneCtrl.dispose();
    bioCtrl.dispose();
    birthDateCtrl.dispose();
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

  Future<void> _loadPreviousProfile() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        fullNameCtrl.text = data['fullName'] ?? '';
        usernameCtrl.text = data['username'] ?? '';
        introCtrl.text = data['intro'] ?? '';
        bioCtrl.text = data['bio'] ?? '';
        emailCtrl.text = data['email'] ?? '';
        phoneCtrl.text = data['phone'] ?? '';

        final birthTs = data['birthDate'];
        if (birthTs is Timestamp) {
          birthDate = birthTs.toDate();
          birthDateCtrl.text = _formatBirthDate(birthDate!);
        }

        gender = data['gender'];
        pronouns = data['pronouns'];
      }
    } catch (e) {
      debugPrint("❌ Failed to load profile: $e");
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _showSelector({
    required String title,
    required List<String> options,
    required String? value,
    required Function(String) onSelect,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              ...options.map(
                (opt) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    opt,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      fontFamily: "Nunito",
                    ),
                  ),
                  trailing: opt == value
                      ? const Icon(
                          PhosphorIconsFill.checkCircle,
                          color: OnboardingStyle.action,
                        )
                      : Icon(
                          PhosphorIconsRegular.circle,
                          color: Colors.grey.shade500,
                        ),
                  onTap: () {
                    onSelect(opt);
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initialDate = birthDate ?? DateTime(now.year - 18, now.month, now.day);

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(now) ? now : initialDate,
      firstDate: DateTime(1900),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: OnboardingStyle.action,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        birthDate = picked;
        birthDateCtrl.text = _formatBirthDate(picked);
      });
    }
  }

  Widget _buildCounter({
    required String text,
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
          color: Colors.white,
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
          cursorColor: OnboardingStyle.action,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            fontFamily: "Nunito",
            color: Colors.black87,
          ),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              fontFamily: "Nunito",
            ),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 14, right: 10),
              child: Icon(
                icon,
                size: 20,
                color: Colors.grey.shade700,
              ),
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 44,
            ),
            suffixIcon: suffixIcon,
            filled: true,
            fillColor: Colors.white,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: maxLines > 1 ? 16 : 18,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide(
                color: Colors.grey.shade300,
                width: 1.1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(
                color: OnboardingStyle.action,
                width: 1.6,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide(
                color: Colors.grey.shade300,
                width: 1.1,
              ),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide(
                color: Colors.grey.shade300,
                width: 1.1,
              ),
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
              text: value.text,
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

  Future<void> _saveAndContinue() async {
    final fullName = fullNameCtrl.text.trim();
    final username = usernameCtrl.text.trim().toLowerCase();
    final intro = introCtrl.text.trim();
    final bio = bioCtrl.text.trim();
    final selectedBirthDate = birthDate;

    if (fullName.isEmpty ||
        username.isEmpty ||
        bio.isEmpty ||
        selectedBirthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all required fields.")),
      );
      return;
    }

    final age = _calculateAge(selectedBirthDate);

    if (age < 13) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Too young. Users must be 13 years or older."),
        ),
      );
      return;
    }

    if (fullName.length > 40) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Full name must be 40 characters or less."),
        ),
      );
      return;
    }

    if (_countWords(intro) > 15) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Headline must be 15 words or less."),
        ),
      );
      return;
    }

    if (bio.length > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Bio must be 500 characters or less."),
        ),
      );
      return;
    }

    final usernameRegex = RegExp(r'^[a-z0-9._]{3,30}$');
    if (!usernameRegex.hasMatch(username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Username can only contain letters, numbers, dots, and underscores (3–30 chars).",
          ),
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final db = FirebaseFirestore.instance;
      final userRef = db.collection("users").doc(uid);
      final usernameRef = db.collection("usernames").doc(username);

      final existing = await userRef.get();
      final currentUsername =
          (existing.data()?["username"] ?? "").toString().toLowerCase();
      final hasCreatedAt = existing.data()?["createdAt"] != null;

      if (username != currentUsername) {
        final takenDoc = await usernameRef.get();

        if (takenDoc.exists && takenDoc.data()?["uid"] != uid) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Username already taken. Please choose another."),
            ),
          );
          setState(() => saving = false);
          return;
        }

        await db.runTransaction((tx) async {
          if (currentUsername.isNotEmpty) {
            final oldRef = db.collection("usernames").doc(currentUsername);
            final oldDoc = await tx.get(oldRef);
            if (oldDoc.exists && oldDoc.data()?["uid"] == uid) {
              tx.delete(oldRef);
            }
          }

          tx.set(usernameRef, {
            "uid": uid,
            "claimedAt": FieldValue.serverTimestamp(),
          });

          tx.set(userRef, {
            "fullName": fullName,
            "fullName_lc": fullName.toLowerCase(),
            "username": username,
            "username_lc": username,
            "intro": intro.isNotEmpty ? intro : null,
            "birthDate": Timestamp.fromDate(
              DateTime(
                selectedBirthDate.year,
                selectedBirthDate.month,
                selectedBirthDate.day,
              ),
            ),
            "age": age,
            "gender": gender,
            "pronouns": pronouns,
            "bio": bio,
            "email": emailCtrl.text.trim().isNotEmpty
                ? emailCtrl.text.trim()
                : null,
            "phone": phoneCtrl.text.trim().isNotEmpty
                ? phoneCtrl.text.trim()
                : null,
            "profileLevel": 1,
            if (!hasCreatedAt) "createdAt": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        });
      } else {
        await userRef.set({
          "fullName": fullName,
          "fullName_lc": fullName.toLowerCase(),
          "username": username,
          "username_lc": username,
          "intro": intro.isNotEmpty ? intro : null,
          "birthDate": Timestamp.fromDate(
            DateTime(
              selectedBirthDate.year,
              selectedBirthDate.month,
              selectedBirthDate.day,
            ),
          ),
          "age": age,
          "gender": gender,
          "pronouns": pronouns,
          "bio": bio,
          "email":
              emailCtrl.text.trim().isNotEmpty ? emailCtrl.text.trim() : null,
          "phone":
              phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
          "profileLevel": 1,
          if (!hasCreatedAt) "createdAt": FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IdentityInterestsScreen(
            firstName: fullName,
          ),
        ),
      );
    } catch (e) {
      debugPrint("❌ Save failed: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Something went wrong. Please try again."),
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
        backgroundColor: Colors.white,
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
            const ProfileProgressBar(step: 1, totalSteps: 10),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_one.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 28),

                    _buildInputField(
                      controller: fullNameCtrl,
                      hintText: "Full name *",
                      icon: PhosphorIconsRegular.user,
                      counterLimit: 40,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(40),
                      ],
                    ),
                    const SizedBox(height: 16),

                    _buildInputField(
                      controller: usernameCtrl,
                      hintText: "Username *",
                      icon: PhosphorIconsRegular.at,
                      counterLimit: 30,
                      inputFormatters: [
                        LowerCaseTextFormatter(),
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-z0-9._]'),
                        ),
                        LengthLimitingTextInputFormatter(30),
                      ],
                    ),
                    const SizedBox(height: 16),

                    _buildInputField(
                      controller: introCtrl,
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
                      controller: emailCtrl,
                      hintText: "Email address",
                      icon: PhosphorIconsRegular.envelopeSimple,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),

                    _buildInputField(
                      controller: phoneCtrl,
                      hintText: "Phone number",
                      icon: PhosphorIconsRegular.phone,
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 16),

                    Row(
                      children: [
                        Expanded(
                          child: _buildSelectorField(
                            hintText: gender ?? "Gender",
                            icon: PhosphorIconsRegular.usersThree,
                            onTap: () => _showSelector(
                              title: "Select gender",
                              options: genders,
                              value: gender,
                              onSelect: (v) => setState(() => gender = v),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _buildSelectorField(
                            hintText: pronouns ?? "Pronouns",
                            icon: PhosphorIconsRegular.chatCircleText,
                            onTap: () => _showSelector(
                              title: "Select pronouns",
                              options: pronounList,
                              value: pronouns,
                              onSelect: (v) => setState(() => pronouns = v),
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
                    const SizedBox(height: 16),

                    _buildInputField(
                      controller: bioCtrl,
                      hintText: "Tell your people who you are and what makes you unique. *",
                      icon: PhosphorIconsRegular.notePencil,
                      maxLines: 4,
                      counterLimit: 500,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(500),
                      ],
                    ),

                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: saving ? null : _saveAndContinue,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                  child: Text(
                    saving ? "Saving..." : "Next",
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontFamily: "Poppins",
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}