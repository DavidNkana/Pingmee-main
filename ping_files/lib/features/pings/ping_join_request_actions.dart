import 'package:cloud_firestore/cloud_firestore.dart';

String _s(dynamic v) => (v ?? "").toString().trim();

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

Future<void> syncPingParticipantCount(String pingId) async {
  final db = FirebaseFirestore.instance;
  final pingRef = db.collection("pings").doc(pingId);
  final participantsRef = pingRef.collection("participants");

  final approvedSnap = await participantsRef
      .where("status", isEqualTo: "approved")
      .get();

  await pingRef.set({
    "participantCount": approvedSnap.docs.length,
    "updatedAt": FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

Future<bool> approvePingJoinRequest({
  required String pingId,
  required String memberUid,
}) async {
  final db = FirebaseFirestore.instance;
  final pingRef = db.collection("pings").doc(pingId);
  final partRef = pingRef.collection("participants").doc(memberUid);
  final userRef = db.collection("users").doc(memberUid);

  bool changed = false;

  await db.runTransaction((tx) async {
    final partSnap = await tx.get(partRef);
    if (!partSnap.exists) return;

    final partData = partSnap.data() ?? <String, dynamic>{};
    final status = _s(partData["status"]).toLowerCase();
    if (status != "pending") return;

    final pingSnap = await tx.get(pingRef);
    final pingData = pingSnap.data() ?? <String, dynamic>{};

    final maxMembers = _i(pingData["maxMembers"]);
    final participantCount = _i(pingData["participantCount"]);

    if (maxMembers > 0 && participantCount >= maxMembers) {
      throw Exception("ping-full-on-approve");
    }

    final joinedAtValue =
        partData["joinedAt"] ?? partData["requestedAt"] ?? FieldValue.serverTimestamp();

    tx.set(partRef, {
      "status": "approved",
      "approvedAt": FieldValue.serverTimestamp(),
      "joinedAt": joinedAtValue,
      "updatedAt": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    tx.set(userRef, {
      "activePingId": pingId,
      "activePingStatus": "approved",
      "activePingJoinedAt": joinedAtValue,
    }, SetOptions(merge: true));

    tx.set(pingRef, {
      "participantCount": FieldValue.increment(1),
      "updatedAt": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    changed = true;
  });

  if (changed) {
    await syncPingParticipantCount(pingId);
  }

  return changed;
}

Future<bool> denyPingJoinRequest({
  required String pingId,
  required String memberUid,
}) async {
  final db = FirebaseFirestore.instance;
  final pingRef = db.collection("pings").doc(pingId);
  final partRef = pingRef.collection("participants").doc(memberUid);
  final userRef = db.collection("users").doc(memberUid);

  bool changed = false;

  await db.runTransaction((tx) async {
    final snap = await tx.get(partRef);
    if (!snap.exists) return;

    final data = snap.data() ?? <String, dynamic>{};
    final status = _s(data["status"]).toLowerCase();
    if (status != "pending") return;

    tx.delete(partRef);

    tx.set(userRef, {
      "activePingId": FieldValue.delete(),
      "activePingStatus": FieldValue.delete(),
      "activePingJoinedAt": FieldValue.delete(),
    }, SetOptions(merge: true));

    changed = true;
  });

  return changed;
}