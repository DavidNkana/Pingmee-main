import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ping_files/features/pings/ping_visibility.dart';
import 'package:ping_files/features/pings/create_ping_draft.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';

class CreatePingSheet extends StatefulWidget {
  final GeoPoint? initialGeoPoint;
  final ValueChanged<CreatePingResult>? onCreated;
  final CreatePingDraft draft;

  const CreatePingSheet({
    super.key,
    required this.initialGeoPoint,
    this.onCreated,
    required this.draft,
  });

  @override
  State<CreatePingSheet> createState() => _CreatePingSheetState();
}

class CreatePingResult {
  final String pingId;
  final String title;
  final GeoPoint geoPoint;
  final int mediaTotal;
  final int mediaUploaded;
  final int mediaFailed;

  const CreatePingResult({
    required this.pingId,
    required this.title,
    required this.geoPoint,
    required this.mediaTotal,
    required this.mediaUploaded,
    required this.mediaFailed,
  });

  bool get hasMedia => mediaTotal > 0;
  bool get hasMediaIssues => mediaFailed > 0;
}

class _CreatePingSheetState extends State<CreatePingSheet> with SingleTickerProviderStateMixin {
  late final _titleCtrl = widget.draft.titleCtrl;
  late final _descCtrl = widget.draft.descCtrl;
  late final _customCategoryCtrl = widget.draft.customCategoryCtrl;
  late final _tagCtrl = widget.draft.tagCtrl;
  late final _meetingPointCtrl = widget.draft.meetingPointCtrl;
  late final _maxMembersCtrl = widget.draft.maxMembersCtrl;

  String _createStage = "";
  double _overallUploadProgress = 0.0;

  int get _uploadedOkCount =>
      _media.where((m) => m.uploadState == MediaUploadState.done).length;

  int get _uploadFailedCount =>
      _media.where((m) => m.uploadState == MediaUploadState.failed).length;

  int get _uploadFinishedCount => _uploadedOkCount + _uploadFailedCount;

  final List<String> _targetInterests = [];
  final List<String> _targetSkills = [];
  List<String> _profileInterests = [];
  List<String> _profileSkills = [];
  bool _loadingProfileMatchData = true;

  final FocusNode _parkingFocusNode = FocusNode(
    debugLabel: 'ping_parking_focus',
    skipTraversal: true,
  );

  final FocusNode _titleFocusNode = FocusNode();
  final FocusNode _descFocusNode = FocusNode();
  final FocusNode _customCategoryFocusNode = FocusNode();
  final FocusNode _tagFocusNode = FocusNode();
  final FocusNode _meetingPointFocusNode = FocusNode();
  final FocusNode _maxMembersFocusNode = FocusNode();

  int? _parsedMaxMembers() {
    final raw = _maxMembersCtrl.text.trim();
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  void _recomputeOverallUploadProgress() {
    if (_media.isEmpty) {
      _overallUploadProgress = 0.0;
      return;
    }

    double total = 0.0;

    for (final m in _media) {
      switch (m.uploadState) {
        case MediaUploadState.idle:
          total += 0.0;
          break;
        case MediaUploadState.validating:
          total += 0.05;
          break;
        case MediaUploadState.uploading:
          total += m.uploadProgress.clamp(0.0, 1.0);
          break;
        case MediaUploadState.done:
        case MediaUploadState.failed:
          total += 1.0;
          break;
      }
    }

    _overallUploadProgress = (total / _media.length).clamp(0.0, 1.0);
  }

  GeoPoint? _liveGeoPoint;

  // Media (max 6) with upload state
  final List<PickedMedia> _media = [];
  String? _mediaErr;

  bool get _mediaFull => _media.length >= 6;

  void _removeMedia(PickedMedia m) {
    setState(() => _media.removeWhere((x) => x.id == m.id));
  }

  // ✅ File size validation (50MB max)
  static const int _maxFileSizeBytes = 50 * 1024 * 1024; // 50MB

  bool _validateFileSize(int sizeBytes, String filename) {
    if (sizeBytes > _maxFileSizeBytes) {
      final sizeMB = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
      _showError("$filename is ${sizeMB}MB. Max allowed is 50MB.");
      return false;
    }
    return true;
  }

  Future<File> _assetToFile(AssetEntity asset) async {
    final f = await asset.file;
    if (f == null) throw Exception("Could not read gallery media file.");
    return f;
  }

  @override
  void dispose() {
    _parkingFocusNode.dispose();
    _titleFocusNode.dispose();
    _descFocusNode.dispose();
    _customCategoryFocusNode.dispose();
    _tagFocusNode.dispose();
    _meetingPointFocusNode.dispose();
    _maxMembersFocusNode.dispose();
    super.dispose();
  }

  void _showBottomSnack(
    String message, {
    bool isError = false,
    bool isSuccess = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final mediaQuery = MediaQuery.of(context);
    final bottomOffset = mediaQuery.viewInsets.bottom > 0
        ? mediaQuery.viewInsets.bottom + 16
        : mediaQuery.padding.bottom + 20;

    final bgColor = isError
        ? const Color(0xFFB42318)
        : isSuccess
            ? const Color(0xFF166534)
            : const Color(0xFF1F2937);

    final icon = isError
        ? PhosphorIcons.warningCircle(PhosphorIconsStyle.fill)
        : isSuccess
            ? PhosphorIcons.checkCircle(PhosphorIconsStyle.fill)
            : PhosphorIcons.info(PhosphorIconsStyle.fill);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: bgColor,
          elevation: 0,
          duration: duration,
          dismissDirection: DismissDirection.down,
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomOffset),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  void _showError(String message) {
    _showBottomSnack(message, isError: true);
  }

  void _showSuccess(String message) {
    _showBottomSnack(
      message,
      isSuccess: true,
      duration: const Duration(seconds: 2),
    );
  }

  void _showInfo(String message) {
    _showBottomSnack(
      message,
      duration: const Duration(seconds: 2),
    );
  }

  Future<String> _uploadAny({
    required String path,
    File? file,
    Uint8List? bytes,
    required String contentType,
    void Function(double)? onProgress,
  }) async {
    debugPrint("🔄 Starting upload to: $path");
    final ref = FirebaseStorage.instance.ref().child(path);

    UploadTask task;
    if (file != null) {
      debugPrint("📁 Uploading file: ${file.path}");
      task = ref.putFile(file, SettableMetadata(contentType: contentType));
    } else if (bytes != null) {
      debugPrint("📦 Uploading bytes: ${bytes.length} bytes");
      task = ref.putData(bytes, SettableMetadata(contentType: contentType));
    } else {
      throw Exception("No file or bytes to upload");
    }

    // Listen to progress
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress(progress);
      });
    }

    try {
      await task;
      final url = await ref.getDownloadURL();
      debugPrint("✅ Upload successful: $url");
      return url;
    } catch (e) {
      debugPrint("❌ Upload failed: $e");
      rethrow;
    }
  }

  Future<String> _createPingCore(String uid) async {
    final firestore = FirebaseFirestore.instance;
    final pingRef = firestore.collection("pings").doc();
    final participantRef = pingRef.collection("participants").doc(uid);

    final now = DateTime.now();
    final startAt = now;
    final endsAt = _endsAt(startAt);

    // Ping chat lifecycle:
    // - Ping expires at endsAt
    // - Chat stays writable for 3 days after expiry
    // - Chat becomes read-only after 3 days
    // - Chat auto-archives after 4 days
    final chatReadOnlyAt = endsAt.add(const Duration(days: 3));
    final chatAutoArchiveAt = endsAt.add(const Duration(days: 4));

    final scheduledStart =
        _combineDateAndTime(_scheduledDate, _scheduledStartTime!);
    final scheduledEnd =
        _combineDateAndTime(_scheduledDate, _scheduledEndTime!);

    final gp = _liveGeoPoint ?? widget.initialGeoPoint;
    if (gp == null) {
      throw Exception("No location");
    }

    final accuracyMode = _accuracyMode;
    final accuracyRadiusMeters = _accuracyMeters();

    final mapGeoPoint = _buildStoredMapGeoPoint(
      pingId: pingRef.id,
      exactGeoPoint: gp,
      accuracyMode: accuracyMode,
      radiusMeters: accuracyRadiusMeters,
    );

    final categoryText = (_category ?? "").trim();

    final title = _titleCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final meetingPoint = _meetingPointCtrl.text.trim();
    final placeName = _placeName.trim();
    final privacy = _privacy.trim().toLowerCase();

    if (!const {"public", "verified", "friends"}.contains(privacy)) {
      throw Exception("Invalid privacy value: $privacy");
    }

    final keywords = _buildPingKeywords(
      title: title,
      description: desc,
      category: categoryText,
      tags: _tags,
      placeName: placeName,
      meetingPoint: meetingPoint,
    );

    final visibilityFields = Map<String, dynamic>.from(
      PingVisibility.buildPingAudienceFields(privacy: privacy),
    );
    final parsedMaxMembers = _parsedMaxMembers();

    // Force rule-critical fields instead of hoping the helper does it right.
    visibilityFields["privacy"] = privacy;

    if (visibilityFields["audience"] is Map) {
      final audience =
          Map<String, dynamic>.from(visibilityFields["audience"] as Map);
      audience["scope"] = privacy;
      visibilityFields["audience"] = audience;
    }

    final pingData = <String, dynamic>{
      "creatorId": uid,
      "category": categoryText,
      "category_lc": categoryText.toLowerCase(),
      ...visibilityFields,
      "title": title,
      "title_lc": title.toLowerCase(),
      "description": desc,
      "tags": _tags,
      "keywords": keywords,
      "createdAt": FieldValue.serverTimestamp(),
      "createdAtLocal": Timestamp.now(),
      "startAt": Timestamp.fromDate(startAt),
      "endsAt": Timestamp.fromDate(endsAt),
      "chatReadOnlyAt": Timestamp.fromDate(chatReadOnlyAt),
      "chatAutoArchiveAt": Timestamp.fromDate(chatAutoArchiveAt),
      "chatLifecycle": {
        "readOnly": false,
        "autoArchived": false,
        "warningMessage":
            "This ping has expired. Chat stays open for 3 days, then becomes read-only.",
      },
      "chatConfig": {
        "readOnly": false,
        "autoArchived": false,
      },
      "scheduledStartAt": Timestamp.fromDate(scheduledStart),
      "targetInterests": _targetInterests,
      "targetSkills": _targetSkills,
      "targetTerms": {
        ..._targetInterests.map((e) => e.trim().toLowerCase()),
        ..._targetSkills.map((e) => e.trim().toLowerCase()),
      }.toList(),
      "scheduledEndAt": Timestamp.fromDate(scheduledEnd),
      "viewCount": 0,
      "participantCount": 1,
      if (parsedMaxMembers != null) "maxMembers": parsedMaxMembers,
      "location": {
        "geopoint": gp, // real location kept for now
        "mapGeopoint": mapGeoPoint, // stable map display point
        "geohash": "",
        "placeName": placeName,
        "placeName_lc": placeName.toLowerCase(),
        "accuracyMode": accuracyMode,
        "accuracyRadiusMeters": accuracyRadiusMeters,
        "meetingPoint": meetingPoint,
      },
      "status": "active",
      "media": [],
      "mediaCount": 0,
      "requiresApproval": _requiresApproval,
    };

    debugPrint(
      "🧪 create ping payload => privacy=${pingData["privacy"]}, "
      "audience=${pingData["audience"]}, status=${pingData["status"]}, "
      "creatorId=${pingData["creatorId"]}",
    );

    try {
      await pingRef.set(pingData);
      debugPrint("✅ ping doc created: ${pingRef.id}");
    } catch (e, st) {
      debugPrint("❌ ping doc create failed: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }

    try {
      await participantRef.set({
        "uid": uid,
        "joinedAt": FieldValue.serverTimestamp(),
        "role": "creator",
        "status": "approved",
        "mutedInChat": false,
      });
      debugPrint("✅ creator participant created: $uid");
    } catch (e, st) {
      debugPrint("❌ creator participant create failed: $e");
      debugPrintStack(stackTrace: st);

      // Roll back the ping so you don't leave broken orphan docs.
      try {
        await pingRef.delete();
        debugPrint("↩️ rolled back ping doc after participant failure");
      } catch (rollbackError, rollbackSt) {
        debugPrint("❌ rollback delete failed: $rollbackError");
        debugPrintStack(stackTrace: rollbackSt);
      }

      rethrow;
    }

    return pingRef.id;
  }

  DateTime get _scheduledDate =>
      widget.draft.scheduledDate ?? DateTime.now();

  set _scheduledDate(DateTime v) => widget.draft.scheduledDate = v;

  TimeOfDay? get _scheduledStartTime => widget.draft.scheduledStartTime;
  set _scheduledStartTime(TimeOfDay? v) => widget.draft.scheduledStartTime = v;

  TimeOfDay? get _scheduledEndTime => widget.draft.scheduledEndTime;
  set _scheduledEndTime(TimeOfDay? v) => widget.draft.scheduledEndTime = v;

  List<String> _buildPingKeywords({
    required String title,
    required String description,
    required String category,
    required List<String> tags,
    required String placeName,
    required String meetingPoint,
  }) {
    final rawText = <String>[
      title,
      description,
      category,
      placeName,
      meetingPoint,
      ...tags,
    ].join(" ").toLowerCase();

    final rawTokens = rawText
        .replaceAll(RegExp(r"[^\w#\s]"), " ")
        .split(RegExp(r"\s+"))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .map((t) => t.startsWith("#") ? t.substring(1) : t)
        .where((t) => t.length >= 2)
        .toList();

    final expanded = <String>{...rawTokens};

    for (final t in rawTokens) {
      expanded.addAll(_synonymsFor(t));
    }

    for (int i = 0; i < rawTokens.length - 1; i++) {
      final joined = "${rawTokens[i]}${rawTokens[i + 1]}";
      expanded.add(joined);
      expanded.addAll(_synonymsFor(joined));
    }

    return expanded.take(80).toList();
  }

  List<String> _synonymsFor(String t) {
    switch (t) {
      case "photography":
        return [
          "camera",
          "photo",
          "photos",
          "photographer",
          "videography",
          "filming",
          "film",
          "cinematography",
          "contentcreation",
          "nature",
        ];
      case "filming":
        return [
          "videography",
          "cinematography",
          "film",
          "video",
          "photography",
          "contentcreation",
        ];
      case "videography":
        return [
          "filming",
          "cinematography",
          "video",
          "film",
          "photography",
        ];
      case "nature":
        return [
          "outdoors",
          "wildlife",
          "hiking",
          "trees",
          "travel",
          "photography",
          "filming",
        ];
      case "movies":
        return ["film", "cinema", "filming", "videography"];
      case "music":
        return ["beats", "singing", "production", "guitar", "piano"];
      case "fitness":
        return ["gym", "workout", "training", "coaching"];
      case "sports":
        return ["football", "soccer", "basketball", "running"];
      case "technology":
        return ["tech", "ai", "ml", "coding", "software"];
      case "business":
        return ["startup", "founder", "strategy", "networking"];
      case "art":
        return ["design", "creative", "drawing", "painting"];
      case "travel":
        return ["adventure", "outdoors", "nature"];
      case "content":
        return ["contentcreation", "creator", "media"];
      case "contentcreation":
        return ["content", "creator", "media", "photography", "filming"];
      case "chill":
        return ["hangout", "vibes", "relax", "linkup", "lowkey"];
      case "hangout":
        return ["chill", "linkup", "vibes"];
      case "gym":
        return ["fitness", "workout"];
      case "football":
        return ["soccer"];
      default:
        return const [];
    }
  }

  void _dismissKeyboard() {
    final current = FocusManager.instance.primaryFocus;
    current?.unfocus(disposition: UnfocusDisposition.scope);

    if (!mounted) return;

    FocusScope.of(context).requestFocus(_parkingFocusNode);
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_parkingFocusNode.hasFocus) {
        _parkingFocusNode.unfocus();
      }
    });
  }

  Future<void> _pickFiles() async {
    _dismissKeyboard();
    if (_creating) return;
    if (_mediaFull) return;

    try {
      final maxPick = 6 - _media.length;

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) return;

      final existingIds = _media.map((e) => e.id).toSet();

      for (final f in result.files) {
        if (_media.length >= 6) break;

        final path = f.path;
        if (path == null) continue;

        // ✅ Validate file size
        if (!_validateFileSize(f.size, f.name)) continue;

        final id = "file_${f.identifier ?? f.name}_${f.size}";
        if (existingIds.contains(id)) continue;

        final ext = p.extension(f.name).replaceFirst(".", "").toLowerCase();

        _media.add(
          PickedMedia(
            id: id,
            type: "file",
            file: f.path != null ? File(f.path!) : null,
            bytes: f.bytes,
            name: f.name,
            sizeBytes: f.size,
            ext: ext.isEmpty ? null : ext,
            contentType: _guessFileContentType(f.name),
            uploadState: MediaUploadState.idle,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _error = null;
        _mediaErr = null;
      });
    } catch (e) {
      debugPrint("❌ file pick error: $e");
      _showError("Couldn't open files. Try again.");
    }
  }

  String _guessFileContentType(String filename) {
    final ext = p.extension(filename).toLowerCase();
    switch (ext) {
      case ".pdf":
        return "application/pdf";
      case ".doc":
        return "application/msword";
      case ".docx":
        return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
      case ".ppt":
        return "application/vnd.ms-powerpoint";
      case ".pptx":
        return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
      case ".xls":
        return "application/vnd.ms-excel";
      case ".xlsx":
        return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
      case ".zip":
        return "application/zip";
      case ".txt":
        return "text/plain";
      default:
        return "application/octet-stream";
    }
  }

  Future<void> _uploadAndAttachMedia({required String pingId}) async {
    final pingRef = FirebaseFirestore.instance.collection("pings").doc(pingId);

    final uploaded = await _uploadPingMedia(pingId: pingId);
    final safeUploaded = _sanitizeMediaList(uploaded);

    await pingRef.set({
      "media": safeUploaded,
      "mediaCount": safeUploaded.length,
    }, SetOptions(merge: true));

    debugPrint(
      "✅ Media attach complete: ${safeUploaded.length}/${_media.length}",
    );
  }

  Future<File?> _mediaToFile(PickedMedia m) async {
    if (m.file != null) return m.file;
    if (m.asset != null) return await m.asset!.file;
    return null;
  }

  Future<File?> _ensureVideoThumbFile(PickedMedia m) async {
    try {
      if (m.isVideo && m.thumbBytes != null) {
        final dir = await getTemporaryDirectory();
        final out = File(p.join(dir.path, "ping_thumb_${m.id}.jpg"));
        await out.writeAsBytes(m.thumbBytes!, flush: true);
        return out;
      }

      final f = await _mediaToFile(m);
      if (f == null) return null;
      if (!m.isVideo) return null;

      final bytes = await vt.VideoThumbnail.thumbnailData(
        video: f.path,
        imageFormat: vt.ImageFormat.JPEG,
        maxWidth: 600,
        quality: 75,
      );

      if (bytes == null) return null;

      final dir = await getTemporaryDirectory();
      final out = File(p.join(dir.path, "ping_thumb_${m.id}.jpg"));
      await out.writeAsBytes(bytes, flush: true);
      return out;
    } catch (e) {
      debugPrint("❌ thumb gen error: $e");
      return null;
    }
  }

  String _guessContentType({required bool isVideo, required String path}) {
    final ext = p.extension(path).toLowerCase();

    if (isVideo) {
      if (ext == ".mov") return "video/quicktime";
      if (ext == ".webm") return "video/webm";
      if (ext == ".mkv") return "video/x-matroska";
      if (ext == ".avi") return "video/x-msvideo";
      return "video/mp4";
    } else {
      if (ext == ".png") return "image/png";
      if (ext == ".webp") return "image/webp";
      return "image/jpeg";
    }
  }

  Future<List<Map<String, dynamic>>> _uploadPingMedia({
    required String pingId,
  }) async {
    if (_media.isEmpty) return [];

    final List<Map<String, dynamic>> out = [];

    for (int i = 0; i < _media.length; i++) {
      final m = _media[i];

      try {
        if (mounted) {
          setState(() {
            _createStage = "Uploading media ${i + 1} of ${_media.length}...";
            m.uploadState = MediaUploadState.validating;
            _recomputeOverallUploadProgress();
          });
        }

        final f = await _mediaToFile(m);
        if (f == null || !await f.exists()) {
          if (mounted) {
            if (mounted) {
              setState(() {
                m.uploadState = MediaUploadState.failed;
                _recomputeOverallUploadProgress();
              });
            }
          }
          continue;
        }

        final sizeBytes = await f.length();
        if (sizeBytes > _maxFileSizeBytes) {
          if (mounted) {
            if (mounted) {
              setState(() {
                m.uploadState = MediaUploadState.failed;
                _recomputeOverallUploadProgress();
              });
            }
          }
          continue;
        }

        if (mounted) {
          setState(() {
            m.uploadState = MediaUploadState.uploading;
            m.uploadProgress = 0.0;
            _recomputeOverallUploadProgress();
          });
        }

        

        final suffix =
            "${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}";

        if (m.type == "image") {
          final url = await _uploadAny(
            path: "pings/$pingId/media/img_$suffix.jpg",
            file: f,
            contentType: "image/jpeg",
            onProgress: (progress) {
              if (mounted) {
                setState(() {
                  m.uploadProgress = progress;
                  _recomputeOverallUploadProgress();
                });
              }
            },
          );

          out.add({
            "type": "image",
            "url": url,
            "thumbUrl": url,
            "name": "image_$suffix.jpg",
            "sizeBytes": sizeBytes,
            "contentType": "image/jpeg",
          });

          if (mounted) {
            setState(() {
              m.uploadState = MediaUploadState.done;
              _recomputeOverallUploadProgress();
            });
          }
        } else if (m.type == "video") {
          final ext = p.extension(f.path).toLowerCase();
          final vidPath =
              "pings/$pingId/media/vid_$suffix${ext.isEmpty ? ".mp4" : ext}";

          final videoUrl = await _uploadAny(
            path: vidPath,
            file: f,
            contentType: _guessContentType(isVideo: true, path: f.path),
            onProgress: (progress) {
              if (mounted) {
                setState(() {
                  m.uploadProgress = progress;
                  _recomputeOverallUploadProgress();
                });
              }
            },
          );

          String thumbUrl = "";
          try {
            final thumbFile = await _ensureVideoThumbFile(m);
            if (thumbFile != null && await thumbFile.exists()) {
              thumbUrl = await _uploadAny(
                path: "pings/$pingId/media/thumb_$suffix.jpg",
                file: thumbFile,
                contentType: "image/jpeg",
              );
            }
          } catch (_) {
            thumbUrl = "";
          }

          out.add({
            "type": "video",
            "url": videoUrl,
            "thumbUrl": thumbUrl,
            "name": m.name ?? "video_$suffix${ext.isEmpty ? ".mp4" : ext}",
            "sizeBytes": sizeBytes,
            "contentType": _guessContentType(isVideo: true, path: f.path),
          });

          if (mounted) {
            setState(() {
              m.uploadState = MediaUploadState.done;
              _recomputeOverallUploadProgress();
            });
          }
        } else if (m.type == "file") {
          final ext = p.extension(m.name ?? f.path).toLowerCase();
          final fileName =
              (m.name ?? "file_$suffix${ext.isEmpty ? "" : ext}");
          final filePath =
              "pings/$pingId/media/file_$suffix${ext.isEmpty ? "" : ext}";

          final fileUrl = await _uploadAny(
            path: filePath,
            file: m.file,
            bytes: m.bytes,
            contentType: m.contentType ?? _guessFileContentType(fileName),
            onProgress: (progress) {
              if (mounted) {
                setState(() {
                  m.uploadProgress = progress;
                  _recomputeOverallUploadProgress();
                });
              }
            },
          );

          out.add({
            "type": "file",
            "url": fileUrl,
            "thumbUrl": "",
            "name": fileName,
            "sizeBytes": m.sizeBytes ?? sizeBytes,
            "contentType": m.contentType ?? _guessFileContentType(fileName),
            "ext": m.ext ?? ext.replaceFirst(".", ""),
          });

          if (mounted) {
            setState(() {
              m.uploadState = MediaUploadState.done;
              _recomputeOverallUploadProgress();
            });
          }
        }
      } catch (e) {
        debugPrint("❌ media upload failed for item ${m.id}: $e");
        if (mounted) {
          setState(() {
            m.uploadState = MediaUploadState.failed;
            _recomputeOverallUploadProgress();
          });
        }
        continue;
      }
    }

    return out;
  }

  List<Map<String, dynamic>> _sanitizeMediaList(
      List<Map<String, dynamic>> media) {
    return media.map((m) {
      return {
        "type": (m["type"] ?? "").toString(),
        "url": (m["url"] ?? "").toString(),
        "thumbUrl": (m["thumbUrl"] ?? "").toString(),
        "name": (m["name"] ?? "").toString(),
        "sizeBytes": m["sizeBytes"] ?? 0,
        "contentType": (m["contentType"] ?? "").toString(),
        "ext": (m["ext"] ?? "").toString(),
        "createdAt": Timestamp.now(),
      };
    }).toList();
  }

  Future<void> _pickMediaFromGallery() async {
    if (_creating) return;
    if (_media.length >= 6) return;

    try {
      final maxPick = 6 - _media.length;

      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        _showError("Allow gallery access to pick photos or videos.");
        return;
      }

      final assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          maxAssets: maxPick,
          requestType: RequestType.common,
          selectedAssets: _media
              .where((m) => m.asset != null)
              .map((m) => m.asset!)
              .toList(),
        ),
      );

      if (assets == null || assets.isEmpty) return;

      final existingIds = _media.map((e) => e.id).toSet();

      for (final a in assets) {
        if (_media.length >= 6) break;

        final id = "asset_${a.id}";
        if (existingIds.contains(id)) continue;

        // ✅ Get file to validate size
        final file = await a.file;
        if (file == null) {
          _showError("Couldn't read ${a.title ?? 'media'}. Try again.");
          continue;
        }

        final sizeBytes = await file.length();
        if (!_validateFileSize(sizeBytes, a.title ?? "Media")) continue;

        _media.add(
          PickedMedia(
            id: id,
            type: a.type == AssetType.video ? "video" : "image",
            asset: a,
            uploadState: MediaUploadState.idle,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _error = null;
        _mediaErr = null;
      });
    } catch (e) {
      debugPrint("❌ gallery pick error: $e");
      _showError("Couldn't open gallery. Try again.");
    }
  }

  Future<void> _pickMediaFromCamera() async {
    if (_creating) return;
    if (_mediaFull) return;

    try {
      XFile? captured;
      CameraPickerViewType? viewType;

      await CameraPicker.pickFromCamera(
        context,
        pickerConfig: CameraPickerConfig(
          enableRecording: true,
          textDelegate: const EnglishCameraPickerTextDelegate(),
          onXFileCaptured: (XFile file, CameraPickerViewType vt) {
            captured = file;
            viewType = vt;
            Navigator.of(context).pop();
            return true;
          },
        ),
      );

      if (captured == null) return;

      final f = File(captured!.path);
      if (!await f.exists()) {
        _showError("Couldn't read camera capture. Try again.");
        return;
      }

      // ✅ Validate size
      final sizeBytes = await f.length();
      if (!_validateFileSize(sizeBytes, "Camera capture")) return;

      final id = "cam_${DateTime.now().millisecondsSinceEpoch}";
      final isVid = viewType == CameraPickerViewType.video ||
          _looksLikeVideoPath(f.path);

      Uint8List? thumb;
      if (isVid) {
        thumb = await VideoThumbnail.thumbnailData(
          video: f.path,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: 600,
          quality: 75,
        );
      }

      setState(() {
        _error = null;
        _mediaErr = null;
        _media.add(
          PickedMedia(
            id: id,
            type: isVid ? "video" : "image",
            file: f,
            thumbBytes: thumb,
            uploadState: MediaUploadState.idle,
          ),
        );
      });
    } catch (e) {
      debugPrint("❌ camera pick error: $e");
      _showError("Couldn't open camera. Try again.");
    }
  }

  bool _looksLikeVideoPath(String path) {
    final ext = p.extension(path).toLowerCase();
    return [".mp4", ".mov", ".mkv", ".webm", ".avi"].contains(ext);
  }

  Future<void> _requestLocation() async {
    try {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        await Geolocator.openLocationSettings();

        final enabledNow = await Geolocator.isLocationServiceEnabled();
        if (!enabledNow) {
          _showError("Turn on location services to create a ping.");
          return;
        }
      }

      var perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      if (perm == LocationPermission.denied) {
        _showError("Location permission denied.");
        return;
      }

      if (perm == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
        _showError("Location permission is blocked. Enable it in settings.");
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );

      setState(() {
        _liveGeoPoint = GeoPoint(pos.latitude, pos.longitude);
        _placeName = "Location enabled";
      });

      _showSuccess("Location enabled.");
    } catch (e) {
      debugPrint("❌ requestLocation error: $e");
      _showError("Couldn't enable location. Try again.");
    }
  }

  bool _creating = false;
  String? _error;

  String? get _category => widget.draft.category;
  set _category(String? v) => widget.draft.category = v;

  bool get _categoryIsCustom => widget.draft.categoryIsCustom;
  set _categoryIsCustom(bool v) => widget.draft.categoryIsCustom = v;

  List<String> get _tags => widget.draft.tags;

  String get _privacy => widget.draft.privacy;
  set _privacy(String v) => widget.draft.privacy = v;

  int get _accuracyMode => widget.draft.accuracyMode;
  set _accuracyMode(int v) => widget.draft.accuracyMode = v;

  int get _durationMinutes => widget.draft.durationMinutes;
  set _durationMinutes(int v) => widget.draft.durationMinutes = v;

  bool get _startNow => widget.draft.startNow;
  set _startNow(bool v) => widget.draft.startNow = v;

  bool get _requiresApproval => widget.draft.requiresApproval;
  set _requiresApproval(bool v) => widget.draft.requiresApproval = v;

  String _placeName = "Nearby";

  @override
  void initState() {
    super.initState();
    _liveGeoPoint = widget.initialGeoPoint;
    if (_liveGeoPoint == null) _placeName = "Location unavailable";
  }


  static final RegExp _tagAllowed = RegExp(r"^[a-z0-9_]{2,20}$");
  static final List<String> _blockedSubstrings = [
    "porn",
    "sex",
    "nude",
    "kill",
    "murder",
    "rape",
    "weapon",
    "gun",
    "cocaine",
    "heroin",
    "meth",
    "fuck",
    "fucking",
  ];

  bool _isTagAllowed(String tag) {
    if (!_tagAllowed.hasMatch(tag)) return false;
    for (final b in _blockedSubstrings) {
      if (tag.contains(b)) return false;
    }
    return true;
  }

  void _applyCustomCategory() {
    final raw = _customCategoryCtrl.text.trim();
    if (raw.isEmpty) {
      _showError("Enter a custom category first.");
      return;
    }

    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (cleaned.length < 2) {
      _showError("Custom category is too short.");
      return;
    }

    if (cleaned.length > 24) {
      _showError("Custom category must be 24 characters or less.");
      return;
    }

    setState(() {
      _error = null;
      _category = cleaned;
      _categoryIsCustom = true;
      _customCategoryCtrl.clear();
    });

    FocusScope.of(context).unfocus();
    HapticFeedback.selectionClick();
  }
  

  void _addTag() {
    _dismissKeyboard();

    final raw = _tagCtrl.text.trim();
    if (raw.isEmpty) return;

    final cleaned = raw.startsWith("#") ? raw.substring(1) : raw;
    final tag = cleaned.trim().toLowerCase();

    if (tag.isEmpty) return;

    if (!_isTagAllowed(tag)) {
      _showError("That tag isn't allowed. Try a simple interest tag.");
      return;
    }

    if (_tags.contains(tag)) {
      _showInfo("That tag is already added.");
      _tagCtrl.clear();
      return;
    }

    if (_tags.length >= 5) {
      _showError("You can add up to 5 tags.");
      return;
    }

    setState(() {
      _tags.add(tag);
      _tagCtrl.clear();
    });
  }

  void _removeTag(String t) {
    _dismissKeyboard();
    setState(() => _tags.remove(t));
  }

  String _accuracyLabel() {
    switch (_accuracyMode) {
      case 0:
        return "Hidden (landmark)";
      case 1:
        return "Approx (recommended)";
      case 2:
        return "Exact";
      default:
        return "Approx";
    }
  }

  int _accuracyMeters() {
    switch (_accuracyMode) {
      case 0:
        return 1200;
      case 1:
        return 250;
      case 2:
        return 25;
      default:
        return 250;
    }
  }

  int _stableSeedFromString(String input) {
    var hash = 0x811C9DC5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash & 0x7fffffff;
  }

  double _seedUnit(int seed, int salt) {
    final mixed = (seed ^ (salt * 0x9E3779B9)) & 0x7fffffff;
    return mixed / 0x7fffffff;
  }

  GeoPoint _offsetGeoPoint(
    GeoPoint start,
    double meters,
    double bearingRad,
  ) {
    const earthRadius = 6371000.0;

    final angularDistance = meters / earthRadius;
    final lat1 = start.latitude * pi / 180.0;
    final lon1 = start.longitude * pi / 180.0;

    final lat2 = asin(
      sin(lat1) * cos(angularDistance) +
          cos(lat1) * sin(angularDistance) * cos(bearingRad),
    );

    final lon2 = lon1 +
        atan2(
          sin(bearingRad) * sin(angularDistance) * cos(lat1),
          cos(angularDistance) - sin(lat1) * sin(lat2),
        );

    return GeoPoint(
      lat2 * 180.0 / pi,
      lon2 * 180.0 / pi,
    );
  }

  GeoPoint? _buildStoredMapGeoPoint({
    required String pingId,
    required GeoPoint exactGeoPoint,
    required int accuracyMode,
    required int radiusMeters,
  }) {
    switch (accuracyMode) {
      case 0:
        // Hidden from everyone else on the map.
        return null;

      case 2:
        // Exact
        return exactGeoPoint;

      case 1:
      default:
        final safeRadius = max(120, radiusMeters);
        final seed = _stableSeedFromString(pingId);

        final bearing = _seedUnit(seed, 11) * 2 * pi;
        final distanceMeters =
            max(70.0, safeRadius * (0.38 + (_seedUnit(seed, 23) * 0.47)));

        return _offsetGeoPoint(
          exactGeoPoint,
          distanceMeters,
          bearing,
        );
    }
  }

  DateTime _endsAt(DateTime start) => start.add(const Duration(hours: 24));

  DateTime _combineDateAndTime(DateTime date, TimeOfDay time) {
    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  Future<void> _pickScheduleDate() async {
    _dismissKeyboard();

    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _scheduledDate,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );

    if (picked == null) return;

    setState(() {
      _scheduledDate = picked;
      _error = null;
    });
  }

  Future<void> _pickScheduledStartTime() async {
    _dismissKeyboard();

    final picked = await showTimePicker(
      context: context,
      initialTime:
          _scheduledStartTime ?? const TimeOfDay(hour: 11, minute: 30),
    );

    if (picked == null) return;

    setState(() {
      _scheduledStartTime = picked;
      _error = null;
    });
  }

  Future<void> _pickScheduledEndTime() async {
    _dismissKeyboard();

    final picked = await showTimePicker(
      context: context,
      initialTime: _scheduledEndTime ?? const TimeOfDay(hour: 14, minute: 0),
    );

    if (picked == null) return;

    setState(() {
      _scheduledEndTime = picked;
      _error = null;
    });
  }

  String _formatTimeOfDay12(TimeOfDay? t) {
    if (t == null) return "Select time";

    final hour12 = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
    final minute = t.minute.toString().padLeft(2, '0');
    final suffix = t.hour >= 12 ? "PM" : "AM";

    return "$hour12:$minute $suffix";
  }

  String _formatDateShort(DateTime d) {
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ];
    return "${d.day} ${months[d.month - 1]} ${d.year}";
  }

  bool _validateCreatePingForm() {
    final title = _titleCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final meetingPoint = _meetingPointCtrl.text.trim();
    final customCategory = _customCategoryCtrl.text.trim();
    final privacy = _privacy.trim().toLowerCase();
    final maxRaw = _maxMembersCtrl.text.trim();
    final parsedMaxMembers = _parsedMaxMembers();

    if (maxRaw.isNotEmpty && (parsedMaxMembers == null || parsedMaxMembers < 1)) {
      _showError("Max people must be at least 1.");
      return false;
    }

    if (_liveGeoPoint == null && widget.initialGeoPoint == null) {
      _showError("Turn on location before creating a ping.");
      return false;
    }

    if (!const {"public", "verified", "friends"}.contains(privacy)) {
      _showError("Invalid ping privacy. Pick Public, Verified, Friends.");
      return false;
    }

    if (_category == null || _category!.trim().isEmpty) {
      _showError("Choose a category for your ping.");
      return false;
    }

    final selectedCategory = (_category ?? "").trim();

    if (_category == null || selectedCategory.isEmpty) {
      _showError("Choose a category for your ping.");
      return false;
    }

    if (_categoryIsCustom && selectedCategory.toLowerCase() == "custom") {
      _showError("Add your custom category.");
      return false;
    }

    if (title.isEmpty) {
      _showError("Ping title is required.");
      return false;
    }

    if (desc.isEmpty) {
      _showError("Description is required.");
      return false;
    }

    if (meetingPoint.isEmpty) {
      _showError("Meeting point is required.");
      return false;
    }

    if (_scheduledStartTime == null) {
      _showError("Select when the ping starts.");
      return false;
    }

    if (_scheduledEndTime == null) {
      _showError("Select when the ping ends.");
      return false;
    }

    final scheduledStart =
        _combineDateAndTime(_scheduledDate, _scheduledStartTime!);
    final scheduledEnd =
        _combineDateAndTime(_scheduledDate, _scheduledEndTime!);

    if (!scheduledEnd.isAfter(scheduledStart)) {
      _showError("Ping end time must be after the start time.");
      return false;
    }

    return true;
  }

  Future<void> _createPing() async {
    FocusScope.of(context).unfocus();

    if (_creating) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    if (!_validateCreatePingForm()) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showError("You need to be logged in to create a ping.");
      return;
    }

    final gp = _liveGeoPoint ?? widget.initialGeoPoint;
    if (gp == null) {
      _showError("Turn on location before creating a ping.");
      return;
    }

    setState(() {
      _creating = true;
      _createStage = "Creating your ping...";
      _overallUploadProgress = 0.0;
    });

    try {
      final pingId = await _createPingCore(uid);

      unawaited(
        PingmeeStreamChatService.instance.openPingChat(pingId).catchError((error) {
          debugPrint('❌ create/open ping chat after ping create failed: $error');
        }),
      );

      bool mediaStepFailed = false;

      if (_media.isNotEmpty) {
        try {
          if (mounted) {
            setState(() {
              _createStage = "Preparing media upload...";
              _recomputeOverallUploadProgress();
            });
          }

          await _uploadAndAttachMedia(pingId: pingId);

          unawaited(
            PingmeeStreamChatService.instance.openPingChat(pingId).catchError((error) {
              debugPrint('❌ update ping chat image after media upload failed: $error');
            }),
          );
        } catch (e, st) {
          mediaStepFailed = true;
          debugPrint("⚠️ ping created, but media attach failed: $e");
          debugPrintStack(stackTrace: st);
        }
      } else {
        if (mounted) {
          setState(() {
            _createStage = "Finalizing...";
          });
        }
      }

      final result = CreatePingResult(
        pingId: pingId,
        title: _titleCtrl.text.trim(),
        geoPoint: gp,
        mediaTotal: _media.length,
        mediaUploaded: _uploadedOkCount,
        mediaFailed: _uploadFailedCount,
      );

      try {
        widget.onCreated?.call(result);
      } catch (e, st) {
        debugPrint("⚠️ onCreated callback failed: $e");
        debugPrintStack(stackTrace: st);
      }

      try {
        widget.draft.clear();
      } catch (e, st) {
        debugPrint("⚠️ draft.clear failed: $e");
        debugPrintStack(stackTrace: st);
      }

      if (!mounted) return;

      Navigator.of(context).pop(result);

      if (mediaStepFailed) {
        _showInfo("Ping created, but some media could not be uploaded.");
      }
    } catch (e, st) {
      debugPrint("❌ create ping core failed: $e");
      debugPrintStack(stackTrace: st);

      if (mounted) {
        _showError("Couldn't create ping. Check your connection and try again.");
      }
    } finally {
      if (mounted) {
        setState(() {
          _creating = false;
          _createStage = "";
        });
      }
    }
  }

  static const _defaultCategories = <_CatItem>[
    _CatItem("Hangout", PhosphorIcons.confetti),
    _CatItem("Study", PhosphorIcons.bookOpenText),
    _CatItem("Gym", PhosphorIcons.barbell),
    _CatItem("Gaming", PhosphorIcons.gameController),
    _CatItem("Networking", PhosphorIcons.handshake),
    _CatItem("Help / Fix", PhosphorIcons.wrench),
    _CatItem("Event", PhosphorIcons.ticket),
    _CatItem("Support / Talk", PhosphorIcons.chatCircleText),
    _CatItem("Food", PhosphorIcons.hamburger),
    _CatItem("Music", PhosphorIcons.musicNotes),
    _CatItem("Sports", PhosphorIcons.soccerBall),
    _CatItem("Work Session", PhosphorIcons.laptop),
    _CatItem("Explore", PhosphorIcons.compass),
    _CatItem("Instant help", PhosphorIcons.siren),
    _CatItem("Custom", PhosphorIcons.sparkle),
  ];

  static const _suggestedTags = <String>[
    "startup",
    "flutter",
    "music",
    "fitness",
    "anime",
    "football",
    "design",
    "coding",
    "career",
    "gaming",
  ];

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F9),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: const Color(0xFFF6F7F9),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _creating ? null : _createPing,
              style: ElevatedButton.styleFrom(
                backgroundColor:Colors.black,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size.fromHeight(58),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
              child: _creating
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          PhosphorIcons.paperPlaneTilt(
                            PhosphorIconsStyle.light,
                          ),
                          size: 18,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          "Create Ping",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),

      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                22 + mq.padding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _IconSquareButton(
                        icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.light),
                        onTap: _creating ? null : () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "Create a Ping",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF16181D),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Simple, clear, and easy for nearby people to trust.",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                height: 1.35,
                                color: Colors.black.withOpacity(.52),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  

                  const SizedBox(height: 18),
                  const Center(child: _CreatePingTopArtwork()),
                  const SizedBox(height: 20),

                  _SectionCard(
                    title: "Privacy",
                    subtitle: "Choose who this ping is for.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SegmentPills(
                          value: _privacy,
                          items: const [
                            _SegItem("public", "Public"),
                            _SegItem("verified", "Verified"),
                            _SegItem("friends", "Friends"),
                          ],
                          onChanged: _creating
                              ? null
                              : (v) => setState(() => _privacy = v),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Join requests",
                    subtitle: "Choose whether people join instantly or request first.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Card(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreen.withOpacity(.12),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  PhosphorIcons.userList(PhosphorIconsStyle.light),
                                  size: 18,
                                  color: AppColors.brandGreen,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "Approve join requests",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1F2937),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _requiresApproval
                                          ? "People will request first, then you approve them from Manage Ping."
                                          : "People can join instantly when they tap Join Ping.",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w400,
                                        height: 1.4,
                                        color: Colors.black.withOpacity(.55),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Transform.scale(
                                scale: 0.96,
                                child: CupertinoSwitch(
                                  value: _requiresApproval,
                                  activeColor: AppColors.brandGreen,
                                  onChanged: _creating
                                      ? null
                                      : (value) {
                                          HapticFeedback.selectionClick();
                                          setState(() {
                                            _requiresApproval = value;
                                          });
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Capacity",
                    subtitle: "Limit how many people can be inside this ping.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Field(
                          label: "Max people",
                          hint: "Leave empty for unlimited",
                          controller: _maxMembersCtrl,
                          focusNode: _maxMembersFocusNode,
                          onTapOutsideDismiss: _dismissKeyboard,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          helper: "Includes you.",
                        ),
                      ],
                    ),
                  ),

                  if (_liveGeoPoint == null) ...[
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: "Location access",
                      subtitle:
                          "Pingmee needs location before this ping can go live.",
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Card(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: AppColors.brandGreen.withOpacity(.12),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    PhosphorIcons.navigationArrow(
                                      PhosphorIconsStyle.light,
                                    ),
                                    size: 18,
                                    color: AppColors.brandGreen,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "Location is currently off",
                                        style: TextStyle(
                                          fontFamily: "Nunito",
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1F2937),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        "People need a safe place to find your ping. Turn it on first.",
                                        style: TextStyle(
                                          fontFamily: "Nunito",
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w400,
                                          height: 1.4,
                                          color: Colors.black.withOpacity(.55),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _TinyPillButton(
                                label: "Enable location",
                                icon: PhosphorIcons.navigationArrow(
                                  PhosphorIconsStyle.light,
                                ),
                                onTap: _creating ? null : _requestLocation,
                              ),
                              _TinyPillButton(
                                label: "Why?",
                                icon: PhosphorIcons.info(
                                  PhosphorIconsStyle.light,
                                ),
                                onTap: _creating
                                    ? null
                                    : () => _showInfo(
                                          "Location is required before you can create a ping.",
                                        ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Category",
                    subtitle: "Pick the main reason people should open this ping.",
                    trailing: _category == null
                        ? null
                        : Text(
                            "Selected",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.brandGreen,
                            ),
                          ),
                    child: Builder(
                      builder: (context) {
                        final baseCategories = _defaultCategories
                            .where((c) => c.label.toLowerCase() != "custom")
                            .toList();

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: baseCategories.map((c) {
                                final selected = _category == c.label;

                                return _CategoryChip(
                                  label: c.label,
                                  icon: c.icon(PhosphorIconsStyle.light),
                                  selected: selected,
                                  isCustom: false,
                                  onTap: _creating
                                      ? null
                                      : () {
                                          _dismissKeyboard();
                                          HapticFeedback.selectionClick();
                                          setState(() {
                                            _error = null;
                                            _category = c.label;
                                            _categoryIsCustom = false;
                                            _customCategoryCtrl.clear();

                                            if (_tags.isEmpty) {
                                              final sug = _suggestTagsForCategory(c.label);
                                              _tags.addAll(sug.take(2));
                                            }
                                          });
                                        },
                                );
                              }).toList(),
                            ),

                            const SizedBox(height: 12),

                            _PingCustomCategoryCard(
                              isSelected: _categoryIsCustom,
                              onTap: _creating
                                  ? null
                                  : () {
                                      _dismissKeyboard();
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _error = null;
                                        _category = "Custom";
                                        _categoryIsCustom = true;
                                      });
                                    },
                            ),

                            if (_categoryIsCustom) ...[
                              const SizedBox(height: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Custom category",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black.withOpacity(.76),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _customCategoryCtrl,
                                          focusNode: _customCategoryFocusNode,
                                          onTapOutside: (_) => _dismissKeyboard(),
                                          textCapitalization: TextCapitalization.sentences,
                                          onSubmitted: (_) => _applyCustomCategory(),
                                          maxLength: 24,
                                          buildCounter: (
                                            _, {
                                            required currentLength,
                                            required isFocused,
                                            maxLength,
                                          }) =>
                                              null,
                                          style: const TextStyle(
                                            fontFamily: "Nunito",
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF1F2937),
                                          ),
                                          decoration: InputDecoration(
                                            hintText: "e.g. Photography, Chess, Basketball",
                                            hintStyle: TextStyle(
                                              fontFamily: "Nunito",
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                              color: Colors.black.withOpacity(.34),
                                            ),
                                            filled: true,
                                            fillColor: const Color(0xFFF2F4F8),
                                            contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 15,
                                            ),
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
                                              borderSide: BorderSide(
                                                color: AppColors.brandGreen.withOpacity(.18),
                                                width: 1.2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      _IconPillAdd(
                                        onTap: _creating ? null : _applyCustomCategory,
                                      ),
                                    ],
                                  ),
                                  if (_categoryIsCustom &&
                                    (_category ?? "").trim().isNotEmpty &&
                                    (_category ?? "").toLowerCase() != "custom") ...[
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.brandGreen.withOpacity(.10),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(
                                            color: AppColors.brandGreen.withOpacity(.16),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              PhosphorIcons.sparkle(PhosphorIconsStyle.light),
                                              size: 14,
                                              color: AppColors.brandGreen,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _category!,
                                              style: const TextStyle(
                                                fontFamily: "Nunito",
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF166534),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            GestureDetector(
                                              onTap: _creating
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        _category = "Custom";
                                                      });
                                                    },
                                              child: Icon(
                                                PhosphorIcons.x(PhosphorIconsStyle.bold),
                                                size: 14,
                                                color: AppColors.brandGreen,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                ],
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Details",
                    subtitle: "Keep this short, warm, and easy to understand.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Field(
                          label: "Ping title *",
                          hint: "I'm at East Park — anyone up for a quick chat?",
                          controller: _titleCtrl,
                          focusNode: _titleFocusNode,
                          onTapOutsideDismiss: _dismissKeyboard,
                          maxLen: 50,
                          helper: "Short, clear, trustworthy.",
                        ),
                        const SizedBox(height: 16),
                        _Field(
                          label: "Description *",
                          hint:
                              "I'm here for 45 mins. Let's discuss startups or tech careers.",
                          controller: _descCtrl,
                          focusNode: _descFocusNode,
                          onTapOutsideDismiss: _dismissKeyboard,
                          maxLines: 6,
                          maxLen: 1000,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Interests",
                    subtitle: "Help the right people notice this ping.",
                    trailing: Text(
                      "${_tags.length}/5",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.48),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _tagCtrl,
                                focusNode: _tagFocusNode,
                                onTapOutside: (_) => _dismissKeyboard(),
                                textCapitalization: TextCapitalization.sentences,
                                onSubmitted: (_) => _addTag(),
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF1F2937),
                                ),
                                decoration: InputDecoration(
                                  hintText: "Add tag (e.g. startup, flutter, music)",
                                  hintStyle: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black.withOpacity(.34),
                                  ),
                                  filled: true,
                                  fillColor: const Color(0xFFF2F4F8),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 15,
                                  ),
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
                                    borderSide: BorderSide(
                                      color: AppColors.brandGreen.withOpacity(.18),
                                      width: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            _IconPillAdd(onTap: _creating ? null : _addTag),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _suggestedTags.map((t) {
                            final taken = _tags.contains(t);
                            return _SuggestChip(
                              text: "#$t",
                              selected: taken,
                              onTap: _creating
                                  ? null
                                  : () {
                                      _dismissKeyboard();
                                      if (taken) return;
                                      _tagCtrl.text = t;
                                      _addTag();
                                    },
                            );
                          }).toList(),
                        ),
                        if (_tags.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _tags.map((t) {
                              return _TagChip(
                                text: "#$t",
                                onRemove: _creating ? null : () => _removeTag(t),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Location",
                    subtitle: "Let people find you without killing safety.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Card(
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreen.withOpacity(.12),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(
                                  PhosphorIcons.mapPin(
                                    PhosphorIconsStyle.light,
                                  ),
                                  size: 17,
                                  color: AppColors.brandGreen,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _placeName,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          "Show my location",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black.withOpacity(.72),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _SegmentPills(
                          value: _accuracyMode.toString(),
                          items: const [
                            _SegItem("0", "Hidden"),
                            _SegItem("1", "Approx"),
                            _SegItem("2", "Exact"),
                          ],
                          onChanged: _creating
                              ? null
                              : (v) {
                                  HapticFeedback.selectionClick();
                                  setState(() {
                                    _accuracyMode = int.parse(v);

                                    if (_privacy == "public" &&
                                        _accuracyMode == 2) {
                                      _accuracyMode = 1;
                                      _showInfo(
                                        "For safety, Exact is not allowed on Public. Switched to Approx.",
                                      );
                                    }
                                  });
                                },
                        ),
                        const SizedBox(height: 12),
                        _Card(
                          child: Text(
                            _accuracyMode == 0
                                ? "Hidden keeps your exact spot private and only hints at the general area."
                                : _accuracyMode == 1
                                    ? "Approx shows a safer nearby radius. This is the recommended setting."
                                    : "Exact shows your real position. Use it only when the audience is trusted.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13.5,
                              fontWeight: FontWeight.w400,
                              height: 1.45,
                              color: Colors.black.withOpacity(.56),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _Field(
                          label: "Meeting point *",
                          hint:
                              "e.g. Food court entrance / Shoprite side / Outside café",
                          controller: _meetingPointCtrl,
                          focusNode: _meetingPointFocusNode,
                          onTapOutsideDismiss: _dismissKeyboard,
                          maxLen: 60,
                          dense: true,
                          helper: "Required so people know exactly where to meet.",
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Schedule",
                    subtitle: "Tell people exactly when this ping is happening.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ScheduleInfoCard(
                          label: "Date",
                          value: _formatDateShort(_scheduledDate),
                          icon: PhosphorIcons.calendarBlank(
                            PhosphorIconsStyle.light,
                          ),
                          onTap: _creating ? null : _pickScheduleDate,
                        ),
                        const SizedBox(height: 10),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final twoUp = constraints.maxWidth >= 390;
                            final itemWidth = twoUp
                                ? (constraints.maxWidth - 10) / 2
                                : constraints.maxWidth;

                            return Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                SizedBox(
                                  width: itemWidth,
                                  child: _ScheduleInfoCard(
                                    label: "Starts",
                                    value: _formatTimeOfDay12(
                                      _scheduledStartTime,
                                    ),
                                    icon: PhosphorIcons.clockCountdown(
                                      PhosphorIconsStyle.light,
                                    ),
                                    onTap: _creating
                                        ? null
                                        : _pickScheduledStartTime,
                                  ),
                                ),
                                SizedBox(
                                  width: itemWidth,
                                  child: _ScheduleInfoCard(
                                    label: "Ends",
                                    value: _formatTimeOfDay12(_scheduledEndTime),
                                    icon: PhosphorIcons.clockAfternoon(
                                      PhosphorIconsStyle.light,
                                    ),
                                    onTap: _creating
                                        ? null
                                        : _pickScheduledEndTime,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _Card(
                          child: Text(
                            "This is the actual time people should show up, not just when the ping was created.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13.5,
                              fontWeight: FontWeight.w400,
                              height: 1.45,
                              color: Colors.black.withOpacity(.56),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _SectionCard(
                    title: "Media",
                    subtitle: "Optional, but useful when people need context.",
                    trailing: Text(
                      "${_media.length}/6",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.48),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 560
                                ? 3
                                : constraints.maxWidth >= 360
                                    ? 2
                                    : 1;
                            final itemWidth = (constraints.maxWidth -
                                    ((columns - 1) * 10)) /
                                columns;

                            return Row(
                              children: [
                                Expanded(
                                  child: _SourceButton(
                                    label: "Gallery",
                                    icon: PhosphorIcons.images(PhosphorIconsStyle.light),
                                    onTap: _mediaFull ? null : _pickMediaFromGallery,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _SourceButton(
                                    label: "Camera",
                                    icon: PhosphorIcons.camera(PhosphorIconsStyle.light),
                                    onTap: _mediaFull ? null : _pickMediaFromCamera,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _SourceButton(
                                    label: "Files",
                                    icon: PhosphorIcons.paperclip(PhosphorIconsStyle.light),
                                    onTap: _mediaFull ? null : _pickFiles,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        if (_media.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _MediaGrid(
                            items: _media,
                            onRemove: _creating ? null : _removeMedia,
                          ),
                        ] else ...[
                          const SizedBox(height: 14),
                          _Card(
                            child: Column(
                              children: [
                                Icon(
                                  PhosphorIcons.image(
                                    PhosphorIconsStyle.light,
                                  ),
                                  size: 34,
                                  color: Colors.black.withOpacity(.22),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  "No media added yet",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black.withOpacity(.42),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Use the buttons above to add photos, videos, or files.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 13,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black.withOpacity(.34),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  

                  const SizedBox(height: 12),

                  Center(
                    child: Text(
                      "Be respectful • Meet in safe public places • Report bad behavior",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_creating) ...[
            const ModalBarrier(
              dismissible: false,
              color: Color.fromRGBO(0, 0, 0, 0.12),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + mq.padding.bottom,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121826),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.18),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _createStage.isEmpty
                            ? "Creating your ping..."
                            : _createStage,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 8,
                            value: _overallUploadProgress <= 0
                                ? null
                                : _overallUploadProgress.clamp(0.0, 1.0),
                            backgroundColor: Colors.white.withOpacity(.12),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      )
    );
  }

  List<String> _suggestTagsForCategory(String cat) {
    final c = cat.toLowerCase();
    if (c.contains("study")) return ["study", "career", "coding"];
    if (c.contains("gym")) return ["fitness", "gym", "health"];
    if (c.contains("gaming")) return ["gaming", "fifa", "fun"];
    if (c.contains("network")) return ["startup", "career", "tech"];
    if (c.contains("help")) return ["help", "community", "urgent"];
    if (c.contains("support")) return ["talk", "support", "friends"];
    if (c.contains("event")) return ["event", "music", "fun"];
    if (c.contains("hangout")) return ["hangout", "chill", "friends"];
    if (c.contains("instant")) return ["urgent", "help", "nearby"];
    return ["nearby", "ping", "meet"];
  }
}

/// ----------------- UI Components -----------------

class _CatItem {
  final String label;
  final IconData Function(PhosphorIconsStyle) icon;
  const _CatItem(this.label, this.icon);
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SectionTitle({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(.78),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  color: Colors.black.withOpacity(.50),
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

class _ScheduleInfoCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;

  const _ScheduleInfoCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withOpacity(.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                size: 18,
                color: AppColors.brandGreen,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(.45),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withOpacity(disabled ? .38 : .78),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              PhosphorIcons.caretRight(PhosphorIconsStyle.light),
              size: 16,
              color: Colors.black.withOpacity(.32),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool isCustom;
  final VoidCallback? onTap;

  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.isCustom,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppColors.brandGreen
        : const Color(0xFFF4F5F7);

    final fg = selected
        ? Colors.white
        : const Color(0xFF4B5563);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.brandGreen.withOpacity(.18),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: fg),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
            if (isCustom) ...[
              const SizedBox(width: 8),
              Icon(
                PhosphorIcons.pencilSimpleLine(
                  PhosphorIconsStyle.light,
                ),
                size: 14,
                color: selected
                    ? Colors.white.withOpacity(.92)
                    : fg.withOpacity(.72),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final int maxLines;
  final int? maxLen;
  final String? helper;
  final bool dense;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;
  final FocusNode? focusNode;
  final VoidCallback? onTapOutsideDismiss;

  const _Field({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    this.maxLines = 1,
    this.maxLen,
    this.helper,
    this.dense = false,
    this.keyboardType,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.sentences,
    this.focusNode,
    this.onTapOutsideDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(.76),
              ),
            ),
            if (maxLen != null) ...[
              const Spacer(),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, v, __) {
                  final len = v.text.length;
                  final pct = len / maxLen!;

                  final color = pct >= 0.95
                      ? Colors.red
                      : pct >= 0.85
                          ? Colors.amber.shade700
                          : Colors.black.withOpacity(.38);

                  return Text(
                    "$len/$maxLen",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  );
                },
              ),
            ],
          ],
        ),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper!,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              height: 1.35,
              color: Colors.black.withOpacity(.45),
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          onTapOutside: (_) => onTapOutsideDismiss?.call(),
          textCapitalization: textCapitalization,
          keyboardType: keyboardType ??
              (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
          inputFormatters: inputFormatters,
          textInputAction:
              maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
          maxLines: maxLines,
          maxLength: maxLen,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1F2937),
          ),
          buildCounter: (
            _, {
            required currentLength,
            required isFocused,
            maxLength,
          }) =>
              null,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontFamily: "Nunito",
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withOpacity(.34),
            ),
            filled: true,
            fillColor: const Color(0xFFF2F4F8),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: dense ? 13 : 15,
            ),
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
              borderSide: BorderSide(
                color: AppColors.brandGreen.withOpacity(.18),
                width: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  final String text;
  final VoidCallback? onRemove;

  const _TagChip({required this.text, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.brandGreen.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.brandGreen.withOpacity(.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              color: AppColors.brandGreen,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(999),
            child: Icon(
              PhosphorIcons.x(PhosphorIconsStyle.bold),
              size: 14,
              color: AppColors.brandGreen.withOpacity(.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestChip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback? onTap;

  const _SuggestChip({
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.brandGreen.withOpacity(.14)
              : Colors.white.withOpacity(.75),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppColors.brandGreen.withOpacity(.22)
                : Colors.black.withOpacity(.06),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
            color: selected
                ? AppColors.brandGreen
                : Colors.black.withOpacity(.60),
          ),
        ),
      ),
    );
  }
}

class _SegItem {
  final String value;
  final String label;
  const _SegItem(this.value, this.label);
}

class _SegmentPills extends StatelessWidget {
  final String value;
  final List<_SegItem> items;
  final ValueChanged<String>? onChanged;

  const _SegmentPills({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((item) {
        final selected = item.value == value;

        return InkWell(
          onTap: onChanged == null ? null : () => onChanged!(item.value),
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.black
                  : const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(999),
              // boxShadow: selected
              //     ? [
              //         BoxShadow(
              //           color: AppColors.brandGreen.withOpacity(.18),
              //           blurRadius: 16,
              //           offset: const Offset(0, 7),
              //         ),
              //       ]
              //     : null,
            ),
            child: Text(
              item.label,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? Colors.white
                    : Colors.black.withOpacity(.64),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _IconPillAdd extends StatelessWidget {
  final VoidCallback? onTap;

  const _IconPillAdd({
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: disabled
                ? Colors.black
                : Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Center(
            child: Icon(
              PhosphorIcons.plus(PhosphorIconsStyle.light),
              size: 22,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _TinyPillButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _TinyPillButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.black.withOpacity(.58)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(.66),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconSquareButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _IconSquareButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.04),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 20,
          color: Colors.black.withOpacity(.58),
        ),
      ),
    );
  }
}

const double _g8 = 8;
const double _g12 = 12;
const double _g16 = 16;
const double _g20 = 20;

class _SectionGap extends StatelessWidget {
  final String? label;
  const _SectionGap({this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: _g16),
        if (label != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label!,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .6,
                color: Colors.black.withOpacity(.40),
              ),
            ),
          ),
          const SizedBox(height: _g8),
        ],
        Container(
          height: 1,
          width: double.infinity,
          color: Colors.black.withOpacity(.06),
        ),
        const SizedBox(height: _g16),
      ],
    );
  }
}

// ✅ NEW: Upload state enum
enum MediaUploadState {
  idle,
  validating,
  uploading,
  done,
  failed,
}

class _MediaGrid extends StatelessWidget {
  final List<PickedMedia> items;
  final void Function(PickedMedia)? onRemove;

  const _MediaGrid({
    required this.items,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemBuilder: (_, i) {
        final m = items[i];

        return ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _thumb(m),

              // ✅ Upload state overlay
              if (m.uploadState == MediaUploadState.uploading)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(.65),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            value: m.uploadProgress,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.white),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "${(m.uploadProgress * 100).toInt()}%",
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (m.uploadState == MediaUploadState.done)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 8,
                          color: Colors.black.withOpacity(.2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),

              if (m.uploadState == MediaUploadState.failed)
                Positioned.fill(
                  child: Container(
                    color: Colors.red.withOpacity(.7),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          PhosphorIcons.warning(PhosphorIconsStyle.fill),
                          size: 32,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Failed",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (m.isVideo && m.uploadState == MediaUploadState.idle)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded,
                            size: 16, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          "Video",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (m.isFile && m.uploadState == MediaUploadState.idle)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.insert_drive_file_rounded,
                            size: 14, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          "File",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (onRemove != null && m.uploadState == MediaUploadState.idle)
                Positioned(
                  right: 8,
                  top: 8,
                  child: InkWell(
                    onTap: () => onRemove!(m),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 18, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _thumb(PickedMedia m) {
    if (m.isFile) {
      return Container(
        color: Colors.black.withOpacity(.06),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              PhosphorIcons.file(PhosphorIconsStyle.light),
              size: 26,
              color: Colors.black.withOpacity(.65),
            ),
            const SizedBox(height: 8),
            Text(
              (m.name ?? "File"),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w700,
                fontSize: 11,
                color: Colors.black.withOpacity(.70),
              ),
            ),
          ],
        ),
      );
    }

    if (m.asset != null) {
      return AssetEntityImage(
        m.asset!,
        fit: BoxFit.cover,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize(500, 500),
      );
    }

    if (m.file != null) {
      if (m.isVideo && m.thumbBytes != null) {
        return Image.memory(m.thumbBytes!, fit: BoxFit.cover);
      }
      return Image.file(m.file!, fit: BoxFit.cover);
    }

    return Container(color: Colors.black12);
  }
}

class PickedMedia {
  final String id;
  final String type;

  final AssetEntity? asset;
  final File? file;
  final Uint8List? thumbBytes;

  final String? name;
  final int? sizeBytes;
  final String? ext;
  final String? contentType;

  final Uint8List? bytes;

  // ✅ Upload state
  MediaUploadState uploadState;
  double uploadProgress;

  PickedMedia({
    required this.id,
    required this.type,
    this.asset,
    this.file,
    this.thumbBytes,
    this.name,
    this.sizeBytes,
    this.ext,
    this.contentType,
    this.bytes,
    this.uploadState = MediaUploadState.idle,
    this.uploadProgress = 0.0,
  });

  bool get isVideo => type == "video";
  bool get isFile => type == "file";
  bool get isImage => type == "image";
}

class _CreatePingTopArtwork extends StatelessWidget {
  const _CreatePingTopArtwork();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 150,
        width: double.infinity,
        child: Image.asset(
          "assets/images/create_a_ping.png",
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.04),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF16181D),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        color: Colors.black.withOpacity(.50),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _DoodleStar extends StatelessWidget {
  final Color color;
  final double size;

  const _DoodleStar({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.auto_awesome,
      color: color,
      size: size,
    );
  }
}

class _DoodleHeart extends StatelessWidget {
  final Color color;
  final double size;

  const _DoodleHeart({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.favorite_border_rounded,
      color: color,
      size: size,
    );
  }
}

class _SourceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _SourceButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final fg = Colors.black.withOpacity(disabled ? .40 : .72);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          height: 84,
          decoration: BoxDecoration(
            color: const Color(0xFFF2F4F8),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: fg,
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PingCustomCategoryCard extends StatelessWidget {
  final bool isSelected;
  final VoidCallback? onTap;

  const _PingCustomCategoryCard({
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.brandGreen.withOpacity(.08)
                : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? AppColors.brandGreen.withOpacity(.34)
                  : const Color(0xFFE8ECF2),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.03),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.brandGreen.withOpacity(.16)
                      : const Color(0xFFF2F4F8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected
                        ? AppColors.brandGreen.withOpacity(.18)
                        : const Color(0xFFF2F4F8),
                  ),
                ),
                child: Icon(
                  PhosphorIcons.plus(PhosphorIconsStyle.bold),
                  size: 18,
                  color: isSelected
                      ? AppColors.brandGreen
                      : const Color(0xFF1F2937),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Custom category",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF16181D),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Different from the options above. Tap this and name your own.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                        color: Colors.black.withOpacity(.52),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(
                  PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
                  size: 18,
                  color: AppColors.brandGreen,
                ),
            ],
          ),
        ),
      ),
    );
  }
}