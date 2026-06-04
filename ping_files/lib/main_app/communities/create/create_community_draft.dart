import 'dart:io';

import 'package:flutter/material.dart';

class CreateCommunityDraft {
  String communityName = "";
  String headline = "";
  String shortBio = "";

  File? profilePhotoFile;
  File? coverPhotoFile;

  String? profilePhotoUrl;
  String? coverPhotoUrl;

  Color themeColor = const Color(0xFF22C55E);

  String website = '';
  String email = '';
  String phone = '';

  double discoveryRadiusKm = 10;
  String communityCategory = '';

  String hoursMode = 'none'; // none | always_open | selected
  Map<String, List<Map<String, String>>> selectedHours = {};
  final Map<String, CommunitySocialDraft> socials = {};

  final Set<String> invitedFriendIds = <String>{};

  void dispose() {}

  bool get hasAnyContactPath {
    final hasDirect =
        website.trim().isNotEmpty ||
        email.trim().isNotEmpty ||
        phone.trim().isNotEmpty;

    final hasSocial = socials.values.any((item) => item.hasValue);
    return hasDirect || hasSocial;
  }
}

class CommunitySocialDraft {
  CommunitySocialDraft({
    required this.platform,
    this.handle = '',
    this.url = '',
    this.visible = true,
  });

  final String platform;
  String handle;
  String url;
  bool visible;

  bool get hasValue => handle.trim().isNotEmpty || url.trim().isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      "platform": platform,
      "handle": handle,
      "url": url,
      "visible": visible,
    };
  }

  factory CommunitySocialDraft.fromMap(Map<String, dynamic> map) {
    return CommunitySocialDraft(
      platform: (map["platform"] ?? "").toString(),
      handle: (map["handle"] ?? "").toString(),
      url: (map["url"] ?? "").toString(),
      visible: (map["visible"] ?? true) == true,
    );
  }
}