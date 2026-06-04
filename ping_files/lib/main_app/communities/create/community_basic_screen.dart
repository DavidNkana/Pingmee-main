import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/main_app/communities/create/community_branding_screen.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
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

class CommunityBasicScreen extends StatefulWidget {
  const CommunityBasicScreen({
    super.key,
    required this.draft,
  });

  final CreateCommunityDraft draft;

  @override
  State<CommunityBasicScreen> createState() => _CommunityBasicScreenState();
}

class _CommunityBasicScreenState extends State<CommunityBasicScreen> {
  late final TextEditingController communityNameCtrl;
  late final TextEditingController headlineCtrl;
  late final TextEditingController bioCtrl;

  bool saving = false;

  @override
  void initState() {
    super.initState();
    communityNameCtrl = TextEditingController(text: widget.draft.communityName);
    headlineCtrl = TextEditingController(text: widget.draft.headline);
    bioCtrl = TextEditingController(text: widget.draft.shortBio);
  }

  @override
  void dispose() {
    communityNameCtrl.dispose();
    headlineCtrl.dispose();
    bioCtrl.dispose();
    super.dispose();
  }

  int _countWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }

  int _countChars(String text) => text.length;

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
  }) {
    Widget field() {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: TextFormField(
          controller: controller,
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
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(18)),
              borderSide: BorderSide(
                color: AppColors.brandGreen,
                width: 1.6,
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

  Future<void> _saveAndContinue() async {
    final communityName = communityNameCtrl.text.trim();
    final headline = headlineCtrl.text.trim();
    final bio = bioCtrl.text.trim();

    if (communityName.isEmpty || bio.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please fill in community name and short bio."),
        ),
      );
      return;
    }

    if (communityName.length > 40) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Community name must be 40 characters or less."),
        ),
      );
      return;
    }

    if (_countWords(headline) > 15) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Headline must be 15 words or less."),
        ),
      );
      return;
    }

    if (bio.length > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Short bio must be 180 characters or less."),
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      widget.draft.communityName = communityName;
      widget.draft.headline = headline;
      widget.draft.shortBio = bio;

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CommunityBrandingScreen(
            draft: widget.draft,
          ),
        ),
      );
    } catch (_) {
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
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.grey.shade200,
                        ),
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
                        fontWeight: FontWeight.w700,
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
              child: ProfileProgressBar(step: 1, totalSteps: 5),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/community_one.png",
                        height: 230,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildInputField(
                      controller: communityNameCtrl,
                      hintText: "Community name *",
                      icon: PhosphorIconsRegular.usersThree,
                      counterLimit: 40,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(40),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildInputField(
                      controller: headlineCtrl,
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
                      controller: bioCtrl,
                      hintText: "Short bio *",
                      icon: PhosphorIconsRegular.notePencil,
                      maxLines: 4,
                      counterLimit: 180,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(180),
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
                    backgroundColor: AppColors.brandGreen,
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