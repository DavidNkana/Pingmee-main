import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/main_app/communities/create/community_settings_screen.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
import 'package:ping_files/theme/colors2.dart';

class CommunityLinksContactScreen extends StatefulWidget {
  const CommunityLinksContactScreen({
    super.key,
    required this.draft,
    this.nextScreenBuilder,
  });

  final CreateCommunityDraft draft;

  /// Pass step 4 here when it exists.
  /// Example:
  /// nextScreenBuilder: (draft) => CommunitySettingsScreen(draft: draft),
  final Widget Function(CreateCommunityDraft draft)? nextScreenBuilder;

  @override
  State<CommunityLinksContactScreen> createState() =>
      _CommunityLinksContactScreenState();
}

class _CommunityLinksContactScreenState
    extends State<CommunityLinksContactScreen> {
  late final TextEditingController websiteCtrl;
  late final TextEditingController emailCtrl;
  late final TextEditingController phoneCtrl;

  bool saving = false;
  String? pressedPlatform;

  final List<String> platforms = [
    "Instagram",
    "TikTok",
    "X",
    "LinkedIn",
    "Facebook",
    "Threads",
    "YouTube",
    "WhatsApp",
  ];

  final Map<String, IconData> platformIcons = {
    "Instagram": FontAwesomeIcons.instagram,
    "TikTok": FontAwesomeIcons.tiktok,
    "X": FontAwesomeIcons.xTwitter,
    "LinkedIn": FontAwesomeIcons.linkedin,
    "Facebook": FontAwesomeIcons.facebook,
    "Threads": FontAwesomeIcons.threads,
    "YouTube": FontAwesomeIcons.youtube,
    "WhatsApp": FontAwesomeIcons.whatsapp,
  };

  @override
  void initState() {
    super.initState();

    websiteCtrl = TextEditingController(text: widget.draft.website);
    emailCtrl = TextEditingController(text: widget.draft.email);
    phoneCtrl = TextEditingController(text: widget.draft.phone);

    for (final platform in platforms) {
      widget.draft.socials.putIfAbsent(
        platform,
        () => CommunitySocialDraft(platform: platform),
      );
    }
  }

  @override
  void dispose() {
    websiteCtrl.dispose();
    emailCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  int get _connectedSocialsCount =>
      widget.draft.socials.values.where((item) => item.hasValue).length;

  String _normalizeWebsite(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    return value;
  }

  bool _isValidWebsite(String value) {
    if (value.trim().isEmpty) return true;
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    final goodScheme = uri.scheme == 'http' || uri.scheme == 'https';
    return goodScheme && uri.host.isNotEmpty && uri.host.contains('.');
  }

  bool _isValidEmail(String value) {
    if (value.trim().isEmpty) return true;
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    return emailRegex.hasMatch(value.trim());
  }

  bool _isValidPhone(String value) {
    if (value.trim().isEmpty) return true;
    final normalized = value.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    final phoneRegex = RegExp(r'^\+?[0-9]{7,15}$');
    return phoneRegex.hasMatch(normalized);
  }

  String _platformHelper(String platform) {
    switch (platform) {
      case "Instagram":
        return "Add your handle or page link.";
      case "TikTok":
        return "Useful if the community posts clips or promos.";
      case "X":
        return "Share updates or public announcements.";
      case "LinkedIn":
        return "Great for professional or campus communities.";
      case "Facebook":
        return "Useful for wider public reach.";
      case "Threads":
        return "Add your Threads page if you use it.";
      case "YouTube":
        return "Perfect for creator or media communities.";
      case "WhatsApp":
        return "Add a contact or invite link if relevant.";
      default:
        return "Add a handle or link.";
    }
  }

  String _platformPreview(String platform) {
    final entry = widget.draft.socials[platform];
    if (entry == null || !entry.hasValue) return "No link added";

    final handle = entry.handle.trim();
    final url = entry.url.trim();

    if (handle.isNotEmpty) {
      return handle.startsWith('@') ? handle : '@$handle';
    }

    return url;
  }

  String _summaryTitle() {
    if (_connectedSocialsCount == 0) return "No socials added";
    if (_connectedSocialsCount == 1) return "1 social added";
    return "$_connectedSocialsCount socials added";
  }

  String _summarySubtitle() {
    final hasWebsite = websiteCtrl.text.trim().isNotEmpty;
    final hasEmail = emailCtrl.text.trim().isNotEmpty;
    final hasPhone = phoneCtrl.text.trim().isNotEmpty;

    final directCount = [hasWebsite, hasEmail, hasPhone].where((e) => e).length;

    if (directCount == 0 && _connectedSocialsCount == 0) {
      return "Add at least one contact path so the page feels real.";
    }

    if (directCount > 0 && _connectedSocialsCount > 0) {
      return "Clean. You have direct contact and social presence.";
    }

    if (directCount > 0) {
      return "Direct contact added. Social links are optional.";
    }

    return "Social presence added. Direct contact is still optional.";
  }

  void _toggleVisibility(String platform) {
    final entry = widget.draft.socials[platform];
    if (entry == null) return;

    setState(() {
      entry.visible = !entry.visible;
    });

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  void _openSocialEditor(String platform) {
    final entry = widget.draft.socials[platform]!;
    final handleCtrl = TextEditingController(text: entry.handle);
    final urlCtrl = TextEditingController(text: entry.url);

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
              left: 24,
              right: 24,
              top: 18,
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
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
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        platformIcons[platform],
                        color: AppColors.brandGreen,
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
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(PhosphorIconsBold.x),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildBottomSheetInput(
                  controller: handleCtrl,
                  hintText: "Handle or username",
                  icon: PhosphorIconsRegular.at,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                _buildBottomSheetInput(
                  controller: urlCtrl,
                  hintText: "Profile or invite link (optional)",
                  icon: PhosphorIconsRegular.linkSimpleHorizontal,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        entry.handle = handleCtrl.text.trim();
                        entry.url = urlCtrl.text.trim();
                      });

                      Navigator.pop(context);

                      try {
                        HapticFeedback.selectionClick();
                      } catch (_) {}
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(40),
                      ),
                    ),
                    child: const Text(
                      "Save",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      entry.handle = '';
                      entry.url = '';
                      entry.visible = true;
                    });
                    Navigator.pop(context);
                  },
                  child: Text(
                    "Remove",
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

  Widget _buildBottomSheetInput({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction? textInputAction,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      cursorColor: AppColors.brandGreen,
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
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
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
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

  Widget _buildSectionTitle(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: "Nunito",
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFamily: "Nunito",
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.05),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              widget.draft.hasAnyContactPath
                  ? PhosphorIconsBold.checkCircle
                  : PhosphorIconsRegular.linkSimpleHorizontal,
              color: AppColors.brandGreen,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _summaryTitle(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFamily: "Nunito",
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _summarySubtitle(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFamily: "Nunito",
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          if (widget.draft.hasAnyContactPath)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.brandGreen,
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
    );
  }

  Widget _buildSocialCard(String platform) {
    final entry = widget.draft.socials[platform]!;
    final hasValue = entry.hasValue;
    final isPressed = pressedPlatform == platform;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => pressedPlatform = platform),
      onTapCancel: () => setState(() => pressedPlatform = null),
      onTapUp: (_) => setState(() => pressedPlatform = null),
      onTap: () => _openSocialEditor(platform),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        scale: isPressed ? 0.985 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: hasValue
                  ? AppColors.brandGreen.withOpacity(.12)
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
                          ? AppColors.brandGreen.withOpacity(.10)
                          : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      platformIcons[platform],
                      color: AppColors.brandGreen,
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
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _platformHelper(platform),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            fontFamily: "Nunito",
                            color: Colors.grey.shade600,
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
                        color: AppColors.brandGreen,
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
                  GestureDetector(
                    onTap: () => _openSocialEditor(platform),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            hasValue
                                ? PhosphorIconsRegular.pencilSimple
                                : PhosphorIconsRegular.plus,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            hasValue ? "Edit" : "Add",
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _toggleVisibility(platform),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: entry.visible
                            ? AppColors.brandGreen
                            : Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: entry.visible
                            ? null
                            : Border.all(color: Colors.grey.shade200),
                      ),
                      child: Icon(
                        entry.visible
                            ? PhosphorIconsRegular.eye
                            : PhosphorIconsRegular.eyeSlash,
                        size: 18,
                        color:
                            entry.visible ? Colors.white : Colors.grey.shade600,
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

  Future<void> _saveAndContinue() async {
    final normalizedWebsite = _normalizeWebsite(websiteCtrl.text);
    final email = emailCtrl.text.trim();
    final phone = phoneCtrl.text.trim();

    if (normalizedWebsite.isNotEmpty && !_isValidWebsite(normalizedWebsite)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter a valid website link."),
        ),
      );
      return;
    }

    if (!_isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter a valid email address."),
        ),
      );
      return;
    }

    if (!_isValidPhone(phone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please enter a valid phone number."),
        ),
      );
      return;
    }

    if (normalizedWebsite.isEmpty && email.isEmpty && phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Add at least one contact path before continuing."),
        ),
      );
      return;
    }

    widget.draft.website = normalizedWebsite;
    widget.draft.email = email;
    widget.draft.phone = phone;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunitySettingsScreen(
          draft: widget.draft,
        ),
      ),
    );
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
                    onTap: saving ? null : () => Navigator.pop(context),
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
              child: ProfileProgressBar(step: 3, totalSteps: 5),
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
                        "assets/images/onboarding_seven.png",
                        height: 230,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _buildSummaryCard(),
                    const SizedBox(height: 22),

                    _buildSectionTitle(
                      "Website",
                      "Add the main link people should trust first.",
                    ),
                    _buildInputField(
                      controller: websiteCtrl,
                      hintText: "Website",
                      icon: PhosphorIconsRegular.globeHemisphereWest,
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 18),

                    _buildSectionTitle(
                      "Email and phone",
                      "Optional, but useful for direct contact and credibility.",
                    ),
                    _buildInputField(
                      controller: emailCtrl,
                      hintText: "Community email",
                      icon: PhosphorIconsRegular.envelopeSimple,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 14),
                    _buildInputField(
                      controller: phoneCtrl,
                      hintText: "Phone number",
                      icon: PhosphorIconsRegular.phone,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9+\s\-\(\)]'),
                        ),
                        LengthLimitingTextInputFormatter(20),
                      ],
                    ),
                    const SizedBox(height: 22),

                    _buildSectionTitle(
                      "Socials",
                      "These can stay optional, but they make the page feel alive.",
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 1,
                            color: Colors.grey.shade200,
                          ),
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
                          child: Container(
                            height: 1,
                            color: Colors.grey.shade200,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    ...platforms.map(_buildSocialCard),

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
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
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