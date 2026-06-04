import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

class PingmeeStreamVideoService {
  PingmeeStreamVideoService._();

  static final PingmeeStreamVideoService instance =
      PingmeeStreamVideoService._();

  static const String _region = 'us-central1';

  String? _connectedUid;
  Future<StreamVideo>? _connectFuture;

  FirebaseFunctions get _functions {
    return FirebaseFunctions.instanceFor(region: _region);
  }

  Future<StreamVideo> connectCurrentUser() {
    final existing = _connectFuture;
    if (existing != null) return existing;

    final future = _connectCurrentUserInternal();

    _connectFuture = future.whenComplete(() {
      _connectFuture = null;
    });

    return _connectFuture!;
  }

  Future<StreamVideo> _connectCurrentUserInternal() async {
    final firebaseUser = fb.FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      throw StateError('No Firebase user is signed in.');
    }

    if (_connectedUid == firebaseUser.uid) {
      return StreamVideo.instance;
    }

    final callable = _functions.httpsCallable('getStreamUserToken');
    final result = await callable.call<Map<String, dynamic>>({});

    final data = Map<String, dynamic>.from(result.data);

    final apiKey = (data['apiKey'] ?? '').toString();
    final token = (data['token'] ?? '').toString();
    final userId = (data['userId'] ?? firebaseUser.uid).toString();
    final name = (data['name'] ?? 'Pingmee user').toString();

    if (apiKey.isEmpty || token.isEmpty || userId.isEmpty) {
      throw StateError('Invalid Stream Video token response.');
    }

    StreamVideo(
      apiKey,
      user: User.regular(
        userId: userId,
        name: name,
      ),
      userToken: token,
      failIfSingletonExists: false,
    );

    _connectedUid = userId;

    return StreamVideo.instance;
  }

  String _dmCallId({
    required String currentUid,
    required String otherUid,
  }) {
    final pair = [currentUid, otherUid]..sort();
    return 'dm_${pair[0]}_${pair[1]}';
  }

  String _pingHuddleCallId({
    required String pingId,
  }) {
    final cleanPingId = pingId.trim();

    if (cleanPingId.isEmpty) {
      throw StateError('Missing ping id.');
    }

    return 'ping_huddle_$cleanPingId';
  }

  Future<Call> startDirectCall({
    required String otherUid,
    required bool video,
  }) async {
    final firebaseUser = fb.FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      throw StateError('No Firebase user is signed in.');
    }

    if (otherUid.trim().isEmpty) {
      throw StateError('Missing call recipient.');
    }

    debugPrint('📞 Starting Pingmee ${video ? "video" : "audio"} call to $otherUid');

    final client = await connectCurrentUser();

    final callId = _dmCallId(
      currentUid: firebaseUser.uid,
      otherUid: otherUid,
    );

    debugPrint('📞 Stream callId=$callId');

    final call = client.makeCall(
      callType: StreamCallType.defaultType(),
      id: callId,
    );

    debugPrint('📞 getOrCreate call...');

    await call.getOrCreate(
      memberIds: [
        firebaseUser.uid,
        otherUid,
      ],
      ringing: false,
      video: video,
      custom: {
        'source': 'pingmee_dm',
        'mode': video ? 'video' : 'audio',
      },
    );

    debugPrint('📞 joining call...');

    await call.join();

    debugPrint('✅ joined call');

    return call;
  }

  Future<Call> startPingHuddle({
    required String pingId,
    required String title,
    required List<String> memberIds,
  }) async {
    final firebaseUser = fb.FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      throw StateError('No Firebase user is signed in.');
    }

    final cleanPingId = pingId.trim();

    if (cleanPingId.isEmpty) {
      throw StateError('Missing ping id.');
    }

    final cleanTitle = title.trim().isEmpty ? 'Ping Huddle' : title.trim();

    final cleanMemberIds = <String>{
      firebaseUser.uid,
      ...memberIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty),
    }.toList()
      ..sort();

    debugPrint(
      '📞 Starting Ping Huddle pingId=$cleanPingId members=${cleanMemberIds.length}',
    );

    final client = await connectCurrentUser();

    final callId = _pingHuddleCallId(pingId: cleanPingId);

    debugPrint('📞 Stream ping huddle callId=$callId');

    final call = client.makeCall(
      callType: StreamCallType.defaultType(),
      id: callId,
    );

    await call.getOrCreate(
      memberIds: cleanMemberIds,
      ringing: false,
      video: true,
      custom: {
        'source': 'pingmee_ping_huddle',
        'mode': 'video',
        'pingId': cleanPingId,
        'title': cleanTitle,
      },
    );

    await call.join();

    debugPrint('✅ joined Ping Huddle');

    return call;
  }
}