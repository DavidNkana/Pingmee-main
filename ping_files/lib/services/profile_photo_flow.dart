import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_editor_plus/image_editor_plus.dart' as editor;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ping_files/services/profile_avatar_picker_sheet.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

enum _ProfilePhotoAction {
  camera,
  gallery,
  editCurrent,
  chooseAvatar,
  restoreDefault,
}

class _PhotoActionTile extends StatelessWidget {
  const _PhotoActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 24,
      leading: Icon(
        icon,
        size: 24,
        color: Colors.black87,
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Colors.black87,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Colors.black.withOpacity(.55),
        ),
      ),
      onTap: onTap,
    );
  }
}

/// One pipeline:
/// BottomSheet -> Camera/Gallery/Avatar -> Editor (for real photos) -> Upload -> Save Firestore.
/// Returns final download URL or null (if user cancels).
Future<String?> updateUserImageFlow({
  required BuildContext context,
  required String uid,
  required String? existingUrl,
  required String firestoreField, // "photoUrl" | "coverUrl"
  required String storageFolder,
  String sheetTitle = "Image",
  bool haptics = true,
  bool allowRestoreDefault = false,
  String restoreDefaultLabel = "Revert to default cover",
  bool allowAvatarPicker = false,
}) async {
  void tinyPop() {
    if (!haptics) return;
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  void showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<File> copyToTemp(File input) async {
    final dir = await getTemporaryDirectory();
    final outPath = p.join(
      dir.path,
      "pingmee_profile_${DateTime.now().millisecondsSinceEpoch}.jpg",
    );
    return input.copy(outPath);
  }

  Future<File?> openEditor(File inputFile) async {
    try {
      final Uint8List bytes = await inputFile.readAsBytes();

      final dynamic result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => editor.ImageEditor(image: bytes),
        ),
      );

      if (result == null) return null;

      final Uint8List editedBytes = result as Uint8List;
      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        "pingmee_edited_${DateTime.now().millisecondsSinceEpoch}.jpg",
      );

      final outFile = File(outPath);
      await outFile.writeAsBytes(editedBytes, flush: true);
      return outFile;
    } catch (e) {
      debugPrint("❌ Editor error: $e");
      showSnack("Could not open editor. Try again.");
      return null;
    }
  }

  Future<File?> pickFromCameraNoGallerySave() async {
    XFile? captured;

    try {
      await CameraPicker.pickFromCamera(
        context,
        pickerConfig: CameraPickerConfig(
          enableRecording: false,
          textDelegate: const EnglishCameraPickerTextDelegate(),
          onXFileCaptured: (XFile file, CameraPickerViewType viewType) {
            captured = file;
            Navigator.of(context).pop();
            return true;
          },
        ),
      );

      if (captured == null) return null;

      final rawFile = File(captured!.path);
      if (!await rawFile.exists()) {
        showSnack("Could not read captured photo. Try again.");
        return null;
      }

      return copyToTemp(rawFile);
    } catch (e) {
      debugPrint("❌ Camera capture error: $e");
      showSnack("Could not capture photo. Try again.");
      return null;
    }
  }

  Future<File?> pickFromGallery() async {
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      showSnack("Please allow photo access to select an image.");
      return null;
    }

    try {
      final List<AssetEntity>? assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: const AssetPickerConfig(
          maxAssets: 1,
          requestType: RequestType.image,
        ),
      );

      if (assets == null || assets.isEmpty) return null;

      final file = await assets.first.file;
      if (file == null) {
        showSnack("Could not load this image. Try another one.");
        return null;
      }

      return file;
    } catch (e) {
      debugPrint("❌ Gallery picker error: $e");
      showSnack("Something went wrong opening your gallery.");
      return null;
    }
  }

  Future<File?> loadExistingUrlAsFile(String url) async {
    try {
      final ByteData data = await NetworkAssetBundle(Uri.parse(url)).load(url);
      final Uint8List bytes = data.buffer.asUint8List();

      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        "pingmee_existing_${DateTime.now().millisecondsSinceEpoch}.jpg",
      );

      final file = File(outPath);
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (e) {
      debugPrint("❌ Failed to load existing photo: $e");
      showSnack("Could not load existing photo.");
      return null;
    }
  }

  Future<String> uploadAvatarSelection({
    required ProfileAvatarSelection selection,
  }) async {
    final Uint8List bytes = await renderProfileAvatarPng(selection);

    final ref = FirebaseStorage.instance
        .ref()
        .child(storageFolder)
        .child(uid)
        .child("avatar_${DateTime.now().millisecondsSinceEpoch}.png");

    await ref.putData(
      bytes,
      SettableMetadata(contentType: "image/png"),
    );

    final downloadUrl = await ref.getDownloadURL();

    await FirebaseFirestore.instance.collection("users").doc(uid).set({
      firestoreField: downloadUrl,
      "updatedAt": FieldValue.serverTimestamp(),
      if (firestoreField == "photoUrl") ...{
        "photoSource": "avatar",
        "avatarConfig": {
          "style": "pingmee_faces_v1",
          "expression": selection.expression.name,
          "backgroundColor": selection.backgroundColor.value,
          "updatedAt": FieldValue.serverTimestamp(),
        },
      },
    }, SetOptions(merge: true));

    return downloadUrl;
  }

  Future<String?> uploadAndSave(File file) async {
    try {
      final fileName = "${DateTime.now().millisecondsSinceEpoch}.jpg";
      final ref = FirebaseStorage.instance
          .ref()
          .child("$storageFolder/$uid/$fileName");

      await ref.putFile(
        file,
        SettableMetadata(contentType: "image/jpeg"),
      );

      final url = await ref.getDownloadURL();

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        firestoreField: url,
        "updatedAt": FieldValue.serverTimestamp(),
        if (firestoreField == "photoUrl") ...{
          "photoSource": "photo",
          "avatarConfig": FieldValue.delete(),
        },
      }, SetOptions(merge: true));

      return url;
    } on FirebaseException catch (e) {
      debugPrint("❌ FirebaseException code=${e.code}");
      debugPrint("❌ message=${e.message}");
      debugPrint("❌ details=${e.toString()}");
      showSnack(
        "Save failed: ${e.code}${e.message != null ? " • ${e.message}" : ""}",
      );
      return null;
    } catch (e) {
      debugPrint("❌ Upload/save failed (non-firebase): $e");
      showSnack("Save failed: $e");
      return null;
    }
  }

  tinyPop();

  final _ProfilePhotoAction? pickedAction =
      await showModalBottomSheet<_ProfilePhotoAction>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: false,
    builder: (sheetContext) {
      final hasExisting = (existingUrl ?? "").trim().isNotEmpty;

      return SafeArea(
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
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
                Text(
                  sheetTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    fontFamily: "Nunito",
                  ),
                ),
                const SizedBox(height: 14),

                ListTile(
                  leading: const Icon(Icons.camera_alt_rounded),
                  title: const Text(
                    "Take a photo",
                    style: TextStyle(fontFamily: "Nunito"),
                  ),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _ProfilePhotoAction.camera,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_rounded),
                  title: const Text(
                    "Choose from gallery",
                    style: TextStyle(fontFamily: "Nunito"),
                  ),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _ProfilePhotoAction.gallery,
                  ),
                ),


                if (hasExisting) ...[
                  const SizedBox(height: 6),
                  ListTile(
                    leading: const Icon(Icons.auto_fix_high_rounded),
                    title: const Text(
                      "Edit current photo",
                      style: TextStyle(fontFamily: "Nunito"),
                    ),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      _ProfilePhotoAction.editCurrent,
                    ),
                  ),
                ],

                if (allowAvatarPicker)
                  _PhotoActionTile(
                    icon: Icons.sentiment_satisfied_alt_rounded,
                    title: "Choose avatar",
                    subtitle: "Use a Pingmee face instead",
                    onTap: () => Navigator.pop(
                      sheetContext,
                      _ProfilePhotoAction.chooseAvatar,
                    ),
                  ),

                if (allowRestoreDefault) ...[
                  const SizedBox(height: 6),
                  ListTile(
                    leading: const Icon(Icons.refresh_rounded),
                    title: Text(
                      restoreDefaultLabel,
                      style: const TextStyle(fontFamily: "Nunito"),
                    ),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      _ProfilePhotoAction.restoreDefault,
                    ),
                  ),
                ],

                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    },
  );

  if (pickedAction == null) return null;

  if (pickedAction == _ProfilePhotoAction.restoreDefault) {
    try {
      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        firestoreField: FieldValue.delete(),
        "updatedAt": FieldValue.serverTimestamp(),
        if (firestoreField == "photoUrl") ...{
          "photoSource": FieldValue.delete(),
          "avatarConfig": FieldValue.delete(),
        },
      }, SetOptions(merge: true));

      showSnack("Reverted successfully.");
      return "";
    } on FirebaseException catch (e) {
      debugPrint("❌ Restore default failed code=${e.code}");
      debugPrint("❌ message=${e.message}");
      showSnack(
        "Could not revert: ${e.code}${e.message != null ? " • ${e.message}" : ""}",
      );
      return null;
    } catch (e) {
      debugPrint("❌ Restore default failed: $e");
      showSnack("Could not revert.");
      return null;
    }
  }

  if (pickedAction == _ProfilePhotoAction.chooseAvatar) {
    final selection = await showProfileAvatarPickerSheet(context);
    if (selection == null) return null;

    try {
      final avatarUrl = await uploadAvatarSelection(
        selection: selection,
      );
      showSnack("Avatar updated ✅");
      return avatarUrl;
    } on FirebaseException catch (e) {
      debugPrint("❌ Avatar upload failed code=${e.code}");
      debugPrint("❌ message=${e.message}");
      showSnack(
        "Could not save avatar: ${e.code}${e.message != null ? " • ${e.message}" : ""}",
      );
      return null;
    } catch (e) {
      debugPrint("❌ Avatar upload failed: $e");
      showSnack("Could not save avatar.");
      return null;
    }
  }

  File? baseFile;

  if (pickedAction == _ProfilePhotoAction.camera) {
    baseFile = await pickFromCameraNoGallerySave();
  } else if (pickedAction == _ProfilePhotoAction.gallery) {
    baseFile = await pickFromGallery();
  } else if (pickedAction == _ProfilePhotoAction.editCurrent) {
    final url = (existingUrl ?? "").trim();
    if (url.isEmpty) return null;
    baseFile = await loadExistingUrlAsFile(url);
  }

  if (baseFile == null) return null;

  final edited = await openEditor(baseFile);
  if (edited == null) return null;

  final finalUrl = await uploadAndSave(edited);
  return finalUrl;
}