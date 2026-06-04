import 'package:cloud_firestore/cloud_firestore.dart';

class PingVisibilityContext {
  final String? viewerUid;
  final bool viewerVerified;
  final Set<String> viewerFriendIds;

  const PingVisibilityContext({
    required this.viewerUid,
    required this.viewerVerified,
    required this.viewerFriendIds,
  });

  bool isOwner(String creatorId) {
    return viewerUid != null && viewerUid == creatorId;
  }

  bool isFriendWith(String creatorId) {
    return viewerFriendIds.contains(creatorId);
  }
}

List<QueryDocumentSnapshot<Map<String, dynamic>>> filterVisiblePingDocs({
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  required PingVisibilityContext context,
  bool activeOnly = false,
  DateTime? now,
}) {
  return docs.where((doc) {
    final data = doc.data();

    if (activeOnly) {
      return PingVisibility.canViewerSeeActivePing(
        ping: data,
        context: context,
        now: now,
      );
    }

    return PingVisibility.canViewerSeePing(
      ping: data,
      context: context,
    );
  }).toList();
}

class PingVisibility {
  static const String privacyPublic = "public";
  static const String privacyVerified = "verified";
  static const String privacyFriends = "friends";

  static const Set<String> allowedPrivacyValues = {
    privacyPublic,
    privacyVerified,
    privacyFriends,
  };

  static String normalizePrivacy(dynamic raw) {
    final value = (raw ?? privacyPublic).toString().trim().toLowerCase();
    if (allowedPrivacyValues.contains(value)) return value;
    return privacyPublic;
  }

  static bool canViewerSeePing({
    required Map<String, dynamic> ping,
    required PingVisibilityContext context,
  }) {
    final creatorId = (ping["creatorId"] ?? "").toString();
    if (creatorId.isEmpty) return false;

    if (context.isOwner(creatorId)) return true;

    final privacy = normalizePrivacy(ping["privacy"]);

    switch (privacy) {
      case privacyPublic:
        return true;

      case privacyVerified:
        return context.viewerVerified;

      case privacyFriends:
        return context.isFriendWith(creatorId);

      default:
        return false;
    }
  }

  static bool canViewerSeePingDoc({
    required DocumentSnapshot<Map<String, dynamic>> doc,
    required PingVisibilityContext context,
  }) {
    final data = doc.data();
    if (data == null) return false;
    return canViewerSeePing(ping: data, context: context);
  }

  static bool isPingActive(Map<String, dynamic> ping, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final endsAt = ping["endsAt"];

    if (endsAt is Timestamp) {
      return endsAt.toDate().isAfter(current);
    }

    if (endsAt is DateTime) {
      return endsAt.isAfter(current);
    }

    return true;
  }

  static bool canViewerSeeActivePing({
    required Map<String, dynamic> ping,
    required PingVisibilityContext context,
    DateTime? now,
  }) {
    return isPingActive(ping, now: now) &&
        canViewerSeePing(ping: ping, context: context);
  }

  static Map<String, dynamic> buildPingAudienceFields({
    required String privacy,
  }) {
    final normalized = normalizePrivacy(privacy);

    return {
      "privacy": normalized,
      "audience": {
        "scope": normalized,
      },
    };
  }
}