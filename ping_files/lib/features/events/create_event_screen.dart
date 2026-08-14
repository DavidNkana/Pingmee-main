import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/events/create_event_draft.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import 'package:file_picker/file_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class PlaceAutocompletePrediction {
  final String placeId;
  final String text;
  final String mainText;
  final String secondaryText;

  const PlaceAutocompletePrediction({
    required this.placeId,
    required this.text,
    required this.mainText,
    required this.secondaryText,
  });

  factory PlaceAutocompletePrediction.fromJson(Map<String, dynamic> json) {
    return PlaceAutocompletePrediction(
      placeId: (json['placeId'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      mainText: (json['mainText'] ?? '').toString(),
      secondaryText: (json['secondaryText'] ?? '').toString(),
    );
  }
}

class SelectedPlaceDetails {
  final String placeId;
  final String name;
  final String formattedAddress;
  final double? lat;
  final double? lng;

  const SelectedPlaceDetails({
    required this.placeId,
    required this.name,
    required this.formattedAddress,
    required this.lat,
    required this.lng,
  });

  factory SelectedPlaceDetails.fromJson(Map<String, dynamic> json) {
    return SelectedPlaceDetails(
      placeId: (json['placeId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      formattedAddress: (json['formattedAddress'] ?? '').toString(),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
    );
  }
}

class CreateEventResult {
  final String eventId;
  final String title;
  final String themeId;
  final bool showCreatedPopup;

  const CreateEventResult({
    required this.eventId,
    required this.title,
    required this.themeId,
    this.showCreatedPopup = false,
  });
}

class CreateEventScreen extends StatefulWidget {
  final CreateEventDraft draft;
  final VoidCallback? onReady;

  const CreateEventScreen({
    super.key,
    required this.draft,
    this.onReady,
  });

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends State<CreateEventScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final ScrollController _sessionScrollController = ScrollController();
  bool _saving = false;
  String _createStage = "";
  double _overallUploadProgress = 0.0;

  Timer? _placeSearchDebounce;
  bool _placeSearching = false;
  bool _placeDetailsLoading = false;
  List<PlaceAutocompletePrediction> _placePredictions = [];
  SelectedPlaceDetails? _selectedPlace;
  bool _ignorePlaceTextChanges = false;
  String _placeSessionToken = '';
  late final AnimationController _gyroBorderController;

  static const int _maxEventMediaBytes = 50 * 1024 * 1024;
  bool _coverPickerOpen = false;
  bool _showMeetupInstructionsComposer = false;

  // late final VoidCallback _locationCtrlListener;
  bool get _eventMediaFull => _eventMediaItems.length >= 6;

  final FocusNode _parkingFocusNode = FocusNode(
    debugLabel: 'event_parking_focus',
    skipTraversal: true,
  );

  final FocusNode _titleFocusNode = FocusNode();
  final FocusNode _descFocusNode = FocusNode();
  final FocusNode _locationFocusNode = FocusNode();
  final FocusNode _virtualLinkFocusNode = FocusNode();
  final FocusNode _meetupInstructionsFocusNode = FocusNode();
  final FocusNode _maxPeopleFocusNode = FocusNode();
  final FocusNode _customCategoryFocusNode = FocusNode();
  final FocusNode _tagFocusNode = FocusNode();

  double? _searchBiasRadiusMeters;
  double? _searchBiasLat;
  double? _searchBiasLng;

  // Built in preset image covers
  // Replace these with your real asset files.
  static const List<String> _coverChoiceAssets = [
    "assets/event_covers/default_event_cover.png",
    "assets/event_covers/choices_1.jpg",
    "assets/event_covers/choices_2.jpg",
    "assets/event_covers/choices_3.jpg",
    "assets/event_covers/choices_4.jpg",
    "assets/event_covers/choices_5.jpg",
    "assets/event_covers/choices_6.jpg",
    "assets/event_covers/choices_7.jpg",
  ];
  static const Map<String, List<int>> _gradientCoverOptions = {
    "grad_01": [0xFF0F172A, 0xFF22C55E],
    "grad_02": [0xFF111827, 0xFF3B82F6],
    "grad_03": [0xFF7C3AED, 0xFFEC4899],
    "grad_04": [0xFF0F766E, 0xFF14B8A6],
    "grad_05": [0xFFF97316, 0xFFEF4444],
    "grad_06": [0xFF1E293B, 0xFF64748B],
  };

  bool _validateEventMediaSize(int sizeBytes, String filename) {
    if (sizeBytes > _maxEventMediaBytes) {
      final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
      _showError("$filename is ${sizeMb}MB. Max allowed is 50MB.");
      return false;
    }
    return true;
  }

  static final RegExp _eventTagAllowed = RegExp(r"^[a-z0-9_]{2,20}$");
  static final List<String> _eventBlockedSubstrings = [
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

  static final RegExp _eventCategoryAllowed =
      RegExp(r'^[a-z0-9]+(?: [a-z0-9]+){0,2}$');

  bool _isEventTagAllowed(String tag) {
    if (!_eventTagAllowed.hasMatch(tag)) return false;
    for (final blocked in _eventBlockedSubstrings) {
      if (tag.contains(blocked)) return false;
    }
    return true;
  }

  String? _validateCustomEventCategory(String raw) {
    final cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');

    if (cleaned.isEmpty) return "Enter a custom category first.";
    if (cleaned.length < 2) return "Custom category is too short.";
    if (cleaned.length > 24) {
      return "Custom category must be 24 characters or less.";
    }
    if (!_eventCategoryAllowed.hasMatch(cleaned)) {
      return "Use 1 to 3 short words only.";
    }
    return null;
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

  void _recomputeOverallUploadProgress() {
    if (_eventMediaItems.isEmpty) {
      _overallUploadProgress = 0.0;
      return;
    }

    double total = 0.0;

    for (final item in _eventMediaItems) {
      switch (item.uploadState) {
        case EventMediaUploadState.idle:
          total += 0.0;
          break;
        case EventMediaUploadState.validating:
          total += 0.05;
          break;
        case EventMediaUploadState.uploading:
          total += item.uploadProgress.clamp(0.0, 1.0);
          break;
        case EventMediaUploadState.done:
        case EventMediaUploadState.failed:
          total += 1.0;
          break;
      }
    }

    _overallUploadProgress =
        (total / _eventMediaItems.length).clamp(0.0, 1.0);
  }

  String _friendlyEventError(Object e) {
    final msg = e.toString().toLowerCase();

    if (msg.contains("permission")) {
      return "You don’t have permission to do that right now.";
    }
    if (msg.contains("network") ||
        msg.contains("timeout") ||
        msg.contains("unavailable")) {
      return "Network issue. Check your connection and try again.";
    }
    if (msg.contains("storage") || msg.contains("upload")) {
      return "Some media could not be uploaded. Try again.";
    }
    if (msg.contains("location") || msg.contains("place")) {
      return "We couldn’t use that location. Pick a real place and try again.";
    }
    return "Couldn't create event. Please try again.";
  }

  bool _looksLikeVideoPath(String path) {
    final ext = p.extension(path).toLowerCase();
    return [".mp4", ".mov", ".mkv", ".webm", ".avi"].contains(ext);
  }

  String _guessImageContentType(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case ".png":
        return "image/png";
      case ".webp":
        return "image/webp";
      default:
        return "image/jpeg";
    }
  }

  String _guessVideoContentType(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case ".mov":
        return "video/quicktime";
      case ".webm":
        return "video/webm";
      case ".mkv":
        return "video/x-matroska";
      case ".avi":
        return "video/x-msvideo";
      default:
        return "video/mp4";
    }
  }

  static const String _placesAutocompleteUrl =
      "https://placesautocomplete-iaxwoch7na-uc.a.run.app";

  static const String _placeDetailsUrl =
      "https://placedetails-iaxwoch7na-uc.a.run.app";

  String _newPlaceSessionToken() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = math.Random().nextInt(999999);
    return "pm_${now}_$rand";
  }

  void _onPlaceTextChanged(String value) {
    if (_ignorePlaceTextChanges) return;
    if (widget.draft.venueType != EventVenueType.inPerson) return;

    _placeSearchDebounce?.cancel();

    if (_selectedPlace != null) {
      setState(() {
        _resetSelectedPlace();
      });
    }

    final query = value.trim();

    if (query.length < 2) {
      setState(() {
        _placeSearching = false;
        _placePredictions = [];
      });
      return;
    }

    _placeSearchDebounce = Timer(const Duration(milliseconds: 350), () {
      _searchPlaces(query);
    });
  }

  Future<void> _loadPlaceSearchBias() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final userSnap = await FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .get();

      final data = userSnap.data() ?? <String, dynamic>{};
      final miles = (data["distanceMiles"] is num)
          ? (data["distanceMiles"] as num).toDouble()
          : null;

      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 8),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }

      if (!mounted) return;

      setState(() {
        _searchBiasRadiusMeters =
            miles == null || miles <= 0 ? null : miles * 1609.344;
        _searchBiasLat = pos?.latitude;
        _searchBiasLng = pos?.longitude;
      });
    } catch (_) {}
  }

  Future<void> _searchPlaces(String query) async {
    if (!mounted) return;

    if (_placeSessionToken.isEmpty) {
      _placeSessionToken = _newPlaceSessionToken();
    }

    setState(() {
      _placeSearching = true;
    });

    try {
      final params = <String, String>{
        "input": query,
        "sessionToken": _placeSessionToken,
      };

      if (_searchBiasLat != null &&
          _searchBiasLng != null &&
          _searchBiasRadiusMeters != null &&
          _searchBiasRadiusMeters! > 0) {
        params["lat"] = _searchBiasLat!.toString();
        params["lng"] = _searchBiasLng!.toString();
        params["radiusMeters"] =
            _searchBiasRadiusMeters!.round().toString();
      }

      final uri = Uri.parse(_placesAutocompleteUrl).replace(
        queryParameters: params,
      );

      final response = await http.get(uri);

      final Map<String, dynamic> jsonBody =
          json.decode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        throw Exception(jsonBody["error"] ?? "Autocomplete failed");
      }

      final list = (jsonBody["predictions"] as List<dynamic>? ?? [])
          .map((e) => PlaceAutocompletePrediction.fromJson(
                e as Map<String, dynamic>,
              ))
          .toList();

      if (!mounted) return;

      setState(() {
        _placePredictions = list;
        _placeSearching = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _placeSearching = false;
        _placePredictions = [];
      });

      _showError("Couldn't search places. Try again.");
    }
  }

  Future<void> _selectPlacePrediction(
    PlaceAutocompletePrediction prediction,
  ) async {
    if (!mounted) return;

    FocusScope.of(context).unfocus();
    _placeSearchDebounce?.cancel();

    setState(() {
      _placePredictions = [];
      _placeSearching = false;
      _placeDetailsLoading = true;
    });

    try {
      final uri = Uri.parse(_placeDetailsUrl).replace(
        queryParameters: {
          "placeId": prediction.placeId,
        },
      );

      final response = await http.get(uri);

      final Map<String, dynamic> jsonBody =
          json.decode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        throw Exception(jsonBody["error"] ?? "Place details failed");
      }

      final details = SelectedPlaceDetails.fromJson(jsonBody);

      if (!mounted) return;

      _ignorePlaceTextChanges = true;

      setState(() {
        _selectedPlace = details;
        widget.draft.locationCtrl.text = details.name.isNotEmpty
            ? details.name
            : details.formattedAddress;
        _placePredictions = [];
        _placeSearching = false;
        _placeDetailsLoading = false;
        _placeSessionToken = "";
      });

      _ignorePlaceTextChanges = false;
    } catch (e) {
      _ignorePlaceTextChanges = false;

      if (!mounted) return;

      setState(() {
        _placeDetailsLoading = false;
      });

      _showError("Couldn't load place details. Try again.");
    }
  }    

  Future<void> _useMyCurrentLocation() async {
    if (!mounted) return;

    FocusScope.of(context).unfocus();
    _placeSearchDebounce?.cancel();

    setState(() {
      _placePredictions = [];
      _placeSearching = false;
      _placeDetailsLoading = true;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception("Turn on location services first.");
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception(
          "Location permission is required to use your current location.",
        );
      }

      Position? position;

      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 12),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      if (position == null) {
        throw Exception("Couldn't get your current location.");
      }

      if (!mounted) return;

      _ignorePlaceTextChanges = true;

      setState(() {
        _selectedPlace = SelectedPlaceDetails(
          placeId: "device_current_location",
          name: "Current location",
          formattedAddress: "Using your current GPS location",
          lat: position!.latitude,
          lng: position.longitude,
        );

        widget.draft.locationCtrl.text = "Current location";
        _placePredictions = [];
        _placeSearching = false;
        _placeDetailsLoading = false;
        _placeSessionToken = "";
      });

      _ignorePlaceTextChanges = false;
    } catch (e) {
      _ignorePlaceTextChanges = false;

      if (!mounted) return;

      _showError(e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) {
        setState(() {
          _placeDetailsLoading = false;
        });
      }
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

  Future<File?> _eventMediaToFile(EventDraftMediaItem item) async {
    if (item.file != null) return item.file;
    if (item.asset != null) return await item.asset!.file;
    return null;
  }

  Future<String?> _uploadBinary({
    required String storagePath,
    required String fileName,
    required String contentType,
    File? file,
    Uint8List? bytes,
    void Function(double progress)? onProgress,
  }) async {
    final ext = p.extension(fileName);
    final ref = FirebaseStorage.instance.ref(
      ext.isEmpty ? storagePath : "$storagePath$ext",
    );

    final metadata = SettableMetadata(contentType: contentType);

    UploadTask task;
    if (file != null) {
      task = ref.putFile(file, metadata);
    } else if (bytes != null) {
      task = ref.putData(bytes, metadata);
    } else {
      return null;
    }

    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        final total = snapshot.totalBytes;
        if (total <= 0) return;
        onProgress(snapshot.bytesTransferred / total);
      });
    }

    await task;
    return await ref.getDownloadURL();
  }

  void _animateToLatestSession() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_sessionScrollController.hasClients) return;

      final position = _sessionScrollController.position;
      final start = position.pixels;
      final target = position.maxScrollExtent;

      // If there is almost nothing to scroll, do nothing.
      if ((target - start).abs() < 4) return;

      // Jumping usually happens when layout is still settling.
      // Wait one more frame, then animate to the final edge.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!mounted || !_sessionScrollController.hasClients) return;

      final settledTarget = _sessionScrollController.position.maxScrollExtent;
      final current = _sessionScrollController.position.pixels;

      if ((settledTarget - current).abs() < 4) return;

      await _sessionScrollController.animateTo(
        settledTarget,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _animateSessionsToStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sessionScrollController.hasClients) return;

      _sessionScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _resetSelectedPlace() {
    _selectedPlace = null;
  }

  String? _validateMeetupInstructions(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (cleaned.isEmpty) return "Add some instructions first.";
    if (cleaned.length > 100) {
      return "Keep instructions under 100 characters.";
    }
    return null;
  }

  void _addMeetupInstructions() {
    _dismissKeyboard();

    final raw = widget.draft.meetupInstructionsCtrl.text;
    final error = _validateMeetupInstructions(raw);

    if (error != null) {
      _showError(error);
      return;
    }

    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    setState(() {
      widget.draft.meetupInstructionsValue = cleaned;
      widget.draft.meetupInstructionsCtrl.clear();
      _showMeetupInstructionsComposer = false;
    });

    HapticFeedback.selectionClick();
    _showSuccess("Further instructions added.");
  }

  void _removeMeetupInstructions() {
    _dismissKeyboard();
    setState(() {
      widget.draft.meetupInstructionsValue = null;
      widget.draft.meetupInstructionsCtrl.clear();
      _showMeetupInstructionsComposer = false;
    });
  }

  @override
  void dispose() {
    _placeSearchDebounce?.cancel();
    _sessionScrollController.dispose();
    _parkingFocusNode.dispose();
    _titleFocusNode.dispose();
    _descFocusNode.dispose();
    _locationFocusNode.dispose();
    _virtualLinkFocusNode.dispose();
    _meetupInstructionsFocusNode.dispose();
    _maxPeopleFocusNode.dispose();
    _customCategoryFocusNode.dispose();
    _tagFocusNode.dispose();
    _gyroBorderController.dispose();
    super.dispose();
  }

  Future<void> _pickEventMediaFromGallery() async {
    _dismissKeyboard();
    if (_saving || _eventMediaFull) return;

    final left = 6 - _eventMediaItems.length;
    final permission = await PhotoManager.requestPermissionExtend();

    if (!permission.isAuth) {
      _showError("Allow gallery access to add media.");
      return;
    }

    final assets = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        maxAssets: left,
        requestType: RequestType.common,
        selectedAssets: _eventMediaItems
            .where((e) => e.asset != null)
            .map((e) => e.asset!)
            .toList(),
      ),
    );

    if (!mounted || assets == null || assets.isEmpty) return;

    final existingIds = _eventMediaItems.map((e) => e.id).toSet();
    final additions = <EventDraftMediaItem>[];

    for (final asset in assets) {
      final id = "asset_${asset.id}";
      if (existingIds.contains(id)) continue;

      final file = await asset.file;
      if (file == null) continue;

      final size = await file.length();
      if (!_validateEventMediaSize(size, asset.title ?? "Media")) continue;

      additions.add(
        EventDraftMediaItem(
          id: id,
          type: asset.type == AssetType.video ? "video" : "image",
          asset: asset,
          name: asset.title,
          sizeBytes: size,
        ),
      );
    }

    if (!mounted || additions.isEmpty) return;

    setState(() {
      _eventMediaItems.addAll(additions);
    });
  }

  Future<void> _pickEventMediaFromCamera() async {
    _dismissKeyboard();
    if (_saving || _eventMediaFull) return;

    try {
      XFile? captured;
      CameraPickerViewType? capturedType;

      await CameraPicker.pickFromCamera(
        context,
        pickerConfig: CameraPickerConfig(
          enableRecording: true,
          textDelegate: const EnglishCameraPickerTextDelegate(),
          onXFileCaptured: (XFile file, CameraPickerViewType viewType) {
            captured = file;
            capturedType = viewType;
            Navigator.of(context).pop();
            return true;
          },
        ),
      );

      if (captured == null || !mounted) return;

      final file = File(captured!.path);
      if (!await file.exists()) {
        _showError("Couldn't read camera capture.");
        return;
      }

      final size = await file.length();
      if (!_validateEventMediaSize(size, "Camera capture")) return;

      final isVideo = capturedType == CameraPickerViewType.video ||
          _looksLikeVideoPath(file.path);

      Uint8List? thumb;
      if (isVideo) {
        thumb = await vt.VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: vt.ImageFormat.JPEG,
          maxWidth: 600,
          quality: 75,
        );
      }

      setState(() {
        _eventMediaItems.add(
          EventDraftMediaItem(
            id: "cam_${DateTime.now().millisecondsSinceEpoch}",
            type: isVideo ? "video" : "image",
            file: file,
            thumbBytes: thumb,
            name: p.basename(file.path),
            sizeBytes: size,
            ext: p.extension(file.path).replaceFirst(".", "").toLowerCase(),
            contentType: isVideo
                ? _guessVideoContentType(file.path)
                : _guessImageContentType(file.path),
          ),
        );
      });
    } catch (e) {
      _showError("Couldn't open camera. Try again.");
    }
  }

  Future<void> _pickEventFiles() async {
    _dismissKeyboard();
    if (_saving || _eventMediaFull) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) return;

      final existingIds = _eventMediaItems.map((e) => e.id).toSet();
      final additions = <EventDraftMediaItem>[];

      for (final picked in result.files) {
        if (_eventMediaItems.length + additions.length >= 6) break;

        final id = "file_${picked.identifier ?? picked.name}_${picked.size}";
        if (existingIds.contains(id)) continue;

        if (picked.path == null && picked.bytes == null) continue;
        if (!_validateEventMediaSize(picked.size, picked.name)) continue;

        additions.add(
          EventDraftMediaItem(
            id: id,
            type: "file",
            file: picked.path != null ? File(picked.path!) : null,
            bytes: picked.bytes,
            name: picked.name,
            sizeBytes: picked.size,
            ext: p.extension(picked.name).replaceFirst(".", "").toLowerCase(),
            contentType: _guessFileContentType(picked.name),
          ),
        );
      }

      if (!mounted || additions.isEmpty) return;

      setState(() {
        _eventMediaItems.addAll(additions);
      });
    } catch (e) {
      _showError("Couldn't open files. Try again.");
    }
  }

    static const List<int> _solidCoverOptions = [
      0xFF22C55E,
      0xFF0F172A,
      0xFF2563EB,
      0xFF7C3AED,
      0xFFDB2777,
      0xFFF97316,
      0xFFEAB308,
      0xFF14B8A6,
    ];

    AssetEntity? get _coverAsset => widget.draft.coverAsset;
    set _coverAsset(AssetEntity? value) => widget.draft.coverAsset = value;

    List<EventDraftMediaItem> get _eventMediaItems => widget.draft.mediaItems;

    String? get _selectedPresetCoverAsset => widget.draft.selectedPresetCoverAsset;
    set _selectedPresetCoverAsset(String? value) {
      widget.draft.selectedPresetCoverAsset = value;
    }

    String? get _selectedGradientCoverId => widget.draft.selectedGradientCoverId;
    set _selectedGradientCoverId(String? value) {
      widget.draft.selectedGradientCoverId = value;
    }

  static const List<String> _categoryOptions = [
    "network",
    "study",
    "gaming",
    "music",
    "sport",
    "food",
    "hangout",
    "business",
    "creative",
    "custom",
  ];

  IconData _categoryIcon(String category) {
    switch (category) {
      case "network":
        return PhosphorIcons.usersThree(PhosphorIconsStyle.bold);
      case "study":
        return PhosphorIcons.bookOpenText(PhosphorIconsStyle.bold);
      case "gaming":
        return PhosphorIcons.gameController(PhosphorIconsStyle.bold);
      case "music":
        return PhosphorIcons.musicNotes(PhosphorIconsStyle.bold);
      case "sport":
        return PhosphorIcons.soccerBall(PhosphorIconsStyle.bold);
      case "food":
        return PhosphorIcons.forkKnife(PhosphorIconsStyle.bold);
      case "hangout":
        return PhosphorIcons.smiley(PhosphorIconsStyle.bold);
      case "business":
        return PhosphorIcons.briefcase(PhosphorIconsStyle.bold);
      case "creative":
        return PhosphorIcons.palette(PhosphorIconsStyle.bold);
      case "custom":
        return PhosphorIcons.sparkle(PhosphorIconsStyle.bold);
      default:
        return PhosphorIcons.tag(PhosphorIconsStyle.bold);
    }
  }

  static const List<_EventThemePalette> _eventThemes = [
    _EventThemePalette(
      id: "pink_nova",
      top: Color(0xFFA86AA0),
      bottom: Color(0xFF243B68),
      solid: Color(0xFFE85ED5),
    ),
    _EventThemePalette(
      id: "violet_dusk",
      top: Color(0xFF9A84FF),
      bottom: Color(0xFF2E206D),
      solid: Color(0xFF8B5CF6),
    ),
    _EventThemePalette(
      id: "ocean_night",
      top: Color(0xFF68B7FF),
      bottom: Color(0xFF153C78),
      solid: Color(0xFF3298FF),
    ),
    _EventThemePalette(
      id: "emerald_night",
      top: Color(0xFF73E3BF),
      bottom: Color(0xFF0B4E4B),
      solid: Color(0xFF16C784),
    ),
    _EventThemePalette(
      id: "sunset_blaze",
      top: Color(0xFFFF9A7A),
      bottom: Color(0xFF653049),
      solid: Color(0xFFFF6B57),
    ),
    _EventThemePalette(
      id: "amber_smoke",
      top: Color(0xFFF6CB75),
      bottom: Color(0xFF6B4722),
      solid: Color(0xFFF0A827),
    ),
    _EventThemePalette(
      id: "berry_wave",
      top: Color(0xFFF29BCE),
      bottom: Color(0xFF4A245B),
      solid: Color(0xFFE95FAF),
    ),
    _EventThemePalette(
      id: "teal_ink",
      top: Color(0xFF75E0DE),
      bottom: Color(0xFF184C64),
      solid: Color(0xFF21C7C9),
    ),
  ];

  _EventThemePalette get _activeTheme {
    for (final theme in _eventThemes) {
      if (theme.id == widget.draft.selectedTheme) return theme;
    }
    return _eventThemes.first;
  }

  @override
  void initState() {
    super.initState();

    final hasValidTheme = _eventThemes.any(
      (theme) => theme.id == widget.draft.selectedTheme,
    );

    if (!hasValidTheme) {
      widget.draft.selectedTheme = "pink_nova";
    }

    unawaited(_loadPlaceSearchBias());

    _gyroBorderController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();

    // _locationCtrlListener = () {
    //   _onPlaceTextChanged(widget.draft.locationCtrl.text);
    // };
    // widget.draft.locationCtrl.addListener(_locationCtrlListener);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      setState(() {
        // _initialLoading = false;
      });
    });
  }

  Widget _buildEventMediaProgressOverlay(EventDraftMediaItem item) {
    if (item.uploadState == EventMediaUploadState.idle ||
        item.uploadState == EventMediaUploadState.done) {
      return const SizedBox.shrink();
    }

    final isFailed = item.uploadState == EventMediaUploadState.failed;
    final isValidating = item.uploadState == EventMediaUploadState.validating;
    final progress = item.uploadProgress.clamp(0.0, 1.0);
    final percent = (progress * 100).round();

    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withOpacity(.28),
          child: Center(
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.55),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withOpacity(.10),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      value: isFailed || isValidating ? null : progress,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isFailed ? Colors.redAccent : _themeSolid,
                      ),
                      backgroundColor: Colors.white.withOpacity(.14),
                    ),
                  ),
                  Text(
                    isFailed
                        ? "!"
                        : isValidating
                            ? "..."
                            : "$percent%",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  Color get _themeSolid => _activeTheme.solid;
  Color get _themeTop => _activeTheme.top;
  Color get _themeBottom => _activeTheme.bottom;
  Color get _themeSoftBorder => _themeSolid.withOpacity(.26);
  Color get _themeSoftFill => _themeSolid.withOpacity(.12);
  Color get _surfaceBorder => Colors.white.withOpacity(.22);
  Color get _surfaceFill => Colors.white.withOpacity(.90);
  Color get _glassFill => Colors.white.withOpacity(.16);

  Color get _sheetFill =>
      Color.alphaBlend(Colors.black.withOpacity(.26), _themeBottom.withOpacity(.84));

  Color get _sheetBorder => Colors.white.withOpacity(.10);
  Color get _panelFill => Colors.white.withOpacity(.075);
  Color get _panelBorder => Colors.white.withOpacity(.10);
  Color get _fieldFill => Colors.white.withOpacity(.07);
  Color get _fieldBorder => Colors.white.withOpacity(.12);
  Color get _inactiveChipFill => Colors.white.withOpacity(.08);
  Color get _inactiveChipBorder => Colors.white.withOpacity(.10);
  Color get _mutedText => Colors.white.withOpacity(.62);
  Color get _softText => Colors.white.withOpacity(.88);
  Color get _dividerColor => Colors.white.withOpacity(.08);
  Color get _dangerFill => const Color(0xFF4A1E2A);
  Color get _dangerText => const Color(0xFFFFB3C1);

  LinearGradient get _screenGradient => LinearGradient(
        colors: [
          Color.alphaBlend(Colors.black.withOpacity(.72), _activeTheme.top),
          Color.alphaBlend(Colors.black.withOpacity(.38), _activeTheme.bottom),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  LinearGradient get _heroOverlayGradient => LinearGradient(
        colors: [
          Colors.transparent,
          Colors.black.withOpacity(.10),
          Colors.black.withOpacity(.42),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  TextStyle get _sectionTitle => TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Colors.white.withOpacity(.90),
        letterSpacing: .2,
      );

  TextStyle get _sectionBody => TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: _mutedText,
        height: 1.35,
      );

  LinearGradient get _themeGradient => LinearGradient(
        colors: [
          Color.alphaBlend(Colors.black.withOpacity(.72), _themeTop),
          Color.alphaBlend(Colors.black.withOpacity(.38), _themeBottom),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  static const List<int> _coverPalette = [
    0xFF22C55E,
    0xFF0F172A,
    0xFF2563EB,
    0xFF7C3AED,
    0xFFDB2777,
    0xFFF97316,
    0xFFEAB308,
    0xFF14B8A6,
  ];



  TextStyle get _labelStyle => const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: Color(0xFF334155),
      );

  TextStyle get _bodyStyle => const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: Color(0xFF64748B),
      );

  Color get _coverColor => Color(widget.draft.coverColorValue);

  Widget _editorMiniChip({
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          _dismissKeyboard();
          onTap();
        },
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withOpacity(.10)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _softText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDescriptionEditor() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _fieldFill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _fieldBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _editorMiniChip(
                  label: "H1",
                  onTap: () => _insertDescriptionText("# "),
                ),
                _editorMiniChip(
                  label: "H2",
                  onTap: () => _insertDescriptionText("## "),
                ),
                _editorMiniChip(
                  label: "Bold",
                  onTap: () => _wrapDescriptionSelection(
                    prefix: "**",
                    suffix: "**",
                    placeholder: "bold text",
                  ),
                ),
                _editorMiniChip(
                  label: "Underline",
                  onTap: () => _wrapDescriptionSelection(
                    prefix: "__",
                    suffix: "__",
                    placeholder: "underlined text",
                  ),
                ),
                _editorMiniChip(
                  label: "• Bullet",
                  onTap: () => _prefixDescriptionLines("- "),
                ),
                _editorMiniChip(
                  label: "1. List",
                  onTap: () => _prefixDescriptionLines("1. "),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              "Use simple formatting: headers, bullets, bold, underline.",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _mutedText,
              ),
            ),
          ),
          Container(
            height: 1,
            color: Colors.white.withOpacity(.08),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(
              "Description",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _mutedText,
                letterSpacing: .2,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: TextFormField(
              controller: widget.draft.descCtrl,
              maxLength: 2000,
              minLines: 8,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: _softText,
                height: 1.5,
              ),
              decoration: InputDecoration(
                hintText:
                    "Describe the event clearly. You can use line breaks, bullets, and simple formatting.",
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: _mutedText,
                  height: 1.45,
                ),
                counterStyle: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: _mutedText,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
              ),
              validator: (value) {
                final v = value?.trim() ?? "";
                if (v.isEmpty) return "Enter an event description.";
                if (v.length > 2000) {
                  return "Description must be 2000 characters or less.";
                }
                return null;
              },
            ),
          ),
        ],
      ),
    );
  }

    @override
    Widget build(BuildContext context) {
      return PopScope(
        canPop: !_saving,
        child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissKeyboard,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Container(
            decoration: BoxDecoration(gradient: _screenGradient),
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withOpacity(.02),
                          Colors.transparent,
                          Colors.black.withOpacity(.12),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
                AbsorbPointer(
                  absorbing: _saving,
                  child: Column(
                    children: [
                      Expanded(
                        child: Form(
                        key: _formKey,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 132),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTopBar(),
                              const SizedBox(height: 8),
                              _buildHeroSection(),
                              const SizedBox(height: 18),
                              _buildComposerSheet(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  )
                ),
                _buildBottomActionBar(),
              ],
            ),
          ),
        ),
        )
        )
      );
    }

    Widget _buildSelectedPlaceCard() {
      final place = _selectedPlace;
      if (place == null) return const SizedBox.shrink();

      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _themeSolid.withOpacity(.16),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _themeSolid.withOpacity(.34),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _themeSolid.withOpacity(.24),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                size: 18,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name.isNotEmpty ? place.name : "Selected place",
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: _softText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    place.formattedAddress,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: _mutedText,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                _dismissKeyboard();
                setState(() {
                  _selectedPlace = null;
                  _placePredictions = [];
                  _placeSessionToken = "";
                  widget.draft.locationCtrl.clear();
                });
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  PhosphorIcons.x(PhosphorIconsStyle.bold),
                  size: 14,
                  color: Colors.white.withOpacity(.9),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget _buildPlacePredictionsPanel() {
      final showPanel = _placeSearching ||
          _placeDetailsLoading ||
          _placePredictions.isNotEmpty;

      if (!showPanel) return const SizedBox.shrink();

      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: _panelFill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _panelBorder),
        ),
        child: Column(
          children: [
            if (_placeSearching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(_themeSolid),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "Searching places...",
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _softText,
                      ),
                    ),
                  ],
                ),
              ),
            if (_placeDetailsLoading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(_themeSolid),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "Loading place details...",
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _softText,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_placeSearching && !_placeDetailsLoading && _placePredictions.isNotEmpty)
              ...List.generate(_placePredictions.length, (index) {
                final item = _placePredictions[index];
                final isLast = index == _placePredictions.length - 1;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _selectPlacePrediction(item),
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        border: isLast
                            ? null
                            : Border(
                                bottom: BorderSide(
                                  color: Colors.white.withOpacity(.06),
                                ),
                              ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.07),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              PhosphorIcons.mapPin(PhosphorIconsStyle.bold),
                              size: 16,
                              color: Colors.white.withOpacity(.92),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.mainText.isNotEmpty ? item.mainText : item.text,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: _softText,
                                  ),
                                ),
                                if (item.secondaryText.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    item.secondaryText,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: _mutedText,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
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
      );
    }

    Widget _buildTopBar() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            _circleGlassButton(
              icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
              onTap: _saving ? null : () => Navigator.pop(context),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Create event",
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(.96),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Mood first. Details second.",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _mutedText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget _buildGyroHeroFrame({required Widget child}) {
      return AnimatedBuilder(
        animation: _gyroBorderController,
        builder: (context, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Transform.rotate(
                angle: _gyroBorderController.value * 2 * math.pi,
                child: Container(
                  decoration: BoxDecoration(
  borderRadius: BorderRadius.circular(30),
  border: Border.all(
    color: Colors.white.withOpacity(.30),
    width: 2.2,
  ),
  boxShadow: [
    BoxShadow(
      color: _themeSolid.withOpacity(.16),
      blurRadius: 16,
      spreadRadius: 1,
    ),
  ],
),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(2.2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: child,
                ),
              ),
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    gradient: RadialGradient(
                      center: const Alignment(-0.75, -0.8),
                      radius: 1.15,
                      colors: [
                        Colors.white.withOpacity(.10),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    Widget _buildHeroSection() {
      final title = widget.draft.titleCtrl.text.trim();
      final displayTitle = title.isEmpty ? "Untitled event" : title;

      final firstSession =
          widget.draft.sessions.isNotEmpty ? widget.draft.sessions.first : null;

      final meta = <String>[
        _privacyLabel(widget.draft.privacy),
        widget.draft.venueType == EventVenueType.virtual ? "Virtual" : "In person",
        firstSession?.startAt != null
            ? _formatDateTime(firstSession!.startAt).split("•").first.trim()
            : "No date yet",
      ];

      return SizedBox(
        height: 380,
        width: double.infinity,
        child: _buildGyroHeroFrame(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: _buildCoverPreview(),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: _heroOverlayGradient,
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: _pillButton(
                  label: "Change cover",
                  icon: PhosphorIcons.imageSquare(PhosphorIconsStyle.bold),
                  selected: false,
                  compact: true,
                  fillColor: Colors.black.withOpacity(.34),
                  borderColor: Colors.white.withOpacity(.18),
                  foregroundColor: Colors.white,
                  onTap: _openCoverPicker,
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: meta.map(_buildHeroMetaChip).toList(),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 28,
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.draft.descCtrl.text.trim().isEmpty
                          ? "Set the tone, then tighten the details below."
                          : widget.draft.descCtrl.text.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withOpacity(.76),
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

    Widget _buildHeroMetaChip(String text) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.13),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(.14)),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white.withOpacity(.90),
          ),
        ),
      );
    }

    Widget _buildComposerSheet() {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
        decoration: BoxDecoration(
          color: _sheetFill,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: _sheetBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.12),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMoodGroup(),
            _thinDivider(),
            _buildDetailsGroup(),
            _thinDivider(),
            _buildScheduleGroup(),
            _thinDivider(),
            _buildPlaceGroup(),
            _thinDivider(),
            _buildAccessGroup(),
            _thinDivider(),
            _buildHostsGroup(),
            _thinDivider(),
            _buildDiscoveryGroup(),
          ],
        ),
      );
    }

    Widget _buildMoodGroup() {
      final total = _eventThemes.length;
      final mid = (total - 1) / 2;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(
            title: "Mood",
            subtitle: "Pick the emotional tone before you throw fields everywhere.",
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 72,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_eventThemes.length, (index) {
                  final theme = _eventThemes[index];
                  final distance = (index - mid).abs();
                  final factor = mid == 0 ? 0.0 : (1 - (distance / mid));
                  final dy = (factor * 8.0).clamp(0.0, 8.0);

                  final selected = widget.draft.selectedTheme == theme.id;

                  return Transform.translate(
                    offset: Offset(0, dy),
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: index == _eventThemes.length - 1 ? 0 : 12,
                      ),
                      child: GestureDetector(
                        onTap: () {
                          _dismissKeyboard();
                          setState(() {
                            widget.draft.selectedTheme = theme.id;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [theme.top, theme.bottom],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                            border: Border.all(
                              color: selected
                                  ? Colors.white.withOpacity(.94)
                                  : Colors.white.withOpacity(.30),
                              width: selected ? 2.6 : 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(.16),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: selected
                              ? Center(
                                  child: Icon(
                                    PhosphorIcons.check(PhosphorIconsStyle.bold),
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      );
    }

    Widget _buildDetailsGroup() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(title: "Details"),
          const SizedBox(height: 14),
          TextFormField(
            controller: widget.draft.titleCtrl,
            textCapitalization: TextCapitalization.sentences,
            focusNode: _titleFocusNode,
            onTapOutside: (_) => _dismissKeyboard(),
            maxLength: 60,
            onChanged: (_) => setState(() {}),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _softText,
            ),
            decoration: _inputDecoration(
              label: "Event title",
              hint: "Friday rooftop founders meetup",
            ),
            validator: (value) {
              final v = value?.trim() ?? "";
              if (v.isEmpty) return "Enter an event title.";
              if (v.length > 60) return "Title must be 60 characters or less.";
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildDescriptionEditor(),
        ],
      );
    }

    Widget _buildSessionCard({
      required int index,
      required EventSessionDraft session,
    }) {
      return _tonalCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: _themeSolid.withOpacity(.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _themeSolid.withOpacity(.24),
                    ),
                  ),
                  child: Text(
                    "Session ${index + 1}",
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _softText,
                      letterSpacing: .15,
                    ),
                  ),
                ),
                const Spacer(),
                if (widget.draft.multiSession && widget.draft.sessions.length > 1)
                  InkWell(
                    onTap: () {
                      _dismissKeyboard();
                      setState(() {
                        widget.draft.removeSession(index);
                      });

                      if (widget.draft.sessions.length <= 1) {
                        _animateSessionsToStart();
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _fieldBorder),
                      ),
                      child: Icon(
                        PhosphorIcons.trash(PhosphorIconsStyle.bold),
                        size: 16,
                        color: Colors.white.withOpacity(.86),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _dateTimeButton(
              label: "Start",
              value: _formatDateTime(session.startAt),
              onTap: () => _pickDateTime(
                session: session,
                isStart: true,
              ),
            ),
            const SizedBox(height: 10),
            _dateTimeButton(
              label: "End",
              value: _formatDateTime(session.endAt),
              onTap: () => _pickDateTime(
                session: session,
                isStart: false,
              ),
            ),
          ],
        ),
      );
    }

    Widget _buildHostsGroup() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(
            title: "Hosts",
            subtitle: "You are the owner. Invite up to 6 co-hosts after the event is created.",
          ),
          const SizedBox(height: 14),
          _tonalCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _themeSolid.withOpacity(.16),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _themeSolid.withOpacity(.24)),
                      ),
                      child: Icon(
                        PhosphorIcons.crownSimple(PhosphorIconsStyle.fill),
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Event owner",
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: _softText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "The creator owns this event. Co-hosts can be invited after creation.",
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: _mutedText,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _panelBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        PhosphorIcons.usersThree(PhosphorIconsStyle.bold),
                        size: 16,
                        color: Colors.white.withOpacity(.9),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Up to 6 co-hosts",
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _softText,
                          ),
                        ),
                      ),
                      Text(
                        "After create",
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _themeSolid,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    Widget _buildScheduleGroup() {
      final sessions = widget.draft.sessions;

      final cardWidth = math.min(
        MediaQuery.of(context).size.width - 84,
        340.0,
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(title: "Schedule"),
          const SizedBox(height: 14),
          _toggleTile(
            title: "Multi-session event",
            subtitle: "Turn this on only if this actually spans multiple blocks.",
            value: widget.draft.multiSession,
            onChanged: (value) {
              _dismissKeyboard();
              setState(() {
                widget.draft.multiSession = value;

                if (!value && widget.draft.sessions.length > 1) {
                  final first = widget.draft.sessions.first;
                  widget.draft.sessions
                    ..clear()
                    ..add(first);
                }
              });

              if (!value) {
                _animateSessionsToStart();
              }
            },
          ),
          const SizedBox(height: 14),

          SizedBox(
            height: 390,
            child: SingleChildScrollView(
              controller: _sessionScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(sessions.length, (index) {
                  final session = sessions[index];

                  return Padding(
                    padding: EdgeInsets.only(
                      right: index == sessions.length - 1 ? 0 : 12,
                    ),
                    child: SizedBox(
                      width: cardWidth,
                      child: _buildSessionCard(
                        index: index,
                        session: session,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          if (widget.draft.multiSession) ...[
            const SizedBox(height: 10),
            Text(
              sessions.length > 1
                  ? "Swipe left or right between sessions."
                  : "New sessions will appear to the right.",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _mutedText,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  _dismissKeyboard();

                  if (widget.draft.sessions.length >= 10) {
                    _showError("You can add up to 10 sessions for one event.");
                    return;
                  }

                  setState(() {
                    widget.draft.addSession();
                  });

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _animateToLatestSession();
                  });
                },
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _fieldBorder),
                  backgroundColor: _panelFill,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                icon: Icon(
                  PhosphorIcons.plus(PhosphorIconsStyle.bold),
                  color: Colors.white,
                  size: 18,
                ),
                label: Text(
                  "Add session",
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _softText,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    Widget _buildPlaceGroup() {
      final inPerson = widget.draft.venueType == EventVenueType.inPerson;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(title: "Place"),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: EventVenueType.values.map((type) {
              final selected = widget.draft.venueType == type;

              return _pillButton(
                label: type == EventVenueType.virtual ? "Virtual" : "In person",
                icon: type == EventVenueType.virtual
                    ? PhosphorIcons.videoCamera(PhosphorIconsStyle.bold)
                    : PhosphorIcons.mapPin(PhosphorIconsStyle.bold),
                selected: selected,
                onTap: () {
                  _dismissKeyboard();
                  setState(() {
                    widget.draft.venueType = type;
                    _placePredictions = [];
                    _placeSearching = false;
                    _placeDetailsLoading = false;
                    if (type != EventVenueType.inPerson) {
                      _selectedPlace = null;
                      _showMeetupInstructionsComposer = false;
                      widget.draft.meetupInstructionsCtrl.clear();
                      widget.draft.meetupInstructionsValue = null;
                    }
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller:
                inPerson ? widget.draft.locationCtrl : widget.draft.virtualLinkCtrl,
            maxLines: inPerson ? 2 : 1,
            onChanged: inPerson ? _onPlaceTextChanged : null,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: _softText,
            ),
            decoration: _inputDecoration(
              label: inPerson ? "Location" : "Virtual link / platform",
              hint: inPerson
                  ? "Search for a real place like East Park Mall, Lusaka"
                  : "Google Meet, Zoom, Discord, or direct link",
            ),
            validator: (value) {
              final v = value?.trim() ?? "";
              if (v.isEmpty) {
                return inPerson
                    ? "Enter the event location."
                    : "Enter the virtual meeting link or platform.";
              }
              return null;
            },
          ),
          if (inPerson) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _placeDetailsLoading ? null : _useMyCurrentLocation,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _fieldBorder),
                  backgroundColor: _panelFill,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                icon: Icon(
                  PhosphorIcons.navigationArrow(PhosphorIconsStyle.bold),
                  size: 18,
                  color: _softText,
                ),
                label: Text(
                  "Use my current location",
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _softText,
                  ),
                ),
              ),
            ),
            _buildSelectedPlaceCard(),
            if (inPerson && _selectedPlace != null) ...[
              const SizedBox(height: 12),

              if ((widget.draft.meetupInstructionsValue ?? "").trim().isEmpty &&
                  !_showMeetupInstructionsComposer)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _dismissKeyboard();
                      setState(() {
                        _showMeetupInstructionsComposer = true;
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: _fieldBorder),
                      backgroundColor: _panelFill,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 15,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: Icon(
                      PhosphorIcons.plus(PhosphorIconsStyle.bold),
                      size: 18,
                      color: _softText,
                    ),
                    label: Text(
                      "Add further instructions",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _softText,
                      ),
                    ),
                  ),
                ),

              if (_showMeetupInstructionsComposer) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.draft.meetupInstructionsCtrl,
                        focusNode: _meetupInstructionsFocusNode,
                        onTapOutside: (_) => _dismissKeyboard(),
                        textCapitalization: TextCapitalization.sentences,
                        maxLength: 100,
                        onSubmitted: (_) => _addMeetupInstructions(),
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: _softText,
                        ),
                        decoration: _inputDecoration(
                          label: "Further instructions",
                          hint: "Take the elevator, 2nd floor, meet outside the studio",
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _addMeetupInstructions,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _themeSolid,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: Icon(
                          PhosphorIcons.plus(PhosphorIconsStyle.bold),
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              if ((widget.draft.meetupInstructionsValue ?? "").trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: _themeSolid.withOpacity(.17),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withOpacity(.08),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            PhosphorIcons.mapTrifold(PhosphorIconsStyle.bold),
                            size: 14,
                            color: Colors.white.withOpacity(.94),
                          ),
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text(
                              widget.draft.meetupInstructionsValue!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withOpacity(.94),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _removeMeetupInstructions,
                            child: Icon(
                              PhosphorIcons.x(PhosphorIconsStyle.bold),
                              size: 14,
                              color: Colors.white.withOpacity(.88),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
            _buildPlacePredictionsPanel(),
          ],
        ],
      );
    }

    Widget _buildAccessGroup() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(title: "Access"),
          const SizedBox(height: 14),
          Text(
            "Privacy",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _mutedText,
              letterSpacing: .2,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: EventPrivacy.values.map((privacy) {
              final selected = widget.draft.privacy == privacy;
              return _pillButton(
                label: _privacyLabel(privacy),
                selected: selected,
                onTap: () {
                  _dismissKeyboard();
                  setState(() {
                    widget.draft.privacy = privacy;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Text(
            "Who can join",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _mutedText,
              letterSpacing: .2,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: EventAccess.values.map((access) {
              final selected = widget.draft.access == access;
              return _pillButton(
                label: _accessLabel(access),
                selected: selected,
                onTap: () {
                  _dismissKeyboard();
                  setState(() {
                    widget.draft.access = access;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          _toggleTile(
            title: "Require registration",
            subtitle: "Turn this off only if people can join freely without approval.",
            value: widget.draft.requireRegistration,
            onChanged: (value) {
              _dismissKeyboard();
              setState(() {
                widget.draft.requireRegistration = value;
              });
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: widget.draft.maxPeopleCtrl,
            focusNode: _maxPeopleFocusNode,
            onTapOutside: (_) => _dismissKeyboard(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _softText,
            ),
            decoration: _inputDecoration(
              label: "Attendee limit",
              hint: "50",
            ),
            validator: (value) {
              final v = int.tryParse((value ?? "").trim());
              if (v == null || v <= 0) {
                return "Enter a valid attendee limit.";
              }
              return null;
            },
          ),
        ],
      );
    }

    Widget _buildEventMediaDoneBadge(EventDraftMediaItem item) {
      if (item.uploadState != EventMediaUploadState.done) {
        return const SizedBox.shrink();
      }

      return Positioned(
        left: 8,
        top: 8,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFF16A34A),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(.24),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.18),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.check,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    Widget _buildDiscoveryGroup() {
      final isCustom = widget.draft.selectedCategory == "custom";
      final baseCategories =
          _categoryOptions.where((category) => category != "custom").toList();

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _groupHeader(title: "Discovery"),
          const SizedBox(height: 14),

          _subSectionLabel(
            "Category",
            subtitle: "How people will discover this event.",
          ),
          const SizedBox(height: 10),

          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: baseCategories.map((category) {
              final selected = widget.draft.selectedCategory == category;

              return _pillButton(
                label: _capitalise(category),
                icon: _categoryIcon(category),
                selected: selected,
                onTap: () {
                  setState(() {
                    widget.draft.selectedCategory = category;
                  });
                },
              );
            }).toList(),
          ),

          const SizedBox(height: 12),
          _buildCustomCategoryCard(isSelected: isCustom),

          if (isCustom) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: widget.draft.customCategoryCtrl,
                    focusNode: _customCategoryFocusNode,
                    onTapOutside: (_) => _dismissKeyboard(),
                    textCapitalization: TextCapitalization.sentences,
                    onFieldSubmitted: (_) => _addCustomCategory(),
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: _softText,
                    ),
                    decoration: _inputDecoration(
                      label: "Custom category",
                      hint: "Tech breakfast, rooftop mixer, art jam...",
                    ),
                    validator: (_) {
                      if (widget.draft.selectedCategory == "custom" &&
                          (widget.draft.customCategoryValue ?? "").trim().isEmpty) {
                        return "Add your custom category.";
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _addCustomCategory,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _themeSolid,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Icon(
                      PhosphorIcons.plus(PhosphorIconsStyle.bold),
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),

            if ((widget.draft.customCategoryValue ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _themeSolid.withOpacity(.17),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withOpacity(.08),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _categoryIcon("custom"),
                          size: 14,
                          color: Colors.white.withOpacity(.94),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.draft.customCategoryValue!,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withOpacity(.94),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              widget.draft.customCategoryValue = null;
                            });
                          },
                          child: Icon(
                            PhosphorIcons.x(PhosphorIconsStyle.bold),
                            size: 14,
                            color: Colors.white.withOpacity(.88),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],

          const SizedBox(height: 18),

          _subSectionLabel(
            "Tags",
            subtitle: "Extra search words for discovery.",
          ),
          const SizedBox(height: 10),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.draft.tagCtrl,
                  focusNode: _tagFocusNode,
                  onTapOutside: (_) => _dismissKeyboard(),
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: _softText,
                  ),
                  decoration: _inputDecoration(
                    label: "Add tag",
                    hint: "founders, lusaka, fintech",
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                width: 56,
                child: ElevatedButton(
                  onPressed: _addTag,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _themeSolid,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Icon(
                    PhosphorIcons.plus(PhosphorIconsStyle.bold),
                    size: 18,
                  ),
                ),
              ),
            ],
          ),

          if (widget.draft.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: widget.draft.tags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _themeSolid.withOpacity(.17),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withOpacity(.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "#$tag",
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withOpacity(.94),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            widget.draft.tags.remove(tag);
                          });
                        },
                        child: Icon(
                          PhosphorIcons.x(PhosphorIconsStyle.bold),
                          size: 14,
                          color: Colors.white.withOpacity(.88),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 18),

          _subSectionLabel(
            "Media (Optional)",
            subtitle: "Photos / Videos / Files",
          ),
          const SizedBox(height: 4),
          Text(
            "Add proof (max 6, 50MB each)",
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: _mutedText,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              "${_eventMediaItems.length}/6 added",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _softText,
              ),
            ),
          ),

          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: _mediaSourceButton(
                  label: "Gallery",
                  icon: PhosphorIcons.images(PhosphorIconsStyle.bold),
                  onTap: _eventMediaFull ? null : _pickEventMediaFromGallery,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _mediaSourceButton(
                  label: "Camera",
                  icon: PhosphorIcons.camera(PhosphorIconsStyle.bold),
                  onTap: _eventMediaFull ? null : _pickEventMediaFromCamera,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _mediaSourceButton(
                  label: "Files",
                  icon: PhosphorIcons.paperclip(PhosphorIconsStyle.bold),
                  onTap: _eventMediaFull ? null : _pickEventFiles,
                ),
              ),
            ],
          ),

          if (_eventMediaItems.isNotEmpty) ...[
            const SizedBox(height: 14),
            GridView.builder(
              itemCount: _eventMediaItems.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
              ),
              itemBuilder: (context, index) {
                final item = _eventMediaItems[index];

                return AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: _buildEventMediaPreview(item),
                        ),

                        if (item.isVideo)
                          Align(
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.45),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                PhosphorIcons.play(PhosphorIconsStyle.fill),
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),

                        _buildEventMediaProgressOverlay(item),
                        _buildEventMediaDoneBadge(item),

                        Positioned(
                          right: 8,
                          top: 8,
                          child: GestureDetector(
                            onTap: () {
                              _dismissKeyboard();
                              setState(() {
                                _eventMediaItems.removeAt(index);
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.56),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                PhosphorIcons.x(PhosphorIconsStyle.bold),
                                size: 12,
                                color: Colors.white,
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
          ] else ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                color: _panelFill,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _panelBorder),
              ),
              child: Column(
                children: [
                  Icon(
                    PhosphorIcons.imagesSquare(PhosphorIconsStyle.bold),
                    size: 28,
                    color: Colors.white.withOpacity(.45),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "No media yet",
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(.78),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Photos, videos, or files you want attached",
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: _mutedText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }

    Widget _subSectionLabel(String title, {String? subtitle}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _softText,
              letterSpacing: .2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: _mutedText,
                height: 1.3,
              ),
            ),
          ],
        ],
      );
    }

    Widget _buildCustomCategoryCard({required bool isSelected}) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              widget.draft.selectedCategory = "custom";
            });
          },
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isSelected ? _themeSolid.withOpacity(.16) : _panelFill,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? _themeSolid.withOpacity(.45)
                    : _panelBorder,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? _themeSolid.withOpacity(.30)
                        : Colors.white.withOpacity(.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? _themeSolid.withOpacity(.30)
                          : Colors.white.withOpacity(.08),
                    ),
                  ),
                  child: Icon(
                    PhosphorIcons.plus(PhosphorIconsStyle.bold),
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Custom category",
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _softText,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Different from the options above. Tap this and name your own.",
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: _mutedText,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(
                    PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
                    size: 18,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    Widget _groupHeader({
      required String title,
      String? subtitle,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _sectionTitle),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: _sectionBody),
          ],
        ],
      );
    }

    Widget _thinDivider() {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Container(
          width: double.infinity,
          height: 1,
          color: _dividerColor,
        ),
      );
    }

    Widget _tonalCard({
      required Widget child,
    }) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _panelFill,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _panelBorder),
        ),
        child: child,
      );
    }

    Widget _circleGlassButton({
      required IconData icon,
      required VoidCallback? onTap,
    }) {
      return Material(
        color: Colors.white.withOpacity(.14),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 20,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

  Widget _pillButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    bool compact = false,
    Color? fillColor,
    Color? borderColor,
    Color? foregroundColor,
  }) {
    final resolvedFill =
        fillColor ?? (selected ? _themeSolid : _inactiveChipFill);

    final resolvedBorder =
        borderColor ?? (selected ? _themeSolid : _inactiveChipBorder);

    final resolvedForeground =
        foregroundColor ?? Colors.white.withOpacity(selected ? 1 : .88);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: resolvedFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: resolvedBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: compact ? 15 : 16,
                  color: resolvedForeground,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: resolvedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

    Widget _toggleTile({
      required String title,
      required String subtitle,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: _panelFill,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _panelBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _softText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                      color: _mutedText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: _themeSolid,
              inactiveThumbColor: Colors.white.withOpacity(.92),
              inactiveTrackColor: Colors.white.withOpacity(.20),
            ),
          ],
        ),
      );
    }

  Widget _dateTimeButton({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final hasValue = !value.toLowerCase().contains("select");
    final isStart = label.toLowerCase() == "start";

    final fill = _themeSolid.withOpacity(hasValue ? .18 : .10);
    final border = _themeSolid.withOpacity(hasValue ? .46 : .24);
    final badgeFill = _themeSolid.withOpacity(hasValue ? .28 : .18);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 140),
          child: Ink(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border, width: hasValue ? 1.35 : 1.05),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.08),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: badgeFill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _themeSolid.withOpacity(.26),
                        ),
                      ),
                      child: Icon(
                        isStart
                            ? PhosphorIcons.calendarBlank(PhosphorIconsStyle.bold)
                            : PhosphorIcons.clockAfternoon(PhosphorIconsStyle.bold),
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _mutedText,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    value,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: _softText,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hasValue ? "Change" : "Choose",
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withOpacity(.78),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                      size: 14,
                      color: Colors.white.withOpacity(.74),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

    InputDecoration _inputDecoration({
      required String label,
      required String hint,
    }) {
      return InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          color: Colors.white.withOpacity(.62),
        ),
        floatingLabelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          color: Colors.white.withOpacity(.82),
        ),
        hintStyle: TextStyle(
          fontWeight: FontWeight.w400,
          color: Colors.white.withOpacity(.34),
        ),
        filled: true,
        fillColor: _fieldFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _fieldBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _themeSolid, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0xFFFF7A8A), width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0xFFFF7A8A), width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        counterStyle: TextStyle(
          fontWeight: FontWeight.w500,
          color: Colors.white.withOpacity(.48),
        ),
        errorStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          color: Color(0xFFFFB3C1),
        ),
      );
    }

    Future<void> _openCoverPicker() async {
      if (_coverPickerOpen || !mounted) return;

      _coverPickerOpen = true;

      try {
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          useSafeArea: false,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) {
            final height = MediaQuery.of(sheetContext).size.height * 0.84;

            return SafeArea(
              top: false,
              child: SizedBox(
                height: height,
                child: Container(
                  decoration: BoxDecoration(
                    color: _sheetFill,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(32),
                    ),
                    border: Border.all(color: _sheetBorder),
                  ),
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: Container(
                                  width: 46,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(.18),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                "Choose cover",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: _softText,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "Gallery, presets, gradients, or solids.",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                  color: _mutedText,
                                ),
                              ),
                              const SizedBox(height: 18),
                              InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () async {
                                  Navigator.pop(sheetContext);
                                  await Future.delayed(
                                    const Duration(milliseconds: 120),
                                  );
                                  if (!mounted) return;
                                  await _pickCoverImage();
                                },
                                child: Ink(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _panelFill,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: _panelBorder),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        PhosphorIcons.imageSquare(
                                          PhosphorIconsStyle.bold,
                                        ),
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        "Upload from gallery",
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: _softText,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 22),
                              _coverPickerSectionLabel("Presets"),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ),

                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final assetPath = _coverChoiceAssets[index];
                              final selected =
                                  _selectedPresetCoverAsset == assetPath;

                              return RepaintBoundary(
                                child: _coverOptionTile(
                                  selected: selected,
                                  onTap: () {
                                    setState(() {
                                      _coverAsset = null;
                                      _selectedGradientCoverId = null;
                                      _selectedPresetCoverAsset = assetPath;
                                    });
                                    Navigator.pop(sheetContext);
                                  },
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(18),
                                    child: Image.asset(
                                      assetPath,
                                      fit: BoxFit.contain,
                                      cacheWidth: 420,
                                      filterQuality: FilterQuality.none,
                                      errorBuilder: (_, __, ___) {
                                        return Container(
                                          color: Colors.white.withOpacity(.08),
                                          alignment: Alignment.center,
                                          child: Icon(
                                            Icons.broken_image_rounded,
                                            color: Colors.white.withOpacity(.45),
                                            size: 28,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              );
                            },
                            childCount: _coverChoiceAssets.length,
                          ),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.55,
                          ),
                        ),
                      ),

                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
                          child: _coverPickerSectionLabel("Gradients"),
                        ),
                      ),

                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final entry =
                                  _gradientCoverOptions.entries.elementAt(index);
                              final selected =
                                  _selectedGradientCoverId == entry.key;

                              return _coverOptionTile(
                                selected: selected,
                                onTap: () {
                                  setState(() {
                                    _coverAsset = null;
                                    _selectedPresetCoverAsset = null;
                                    _selectedGradientCoverId = entry.key;
                                  });
                                  Navigator.pop(sheetContext);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: entry.value
                                          .map((e) => Color(e))
                                          .toList(),
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                  ),
                                ),
                              );
                            },
                            childCount: _gradientCoverOptions.length,
                          ),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.55,
                          ),
                        ),
                      ),

                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
                          child: _coverPickerSectionLabel("Solid colors"),
                        ),
                      ),

                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final value = _solidCoverOptions[index];
                              final selected =
                                  widget.draft.coverColorValue == value &&
                                  _coverAsset == null &&
                                  _selectedPresetCoverAsset == null &&
                                  _selectedGradientCoverId == null;

                              return _coverOptionTile(
                                selected: selected,
                                onTap: () {
                                  setState(() {
                                    widget.draft.coverColorValue = value;
                                    _coverAsset = null;
                                    _selectedPresetCoverAsset = null;
                                    _selectedGradientCoverId = null;
                                  });
                                  Navigator.pop(sheetContext);
                                },
                                child: Container(color: Color(value)),
                              );
                            },
                            childCount: _solidCoverOptions.length,
                          ),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.55,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      } finally {
        _coverPickerOpen = false;
      }
    }

    Widget _coverPickerSectionLabel(String text) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white.withOpacity(.86),
          letterSpacing: .2,
        ),
      );
    }

    Widget _coverOptionTile({
      required bool selected,
      required VoidCallback onTap,
      required Widget child,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? Colors.white : _panelBorder,
              width: selected ? 2.0 : 1.0,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(.18),
                      blurRadius: 14,
                      offset: const Offset(0, 7),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (selected)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    margin: const EdgeInsets.all(10),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.16),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(.20)),
                    ),
                    child: const Icon(
                      Icons.check,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    Widget _buildBottomActionBar() {
      return Positioned(
        left: 16,
        right: 16,
        bottom: 0,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.16),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(.08)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 56,
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _themeSolid,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Icon(
                              PhosphorIcons.calendarPlus(
                                PhosphorIconsStyle.bold,
                              ),
                              size: 20,
                            ),
                      label: Text(
                        _saving ? "Creating..." : "Create event",
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),

                  if (_saving) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _overallUploadProgress,
                        minHeight: 8,
                        backgroundColor: Colors.white.withOpacity(.10),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(_themeSolid),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _createStage.isEmpty
                            ? "Creating event..."
                            : _createStage,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _mutedText,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget _containedCoverWithBlur({
      required ImageProvider imageProvider,
    }) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.high,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return SizedBox.shrink();
        },
        errorBuilder: (context, error, stack) => Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _coverColor.withOpacity(.96),
                _coverColor.withOpacity(.72),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      );
    }

    Widget _buildCoverPreview() {
      if (_coverAsset != null) {
        return _containedCoverWithBlur(
          imageProvider: AssetEntityImageProvider(
            _coverAsset!,
            isOriginal: true,
          ),
        );
      }

      if (_selectedPresetCoverAsset != null) {
        return Image.asset(
          _selectedPresetCoverAsset!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stack) => Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _coverColor.withOpacity(.96),
                  _coverColor.withOpacity(.72),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        );
      }

      if (_selectedGradientCoverId != null) {
        final colors = _gradientCoverOptions[_selectedGradientCoverId!]!
            .map((e) => Color(e))
            .toList();

        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        );
      }

      return Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _coverColor.withOpacity(.96),
              _coverColor.withOpacity(.72),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );
    }

    Widget _buildCoverSection() {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Event cover", style: _sectionTitle),
                  const SizedBox(height: 4),
                  Text(
                    "Pick a cover that actually makes the event feel real.",
                    style: _bodyStyle,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: SizedBox(
                  height: 212,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildCoverPreview(),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(.28),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.draft.titleCtrl.text.trim().isEmpty
                                    ? "Your event cover"
                                    : widget.draft.titleCtrl.text.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _openCoverPicker,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _themeSolid,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                ),
                                icon: Icon(
                                  PhosphorIcons.imageSquare(PhosphorIconsStyle.bold),
                                  size: 18,
                                ),
                                label: const Text(
                                  "",
                                  style: TextStyle(
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
              ),
            ),
          ],
        ),
      );
    }


  Widget _buildThemeSection() {
    final total = _eventThemes.length;
    final mid = (total - 1) / 2;

    return _sectionCard(
      title: "Event theme",
      subtitle: "Gradient background. Solid buttons. Pick the color system.",
      child: SizedBox(
        height: 76,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(_eventThemes.length, (index) {
              final theme = _eventThemes[index];
              final distance = (index - mid).abs();
              final factor = mid == 0 ? 0.0 : (1 - (distance / mid));
              final double dy = math.max(0.0, factor * 8.0).toDouble();

              final selected = widget.draft.selectedTheme == theme.id;

              return Transform.translate(
                offset: Offset(0, dy),
                child: Padding(
                  padding: EdgeInsets.only(
                    right: index == _eventThemes.length - 1 ? 0 : 12,
                  ),
                  child: _themeCircle(
                    theme: theme,
                    selected: selected,
                    onTap: () {
                      setState(() {
                        widget.draft.selectedTheme = theme.id;
                      });
                    },
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _themeCircle({
    required _EventThemePalette theme,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [theme.top, theme.bottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          border: Border.all(
            color: Colors.white.withOpacity(selected ? .90 : .38),
            width: selected ? 2.6 : 1.3,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.16),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: selected
            ? Center(
                child: Icon(
                  PhosphorIcons.check(PhosphorIconsStyle.bold),
                  size: 14,
                  color: Colors.white,
                ),
              )
            : null,
      ),
    );
  }

  Widget _themeSwatch({
    required _EventThemePalette theme,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 78,
        height: 92,
        padding: EdgeInsets.all(selected ? 3 : 1.2),
        decoration: BoxDecoration(
          color: selected ? theme.bottom.withOpacity(.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? theme.bottom.withOpacity(.75)
                : const Color(0xFFE2E8F0),
            width: selected ? 1.8 : 1.0,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.top, theme.bottom],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(21),
            boxShadow: [
              BoxShadow(
                color: theme.bottom.withOpacity(.18),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.28),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Positioned(
                top: 24,
                left: 10,
                right: 20,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.20),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 12,
                child: Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.18),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withOpacity(.16),
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.22),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(.28),
                      ),
                    ),
                    child: Icon(
                      PhosphorIcons.check(PhosphorIconsStyle.bold),
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacySection() {
    return _sectionCard(
      title: "Privacy settings",
      subtitle: "Control visibility before you start collecting people.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: EventPrivacy.values.map((privacy) {
              final selected = widget.draft.privacy == privacy;
              return _choicePill(
                label: _privacyLabel(privacy),
                selected: selected,
                onTap: () {
                  setState(() {
                    widget.draft.privacy = privacy;
                  });
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildTextSection() {
    return _sectionCard(
      title: "Event details",
      subtitle: "Write like a serious builder, not like a confused toddler.",
      child: Column(
        children: [
          TextFormField(
            controller: widget.draft.titleCtrl,
            maxLength: 60,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              color: Color(0xFF0F172A),
            ),
            decoration: _inputDecoration(
              label: "Event title",
              hint: "Friday rooftop founders meetup",
            ),
            validator: (value) {
              final v = value?.trim() ?? "";
              if (v.isEmpty) return "Enter an event title.";
              if (v.length > 60) return "Title must be 60 characters or less.";
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: widget.draft.descCtrl,
            focusNode: _descFocusNode,
            onTapOutside: (_) => _dismissKeyboard(),
            maxLength: 300,
            maxLines: 5,
            style: const TextStyle(
              fontWeight: FontWeight.w400,
              color: Color(0xFF0F172A),
            ),
            decoration: _inputDecoration(
              label: "Description",
              hint:
                  "What is happening, who it is for, why they should care, and what to bring.",
            ),
            validator: (value) {
              final v = value?.trim() ?? "";
              if (v.isEmpty) return "Enter an event description.";
              if (v.length > 300) {
                return "Description must be 300 characters or less.";
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVenueSection() {
    return _sectionCard(
      title: "Meeting type",
      subtitle: "Virtual or in person. Pick one clearly.",
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: EventVenueType.values.map((type) {
          final selected = widget.draft.venueType == type;
          final isVirtual = type == EventVenueType.virtual;

          return _pillButton(
            label: isVirtual ? "Virtual" : "In person",
            icon: isVirtual
                ? PhosphorIcons.videoCamera(PhosphorIconsStyle.bold)
                : PhosphorIcons.mapPin(PhosphorIconsStyle.bold),
            selected: selected,
            onTap: () {
              setState(() {
                widget.draft.venueType = type;
              });
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDateTimeSection() {
    return _sectionCard(
      title: "When will this happen",
      subtitle: "Single session or multi session. Don’t be sloppy with time.",
      child: Column(
        children: [
          SwitchListTile(
            value: widget.draft.multiSession,
            contentPadding: EdgeInsets.zero,
            activeThumbColor: _themeSolid,
            activeTrackColor: _themeSolid.withOpacity(.35),
            title: const Text(
              "This is a multi-session event",
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF0F172A),
              ),
            ),
            subtitle: const Text(
              "Turn this on if the event runs across multiple days or time blocks.",
              style: TextStyle(
                fontWeight: FontWeight.w400,
                color: Color(0xFF64748B),
              ),
            ),
            onChanged: (value) {
              setState(() {
                widget.draft.multiSession = value;
                if (!value && widget.draft.sessions.length > 1) {
                  final first = widget.draft.sessions.first;
                  widget.draft.sessions
                    ..clear()
                    ..add(first);
                }
              });
            },
          ),
          const SizedBox(height: 6),
          ...List.generate(widget.draft.sessions.length, (index) {
            final session = widget.draft.sessions[index];

            return Padding(
              padding: EdgeInsets.only(
                bottom: index == widget.draft.sessions.length - 1 ? 0 : 12,
              ),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "Session ${index + 1}",
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const Spacer(),
                        if (widget.draft.multiSession &&
                            widget.draft.sessions.length > 1)
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                widget.draft.removeSession(index);
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                PhosphorIcons.trash(PhosphorIconsStyle.bold),
                                size: 16,
                                color: const Color(0xFFDC2626),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _dateTimeButton(
                            label: "Start",
                            value: _formatDateTime(session.startAt),
                            onTap: () => _pickDateTime(
                              session: session,
                              isStart: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _dateTimeButton(
                            label: "End",
                            value: _formatDateTime(session.endAt),
                            onTap: () => _pickDateTime(
                              session: session,
                              isStart: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          if (widget.draft.multiSession) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  widget.draft.addSession();
                });
              },
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _themeSoftBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              icon: Icon(
                PhosphorIcons.plus(PhosphorIconsStyle.bold),
                color: _themeBottom,
                size: 18,
              ),
              label: const Text(
                "Add session",
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCapacitySection() {
    return _sectionCard(
      title: "Capacity",
      subtitle: "Set the number of people allowed to join.",
      child: TextFormField(
        controller: widget.draft.maxPeopleCtrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: _inputDecoration(
          label: "Event limit",
          hint: "50",
        ),
        validator: (value) {
          final v = int.tryParse((value ?? "").trim());
          if (v == null || v <= 0) {
            return "Enter a valid attendee limit.";
          }
          return null;
        },
      ),
    );
  }

  Widget _buildAccessSection() {
    return _sectionCard(
      title: "Who has access",
      subtitle: "Visibility and access are not the same thing. Don’t mix them.",
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: EventAccess.values.map((access) {
              final selected = widget.draft.access == access;
              return _choicePill(
                label: _accessLabel(access),
                selected: selected,
                onTap: () {
                  setState(() {
                    widget.draft.access = access;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: widget.draft.requireRegistration,
            contentPadding: EdgeInsets.zero,
            activeThumbColor: _themeSolid,
            activeTrackColor: _themeSolid.withOpacity(.35),
            title: const Text(
              "Require registration",
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF0F172A),
              ),
            ),
            subtitle: const Text(
              "Turn off only if people can join freely without approval.",
              style: TextStyle(
                fontWeight: FontWeight.w400,
                color: Color(0xFF64748B),
              ),
            ),
            onChanged: (value) {
              setState(() {
                widget.draft.requireRegistration = value;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySection() {
    final isCustom = widget.draft.selectedCategory == "custom";

    return _sectionCard(
      title: "Category and tags",
      subtitle: "Use clean metadata so discovery doesn’t become a joke.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _categoryOptions.map((category) {
              final selected = widget.draft.selectedCategory == category;
              return _choicePill(
                label: _capitalise(category),
                selected: selected,
                onTap: () {
                  setState(() {
                    widget.draft.selectedCategory = category;
                  });
                },
              );
            }).toList(),
          ),
          if (isCustom) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: widget.draft.customCategoryCtrl,
                    onFieldSubmitted: (_) => _addCustomCategory(),
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: _softText,
                    ),
                    decoration: _inputDecoration(
                      label: "Custom category",
                      hint: "Tech breakfast, rooftop mixer, art jam...",
                    ),
                    validator: (_) {
                      if (widget.draft.selectedCategory == "custom" &&
                          (widget.draft.customCategoryValue ?? "").trim().isEmpty) {
                        return "Add your custom category.";
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _addCustomCategory,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _themeSolid,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Icon(
                      _categoryIcon("custom"),
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),

            if ((widget.draft.customCategoryValue ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _themeSolid.withOpacity(.17),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withOpacity(.08),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _categoryIcon("custom"),
                          size: 14,
                          color: Colors.white.withOpacity(.94),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.draft.customCategoryValue!,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withOpacity(.94),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              widget.draft.customCategoryValue = null;
                            });
                          },
                          child: Icon(
                            PhosphorIcons.x(PhosphorIconsStyle.bold),
                            size: 14,
                            color: Colors.white.withOpacity(.88),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.draft.tagCtrl,
                  decoration: _inputDecoration(
                    label: "Add tag",
                    hint: "founders, lusaka, fintech",
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  onPressed: _addTag,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    "Add",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (widget.draft.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: widget.draft.tags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _themeSoftFill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "#$tag",
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF166534),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            widget.draft.tags.remove(tag);
                          });
                        },
                        child: Icon(
                          PhosphorIcons.x(PhosphorIconsStyle.bold),
                          size: 14,
                          color: const Color(0xFF166534),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLocationSection() {
    final inPerson = widget.draft.venueType == EventVenueType.inPerson;

    return _sectionCard(
      title: inPerson ? "Event location" : "Virtual location",
      subtitle: inPerson
          ? "Tell people exactly where to show up."
          : "Add the meeting link or platform details.",
      child: TextFormField(
        controller:
            inPerson ? widget.draft.locationCtrl : widget.draft.virtualLinkCtrl,
        focusNode: inPerson ? _locationFocusNode : _virtualLinkFocusNode,
        onTapOutside: (_) => _dismissKeyboard(),
        maxLines: inPerson ? 2 : 1,
        decoration: _inputDecoration(
          label: inPerson ? "Location" : "Virtual link / platform",
          hint: inPerson
              ? "East Park Mall rooftop, Lusaka"
              : "Google Meet, Zoom, Discord, or direct link",
        ),
        validator: (value) {
          final v = value?.trim() ?? "";
          if (v.isEmpty) {
            return inPerson
                ? "Enter the event location."
                : "Enter the virtual meeting link or platform.";
          }

          if (inPerson && _selectedPlace == null) {
            return "Pick a real place from the search results.";
          }

          return null;
        },
      ),
    );
  }

  Widget _mediaSourceButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: _panelFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _panelBorder),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 18,
                color: Colors.white.withOpacity(disabled ? .32 : .92),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withOpacity(disabled ? .32 : .88),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEventMediaPreview(EventDraftMediaItem item) {
    if (item.asset != null) {
      return AssetEntityImage(
        item.asset!,
        isOriginal: false,
        fit: BoxFit.cover,
      );
    }

    if (item.isImage && item.file != null) {
      return Image.file(
        item.file!,
        fit: BoxFit.cover,
      );
    }

    if (item.isVideo && item.thumbBytes != null) {
      return Image.memory(
        item.thumbBytes!,
        fit: BoxFit.cover,
      );
    }

    return Container(
      color: _themeSolid.withOpacity(.14),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PhosphorIcons.file(PhosphorIconsStyle.bold),
              size: 24,
              color: Colors.white.withOpacity(.85),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                item.ext?.toUpperCase().isNotEmpty == true
                    ? item.ext!.toUpperCase()
                    : "FILE",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white.withOpacity(.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceFill,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _surfaceBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _sectionTitle),
          const SizedBox(height: 4),
          Text(subtitle, style: _bodyStyle),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _choicePill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? _themeSolid : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? _themeSolid : const Color(0xFFE2E8F0),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : const Color(0xFF334155),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glassMiniButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withOpacity(.18),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _squareGhostButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Icon(icon, size: 18, color: const Color(0xFF0F172A)),
      ),
    );
  }

    Future<void> _pickCoverImage() async {
      _dismissKeyboard();

      final assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: const AssetPickerConfig(
          maxAssets: 1,
          requestType: RequestType.image,
        ),
      );

      if (!mounted || assets == null || assets.isEmpty) return;

      setState(() {
        _coverAsset = assets.first;
        _selectedPresetCoverAsset = null;
        _selectedGradientCoverId = null;
      });
    }

  

  Future<void> _pickDateTime({
    required EventSessionDraft session,
    required bool isStart,
  }) async {
    _dismissKeyboard();
    final now = DateTime.now();
    final initial = isStart
        ? (session.startAt ?? now.add(const Duration(hours: 1)))
        : (session.endAt ??
            session.startAt?.add(const Duration(hours: 2)) ??
            now.add(const Duration(hours: 2)));

    ThemeData pickerTheme(BuildContext context) {
      final base = Theme.of(context);

      return base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: _themeSolid,
          secondary: _themeSolid,
          surface: _themeBottom,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: Colors.white,
        ),
        datePickerTheme: DatePickerThemeData(
          backgroundColor: _themeBottom,
          headerBackgroundColor: _themeSolid,
          headerForegroundColor: Colors.white,
          dayForegroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.white;
            return Colors.white.withOpacity(.92);
          }),
          dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return _themeSolid;
            return null;
          }),
          todayForegroundColor: WidgetStatePropertyAll(_themeSolid),
          todayBorder: BorderSide(color: _themeSolid, width: 1.4),
          yearForegroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.white;
            return Colors.white.withOpacity(.92);
          }),
          yearBackgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return _themeSolid;
            return null;
          }),
          cancelButtonStyle: TextButton.styleFrom(
            foregroundColor: Colors.white.withOpacity(.84),
          ),
          confirmButtonStyle: TextButton.styleFrom(
            foregroundColor: _themeSolid,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        timePickerTheme: TimePickerThemeData(
          backgroundColor: _themeBottom,
          hourMinuteColor: _themeSolid.withOpacity(.16),
          hourMinuteTextColor: Colors.white,
          dayPeriodColor: _themeSolid.withOpacity(.14),
          dayPeriodTextColor: Colors.white,
          dialHandColor: _themeSolid,
          dialBackgroundColor: Colors.white.withOpacity(.08),
          dialTextColor: Colors.white,
          entryModeIconColor: Colors.white,
          helpTextStyle: TextStyle(
            color: Colors.white.withOpacity(.82),
            fontWeight: FontWeight.w700,
          ),
          hourMinuteTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          cancelButtonStyle: TextButton.styleFrom(
            foregroundColor: Colors.white.withOpacity(.84),
          ),
          confirmButtonStyle: TextButton.styleFrom(
            foregroundColor: _themeSolid,
          ),
        ),
      );
    }

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) {
        return Theme(
          data: pickerTheme(context),
          child: child!,
        );
      },
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      builder: (context, child) {
        return Theme(
          data: pickerTheme(context),
          child: child!,
        );
      },
    );

    if (pickedTime == null || !mounted) return;

    final dt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    setState(() {
      if (isStart) {
        session.startAt = dt;
        if (session.endAt == null || !session.endAt!.isAfter(dt)) {
          session.endAt = dt.add(const Duration(hours: 2));
        }
      } else {
        session.endAt = dt;
      }
    });
  }

  void _addTag() {
    _dismissKeyboard();

    final raw = widget.draft.tagCtrl.text.trim();
    if (raw.isEmpty) return;

    final cleaned = raw.startsWith("#") ? raw.substring(1) : raw;
    final tag = cleaned.trim().toLowerCase();

    if (tag.isEmpty) return;

    if (!_isEventTagAllowed(tag)) {
      _showError("That tag isn't allowed. Try a simple interest tag.");
      return;
    }

    if (widget.draft.tags.contains(tag)) {
      _showInfo("That tag is already added.");
      widget.draft.tagCtrl.clear();
      return;
    }

    if (widget.draft.tags.length >= 5) {
      _showError("You can add up to 5 tags.");
      return;
    }

    setState(() {
      widget.draft.tags.add(tag);
      widget.draft.tagCtrl.clear();
    });
  }

  void _insertDescriptionText(String insertText) {
    final controller = widget.draft.descCtrl;
    final selection = controller.selection;

    final start = selection.start >= 0 ? selection.start : controller.text.length;
    final end = selection.end >= 0 ? selection.end : controller.text.length;

    final newText = controller.text.replaceRange(start, end, insertText);

    controller.value = controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start + insertText.length,
      ),
      composing: TextRange.empty,
    );

    setState(() {});
  }

  void _wrapDescriptionSelection({
    required String prefix,
    required String suffix,
    String placeholder = "text",
  }) {
    final controller = widget.draft.descCtrl;
    final selection = controller.selection;

    final start = selection.start >= 0 ? selection.start : controller.text.length;
    final end = selection.end >= 0 ? selection.end : controller.text.length;

    final hasSelection = start != end;
    final selectedText =
        hasSelection ? controller.text.substring(start, end) : placeholder;

    final replacement = "$prefix$selectedText$suffix";
    final newText = controller.text.replaceRange(start, end, replacement);

    final cursorOffset = start + replacement.length;

    controller.value = controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorOffset),
      composing: TextRange.empty,
    );

    setState(() {});
  }

  void _prefixDescriptionLines(String prefix) {
    final controller = widget.draft.descCtrl;
    final selection = controller.selection;

    final fullText = controller.text;
    final start = selection.start >= 0 ? selection.start : fullText.length;
    final end = selection.end >= 0 ? selection.end : fullText.length;

    final lineStart = fullText.lastIndexOf('\n', start - 1);
    final actualStart = lineStart == -1 ? 0 : lineStart + 1;

    final lineEndSearch = fullText.indexOf('\n', end);
    final actualEnd = lineEndSearch == -1 ? fullText.length : lineEndSearch;

    final block = fullText.substring(actualStart, actualEnd);
    final lines = block.split('\n');
    final updatedBlock = lines.map((line) => "$prefix$line").join('\n');

    final newText = fullText.replaceRange(actualStart, actualEnd, updatedBlock);

    controller.value = controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: actualStart + updatedBlock.length,
      ),
      composing: TextRange.empty,
    );

    setState(() {});
  }

  void _addCustomCategory() {
    _dismissKeyboard();

    final raw = widget.draft.customCategoryCtrl.text.trim();
    final error = _validateCustomEventCategory(raw);

    if (error != null) {
      _showError(error);
      return;
    }

    final cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');

    setState(() {
      widget.draft.selectedCategory = "custom";
      widget.draft.customCategoryValue = cleaned;
      widget.draft.customCategoryCtrl.clear();
    });

    HapticFeedback.selectionClick();
    _showSuccess("Custom category added.");
  }

  void _saveCustomCategory() {
    final raw = widget.draft.customCategoryCtrl.text.trim();
    if (raw.isEmpty) return;

    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    setState(() {
      widget.draft.selectedCategory = "custom";
      widget.draft.customCategoryCtrl.text = cleaned;
      widget.draft.customCategoryCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: cleaned.length),
      );
    });

    FocusScope.of(context).unfocus();
  }

  Widget _buildDescriptionFormatter() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _pillButton(
          label: "H1",
          selected: false,
          compact: true,
          onTap: () => _insertDescriptionText("# "),
        ),
        _pillButton(
          label: "H2",
          selected: false,
          compact: true,
          onTap: () => _insertDescriptionText("## "),
        ),
        _pillButton(
          label: "Bold",
          selected: false,
          compact: true,
          onTap: () => _wrapDescriptionSelection(
            prefix: "**",
            suffix: "**",
            placeholder: "bold text",
          ),
        ),
        _pillButton(
          label: "Underline",
          selected: false,
          compact: true,
          onTap: () => _wrapDescriptionSelection(
            prefix: "__",
            suffix: "__",
            placeholder: "underlined text",
          ),
        ),
        _pillButton(
          label: "• Bullet",
          selected: false,
          compact: true,
          onTap: () => _prefixDescriptionLines("- "),
        ),
        _pillButton(
          label: "1. List",
          selected: false,
          compact: true,
          onTap: () => _prefixDescriptionLines("1. "),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_saving) return;

    _dismissKeyboard();
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _createStage = "Preparing event...";
      _overallUploadProgress = 0.0;
    });

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showError("You must be logged in to create an event.");
      return;
    }

    final title = widget.draft.titleCtrl.text.trim();
    final description = widget.draft.descCtrl.text.trim();
    final maxPeople = int.tryParse(widget.draft.maxPeopleCtrl.text.trim());
    final selectedThemeId = widget.draft.selectedTheme;

    if (maxPeople == null || maxPeople <= 0) {
      _showError("Enter a valid attendee limit.");
      return;
    }

    final category = widget.draft.selectedCategory == "custom"
        ? (widget.draft.customCategoryValue ?? "").trim()
        : widget.draft.selectedCategory;

    if (category.isEmpty) {
      _showError("Pick a category.");
      return;
    }

    final sessions = widget.draft.sessions
        .map((s) => (start: s.startAt, end: s.endAt))
        .toList();

    if (sessions.any((s) => s.start == null || s.end == null)) {
      _showError("Add both start and end time for every session.");
      return;
    }

    for (var i = 0; i < sessions.length; i++) {
      final start = sessions[i].start!;
      final end = sessions[i].end!;
      if (!end.isAfter(start)) {
        _showError("Session ${i + 1} end time must be after start time.");
        return;
      }
    }

    sessions.sort((a, b) => a.start!.compareTo(b.start!));

    final firstStart = sessions.first.start!;
    final lastEnd = sessions.last.end!;

    final locationText = widget.draft.venueType == EventVenueType.inPerson
        ? widget.draft.locationCtrl.text.trim()
        : widget.draft.virtualLinkCtrl.text.trim();
    final meetupInstructions = (
      (widget.draft.meetupInstructionsValue ?? "").trim().isNotEmpty
          ? widget.draft.meetupInstructionsValue
          : widget.draft.meetupInstructionsCtrl.text
    ).toString().trim();

    if (locationText.isEmpty) {
      _showError(
        widget.draft.venueType == EventVenueType.inPerson
            ? "Enter the event location."
            : "Enter the virtual link or platform.",
      );
      return;
    }

    if (widget.draft.venueType == EventVenueType.inPerson &&
        _selectedPlace == null) {
      _showError("Pick a real place from the search results.");
      return;
    }

    setState(() {
      _saving = true;
      _createStage = "Creating your event...";
      _overallUploadProgress = 0.0;
    });

    await WakelockPlus.enable();

    try {
      final eventRef = FirebaseFirestore.instance.collection("events").doc();

      String? coverImageUrl;
      if (_coverAsset != null) {
        coverImageUrl = await _uploadAsset(
          asset: _coverAsset!,
          storagePath: "events/$uid/${eventRef.id}/cover",
        );
      }

      final List<Map<String, dynamic>> media = [];

      for (var i = 0; i < _eventMediaItems.length; i++) {
        final item = _eventMediaItems[i];
        final file = await _eventMediaToFile(item);

        if (mounted) {
          setState(() {
            _createStage = "Uploading media ${i + 1} of ${_eventMediaItems.length}...";
            item.uploadState = EventMediaUploadState.validating;
            _recomputeOverallUploadProgress();
          });
        }

        final fileName = item.name ?? "media_$i";
        final contentType = item.isFile
            ? (item.contentType ?? "application/octet-stream")
            : item.isVideo
                ? _guessVideoContentType(file?.path ?? fileName)
                : _guessImageContentType(file?.path ?? fileName);

        if (mounted) {
          setState(() {
            item.uploadState = EventMediaUploadState.uploading;
            item.uploadProgress = 0.0;
            _recomputeOverallUploadProgress();
          });
        }

        final url = await _uploadBinary(
          storagePath: "events/$uid/${eventRef.id}/media/media_$i",
          fileName: fileName,
          contentType: contentType,
          file: file,
          bytes: item.isFile ? item.bytes : null,
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              item.uploadProgress = progress;
              _recomputeOverallUploadProgress();
            });
          },
        );

        if (url != null) {
          media.add({
            "type": item.type,
            "url": url,
            "order": i,
            "name": fileName,
            "contentType": contentType,
            if (item.ext != null && item.ext!.isNotEmpty) "ext": item.ext,
            if (item.sizeBytes != null) "sizeBytes": item.sizeBytes,
          });

          if (mounted) {
            setState(() {
              item.uploadState = EventMediaUploadState.done;
              _recomputeOverallUploadProgress();
            });
          }
        } else {
          if (mounted) {
            setState(() {
              item.uploadState = EventMediaUploadState.failed;
              _recomputeOverallUploadProgress();
            });
          }
        }
      }

      final resolvedHostType = EventHostType.user;
      final resolvedHostId = uid;

      if (resolvedHostId.isEmpty) {
        _showError("Event host is missing.");
        return;
      }

      if (widget.draft.venueType == EventVenueType.inPerson && _selectedPlace == null) {
        _showError("Pick a real place from search or use your current location.");
        return;
      }

      final venue = widget.draft.venueType == EventVenueType.inPerson
          ? {
              "type": "inPerson",
              "source": _selectedPlace!.placeId == "device_current_location"
                  ? "device_current_location"
                  : "google_places",
              "placeId": _selectedPlace!.placeId,
              "name": _selectedPlace!.name,
              "formattedAddress": _selectedPlace!.formattedAddress,
              "lat": _selectedPlace!.lat,
              "lng": _selectedPlace!.lng,
              if (_selectedPlace!.lat != null && _selectedPlace!.lng != null)
                "geoPoint": GeoPoint(_selectedPlace!.lat!, _selectedPlace!.lng!),
            }
          : {
              "type": "virtual",
              "source": "manual",
              "label": locationText,
              "linkOrPlatform": locationText,
            };

      final normalizedLocationText = widget.draft.venueType == EventVenueType.inPerson
          ? (_selectedPlace!.name.isNotEmpty
              ? _selectedPlace!.name
              : _selectedPlace!.formattedAddress)
          : locationText;

      debugPrint("🧪 EVENT CREATE placeId=${_selectedPlace?.placeId}");
      debugPrint("🧪 EVENT CREATE placeName=${_selectedPlace?.name}");
      debugPrint("🧪 EVENT CREATE formattedAddress=${_selectedPlace?.formattedAddress}");
      debugPrint("🧪 EVENT CREATE lat=${_selectedPlace?.lat}");
      debugPrint("🧪 EVENT CREATE lng=${_selectedPlace?.lng}");
      debugPrint("🧪 EVENT CREATE venue=$venue");
      debugPrint("🧪 EVENT CREATE cover=${{
        "type": coverImageUrl != null
            ? "uploaded"
            : _selectedPresetCoverAsset != null
                ? "preset"
                : _selectedGradientCoverId != null
                    ? "gradient"
                    : "solid",
        if (coverImageUrl != null) "imageUrl": coverImageUrl,
        if (_selectedPresetCoverAsset != null)
          "presetAssetPath": _selectedPresetCoverAsset,
        if (_selectedGradientCoverId != null)
          "gradientId": _selectedGradientCoverId,
        if (_selectedGradientCoverId != null)
          "gradientColors": _gradientCoverOptions[_selectedGradientCoverId!]!,
        "colorValue": widget.draft.coverColorValue,
      }}");
      debugPrint("🧪 EVENT CREATE media=$media"); 

      if (widget.draft.venueType == EventVenueType.inPerson) {
        if (_selectedPlace == null ||
            _selectedPlace!.lat == null ||
            _selectedPlace!.lng == null) {
          _showError("Pick a real place with valid map coordinates.");
          return;
        }
      }

      try {
        debugPrint("🧪 Creating event doc...");
        debugPrint("🧪 Sessions count: ${sessions.length}");
        debugPrint("🧪 Venue: $venue");

        await eventRef.set({
          "creatorId": uid,
          

          "hostType": resolvedHostType.name,
          "hostId": resolvedHostId,

          "coHostUids": <String>[],
          "coHostCount": 0,

          "title": title,
          "titleLower": title.toLowerCase(),
          "description": description,
          "theme": selectedThemeId,


          "privacy": widget.draft.privacy.name,
          "venueType": widget.draft.venueType.name,
          "meetupInstructions": meetupInstructions,
          "access": widget.draft.access.name,
          "requireRegistration": widget.draft.requireRegistration,

          "maxAttendees": maxPeople,
          "attendeeCount": 0,
          "registrationCount": 0,

          "category": category,
          "tags": widget.draft.tags.map((e) => e.toLowerCase()).toList(),

          "locationText": normalizedLocationText,
          "venue": venue,

          "isMultiSession": widget.draft.multiSession,
          "sessions": sessions
              .map((s) => {
                    "startAt": Timestamp.fromDate(s.start!),
                    "endAt": Timestamp.fromDate(s.end!),
                  })
              .toList(),
          "startsAt": Timestamp.fromDate(firstStart),
          "endsAt": Timestamp.fromDate(lastEnd),

          "cover": {
            "type": coverImageUrl != null
                ? "uploaded"
                : _selectedPresetCoverAsset != null
                    ? "preset"
                    : _selectedGradientCoverId != null
                        ? "gradient"
                        : "solid",
            if (coverImageUrl != null) "imageUrl": coverImageUrl,
            if (_selectedPresetCoverAsset != null)
              "presetAssetPath": _selectedPresetCoverAsset,
            if (_selectedGradientCoverId != null)
              "gradientId": _selectedGradientCoverId,
            if (_selectedGradientCoverId != null)
              "gradientColors": _gradientCoverOptions[_selectedGradientCoverId!]!,
            "colorValue": widget.draft.coverColorValue,
          },

          "media": media,
          "status": "published",
          "createdAt": FieldValue.serverTimestamp(),
          "updatedAt": FieldValue.serverTimestamp(),
        });

        debugPrint("✅ Event doc created");
      } catch (e, st) {
        debugPrint("❌ Event doc failed: $e");
        debugPrintStack(stackTrace: st);
        rethrow;
      }

      try {
        debugPrint("🧪 Creating host doc...");

        await eventRef.collection("hosts").doc(uid).set({
          "uid": uid,
          "role": "owner",
          "status": "active",
          "invitedBy": uid,
          "invitedAt": FieldValue.serverTimestamp(),
          "respondedAt": FieldValue.serverTimestamp(),
          "addedAt": FieldValue.serverTimestamp(),
        });

        debugPrint("✅ Host doc created");
      } catch (e, st) {
        debugPrint("❌ Host doc failed: $e");
        debugPrintStack(stackTrace: st);
        rethrow;
      }

      widget.draft.reset();
        _coverAsset = null;
        _selectedPresetCoverAsset = null;
        _selectedGradientCoverId = null;
        _eventMediaItems.clear();

        if (!mounted) return;

        Navigator.pop(
          context,
          CreateEventResult(
            eventId: eventRef.id,
            title: title,
            themeId: selectedThemeId,
            showCreatedPopup: true,
          ),
        );
    } catch (e, st) {
      debugPrint("❌ create event failed: $e");
      debugPrintStack(stackTrace: st);
      _showError(_friendlyEventError(e));
    } finally {
        await WakelockPlus.disable();

        if (mounted) {
          setState(() {
            _saving = false;
            _createStage = "";
            _overallUploadProgress = 0.0;
          });
        }
      }
  }

  Future<String?> _uploadAsset({
    required AssetEntity asset,
    required String storagePath,
  }) async {
    final file = await asset.file;
    if (file == null) return null;

    final ext = p.extension(file.path).isEmpty ? ".jpg" : p.extension(file.path);
    final ref = FirebaseStorage.instance.ref("$storagePath$ext");
    await ref.putFile(file);
    return await ref.getDownloadURL();
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return "Select date & time";

    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, "0");
    final ampm = dt.hour >= 12 ? "PM" : "AM";

    return "${dt.day}/${dt.month}/${dt.year} • $hour:$minute $ampm";
  }

  String _privacyLabel(EventPrivacy value) {
    switch (value) {
      case EventPrivacy.public:
        return "Public";
      case EventPrivacy.connections:
        return "Friends";
      case EventPrivacy.inviteOnly:
        return "Invite only";
    }
  }

  String _accessLabel(EventAccess value) {
    switch (value) {
      case EventAccess.everyone:
        return "Everyone";
      case EventAccess.connectionsOnly:
        return "Friends only";
      case EventAccess.verifiedOnly:
        return "Verified only";
    }
  }

  String _capitalise(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
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
    _showBottomSnack(message, duration: const Duration(seconds: 2));
  }
}

class _EventThemePalette {
  final String id;
  final Color top;
  final Color bottom;
  final Color solid;

  const _EventThemePalette({
    required this.id,
    required this.top,
    required this.bottom,
    required this.solid,
  });
}

