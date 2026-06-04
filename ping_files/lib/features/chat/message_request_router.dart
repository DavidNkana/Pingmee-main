import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/features/chat/stream_chat_service.dart';

class PingmeeMessageRequestRouter {
  const PingmeeMessageRequestRouter._();

  static Future<bool> _isConnectedTo({
    required String myUid,
    required String otherUid,
  }) async {
    if (myUid == otherUid) return true;

    final db = firestore.FirebaseFirestore.instance;

    final friendDoc = await db
        .collection('users')
        .doc(myUid)
        .collection('friends')
        .doc(otherUid)
        .get();

    if (friendDoc.exists) return true;

    final myUserDoc = await db.collection('users').doc(myUid).get();
    final friendIds = List<String>.from(myUserDoc.data()?['friendIds'] ?? []);

    return friendIds.contains(otherUid);
  }

  static Future<void> _ensureRequestDocs({
    required String fromUid,
    required String toUid,
    required String channelCid,
  }) async {
    final db = firestore.FirebaseFirestore.instance;
    final now = firestore.FieldValue.serverTimestamp();

    final incomingRef = db
        .collection('users')
        .doc(toUid)
        .collection('message_requests_in')
        .doc(fromUid);

    final outgoingRef = db
        .collection('users')
        .doc(fromUid)
        .collection('message_requests_out')
        .doc(toUid);

    final payload = <String, dynamic>{
      'fromUid': fromUid,
      'toUid': toUid,
      'channelCid': channelCid,
      'status': 'pending',
      'messageCount': 0,
      'maxMessages': 3,
      'createdAt': now,
      'updatedAt': now,
    };

    final batch = db.batch();

    batch.set(incomingRef, payload, firestore.SetOptions(merge: true));
    batch.set(outgoingRef, payload, firestore.SetOptions(merge: true));

    await batch.commit();
  }

  static Future<Channel> openDirectChat({
    required String otherUid,
  }) async {
    final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

    if (myUid == null || myUid.isEmpty) {
      throw StateError('You must be logged in to message.');
    }

    if (otherUid.trim().isEmpty) {
      throw StateError('Missing user id.');
    }

    final db = firestore.FirebaseFirestore.instance;

    final targetSnap = await db.collection('users').doc(otherUid).get();
    final targetData = targetSnap.data() ?? {};

    final messagePrivacy = Map<String, dynamic>.from(
      targetData['messagePrivacy'] ?? {},
    );

    final requiresRequests =
        messagePrivacy['requireMessageRequests'] == true;

    final connected = await _isConnectedTo(
      myUid: myUid,
      otherUid: otherUid,
    );

    final cached =
        PingmeeStreamChatService.instance.getCachedDirectChannel(otherUid);

    final channel = cached ??
        await PingmeeStreamChatService.instance
            .openCachedOrCreateDirectChat(otherUid)
            .timeout(const Duration(seconds: 12));

    final channelCid = (channel.cid ?? channel.id ?? '').toString();

    if (!connected && requiresRequests) {
      await _ensureRequestDocs(
        fromUid: myUid,
        toUid: otherUid,
        channelCid: channelCid,
      );
    }

    return channel;
  }
}