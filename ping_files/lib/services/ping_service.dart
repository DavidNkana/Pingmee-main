import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geoflutterfire_plus/geoflutterfire_plus.dart';

class PingService {
  static final _db = FirebaseFirestore.instance;

  static Future<String> createPing({
    required String title,
    required String description,
    required GeoPoint geopoint,
    required List<String> tags,
    required bool showExactLocation,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("Not logged in");

    final point = GeoFirePoint(geopoint); // ✅ correct: needs GeoPoint arg

    final ref = await _db.collection("pings").add({
      "type": "ping",
      "title": title.trim().isEmpty ? "Ping" : title.trim(),
      "description": description.trim(),
      "tags": tags,
      "creatorId": uid,
      "createdAt": FieldValue.serverTimestamp(),
      "participantCount": 1,

      // location: { geopoint, geohash }
      "location": point.data,

      // privacy
      "showExactLocation": showExactLocation,
    });

    // creator auto-joins
    await ref.collection("participants").doc(uid).set({
      "uid": uid,
      "joinedAt": FieldValue.serverTimestamp(),
    });

    return ref.id;
  }
}
