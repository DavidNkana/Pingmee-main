import 'dart:ui';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/main_app/main_app_shell.dart';
import 'package:ping_files/main_app/tabs/profile/profile_edit_screen.dart';
import 'package:ping_files/main_app/tabs/profile/profile_owner_main_menu_screen.dart';
import '../feed/pingmee_feed_service.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/app_start_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:ping_files/services/profile_photo_flow.dart';
import 'package:ping_files/features/pings/create_ping_sheet.dart';
import 'package:ping_files/features/pings/ping_visibility.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;
import 'package:ping_files/widgets/app_pull_to_refresh.dart';
import 'package:ping_files/features/pings/create_ping_draft.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';
import 'package:ping_files/features/chat/pingmee_chat_routes.dart';


// OPTIONAL (for real city names):
// add dependency: geocoding: ^3.0.0 (or latest)
// import 'package:geocoding/geocoding.dart';

// Optional: your edit flow entry point (change to your real edit route)
import 'package:ping_files/ProfileCreation/identity_basic_screen.dart';

// ============================================================================
// PREMIUM STATE MANAGEMENT LAYER
// ============================================================================

String formatCompactCount(int value) {
  final abs = value.abs();

  String stripZero(String s) {
    return s.endsWith(".0") ? s.substring(0, s.length - 2) : s;
  }

  if (abs < 1000) return value.toString();

  if (abs < 1000000) {
    final k = value / 1000;
    final text = abs >= 10000
        ? k.toStringAsFixed(0)
        : stripZero(k.toStringAsFixed(1));
    return "${text}k";
  }

  if (abs < 1000000000) {
    final m = value / 1000000;
    final text = abs >= 10000000
        ? m.toStringAsFixed(0)
        : stripZero(m.toStringAsFixed(1));
    return "${text}m";
  }

  final b = value / 1000000000;
  final text = abs >= 10000000000
      ? b.toStringAsFixed(0)
      : stripZero(b.toStringAsFixed(1));
  return "${text}b";
}

/// Cache entry for mutual friends data with TTL
class _CachedMutualFriends {
  final Set<String> mutualIds;
  final DateTime cachedAt;

  _CachedMutualFriends({required this.mutualIds, required this.cachedAt});

  bool get isExpired => DateTime.now().difference(cachedAt).inSeconds > 30;
}

/// Friend button state enum for clarity
enum FriendButtonState {
  none, // not friends, no request
  outgoing, // friend request sent
  incoming, // friend request received
  friends, // already friends
  loading, // network call in progress
  error, // error state
}

/// Relationship state from Firestore
class RelationshipState {
  final bool hasIncoming;
  final bool hasOutgoing;
  final bool isFriend;

  const RelationshipState({
    required this.hasIncoming,
    required this.hasOutgoing,
    required this.isFriend,
  });

  FriendButtonState get derived {
    if (isFriend) return FriendButtonState.friends;
    if (hasIncoming) return FriendButtonState.incoming;
    if (hasOutgoing) return FriendButtonState.outgoing;
    return FriendButtonState.none;
  }
}

/// Manages friend state with optimistic updates and haptic feedback
class FriendStateManager {
  final String myUid;
  final String targetUid;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  FriendButtonState? _optimisticOverride;
  bool _isNetworkBusy = false;

  FriendStateManager({
    required this.myUid,
    required this.targetUid,
  });

  FriendButtonState get currentState =>
      _optimisticOverride ?? FriendButtonState.none;

  bool get isBusy => _isNetworkBusy;

  void setOptimisticState(FriendButtonState state) {
    _optimisticOverride = state;
    _playHapticFeedback(strength: HapticStrength.light);
  }

  void clearOptimisticState() {
    _optimisticOverride = null;
  }

  void setNetworkBusy(bool busy) {
    _isNetworkBusy = busy;
  }

  void _playHapticFeedback({
    HapticStrength strength = HapticStrength.medium,
  }) {
    try {
      switch (strength) {
        case HapticStrength.light:
          HapticFeedback.lightImpact();
          break;
        case HapticStrength.medium:
          HapticFeedback.mediumImpact();
          break;
        case HapticStrength.heavy:
          HapticFeedback.heavyImpact();
          break;
      }
    } catch (_) {}
  }

  Future<bool> sendFriendRequest(
    String senderName,
    String senderUsername,
  ) async {
    if (_isNetworkBusy) return false;

    setNetworkBusy(true);
    setOptimisticState(FriendButtonState.outgoing);

    try {
      final inRef = _db
          .collection("users")
          .doc(targetUid)
          .collection("friend_requests_in")
          .doc(myUid);

      final outRef = _db
          .collection("users")
          .doc(myUid)
          .collection("friend_requests_out")
          .doc(targetUid);

      final notifRef = _db
          .collection("users")
          .doc(targetUid)
          .collection("notifications")
          .doc();

      final senderDocRef = _db.collection("users").doc(myUid);

      await _db.runTransaction((tx) async {
        final existingFriendA = await tx.get(
          _db.collection("users").doc(myUid).collection("friends").doc(targetUid),
        );
        final existingFriendB = await tx.get(
          _db.collection("users").doc(targetUid).collection("friends").doc(myUid),
        );
        final existingIn = await tx.get(inRef);
        final existingOut = await tx.get(outRef);
        final senderDoc = await tx.get(senderDocRef);

        if (existingFriendA.exists || existingFriendB.exists) return;
        if (existingIn.exists || existingOut.exists) return;

        final senderData = senderDoc.data() ?? {};
        final senderPhotoUrl = (senderData["photoUrl"] ?? "").toString();
        final now = FieldValue.serverTimestamp();

        tx.set(inRef, {
          "fromUid": myUid,
          "toUid": targetUid,
          "status": "pending",
          "createdAt": now,
        });

        tx.set(outRef, {
          "fromUid": myUid,
          "toUid": targetUid,
          "status": "pending",
          "createdAt": now,
        });

        tx.set(notifRef, {
          "type": "connection_request",
          "senderUid": myUid,
          "senderName": senderName,
          "senderUsername": senderUsername,
          "senderPhotoUrl": senderPhotoUrl,
          "title": "Connection request",
          "body": "$senderName sent you a connection request.",
          "read": false,
          "createdAt": now,
        });
      });

      _playHapticFeedback(strength: HapticStrength.heavy);
      return true;
    } catch (_) {
      clearOptimisticState();
      return false;
    } finally {
      setNetworkBusy(false);
    }
  }

  Future<bool> acceptFriendRequest(
    String myFullName,
    String myUsername,
    String myPhotoUrl,
  ) async {
    if (_isNetworkBusy) return false;

    setNetworkBusy(true);
    setOptimisticState(FriendButtonState.friends);

    try {
      final myUserRef = _db.collection("users").doc(myUid);
      final otherUserRef = _db.collection("users").doc(targetUid);

      final myIncomingRef =
          myUserRef.collection("friend_requests_in").doc(targetUid);
      final theirOutgoingRef =
          otherUserRef.collection("friend_requests_out").doc(myUid);

      final myFriendRef = myUserRef.collection("friends").doc(targetUid);
      final theirFriendRef = otherUserRef.collection("friends").doc(myUid);

      final acceptNotifRef = otherUserRef.collection("notifications").doc();

      await _db.runTransaction((tx) async {
        final incomingSnap = await tx.get(myIncomingRef);
        if (!incomingSnap.exists) return;

        final myUserSnap = await tx.get(myUserRef);

        final myIds = List<String>.from(myUserSnap.data()?["friendIds"] ?? []);
        if (!myIds.contains(targetUid)) myIds.add(targetUid);

        final now = FieldValue.serverTimestamp();

        tx.delete(myIncomingRef);
        tx.delete(theirOutgoingRef);

        tx.set(myFriendRef, {
          "friendId": targetUid,
          "createdAt": now,
        });

        tx.set(theirFriendRef, {
          "friendId": myUid,
          "createdAt": now,
        });

        tx.set(
          myUserRef,
          {
            "friendIds": myIds,
            "friendsCount": myIds.length,
          },
          SetOptions(merge: true),
        );

        tx.set(acceptNotifRef, {
          "type": "connection_accept",
          "senderUid": myUid,
          "senderName": myFullName,
          "senderUsername": myUsername,
          "senderPhotoUrl": myPhotoUrl,
          "title": "Connection request accepted",
          "body": "$myFullName accepted your connection request.",
          "read": false,
          "createdAt": now,
        });
      });

      _playHapticFeedback(strength: HapticStrength.heavy);
      return true;
    } catch (e) {
      debugPrint("❌ acceptFriendRequest failed: $e");
      clearOptimisticState();
      return false;
    } finally {
      setNetworkBusy(false);
    }
  }

  Future<bool> declineFriendRequest() async {
    if (_isNetworkBusy) return false;

    setNetworkBusy(true);
    setOptimisticState(FriendButtonState.none);

    try {
      final myIncomingRef = _db
          .collection("users")
          .doc(myUid)
          .collection("friend_requests_in")
          .doc(targetUid);

      final theirOutgoingRef = _db
          .collection("users")
          .doc(targetUid)
          .collection("friend_requests_out")
          .doc(myUid);

      final batch = _db.batch();
      batch.delete(myIncomingRef);
      batch.delete(theirOutgoingRef);
      await batch.commit();

      _playHapticFeedback(strength: HapticStrength.medium);
      return true;
    } catch (_) {
      clearOptimisticState();
      return false;
    } finally {
      setNetworkBusy(false);
    }
  }

  Future<bool> cancelFriendRequest() async {
    if (_isNetworkBusy) return false;

    setNetworkBusy(true);
    setOptimisticState(FriendButtonState.none);

    try {
      final myOutgoingRef = _db
          .collection("users")
          .doc(myUid)
          .collection("friend_requests_out")
          .doc(targetUid);

      final theirIncomingRef = _db
          .collection("users")
          .doc(targetUid)
          .collection("friend_requests_in")
          .doc(myUid);

      final batch = _db.batch();
      batch.delete(myOutgoingRef);
      batch.delete(theirIncomingRef);
      await batch.commit();

      _playHapticFeedback(strength: HapticStrength.medium);
      return true;
    } catch (_) {
      clearOptimisticState();
      return false;
    } finally {
      setNetworkBusy(false);
    }
  }

  Future<bool> removeFriendConnection() async {
    if (_isNetworkBusy) return false;

    setNetworkBusy(true);
    setOptimisticState(FriendButtonState.none);

    try {
      final myUserRef = _db.collection("users").doc(myUid);
      final otherUserRef = _db.collection("users").doc(targetUid);

      final myFriendRef = myUserRef.collection("friends").doc(targetUid);
      final theirFriendRef = otherUserRef.collection("friends").doc(myUid);

      await _db.runTransaction((tx) async {
        final myUserSnap = await tx.get(myUserRef);
        final otherUserSnap = await tx.get(otherUserRef);

        final myIds = List<String>.from(myUserSnap.data()?["friendIds"] ?? []);
        final otherIds =
            List<String>.from(otherUserSnap.data()?["friendIds"] ?? []);

        myIds.remove(targetUid);
        otherIds.remove(myUid);

        tx.delete(myFriendRef);
        tx.delete(theirFriendRef);

        tx.set(
          myUserRef,
          {
            "friendIds": myIds,
            "friendsCount": myIds.length,
          },
          SetOptions(merge: true),
        );

        tx.set(
          otherUserRef,
          {
            "friendIds": otherIds,
            "friendsCount": otherIds.length,
          },
          SetOptions(merge: true),
        );
      });

      _playHapticFeedback(strength: HapticStrength.heavy);
      return true;
    } catch (_) {
      clearOptimisticState();
      return false;
    } finally {
      setNetworkBusy(false);
    }
  }
}

enum HapticStrength { light, medium, heavy }

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key, this.profileUid, this.onBack});
  final String? profileUid;
  /// Called when the back arrow in the cover image is tapped. The parent
  /// (typically MainAppShell) decides what to do — usually clear the
  /// foreign uid and switch to the feed tab. If null, the widget falls
  /// back to Navigator.maybePop() (which only works when the profile
  /// was opened as a route, not as a tab inside an IndexedStack).
  final VoidCallback? onBack;

  static const double navBarHeight = 78; // matches frosted bar

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  final CreatePingDraft _createPingDraft = CreatePingDraft();

  late final TabController _tabs = TabController(length: 4, vsync: this);
  late final ScrollController _scrollController = ScrollController();

  static const String _defaultCoverAsset = "assets/images/default_cover.png";
  late final String? _myUid = FirebaseAuth.instance.currentUser?.uid;
  String? _loggedProfileViewKey;

  String? _localNoteOverride;
  DateTime? _localNoteUpdatedAtOverride;

  String _cityLabel = "Near you"; // fallback
  final bool _presenceReady = false;
  bool _didLoadCityOnce = false;
  bool _refreshingProfile = false;
  /// Increments on every pull-to-refresh. Pass to tab children as a
  /// ValueKey so they rebuild and re-fetch their data. Also used to
  /// re-key the visibility/mutuals FutureBuilder so the future re-runs.
  int _profileRefreshTick = 0;

  final Map<String, Future<MutualFriendsData>> _mutualFriendsFutureCache = {};

  // ✅ NEW: Premium state management
  final Map<String, _CachedMutualFriends> _mutualFriendsCache = {};
  final Map<String, FriendStateManager> _friendStateManagers = {};
  late final AnimationController _buttonAnimController = AnimationController(
    duration: const Duration(milliseconds: 100),
    vsync: this,
  );
  

  // Heartbeat: refreshes `isOnline = true` + `lastSeen = now` every
  // 60 s while the widget is mounted and the app is in the
  // foreground. Without this, a user who opens the app, marks
  // themselves online, and then sits on the feed for 3 minutes would
  // appear offline (because `lastSeen` is now 3 min old and the read
  // side enforces a 2-min staleness window). The heartbeat is paused
  // when the app is backgrounded and cancelled in dispose.
  Timer? _presenceHeartbeat;
  bool _appResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Do not block or visually reload the profile.
    unawaited(_loadCityFromGeoOnce());

    _setOnline(true);

    _presenceHeartbeat = Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        // Only refresh while the app is in the foreground. The
        // lifecycle observer (resumed/paused) keeps `_appResumed`
        // up to date.
        if (_appResumed) {
          unawaited(_setOnline(true));
        }
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // NB: we deliberately do NOT call _setOnline(false) here.
    // `_setOnline(false)` was being called when a foreign ProfileTab
    // (pushed as a route to view someone else's profile) was popped,
    // which would mark the *current* user offline even though they
    // were still in the app, on a different tab. App-level
    // backgrounding is handled by didChangeAppLifecycleState(paused)
    // and the heartbeat staleness window in
    // `pingmeeIsUserOnlineFromUserData` (the read-side filter).
    _tabs.dispose();
    _scrollController.dispose();
    _createPingDraft.dispose();
    _buttonAnimController.dispose();
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (uid == null) return;
    if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      // Refresh the timestamp immediately on resume so the read
      // side does not show a stale offline state for up to 2
      // minutes after the user comes back.
      unawaited(_setOnline(true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _appResumed = false;
      // Mark offline on background so other users see us as
      // offline promptly. (The 2-min staleness filter on the read
      // side is the safety net for missed cases.)
      unawaited(_setOnline(false));
    }
  }

  String? _profileStreamKey;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _profileStream;

  final Map<String, Stream<QuerySnapshot<Map<String, dynamic>>>>
      _friendsStreamCache = {};

  Stream<DocumentSnapshot<Map<String, dynamic>>> _profileDocStreamFor(
    String profileUid,
  ) {
    if (_profileStreamKey != profileUid || _profileStream == null) {
      _profileStreamKey = profileUid;
      _profileStream = FirebaseFirestore.instance
          .collection("users")
          .doc(profileUid)
          .snapshots();
    }

    return _profileStream!;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _friendsStreamFor(
    String profileUid,
  ) {
    return _friendsStreamCache.putIfAbsent(
      profileUid,
      () => FirebaseFirestore.instance
          .collection("users")
          .doc(profileUid)
          .collection("friends")
          .snapshots(),
    );
  }

  Future<void> _loadCityFromGeoOnce({bool force = false}) async {
    if (_didLoadCityOnce && !force) return;

    _didLoadCityOnce = true;

    await _loadCityFromGeo();
  }

  void _openViewerMenu({
    required BuildContext context,
    required String profileUid,
    required String username,
    required String fullName,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ViewerMenuSheet(
        profileUid: profileUid,
        username: username,
        fullName: fullName,
      ),
    );
  }

  Future<bool> _isConnectedTo({
    required String myUid,
    required String otherUid,
  }) async {
    if (myUid == otherUid) return true;

    final db = FirebaseFirestore.instance;

    final myFriendDoc = await db
        .collection('users')
        .doc(myUid)
        .collection('friends')
        .doc(otherUid)
        .get();

    if (myFriendDoc.exists) return true;

    final myUserDoc = await db.collection('users').doc(myUid).get();
    final friendIds = List<String>.from(myUserDoc.data()?['friendIds'] ?? []);

    return friendIds.contains(otherUid);
  }

  Future<void> _ensureMessageRequestDocs({
    required String fromUid,
    required String toUid,
    required String channelCid,
  }) async {
    final db = FirebaseFirestore.instance;
    final now = FieldValue.serverTimestamp();

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

    debugPrint('🧾 writing request docs with batch...');
    debugPrint('incoming path: ${incomingRef.path}');
    debugPrint('outgoing path: ${outgoingRef.path}');

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

    batch.set(
      incomingRef,
      payload,
      SetOptions(merge: true),
    );

    batch.set(
      outgoingRef,
      payload,
      SetOptions(merge: true),
    );

    await batch.commit();

    debugPrint('✅ request docs batch committed.');
  }

  Future<void> _openProfileChatWithRequestRouting({
    required String profileUid,
    required bool targetRequiresRequests,
  }) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    if (myUid == null || myUid.isEmpty) return;
    if (profileUid.trim().isEmpty) return;
    if (myUid == profileUid) return;

    HapticFeedback.selectionClick();

    try {
      final db = FirebaseFirestore.instance;

      final targetSnap = await db.collection('users').doc(profileUid).get();
      final targetData = targetSnap.data() ?? {};

      final messagePrivacy = Map<String, dynamic>.from(
        targetData['messagePrivacy'] ?? {},
      );

      final targetActuallyRequiresRequests =
          messagePrivacy['requireMessageRequests'] == true;

      // Use BOTH values. The profile stream value and fresh Firestore value.
      // If either says requests are on, treat requests as ON.
      final resolvedRequiresRequests =
          targetRequiresRequests || targetActuallyRequiresRequests;

      final connected = await _isConnectedTo(
        myUid: myUid,
        otherUid: profileUid,
      );

      debugPrint('================ MESSAGE ROUTE DEBUG ================');
      debugPrint('myUid: $myUid');
      debugPrint('profileUid/targetUid: $profileUid');
      debugPrint('targetRequiresRequests param: $targetRequiresRequests');
      debugPrint('target Firestore messagePrivacy: $messagePrivacy');
      debugPrint('targetActuallyRequiresRequests: $targetActuallyRequiresRequests');
      debugPrint('resolvedRequiresRequests: $resolvedRequiresRequests');
      debugPrint('connected: $connected');
      debugPrint('=====================================================');

      final channel = await PingmeeStreamChatService.instance
          .openCachedOrCreateDirectChat(profileUid)
          .timeout(const Duration(seconds: 14));

      final channelCid = (channel.cid ?? channel.id ?? '').toString();

      final shouldBeRequest = !connected && resolvedRequiresRequests;

      debugPrint(
        '💬 message route result: '
        'channelCid=$channelCid shouldBeRequest=$shouldBeRequest',
      );

      if (shouldBeRequest) {
        await _ensureMessageRequestDocs(
          fromUid: myUid,
          toUid: profileUid,
          channelCid: channelCid,
        );

        debugPrint('✅ message request docs ensured.');
      } else {
        debugPrint(
          '⚠️ NOT creating message request because '
          'connected=$connected resolvedRequiresRequests=$resolvedRequiresRequests',
        );
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        pingmeeChatRoute(channel),
      );
    } catch (error, stack) {
      debugPrint('❌ open profile chat failed: $error');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<MutualFriendsData> _mutualFriendsFuture({
    required String myUid,
    required String profileUid,
  }) {
    final key = "$myUid:$profileUid";

    return _mutualFriendsFutureCache.putIfAbsent(
      key,
      () => _buildMutualFriendsData(
        myUid: myUid,
        profileUid: profileUid,
      ),
    );
  }

  Future<void> _maybeLogProfileView(String profileUid) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;
    if (myUid == profileUid) return;

    final now = DateTime.now();
    final dayKey = DateFormat("yyyy-MM-dd").format(now);
    final logKey = "$myUid|$profileUid|$dayKey";

    if (_loggedProfileViewKey == logKey) return;
    _loggedProfileViewKey = logKey;

    try {
      final city = _cityLabel.trim().isEmpty ? "Unknown" : _cityLabel.trim();
      final db = FirebaseFirestore.instance;

      final viewRef = db
          .collection("users")
          .doc(profileUid)
          .collection("profile_views")
          .doc("${myUid}_$dayKey");

      final notifRef = db
          .collection("users")
          .doc(profileUid)
          .collection("notifications")
          .doc("profile_view_${myUid}_$dayKey");

      final viewerSnap = await db.collection("users").doc(myUid).get();
      final viewerData = viewerSnap.data() ?? {};

      final senderName = (viewerData["fullName"] ??
              viewerData["displayName"] ??
              viewerData["name"] ??
              "")
          .toString()
          .trim();

      final senderPhotoUrl = (viewerData["photoUrl"] ??
              viewerData["profilePhotoUrl"] ??
              viewerData["avatarUrl"] ??
              "")
          .toString()
          .trim();

      final batch = db.batch();

      batch.set(
        viewRef,
        {
          "viewerUid": myUid,
          "viewerCity": city,
          "viewerDisplayLocation": city,
          "viewerCountry": "Zambia",
          "dayKey": dayKey,
          "viewedAt": FieldValue.serverTimestamp(),
          "expiresAt": Timestamp.fromDate(
            now.add(const Duration(days: 90)),
          ),
        },
        SetOptions(merge: true),
      );

      batch.set(
        notifRef,
        {
          "type": "profile_view",
          "senderUid": myUid,
          "senderName": senderName,
          "senderPhotoUrl": senderPhotoUrl,
          "viewerCity": city,
          "read": false,
          "createdAt": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      await batch.commit();
      debugPrint("✅ profile view logged: $logKey");
    } catch (e, st) {
      _loggedProfileViewKey = null;
      debugPrint("❌ profile view log failed: $e");
      debugPrint("$st");
    }
  }

  /// Pull-to-refresh handler. The old implementation only reloaded
  /// the city from geo, so the on-screen profile data, pings, events,
  /// tasks, moments, friend count, mutual friends, and visibility context
  /// were never actually re-fetched. Now we:
  ///   1. Bump the refresh tick so child tabs and the visibility
  ///      FutureBuilder rebuild with a new Key (forces them to re-fetch).
  ///   2. Null out the cached Firestore streams so the next build
  ///      re-subscribes to the user doc and friends collection
  ///      (a fresh subscription gets the latest data, instead of
  ///      trusting the long-lived stream that may have gone stale
  ///      while the screen was backgrounded).
  ///   3. Re-load the city from geo.
  Future<void> _refreshProfileTab() async {
    if (_refreshingProfile) return;

    _refreshingProfile = true;

    try {
      // Invalidate the cached streams so the next build of the
      // StreamBuilder re-subscribes. The new subscription will fetch
      // the current document/collection state from Firestore.
      _profileStream = null;
      _profileStreamKey = null;
      _friendsStreamCache.clear();

      setState(() {
        _profileRefreshTick++;
      });

      await _loadCityFromGeoOnce(force: true);

      // Small delay keeps the pull gesture feeling deliberate.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } finally {
      if (mounted) {
        setState(() {
          _refreshingProfile = false;
        });
      }
    }
  }

  Future<void> _openNoteComposerFlow({
    required BuildContext context,
    required String currentNote,
    required DocumentReference<Map<String, dynamic>> userRef,
  }) async {
    final proceed = await _showNoteIntroPopup(
      context: context,
      hasExistingNote: currentNote.trim().isNotEmpty,
    );

    if (proceed != true || !context.mounted) return;

    await _openStickyNoteEditor(
      context: context,
      currentNote: currentNote,
      userRef: userRef,
    );
  }

  Future<bool?> _showNoteIntroPopup({
    required BuildContext context,
    required bool hasExistingNote,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8F3),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 30,
                      offset: const Offset(0, 16),
                      color: Colors.black.withOpacity(.16),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),

                      const SizedBox(height: 14),

                      const _NotesIntroArtwork(),

                      const SizedBox(height: 16),

                      Text(
                        hasExistingNote ? "Edit your note" : "Write a quick note",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),

                      const SizedBox(height: 8),

                      Text(
                        hasExistingNote
                            ? "Refresh what people see when they land on your profile."
                            : "Share a short thought, mood, or update. Keep it light and current.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13.5,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: Colors.black.withOpacity(.56),
                        ),
                      ),

                      const SizedBox(height: 20),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  Navigator.pop(sheetContext, false),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: Colors.black.withOpacity(.10),
                                ),
                                backgroundColor: Colors.white.withOpacity(.62),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(
                                "Not now",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black.withOpacity(.70),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 10),

                          Expanded(
                            child: ElevatedButton(
                              onPressed: () =>
                                  Navigator.pop(sheetContext, true),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(
                                hasExistingNote ? "Edit note" : "Write note",
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Get or create friend state manager for a profile
  FriendStateManager _getFriendStateManager(String profileUid) {
    if (!_friendStateManagers.containsKey(profileUid)) {
      _friendStateManagers[profileUid] = FriendStateManager(
        myUid: _myUid ?? "",
        targetUid: profileUid,
      );
    }
    return _friendStateManagers[profileUid]!;
  }

  void _openCommunitiesPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Communities coming next."),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openJoinedTabAndScroll() async {
    _tabs.animateTo(0);

    await Future.delayed(const Duration(milliseconds: 40));

    if (!_scrollController.hasClients) return;

    await _scrollController.animateTo(
      320,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<MutualFriendsData> _buildMutualFriendsData({
    required String myUid,
    required String profileUid,
  }) async {
    // ✅ Check cache first
    final cacheKey = "$myUid:$profileUid";
    if (_mutualFriendsCache.containsKey(cacheKey)) {
      final cached = _mutualFriendsCache[cacheKey]!;
      if (!cached.isExpired) {
        return MutualFriendsData(
          myFriendIds: {},
          profileFriendIds: {},
          mutualFriendIds: cached.mutualIds,
        );
      }
    }

    final db = FirebaseFirestore.instance;

    if (myUid == profileUid) {
      return const MutualFriendsData(
        myFriendIds: {},
        profileFriendIds: {},
        mutualFriendIds: {},
      );
    }

    final myDocFuture = db.collection("users").doc(myUid).get();
    final profileDocFuture = db.collection("users").doc(profileUid).get();
    final myFriendsFuture =
        db.collection("users").doc(myUid).collection("friends").get();
    final profileFriendsFuture =
        db.collection("users").doc(profileUid).collection("friends").get();

    final results = await Future.wait([
      myDocFuture,
      profileDocFuture,
      myFriendsFuture,
      profileFriendsFuture,
    ]);

    final myData =
        (results[0] as DocumentSnapshot<Map<String, dynamic>>).data() ?? {};
    final profileData =
        (results[1] as DocumentSnapshot<Map<String, dynamic>>).data() ?? {};
    final myFriendsSnap =
        results[2] as QuerySnapshot<Map<String, dynamic>>;
    final profileFriendsSnap =
        results[3] as QuerySnapshot<Map<String, dynamic>>;

    final myIds = <String>{};
    final profileIds = <String>{};

    myIds.addAll(List<String>.from(myData["friendIds"] ?? []));
    profileIds.addAll(List<String>.from(profileData["friendIds"] ?? []));

    for (final doc in myFriendsSnap.docs) {
      final fid = (doc.data()["friendId"] ?? "").toString();
      if (fid.isNotEmpty) myIds.add(fid);
    }

    for (final doc in profileFriendsSnap.docs) {
      final fid = (doc.data()["friendId"] ?? "").toString();
      if (fid.isNotEmpty) profileIds.add(fid);
    }

    myIds.remove(myUid);
    myIds.remove(profileUid);

    profileIds.remove(profileUid);
    profileIds.remove(myUid);

    final mutualIds = myIds.intersection(profileIds);

    // ✅ Cache the result with TTL
    _mutualFriendsCache[cacheKey] = _CachedMutualFriends(
      mutualIds: mutualIds,
      cachedAt: DateTime.now(),
    );

    return MutualFriendsData(
      myFriendIds: myIds,
      profileFriendIds: profileIds,
      mutualFriendIds: mutualIds,
    );
  }


  Future<PingVisibilityContext> _buildViewerVisibilityContext({
    required String viewerUid,
  }) async {
    final db = FirebaseFirestore.instance;

    final viewerDoc =
        await db.collection("users").doc(viewerUid).get();

    final viewerData = viewerDoc.data() ?? {};
    final verification =
        Map<String, dynamic>.from(viewerData["verification"] ?? {});
    final viewerVerified = verification["status"] == "verified";

    final friendIds = <String>{};

    final storedFriendIds = List<String>.from(viewerData["friendIds"] ?? []);
    friendIds.addAll(storedFriendIds);

    final friendsSnap = await db
        .collection("users")
        .doc(viewerUid)
        .collection("friends")
        .get();

    for (final doc in friendsSnap.docs) {
      final fid = (doc.data()["friendId"] ?? "").toString();
      if (fid.isNotEmpty) friendIds.add(fid);
    }

    return PingVisibilityContext(
      viewerUid: viewerUid,
      viewerVerified: viewerVerified,
      viewerFriendIds: friendIds,
    );
  }

  void _openFriendsScreen({
    required String profileUid,
    required bool isOwner,
    int initialTab = 0,
  }) {
    final myUid = _myUid;
    if (myUid == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProfileFriendsScreen(
          profileUid: profileUid,
          viewerUid: myUid,
          isOwner: isOwner,
          initialTab: initialTab,
        ),
      ),
    );
  }

  Future<void> _setOnline(bool online) async {
    final uid = _myUid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "isOnline": online,
        "lastSeen": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }


  Stream<Map<String, dynamic>> _friendEdgeStateStream({
    required String myUid,
    required String profileUid,
  }) {
    final db = FirebaseFirestore.instance;

    final inStream = db
        .collection("users")
        .doc(myUid)
        .collection("friend_requests_in")
        .doc(profileUid)
        .snapshots();

    final outStream = db
        .collection("users")
        .doc(myUid)
        .collection("friend_requests_out")
        .doc(profileUid)
        .snapshots();

    final friendStream = db
        .collection("users")
        .doc(myUid)
        .collection("friends")
        .doc(profileUid)
        .snapshots();

    return Stream.multi((controller) {
      DocumentSnapshot<Map<String, dynamic>>? inSnap;
      DocumentSnapshot<Map<String, dynamic>>? outSnap;
      DocumentSnapshot<Map<String, dynamic>>? friendSnap;

      void emit() {
        controller.add({
          "hasIncoming": inSnap?.exists == true,
          "hasOutgoing": outSnap?.exists == true,
          "isFriend": friendSnap?.exists == true,
        });
      }

      final sub1 = inStream.listen((snap) {
        inSnap = snap;
        emit();
      }, onError: controller.addError);

      final sub2 = outStream.listen((snap) {
        outSnap = snap;
        emit();
      }, onError: controller.addError);

      final sub3 = friendStream.listen((snap) {
        friendSnap = snap;
        emit();
      }, onError: controller.addError);

      controller.onCancel = () async {
        await sub1.cancel();
        await sub2.cancel();
        await sub3.cancel();
      };
    });
  }

  Future<void> _sendFriendRequest({
    required String fromUid,
    required String toUid,
    required String senderName,
    required String senderUsername,
  }) async {
    if (fromUid == toUid) return;

    final db = FirebaseFirestore.instance;

    final inRef = db
        .collection("users")
        .doc(toUid)
        .collection("friend_requests_in")
        .doc(fromUid);

    final outRef = db
        .collection("users")
        .doc(fromUid)
        .collection("friend_requests_out")
        .doc(toUid);

    final friendRefA = db
        .collection("users")
        .doc(fromUid)
        .collection("friends")
        .doc(toUid);

    final friendRefB = db
        .collection("users")
        .doc(toUid)
        .collection("friends")
        .doc(fromUid);

    final notifRef = db
        .collection("users")
        .doc(toUid)
        .collection("notifications")
        .doc();

    final senderDocRef = db.collection("users").doc(fromUid);

    await db.runTransaction((tx) async {
      // ✅ ALL READS FIRST
      final existingFriendA = await tx.get(friendRefA);
      final existingFriendB = await tx.get(friendRefB);
      final existingIn = await tx.get(inRef);
      final existingOut = await tx.get(outRef);
      final senderDoc = await tx.get(senderDocRef);

      if (existingFriendA.exists || existingFriendB.exists) return;
      if (existingIn.exists || existingOut.exists) return;

      final senderData = senderDoc.data() ?? {};
      final senderPhotoUrl = (senderData["photoUrl"] ?? "").toString();

      final now = FieldValue.serverTimestamp();

      // ✅ WRITES AFTER ALL READS
      tx.set(inRef, {
        "fromUid": fromUid,
        "toUid": toUid,
        "status": "pending",
        "createdAt": now,
      });

      tx.set(outRef, {
        "fromUid": fromUid,
        "toUid": toUid,
        "status": "pending",
        "createdAt": now,
      });

      tx.set(notifRef, {
        "type": "connection_request",
        "senderUid": fromUid,
        "senderName": senderName,
        "senderUsername": senderUsername,
        "senderPhotoUrl": senderPhotoUrl,
        "title": "Connection request",
        "body": "$senderName sent you a connection request.",
        "read": false,
        "createdAt": now,
      });
    });
  }

  Future<void> _acceptFriendRequest({
    required String myUid,
    required String otherUid,
  }) async {
    final db = FirebaseFirestore.instance;

    final myUserRef = db.collection("users").doc(myUid);
    final otherUserRef = db.collection("users").doc(otherUid);

    final myIncomingRef =
        myUserRef.collection("friend_requests_in").doc(otherUid);
    final theirOutgoingRef =
        otherUserRef.collection("friend_requests_out").doc(myUid);

    final myFriendRef = myUserRef.collection("friends").doc(otherUid);
    final theirFriendRef = otherUserRef.collection("friends").doc(myUid);

    final acceptNotifRef = otherUserRef.collection("notifications").doc();

    await db.runTransaction((tx) async {
      final incomingSnap = await tx.get(myIncomingRef);
      if (!incomingSnap.exists) return;

      final myUserSnap = await tx.get(myUserRef);
      final myIds = List<String>.from(myUserSnap.data()?["friendIds"] ?? []);

      if (!myIds.contains(otherUid)) myIds.add(otherUid);

      final now = FieldValue.serverTimestamp();

      tx.delete(myIncomingRef);
      tx.delete(theirOutgoingRef);

      tx.set(myFriendRef, {
        "friendId": otherUid,
        "createdAt": now,
      });

      tx.set(theirFriendRef, {
        "friendId": myUid,
        "createdAt": now,
      });

      // ✅ only update MY parent doc
      tx.set(myUserRef, {
        "friendIds": myIds,
        "friendsCount": myIds.length,
      }, SetOptions(merge: true));

      final myUserData = myUserSnap.data() ?? {};
      final myFullName = (myUserData["fullName"] ?? "").toString();
      final myUsername = (myUserData["username"] ?? "").toString();
      final myPhotoUrl = (myUserData["photoUrl"] ?? "").toString();

      tx.set(acceptNotifRef, {
        "type": "connection_accept",
        "senderUid": myUid,
        "senderName": myFullName,
        "senderUsername": myUsername,
        "senderPhotoUrl": myPhotoUrl,
        "title": "Connection request accepted",
        "body": "$myFullName accepted your connection request.",
        "read": false,
        "createdAt": now,
      });
    });
  }

  Future<void> _cancelFriendRequest({
    required String myUid,
    required String otherUid,
  }) async {
    final db = FirebaseFirestore.instance;

    final myOutgoingRef = db
        .collection("users")
        .doc(myUid)
        .collection("friend_requests_out")
        .doc(otherUid);

    final theirIncomingRef = db
        .collection("users")
        .doc(otherUid)
        .collection("friend_requests_in")
        .doc(myUid);

    final batch = db.batch();
    batch.delete(myOutgoingRef);
    batch.delete(theirIncomingRef);
    await batch.commit();
  }

  Future<void> _removeFriendConnection({
    required String myUid,
    required String otherUid,
  }) async {
    final db = FirebaseFirestore.instance;

    final myUserRef = db.collection("users").doc(myUid);
    final otherUserRef = db.collection("users").doc(otherUid);

    final myFriendRef = myUserRef.collection("friends").doc(otherUid);
    final theirFriendRef = otherUserRef.collection("friends").doc(myUid);

    await db.runTransaction((tx) async {
      final myUserSnap = await tx.get(myUserRef);
      final otherUserSnap = await tx.get(otherUserRef);

      final myIds = List<String>.from(myUserSnap.data()?["friendIds"] ?? []);
      final otherIds = List<String>.from(otherUserSnap.data()?["friendIds"] ?? []);

      myIds.remove(otherUid);
      otherIds.remove(myUid);

      tx.delete(myFriendRef);
      tx.delete(theirFriendRef);

      tx.set(myUserRef, {
        "friendIds": myIds,
        "friendsCount": myIds.length,
      }, SetOptions(merge: true));

      tx.set(otherUserRef, {
        "friendIds": otherIds,
        "friendsCount": otherIds.length,
      }, SetOptions(merge: true));
    });
  }

  Future<void> _declineFriendRequest({
    required String myUid,
    required String otherUid,
  }) async {
    final db = FirebaseFirestore.instance;

    final myIncomingRef = db
        .collection("users")
        .doc(myUid)
        .collection("friend_requests_in")
        .doc(otherUid);

    final theirOutgoingRef = db
        .collection("users")
        .doc(otherUid)
        .collection("friend_requests_out")
        .doc(myUid);

    final batch = db.batch();
    batch.delete(myIncomingRef);
    batch.delete(theirOutgoingRef);
    await batch.commit();
  }

  Future<void> _showQuickLoader(Future<void> Function() work) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.10),
      builder: (_) => const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
          ),
        ),
      ),
    );

    try {
      await work();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _openCreatePingSheet() async {
    HapticFeedback.selectionClick();

    await _showQuickLoader(() async {
      // tiny delay so the loader actually appears
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;

      // ✅ Navigate to full-screen page instead of bottom sheet
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CreatePingSheet(
            initialGeoPoint: null,
            onCreated: (result) {
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    result.hasMediaIssues
                        ? "Ping created, but some media failed to upload."
                        : "Ping created ✅",
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            draft: _createPingDraft,
          ),
        ),
      );
    });
  }

  Future<void> _openNoteViewerFullScreen({
    required BuildContext context,
    required String note,
    required String name,
  }) async {
    final t = note.trim();
    if (t.isEmpty) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final h = MediaQuery.of(sheetContext).size.height;

        return SafeArea(
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            child: Container(
              height: h * 0.92,
              decoration: const BoxDecoration(
                color: Color(0xFF8BCF7B),
              ),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: _GreenWallPattern(),
                  ),

                  Column(
                    children: [
                      const SizedBox(height: 12),
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 12),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              PhosphorIcons.note(PhosphorIconsStyle.light),
                              color: Colors.white,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "$name’s note",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              icon: const Icon(Icons.close_rounded, color: Colors.white),
                            ),
                          ],
                        ),
                      ),

                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: _StickyDisplayCard(text: t),
                          ),
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: AppColors.brandGreen,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text(
                              "Close",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatJoinedLabel({
    dynamic createdAt,
    User? currentUser,
  }) {
    DateTime? joined;

    if (createdAt is Timestamp) {
      joined = createdAt.toDate();
    } else if (createdAt is DateTime) {
      joined = createdAt;
    } else {
      final creationTime = currentUser?.metadata.creationTime;
      if (creationTime != null) joined = creationTime;
    }

    if (joined == null) return "Joined recently";

    return "Joined ${DateFormat("MMM yyyy").format(joined)}";
  }

  Future<void> requestVerification({
    required String uid,
    required Map<String, dynamic> userData,
    required String typeRequested, // identity | trusted | business
    required String reason,
  }) async {
    final requests = FirebaseFirestore.instance.collection("verification_requests");

    // prevent duplicate pending requests
    final existing = await requests
        .where("uid", isEqualTo: uid)
        .where("status", isEqualTo: "pending")
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      throw Exception("You already have a pending verification request.");
    }

    final reqRef = requests.doc();

    await reqRef.set({
      "uid": uid,
      "createdAt": FieldValue.serverTimestamp(),
      "status": "pending",
      "typeRequested": typeRequested,
      "reason": reason.trim(),
      "snapshot": {
        "fullName": (userData["fullName"] ?? "").toString(),
        "username": (userData["username"] ?? "").toString(),
        "email": (userData["email"] ?? "").toString(),
        "phone": (userData["phone"] ?? "").toString(),
        "photoUrl": (userData["photoUrl"] ?? "").toString(),
        "coverUrl": (userData["coverUrl"] ?? "").toString(),
        "socials": Map<String, dynamic>.from(userData["socials"] ?? {}),
        "intro": (userData["intro"] ?? "").toString(),
      },
    });
  }

  Future<void> _showVerificationRequestSheet({
    required BuildContext context,
    required String uid,
    required Map<String, dynamic> userData,
  }) async {
    String selectedType = "identity";
    final reasonCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Row(
                          children: [
                            Expanded(
                              child: Text(
                                "Request verification",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: selectedType,
                          decoration: const InputDecoration(
                            labelText: "Verification type",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: "identity",
                              child: Text("Identity"),
                            ),
                            DropdownMenuItem(
                              value: "trusted",
                              child: Text("Trusted"),
                            ),
                            DropdownMenuItem(
                              value: "business",
                              child: Text("Business"),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setModalState(() => selectedType = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: reasonCtrl,
                          maxLines: 4,
                          maxLength: 240,
                          decoration: const InputDecoration(
                            labelText: "Why should this account be verified?",
                            hintText: "Add context for your request",
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.brandGreen,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: () async {
                              final reason = reasonCtrl.text.trim();

                              if (reason.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Please add a reason first."),
                                  ),
                                );
                                return;
                              }

                              try {
                                await requestVerification(
                                  uid: uid,
                                  userData: userData,
                                  typeRequested: selectedType,
                                  reason: reason,
                                );

                                if (!mounted) return;
                                Navigator.pop(sheetContext);

                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Verification request sent."),
                                  ),
                                );
                              } catch (e) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(e.toString().replaceFirst("Exception: ", "")),
                                  ),
                                );
                              }
                            },
                            child: const Text(
                              "Submit request",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showVerifiedBadgeSheet({
    required BuildContext context,
    required String fullName,
    required String verificationType,
    required dynamic verifiedAt,
  }) {
    String prettyType(String raw) {
      switch (raw.trim().toLowerCase()) {
        case "business":
          return "Business";
        case "trusted":
          return "Trusted";
        case "identity":
        default:
          return "Identity";
      }
    }

    final typeLabel = prettyType(verificationType);

    DateTime? verifiedDate;
    if (verifiedAt is Timestamp) {
      verifiedDate = verifiedAt.toDate();
    } else if (verifiedAt is DateTime) {
      verifiedDate = verifiedAt;
    }

    final verifiedDateLabel = verifiedDate != null
        ? DateFormat("d MMM yyyy").format(verifiedDate)
        : "Unknown";

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withOpacity(.18),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 520,
                ),
                child: _GlassBottomSheet(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        Center(
                          child: Container(
                            width: 62,
                            height: 62,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1D9BF0).withOpacity(.12),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.verified_rounded,
                              color: Color(0xFF1D9BF0),
                              size: 34,
                            ),
                          ),
                        ),

                        const SizedBox(height: 14),

                        Text(
                          "$fullName is verified",
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),

                        const SizedBox(height: 8),

                        Text(
                          "This account is verified.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.5,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                            color: Colors.black.withOpacity(.62),
                          ),
                        ),

                        const SizedBox(height: 16),

                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.75),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.black.withOpacity(.06),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1D9BF0).withOpacity(.10),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  PhosphorIcons.sealCheck(
                                    PhosphorIconsStyle.fill,
                                  ),
                                  color: Color(0xFF1D9BF0),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      "Verification type",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black.withOpacity(.52),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      typeLabel,
                                      style: const TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 10),

                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.75),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.black.withOpacity(.06),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1D9BF0).withOpacity(.10),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(
                                  Icons.event_rounded,
                                  color: Color(0xFF1D9BF0),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      "Verified on",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black.withOpacity(.52),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      verifiedDateLabel,
                                      style: const TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        ElevatedButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          child: const Text(
                            "Close",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadCityFromGeo() async {
    debugPrint("📍 _loadCityFromGeo() called");
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      debugPrint("📍 serviceEnabled: $serviceEnabled");
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      debugPrint("📍 permission (before): $permission");

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        debugPrint("📍 permission (after request): $permission");
      }

      if (permission == LocationPermission.denied) return;
      if (permission == LocationPermission.deniedForever) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 20),
      );

      debugPrint("📍 coords: ${pos.latitude}, ${pos.longitude}");

      final placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      debugPrint("📍 placemarks length: ${placemarks.length}");

      if (placemarks.isEmpty) return;

      final p = placemarks.first;

      debugPrint(
        "📍 placemark fields: locality=${p.locality}, subAdmin=${p.subAdministrativeArea}, admin=${p.administrativeArea}, subLocality=${p.subLocality}, country=${p.country}",
      );

      final city = (p.locality?.trim().isNotEmpty == true)
          ? p.locality!.trim()
          : (p.subAdministrativeArea?.trim().isNotEmpty == true)
              ? p.subAdministrativeArea!.trim()
              : (p.administrativeArea?.trim().isNotEmpty == true)
                  ? p.administrativeArea!.trim()
                  : (p.subLocality?.trim().isNotEmpty == true)
                      ? p.subLocality!.trim()
                      : "";

      final country = (p.country ?? "").trim();
      final result = [city, country].where((e) => e.isNotEmpty).join(", ");

      debugPrint("📍 result: $result");

      if (!mounted || result.isEmpty) return;

      if (_cityLabel == result) return;

      setState(() {
        _cityLabel = result;
      });
    } catch (e, st) {
      debugPrint("📍 ERROR: $e");
      debugPrint("$st");
    }
  }

  // NOTE bubble editing
  Future<void> _openStickyNoteEditor({
    required BuildContext context,
    required String currentNote,
    required DocumentReference<Map<String, dynamic>> userRef,
  }) async {
    final ctrl = TextEditingController(text: currentNote.trim());
    final isEditing = currentNote.trim().isNotEmpty;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final h = MediaQuery.of(sheetContext).size.height;

        void saveNote() {
          FocusScope.of(sheetContext).unfocus();
          final note = ctrl.text.trim();
          final optimisticTime = DateTime.now();

          final previousLocalNote = _localNoteOverride;
          final previousLocalTime = _localNoteUpdatedAtOverride;

          Navigator.pop(sheetContext);

          if (!mounted) return;

          setState(() {
            _localNoteOverride = note;
            _localNoteUpdatedAtOverride = optimisticTime;
          });

          final payload = note.isEmpty
              ? <String, dynamic>{
                  "note": FieldValue.delete(),
                  "noteUpdatedAt": FieldValue.delete(),
                }
              : <String, dynamic>{
                  "note": note,
                  "noteUpdatedAt": FieldValue.serverTimestamp(),
                };

          unawaited(
            userRef.set(payload, SetOptions(merge: true)).catchError((error) {
              debugPrint("❌ note save failed: $error");

              if (!mounted) return;

              setState(() {
                _localNoteOverride = previousLocalNote;
                _localNoteUpdatedAtOverride = previousLocalTime;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Could not save note."),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }),
          );
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 12,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Container(
                height: h * 0.86,
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8F3),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 30,
                      offset: const Offset(0, 16),
                      color: Colors.black.withOpacity(.16),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),

                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              PhosphorIcons.notePencil(
                                PhosphorIconsStyle.bold,
                              ),
                              color: Colors.white,
                              size: 21,
                            ),
                          ),

                          const SizedBox(width: 12),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEditing ? "Edit note" : "Create note",
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "A short profile note for what matters right now.",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 12.8,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black.withOpacity(.50),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          IconButton(
                            onPressed: () {
                              FocusScope.of(sheetContext).unfocus();
                              Navigator.pop(sheetContext);
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          children: [
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(
                                minHeight: 360,
                              ),
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(28),
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 22,
                                    offset: const Offset(0, 12),
                                    color: Colors.black.withOpacity(.055),
                                  ),
                                ],
                              ),
                              child: _EditableStickyNote(
                                controller: ctrl,
                              ),
                            ),

                            const SizedBox(height: 12),

                            Text(
                              "Keep it sharp. One clear thought beats a messy paragraph.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w500,
                                fontSize: 12.5,
                                color: Colors.black.withOpacity(.52),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: Colors.black.withOpacity(.10),
                                ),
                                backgroundColor: Colors.white.withOpacity(.65),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(
                                "Cancel",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black.withOpacity(.70),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 10),

                          Expanded(
                            child: ElevatedButton(
                              onPressed: saveNote,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(
                                isEditing ? "Save note" : "Post note",
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
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
        );
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 350));
    ctrl.dispose();
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppStartRouter()),
      (r) => false,
    );
  }

  void _openMenu({
    required bool verified,
    required bool hasPendingVerification,
    required Map<String, dynamic> userData,
  }) {
    HapticFeedback.selectionClick();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileOwnerMainMenuScreen(uid: uid!),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFEFF2F7),
        body: SafeArea(
          child: Center(
            child: Text(
              "Not logged in",
              style: TextStyle(fontFamily: "Nunito"),
            ),
          ),
        ),
      );
    }

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFEFF2F7),
        body: SafeArea(
          child: Center(
            child: Text(
              "Not logged in",
              style: TextStyle(fontFamily: "Nunito"),
            ),
          ),
        ),
      );
    }

    final profileUid = widget.profileUid ?? myUid; // ✅ viewed user
    final isOwner = myUid == profileUid;

    if (!isOwner) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeLogProfileView(profileUid);
      });
    }

    final userRef = FirebaseFirestore.instance.collection("users").doc(profileUid);

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _profileDocStreamFor(profileUid),
          builder: (context, snap) {
            if (snap.hasError) {
              return const Scaffold(
                backgroundColor: Color(0xFFEFF2F7),
                body: SafeArea(
                  child: Center(
                    child: Text(
                      "Couldn’t load profile",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            }

            if (!snap.hasData || snap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                backgroundColor: Color(0xFFEFF2F7),
                body: SafeArea(
                  child: _ProfileInitialLoading(),
                ),
              );
            }

            final data = snap.data?.data() ?? {};

            final fullName = (data["fullName"] ?? "Your profile").toString();
            final bio = (data["bio"] ?? "").toString();

            final verification =
                Map<String, dynamic>.from(data["verification"] ?? {});
            final verified = verification["status"] == "verified";
            final verificationType = (verification["type"] ?? "identity").toString();
            final verificationVerifiedAt = verification["verifiedAt"];

            final username = (data["username"] ?? "").toString();
            final intro = (data["intro"] ?? "").toString();
            final gender = (data["gender"] ?? "").toString();
            final pronouns = (data["pronouns"] ?? "").toString();

            final createdAt = data["createdAt"];
            final joinedLabel = _formatJoinedLabel(
              createdAt: createdAt,
              currentUser: FirebaseAuth.instance.currentUser,
            );

            final email = (data["email"] ?? "").toString();
            final phone = (data["phone"] ?? "").toString();

            DateTime? birthDate;

            final rawBirthDate = data["birthDate"];

            if (rawBirthDate is Timestamp) {
              birthDate = rawBirthDate.toDate();
            } else if (rawBirthDate is DateTime) {
              birthDate = rawBirthDate;
            }

            final profileVisibility = Map<String, dynamic>.from(
              data["profileVisibility"] ?? {},
            );

            final showBirthdayOnProfile =
                profileVisibility["showBirthday"] == true;

            final messagePrivacy = Map<String, dynamic>.from(
              data["messagePrivacy"] ?? {},
            );

            final requireMessageRequests =
                messagePrivacy["requireMessageRequests"] == true;                          

            final socials = Map<String, dynamic>.from(data["socials"] ?? {});
            final websiteObj = socials["Website"];
            final websiteUrl = (websiteObj is Map)
                ? (websiteObj["url"] ?? websiteObj["handle"] ?? "").toString()
                : "";

            final storedFriendsCount = (data["friendsCount"] is num)
              ? (data["friendsCount"] as num).toInt()
              : 0;

            final communitiesCount = (data["communitiesCount"] is num)
              ? (data["communitiesCount"] as num).toInt()
              : 0;

            final photoUrl = (data["photoUrl"] ?? "").toString();
            final coverUrl = (data["coverUrl"] ?? "").toString();

            final interests = List<String>.from(data["interests"] ?? []);
            final skills = List<String>.from(data["skills"] ?? []);
            final distanceMiles = data["distanceMiles"];
            final distanceLabel =
                (distanceMiles is num) ? "${distanceMiles.round()} mi" : "—";

            final isOnline = pingmeeIsUserOnlineFromUserData(data);
            final serverRawNote = (data["note"] ?? "").toString();
            final noteUpdatedAt = data["noteUpdatedAt"];

            DateTime? serverNoteTime;
            if (noteUpdatedAt is Timestamp) {
              serverNoteTime = noteUpdatedAt.toDate();
            }

            final rawNote = _localNoteOverride ?? serverRawNote;
            final noteTime = _localNoteUpdatedAtOverride ?? serverNoteTime;

            final now = DateTime.now();
            final isNoteFresh =
                noteTime != null && now.difference(noteTime).inHours < 24;

            final note = isNoteFresh ? rawNote : "";
            final relationshipStream = (!isOwner)
                  ? _friendEdgeStateStream(myUid: myUid, profileUid: profileUid)
                  : null;
            final hasPendingVerification = verification["status"] == "pending";

                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _friendsStreamFor(profileUid),
                      builder: (context, friendsSnap) {
                        final liveFriendsCount = friendsSnap.data?.docs.length ?? 0;
                        final friendsCount = liveFriendsCount > storedFriendsCount
                            ? liveFriendsCount
                            : storedFriendsCount;

                        return RefreshIndicator(
                          onRefresh: _refreshProfileTab,

                          // Custom predicate so the spinner responds to any
                          // scroll-up gesture at the top of the scrollable,
                          // matching the natural feel of pull-to-refresh on
                          // the main feed. Fires on ScrollStart/Update/
                          // Overscroll while the user is at the top.
                          notificationPredicate: (notification) {
                            if (notification.metrics.axis != Axis.vertical) return false;

                            final atTop = notification.metrics.extentBefore == 0;

                            if (!atTop) return false;

                            return notification is ScrollStartNotification ||
                                notification is ScrollUpdateNotification ||
                                notification is OverscrollNotification;
                          },

                          color: AppColors.brandGreen,
                          displacement: 34,
                          edgeOffset: 0,
                          child: NestedScrollView(
                            controller: _scrollController,
                            physics: const BouncingScrollPhysics(
                              parent: AlwaysScrollableScrollPhysics(),
                            ),
                            floatHeaderSlivers: true,
                            headerSliverBuilder: (context, innerScrolled) => [
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                  child: isOwner
                                      ? _ProfileHeaderCard(
                                          fullName: fullName,
                                          username: username,
                                          intro: intro,
                                          cityLabel: _cityLabel,
                                          gender: gender,
                                          pronouns: pronouns,
                                          joinedLabel: joinedLabel,
                                          email: email,
                                          phone: phone,
                                          socials: socials,
                                          websiteUrl: websiteUrl,
                                          birthDate: birthDate,
                                          showBirthdayOnProfile: true,
                                          friendsCount: friendsCount,
                                          mutualFriendsCount: 0,
                                          communitiesCount: communitiesCount,
                                          photoUrl: photoUrl,
                                          coverUrl: coverUrl,
                                          onEditCover: () async {
                                            if (!isOwner) return;

                                            await updateUserImageFlow(
                                              context: context,
                                              uid: profileUid,
                                              existingUrl: coverUrl,
                                              firestoreField: "coverUrl",
                                              storageFolder: "cover_photos",
                                              sheetTitle: "Cover photo",
                                              allowRestoreDefault: true,
                                              restoreDefaultLabel: "Revert to default cover",
                                            );
                                          },
                                          defaultCoverAsset: _defaultCoverAsset,
                                          isOnline: isOnline,
                                          note: note,
                                          verified: verified,
                                          verificationType: verificationType,
                                          onVerifiedBadgeTap: () => _showVerifiedBadgeSheet(
                                            context: context,
                                            fullName: fullName,
                                            verificationType: verificationType,
                                            verifiedAt: verificationVerifiedAt,
                                          ),
                                          hasPendingVerification: hasPendingVerification,
                                          onRequestVerification: () => _showVerificationRequestSheet(
                                            context: context,
                                            uid: uid!,
                                            userData: data,
                                          ),
                                          onMenuTap: () {
                                            _openMenu(
                                              verified: verified,
                                              hasPendingVerification: hasPendingVerification,
                                              userData: data,
                                            );
                                          },
                                          onEdit: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => const ProfileEditScreen(),
                                              ),
                                            );
                                          },
                                          onCreatePing: _openCreatePingSheet,
                                          onOpenCamera: () async {
                                            await updateUserImageFlow(
                                              context: context,
                                              uid: profileUid,
                                              existingUrl: photoUrl,
                                              firestoreField: "photoUrl",
                                              storageFolder: "profile_pictures",
                                              sheetTitle: "Profile photo",
                                              allowAvatarPicker: true,
                                            );
                                          },
                                          onOwnerEditNote: () => _openNoteComposerFlow(
                                            context: context,
                                            currentNote: note,
                                            userRef: userRef,
                                          ),
                                          onViewerOpenNote: () => _openNoteViewerFullScreen(
                                            context: context,
                                            note: note,
                                            name: fullName,
                                          ),
                                          interests: interests,
                                          skills: skills,
                                          distanceLabel: distanceLabel,
                                          bio: bio,
                                          onOpenFriendsTab: () => _openFriendsScreen(
                                            profileUid: profileUid,
                                            isOwner: true,
                                          ),
                                          onOpenCommunitiesTap: _openCommunitiesPlaceholder,
                                          isOwner: true,
                                          friendButtonState: "owner",
                                          onAddFriend: () {},
                                          onRespondToRequest: () {},
                                          onMessage: () {
                                            _openProfileChatWithRequestRouting(
                                              profileUid: profileUid,
                                              targetRequiresRequests: requireMessageRequests,
                                            );
                                          },
                                          onShareNote: () => _openNoteComposerFlow(
                                            context: context,
                                            currentNote: note,
                                            userRef: userRef,
                                          ),
                                          onBack: widget.onBack,
                                        )
                                      : StreamBuilder<Map<String, dynamic>>(
                                        stream: relationshipStream,
                                        builder: (context, relSnap) {
                                          final rel = relSnap.data;
                                          final hasRelationshipData = relSnap.hasData && rel != null;

                                          final hasIncoming =
                                              hasRelationshipData && rel["hasIncoming"] == true;
                                          final hasOutgoing =
                                              hasRelationshipData && rel["hasOutgoing"] == true;
                                          final isFriendNow =
                                              hasRelationshipData && rel["isFriend"] == true;

                                          final derivedFriendButtonState = !hasRelationshipData
                                              ? "loading"
                                              : isFriendNow
                                                  ? "friends"
                                                  : hasIncoming
                                                      ? "incoming"
                                                      : hasOutgoing
                                                          ? "outgoing"
                                                          : "none";

                                          return FutureBuilder<MutualFriendsData>(
                                            future: _mutualFriendsFuture(
                                              myUid: myUid,
                                              profileUid: profileUid,
                                            ),
                                            builder: (context, mutualSnap) {
                                              final mutualData = mutualSnap.data;
                                              final mutualFriendsCount = mutualData?.mutualCount ?? 0;

                                              return _ProfileHeaderCard(
                                                fullName: fullName,
                                                username: username,
                                                intro: intro,
                                                cityLabel: _cityLabel,
                                                gender: gender,
                                                pronouns: pronouns,
                                                joinedLabel: joinedLabel,
                                                email: email,
                                                phone: phone,
                                                socials: socials,
                                                websiteUrl: websiteUrl,
                                                birthDate: birthDate,
                                                showBirthdayOnProfile: showBirthdayOnProfile,
                                                friendsCount: friendsCount,
                                                mutualFriendsCount: mutualFriendsCount,
                                                communitiesCount: communitiesCount,
                                                photoUrl: photoUrl,
                                                coverUrl: coverUrl,
                                                onEditCover: () async {},
                                                defaultCoverAsset: _defaultCoverAsset,
                                                isOnline: isOnline,
                                                note: note,
                                                verified: verified,
                                                verificationType: verificationType,
                                                onVerifiedBadgeTap: () => _showVerifiedBadgeSheet(
                                                  context: context,
                                                  fullName: fullName,
                                                  verificationType: verificationType,
                                                  verifiedAt: verificationVerifiedAt,
                                                ),
                                                hasPendingVerification: hasPendingVerification,
                                                onRequestVerification: () {},
                                                onMenuTap: () {
                                                  _openViewerMenu(
                                                    context: context,
                                                    profileUid: profileUid,
                                                    username: username,
                                                    fullName: fullName,
                                                  );
                                                },
                                                onEdit: () {},
                                                onCreatePing: () {},
                                                onOpenCamera: () async {},
                                                onOwnerEditNote: () {},
                                                onViewerOpenNote: () => _openNoteViewerFullScreen(
                                                  context: context,
                                                  note: note,
                                                  name: fullName,
                                                ),
                                                interests: interests,
                                                skills: skills,
                                                distanceLabel: distanceLabel,
                                                bio: bio,
                                                onOpenFriendsTab: () => _openFriendsScreen(
                                                  profileUid: profileUid,
                                                  isOwner: false,
                                                ),
                                                onOpenCommunitiesTap: _openCommunitiesPlaceholder,
                                                isOwner: false,
                                                friendButtonState: derivedFriendButtonState,
                                                onAddFriend: () async {
                                                  final manager = _getFriendStateManager(profileUid);
                                                  if (manager.isBusy) return;

                                                  HapticFeedback.selectionClick();

                                                  if (derivedFriendButtonState == "outgoing") {
                                                    final action = await showModalBottomSheet<String>(
                                                      context: context,
                                                      backgroundColor: Colors.transparent,
                                                      builder: (_) => _RequestedFriendSheet(),
                                                    );

                                                    if (action != "cancel") return;

                                                    final success = await manager.cancelFriendRequest();
                                                    if (!mounted) return;
                                                    setState(() {});

                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          success
                                                              ? "Connection request cancelled."
                                                              : "Failed to cancel request.",
                                                        ),
                                                      ),
                                                    );
                                                    return;
                                                  }

                                                  if (isFriendNow || hasOutgoing || hasIncoming) return;

                                                  final meDoc = await FirebaseFirestore.instance
                                                      .collection("users")
                                                      .doc(myUid)
                                                      .get();

                                                  final me = meDoc.data() ?? {};
                                                  final myFullName = (me["fullName"] ?? "").toString();
                                                  final myUsername = (me["username"] ?? "").toString();

                                                  final success = await manager.sendFriendRequest(
                                                    myFullName,
                                                    myUsername,
                                                  );

                                                  if (!mounted) return;
                                                  setState(() {});

                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        success
                                                            ? "Connection request sent."
                                                            : "Failed to send request.",
                                                      ),
                                                    ),
                                                  );
                                                },
                                                onRespondToRequest: () async {
                                                  final manager = _getFriendStateManager(profileUid);
                                                  if (manager.isBusy) return;

                                                  HapticFeedback.selectionClick();

                                                  if (derivedFriendButtonState == "friends") {
                                                    final action = await showModalBottomSheet<String>(
                                                      context: context,
                                                      backgroundColor: Colors.transparent,
                                                      builder: (_) => _FriendsActionsSheet(),
                                                    );

                                                    if (action == null) return;

                                                    if (action == "remove") {
                                                      final success = await manager.removeFriendConnection();
                                                      if (!mounted) return;
                                                      setState(() {});

                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        SnackBar(
                                                          content: Text(
                                                            success
                                                                ? "Connection removed."
                                                                : "Failed to remove connection.",
                                                          ),
                                                        ),
                                                      );
                                                      return;
                                                    }

                                                    if (!context.mounted) return;
                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          action == "block"
                                                              ? "Block coming next."
                                                              : action == "report"
                                                                  ? "Report flow coming next."
                                                                  : action == "share"
                                                                      ? "Share coming next."
                                                                      : "Help coming next.",
                                                        ),
                                                      ),
                                                    );
                                                    return;
                                                  }

                                                  final action = await showModalBottomSheet<String>(
                                                    context: context,
                                                    backgroundColor: Colors.transparent,
                                                    builder: (_) => _RespondFriendRequestSheet(),
                                                  );

                                                  if (action == null) return;

                                                  bool success = false;
                                                  String message = "";

                                                  if (action == "accept") {
                                                    final myDoc = await FirebaseFirestore.instance
                                                        .collection("users")
                                                        .doc(myUid)
                                                        .get();
                                                    final myData = myDoc.data() ?? {};

                                                    success = await manager.acceptFriendRequest(
                                                      (myData["fullName"] ?? "").toString(),
                                                      (myData["username"] ?? "").toString(),
                                                      (myData["photoUrl"] ?? "").toString(),
                                                    );
                                                    message = success
                                                        ? "Connection request accepted."
                                                        : "Failed to accept.";
                                                  } else if (action == "decline") {
                                                    success = await manager.declineFriendRequest();
                                                    message = success
                                                        ? "Connection request declined."
                                                        : "Failed to decline.";
                                                  }

                                                  if (!mounted) return;
                                                  setState(() {});
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text(message)),
                                                  );
                                                },
                                                onMessage: () {
                                                  _openProfileChatWithRequestRouting(
                                                    profileUid: profileUid,
                                                    targetRequiresRequests: requireMessageRequests,
                                                  );
                                                },
                                                onShareNote: () {},
                                                onBack: widget.onBack,
                                              );
                                            },
                                          );
                                        },
                                      ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                                  child: const Text(
                                    "Activity",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w700,
                                      fontSize: 17,
                                      color: Colors.black87,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                ),
                              ),
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _PinnedHeaderDelegate(
                                  height: 64,
                                  child: Container(
                                    color: const Color(0xFFEFF2F7),
                                    padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
                                    child: _GlassTabs(
                                      controller: _tabs,
                                      items: const [
                                        _TabSpec(
                                          label: "Pings",
                                          icon: PhosphorIcons.mapPin,
                                        ),
                                        _TabSpec(
                                          label: "Events",
                                          icon: PhosphorIcons.ticket,
                                        ),
                                        _TabSpec(
                                          label: "Tasks",
                                          icon: PhosphorIcons.checkSquare,
                                        ),
                                        _TabSpec(
                                          label: "Moments",
                                          icon: PhosphorIcons.sparkle,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            body: RefreshIndicator(
                              onRefresh: _refreshProfileTab,
                              color: AppColors.brandGreen,
                              displacement: 34,
                              edgeOffset: 0,
                              child: FutureBuilder<Map<String, dynamic>>(
                              key: ValueKey('bundle-$profileUid-$_profileRefreshTick'),
                              future: () async {
                                final visibility =
                                    await _buildViewerVisibilityContext(viewerUid: myUid);
                                final mutuals = await _buildMutualFriendsData(
                                  myUid: myUid,
                                  profileUid: profileUid,
                                );

                                return {
                                  "visibility": visibility,
                                  "mutuals": mutuals,
                                };
                              }(),
                              builder: (context, bundleSnap) {
                                if (!bundleSnap.hasData || bundleSnap.connectionState == ConnectionState.waiting) {
                                  return const _ProfileBodySkeleton();
                                }

                                final visibilityContext =
                                    bundleSnap.data!["visibility"] as PingVisibilityContext;
                                final mutualData =
                                    bundleSnap.data!["mutuals"] as MutualFriendsData;

                                return TabBarView(
                                  controller: _tabs,
                                  physics: const BouncingScrollPhysics(),
                                  children: [
                                    _PingsTab(
                                      key: ValueKey('pings-$profileUid-${_profileRefreshTick}_$_refreshingProfile'),
                                      uid: profileUid,
                                      visibilityContext: visibilityContext,
                                    ),
                                    _EventsTab(
                                      key: ValueKey('events-$profileUid-${_profileRefreshTick}_$_refreshingProfile'),
                                      uid: profileUid,
                                      bottomPad: ProfileTab.navBarHeight + 18,
                                    ),
                                    _TasksTab(
                                      key: ValueKey('tasks-$profileUid-${_profileRefreshTick}_$_refreshingProfile'),
                                      uid: profileUid,
                                      bottomPad: ProfileTab.navBarHeight + 18,
                                    ),
                                    _MomentsTab(
                                      key: ValueKey('moments-$profileUid-${_profileRefreshTick}_$_refreshingProfile'),
                                      uid: profileUid,
                                      bottomPad: ProfileTab.navBarHeight + 18,
                                    ),
                                  ],
                                );
                              },
                            ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          }
      

        String _formatLastSeen({required bool isOnline, dynamic lastSeen}) {
          if (isOnline) return "Online";

          if (lastSeen is Timestamp) {
            final dt = lastSeen.toDate();
            final now = DateTime.now();
            final diff = now.difference(dt);

            if (diff.inMinutes < 2) return "Last seen just now";
            if (diff.inMinutes < 60) return "Last seen ${diff.inMinutes} min ago";
            if (diff.inHours < 24) return "Last seen ${diff.inHours}h ago";
            return "Last seen ${diff.inDays}d ago";
          }

          return "Offline";
        }

  
}




// ============================================================================
// Top-level presence helper (callable from any class in this file)
// ============================================================================
//
// Returns true if the user is currently online, treating the read
// side as the source of truth. The read is "online" only when the
// stored `isOnline` flag is true AND the stored `lastSeen` is
// within the last [window] minutes (default 2). The 2-minute window
// matches the chat-side presence helper
// (`pingmeeIsOnlineFromUserData` in `chat_display_helpers.dart`)
// and the cloud-side `pruneStaleOnlineUsers` scheduled function.
//
// The staleness check is the safety net for:
//
//   - The client-side `_setOnline(false)` lifecycle observer not
//     firing reliably on every platform (e.g. Android force-stop).
//   - A foreign ProfileTab route popping and accidentally flipping
//     the viewer offline (a previous bug).
//   - The heartbeat (Timer.periodic) being killed because the
//     widget was disposed before the timer could fire.
//
// The check is intentionally cheap (one Timestamp comparison) and
// runs on every read of the `users/{uid}` doc. Firestore streams
// push the latest doc on every write, so this function always sees
// the freshest `isOnline` / `lastSeen` pair.
//
// IMPORTANT: this function MUST live at the top level of the file
// (not inside `_ProfileTabState` or any other class) because the
// three read sites that use it — the profile header, the friends
// list view, and the profile friends screen — are themselves in
// different classes that don't have access to instance methods on
// each other.

bool pingmeeIsUserOnlineFromUserData(
  Map<String, dynamic>? data, {
  Duration window = const Duration(minutes: 2),
}) {
  if (data == null) return false;
  if (data['isOnline'] != true) return false;

  // Tolerate older docs that may have used a different field name.
  final raw = data['lastSeen'] ??
      data['lastSeenAt'] ??
      data['lastActiveAt'] ??
      data['lastOnlineAt'];
  if (raw == null) {
    // No timestamp yet: don't trust a stale "online" flag. Without
    // a heartbeat, the next read will be honest.
    return false;
  }

  DateTime? dt;
  if (raw is DateTime) {
    dt = raw;
  } else if (raw is Timestamp) {
    dt = raw.toDate();
  } else {
    dt = DateTime.tryParse(raw.toString());
  }
  if (dt == null) return false;

  final diff = DateTime.now().difference(dt.toLocal());

  // Future-dated timestamp (clock skew): treat as online.
  if (diff.isNegative) return true;

  return diff < window;
}
class MutualFriendsData {
  final Set<String> myFriendIds;
  final Set<String> profileFriendIds;
  final Set<String> mutualFriendIds;

  const MutualFriendsData({
    required this.myFriendIds,
    required this.profileFriendIds,
    required this.mutualFriendIds,
  });

  int get mutualCount => mutualFriendIds.length;
}

/// ---------------- UI: Header Card ----------------

class _ProfileHeaderCard extends StatelessWidget {
  final String fullName;
  final String username;

  final String intro;
  final String cityLabel;
  final String gender;
  final String pronouns;

  final String joinedLabel;

  final String email;
  final String phone;
  final Map<String, dynamic> socials;
  final String websiteUrl;

  final int friendsCount;
  final int mutualFriendsCount;
  final int communitiesCount;

  final String photoUrl;
  final String coverUrl;
  final String defaultCoverAsset;

  final bool isOnline;
  final String note;

  final VoidCallback onEdit;
  final VoidCallback onCreatePing;
  final VoidCallback onOpenCamera;
  final VoidCallback onShareNote;
  /// Forwarded from the parent so the back arrow on the cover image
  /// can clear the foreign-user uid and switch back to the feed tab
  /// (in MainAppShell) rather than calling Navigator.maybePop() which
  /// does nothing inside an IndexedStack.
  final VoidCallback? onBack;

  final List<String> interests;
  final List<String> skills;
  final String distanceLabel;

  final bool verified;
  final String verificationType;
  final VoidCallback onVerifiedBadgeTap;

  final VoidCallback onMenuTap;

  final String bio;

  final DateTime? birthDate;
  final bool showBirthdayOnProfile;

  final bool hasPendingVerification;
  final VoidCallback onRequestVerification;
  final bool isOwner;
  final VoidCallback onEditCover;

  final VoidCallback onOwnerEditNote;
  final VoidCallback onViewerOpenNote;

  final VoidCallback onAddFriend;
  final VoidCallback onMessage;

  final VoidCallback onRespondToRequest;

  final String friendButtonState;
  final VoidCallback onOpenFriendsTab;
  final VoidCallback onOpenCommunitiesTap;

  

  const _ProfileHeaderCard({
    required this.fullName,
    required this.username,
    required this.intro,
    required this.cityLabel,
    required this.gender,
    required this.pronouns,
    required this.joinedLabel,
    required this.email,
    required this.phone,
    required this.socials,
    required this.websiteUrl,
    required this.friendsCount,
    required this.mutualFriendsCount,
    required this.photoUrl,
    required this.coverUrl,
    required this.defaultCoverAsset,
    required this.isOnline,
    required this.note,
    required this.onEdit,
    required this.onCreatePing,
    required this.onOpenCamera,
    required this.onShareNote,
    required this.interests,
    required this.skills,
    required this.distanceLabel,
    required this.verified,
    required this.onMenuTap,
    required this.bio,
    required this.birthDate,
    required this.showBirthdayOnProfile,
    required this.hasPendingVerification,
    required this.onRequestVerification,
    required this.isOwner,
    required this.onEditCover,
    required this.onOwnerEditNote,
    required this.onViewerOpenNote,
    required this.onAddFriend,
    required this.onMessage,
    required this.onRespondToRequest,
    required this.friendButtonState,
    required this.onOpenFriendsTab,
    required this.verificationType,
    required this.onVerifiedBadgeTap,
    required this.communitiesCount,
    required this.onOpenCommunitiesTap,
    this.onBack,
  });

  String _headerMetaLine() {
    final parts = <String>[];

    final cleanCity = cityLabel.trim();
    final cleanPronouns = pronouns.trim();
    final cleanJoined = joinedLabel.trim();

    if (cleanCity.isNotEmpty && cleanCity != "Near you") {
      parts.add("📍 $cleanCity");
    } else if (cleanCity == "Near you") {
      parts.add("📍 Near you");
    }

    if (cleanPronouns.isNotEmpty) {
      parts.add(cleanPronouns);
    }

    if (cleanJoined.isNotEmpty) {
      parts.add(cleanJoined);
    }

    return parts.join("  ·  ");
  }

  String _distanceVibeFromLabel(String label) {
    final v = label.trim();
    if (v == "—") return "Discovery not set";
    final numStr = v.split(" ").first;
    final miles = int.tryParse(numStr) ?? 0;
    if (miles <= 3) return "Very close";
    if (miles <= 10) return "Nearby";
    if (miles <= 25) return "City-wide";
    if (miles <= 60) return "Regional";
    if (miles <= 120) return "Long-range";
    return "Explorer";
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;
    final hasCover = coverUrl.trim().isNotEmpty;

    const double coverH = 200; // or 220 if you want dramatic
    const double avatarSize = 92;
    const double overlap = 44;

    final safeIntro = intro.trim().isEmpty ? "Add a headline to stand out." : intro.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // COVER + LEFT AVATAR (Twitter-style)
        SizedBox(
          height: coverH + overlap,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28), // adjust if you want more dramatic
                ),
              child: GestureDetector(
                onTap: () => openProfilePhotoViewer(
                  context: context,
                  imageProvider: hasCover ? NetworkImage(coverUrl) : AssetImage(defaultCoverAsset),
                  heroTag: "profile_cover_$username",
                  canEdit: isOwner,
                  onEditTap: isOwner ? onEditCover : null,
                ),
                child: Hero(
                  tag: "profile_cover_$username",
                  child: SizedBox(
                    height: coverH,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (hasCover)
                          Image.network(
                            coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const _CoverErrorState(),
                          )
                        else
                          Image.asset(defaultCoverAsset, fit: BoxFit.cover),

                        Container(color: Colors.black.withOpacity(.10)),

                        // Menu dots (top-right)
                        Positioned(
                          top: 12,
                          left: 12,
                          right: 12,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (!isOwner)
                                GestureDetector(
                                  onTap: () {
                                    if (onBack != null) {
                                      onBack!();
                                    } else {
                                      Navigator.of(context).maybePop();
                                    }
                                  },
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(.90),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          blurRadius: 10,
                                          color: Colors.black.withOpacity(.08),
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      PhosphorIcons.arrowLeft(PhosphorIconsStyle.light),
                                      color: Colors.black.withOpacity(.75),
                                    ),
                                  ),
                                )
                              else
                                const SizedBox(width: 40, height: 40),

                              GestureDetector(
                                onTap: onMenuTap,
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(.90),
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        blurRadius: 10,
                                        color: Colors.black.withOpacity(.08),
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    PhosphorIcons.dotsThreeOutlineVertical(
                                      PhosphorIconsStyle.light,
                                    ),
                                    color: Colors.black.withOpacity(.75),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ✅ Cover edit pencil (bottom-right INSIDE cover)
                        if (isOwner)
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: GestureDetector(
                              onTap: onEditCover,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(.90),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      blurRadius: 10,
                                      color: Colors.black.withOpacity(.10),
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  PhosphorIcons.pencilSimple(PhosphorIconsStyle.light),
                                  color: Colors.black.withOpacity(.75),
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                      ],
                ),
              ),
              ),
              ),
              ),
            

              // Avatar left
              // Avatar left (strictly bounded)
              Positioned(
                left: 16,
                top: coverH - overlap,
                child: SizedBox(
                  width: avatarSize,
                  height: avatarSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Avatar (tap to preview)
                      GestureDetector(
                        onTap: () => openProfilePhotoViewer(
                          context: context,
                          imageProvider: hasPhoto ? NetworkImage(photoUrl) : null,
                          heroTag: "profile_avatar_$username",
                          canEdit: isOwner,
                          onEditTap: isOwner ? onOpenCamera : null,
                        ),
                        child: Hero(
                          tag: "profile_avatar_$username",
                          child: Container(
                            width: avatarSize,
                            height: avatarSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFF2F4F8),
                              border: Border.all(color: Colors.white, width: 4),
                              image: hasPhoto
                                  ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
                                  : null,
                            ),
                            child: !hasPhoto
                                ? Icon(
                                    PhosphorIcons.user(PhosphorIconsStyle.light),
                                    size: 34,
                                    color: Colors.black.withOpacity(.55),
                                  )
                                : null,
                          ),
                        ),
                      ),

                      // Online dot (top-right of avatar)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: isOnline ? AppColors.brandGreen : Colors.black.withOpacity(.22),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),

                      // Camera button (bottom-right of avatar)
                      if (isOwner)
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: GestureDetector(
                            onTap: onOpenCamera,
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: AppColors.brandGreen,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                              ),
                              child: const Icon(
                                Icons.camera_alt_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // ✅ Share note bubble (Facebook-style above avatar)
              Positioned(
                left: 0 + 18,
                top: (coverH - overlap) - 62,
                child: GestureDetector(
                  onTap: () => isOwner ? onOwnerEditNote() : onViewerOpenNote(),
                  child: _ThoughtBubbleFB(
                    text: note,
                    isOwner: isOwner,
                  ),
                ),
              ),
              
            ],
          ),
        ),

        const SizedBox(height: 10),

        


        // Name + @username (free floating)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      fullName.isEmpty ? "Your profile" : fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (verified) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: onVerifiedBadgeTap,
                      child: const Icon(
                        Icons.verified_rounded,
                        size: 18,
                        color: Color(0xFF1D9BF0),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                username.trim().isEmpty ? "@username" : "@$username",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.55),
                ),
              ),

              const SizedBox(height: 12),

              // Intro replaces bio here
              Text(
                safeIntro,
                style: TextStyle(
                  fontFamily: "Nunito",
                  height: 1.25,
                  color: Colors.black.withOpacity(.78),
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),

              

              const SizedBox(height: 16),

              // Basic info row (wrap): City • Gender • Pronouns • Contact Info button
              Builder(
                builder: (context) {
                  final metaLine = _headerMetaLine();

                  if (metaLine.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      metaLine,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.8,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.48),
                        height: 1.2,
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 12),

              // Website row (link icon + website)
              if (websiteUrl.trim().isNotEmpty) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      PhosphorIcons.linkSimpleHorizontal(PhosphorIconsStyle.light),
                      size: 16,
                      color: Colors.black.withOpacity(.55),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: _LinkText(url: websiteUrl.trim()),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],

              // Friends • Joined
              _ProfileStatsStrip(
                isOwner: isOwner,
                friendsCount: friendsCount,
                mutualFriendsCount: mutualFriendsCount,
                communitiesCount: communitiesCount,
                onFriendsTap: onOpenFriendsTab,
                onCommunitiesTap: onOpenCommunitiesTap,
              ),

              const SizedBox(height: 18),

              // Buttons row: Create Ping (green) + Edit (not green)
              // Buttons row (OWNER vs VIEWER)
              _ProfileHeaderActions(
                isOwner: isOwner,
                friendButtonState: friendButtonState,
                onCreatePing: onCreatePing,
                onEdit: onEdit,
                onMenuTap: onMenuTap,
                onMessage: onMessage,
                onAddFriend: onAddFriend,
                onRespondToRequest: onRespondToRequest,
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // Keep your existing sections (distance/interests/skills) below if you still want them:
        // Distance (stays here)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _InfoRow(
            distanceLabel: distanceLabel,
            distanceVibe: _distanceVibeFromLabel(distanceLabel),
          ),
        ),

        const SizedBox(height: 12),

        // More about section (NEW)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _MoreAboutSection(
            fullName: fullName,
            onSeeMore: () => _showMoreAboutSheet(
              context: context,
              fullName: fullName,
              username: username,
              intro: intro,
              cityLabel: cityLabel,
              gender: gender,
              pronouns: pronouns,
              bio: bio,
              interests: interests,
              skills: skills,
              email: email,
              phone: phone,
              socials: socials,
              websiteUrl: websiteUrl,
              birthDate: birthDate,
              showBirthday: showBirthdayOnProfile,
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniInfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MiniInfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.75),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.black.withOpacity(.55)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: Colors.black.withOpacity(.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactInfoButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ContactInfoButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.brandGreen.withOpacity(.10),
          borderRadius: BorderRadius.circular(999),
          // border: Border.all(color: AppColors.brandGreen.withOpacity(.14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              PhosphorIcons.addressBook(PhosphorIconsStyle.light),
              size: 16,
              color: AppColors.brandGreen,
            ),
            const SizedBox(width: 8),
            const Text(
              "Contact info",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: AppColors.brandGreen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showContactInfo({
  required BuildContext context,
  required Map<String, dynamic> socials,
  required String email,
  required String phone,
}) {
  final items = <Widget>[];

  void addLine(String label, String value, IconData icon) {
    if (value.trim().isEmpty) return;

    final isLink = _looksLikeUrl(value);

    items.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: AppColors.brandGreen),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                children: [
                  Text(
                    "$label: ",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withOpacity(.72),
                    ),
                  ),
                  isLink
                      ? _LinkText(url: value, maxLines: 2)
                      : Text(
                          value,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            color: Colors.black.withOpacity(.72),
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

  // socials
  socials.forEach((platform, raw) {
    if (raw is! Map) return;
    final handle = (raw["handle"] ?? "").toString().trim();
    final url = (raw["url"] ?? "").toString().trim();

    final show = url.isNotEmpty ? url : handle;
    if (show.isEmpty) return;

    addLine(
      platform,
      show,
      PhosphorIcons.linkSimpleHorizontal(PhosphorIconsStyle.light),
    );
  });

  // email / phone
  addLine("Email", email, PhosphorIcons.envelopeSimple(PhosphorIconsStyle.light));
  addLine("Phone", phone, PhosphorIcons.phone(PhosphorIconsStyle.light));

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SafeArea(
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Contact info",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    "Nothing added yet.",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                )
              else
                ...items,
            ],
          ),
        ),
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final String distanceLabel;
  final String distanceVibe;

  const _InfoRow({
    required this.distanceLabel,
    required this.distanceVibe,
  });

  @override
  Widget build(BuildContext context) {
    final hasDistance = distanceLabel.trim() != "—";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: Colors.black.withOpacity(.14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.10),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withOpacity(.08),
              ),
            ),
            child: const Icon(
              Icons.radar_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Discovery radius",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: Colors.white,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  hasDistance
                      ? "$distanceLabel • $distanceVibe"
                      : "Set your discovery radius",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: Colors.white.withOpacity(.68),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------- Events ----------------
class _EventsTab extends StatelessWidget {
  final String uid;
  final double bottomPad;

  const _EventsTab({
    super.key,
    required this.uid,
    required this.bottomPad,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, bottomPad + 6),
      child: _EmptyState(
        icon: PhosphorIcons.ticket(PhosphorIconsStyle.light),
        title: "No events yet",
        subtitle: "Events created or joined by this user will show here.",
      ),
    );
  }
}

class _TasksTab extends StatelessWidget {
  final String uid;
  final double bottomPad;

  const _TasksTab({
    super.key,
    required this.uid,
    required this.bottomPad,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, bottomPad + 6),
      child: _EmptyState(
        icon: PhosphorIcons.checkSquare(PhosphorIconsStyle.light),
        title: "No tasks yet",
        subtitle: "Tasks tied to this profile will show here.",
      ),
    );
  }
}

class _MomentsTab extends StatefulWidget {
  final String uid;
  final double bottomPad;
  final void Function(String authorUid)? onOpenProfile;

  const _MomentsTab({
    super.key,
    required this.uid,
    required this.bottomPad,
    this.onOpenProfile,
  });

  @override
  State<_MomentsTab> createState() => _MomentsTabState();
}

class _MomentsTabState extends State<_MomentsTab> {
  final _feedService = PingmeeFeedService();

  List<Map<String, dynamic>> _moments = [];
  List<Map<String, dynamic>> _pinned = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _feedService.loadMyTimelineMoments(limit: 50);
      if (!mounted) return;
      final all = List<Map<String, dynamic>>.from(res.moments);
      // Filter to moments authored by the profile uid.
      final owned = all.where((m) {
        final authorUid = (m["authorUid"] ?? "").toString();
        return authorUid == widget.uid;
      }).toList();
      // Split pinned vs not.
      final pinned = owned
          .where((m) => m["pinned"] == true)
          .toList()
        ..sort((a, b) {
          final ta = a["pinnedAt"]?.toString() ?? "";
          final tb = b["pinnedAt"]?.toString() ?? "";
          return tb.compareTo(ta);
        });
      final rest = owned
          .where((m) => m["pinned"] != true)
          .toList()
        ..sort((a, b) {
          final ta = a["time"]?.toString() ?? "";
          final tb = b["time"]?.toString() ?? "";
          return tb.compareTo(ta);
        });
      setState(() {
        _pinned = pinned;
        _moments = rest;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load Moments.";
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, widget.bottomPad + 6),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, widget.bottomPad + 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _error!,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                color: Color(0xFFB42318),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _load,
              child: const Text("Try again"),
            ),
          ],
        ),
      );
    }
    if (_pinned.isEmpty && _moments.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, widget.bottomPad + 6),
        child: _EmptyState(
          icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
          title: "No moments yet",
          subtitle: "Moments shared by this user will show here.",
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, widget.bottomPad + 24),
        children: [
          if (_pinned.isNotEmpty) ...[
            const _SectionDivider(label: "Pinned"),
            const SizedBox(height: 8),
            for (final m in _pinned)
              _MomentListTile(
                moment: m,
                pinned: true,
                onOpenProfile: widget.onOpenProfile,
              ),
            const SizedBox(height: 16),
          ],
          if (_moments.isNotEmpty) ...[
            const _SectionDivider(label: "All Moments"),
            const SizedBox(height: 8),
            for (final m in _moments)
              _MomentListTile(
                moment: m,
                pinned: false,
                onOpenProfile: widget.onOpenProfile,
              ),
          ],
        ],
      ),
    );
  }
}

// Lightweight section header for the moments tab.
class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Colors.black.withOpacity(.55),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            height: 1,
            color: Colors.black.withOpacity(.08),
          ),
        ),
      ],
    );
  }
}

// Compact moment tile for the profile moments tab. Renders text
// + small thumbnail strip. Tapping the tile currently just
// opens the avatar/name profile via onOpenProfile if provided.
class _MomentListTile extends StatelessWidget {
  final Map<String, dynamic> moment;
  final bool pinned;
  final void Function(String authorUid)? onOpenProfile;

  const _MomentListTile({
    required this.moment,
    required this.pinned,
    this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    final text = (moment["text"] ?? "").toString();
    final authorUid = (moment["authorUid"] ?? "").toString();
    final media = moment["media"];
    final mediaCount = media is List ? (media as List).length : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpenProfile == null
              ? null
              : () => onOpenProfile!(authorUid),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black.withOpacity(.07)),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (text.isNotEmpty)
                  Text(
                    text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      height: 1.32,
                      color: Color(0xDD000000),
                    ),
                  ),
                if (text.isNotEmpty && mediaCount > 0)
                  const SizedBox(height: 8),
                if (mediaCount > 0)
                  Row(
                    children: [
                      const Icon(
                        PhosphorIcons.images(
                            PhosphorIconsStyle.regular),
                        size: 14,
                        color: Color(0xCC000000),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        mediaCount == 1
                            ? "1 media"
                            : "$mediaCount media",
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12,
                          color: Color(0xCC000000),
                        ),
                      ),
                    ],
                  ),
                if (pinned) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        PhosphorIcons.pushPinSimple(
                            PhosphorIconsStyle.fill),
                        size: 12,
                        color: Colors.black.withOpacity(.55),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "Pinned",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// ---------------- Tabs ----------------

class _PingsTab extends StatefulWidget {
  final String uid;
  final PingVisibilityContext visibilityContext;

  const _PingsTab({
    super.key,
    required this.uid,
    required this.visibilityContext,
  });

  @override
  State<_PingsTab> createState() => _PingsTabState();
}

class _PingsTabState extends State<_PingsTab>
    with SingleTickerProviderStateMixin {
  TabController? _innerTabs;
  late final bool _isOwner;
  Timer? _ticker;
  DateTime _now = DateTime.now();

  // bool get _isOwner => FirebaseAuth.instance.currentUser?.uid == widget.uid;

  @override
  void initState() {
    super.initState();
    _isOwner = widget.visibilityContext.viewerUid == widget.uid;

    if (_isOwner) {
      _innerTabs = TabController(length: 2, vsync: this);
    }

    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isOwner) {
      return _buildCreatedTab();
    }

    return Column(
      children: [
        _GlassTabs(
          controller: _innerTabs!,
          dense: true,
          items: const [
            _TabSpec(
              label: "Created",
              icon: PhosphorIcons.broadcast,
            ),
            _TabSpec(
              label: "Saved",
              icon: PhosphorIcons.bookmarkSimple,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TabBarView(
            controller: _innerTabs!,
            physics: const BouncingScrollPhysics(),
            children: [
              _buildCreatedTab(),
              _buildSavedTab(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  ({IconData icon, Color color}) _getIconForCategory(String category) {
    final c = category.toLowerCase().trim();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.light),
        color: const Color(0xFF6C5CE7),
      );
    } else if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.light),
        color: const Color(0xFFE74C3C),
      );
    } else if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.light),
        color: const Color(0xFF9B59B6),
      );
    } else if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.light),
        color: const Color(0xFF3498DB),
      );
    } else if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.light),
        color: const Color(0xFFE67E22),
      );
    } else if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.light),
        color: const Color(0xFF1ABC9C),
      );
    } else if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.light),
        color: const Color(0xFFF39C12),
      );
    } else if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.light),
        color: const Color(0xFFE91E63),
      );
    } else if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.light),
        color: const Color(0xFFFFB800),
      );
    } else if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.light),
        color: const Color(0xFFFF6B6B),
      );
    } else if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.light),
        color: const Color(0xFFFF1744),
      );
    } else if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.light),
        color: const Color(0xFF2196F3),
      );
    }

    final hash = category.hashCode;
    final customColors = [
      const Color(0xFF00BCD4),
      const Color(0xFF009688),
      const Color(0xFF8BC34A),
      const Color(0xFFFF5722),
      const Color(0xFF673AB7),
      const Color(0xFFE91E63),
    ];
    final customColor = customColors[hash.abs() % customColors.length];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
      color: customColor,
    );
  }

  Query<Map<String, dynamic>> _buildCreatedPingsQuery() {
    final db = FirebaseFirestore.instance;
    final isOwnerViewing = widget.visibilityContext.viewerUid == widget.uid;
    final isFriendViewing =
        widget.visibilityContext.viewerFriendIds.contains(widget.uid);
    final isVerifiedViewing = widget.visibilityContext.viewerVerified;

    if (isOwnerViewing) {
      return db
          .collection("pings")
          .where("creatorId", isEqualTo: widget.uid)
          .orderBy("createdAtLocal", descending: true);
    }

    final allowedPrivacies = <String>["public"];
    if (isFriendViewing) allowedPrivacies.add("friends");
    if (isVerifiedViewing) allowedPrivacies.add("verified");

    if (allowedPrivacies.length == 1) {
      return db
          .collection("pings")
          .where("creatorId", isEqualTo: widget.uid)
          .where("privacy", isEqualTo: allowedPrivacies.first)
          .orderBy("createdAtLocal", descending: true);
    }

    return db
        .collection("pings")
        .where("creatorId", isEqualTo: widget.uid)
        .where("privacy", whereIn: allowedPrivacies)
        .orderBy("createdAtLocal", descending: true);
  }

  bool _isStillActive(Map<String, dynamic> d) {
    final rawStatus = (d["status"] ?? "active").toString().trim().toLowerCase();
    if (rawStatus == "ended" || rawStatus == "expired") return false;

    final endsAt = (d["endsAt"] is Timestamp)
        ? (d["endsAt"] as Timestamp).toDate()
        : null;

    if (endsAt != null && !endsAt.isAfter(_now)) return false;

    return true;
  }

  String _prettyPrivacy(String p) {
    switch (p) {
      case "verified":
        return "Verified";
      case "friends":
        return "Friends";
      default:
        return "Public";
    }
  }

  String _prettyStatus(String s) {
    if (s == "active") return "Active";
    if (s == "ended") return "Ended";
    return s;
  }

  String _endsLabel(DateTime? endsAt) {
    if (endsAt == null) return "Active";

    final diff = endsAt.difference(_now);

    if (diff.inSeconds <= 0) return "Expired";
    if (diff.inMinutes < 60) return "Ends in ${diff.inMinutes}m";
    if (diff.inHours < 24) return "Ends in ${diff.inHours}h";
    return "Ends in ${diff.inDays}d";
  }

  Widget _buildPingTile({
    required BuildContext context,
    required Map<String, dynamic> d,
    required String pingId,
    String? badgeText,
    String? subtitleOverride,
  }) {
    final title = (d["title"] ?? "Untitled").toString();
    final privacy = (d["privacy"] ?? "public").toString();
    final rawStatus = (d["status"] ?? "active").toString();
    final endsAt = (d["endsAt"] is Timestamp)
        ? (d["endsAt"] as Timestamp).toDate()
        : null;

    final derivedStatus =
        (endsAt != null && endsAt.isBefore(_now)) ? "ended" : rawStatus;

    final mediaCount = (d["mediaCount"] is num)
        ? (d["mediaCount"] as num).toInt()
        : 0;

    final participantCount = (d["participantCount"] is num)
        ? (d["participantCount"] as num).toInt()
        : 1;

    final category = (d["category"] ?? "default").toString();
    final categoryIcon = _getIconForCategory(category);

    final subtitle =
        subtitleOverride ??
        "${_prettyPrivacy(privacy)} • ${_prettyStatus(derivedStatus)} • ${formatCompactCount(participantCount)} joined • ${formatCompactCount(mediaCount)} media";

    return InkWell(
      borderRadius: BorderRadius.circular(26),
      onTap: () async {
        HapticFeedback.selectionClick();
        await openPingDetailsSheet(
          context: context,
          pingId: pingId,
        );
      },
      child: _GlassCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: categoryIcon.color.withOpacity(.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                categoryIcon.icon,
                color: categoryIcon.color,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      if (badgeText != null) ...[
                        const SizedBox(width: 8),
                        _MiniPill(text: badgeText),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      color: Colors.black.withOpacity(.55),
                      fontWeight: FontWeight.w500,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              PhosphorIcons.caretRight(PhosphorIconsStyle.light),
              size: 18,
              color: Colors.black.withOpacity(.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreatedTab() {
    final createdQ = _buildCreatedPingsQuery();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: createdQ.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, ProfileTab.navBarHeight + 24),
            child: _SectionListSkeleton(),
          );
        }

        if (snap.hasError) {
          final msg = snap.error.toString();
          return _EmptyState(
            icon: PhosphorIcons.warningCircle(PhosphorIconsStyle.light),
            title: "Couldn’t load pings",
            subtitle: msg.contains("permission-denied")
                ? "Firestore rules still blocked this query."
                : "Please try again.",
          );
        }

        final docsAll = (snap.data?.docs ?? []).toList();

        final docs = docsAll.where((doc) {
          final d = doc.data();
          return PingVisibility.canViewerSeeActivePing(
            ping: d,
            context: widget.visibilityContext,
            now: _now,
          );
        }).toList();

        if (docs.isEmpty) {
          return _EmptyState(
            icon: PhosphorIcons.broadcast(PhosphorIconsStyle.bold),
            title: _isOwner ? "No live pings yet" : "No visible pings yet",
            subtitle: _isOwner
                ? "Create a ping when something is happening around you. Keep it useful, not noisy."
                : "When this profile shares public pings, they’ll appear here.",
          );
        }

        return ListView.separated(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            18,
            16,
            ProfileTab.navBarHeight + 24,
          ),
          itemCount: docs.length + 1,
          separatorBuilder: (_, i) =>
              i == 0 ? const SizedBox(height: 12) : const SizedBox(height: 10),
          itemBuilder: (_, i) {
            if (i == 0) {
              final label = _isOwner ? "Pings" : "Visible pings";

              return Row(
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    "${docs.length}",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withOpacity(.48),
                    ),
                  ),
                ],
              );
            }

            final doc = docs[i - 1];
            return _buildPingTile(
              context: context,
              d: doc.data(),
              pingId: doc.id,
            );
          },
        );
      },
    );
  }

  Widget _buildSavedTab() {
    final savedQ = FirebaseFirestore.instance
        .collection("users")
        .doc(widget.uid)
        .collection("saved_pings")
        .orderBy("savedAt", descending: true)
        .limit(30);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: savedQ.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, ProfileTab.navBarHeight + 24),
            child: _SectionListSkeleton(),
          );
        }

        if (snap.hasError) {
          final msg = snap.error.toString();
          return _EmptyState(
            icon: PhosphorIcons.warningCircle(PhosphorIconsStyle.light),
            title: "Couldn’t load saved pings",
            subtitle: msg.contains("permission-denied")
                ? "Firestore rules blocked saved pings."
                : "Please try again.",
          );
        }

        final docs = (snap.data?.docs ?? [])
            .where((doc) => _isStillActive(doc.data()))
            .toList();

        if (docs.isEmpty) {
          return _EmptyState(
            icon: PhosphorIcons.bookmarkSimple(PhosphorIconsStyle.bold),
            title: "Nothing saved yet",
            subtitle: "Save pings you want to revisit. The good ones shouldn’t disappear without a trace.",
          );
        }

        return ListView.separated(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            24,
            16,
            ProfileTab.navBarHeight + 24,
          ),
          itemCount: docs.length + 1,
          separatorBuilder: (_, i) =>
              i == 0 ? const SizedBox(height: 12) : const SizedBox(height: 10),
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  "Saved pings stay here until they expire.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
              );
            }

            final doc = docs[i - 1];
            final d = doc.data();

            final privacy = (d["privacy"] ?? "public").toString();
            final participantCount = (d["participantCount"] is num)
                ? (d["participantCount"] as num).toInt()
                : 1;
            final mediaCount = (d["mediaCount"] is num)
                ? (d["mediaCount"] as num).toInt()
                : 0;
            final endsAt = (d["endsAt"] is Timestamp)
                ? (d["endsAt"] as Timestamp).toDate()
                : null;

            final subtitle =
                "${_endsLabel(endsAt)} • ${_prettyPrivacy(privacy)} • ${formatCompactCount(participantCount)} joined • ${formatCompactCount(mediaCount)} media";

            return _buildPingTile(
              context: context,
              d: d,
              pingId: doc.id,
              badgeText: "Saved",
              subtitleOverride: subtitle,
            );
          },
        );
      },
    );
  }
}

class _FriendsTab extends StatefulWidget {
  final String uid;
  final String viewerUid;
  final Set<String> mutualFriendIds;
  final double bottomPad;
  final bool isOwner;

  const _FriendsTab({
    required this.uid,
    required this.viewerUid,
    required this.mutualFriendIds,
    required this.bottomPad,
    required this.isOwner,
  });

  @override
  State<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<_FriendsTab>
    with SingleTickerProviderStateMixin {
  late final TabController _innerTabs;
  final TextEditingController _searchCtrl = TextEditingController();

  final ValueNotifier<String> _searchText = ValueNotifier("");
  final FocusNode _searchFocus = FocusNode();
  final Map<String, Set<String>> _friendIdsMemory = {};
  late final Future<Set<String>> _viewerFriendIdsFuture;

  @override
  void initState() {
    super.initState();
    _innerTabs = TabController(length: widget.isOwner ? 1 : 2, vsync: this);

    _searchCtrl.addListener(() {
      _searchText.value = _searchCtrl.text.trim().toLowerCase();
    });
  }

  @override
  void dispose() {
    _innerTabs.dispose();
    _searchCtrl.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection("users").doc(widget.uid);
    final friendsSub = userRef.collection("friends").limit(80);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, userSnap) {
        if (!userSnap.hasData || userSnap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, ProfileTab.navBarHeight + 24),
            child: _SectionListSkeleton(),
          );
        }

        final userData = userSnap.data?.data() ?? {};
        final friendIds = List<String>.from(userData["friendIds"] ?? []);

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: friendsSub.snapshots(),
          builder: (context, subSnap) {
            if (!subSnap.hasData || subSnap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, ProfileTab.navBarHeight + 24),
                child: _SectionListSkeleton(),
              );
            }

            final subDocs = subSnap.data?.docs ?? [];
            final idsFromSub = subDocs
                .map((d) => (d.data()["friendId"] ?? "").toString())
                .where((x) => x.isNotEmpty)
                .toList();

            final ids = {...friendIds, ...idsFromSub}.toList();
            final mutualIds = ids
                .where((id) => widget.mutualFriendIds.contains(id))
                .toList();

            if (ids.isEmpty) {
              return _EmptyState(
                icon: PhosphorIcons.usersThree(PhosphorIconsStyle.light),
                title: "No friends yet",
                subtitle: widget.isOwner
                    ? "Start connecting and your network will show here."
                    : "When this user connects with people, they’ll show up here.",
              );
            }

            return Column(
              children: [
                _GlassCard(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            PhosphorIcons.usersThree(PhosphorIconsStyle.light),
                            color: Colors.black.withOpacity(.55),
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                Text(
                                  "${formatCompactCount(ids.length)} ${ids.length == 1 ? "connection" : "connections"}",
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (!widget.isOwner)
                                  Text(
                                    "• ${formatCompactCount(widget.mutualFriendIds.length)} ${widget.mutualFriendIds.length == 1 ? "mutual connection" : "mutual connections"}",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.brandGreen,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _FriendsSearchField(controller: _searchCtrl),
                      const SizedBox(height: 12),
                      _GlassTabs(
                        controller: _innerTabs,
                        dense: true,
                        items: widget.isOwner
                            ? const [
                                _TabSpec(
                                  label: "All",
                                  icon: PhosphorIcons.usersThree,
                                ),
                              ]
                            : const [
                                _TabSpec(
                                  label: "All",
                                  icon: PhosphorIcons.usersThree,
                                ),
                                _TabSpec(
                                  label: "Mutuals",
                                  icon: PhosphorIcons.userList,
                                ),
                              ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TabBarView(
                    controller: _innerTabs,
                    physics: const BouncingScrollPhysics(),
                    children: widget.isOwner
                        ? [
                            _FriendsListView(
                              ids: ids,
                              viewerUid: widget.viewerUid,
                              mutualFriendIds: widget.mutualFriendIds,
                              bottomPad: widget.bottomPad,
                              searchText: _searchText.value,
                            ),
                          ]
                        : [
                            _FriendsListView(
                              ids: ids,
                              viewerUid: widget.viewerUid,
                              mutualFriendIds: widget.mutualFriendIds,
                              bottomPad: widget.bottomPad,
                              searchText: _searchText.value,
                            ),
                            _FriendsListView(
                              ids: mutualIds,
                              viewerUid: widget.viewerUid,
                              mutualFriendIds: widget.mutualFriendIds,
                              bottomPad: widget.bottomPad,
                              searchText: _searchText.value,
                              emptyTitle: "No mutual friends",
                              emptySubtitle:
                                  "Mutual friends between you and this user will show here.",
                            ),
                          ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _FriendsSearchField extends StatelessWidget {
  final TextEditingController controller;

  const _FriendsSearchField({
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(
        fontFamily: "Nunito",
        fontWeight: FontWeight.w500,
        fontSize: 13.5,
      ),
      decoration: InputDecoration(
        hintText: "Search connections",
        hintStyle: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w500,
          color: Colors.black.withOpacity(.42),
        ),
        prefixIcon: Icon(
          PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
          size: 18,
          color: Colors.black.withOpacity(.45),
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(.78),
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: AppColors.brandGreen.withOpacity(.55),
          ),
        ),
      ),
    );
  }
}

class _FriendsListView extends StatelessWidget {
  final List<String> ids;
  final String viewerUid;
  final Set<String> mutualFriendIds;
  final double bottomPad;
  final String searchText;
  final String emptyTitle;
  final String emptySubtitle;

  const _FriendsListView({
    required this.ids,
    required this.viewerUid,
    required this.mutualFriendIds,
    required this.bottomPad,
    required this.searchText,
    this.emptyTitle = "No friends found",
    this.emptySubtitle = "Try a different name or username.",
  });

  @override
  Widget build(BuildContext context) {
    if (ids.isEmpty) {
      return _EmptyState(
        icon: PhosphorIcons.usersThree(PhosphorIconsStyle.light),
        title: emptyTitle,
        subtitle: emptySubtitle,
      );
    }

    return ListView.builder(
      primary: false,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(0, 0, 0, bottomPad),
      itemCount: ids.length,
      itemBuilder: (_, i) {
        final fid = ids[i];
        final isMutual = mutualFriendIds.contains(fid);
        final isSelf = fid == viewerUid;
        final ref = FirebaseFirestore.instance.collection("users").doc(fid);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: ref.snapshots(),
          builder: (context, s) {
            final d = s.data?.data() ?? {};
            final name = (d["fullName"] ?? "Connection").toString();
            final user = (d["username"] ?? "").toString();
            final pic = (d["photoUrl"] ?? "").toString();
            final online = pingmeeIsUserOnlineFromUserData(d);

            final haystack = "$name $user".toLowerCase().trim();

            if (searchText.isNotEmpty && !haystack.contains(searchText)) {
              return const SizedBox.shrink();
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProfileTab(profileUid: fid),
                    ),
                  );
                },
                child: _GlassCard(
                  child: Row(
                    children: [
                      _MiniAvatar(photoUrl: pic),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isMutual && !isSelf) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreen.withOpacity(.12),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      "Mutual",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11.5,
                                        color: AppColors.brandGreen,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              user.isEmpty ? "" : "@$user",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      _Dot(online: online),
                      const SizedBox(width: 8),
                      Icon(
                        PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                        size: 18,
                        color: Colors.black.withOpacity(.35),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MediaTab extends StatelessWidget {
  final String uid;
  final double bottomPad;
  const _MediaTab({required this.uid, required this.bottomPad});

  @override
  Widget build(BuildContext context) {
    return _MediaInner(bottomPad: bottomPad);
  }
}


class _MediaInner extends StatefulWidget {
  final double bottomPad;
  const _MediaInner({required this.bottomPad});

  @override
  State<_MediaInner> createState() => _MediaInnerState();
}



class _MediaInnerState extends State<_MediaInner> with SingleTickerProviderStateMixin {
  late final TabController _inner = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GlassTabs(
          controller: _inner,
          dense: true,
          items: const [
            _TabSpec(
              label: "Moments",
              icon: PhosphorIcons.sparkle,
            ),
            _TabSpec(
              label: "Ping media",
              icon: PhosphorIcons.images,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TabBarView(
            controller: _inner,
            physics: const BouncingScrollPhysics(),
            children: [
              _EmptyState(
                icon: PhosphorIcons.newspaper(PhosphorIconsStyle.light),
                title: "No moments yet",
                subtitle: "Once moments are live, your posts will show here.",
              ),
              _EmptyState(
                icon: PhosphorIcons.images(PhosphorIconsStyle.light),
                title: "No ping media yet",
                subtitle: "Add media when creating pings to build your profile.",
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// ---------------- Components ----------------

class _TabSpec {
  final String label;
  final IconData Function(PhosphorIconsStyle style) icon;

  const _TabSpec({
    required this.label,
    required this.icon,
  });
}

class _GlassTabs extends StatelessWidget {
  final TabController controller;
  final List<_TabSpec> items;
  final bool dense;

  const _GlassTabs({
    required this.controller,
    required this.items,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = dense ? 16.0 : 18.0;
    final padding = dense
        ? const EdgeInsets.all(4)
        : const EdgeInsets.all(5);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(radius + 2),
      ),
      child: TabBar(
        controller: controller,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        splashBorderRadius: BorderRadius.circular(radius),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicator: BoxDecoration(
          color: const Color(0xFFE4E7EB),
          borderRadius: BorderRadius.circular(radius),
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
        labelColor: Colors.black87,
        unselectedLabelColor: Colors.black87,
        labelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        tabs: items
            .map(
              (item) => Tab(
                height: dense ? 40 : 46,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      item.icon(PhosphorIconsStyle.light),
                      size: dense ? 16 : 17,
                      color: Colors.black87,
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.78),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(.55)),
            boxShadow: [
              BoxShadow(
                blurRadius: 22,
                offset: const Offset(0, 14),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        18,
        34,
        18,
        ProfileTab.navBarHeight + 34,
      ),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F7FA),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(23),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                      color: Colors.black.withOpacity(.10),
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  color: Colors.white,
                  size: 29,
                ),
              ),

              const SizedBox(height: 16),

              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 18.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                  height: 1.15,
                ),
              ),

              const SizedBox(height: 7),

              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.6,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.52),
                  height: 1.35,
                ),
              ),

              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                Material(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    onTap: onAction,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      child: Text(
                        actionLabel!,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _IconSquare extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _IconSquare({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(.06)),
        ),
        child: Icon(icon, color: Colors.black.withOpacity(.60)),
      ),
    );
  }
}

class _ActionDotsButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ActionDotsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 50,
      height: 50,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.black.withOpacity(.10)),
          backgroundColor: Colors.white.withOpacity(.75),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Icon(
          PhosphorIcons.dotsThreeOutline(PhosphorIconsStyle.light),
          size: 20,
          color: Colors.black.withOpacity(.72),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bg;
  final Color fg;

  const _Pill({
    required this.icon,
    required this.text,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: Colors.white.withOpacity(.25)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Text(
                text,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStatusPill extends StatelessWidget {
  final String text;
  const _MiniStatusPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final online = text == "Online";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: online
            ? AppColors.brandGreen.withOpacity(.14)
            : Colors.black.withOpacity(.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: online
              ? AppColors.brandGreen.withOpacity(.18)
              : Colors.black.withOpacity(.06),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: online ? AppColors.brandGreen : Colors.black.withOpacity(.60),
        ),
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SmallChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.75),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.black.withOpacity(.55)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Colors.black.withOpacity(.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionPill extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final Widget child;

  const _SectionPill({
    required this.icon,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.78),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withOpacity(.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _SectionWrap extends StatelessWidget {
  final Color tint;
  final Color border;
  final List<Widget> children;

  const _SectionWrap({
    required this.tint,
    required this.border,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: children,
      ),
    );
  }
}

class _EmptyHintChip extends StatelessWidget {
  final String text;
  const _EmptyHintChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.brandGreen.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
        // border: Border.all(color: AppColors.brandGreen.withOpacity(.14)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: AppColors.brandGreen,
        ),
      ),
    );
  }
}

class _ThoughtBubbleFB extends StatelessWidget {
  final String text;
  final bool isOwner;

  const _ThoughtBubbleFB({
    required this.text,
    required this.isOwner,
  });

  @override
  Widget build(BuildContext context) {
    final t = text.trim();
    final isEmpty = t.isEmpty;

    final display = isEmpty
        ? (isOwner ? "Share a thought…" : "No thought yet.")
        : t;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Transform.rotate(
          angle: -0.03,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF4E77D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black.withOpacity(.08)),
              boxShadow: [
                BoxShadow(
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Text(
              display,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.patrickHand(
                fontSize: 17,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: isEmpty
                    ? Colors.black.withOpacity(.45)
                    : Colors.black.withOpacity(.82),
              ),
            ),
          ),
        ),

        Positioned(
          top: -8,
          left: 18,
          child: Transform.rotate(
            angle: -0.20,
            child: Container(
              width: 34,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.55),
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                    color: Colors.black.withOpacity(.08),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GreenWallPattern extends StatelessWidget {
  const _GreenWallPattern();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GreenWallPainter(),
    );
  }
}

class _GreenWallPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withOpacity(.07)
      ..strokeWidth = 1.2;

    const gap = 34.0;

    for (double y = 0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    for (double x = 0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StickyWall extends StatelessWidget {
  final Widget child;
  const _StickyWall({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 420),
      decoration: BoxDecoration(
        color: const Color(0xFF8BCF7B),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _GreenWallPattern()),
          Center(child: Padding(
            padding: const EdgeInsets.all(20),
            child: child,
          )),
        ],
      ),
    );
  }
}

class _EditableStickyNote extends StatelessWidget {
  final TextEditingController controller;
  const _EditableStickyNote({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.03,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 290),
            padding: const EdgeInsets.fromLTRB(18, 26, 18, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF3E46F),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  blurRadius: 20,
                  offset: const Offset(0, 14),
                  color: Colors.black.withOpacity(.16),
                ),
              ],
            ),
            child: TextField(
              controller: controller,
              maxLines: 8,
              maxLength: 80,
              autofocus: true,
              cursorColor: Colors.black87,
              style: GoogleFonts.patrickHand(
                fontSize: 25,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: Colors.black.withOpacity(.82),
              ),
              decoration: InputDecoration(
                hintText: "I’m here.\nSay something real...",
                hintStyle: GoogleFonts.patrickHand(
                  fontSize: 24,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(.35),
                ),
                border: InputBorder.none,
                counterStyle: const TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  color: Colors.black54,
                ),
              ),
            ),
          ),

          Positioned(
            top: -10,
            left: 22,
            child: Transform.rotate(
              angle: -0.24,
              child: _TapePiece(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickyDisplayCard extends StatelessWidget {
  final String text;
  const _StickyDisplayCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.04,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 320),
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
            decoration: BoxDecoration(
              color: const Color(0xFFF3E46F),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  blurRadius: 22,
                  offset: const Offset(0, 14),
                  color: Colors.black.withOpacity(.16),
                ),
              ],
            ),
            child: Text(
              text,
              style: GoogleFonts.patrickHand(
                fontSize: 28,
                height: 1.03,
                fontWeight: FontWeight.w700,
                color: Colors.black.withOpacity(.84),
              ),
            ),
          ),

          Positioned(
            top: -10,
            left: 26,
            child: Transform.rotate(
              angle: -0.20,
              child: _TapePiece(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TapePiece extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.58),
        borderRadius: BorderRadius.circular(3),
        boxShadow: [
          BoxShadow(
            blurRadius: 5,
            offset: const Offset(0, 1),
            color: Colors.black.withOpacity(.10),
          ),
        ],
      ),
    );
  }
}

class _DoodleStar extends StatelessWidget {
  final Color color;
  final double size;

  const _DoodleStar({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.auto_awesome, color: color, size: size);
  }
}

class _DoodleHeart extends StatelessWidget {
  final Color color;
  final double size;

  const _DoodleHeart({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.favorite_border_rounded, color: color, size: size);
  }
}

class _BubbleDot extends StatelessWidget {
  final double size;
  const _BubbleDot({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black.withOpacity(.06)),
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            offset: const Offset(0, 6),
            color: Colors.black.withOpacity(.06),
          ),
        ],
      ),
    );
  }
}

class _NotesIntroArtwork extends StatelessWidget {
  const _NotesIntroArtwork();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 190,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF16C784),
            Color(0xFF16C784),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 18,
            left: 18,
            child: _DoodleStar(
              color: Colors.white.withOpacity(.85),
              size: 30,
            ),
          ),
          Positioned(
            top: 22,
            right: 20,
            child: _DoodleHeart(
              color: const Color(0xFFF6F09A),
              size: 28,
            ),
          ),
          Positioned(
            bottom: 18,
            left: 24,
            child: _DoodleStar(
              color: const Color(0xFFD8FF88),
              size: 34,
            ),
          ),

          // your custom note image
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Center(
                child: Transform.rotate(
                  angle: -0.05,
                  child: Image.asset(
                    "assets/images/note.png",
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeaderActions extends StatelessWidget {
  const _ProfileHeaderActions({
    required this.isOwner,
    required this.friendButtonState,
    required this.onCreatePing,
    required this.onEdit,
    required this.onMenuTap,
    required this.onMessage,
    required this.onAddFriend,
    required this.onRespondToRequest,
  });

  final bool isOwner;
  final String friendButtonState;
  final VoidCallback onCreatePing;
  final VoidCallback onEdit;
  final VoidCallback onMenuTap;
  final VoidCallback onMessage;
  final VoidCallback onAddFriend;
  final VoidCallback onRespondToRequest;

  String get _friendLabel {
    switch (friendButtonState) {
      case "loading":
        return "Loading";
      case "friends":
        return "Connected";
      case "incoming":
        return "Respond";
      case "outgoing":
        return "Requested";
      case "none":
      default:
        return "Connect";
    }
  }

  IconData get _friendIcon {
    switch (friendButtonState) {
      case "friends":
        return PhosphorIcons.usersThree(PhosphorIconsStyle.bold);
      case "incoming":
        return PhosphorIcons.userCheck(PhosphorIconsStyle.bold);
      case "outgoing":
        return PhosphorIcons.clock(PhosphorIconsStyle.bold);
      case "none":
      default:
        return PhosphorIcons.userPlus(PhosphorIconsStyle.bold);
    }
  }

  VoidCallback? get _friendTap {
    if (friendButtonState == "loading") return null;

    switch (friendButtonState) {
      case "none":
      case "outgoing":
        return onAddFriend;
      case "incoming":
      case "friends":
        return onRespondToRequest;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isOwner) {
      return Row(
        children: [
          Expanded(
            child: _ProfileActionButton(
              label: "Create ping",
              icon: PhosphorIcons.plus(PhosphorIconsStyle.bold),
              onTap: onCreatePing,
              primary: true,
            ),
          ),

          const SizedBox(width: 10),

          Expanded(
            child: _ProfileActionButton(
              label: "Edit profile",
              icon: PhosphorIcons.pencilSimple(PhosphorIconsStyle.bold),
              onTap: onEdit,
              primary: false,
            ),
          ),

          const SizedBox(width: 10),

          _ActionDotsButton(onTap: onMenuTap),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: _ProfileActionButton(
            label: "Message",
            icon: PhosphorIcons.chatCircleDots(PhosphorIconsStyle.bold),
            onTap: onMessage,
            primary: true,
          ),
        ),

        const SizedBox(width: 10),

        Expanded(
          child: _ProfileActionButton(
            label: _friendLabel,
            icon: _friendIcon,
            onTap: _friendTap,
            primary: false,
            loading: friendButtonState == "loading",
          ),
        ),

        const SizedBox(width: 10),

        _ActionDotsButton(onTap: onMenuTap),
      ],
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.primary,
    this.loading = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final bg = primary ? Colors.black : const Color(0xFFF5F7FA);
    final fg = primary ? Colors.white : const Color(0xFF111827);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        splashColor: primary
            ? Colors.white.withOpacity(.08)
            : Colors.black.withOpacity(.035),
        highlightColor: primary
            ? Colors.white.withOpacity(.04)
            : Colors.black.withOpacity(.018),
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        fg.withOpacity(.70),
                      ),
                    ),
                  )
                else
                  Icon(
                    icon,
                    size: 18,
                    color: fg,
                  ),

                const SizedBox(width: 8),

                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _IntroLine({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.brandGreen, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: Colors.black.withOpacity(.72),
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String photoUrl;
  const _MiniAvatar({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final has = photoUrl.trim().isNotEmpty;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF2F4F8),
        image: has ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover) : null,
      ),
      child: !has
          ? Icon(
              PhosphorIcons.user(PhosphorIconsStyle.light),
              size: 18,
              color: Colors.black.withOpacity(.55),
            )
          : null,
    );
  }
}

class _Dot extends StatelessWidget {
  final bool online;
  const _Dot({required this.online});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: online ? AppColors.brandGreen : Colors.black.withOpacity(.25),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ProfileMenuSheet extends StatelessWidget {
  final VoidCallback onEditProfile;
  final VoidCallback onLogout;

  final bool verified;
  final bool hasPendingVerification;
  final VoidCallback onRequestVerification;

  const _ProfileMenuSheet({
    required this.onEditProfile,
    required this.onLogout,
    required this.verified,
    required this.hasPendingVerification,
    required this.onRequestVerification,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassBottomSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),

            _MenuLine(
              icon: verified
                  ? Icons.verified_rounded
                  : hasPendingVerification
                      ? Icons.hourglass_top_rounded
                      : Icons.verified_outlined,
              title: verified
                  ? "Verified"
                  : hasPendingVerification
                      ? "Verification requested"
                      : "Request verification",
              // Disable tap if verified or pending
              onTap: (verified || hasPendingVerification)
                  ? () {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            verified
                                ? "This account is already verified."
                                : "Your verification request is pending.",
                          ),
                        ),
                      );
                    }
                  : onRequestVerification,
            ),

            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.userCircleGear(PhosphorIconsStyle.light),
              title: "Edit profile",
              onTap: onEditProfile,
            ),
            const SizedBox(height: 10),
            _MenuLine(
              icon: PhosphorIcons.signOut(PhosphorIconsStyle.light),
              title: "Log out",
              danger: true,
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewerMenuSheet extends StatelessWidget {
  final String profileUid;
  final String username;
  final String fullName;

  const _ViewerMenuSheet({
    required this.profileUid,
    required this.username,
    required this.fullName,
  });

  @override
  Widget build(BuildContext context) {
    final label = username.trim().isNotEmpty ? "@$username" : fullName;

    return _GlassBottomSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),

            _MenuLine(
              icon: PhosphorIcons.prohibit(PhosphorIconsStyle.light),
              title: "Block $label",
              danger: true,
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Block coming next.")),
                );
              },
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.warningCircle(PhosphorIconsStyle.light),
              title: "Report profile",
              danger: true,
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Report flow coming next.")),
                );
              },
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.shareNetwork(PhosphorIconsStyle.light),
              title: "Share profile",
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Share coming next.")),
                );
              },
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.question(PhosphorIconsStyle.light),
              title: "Help",
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Help coming next.")),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;

  const _MenuLine({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? Colors.red.withOpacity(.85) : Colors.black.withOpacity(.82);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.75),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.black.withOpacity(.06)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
              Icon(
                PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                size: 18,
                color: Colors.black.withOpacity(.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  _PinnedHeaderDelegate({required this.height, required this.child});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}

class _GlassBottomSheet extends StatelessWidget {
  final Widget child;
  const _GlassBottomSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(.65)),
            boxShadow: [
              BoxShadow(
                blurRadius: 24,
                offset: const Offset(0, -8),
                color: Colors.black.withOpacity(.10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ShareNoteDialog extends StatelessWidget {
  final TextEditingController controller;
  const _ShareNoteDialog({required this.controller});


  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  PhosphorIcons.chatTeardropText(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Share a note",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              maxLines: 4,
              maxLength: 80,
              decoration: InputDecoration(
                hintText: "What’s on your mind?",
                filled: true,
                fillColor: Colors.black.withOpacity(.03),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: AppColors.brandGreen.withOpacity(.7)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      side: BorderSide(color: Colors.black.withOpacity(.10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "Cancel",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: const Text(
                      "Save",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreAboutSection extends StatelessWidget {
  final String fullName;
  final VoidCallback onSeeMore;

  const _MoreAboutSection({
    required this.fullName,
    required this.onSeeMore,
  });

  @override
  Widget build(BuildContext context) {
    final name = fullName.trim().isEmpty ? "this profile" : fullName.trim();

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onSeeMore,
        borderRadius: BorderRadius.circular(22),
        splashColor: Colors.black.withOpacity(.035),
        highlightColor: Colors.black.withOpacity(.018),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 13, 13, 13),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F7FA),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  PhosphorIcons.identificationBadge(
                    PhosphorIconsStyle.bold,
                  ),
                  size: 20,
                  color: Colors.black.withOpacity(.76),
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Profile details",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      "View identity, interests, links, and more.",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.50),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  size: 17,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _profileBirthdayLabel(DateTime date) {
  return DateFormat("MMM d").format(date);
}

void _showMoreAboutSheet({
  required BuildContext context,
  required String fullName,
  required String username,
  required String intro,
  required String cityLabel,
  required String gender,
  required String pronouns,
  required String bio,
  required List<String> interests,
  required List<String> skills,
  required String email,
  required String phone,
  required Map<String, dynamic> socials,
  required String websiteUrl,
  required DateTime? birthDate,
  required bool showBirthday,
}) {
  final name = fullName.trim().isEmpty ? "Profile" : fullName.trim();
  final handle = username.trim().isEmpty ? "" : "@${username.trim()}";

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final h = MediaQuery.of(sheetContext).size.height;

      return SafeArea(
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(30),
          ),
          child: Container(
            height: h * 0.92,
            color: const Color(0xFFF8FAF8),
            child: Column(
              children: [
                const SizedBox(height: 10),

                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),

                const SizedBox(height: 14),

                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 10, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          PhosphorIcons.identificationBadge(
                            PhosphorIconsStyle.bold,
                          ),
                          color: Colors.white,
                          size: 21,
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "More about $name",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827),
                              ),
                            ),
                            if (handle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                handle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black.withOpacity(.48),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AboutSection(
                          title: "Identity",
                          children: [
                            _AboutInfoRow(
                              icon: PhosphorIcons.identificationCard(
                                PhosphorIconsStyle.light,
                              ),
                              label: "Headline",
                              value: intro.trim().isEmpty ? "—" : intro.trim(),
                            ),
                            _AboutInfoRow(
                              icon: PhosphorIcons.textT(
                                PhosphorIconsStyle.light,
                              ),
                              label: "Bio",
                              value: bio.trim().isEmpty ? "—" : bio.trim(),
                            ),
                            if (showBirthday && birthDate != null)
                              _AboutInfoRow(
                                icon: PhosphorIcons.cake(
                                  PhosphorIconsStyle.light,
                                ),
                                label: "Birthday",
                                value: _profileBirthdayLabel(birthDate),
                              ),
                            _AboutInfoRow(
                              icon: PhosphorIcons.mapPin(
                                PhosphorIconsStyle.light,
                              ),
                              label: "Location",
                              value: cityLabel.trim().isEmpty
                                  ? "Near you"
                                  : cityLabel.trim(),
                            ),
                            _AboutInfoRow(
                              icon: PhosphorIcons.genderIntersex(
                                PhosphorIconsStyle.light,
                              ),
                              label: "Gender",
                              value: gender.trim().isEmpty
                                  ? "—"
                                  : gender.trim(),
                            ),
                            _AboutInfoRow(
                              icon: PhosphorIcons.chatTeardropText(
                                PhosphorIconsStyle.light,
                              ),
                              label: "Pronouns",
                              value: pronouns.trim().isEmpty
                                  ? "—"
                                  : pronouns.trim(),
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        _AboutChipSection(
                          title: "Interests",
                          emptyText: "No interests yet.",
                          icon: PhosphorIcons.heart(
                            PhosphorIconsStyle.light,
                          ),
                          items: interests,
                        ),

                        const SizedBox(height: 14),

                        _AboutChipSection(
                          title: "Tags / Skills",
                          emptyText: "No tags yet.",
                          icon: PhosphorIcons.hash(
                            PhosphorIconsStyle.light,
                          ),
                          items: skills,
                        ),

                        const SizedBox(height: 14),

                        _AboutContactSection(
                          email: email,
                          phone: phone,
                          socials: socials,
                          websiteUrl: websiteUrl,
                        ),
                      ],
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
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visibleChildren = <Widget>[];

    for (var i = 0; i < children.length; i++) {
      visibleChildren.add(children[i]);

      if (i != children.length - 1) {
        visibleChildren.add(
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.black.withOpacity(.055),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AboutSectionTitle(title),

        const SizedBox(height: 8),

        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: visibleChildren,
          ),
        ),
      ],
    );
  }
}

class _AboutInfoRow extends StatelessWidget {
  const _AboutInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              icon,
              color: Colors.black.withOpacity(.68),
              size: 18,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.4,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.45),
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  value,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutChipSection extends StatelessWidget {
  const _AboutChipSection({
    required this.title,
    required this.emptyText,
    required this.icon,
    required this.items,
  });

  final String title;
  final String emptyText;
  final IconData icon;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final cleanItems = items
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AboutSectionTitle(title),

        const SizedBox(height: 8),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: cleanItems.isEmpty
              ? Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: Colors.black.withOpacity(.38),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      emptyText,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.46),
                      ),
                    ),
                  ],
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: cleanItems.map((item) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: 14,
                            color: Colors.black.withOpacity(.56),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            item,
                            style: const TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }
}

class _AboutContactSection extends StatelessWidget {
  const _AboutContactSection({
    required this.email,
    required this.phone,
    required this.socials,
    required this.websiteUrl,
  });

  final String email;
  final String phone;
  final Map<String, dynamic> socials;
  final String websiteUrl;

  String _socialValue(String platform, dynamic raw) {
    if (raw is! Map) return "";

    final visible = raw["visible"] != false;
    if (!visible) return "";

    final handle = (raw["handle"] ?? "").toString().trim();
    final url = (raw["url"] ?? "").toString().trim();

    if (platform == "Website") {
      return url.isNotEmpty ? url : handle;
    }

    if (handle.isNotEmpty) return handle;
    return url;
  }

  Future<void> _openUrl(String value) async {
    final clean = value.trim();
    if (clean.isEmpty) return;

    final withScheme = clean.startsWith("http://") ||
            clean.startsWith("https://") ||
            clean.startsWith("mailto:") ||
            clean.startsWith("tel:")
        ? clean
        : "https://$clean";

    final uri = Uri.tryParse(withScheme);
    if (uri == null) return;

    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];

    if (email.trim().isNotEmpty) {
      rows.add(
        _AboutInfoRow(
          icon: PhosphorIcons.envelopeSimple(PhosphorIconsStyle.light),
          label: "Email",
          value: email.trim(),
        ),
      );
    }

    if (phone.trim().isNotEmpty) {
      rows.add(
        _AboutInfoRow(
          icon: PhosphorIcons.phone(PhosphorIconsStyle.light),
          label: "Phone",
          value: phone.trim(),
        ),
      );
    }

    if (websiteUrl.trim().isNotEmpty) {
      rows.add(
        _AboutLinkRow(
          icon: PhosphorIcons.globe(PhosphorIconsStyle.light),
          label: "Website",
          value: websiteUrl.trim(),
          onTap: () => _openUrl(websiteUrl),
        ),
      );
    }

    for (final entry in socials.entries) {
      final platform = entry.key.toString();
      final value = _socialValue(platform, entry.value);

      if (value.isEmpty) continue;
      if (platform == "Website" && websiteUrl.trim().isNotEmpty) continue;

      rows.add(
        _AboutLinkRow(
          icon: PhosphorIcons.link(PhosphorIconsStyle.light),
          label: platform,
          value: value,
          onTap: () => _openUrl(value),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _AboutSectionTitle("Contact"),

        const SizedBox(height: 8),

        if (rows.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              "No public contact details yet.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.46),
              ),
            ),
          )
        else
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  rows[i],
                  if (i != rows.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: Colors.black.withOpacity(.055),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _AboutLinkRow extends StatelessWidget {
  const _AboutLinkRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: _AboutInfoRow(
          icon: icon,
          label: label,
          value: value,
        ),
      ),
    );
  }
}

class _AboutSectionTitle extends StatelessWidget {
  const _AboutSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Colors.black.withOpacity(.48),
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _DetailBlock extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const _DetailBlock({
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: AppColors.brandGreen, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.55),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayfulGreenSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _PlayfulGreenSurface({
    required this.borderRadius,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF16C784),
              Color(0xFF16C784),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 10),
              color: Colors.black.withOpacity(.08),
            ),
          ],
        ),
        child: Stack(
          children: [
            const Positioned.fill(
              child: IgnorePointer(
                child: _PlayfulGreenDoodles(),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _PlayfulGreenDoodles extends StatelessWidget {
  const _PlayfulGreenDoodles();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 10,
          left: 12,
          child: _DoodleStar(
            color: Colors.white.withOpacity(.85),
            size: 20,
          ),
        ),
        Positioned(
          top: 12,
          right: 16,
          child: _DoodleHeart(
            color: const Color(0xFFD8FF88),
            size: 18,
          ),
        ),
        Positioned(
          bottom: 10,
          left: 20,
          child: _DoodleSpark(
            color: const Color(0xFFB7F44A),
            size: 24,
          ),
        ),
        Positioned(
          bottom: 8,
          right: 14,
          child: _DoodleStar(
            color: Colors.white.withOpacity(.70),
            size: 18,
          ),
        ),
      ],
    );
  }
}

class _DoodleSpark extends StatelessWidget {
  final Color color;
  final double size;

  const _DoodleSpark({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.auto_awesome,
      color: color,
      size: size,
    );
  }
}

class _DetailWrapBlock extends StatelessWidget {
  final String title;
  final String emptyText;
  final IconData icon;
  final List<Widget> chips;

  const _DetailWrapBlock({
    required this.title,
    required this.emptyText,
    required this.icon,
    required this.chips,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.brandGreen),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (chips.isEmpty)
            Text(
              emptyText,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.55),
              ),
            )
          else
            Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }
}

class _DetailContactBlock extends StatelessWidget {
  final String email;
  final String phone;
  final Map<String, dynamic> socials;
  final String websiteUrl;

  const _DetailContactBlock({
    required this.email,
    required this.phone,
    required this.socials,
    required this.websiteUrl,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[]; // ✅ lines must be HERE

    void addLine(String label, String value, IconData icon) {
      final v = value.trim();
      if (v.isEmpty) return;

      final isLink = _looksLikeUrl(v);

      lines.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: AppColors.brandGreen),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  children: [
                    Text(
                      "$label: ",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.72),
                      ),
                    ),
                    isLink
                        ? _LinkText(url: v, maxLines: 2)
                        : Text(
                            v,
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                              color: Colors.black.withOpacity(.72),
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

    // ✅ Website first
    addLine(
      "Website",
      websiteUrl,
      PhosphorIcons.linkSimpleHorizontal(PhosphorIconsStyle.light),
    );

    // ✅ Socials (treat URLs as links) — skip Website to avoid duplicates
    socials.forEach((platform, raw) {
      if (platform.toString().toLowerCase() == "website") return; // ✅ prevent double website
      if (raw is! Map) return;

      final handle = (raw["handle"] ?? "").toString().trim();
      final url = (raw["url"] ?? "").toString().trim();
      final show = url.isNotEmpty ? url : handle;

      addLine(
        platform,
        show,
        PhosphorIcons.linkSimpleHorizontal(PhosphorIconsStyle.light),
      );
    });

    // ✅ Email / Phone (not blue links with this logic)
    addLine("Email", email, PhosphorIcons.envelopeSimple(PhosphorIconsStyle.light));
    addLine("Phone", phone, PhosphorIcons.phone(PhosphorIconsStyle.light));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Contact & socials",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          if (lines.isEmpty)
            Text(
              "Nothing added yet.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.60),
              ),
            )
          else
            ...lines,
        ],
      ),
    );
  }
}

Future<void> openProfilePhotoViewer({
  required BuildContext context,
  required ImageProvider? imageProvider,
  required String heroTag,
  required bool canEdit,
  VoidCallback? onEditTap,
}) async {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => _ProfilePhotoViewerPage(
        imageProvider: imageProvider,
        heroTag: heroTag,
        canEdit: canEdit,
        onEditTap: onEditTap,
      ),
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(opacity: anim, child: child);
      },
    ),
  );
}

class _ProfilePhotoViewerPage extends StatelessWidget {
  final ImageProvider? imageProvider;
  final String heroTag;
  final bool canEdit;
  final VoidCallback? onEditTap;

  const _ProfilePhotoViewerPage({
    required this.imageProvider,
    required this.heroTag,
    required this.canEdit,
    this.onEditTap,
  });

  @override
  Widget build(BuildContext context) {
    final has = imageProvider != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: has
                  ? Hero(
                      tag: heroTag,
                      child: PhotoView(
                        imageProvider: imageProvider!,
                        backgroundDecoration:
                            const BoxDecoration(color: Colors.black),
                        minScale: PhotoViewComputedScale.contained,
                        maxScale: PhotoViewComputedScale.covered * 2.6,
                      ),
                    )
                  : Center(
                      child: Icon(
                        Icons.person,
                        size: 88,
                        color: Colors.white.withOpacity(.35),
                      ),
                    ),
            ),

            // Close
            Positioned(
              top: 10,
              left: 10,
              child: _viewerIconButton(
                icon: Icons.close_rounded,
                onTap: () => Navigator.pop(context),
              ),
            ),

            // Edit (owner only)
            if (canEdit && onEditTap != null)
              Positioned(
                top: 10,
                right: 10,
                child: _viewerIconButton(
                  icon: Icons.edit_rounded,
                  onTap: () {
                    Navigator.pop(context);
                    onEditTap!();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _viewerIconButton({
  required IconData icon,
  required VoidCallback onTap,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(.18)),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    ),
  );
}

bool _looksLikeUrl(String value) {
  final v = value.trim().toLowerCase();

  return v.startsWith("http://") ||
      v.startsWith("https://") ||
      v.startsWith("www.") ||
      v.contains(".com") ||
      v.contains(".net") ||
      v.contains(".org") ||
      v.contains(".io") ||
      v.contains(".app") ||
      v.contains(".dev") ||
      v.contains(".co");
}

class _LinkText extends StatelessWidget {
  final String url;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  const _LinkText({
    required this.url,
    this.maxLines,
    this.style,
    this.overflow = TextOverflow.ellipsis,
  });

  Future<void> _open() async {
    final raw = url.trim();
    if (raw.isEmpty) return;
    if (!_looksLikeUrl(raw)) return;

    final fixed = raw.startsWith("http") ? raw : "https://$raw";
    final uri = Uri.tryParse(fixed);
    if (uri == null) return;

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = url.trim();
    if (raw.isEmpty) return const SizedBox.shrink();

    return GestureDetector(
      onTap: _open,
      child: Text(
        raw,
        maxLines: maxLines,
        overflow: overflow,
        style: style ??
            const TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
              color: Colors.blue,
            ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return _PlayfulGreenSurface(
      borderRadius: BorderRadius.circular(18),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
              size: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w800,
                color: Colors.white,
                fontSize: 12.8,
                height: 1.28,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftGreenSurfacePattern extends StatelessWidget {
  const _SoftGreenSurfacePattern();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SoftGreenSurfacePainter(),
    );
  }
}

class _SoftGreenSurfacePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withOpacity(.18)
      ..strokeWidth = 1;

    final dotPaint = Paint()
      ..color = Colors.white.withOpacity(.12);

    const gap = 26.0;

    for (double y = 10; y < size.height; y += gap) {
      canvas.drawLine(
        Offset(10, y),
        Offset(size.width - 10, y),
        linePaint,
      );
    }

    for (double x = 16; x < size.width; x += 46) {
      for (double y = 14; y < size.height; y += 34) {
        canvas.drawCircle(Offset(x, y), 1.4, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MiniPill extends StatelessWidget {
  final String text;
  const _MiniPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.brandGreen.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: AppColors.brandGreen,
        ),
      ),
    );
  }
}

class _RespondFriendRequestSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _GlassBottomSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Respond to connection request",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, "accept"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  "Accept",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context, "decline"),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.black.withOpacity(.10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  "Decline",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withOpacity(.75),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestedFriendSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _GlassBottomSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Requested",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _MenuLine(
              icon: PhosphorIcons.xCircle(PhosphorIconsStyle.light),
              title: "Cancel request",
              danger: true,
              onTap: () => Navigator.pop(context, "cancel"),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsActionsSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _GlassBottomSheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),

            _MenuLine(
              icon: PhosphorIcons.userMinus(PhosphorIconsStyle.light),
              title: "Remove connection",
              danger: true,
              onTap: () => Navigator.pop(context, "remove"),
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.prohibit(PhosphorIconsStyle.light),
              title: "Block profile",
              danger: true,
              onTap: () => Navigator.pop(context, "block"),
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.warningCircle(PhosphorIconsStyle.light),
              title: "Report profile",
              danger: true,
              onTap: () => Navigator.pop(context, "report"),
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.shareNetwork(PhosphorIconsStyle.light),
              title: "Share profile",
              onTap: () => Navigator.pop(context, "share"),
            ),
            const SizedBox(height: 10),

            _MenuLine(
              icon: PhosphorIcons.question(PhosphorIconsStyle.light),
              title: "Help",
              onTap: () => Navigator.pop(context, "help"),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverErrorState extends StatelessWidget {
  const _CoverErrorState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFDDE3EE),
            const Color(0xFFEBEFF7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          // Dot grid background
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter()),
          ),

          // Center content
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(.55),
                        border: Border.all(
                          color: Colors.grey.withOpacity(.18),
                        ),
                      ),
                    ),
                    Icon(
                      PhosphorIcons.wifiSlash(PhosphorIconsStyle.light),
                      size: 34,
                      color: Colors.grey.shade400,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  "Cover photo unavailable",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Check your internet connection",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    fontSize: 11.5,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.withOpacity(.18)
      ..strokeCap = StrokeCap.round;

    const spacing = 22.0;
    const radius = 1.4;

    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _ProfileInitialLoading extends StatelessWidget {
  const _ProfileInitialLoading();

  @override
  Widget build(BuildContext context) {
    return NestedScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      headerSliverBuilder: (context, innerScrolled) => const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _ProfileHeaderSkeleton(),
          ),
        ),
      ],
      body: const _ProfileBodySkeleton(),
    );
  }
}

class _ProfileHeaderSkeleton extends StatelessWidget {
  const _ProfileHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 22,
                    offset: const Offset(0, 12),
                    color: Colors.black.withOpacity(.06),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: Column(
                  children: [
                    const _SkeletonBox(
                      height: 200,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(30),
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(16, 58, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Expanded(
                                child: _SkeletonBox(height: 22, width: 180),
                              ),
                              SizedBox(width: 10),
                              _SkeletonCircle(size: 40),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const _SkeletonBox(height: 14, width: 110),
                          const SizedBox(height: 14),
                          const _SkeletonBox(height: 14, width: 210),
                          const SizedBox(height: 18),

                          Row(
                            children: const [
                              Expanded(child: _SkeletonPill(height: 42)),
                              SizedBox(width: 10),
                              Expanded(child: _SkeletonPill(height: 42)),
                            ],
                          ),
                          const SizedBox(height: 14),

                          Row(
                            children: const [
                              Expanded(child: _StatSkeletonCard()),
                              SizedBox(width: 10),
                              Expanded(child: _StatSkeletonCard()),
                              SizedBox(width: 10),
                              Expanded(child: _StatSkeletonCard()),
                            ],
                          ),
                          const SizedBox(height: 14),

                          const _SkeletonCard(height: 84),
                          const SizedBox(height: 14),

                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _SkeletonPill(width: 74, height: 30),
                              _SkeletonPill(width: 88, height: 30),
                              _SkeletonPill(width: 68, height: 30),
                              _SkeletonPill(width: 96, height: 30),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Match the loaded profile header: avatar is at the boundary
            // between the cover and the body. Loaded state uses
            // `left: 16, top: coverH - overlap` where coverH=200 and
            // overlap=44, so the avatar sits at top: 156 from the Stack.
            const Positioned(
              left: 16,
              top: 156,
              child: _SkeletonCircle(size: 92),
            ),

            Positioned(
              top: 14,
              right: 14,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.22),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfileBodySkeleton extends StatelessWidget {
  const _ProfileBodySkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, ProfileTab.navBarHeight + 24),
      children: const [
        Row(
          children: [
            Expanded(child: _SkeletonPill(height: 42)),
            SizedBox(width: 10),
            Expanded(child: _SkeletonPill(height: 42)),
            SizedBox(width: 10),
            Expanded(child: _SkeletonPill(height: 42)),
          ],
        ),
        SizedBox(height: 16),
        _SkeletonCard(height: 84),
        SizedBox(height: 10),
        _SkeletonCard(height: 84),
        SizedBox(height: 10),
        _SkeletonCard(height: 84),
        SizedBox(height: 10),
        _SkeletonCard(height: 84),
      ],
    );
  }
}

class _StatSkeletonCard extends StatelessWidget {
  const _StatSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return _SkeletonCard(
      height: 72,
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonBox(height: 18, width: 34),
            SizedBox(height: 10),
            _SkeletonBox(height: 12, width: 56),
          ],
        ),
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final double height;
  final Widget? child;

  const _SkeletonCard({
    required this.height,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: Colors.black.withOpacity(.04),
          ),
        ],
      ),
      child: child ??
          const Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(height: 14, width: 140),
                SizedBox(height: 10),
                _SkeletonBox(height: 12, width: 220),
                SizedBox(height: 8),
                _SkeletonBox(height: 12, width: 170),
              ],
            ),
          ),
    );
  }
}

class _SkeletonPill extends StatelessWidget {
  final double? width;
  final double height;

  const _SkeletonPill({
    this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return _SkeletonBox(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(999),
    );
  }
}

class _ProfileStatsStrip extends StatelessWidget {
  const _ProfileStatsStrip({
    required this.isOwner,
    required this.friendsCount,
    required this.mutualFriendsCount,
    required this.communitiesCount,
    required this.onFriendsTap,
    required this.onCommunitiesTap,
  });

  final bool isOwner;
  final int friendsCount;
  final int mutualFriendsCount;
  final int communitiesCount;
  final VoidCallback onFriendsTap;
  final VoidCallback onCommunitiesTap;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      Expanded(
        child: _ProfileStatCell(
          value: formatCompactCount(friendsCount),
          label: friendsCount == 1 ? 'Connection' : 'Connections',
          onTap: onFriendsTap,
        ),
      ),

      if (!isOwner) ...[
        _ProfileStatDivider(),
        Expanded(
          child: _ProfileStatCell(
            value: formatCompactCount(mutualFriendsCount),
            label: mutualFriendsCount == 1 ? 'Mutual' : 'Mutuals',
            onTap: onFriendsTap,
          ),
        ),
      ],

      _ProfileStatDivider(),

      Expanded(
        child: _ProfileStatCell(
          value: formatCompactCount(communitiesCount),
          label: communitiesCount == 1 ? 'Community' : 'Communities',
          onTap: onCommunitiesTap,
        ),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: items,
      ),
    );
  }
}

class _ProfileStatCell extends StatelessWidget {
  const _ProfileStatCell({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: Colors.black.withOpacity(.035),
        highlightColor: Colors.black.withOpacity(.018),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                  height: 1.05,
                ),
              ),

              const SizedBox(height: 4),

              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12.2,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.48),
                  height: 1.05,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileStatDivider extends StatelessWidget {
  const _ProfileStatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.black.withOpacity(.07),
    );
  }
}

class _SkeletonCircle extends StatelessWidget {
  final double size;

  const _SkeletonCircle({
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return _SkeletonBox(
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(size / 2),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  const _SkeletonBox({
    this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: borderRadius ?? BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xFFF5F7FA),
            Color(0xFFECEFF4),
            Color(0xFFF5F7FA),
          ],
        ),
      ),
    );
  }
}

class _SectionListSkeleton extends StatelessWidget {
  const _SectionListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        _SkeletonCard(height: 92),
        SizedBox(height: 10),
        _SkeletonCard(height: 92),
        SizedBox(height: 10),
        _SkeletonCard(height: 92),
      ],
    );
  }
}

class _ProfileFriendsScreen extends StatefulWidget {
  final String profileUid;
  final String viewerUid;
  final bool isOwner;
  final int initialTab;

  const _ProfileFriendsScreen({
    required this.profileUid,
    required this.viewerUid,
    required this.isOwner,
    this.initialTab = 0,
  });

  @override
  State<_ProfileFriendsScreen> createState() => _ProfileFriendsScreenState();
}

class _ProfileFriendsScreenState extends State<_ProfileFriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final TextEditingController _searchCtrl = TextEditingController();
  final ValueNotifier<String> _searchText = ValueNotifier("");
  final FocusNode _searchFocus = FocusNode();

  final Map<String, Set<String>> _friendIdsMemory = {};
  late final Future<Set<String>> _viewerFriendIdsFuture;

  @override
  void initState() {
    super.initState();

    final tabCount = widget.isOwner ? 1 : 2;
    final safeInitial = widget.initialTab.clamp(0, tabCount - 1);

    _tabs = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: safeInitial,
    );

    _viewerFriendIdsFuture = _loadResolvedFriendIds(widget.viewerUid);

    _searchCtrl.addListener(() {
      _searchText.value = _searchCtrl.text.trim().toLowerCase();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<Set<String>> _loadResolvedFriendIds(String uid) async {
    if (_friendIdsMemory.containsKey(uid)) {
      return _friendIdsMemory[uid]!;
    }

    final db = FirebaseFirestore.instance;

    final userDoc = await db.collection("users").doc(uid).get();
    final userData = userDoc.data() ?? {};

    final ids = <String>{};
    ids.addAll(List<String>.from(userData["friendIds"] ?? []));

    final subSnap = await db
        .collection("users")
        .doc(uid)
        .collection("friends")
        .get();

    for (final doc in subSnap.docs) {
      final fid = (doc.data()["friendId"] ?? "").toString();
      if (fid.isNotEmpty) ids.add(fid);
    }

    ids.remove(uid);

    _friendIdsMemory[uid] = ids;
    return ids;
  }

  Future<int> _loadMutualCount({
    required String friendUid,
    required Set<String> comparisonBaseIds,
    required Set<String> excludeIds,
  }) async {
    final friendIds = await _loadResolvedFriendIds(friendUid);

    final left = {...comparisonBaseIds}..removeAll(excludeIds);
    final right = {...friendIds}..removeAll(excludeIds);

    return left.intersection(right).length;
  }

  @override
  Widget build(BuildContext context) {
    final profileRef =
        FirebaseFirestore.instance.collection("users").doc(widget.profileUid);
    final friendsSub = profileRef.collection("friends").limit(120);

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: profileRef.snapshots(),
          builder: (context, userSnap) {
            if (!userSnap.hasData ||
                userSnap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(
                  color: AppColors.brandGreen,
                ),
              );
            }

            final userData = userSnap.data?.data() ?? {};
            final fullName = (userData["fullName"] ?? "Connections").toString();
            final storedFriendIds = List<String>.from(userData["friendIds"] ?? []);

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: friendsSub.snapshots(),
              builder: (context, subSnap) {
                if (!subSnap.hasData ||
                    subSnap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.brandGreen,
                    ),
                  );
                }

                final subDocs = subSnap.data?.docs ?? [];
                final idsFromSub = subDocs
                    .map((d) => (d.data()["friendId"] ?? "").toString())
                    .where((x) => x.isNotEmpty)
                    .toList();

                final ids = {...storedFriendIds, ...idsFromSub}.toList();

                return FutureBuilder<Set<String>>(
                  future: _viewerFriendIdsFuture,
                  builder: (context, viewerSnap) {
                    final viewerFriendIds = viewerSnap.data ?? <String>{};
                    final comparisonBaseIds = widget.isOwner
                        ? ids.toSet()
                        : viewerFriendIds;

                    final mutualIds = ids
                        .where((id) => viewerFriendIds.contains(id))
                        .toList();

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Row(
                            children: [
                              _RoundTopButton(
                                icon: PhosphorIcons.arrowLeft(
                                  PhosphorIconsStyle.bold,
                                ),
                                onTap: () => Navigator.pop(context),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.isOwner
                                          ? "Your connections"
                                          : "$fullName’s connections",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      widget.isOwner
                                          ? "${formatCompactCount(ids.length)} people in your network"
                                          : "${formatCompactCount(ids.length)} connections • ${formatCompactCount(mutualIds.length)} mutuals",
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black.withOpacity(.52),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _FriendsScreenSearchField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _FriendsSegmentTabs(
                            controller: _tabs,
                            tabs: widget.isOwner
                                ? const ["Connections"]
                                : const ["All connections", "Mutual"],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: ValueListenableBuilder<String>(
                            valueListenable: _searchText,
                            builder: (context, searchText, _) {
                              return TabBarView(
                                controller: _tabs,
                                physics: const BouncingScrollPhysics(),
                                children: widget.isOwner
                                    ? [
                                        _buildFriendsList(
                                          ids: ids,
                                          comparisonBaseIds: comparisonBaseIds,
                                          searchText: searchText,
                                          emptyTitle: "No connections yet",
                                          emptySubtitle:
                                              "Start connecting and your network will show here.",
                                        ),
                                      ]
                                    : [
                                        _buildFriendsList(
                                          ids: ids,
                                          comparisonBaseIds: comparisonBaseIds,
                                          searchText: searchText,
                                          emptyTitle: "No connections found",
                                          emptySubtitle: "This user’s connections will show here.",
                                        ),
                                        _buildFriendsList(
                                          ids: mutualIds,
                                          comparisonBaseIds: comparisonBaseIds,
                                          searchText: searchText,
                                          emptyTitle: "No mutual connections",
                                          emptySubtitle:
                                              "Connections you both share will show here.",
                                        ),
                                      ],
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildFriendsList({
    required List<String> ids,
    required Set<String> comparisonBaseIds,
    required String searchText,
    required String emptyTitle,
    required String emptySubtitle,
  }) {
    if (ids.isEmpty) {
      return _EmptyState(
        icon: PhosphorIcons.usersThree(PhosphorIconsStyle.light),
        title: emptyTitle,
        subtitle: emptySubtitle,
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: ids.length,
      itemBuilder: (_, i) {
        final fid = ids[i];
        final ref = FirebaseFirestore.instance.collection("users").doc(fid);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: ref.snapshots(),
          builder: (context, snap) {
            final d = snap.data?.data() ?? {};

            final name = (d["fullName"] ?? "Connection").toString();
            final username = (d["username"] ?? "").toString();
            final pic = (d["photoUrl"] ?? "").toString();
            final online = pingmeeIsUserOnlineFromUserData(d);

            final verification =
                Map<String, dynamic>.from(d["verification"] ?? {});
            final isVerified = verification["status"] == "verified";

            final haystack = "$name $username".toLowerCase().trim();
            if (searchText.isNotEmpty && !haystack.contains(searchText)) {
              return const SizedBox.shrink();
            }

            return FutureBuilder<int>(
              future: _loadMutualCount(
                friendUid: fid,
                comparisonBaseIds: comparisonBaseIds,
                excludeIds: {
                  fid,
                  widget.viewerUid,
                  widget.profileUid,
                },
              ),
              builder: (context, mutualSnap) {
                final mutualCount = mutualSnap.data ?? 0;
                final mutualLabel = mutualCount == 1
                    ? "1 mutual connection"
                    : "$mutualCount mutual connections";

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProfileTab(profileUid: fid),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 18,
                              offset: const Offset(0, 10),
                              color: Colors.black.withOpacity(.04),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            _MiniAvatar(photoUrl: pic),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: "Nunito",
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14.5,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ),
                                      if (isVerified) ...[
                                        const SizedBox(width: 6),
                                        const Icon(
                                          Icons.verified_rounded,
                                          size: 16,
                                          color: Color(0xFF1D9BF0),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    username.isEmpty ? "@" : "@$username",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12.5,
                                      color: Colors.black.withOpacity(.58),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    mutualLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                      fontSize: 11.8,
                                      color: Colors.black.withOpacity(.45),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            _Dot(online: online),
                            const SizedBox(width: 8),
                            Icon(
                              PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                              size: 18,
                              color: Colors.black.withOpacity(.30),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _FriendsScreenSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _FriendsScreenSearchField({
    required this.controller,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      textInputAction: TextInputAction.search,
      style: const TextStyle(
        fontFamily: "Nunito",
        fontWeight: FontWeight.w600,
        fontSize: 13.5,
      ),
      decoration: InputDecoration(
        hintText: "Search connections",
        hintStyle: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w500,
          color: Colors.black.withOpacity(.42),
        ),
        prefixIcon: Icon(
          PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
          size: 18,
          color: Colors.black.withOpacity(.45),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _FriendsSegmentTabs extends StatelessWidget {
  final TabController controller;
  final List<String> tabs;

  const _FriendsSegmentTabs({
    required this.controller,
    required this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: Colors.black.withOpacity(.04),
          ),
        ],
      ),
      child: TabBar(
        controller: controller,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: AppColors.brandGreen,
          borderRadius: BorderRadius.circular(14),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: Colors.black.withOpacity(.62),
        labelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w700,
          fontSize: 12.8,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w700,
          fontSize: 12.8,
        ),
        tabs: tabs.map((t) => Tab(text: t)).toList(),
      ),
    );
  }
}

class _RoundTopButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _RoundTopButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 10),
                color: Colors.black.withOpacity(.04),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 18,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }
}