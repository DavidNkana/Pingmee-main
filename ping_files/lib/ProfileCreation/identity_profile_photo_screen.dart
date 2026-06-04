import 'dart:io';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_editor_plus/image_editor_plus.dart' as editor;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ping_files/ProfileCreation/identity_final_review_screen.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/services/profile_photo_flow.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';

enum ProfileChoiceMode { photo, avatar }

enum PingmeeFaceExpression {
  classic,
  wink,
  soft,
  playful,
  glasses,
  laugh,
  cool,
  surprised,
}

class IdentityProfilePhotoScreen extends StatefulWidget {
  const IdentityProfilePhotoScreen({super.key});

  @override
  State<IdentityProfilePhotoScreen> createState() =>
      _IdentityProfilePhotoScreenState();
}

class _IdentityProfilePhotoScreenState extends State<IdentityProfilePhotoScreen> {
  bool loading = true;
  bool saving = false;

  String? existingPhotoUrl;
  File? selectedFile;
  String? toastLine;

  ProfileChoiceMode mode = ProfileChoiceMode.photo;
  PingmeeFaceExpression selectedExpression = PingmeeFaceExpression.classic;
  Color selectedAvatarColor = const Color(0xFF3B82F6);

  final GlobalKey _avatarPreviewKey = GlobalKey();

  static const List<Color> avatarColors = [
    Color(0xFF3B82F6), // blue
    Color(0xFFEF4444), // red
    Color(0xFF38BDF8), // sky
    Color(0xFFF59E0B), // amber
    Color(0xFF22C55E), // green
    Color(0xFFEC4899), // pink
    Color(0xFF8B5CF6), // purple
    Color(0xFF14B8A6), // teal
  ];

  static const List<PingmeeFaceExpression> expressions = [
    PingmeeFaceExpression.classic,
    PingmeeFaceExpression.wink,
    PingmeeFaceExpression.soft,
    PingmeeFaceExpression.playful,
    PingmeeFaceExpression.glasses,
    PingmeeFaceExpression.laugh,
    PingmeeFaceExpression.cool,
    PingmeeFaceExpression.surprised,
  ];

  @override
  void initState() {
    super.initState();
    _loadExistingPhoto();
  }

  Future<void> _loadExistingPhoto() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        existingPhotoUrl = doc.data()!["photoUrl"] as String?;
      }
    } catch (e) {
      debugPrint("❌ Failed to load existing photo: $e");
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  bool get _hasRemotePhoto => (existingPhotoUrl ?? "").trim().isNotEmpty;
  bool get _hasEditedLocalPhoto => selectedFile != null;
  bool get _hasAnyPhoto => _hasEditedLocalPhoto || _hasRemotePhoto;

  ImageProvider? get _displayPhotoProvider {
    if (selectedFile != null) return FileImage(selectedFile!);
    if (_hasRemotePhoto) return NetworkImage(existingPhotoUrl!);
    return null;
  }

  bool get _showAvatarPreview =>
      mode == ProfileChoiceMode.avatar || !_hasAnyPhoto;

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
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

  Future<void> _choosePhotoSource() async {
    if (saving) return;

    setState(() => saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      final url = await updateUserImageFlow(
        context: context,
        uid: uid,
        existingUrl: existingPhotoUrl,
        firestoreField: "photoUrl",
        storageFolder: "profile_pictures",
        sheetTitle: "Profile photo",
      );

      if (!mounted) return;

      if (url != null) {
        setState(() {
          existingPhotoUrl = url;
          selectedFile = null;
          mode = ProfileChoiceMode.photo;
        });
        _tinyPop("Photo added ✅");
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _editCurrentPhoto() async {
    if (saving) return;

    if (selectedFile != null) {
      await _openEditorAndSetFile(selectedFile!);
      return;
    }

    if (_hasRemotePhoto) {
      try {
        final ByteData data = await NetworkAssetBundle(
          Uri.parse(existingPhotoUrl!),
        ).load(existingPhotoUrl!);

        final Uint8List bytes = data.buffer.asUint8List();

        final tempDir = await getTemporaryDirectory();
        final outPath = p.join(
          tempDir.path,
          "pingmee_existing_${DateTime.now().millisecondsSinceEpoch}.jpg",
        );

        final file = File(outPath);
        await file.writeAsBytes(bytes, flush: true);

        await _openEditorAndSetFile(file);
        return;
      } catch (e) {
        debugPrint("❌ Failed to load existing photo for edit: $e");
        _showSnack("Could not open editor for this photo.");
        return;
      }
    }

    _showSnack("Add a photo first, then edit it.");
  }

  Future<void> _openEditorAndSetFile(File inputFile) async {
    try {
      final Uint8List bytes = await inputFile.readAsBytes();

      final dynamic result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => editor.ImageEditor(image: bytes),
        ),
      );

      if (result == null) return;

      final Uint8List editedBytes = result as Uint8List;

      final tempDir = await getTemporaryDirectory();
      final outPath = p.join(
        tempDir.path,
        "pingmee_profile_${DateTime.now().millisecondsSinceEpoch}.jpg",
      );

      final outFile = File(outPath);
      await outFile.writeAsBytes(editedBytes, flush: true);

      if (!mounted) return;
      setState(() {
        selectedFile = outFile;
        mode = ProfileChoiceMode.photo;
      });

      _tinyPop("Profile-ready ✅");
    } catch (e) {
      debugPrint("❌ Editor error: $e");
      _showSnack("Could not open editor. Try again.");
    }
  }

  Future<String> _uploadFileToStorage({
    required String uid,
    required File file,
  }) async {
    final ext = p.extension(file.path).toLowerCase();
    final contentType = ext == ".png" ? "image/png" : "image/jpeg";

    final ref = FirebaseStorage.instance
        .ref()
        .child("profile_pictures")
        .child(uid)
        .child("profile_${DateTime.now().millisecondsSinceEpoch}${ext.isEmpty ? ".jpg" : ext}");

    await ref.putFile(
      file,
      SettableMetadata(contentType: contentType),
    );

    return ref.getDownloadURL();
  }

  Future<String> _uploadAvatarBytes({
    required String uid,
    required Uint8List bytes,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child("profile_pictures")
        .child(uid)
        .child("avatar_${DateTime.now().millisecondsSinceEpoch}.png");

    await ref.putData(
      bytes,
      SettableMetadata(contentType: "image/png"),
    );

    return ref.getDownloadURL();
  }

  Future<Uint8List?> _captureAvatarPreview() async {
    try {
      await Future.delayed(const Duration(milliseconds: 40));

      final boundary = _avatarPreviewKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;

      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 4);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint("❌ Avatar capture failed: $e");
      return null;
    }
  }

  Future<void> _persistUserPhoto({
    required String uid,
    required String photoUrl,
    required String source,
  }) async {
    await FirebaseFirestore.instance.collection("users").doc(uid).set({
      "photoUrl": photoUrl,
      "photoSource": source,
      if (source == "avatar")
        "avatarConfig": {
          "style": "pingmee_faces_v1",
          "expression": selectedExpression.name,
          "backgroundColor": selectedAvatarColor.value,
          "updatedAt": FieldValue.serverTimestamp(),
        },
    }, SetOptions(merge: true));
  }

  Future<void> _uploadAndContinue() async {
    if (saving) return;

    final uid = FirebaseAuth.instance.currentUser!.uid;

    setState(() => saving = true);
    try {
      String? finalPhotoUrl = existingPhotoUrl;

      if (mode == ProfileChoiceMode.avatar) {
        final avatarBytes = await _captureAvatarPreview();
        if (avatarBytes == null) {
          _showSnack("Could not generate avatar. Try again.");
          return;
        }

        finalPhotoUrl = await _uploadAvatarBytes(uid: uid, bytes: avatarBytes);

        await _persistUserPhoto(
          uid: uid,
          photoUrl: finalPhotoUrl,
          source: "avatar",
        );

        if (!mounted) return;
        setState(() {
          existingPhotoUrl = finalPhotoUrl;
          selectedFile = null;
        });
      } else {
        if (selectedFile != null) {
          finalPhotoUrl = await _uploadFileToStorage(uid: uid, file: selectedFile!);

          await _persistUserPhoto(
            uid: uid,
            photoUrl: finalPhotoUrl,
            source: "photo",
          );

          if (!mounted) return;
          setState(() {
            existingPhotoUrl = finalPhotoUrl;
            selectedFile = null;
          });
        } else if (!_hasRemotePhoto) {
          _showSnack("Choose a photo or an avatar to continue.");
          return;
        } else {
          await _persistUserPhoto(
            uid: uid,
            photoUrl: existingPhotoUrl!,
            source: "photo",
          );
        }
      }

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const IdentityFinalReviewScreen(),
        ),
      );
    } catch (e) {
      debugPrint("❌ Failed to save profile choice: $e");
      _showSnack("Could not save your profile choice. Try again.");
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _tipLine() {
    if (_showAvatarPreview) {
      return "Pick a face, then choose a color below.";
    }
    if (!_hasAnyPhoto) {
      return "Tap the circle to add a photo.";
    }
    return "Use your real photo, or switch to a Pingmee face.";
  }

  String _expressionLabel(PingmeeFaceExpression expression) {
    switch (expression) {
      case PingmeeFaceExpression.classic:
        return "Classic";
      case PingmeeFaceExpression.wink:
        return "Wink";
      case PingmeeFaceExpression.soft:
        return "Soft";
      case PingmeeFaceExpression.playful:
        return "Playful";
      case PingmeeFaceExpression.glasses:
        return "Glasses";
      case PingmeeFaceExpression.laugh:
        return "Laugh";
      case PingmeeFaceExpression.cool:
        return "Cool";
      case PingmeeFaceExpression.surprised:
        return "Surprised";
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
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 9, totalSteps: 10),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_ten.png",
                        height: 250,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "Let's put a face to the name",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Use a real photo or choose a Pingmee face.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 18),

                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
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
                              color: OnboardingStyle.accentLine,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.lightbulb_outline_rounded,
                            color: OnboardingStyle.action,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _tipLine(),
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 13,
                                color: Colors.grey,
                                fontWeight: FontWeight.w500,
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
                                color: OnboardingStyle.action,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                toastLine!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontFamily: "Nunito",
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    RepaintBoundary(
                      key: _avatarPreviewKey,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: 170,
                        height: 170,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _showAvatarPreview
                              ? selectedAvatarColor
                              : Colors.grey.shade100,
                          image: !_showAvatarPreview && _displayPhotoProvider != null
                              ? DecorationImage(
                                  image: _displayPhotoProvider!,
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _showAvatarPreview
                            ? ClipOval(
                                child: CustomPaint(
                                  painter: PingmeeFacePainter(
                                    expression: selectedExpression,
                                    strokeColor: Colors.white,
                                  ),
                                ),
                              )
                            : (_displayPhotoProvider == null
                                ? const Icon(
                                    Icons.camera_alt_rounded,
                                    size: 46,
                                    color: OnboardingStyle.action,
                                  )
                                : null),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Text(
                      _showAvatarPreview
                          ? "Pingmee face selected"
                          : (_displayPhotoProvider == null
                              ? "Tap below to add a photo"
                              : "Photo selected"),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 16),

                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: saving ? null : _choosePhotoSource,
                            icon: const Icon(Icons.add_a_photo_rounded),
                            label: const Text(
                              "Use photo",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: mode == ProfileChoiceMode.photo
                                  ? Colors.black
                                  : Colors.grey.shade100,
                              foregroundColor: mode == ProfileChoiceMode.photo
                                  ? Colors.white
                                  : Colors.black87,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: saving || !_hasAnyPhoto ? null : _editCurrentPhoto,
                            icon: const Icon(Icons.auto_fix_high_rounded),
                            label: const Text(
                              "Edit photo",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              elevation: 0,
                              side: BorderSide.none,
                              backgroundColor: Colors.grey.shade100,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            "OR",
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w800,
                              fontFamily: "Nunito",
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                      ],
                    ),

                    const SizedBox(height: 22),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Choose a face",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.grey.shade900,
                          fontFamily: "Nunito",
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: expressions.length,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 14,
                        childAspectRatio: 1,
                      ),
                      itemBuilder: (context, index) {
                        final expression = expressions[index];
                        final isSelected =
                            mode == ProfileChoiceMode.avatar &&
                            selectedExpression == expression;

                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              mode = ProfileChoiceMode.avatar;
                              selectedExpression = expression;
                            });
                            _tinyPop(_expressionLabel(expression));
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            decoration: BoxDecoration(
                              color: const Color(0xFF25272B),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isSelected
                                    ? OnboardingStyle.action
                                    : Colors.transparent,
                                width: 3,
                              ),
                              boxShadow: [
                                if (isSelected)
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.12),
                                    blurRadius: 18,
                                    spreadRadius: 1,
                                  ),
                              ],
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(18),
                                    child: CustomPaint(
                                      painter: PingmeeFacePainter(
                                        expression: expression,
                                        strokeColor: Colors.white,
                                      ),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    _expressionLabel(expression),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: "Nunito",
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 22),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Pick a background color",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.grey.shade900,
                          fontFamily: "Nunito",
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      height: 64,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: avatarColors.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final color = avatarColors[index];
                          final isSelected =
                              mode == ProfileChoiceMode.avatar &&
                              selectedAvatarColor.value == color.value;

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                mode = ProfileChoiceMode.avatar;
                                selectedAvatarColor = color;
                              });
                              _tinyPop("Color updated");
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: isSelected
                                      ? OnboardingStyle.action
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: isSelected
                                  ? const Icon(
                                      Icons.check_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
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
                      onPressed: saving ? null : _uploadAndContinue,
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

class PingmeeFacePainter extends CustomPainter {
  final PingmeeFaceExpression expression;
  final Color strokeColor;

  PingmeeFacePainter({
    required this.expression,
    required this.strokeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double stroke = w * 0.055;

    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.fill;

    final leftEye = Offset(w * 0.36, h * 0.38);
    final rightEye = Offset(w * 0.64, h * 0.38);
    final mouthRect = Rect.fromCenter(
      center: Offset(w * 0.5, h * 0.60),
      width: w * 0.34,
      height: h * 0.22,
    );

    void drawEyeDot(Offset center, {double rFactor = 0.04}) {
      canvas.drawCircle(center, w * rFactor, fillPaint);
    }

    void drawWink(Offset start, bool leftToRight) {
      final dx = w * 0.05;
      canvas.drawLine(
        Offset(start.dx - dx, start.dy),
        Offset(start.dx + dx, start.dy + (leftToRight ? dx * 0.2 : -dx * 0.2)),
        strokePaint,
      );
    }

    void drawSmile({double start = 0.20, double sweep = 2.75}) {
      canvas.drawArc(mouthRect, start, sweep, false, strokePaint);
    }

    void drawOpenMouth() {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.5, h * 0.62),
          width: w * 0.11,
          height: h * 0.15,
        ),
        strokePaint,
      );
    }

    void drawGlasses() {
      final r = w * 0.08;
      canvas.drawCircle(leftEye, r, strokePaint);
      canvas.drawCircle(rightEye, r, strokePaint);
      canvas.drawLine(
        Offset(leftEye.dx + r, leftEye.dy),
        Offset(rightEye.dx - r, rightEye.dy),
        strokePaint,
      );
      canvas.drawLine(
        Offset(leftEye.dx - r, leftEye.dy - r * 0.1),
        Offset(leftEye.dx - r * 1.8, leftEye.dy - r * 0.4),
        strokePaint,
      );
      canvas.drawLine(
        Offset(rightEye.dx + r, rightEye.dy - r * 0.1),
        Offset(rightEye.dx + r * 1.8, rightEye.dy - r * 0.4),
        strokePaint,
      );
    }

    void drawBrows({bool playful = false, bool angry = false}) {
      final browWidth = w * 0.10;
      final browY = h * 0.23;

      canvas.drawLine(
        Offset(leftEye.dx - browWidth * 0.5, browY + (angry ? w * 0.02 : 0)),
        Offset(leftEye.dx + browWidth * 0.5, browY + (playful ? -w * 0.02 : 0)),
        strokePaint,
      );

      canvas.drawLine(
        Offset(rightEye.dx - browWidth * 0.5, browY + (playful ? -w * 0.02 : 0)),
        Offset(rightEye.dx + browWidth * 0.5, browY + (angry ? w * 0.02 : 0)),
        strokePaint,
      );
    }

    switch (expression) {
      case PingmeeFaceExpression.classic:
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawSmile();
        break;

      case PingmeeFaceExpression.wink:
        drawEyeDot(leftEye);
        drawWink(rightEye, true);
        drawSmile();
        break;

      case PingmeeFaceExpression.soft:
        canvas.drawArc(
          Rect.fromCenter(center: leftEye, width: w * 0.10, height: h * 0.07),
          3.3,
          2.2,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(center: rightEye, width: w * 0.10, height: h * 0.07),
          3.3,
          2.2,
          false,
          strokePaint,
        );
        drawSmile(start: 0.28, sweep: 2.55);
        break;

      case PingmeeFaceExpression.playful:
        drawBrows(playful: true);
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawSmile(start: 0.20, sweep: 2.8);
        break;

      case PingmeeFaceExpression.glasses:
        drawGlasses();
        drawSmile(start: 0.22, sweep: 2.75);
        break;

      case PingmeeFaceExpression.laugh:
        canvas.drawArc(
          Rect.fromCenter(center: leftEye, width: w * 0.10, height: h * 0.07),
          3.25,
          2.0,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(center: rightEye, width: w * 0.10, height: h * 0.07),
          3.25,
          2.0,
          false,
          strokePaint,
        );
        canvas.drawArc(
          Rect.fromCenter(
            center: Offset(w * 0.5, h * 0.60),
            width: w * 0.22,
            height: h * 0.18,
          ),
          0.1,
          3.0,
          false,
          strokePaint,
        );
        break;

      case PingmeeFaceExpression.cool:
        canvas.drawLine(
          Offset(w * 0.27, h * 0.35),
          Offset(w * 0.45, h * 0.35),
          strokePaint,
        );
        canvas.drawLine(
          Offset(w * 0.55, h * 0.35),
          Offset(w * 0.73, h * 0.35),
          strokePaint,
        );
        canvas.drawLine(
          Offset(w * 0.45, h * 0.35),
          Offset(w * 0.55, h * 0.35),
          strokePaint,
        );
        drawSmile(start: 0.18, sweep: 2.65);
        break;

      case PingmeeFaceExpression.surprised:
        drawEyeDot(leftEye);
        drawEyeDot(rightEye);
        drawOpenMouth();
        break;
    }
  }

  @override
  bool shouldRepaint(covariant PingmeeFacePainter oldDelegate) {
    return oldDelegate.expression != expression ||
        oldDelegate.strokeColor != strokeColor;
  }
}