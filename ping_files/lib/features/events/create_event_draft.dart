import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

enum EventVenueType { virtual, inPerson }
enum EventPrivacy { public, connections, inviteOnly }
enum EventAccess { everyone, connectionsOnly, verifiedOnly }
enum EventHostType { user, community }

class EventSessionDraft {
  DateTime? startAt;
  DateTime? endAt;

  EventSessionDraft({
    this.startAt,
    this.endAt,
  });
}

enum EventMediaUploadState { idle, validating, uploading, done, failed }

class EventDraftMediaItem {
  final String id;
  final String type; // image, video, file
  final AssetEntity? asset;
  final File? file;
  final Uint8List? bytes;
  final Uint8List? thumbBytes;
  final String? name;
  final int? sizeBytes;
  final String? ext;
  final String? contentType;

  EventMediaUploadState uploadState;
  double uploadProgress;

  EventDraftMediaItem({
    required this.id,
    required this.type,
    this.asset,
    this.file,
    this.bytes,
    this.thumbBytes,
    this.name,
    this.sizeBytes,
    this.ext,
    this.contentType,
    this.uploadState = EventMediaUploadState.idle,
    this.uploadProgress = 0.0,
  });

  bool get isImage => type == "image";
  bool get isVideo => type == "video";
  bool get isFile => type == "file";
}

class CreateEventDraft {
  final TextEditingController titleCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController customCategoryCtrl = TextEditingController();
  final TextEditingController tagCtrl = TextEditingController();
  final TextEditingController locationCtrl = TextEditingController();
  final TextEditingController virtualLinkCtrl = TextEditingController();
  final TextEditingController meetupInstructionsCtrl = TextEditingController();
  String? meetupInstructionsValue;
  final TextEditingController maxPeopleCtrl =
      TextEditingController(text: "50");

  EventHostType hostType = EventHostType.user;
  String? hostId;

  EventVenueType venueType = EventVenueType.inPerson;
  EventPrivacy privacy = EventPrivacy.public;
  EventAccess access = EventAccess.everyone;

  bool requireRegistration = true;
  bool multiSession = false;

  String selectedTheme = "emerald_night";
  String selectedCategory = "network";

  int coverColorValue = 0xFF14B8A6;

  AssetEntity? coverAsset;
  String? selectedPresetCoverAsset = "assets/event_covers/default_event_cover.png";
  String? selectedGradientCoverId;

  String? customCategoryValue;

  final List<EventDraftMediaItem> mediaItems = [];
  final List<String> tags = [];
  final List<EventSessionDraft> sessions = [EventSessionDraft()];

  bool get hasCoverAsset => coverAsset != null;
  bool get hasPresetCover => selectedPresetCoverAsset != null;
  bool get hasGradientCover => selectedGradientCoverId != null;
  bool get hasAnyMedia => mediaItems.isNotEmpty;
  bool get hasCustomCategory =>
      (customCategoryValue ?? '').trim().isNotEmpty;

  String get resolvedCategory {
    if (selectedCategory == "custom") {
      return (customCategoryValue ?? '').trim();
    }
    return selectedCategory;
  }

  void clearCoverSelection() {
    coverAsset = null;
    selectedPresetCoverAsset = null;
    selectedGradientCoverId = null;
  }

  void addSession() {
    sessions.add(EventSessionDraft());
  }

  void removeSession(int index) {
    if (sessions.length <= 1) return;
    sessions.removeAt(index);
  }

  void saveCustomCategory() {
    final raw = customCategoryCtrl.text.trim();
    if (raw.isEmpty) return;

    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return;

    selectedCategory = "custom";
    customCategoryValue = cleaned;
    customCategoryCtrl.clear();
  }

  void removeCustomCategory() {
    customCategoryValue = null;
  }

  void addTag() {
    final raw = tagCtrl.text.trim();
    if (raw.isEmpty) return;

    final cleaned = raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll('#', '');

    if (cleaned.isEmpty) return;

    final exists = tags.any(
      (tag) => tag.toLowerCase() == cleaned.toLowerCase(),
    );

    if (exists) {
      tagCtrl.clear();
      return;
    }

    tags.add(cleaned);
    tagCtrl.clear();
  }

  void removeTag(String tag) {
    tags.remove(tag);
  }

  void reset() {
    titleCtrl.clear();
    descCtrl.clear();
    customCategoryCtrl.clear();
    tagCtrl.clear();
    locationCtrl.clear();
    virtualLinkCtrl.clear();
    maxPeopleCtrl.text = "50";

    hostType = EventHostType.user;
    hostId = null;

    venueType = EventVenueType.inPerson;
    privacy = EventPrivacy.public;
    access = EventAccess.everyone;
    requireRegistration = true;
    multiSession = false;
    selectedTheme = "emerald_night";
    selectedCategory = "network";
    coverColorValue = 0xFF14B8A6;

    meetupInstructionsCtrl.clear();
    meetupInstructionsValue = null;

    clearCoverSelection();
    selectedPresetCoverAsset = "assets/event_covers/default_event_cover.png";

    customCategoryValue = null;
    mediaItems.clear();
    tags.clear();

    sessions
      ..clear()
      ..add(EventSessionDraft());
  }

  void dispose() {
    titleCtrl.dispose();
    descCtrl.dispose();
    customCategoryCtrl.dispose();
    tagCtrl.dispose();
    locationCtrl.dispose();
    virtualLinkCtrl.dispose();
    maxPeopleCtrl.dispose();
    meetupInstructionsCtrl.dispose();
  }
}