import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

String _s(dynamic v) => (v ?? "").toString().trim();

Future<void> sendPingJoinRequestNotification({
  required String creatorUid,
  required String requesterUid,
  required String pingId,
}) async {
  if (creatorUid.trim().isEmpty || requesterUid.trim().isEmpty) return;
  if (creatorUid == requesterUid) return;

  final db = FirebaseFirestore.instance;

  try {
    final requesterSnap = await db.collection("users").doc(requesterUid).get();
    final requesterData = requesterSnap.data() ?? <String, dynamic>{};

    final pingSnap = await db.collection("pings").doc(pingId).get();
    final pingData = pingSnap.data() ?? <String, dynamic>{};

    final requesterName = _s(requesterData["fullName"]);
    final requesterPhotoUrl = _s(requesterData["photoUrl"]);
    final pingTitle = _s(pingData["title"]);

    await db
        .collection("users")
        .doc(creatorUid)
        .collection("notifications")
        .add({
      "type": "ping_join_request",
      "title": "New join request",
      "body": requesterName.isNotEmpty
          ? "$requesterName requested to join your ping."
          : "Someone requested to join your ping.",
      "senderUid": requesterUid,
      "senderName": requesterName,
      "senderPhotoUrl": requesterPhotoUrl,
      "pingId": pingId,
      "pingTitle": pingTitle,
      "requestUid": requesterUid,
      "actionState": "pending",
      "read": false,
      "createdAt": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("❌ ping join request notification failed: $e");
  }
}

Future<void> sendPingJoinDecisionNotification({
  required String recipientUid,
  required String actorUid,
  required String pingId,
  required bool approved,
}) async {
  if (recipientUid.trim().isEmpty || actorUid.trim().isEmpty) return;
  if (recipientUid == actorUid) return;

  final db = FirebaseFirestore.instance;

  try {
    final actorSnap = await db.collection("users").doc(actorUid).get();
    final actorData = actorSnap.data() ?? <String, dynamic>{};

    final pingSnap = await db.collection("pings").doc(pingId).get();
    final pingData = pingSnap.data() ?? <String, dynamic>{};

    final actorName = _s(actorData["fullName"]);
    final actorPhotoUrl = _s(actorData["photoUrl"]);
    final pingTitle = _s(pingData["title"]);

    final type = approved
        ? "ping_request_approved"
        : "ping_request_denied";

    final title = approved
        ? "Join request approved"
        : "Join request denied";

    final body = approved
        ? (actorName.isNotEmpty
            ? (pingTitle.isNotEmpty
                ? "$actorName approved your request to join \"$pingTitle\"."
                : "$actorName approved your join request.")
            : (pingTitle.isNotEmpty
                ? "Your request to join \"$pingTitle\" was approved."
                : "Your join request was approved."))
        : (actorName.isNotEmpty
            ? (pingTitle.isNotEmpty
                ? "$actorName denied your request to join \"$pingTitle\". You can try again by sending a new request."
                : "$actorName denied your join request. You can try again by sending a new request.")
            : (pingTitle.isNotEmpty
                ? "Your request to join \"$pingTitle\" was denied. You can try again by sending a new request."
                : "Your join request was denied. You can try again by sending a new request."));

    await db
        .collection("users")
        .doc(recipientUid)
        .collection("notifications")
        .add({
      "type": type,
      "title": title,
      "body": body,
      "senderUid": actorUid,
      "senderName": actorName,
      "senderPhotoUrl": actorPhotoUrl,
      "pingId": pingId,
      "pingTitle": pingTitle,
      "decision": approved ? "approved" : "denied",
      "read": false,
      "createdAt": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("❌ ping join decision notification failed: $e");
  }
}

Future<void> sendPingMemberRemovedNotification({
  required String recipientUid,
  required String actorUid,
  required String pingId,
}) async {
  if (recipientUid.trim().isEmpty || actorUid.trim().isEmpty) return;
  if (recipientUid == actorUid) return;

  final db = FirebaseFirestore.instance;

  try {
    final actorSnap = await db.collection("users").doc(actorUid).get();
    final actorData = actorSnap.data() ?? <String, dynamic>{};

    final pingSnap = await db.collection("pings").doc(pingId).get();
    final pingData = pingSnap.data() ?? <String, dynamic>{};

    final actorName = _s(actorData["fullName"]);
    final actorPhotoUrl = _s(actorData["photoUrl"]);
    final pingTitle = _s(pingData["title"]);

    await db
        .collection("users")
        .doc(recipientUid)
        .collection("notifications")
        .add({
      "type": "ping_member_removed",
      "title": "Removed from ping",
      "body": actorName.isNotEmpty
          ? (pingTitle.isNotEmpty
              ? '$actorName removed you from "$pingTitle".'
              : "$actorName removed you from their ping.")
          : (pingTitle.isNotEmpty
              ? 'You were removed from "$pingTitle".'
              : "You were removed from a ping."),
      "senderUid": actorUid,
      "senderName": actorName,
      "senderPhotoUrl": actorPhotoUrl,
      "pingId": pingId,
      "pingTitle": pingTitle,
      "read": false,
      "createdAt": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("❌ ping member removed notification failed: $e");
  }
}

Future<void> sendPingMemberLeftNotification({
  required String creatorUid,
  required String memberUid,
  required String pingId,
}) async {
  if (creatorUid.trim().isEmpty || memberUid.trim().isEmpty) return;
  if (creatorUid == memberUid) return;

  final db = FirebaseFirestore.instance;

  try {
    final memberSnap = await db.collection("users").doc(memberUid).get();
    final memberData = memberSnap.data() ?? <String, dynamic>{};

    final pingSnap = await db.collection("pings").doc(pingId).get();
    final pingData = pingSnap.data() ?? <String, dynamic>{};

    final memberName = _s(memberData["fullName"]);
    final memberPhotoUrl = _s(memberData["photoUrl"]);
    final pingTitle = _s(pingData["title"]);

    await db
        .collection("users")
        .doc(creatorUid)
        .collection("notifications")
        .add({
      "type": "ping_member_left",
      "title": "Member left",
      "body": memberName.isNotEmpty
          ? (pingTitle.isNotEmpty
              ? '$memberName left "$pingTitle".'
              : "$memberName left your ping.")
          : (pingTitle.isNotEmpty
              ? 'Someone left "$pingTitle".'
              : "Someone left your ping."),
      "senderUid": memberUid,
      "senderName": memberName,
      "senderPhotoUrl": memberPhotoUrl,
      "pingId": pingId,
      "pingTitle": pingTitle,
      "read": false,
      "createdAt": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("❌ ping member left notification failed: $e");
  }
}