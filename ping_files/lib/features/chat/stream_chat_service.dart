import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

class PingmeeStreamChatService {
  PingmeeStreamChatService._();

  static final PingmeeStreamChatService instance =
      PingmeeStreamChatService._();

  static const String _region = 'us-central1';
  final Map<String, Channel> _directChannelByOtherUid = {};

  StreamChatClient? _client;
  String? _connectedUid;
  Future<StreamChatClient>? _connectFuture;

  String _directCacheKey({
    required String currentUid,
    required String otherUid,
  }) {
    final pair = [currentUid, otherUid]..sort();
    return 'dm_${pair[0]}_${pair[1]}';
  }

  Channel? getCachedDirectChannel(String otherUid) {
    final currentUid = _currentFirebaseUid;

    if (currentUid == null || currentUid.isEmpty) return null;

    final key = _directCacheKey(
      currentUid: currentUid,
      otherUid: otherUid,
    );

    final cached = _directChannelByOtherUid[key];

    if (cached == null) return null;

    final isValid = _channelHasMembers(
      channel: cached,
      currentUid: currentUid,
      otherUid: otherUid,
    );

    if (!isValid) {
      _directChannelByOtherUid.remove(key);
      return null;
    }

    return cached;
  }

  void cacheDirectChannel({
    required String otherUid,
    required Channel channel,
  }) {
    final currentUid = _currentFirebaseUid;

    if (currentUid == null || currentUid.isEmpty) return;
    if (otherUid.trim().isEmpty) return;

    final isValid = _channelHasMembers(
      channel: channel,
      currentUid: currentUid,
      otherUid: otherUid,
    );

    if (!isValid) return;

    final key = _directCacheKey(
      currentUid: currentUid,
      otherUid: otherUid,
    );

    _directChannelByOtherUid[key] = channel;
  }

  Future<Channel> openCachedOrCreateDirectChat(String otherUid) async {
    final cached = getCachedDirectChannel(otherUid);

    if (cached != null) {
      return cached;
    }

    final channel = await openDirectChat(otherUid);

    cacheDirectChannel(
      otherUid: otherUid,
      channel: channel,
    );

    return channel;
  }

  StreamChatClient get client {
    final value = _client;
    if (value == null) {
      throw StateError('Stream Chat client has not been initialized yet.');
    }
    return value;
  }

  bool _isRetryableFunctionsError(FirebaseFunctionsException error) {
    return error.code == 'unavailable' ||
        error.code == 'deadline-exceeded' ||
        error.code == 'internal';
  }

  Future<Map<String, dynamic>> _callGetStreamTokenWithRetry() async {
    final callable = _functions.httpsCallable('getStreamUserToken');

    FirebaseFunctionsException? lastFunctionsError;
    Object? lastError;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await callable.call<Map<String, dynamic>>({});
        return Map<String, dynamic>.from(result.data);
      } on FirebaseFunctionsException catch (error) {
        lastFunctionsError = error;

        if (!_isRetryableFunctionsError(error) || attempt == 2) {
          break;
        }

        await Future.delayed(
          Duration(milliseconds: 450 * (attempt + 1)),
        );
      } catch (error) {
        lastError = error;

        if (attempt == 2) {
          break;
        }

        await Future.delayed(
          Duration(milliseconds: 450 * (attempt + 1)),
        );
      }
    }

    if (lastFunctionsError != null) {
      throw StateError(
        'Could not connect chat: [${lastFunctionsError.code}] '
        '${lastFunctionsError.message ?? 'Firebase Function unavailable'}',
      );
    }

    throw StateError(
      'Could not connect chat: ${lastError ?? 'Unknown error'}',
    );
  }

  bool get isConnected {
    final client = _client;
    if (client == null) return false;

    return client.state.currentUser?.id != null;
  }

  String? get _currentFirebaseUid {
    return fb.FirebaseAuth.instance.currentUser?.uid;
  }

  bool _channelHasMembers({
    required Channel channel,
    required String currentUid,
    required String otherUid,
  }) {
    final members = channel.state?.members ?? const <Member>[];

    final memberIds = members
        .map((member) => member.userId ?? member.user?.id)
        .whereType<String>()
        .toSet();

    return memberIds.contains(currentUid) && memberIds.contains(otherUid);
  }

  bool _isRetryableStreamOpenError(Object error) {
    final raw = error.toString().toLowerCase();

    return raw.contains('timeout') ||
        raw.contains('took longer') ||
        raw.contains('connection') ||
        raw.contains('aborted') ||
        raw.contains('network') ||
        raw.contains('socket') ||
        raw.contains('unavailable');
  }

  Future<void> _watchChannelWithRetry(Channel channel) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await channel.watch();
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;

        if (!_isRetryableStreamOpenError(error) || attempt == 1) {
          rethrow;
        }

        await Future.delayed(
          Duration(milliseconds: 700 * (attempt + 1)),
        );
      }
    }

    Error.throwWithStackTrace(
      lastError ?? StateError('Could not open chat.'),
      lastStack ?? StackTrace.current,
    );
  }

  FirebaseFunctions get _functions {
    return FirebaseFunctions.instanceFor(region: _region);
  }

  Future<StreamChatClient> connectCurrentUser() {
    final existingFuture = _connectFuture;
    if (existingFuture != null) {
      return existingFuture;
    }

    final future = _connectCurrentUserInternal();

    _connectFuture = future.whenComplete(() {
      _connectFuture = null;
    });

    return _connectFuture!;
  } 

  Future<StreamChatClient> _connectCurrentUserInternal() async {
    final firebaseUser = fb.FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      throw StateError('No Firebase user is signed in.');
    }

    final existingClient = _client;
    final existingStreamUid = existingClient?.state.currentUser?.id;

    if (
      existingClient != null &&
      existingStreamUid == firebaseUser.uid &&
      _connectedUid == firebaseUser.uid
    ) {
      return existingClient;
    }

    if (
      existingClient != null &&
      existingStreamUid != null &&
      existingStreamUid != firebaseUser.uid
    ) {
      _directChannelByOtherUid.clear();
      await existingClient.disconnectUser();
      _connectedUid = null;
    }

    final data = await _callGetStreamTokenWithRetry();

    final apiKey = (data['apiKey'] ?? '').toString();
    final token = (data['token'] ?? '').toString();
    final userId = (data['userId'] ?? firebaseUser.uid).toString();
    final name = (data['name'] ?? 'Pingmee user').toString();
    final image = (data['image'] ?? '').toString();

    if (apiKey.isEmpty || token.isEmpty || userId.isEmpty) {
      throw StateError('Invalid Stream token response.');
    }

    final nextClient = _client ?? StreamChatClient(
      apiKey,
      logLevel: kDebugMode ? Level.INFO : Level.WARNING,

      // The default 6s is too weak for some mobile networks.
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    );

    final currentStreamUid = nextClient.state.currentUser?.id;

    if (currentStreamUid == userId) {
      _client = nextClient;
      _connectedUid = userId;
      return nextClient;
    }

    if (currentStreamUid != null && currentStreamUid != userId) {
      await nextClient.disconnectUser();
    }

    try {
      await nextClient.connectUser(
        User(
          id: userId,
          name: name,
          image: image.isEmpty ? null : image,
        ),
        token,
      );
    } on StreamChatError catch (error, stack) {
      final message = error.message.toLowerCase();

      if (message.contains('connection already available')) {
        _client = nextClient;
        _connectedUid = userId;
        return nextClient;
      }

      debugPrint('🚨 📡 error connecting user : $userId');
      debugPrint(error.toString());
      debugPrintStack(stackTrace: stack);

      rethrow;
    }

    _client = nextClient;
    _connectedUid = userId;

    return nextClient;
  }

  Future<void> disconnect() async {
    final client = _client;

    try {
      await client?.disconnectUser();
    } catch (error, stack) {
      debugPrint('Stream disconnect failed: $error');
      debugPrintStack(stackTrace: stack);
    } finally {
      _connectedUid = null;
      _connectFuture = null;
      _directChannelByOtherUid.clear();
    }
  }

  Future<Channel> openDirectChat(String otherUid) async {
    final streamClient = await connectCurrentUser();

    final callable = _functions.httpsCallable('createDirectChat');
    final result = await callable.call<Map<String, dynamic>>({
      'otherUid': otherUid,
    });

    final data = Map<String, dynamic>.from(result.data);
    final channelId = (data['channelId'] ?? '').toString();

    if (channelId.isEmpty) {
      throw StateError('Missing direct chat channelId.');
    }

    final channel = streamClient.channel(
      'messaging',
      id: channelId,
    );

    await _watchChannelWithRetry(channel);
    return channel;
  }

  Future<Channel> openPingChat(String pingId) async {
    final streamClient = await connectCurrentUser();

    final callable = _functions.httpsCallable('ensurePingChatChannel');
    final result = await callable.call<Map<String, dynamic>>({
      'pingId': pingId,
    });

    final data = Map<String, dynamic>.from(result.data);
    final channelId = (data['channelId'] ?? '').toString();

    if (channelId.isEmpty) {
      throw StateError('Missing ping chat channelId.');
    }

    final channel = streamClient.channel(
      'messaging',
      id: channelId,
    );

    await channel.watch();
    return channel;
  }

  Future<void> removePingChatMember({
    required String pingId,
    String? memberUid,
  }) async {
    await connectCurrentUser();

    final callable = _functions.httpsCallable('removePingChatMember');

    await callable.call<Map<String, dynamic>>({
      'pingId': pingId,
      if (memberUid != null && memberUid.trim().isNotEmpty)
        'memberUid': memberUid.trim(),
    });
  }
}