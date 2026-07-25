import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:giphy_get/giphy_get.dart';
import 'package:http/http.dart' as http;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/shared/comment_widgets.dart';
import 'package:ping_files/main_app/shared/connection_picker_sheet.dart';
import 'package:ping_files/main_app/shared/moment_comments_sheet.dart';
import 'package:ping_files/main_app/shared/search_connect_card.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ping_files/main_app/tabs/feed/liked_moments_screen.dart';
import 'package:ping_files/main_app/tabs/feed/saved_moments_screen.dart';
import 'package:ping_files/main_app/tabs/feed/moment_detail_screen.dart';
import 'package:ping_files/main_app/tabs/feed/shared_moment_widgets.dart' show SharedMediaItem;
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/main_app/tabs/profile/profile_engagement_screen.dart';
import 'package:ping_files/features/chat/message_request_router.dart';
import 'package:ping_files/features/chat/pingmee_chat_routes.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/features/pings/ping_visibility.dart' show PingVisibilityContext;
import 'package:ping_files/features/events/event_details_screen.dart';
import 'package:ping_files/features/search/search_service.dart' show SearchService, SearchResult, SearchKind;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart'
    as video_thumb;
import 'package:video_player/video_player.dart';
import 'dart:typed_data';

import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;

enum _FeedMode {
  following,
  aroundMe,
  explore,
  liked,
  saved,
}

class FeedTab extends StatefulWidget {
  /// Called when the user taps an avatar or display name on a moment
  /// card in the feed. The shell uses this to switch to the Profile
  /// tab showing the tapped user's profile.
  final void Function(String authorUid)? onOpenUserProfile;

  /// Called by the feed when the user scrolls. The shell uses this
  /// to hide/show the bottom navigation. Mirrors the pattern used by
  /// the chat tab (see PingmeeChatTab.onNavVisibilityChanged).
  final ValueChanged<bool>? onNavVisibilityChanged;

  const FeedTab({
    super.key,
    this.onOpenUserProfile,
    this.onNavVisibilityChanged,
  });

  @override
  State<FeedTab> createState() => _FeedTabState();
}

/// Public alias for the FeedTab's State so the main app shell can
/// hold a GlobalKey<FeedTabState> and call scrollToTop() on it.
typedef FeedTabState = _FeedTabState;

class _FeedTabState extends State<FeedTab> with SingleTickerProviderStateMixin {
  final PingmeeFeedService _feedService = PingmeeFeedService();

  /// Service for the new threaded comments (v50+). Used by the
  /// MomentCommentsSheet and the connection picker.
  final CommentService _commentService = CommentService();

  /// v90: my-connections cache. Used as a client-side fallback for
  /// the @-mention resolver on moment cards when the backend's
  /// `mentions[]` field is missing (pre-v87a deploy) or empty. The
  /// cache maps the friend's `mentionTag` (lowercased no-spaces
  /// display name) to the UserRef so the renderer can match
  /// @-tags out of the moment text and route the tap to the
  /// right profile. Populated once in initState's post-frame
  /// tick. Capped at 25 entries to keep the lookup cheap.
  final Map<String, UserRef> _myConnectionsByTag = <String, UserRef>{};
  bool _myConnectionsLoaded = false;

  /// Convenience getter for the parent-supplied onOpenUserProfile
  /// callback. Used by the feed's moment cards to navigate to a
  /// tapped user's profile.
  void Function(String authorUid)? get _onOpenUserProfile =>
      widget.onOpenUserProfile;

  StreamSubscription<User?>? _authSub;
  _FeedMode _feedMode = _FeedMode.following;

  bool _feedBooted = false;
  bool _bootingFeed = false;

  /// Bottom-nav visibility is hidden when the user is scrolling down
  /// the feed and shown when scrolling back up. Mirrors the chat tab's
  /// pattern. See [_handleFeedScrollNotification].
  bool _navHidden = false;
  DateTime _lastNavSignalAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _setShellNavHidden(bool hidden) {
    if (_navHidden == hidden) return;
    _navHidden = hidden;
    widget.onNavVisibilityChanged?.call(hidden);
  }

  bool _handleFeedScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    if (notification is! ScrollUpdateNotification) return false;

    final delta = notification.scrollDelta;
    if (delta == null) return false;

    final now = DateTime.now();
    if (now.difference(_lastNavSignalAt).inMilliseconds < 70) {
      return false;
    }

    if (delta.abs() < 3) return false;

    _lastNavSignalAt = now;

    // Content moving up / user scrolling down page => hide nav.
    if (delta > 0 && notification.metrics.pixels > 12) {
      _setShellNavHidden(true);
    }

    // Content moving down / user scrolling back toward top => show nav.
    if (delta < 0) {
      _setShellNavHidden(false);
    }

    return false;
  }

  /// Build (or refresh) the photo cache + per-author Firestore stream
  /// subscriptions for the given set of uids. The cache lets the
  /// _MomentCard show the user's CURRENT profile picture instead of
  /// the stale snapshot stored on each moment. The subscriptions
  /// keep the cache live: when the user changes their photo, every
  /// moment card on screen reflects the new image.
  ///
  /// Safe to call repeatedly with the same uids — duplicates are
  /// de-duplicated. Stale uids (no longer in the visible moments)
  /// should be passed via [dropUids] so we can cancel their
  /// subscriptions and free the listener slots.
  Future<void> _refreshPhotoCacheFor(
    Set<String> uids, {
    Set<String> dropUids = const {},
  }) async {
    // Cancel subscriptions for uids that are no longer visible.
    for (final uid in dropUids) {
      final sub = _userDocSubs.remove(uid);
      if (sub != null) {
        await sub.cancel();
      }
      _photoCache.remove(uid);
    }

    final fresh = uids.where((u) => u.isNotEmpty).toSet();
    if (fresh.isEmpty) return;

    for (final uid in fresh) {
      // Skip if we already have a live subscription for this uid.
      if (_userDocSubs.containsKey(uid)) continue;

      // Subscribe to the user doc so the photo cache stays live.
      _userDocSubs[uid] = FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .snapshots()
          .listen((snap) {
        if (!mounted) return;
        final data = snap.data();
        if (data == null) return;
        final live = (data["photoUrl"] ?? "").toString().trim();
        if (_photoCache[uid] == live) return;
        setState(() {
          _photoCache[uid] = live;
        });
      });

      // One-shot initial fetch (in case the live stream is slow or
      // the cache entry doesn't exist yet).
      try {
        final snap = await FirebaseFirestore.instance
            .collection("users")
            .doc(uid)
            .get();
        if (!mounted) return;
        final data = snap.data();
        if (data == null) continue;
        final live = (data["photoUrl"] ?? "").toString().trim();
        if (_photoCache[uid] == live) continue;
        setState(() {
          _photoCache[uid] = live;
        });
      } catch (_) {
        // Ignore — the snapshot subscription will retry on next change.
      }
    }
  }

  bool _printedBuildLog = false;

  String? _feedBootError;
  String? _bootedUid;

  List<Map<String, dynamic>> _timelineMoments = [];
  Map<String, bool> _verifiedCache = {};
  /// Live photoUrl for each unique author uid. Built from a one-shot
  /// fetch on load/load-more, then kept up-to-date by per-author
  /// Firestore snapshot subscriptions so that when a user changes their
  /// profile picture, every moment card showing their avatar
  /// immediately reflects the new image (even for OLD moments that
  /// were created with the previous photoUrl snapshot).
  Map<String, String> _photoCache = {};

  // v77: current user's Pingmee profile photo URL (NOT the Google
  // OAuth one - we read from users/{myUid}.photoUrl). Synced via
  // a one-shot fetch + a .snapshots() subscription, exactly like
  // the per-author _photoCache entries below. Used by the
  // 'Share what's happening around you' card so the leading
  // avatar reflects what the user set in the Pingmee profile
  // editor (NOT the Google account photo).
  String? _myPhotoUrl;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _myPhotoSub;
  // Inline people-suggestion carousel state. Inserted at
  // itemIndex 11 in the feed's ListView.separated (i.e. after
  // the 10th moment), so the user sees it after scrolling past
  // 10 feed posts. State mirrors the search sheet's: a list of
  // SearchResult (only user-kind), a dismissed set keyed by
  // uid, and a per-uid FriendStateManager cache so each card
  // owns its optimistic override.
  List<SearchResult> _inlinePeopleSuggestions = const [];
  bool _inlinePeopleLoaded = false;
  bool _inlinePeopleLoading = false;
  final Set<String> _inlinePeopleDismissed = <String>{};
  final Map<String, FriendStateManager> _inlinePeopleManagers = {};
  /// 1-based index in the feed's ListView.separated at which
  /// the inline carousel is rendered. Layout:
  ///   itemIndex 0 -> _CreateMomentPreviewCard (share card)
  ///   itemIndex 1..N -> moment[0..N-1]
  ///   itemIndex N+1 -> optional footer (loading spinner)
  /// So the carousel-after-10th-moment goes at itemIndex 11
  /// (1 share + 10 moments = 11, then carousel at 11).
  static const int _inlinePeopleItemIndex = 11;
  /// Active subscriptions on `users/{uid}` documents. Keyed by uid.
  /// We cancel these on dispose and rebuild the set whenever the
  /// visible author set changes (new load, new pagination page).
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> _userDocSubs = {};

  bool _loadingMoments = false;
  bool _loadingMore = false;
  bool _creatingMoment = false;
  // v95a: posting feedback overlay. Shows the current stage as a
  // floating card above the modal sheet. null when not posting.
  String? _uploadStage;
  OverlayEntry? _overlayEntry;
  // v95g: true while a repost is being created. Used by the
  // _PostingOverlay to show "Quoting moment..." instead of
  // "Posting your moment...".
  bool _isReposting = false;

  String? _momentsError;
  int _nextOffset = 0;
  bool _hasMore = true;

  late AnimationController _drawerAnimController;
  final ScrollController _feedScrollController = ScrollController();

  /// Scroll the feed back to the very top. Used by the main app shell
  /// so that re-tapping the Moments tab while already on the feed
  /// behaves like a "scroll to top" affordance, even when the same
  /// widget state is reused via IndexedStack.
  void scrollToTop() {
    if (!_feedScrollController.hasClients) return;
    if (_feedScrollController.offset <= 0) return;
    _feedScrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void initState() {
    super.initState();

    _drawerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _feedScrollController.addListener(_onFeedScroll);

    debugPrint("🟢 FeedTab initState fired");

    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint("🟢 FeedTab post-frame bootstrap check");
      _bootstrapFeed(reason: "post-frame");
      // Kick off the inline people-suggestion loader in
      // the same post-frame tick so it doesn't block the
      // feed bootstrap. By the time the user scrolls past
      // 10 moments, the loader has had time to query.
      _loadInlinePeopleSuggestions();
      // v77: one-shot fetch + live subscription for the
      // current user's Pingmee profile photo so the
      // 'Share what's happening around you' card shows
      // the in-app avatar (not the Google OAuth one).
      _initMyPhoto();
      // v90: load the current user's connections so moment
      // cards can resolve @-mentions client-side (when the
      // backend's mentions[] is empty or before the v87a
      // deploy lands).
      _loadMyConnections();
    });

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      debugPrint("🟢 Feed authStateChanges fired. uid=${user?.uid}");
      if (user != null) {
        _bootstrapFeed(reason: "authStateChanges");
      }
    });
  }


  void _onFeedScroll() {
    if (_loadingMore || _loadingMoments || !_hasMore) {
      return;
    }
    final sc = _feedScrollController;
    if (!sc.hasClients) return;
    final maxScroll = sc.position.maxScrollExtent;
    final currentScroll = sc.offset;
    // Trigger loadMore when within 400px of the bottom
    if (maxScroll - currentScroll < 400) {
      _loadMoreMoments();
    }
  }

  void _toggleDrawer() {
    if (_drawerAnimController.isDismissed) {
      _drawerAnimController.forward();
    } else {
      _drawerAnimController.reverse();
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    // Finger-tracking: drawer edge sticks to finger position, clamped 0..1
    _drawerAnimController.value =
        (_drawerAnimController.value + details.primaryDelta! / 280).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    // Snap open if past 50%, otherwise close
    if (_drawerAnimController.value >= 0.5) {
      _drawerAnimController.forward();
    } else {
      _drawerAnimController.reverse();
    }
  }

  void _selectFeedMode(_FeedMode mode) {
    if (mode == _FeedMode.liked) {
      _drawerAnimController.reverse();
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LikedMomentsScreen()),
      );
      return;
    }
    if (mode == _FeedMode.saved) {
      _drawerAnimController.reverse();
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SavedMomentsScreen()),
      );
      return;
    }
    setState(() => _feedMode = mode);
    _drawerAnimController.reverse();
  }

  String get _feedModeLabel {
    switch (_feedMode) {
      case _FeedMode.following:
        return 'Connections';
      case _FeedMode.aroundMe:
        return 'Around Me';
      case _FeedMode.explore:
        return 'Explore';
      case _FeedMode.liked:
        return 'Liked Moments';
      case _FeedMode.saved:
        return 'Saved Moments';
    }
  }

  @override
  void dispose() {
    // Cancel per-author Firestore subscriptions so the live photoUrl
    // cache stays in sync (see _refreshPhotoCacheFor). Without this,
    // every Firestore snapshot for visible authors would leak.
    for (final sub in _userDocSubs.values) {
      sub.cancel();
    }
    _userDocSubs.clear();

    _feedScrollController.removeListener(_onFeedScroll);
    _feedScrollController.dispose();
    _authSub?.cancel();
    _myPhotoSub?.cancel();  // v77
    _drawerAnimController.dispose();
    super.dispose();
  }

  final Set<String> _likingMomentIds = <String>{};
  final Set<String> _savingMomentIds = <String>{};

  Future<void> _openMomentMoreSheet(
    Map<String, dynamic> moment,
    int index,
  ) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? "";
    final authorUid = (moment["authorUid"] ?? "").toString().trim();
    final isOwner = currentUid.isNotEmpty && currentUid == authorUid;

    // v97r: pass the author's display name so the Mute/Restrict
    // labels can show @"<handle>" rather than a generic label.
    final displayName =
        (moment["authorName"] ?? "").toString().trim();
    final handle = displayName.isNotEmpty
        ? displayName
        : (authorUid.isNotEmpty
            ? authorUid.length > 8
                ? "@" + authorUid.substring(0, 8)
                : "@" + authorUid
            : null);

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _MomentMoreSheet(
        isOwner: isOwner,
        authorUidDisplay: handle,
      ),
    );

    if (action == null) return;

    final activityId = (moment["id"] ?? "").toString().trim();
    final foreignId = (moment["foreignId"] ?? "").toString().trim();

    if (activityId.isEmpty || foreignId.isEmpty) return;

    // v97r: copy / not-interested / mute / restrict / view profile
    // actions. Each writes to a Firestore subcollection under the
    // current user's users/{myUid}/<kind>/<authorUid> doc so the
    // action is durable. Local list mutates immediately for
    // instant UX feedback; a future read-path filter will make
    // these permanent on refresh.
    final firestore = FirebaseFirestore.instance;
    final authorUidForFilter = authorUid.isEmpty ? null : authorUid;
    Future<void> _removeFromLocal(int i) async {
      if (!mounted) return;
      setState(() {
        if (i >= 0 && i < _timelineMoments.length) {
          _timelineMoments.removeAt(i);
        }
      });
    }

    if (action == "copy") {
      // Prefer the link preview's URL if available; otherwise use
      // a deep link to the moment by id.
      String url = "";
      final preview = moment["linkPreview"];
      if (preview is Map) {
        url = (preview["url"] ?? "").toString().trim();
      }
      if (url.isEmpty && activityId.isNotEmpty) {
        url = "https://pingmee.app/m/" + activityId;
      }
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Link copied")),
      );
      return;
    }

    if (action == "view_profile") {
      if (authorUidForFilter != null && _onOpenUserProfile != null) {
        _onOpenUserProfile!(authorUidForFilter);
      }
      return;
    }

    if (action == "not_interested" && currentUid.isNotEmpty
        && authorUidForFilter != null) {
      try {
        await firestore
            .collection("users")
            .doc(currentUid)
            .collection("not_interested")
            .doc(authorUidForFilter)
            .set({
              "authorUid": authorUidForFilter,
              "createdAt": FieldValue.serverTimestamp(),
            });
        await _removeFromLocal(index);
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text("Not interested — fewer like this")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn’t update preference.")),
        );
      }
      return;
    }

    if (action == "mute" && currentUid.isNotEmpty
        && authorUidForFilter != null) {
      try {
        await firestore
            .collection("users")
            .doc(currentUid)
            .collection("muted")
            .doc(authorUidForFilter)
            .set({
              "authorUid": authorUidForFilter,
              "createdAt": FieldValue.serverTimestamp(),
            });
        await _removeFromLocal(index);
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(
              "Muted. You won’t see @" +
                  (displayName.isNotEmpty
                      ? displayName
                      : "this user") +
                  " in your feed.")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn’t mute.")),
        );
      }
      return;
    }

    if (action == "restrict" && currentUid.isNotEmpty
        && authorUidForFilter != null) {
      try {
        await firestore
            .collection("users")
            .doc(currentUid)
            .collection("restricted")
            .doc(authorUidForFilter)
            .set({
              "authorUid": authorUidForFilter,
              "createdAt": FieldValue.serverTimestamp(),
            });
        await _removeFromLocal(index);
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(
              "Restricted @" +
                  (displayName.isNotEmpty
                      ? displayName
                      : "this user") +
                  ".")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn’t restrict.")),
        );
      }
      return;
    }

    if (action == "delete") {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Delete Moment?"),
          content: const Text(
            "This removes the Moment from your feed. This cannot be undone.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Delete"),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      try {
        await _feedService.deleteMoment(
          activityId: activityId,
          foreignId: foreignId,
        );

        if (!mounted) return;

        setState(() {
          _timelineMoments.removeAt(index);
        });

        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Moment deleted.")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn’t delete Moment.")),
        );
      }

      return;
    }

    if (action == "report") {
      try {
        await _feedService.reportMoment(
          activityId: activityId,
          foreignId: foreignId,
        );

        if (!mounted) return;

        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Moment reported.")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't report Moment.")),
        );
      }
      return;
    }
  }

  Future<void> _openRepostSheet(Map<String, dynamic> moment) async {
    final action = await showModalBottomSheet<_RepostAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RepostMomentSheet(moment: moment),
    );

    if (action == null) return;

    // v95g: set _isReposting so the floating overlay says
    // "Quoting moment..." (or "Posting...") instead of the
    // generic "Posting your moment...".
    setState(() {
      _isReposting = true;
      _uploadStage = "posting";
    });
    _showPostingOverlay();

    try {
      await _feedService.createMomentRepost(
        originalMoment: moment,
        quoteText: action.quoteText,
        // v87a: forward @-mentions on the quote text.
        mentions: action.mentions,
      );

      await _loadTimelineMoments(reason: "after repost");

      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            action.quoteText.trim().isEmpty
                ? "Moment reposted."
                : "Quote Moment posted.",
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Couldn’t repost Moment."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isReposting = false;
          _uploadStage = null;
        });
        _removePostingOverlay();
      }
    }
  }


  Future<void> _shareMoment(Map<String, dynamic> moment) async {
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ShareMomentSheet(moment: moment),
      );
    } catch (_) {
      // Share cancelled or failed silently
    }
  }

Future<void> _toggleMomentBookmark(int index) async {
    if (index < 0 || index >= _timelineMoments.length) return;

    final moment = Map<String, dynamic>.from(_timelineMoments[index]);

    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty) return;

    // Extract Firestore document ID from foreignId (format: "moment:{firestoreId}")
    final foreignId = (moment["foreignId"] ?? "").toString().trim();
    final momentId = foreignId.startsWith("moment:")
        ? foreignId.substring(7)
        : activityId;

    if (_savingMomentIds.contains(activityId)) {
      debugPrint("🛑 Save ignored: already updating $activityId");
      return;
    }

    final currentlySaved = moment["savedByMe"] == true;
    final currentCount = moment["savedCount"] is num
        ? (moment["savedCount"] as num).toInt()
        : 0;
    final reactionId =
        (moment["myBookmarkReactionId"] ?? "").toString().trim();

    _savingMomentIds.add(activityId);

    // Optimistically flip savedByMe and bump savedCount in lockstep so the
    // bookmark count in the action bar moves up/down the moment the user
    // taps save. Mirrors the same pattern used by liked/saved/moment-detail
    // so the feed behaves identically.
    setState(() {
      _timelineMoments[index] = {
        ...moment,
        "savedByMe": !currentlySaved,
        "savedCount": currentlySaved
            ? (currentCount - 1).clamp(0, 999999)
            : currentCount + 1,
      };
    });

    try {
      final result = await _feedService.toggleMomentBookmark(
        activityId: activityId,
        currentlySaved: currentlySaved,
        reactionId: reactionId,
        momentId: momentId,
      );

      if (!mounted) return;

      final updated = Map<String, dynamic>.from(_timelineMoments[index]);

      // If the cloud function returns a fresh savedCount, prefer it over
      // the optimistic one (the server's number is the source of truth).
      // Otherwise keep the optimistic value we set above.
      final serverCount = result["savedCount"];
      final merged = <String, dynamic>{
        ...updated,
        "savedByMe": result["saved"] == true,
        "myBookmarkReactionId": (result["reactionId"] ?? "").toString(),
      };
      if (serverCount is num) {
        merged["savedCount"] = serverCount.toInt();
      }

      setState(() {
        _timelineMoments[index] = merged;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _timelineMoments[index] = {
          ...moment,
          "savedByMe": currentlySaved,
          "savedCount": currentCount,
        };
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Couldn’t update save."),
        ),
      );
    } finally {
      _savingMomentIds.remove(activityId);
    }
  }

  Future<void> _syncFollowsThenLoad() async {
    try {
      await _feedService.syncMyFeedFollows();
    } catch (e) {
      debugPrint("⚠️ Feed follows sync failed, loading timeline anyway: $e");
    }

    await _loadTimelineMoments(reason: "after follows sync");
  }

  /// v77: read the current user's Pingmee profile photo (NOT
  /// the Google OAuth photo) and keep _myPhotoUrl in sync via a
  /// Firestore .snapshots() subscription. Pattern matches
  /// _refreshPhotoCacheFor() which feeds the per-author avatar
  /// cache below. The subscription is cancelled in dispose().
  Future<void> _initMyPhoto() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? "";
    if (myUid.isEmpty) return;
    // One-shot initial fetch so the avatar is correct on the
    // very first frame (instead of waiting for the snapshot
    // stream to emit).
    try {
      final snap = await FirebaseFirestore.instance
          .collection("users")
          .doc(myUid)
          .get();
      if (!mounted) return;
      final data = snap.data();
      if (data != null) {
        final url = (data["photoUrl"] ?? "").toString().trim();
        if (url.isNotEmpty) {
          setState(() => _myPhotoUrl = url);
        }
      }
    } catch (e) {
      debugPrint("v77 _initMyPhoto one-shot failed: $e");
    }
    // Live subscription so the avatar updates as soon as the
    // user changes their photo in the profile editor.
    _myPhotoSub?.cancel();
    _myPhotoSub = FirebaseFirestore.instance
        .collection("users")
        .doc(myUid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data();
      final url = (data == null)
          ? null
          : (data["photoUrl"] ?? "").toString().trim();
      final next = (url == null || url.isEmpty) ? null : url;
      if (_myPhotoUrl == next) return;
      setState(() => _myPhotoUrl = next);
    });
  }

  /// v90: client-side fallback for @-mentions on moment cards. When
  /// the backend's `mentions[]` field is empty (pre-v87a deploy, or
  /// the mentioned person is a stranger to the viewer), this cache
  /// lets the renderer still resolve @-tags by matching the
  /// lowercased-no-spaces display name against the current viewer's
  /// friends list. Limited to 25 entries. The cache is built once
  /// on init; we don't subscribe to friends-list changes because
  /// the @-tag in the moment text would still match an updated
  /// display name on a per-card rebuild.
  Future<void> _loadMyConnections() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? "";
    if (myUid.isEmpty) return;
    try {
      final friends = await _commentService.searchConnections(
        myUid,
        limit: 25,
      );
      if (!mounted) return;
      setState(() {
        _myConnectionsByTag.clear();
        for (final u in friends) {
          final tag = u.mentionTag;
          if (tag.isNotEmpty) _myConnectionsByTag[tag] = u;
        }
        _myConnectionsLoaded = true;
      });
      debugPrint("v90 _loadMyConnections: ${friends.length} friends cached");
    } catch (e) {
      debugPrint("🔥 v90 _loadMyConnections failed: $e");
    }
  }

  Future<void> _bootstrapFeed({
    required String reason,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    debugPrint("🟢 Feed bootstrap called. reason=$reason uid=$uid");

    if (uid == null || uid.isEmpty) {
      debugPrint("🛑 Feed bootstrap stopped: Firebase user is not ready yet.");
      return;
    }

    if (_bootingFeed) {
      debugPrint("🛑 Feed bootstrap stopped: already booting.");
      return;
    }

    if (_feedBooted && _bootedUid == uid) {
      debugPrint("🟢 Feed bootstrap skipped: already booted for uid=$uid");
      return;
    }

    if (!mounted) return;

    // v97p: set _loadingMoments = true so the body shows the
    // skeleton during the entire bootstrap -> syncFollows ->
    // loadTimeline chain. Without this, the body briefly shows
    // the empty card between the user's tap on FeedTab and the
    // first moments arriving.
    setState(() {
      _bootingFeed = true;
      _feedBootError = null;
      _momentsError = null;
      _loadingMoments = _timelineMoments.isEmpty;
    });

    try {
      debugPrint("🟢 Calling PingmeeFeedService.bootstrapMyFeeds()");

      final result = await _feedService.bootstrapMyFeeds();

      debugPrint("✅ Feed bootstrap finished");
      debugPrint("   user=${result.userFeed}");
      debugPrint("   timeline=${result.timelineFeed}");
      debugPrint("   notification=${result.notificationFeed}");

      if (!mounted) return;

      setState(() {
        _feedBooted = true;
        _bootingFeed = false;
        _bootedUid = uid;
      });

      unawaited(_syncFollowsThenLoad());
    } catch (e, st) {
      debugPrint("❌ Feed bootstrap failed: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      setState(() {
        _feedBooted = false;
        _bootingFeed = false;
        _feedBootError = "Feed setup needs attention.";
      });
    }
  }

  String _momentContentType({
    required String type,
    required String path,
  }) {
    final ext = p.extension(path).toLowerCase();

    if (type == "video") {
      if (ext == ".mov") return "video/quicktime";
      if (ext == ".webm") return "video/webm";
      if (ext == ".mkv") return "video/x-matroska";
      if (ext == ".avi") return "video/x-msvideo";
      return "video/mp4";
    }

    if (ext == ".png") return "image/png";
    if (ext == ".webp") return "image/webp";
    return "image/jpeg";
  }

  Future<File?> _makeVideoThumbFile(File videoFile, int index) async {
    final dir = await getTemporaryDirectory();

    final thumbPath = await video_thumb.VideoThumbnail.thumbnailFile(
      video: videoFile.path,
      thumbnailPath: dir.path,
      imageFormat: video_thumb.ImageFormat.JPEG,
      quality: 78,
    );

    if (thumbPath == null || thumbPath.isEmpty) return null;

    final file = File(thumbPath);
    if (!await file.exists()) return null;

    return file;
  }

  Future<void> _loadTimelineMoments({
    required String reason,
  }) async {
    // v97q: removed the `if (_loadingMoments) return;` guard.
    // v97p set _loadingMoments = true at the bootstrap step so
    // the skeleton shows immediately. That made the old guard
    // here exit without fetching. The flag is still reset to
    // false at the end of this function in both success and
    // catch paths, and re-entrancy is prevented by the await
    // semantics (a second call inside this function would
    // already be running through the same Future chain).
    debugPrint("🟢 Loading timeline Moments. reason=$reason");

    setState(() {
      _loadingMoments = true;
      _momentsError = null;
      // Reset pagination state on fresh load
      _nextOffset = 0;
      _hasMore = true;
    });

    try {
      final result = await _feedService.loadMyTimelineMoments();

      if (!mounted) return;

      // Build verified cache from all authors in loaded moments
      // Also include originalAuthorUid for reposts (to show verified badge on repost card)
      final uniqueUids = <String>{};
      for (final m in result.moments) {
        final uid = (m["authorUid"] ?? "").toString().trim();
        if (uid.isNotEmpty) uniqueUids.add(uid);
        final o = (m["originalAuthorUid"] ?? "").toString().trim();
        if (o.isNotEmpty) uniqueUids.add(o);
      }
      final cache = <String, bool>{};
      for (final uid in uniqueUids) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection("users")
              .doc(uid)
              .get();
          final verification = Map<String, dynamic>.from(snap.data()?["verification"] ?? {});
          cache[uid] = verification["status"] == "verified";
        } catch (_) {
          cache[uid] = false;
        }
      }


      if (!mounted) return;

      setState(() {
        _timelineMoments = result.moments;
        _verifiedCache = cache;
        _nextOffset = result.nextOffset;
        _hasMore = result.hasMore;
        _loadingMoments = false;
      });

      // Kick off per-author user-doc subscriptions so the live photoUrl
      // cache is built and stays in sync. The set of uids here covers
      // both direct authors and original authors of reposts.
      final photoUids = <String>{};
      for (final m in result.moments) {
        final a = (m["authorUid"] ?? "").toString().trim();
        if (a.isNotEmpty) photoUids.add(a);
        final o = (m["originalAuthorUid"] ?? "").toString().trim();
        if (o.isNotEmpty) photoUids.add(o);
      }
      unawaited(_refreshPhotoCacheFor(photoUids));
    } catch (e, st) {
      debugPrint("❌ Timeline Moments UI load failed: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      setState(() {
        _loadingMoments = false;
        _momentsError = "Couldn't load Moments.";
      });
    }
  }

  Future<void> _loadMoreMoments() async {
    if (_loadingMore || !_hasMore) return;

    debugPrint("🟢 Loading more moments. offset=$_nextOffset");

    setState(() => _loadingMore = true);

    try {
      final result = await _feedService.loadMyTimelineMoments(
        offset: _nextOffset,
      );

      if (!mounted) return;

      // Build verified cache for new authors
      final uniqueUids = <String>{};
      for (final m in result.moments) {
        final uid = (m["authorUid"] ?? "").toString().trim();
        if (uid.isNotEmpty) uniqueUids.add(uid);
        final o = (m["originalAuthorUid"] ?? "").toString().trim();
        if (o.isNotEmpty) uniqueUids.add(o);
      }
      for (final uid in uniqueUids) {
        if (!_verifiedCache.containsKey(uid)) {
          try {
            final snap = await FirebaseFirestore.instance
                .collection("users")
                .doc(uid)
                .get();
            final verification = Map<String, dynamic>.from(snap.data()?["verification"] ?? {});
            _verifiedCache[uid] = verification["status"] == "verified";
          } catch (_) {
            _verifiedCache[uid] = false;
          }
        }
      }

      setState(() {
        final existingIds = _timelineMoments
            .map((m) => (m["id"] ?? "").toString())
            .where((id) => id.isNotEmpty)
            .toSet();
        final newMoments = result.moments.where((m) {
          final id = (m["id"] ?? "").toString();
          return id.isNotEmpty && !existingIds.contains(id);
        }).toList();

        // Also pick up any new author uids from the freshly-loaded
        // page so the photo cache subscribes to them too.
        final photoUids = <String>{};
        for (final m in newMoments) {
          final a = (m["authorUid"] ?? "").toString().trim();
          if (a.isNotEmpty) photoUids.add(a);
          final o = (m["originalAuthorUid"] ?? "").toString().trim();
          if (o.isNotEmpty) photoUids.add(o);
        }
        unawaited(_refreshPhotoCacheFor(photoUids));

        _timelineMoments = [..._timelineMoments, ...newMoments];
        _nextOffset = result.nextOffset;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } catch (e, st) {
      debugPrint("❌ _loadMoreMoments failed: $e");
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _openCreateMomentSheet() async {
    final draft = await showModalBottomSheet<_CreateMomentDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateMomentSheet(),
    );

    if (draft == null) return;

    final cleaned = draft.text.trim();
    if (cleaned.isEmpty && draft.media.isEmpty) return;

    await _createAndReloadMoment(
      cleaned,
      pickedMedia: draft.media,
      // v87a: forward the @-mentions captured by the composer.
      mentions: draft.mentions,
      // v94c: poll question + options from the draft. When set,
      // createMomentV2 creates the chat poll itself and embeds
      // the full poll object on the activity. The composer's
      // _onTapPost populated these on the draft. Takes precedence
      // over pollId when both are set.
      pollId: draft.pollId,
      pollQuestion: draft.pollQuestion,
      pollOptions: draft.pollOptions,
    );
  }

  Future<void> _createAndReloadMoment(
    String text, {
    List<_MomentPickedMedia> pickedMedia = const [],
    // v87a: @-mention UIDs the user picked in the create-moment
    // composer. Forwarded to createMomentV2 (which stores on
    // activity + moment doc + sends moment_mention notifications).
    List<String> mentions = const [],
    // v92d: optional poll id from the composer.
    String? pollId,
    // v94c: poll question + options from the composer. When set,
    // createMomentV2 creates the chat-hosted poll itself and
    // embeds the full poll object on the activity. Takes
    // precedence over pollId when both are present.
    String? pollQuestion,
    List<String>? pollOptions,
  }) async {
    if (_creatingMoment) return;

    setState(() {
      _creatingMoment = true;
      _uploadStage = pickedMedia.isNotEmpty ? "uploading" : "posting";
    });
    _showPostingOverlay();

    try {
      final media = <Map<String, dynamic>>[];

      for (int i = 0; i < pickedMedia.length; i++) {
        final item = pickedMedia[i];

        // v85: sticker items are already uploaded to Firebase Storage
        // by the v85b composer (via the v63 uploadCommentImage cloud
        // function). Skip the putFile path and forward the existing
        // remoteUrl + kind directly.
        if (item.kind == "sticker" &&
            item.remoteUrl != null &&
            item.remoteUrl!.isNotEmpty) {
          media.add({
            "type": "image",
            "kind": "sticker",
            "url": item.remoteUrl!,
            "thumbUrl": item.remoteUrl!,
            "name": item.name ?? "sticker_${i}",
            "contentType": "image/gif",
          });
          continue;
        }

        File? file = item.file;

        if (file == null && item.asset != null) {
          file = await item.asset!.file;
        }

        if (file == null || !await file.exists()) {
          continue;
        }

        final uid = FirebaseAuth.instance.currentUser?.uid ?? "";
        final suffix = DateTime.now().millisecondsSinceEpoch;
        final ext = p.extension(file.path).toLowerCase();

        final type = item.type == "video" ? "video" : "image";
        final contentType = _momentContentType(
          type: type,
          path: file.path,
        );

        final filePrefix = type == "video" ? "vid" : "img";
        final fallbackExt = type == "video" ? ".mp4" : ".jpg";

        final ref = FirebaseStorage.instance
            .ref()
            .child("moments")
            .child(uid)
            .child("$filePrefix${suffix}_$i${ext.isEmpty ? fallbackExt : ext}");

        await ref.putFile(
          file,
          SettableMetadata(contentType: contentType),
        );

        final url = await ref.getDownloadURL();

        String thumbUrl = url;

        if (type == "video") {
          final thumbFile = await _makeVideoThumbFile(file, i);

          if (thumbFile != null) {
            final thumbRef = FirebaseStorage.instance
                .ref()
                .child("moments")
                .child(uid)
                .child("thumb_${suffix}_$i.jpg");

            await thumbRef.putFile(
              thumbFile,
              SettableMetadata(contentType: "image/jpeg"),
            );

            thumbUrl = await thumbRef.getDownloadURL();
          }
        }

        media.add({
          "type": type,
          "url": url,
          "thumbUrl": thumbUrl,
          "name": item.name ?? "moment_${type}_$suffix",
          "contentType": contentType,
        });
      }
      if (!mounted) return;
      setState(() => _uploadStage =
          pollQuestion != null ? "creatingPoll" : "posting");
      debugPrint("🧪 Moment media before create: count=${media.length}");
      for (final item in media) {
        debugPrint("🧪 Moment media item=$item");
      }

      if (!mounted) return;
      setState(() => _uploadStage = "posting");
      final createResult = await _feedService.createMoment(
        text: text,
        media: media,
        // v87a: forward @-mentions to the backend.
        mentions: mentions,
        // v92d: pollId-only legacy path.
        pollId: pollId,
        // v94c: full poll path (backend creates the chat poll).
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
      );

      debugPrint("🧪 createMoment result mediaCount=${createResult["mediaCount"]}");
      debugPrint("🧪 createMoment result media=${createResult["media"]}");
      if (!mounted) return;
      setState(() => _uploadStage = "reloading");
      await _loadTimelineMoments(reason: "after real moment create");

      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Moment posted."),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Couldn’t post Moment."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _creatingMoment = false;
          _uploadStage = null;
        });
        _removePostingOverlay();
      }
    }
  }

  /// v95a: shows the posting overlay above the modal sheet.
  /// The overlay is a floating card at the bottom-center of the
  /// screen, above the keyboard, with a spinner and the current
  /// stage label. It updates when _uploadStage changes.
  void _showPostingOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (overlayContext) {
        // v95h: small centered pill. isQuote=true makes the
        // fallback text say "Quoting moment...".
        return _PostingOverlay(
          stage: _uploadStage,
          isQuote: _isReposting,
        );
      },
    );
    _overlayEntry = entry;
    overlay.insert(entry);
  }

  /// v95a: removes the posting overlay (if any).
  void _removePostingOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }


  /// Loads up to 20 people who share interests or skills with
  /// the viewer, excluding self and existing friends. Uses the
  /// SAME `SearchService.searchPeopleOnly` path the search sheet
  /// uses so the wire format (interests/skills arrayContainsAny
  /// query) is identical.
  ///
  /// Reads the viewer's profile and friends on demand (no
  /// local cache) so this works for first-launch users who
  /// haven't hit the profile flow yet. Cost: 2 Firestore
  /// reads per call. Runs in the background; doesn't block
  /// the feed bootstrap.
  Future<void> _loadInlinePeopleSuggestions() async {
    if (_inlinePeopleLoading) return;
    _inlinePeopleLoading = true;

    try {
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) {
        if (mounted) {
          setState(() {
            _inlinePeopleSuggestions = const [];
            _inlinePeopleLoaded = true;
            _inlinePeopleLoading = false;
          });
        }
        return;
      }

      // Fetch the viewer's profile + friends list in parallel.
      final meRef =
          FirebaseFirestore.instance.collection("users").doc(myUid);
      final results = await Future.wait([
        meRef.get(),
        meRef.collection("friends").limit(200).get(),
      ]);
      final meSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final friendsSnap =
          results[1] as QuerySnapshot<Map<String, dynamic>>;

      final meData = meSnap.data() ?? const <String, dynamic>{};
      final interests = List<String>.from(meData["interests"] ?? const []);
      final skills = List<String>.from(meData["skills"] ?? const []);
      final verified = meData["verification"]?["status"] == "verified";

      // FriendIds come from the friends subcollection
      // (canonical source).
      final friendIds = <String>{
        for (final d in friendsSnap.docs)
          if ((d.data()["friendId"] ?? "").toString().isNotEmpty)
            (d.data()["friendId"] ?? "").toString(),
      };

      if (interests.isEmpty && skills.isEmpty) {
        if (mounted) {
          setState(() {
            _inlinePeopleSuggestions = const [];
            _inlinePeopleLoaded = true;
            _inlinePeopleLoading = false;
          });
        }
        return;
      }

      // Build a deduped lowercase token list. SearchService
      // handles the arrayContainsAny query.
      final tokens = <String>{
        ...interests.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty),
        ...skills.map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty),
      }.take(6).toList();

      if (tokens.isEmpty) {
        if (mounted) {
          setState(() {
            _inlinePeopleSuggestions = const [];
            _inlinePeopleLoaded = true;
            _inlinePeopleLoading = false;
          });
        }
        return;
      }

      final service = SearchService(
        FirebaseFirestore.instance,
        // PingVisibilityContext only carries viewerUid,
        // viewerVerified, viewerFriendIds. The interests and
        // skills we already collected above drive the
        // SearchService query directly via the tokens
        // parameter, so they don't need to live on the
        // visibility context.
        visibilityContext: PingVisibilityContext(
          viewerUid: myUid,
          viewerVerified: verified,
          // friendIds is already a Set<String> from the friends
          // subcollection scan; PingVisibilityContext expects a
          // Set<String>, not a List<String>.
          viewerFriendIds: friendIds,
        ),
      );

      // Fetch candidates, then filter non-self / non-friend and
      // cap at 20 (per the v43 design).
      final out = await service.searchPeopleOnly(tokens.join(' '));
      final filtered = out.where((r) {
        if (r.kind != SearchKind.user) return false;
        final uid = r.id.trim();
        if (uid.isEmpty || uid == myUid) return false;
        if (friendIds.contains(uid)) return false;
        return true;
      }).take(20).toList();

      if (!mounted) return;

      setState(() {
        _inlinePeopleSuggestions = filtered;
        _inlinePeopleLoaded = true;
        _inlinePeopleLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _inlinePeopleSuggestions = const [];
          _inlinePeopleLoaded = true;
          _inlinePeopleLoading = false;
        });
      }
    }
  }

  /// Lazy-creates a FriendStateManager for the given suggested
  /// uid, mirroring how the search sheet owns one manager per
  /// suggested uid. Returns a no-op manager (myUid="") if the
  /// viewer is signed out, so callers don't crash before auth
  /// is ready.
  FriendStateManager _getOrCreateInlineManager(String targetUid) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null || myUid.isEmpty) {
      return FriendStateManager(myUid: "", targetUid: targetUid);
    }
    return _inlinePeopleManagers.putIfAbsent(
      targetUid,
      () => FriendStateManager(myUid: myUid, targetUid: targetUid),
    );
  }

  /// Renders the "People who match your skills and interests"
  /// section in the feed's main scroll. Same visual language
  /// as the search screen's people-suggestion carousel: a
  /// header with a soft subtitle, then a horizontally-
  /// scrolling list of SearchConnectCard tiles, each 168 px
  /// wide. Max 20 people (already capped at the data layer).
  Widget _buildInlinePeopleCarousel() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final muted = isDark
        ? Colors.white.withOpacity(.62)
        : const Color(0xFF6B7280);

    final visible = _inlinePeopleSuggestions
        .where((r) => !_inlinePeopleDismissed.contains(r.id))
        .toList();

    if (visible.isEmpty) {
      // Defensive: the itemBuilder only calls this when the
      // list is non-empty, but if the user dismissed every
      // card between the gate check and the build call, we
      // still need to return something.
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              "Suggestions",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 14.2,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              "People matching your interests and skills.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 12.2,
                fontWeight: FontWeight.w400,
                color: muted,
                height: 1.3,
              ),
            ),
          ),
          SizedBox(
            // 231 px = outer 6/6/6/0 + content 215 (incl.
            // inner 4/4/4/4 padding and the new 18-px
            // gap between username and button) + 4 px
            // margin for the rounded card edge. The
            // card's bottom is now 0 so the connect
            // button hugs the carousel's bottom edge;
            // the breath lives between the username and
            // the button.
            height: 231,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              itemCount: visible.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final r = visible[index];
                return SearchConnectCard(
                  result: r,
                  onOpenProfile: (uid) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileTab(profileUid: uid),
                      ),
                    );
                  },
                  onDismiss: () {
                    setState(() {
                      _inlinePeopleDismissed.add(r.id);
                    });
                  },
                  isFriend: _inlinePeopleDismissed.contains(r.id),
                  manager: _getOrCreateInlineManager(r.id),
                  // The shared widget lives in a shared file
                  // and can't reach our private State class.
                  // We wire the callback through so each
                  // connect tap re-renders the feed's
                  // carousel with the new button state.
                  onConnectSent: () {
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMomentsBody() {
    if (_feedMode == _FeedMode.aroundMe) {
      return const _FeedComingSoonState(
        icon: PhosphorIcons.mapPinArea,
        title: "Around Me is coming",
        subtitle:
            "This will show Moments from people, events, and communities near your discovery radius.",
      );
    }

    if (_feedMode == _FeedMode.explore) {
      return const _FeedComingSoonState(
        icon: PhosphorIcons.compass,
        title: "Explore is coming",
        subtitle:
            "This will help you discover interesting Moments beyond your normal radius.",
      );
    }
    if (_bootingFeed && !_feedBooted) {
      return const _FeedMomentsSkeleton();
    }

    if (_feedBootError != null) {
      return _MomentsCenterState(
        title: "Moments need attention",
        subtitle: _feedBootError!,
        buttonLabel: "Try again",
        onPressed: () => _bootstrapFeed(reason: "retry button"),
      );
    }

    if (_loadingMoments && _timelineMoments.isEmpty) {
      return const _FeedMomentsSkeleton();
    }

    if (_momentsError != null && _timelineMoments.isEmpty) {
      return _MomentsCenterState(
        title: "Couldn’t load Moments",
        subtitle: "Try again in a moment.",
        buttonLabel: "Reload",
        onPressed: () => _loadTimelineMoments(reason: "error reload"),
      );
    }

    if (_timelineMoments.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadTimelineMoments(reason: "pull refresh empty"),
        color: AppColors.brandGreen,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Center the empty state vertically so the user's eye lands
            // on it without scrolling. The create-moment preview sits
            // at the natural top of the column, the empty card sits
            // below it, and the whole thing is vertically centered
            // within the available feed area.
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 18 - 120,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CreateMomentPreviewCard(
        creating: _creatingMoment,
        onCreateMoment: _openCreateMomentSheet,
        myPhotoUrl: _myPhotoUrl,
      ),
                      const SizedBox(height: 24),
                      const _MomentsEmptyCard(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    final footerCount = (_hasMore || _loadingMore) ? 1 : 0;

    return RefreshIndicator(
      onRefresh: () => _loadTimelineMoments(reason: "pull refresh"),
      color: AppColors.brandGreen,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleFeedScrollNotification,
        child: ListView.separated(
          controller: _feedScrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
        // +2 accounts for the share card at itemIndex 0 AND
        // the inline people-suggestion carousel slot at
        // itemIndex 11. The carousel renders only when the
        // gates pass (see itemBuilder); otherwise it's a
        // zero-height SizedBox so itemCount stays consistent
        // and ListView.separated doesn't double-count.
        itemCount: _timelineMoments.length + 2 + footerCount,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _CreateMomentPreviewCard(
        creating: _creatingMoment,
        onCreateMoment: _openCreateMomentSheet,
        myPhotoUrl: _myPhotoUrl,
      );
          }

          // Inline people-suggestion carousel at itemIndex
          // 11, but only if we have at least 10 moments to
          // anchor it against (so the user has actually
          // scrolled past the 10th post) AND the loader has
          // produced results. If either gate fails, skip the
          // carousel and shift the moment index down by 1.
          if (index == _inlinePeopleItemIndex &&
              _inlinePeopleLoaded &&
              _inlinePeopleSuggestions.isNotEmpty &&
              _timelineMoments.length >= 10) {
            return _buildInlinePeopleCarousel();
          }

          // Compute the moment index, accounting for the
          // carousel slot if it would have appeared at this
          // position but was skipped (e.g. fewer than 10
          // moments, or loader still running).
          final momentIndex = (index > _inlinePeopleItemIndex)
              ? index - 2
              : index - 1;

          if (momentIndex >= _timelineMoments.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.brandGreen),
              ),
            );
          }

          final moment = _timelineMoments[momentIndex];

          final authorUid = (moment["authorUid"] ?? "").toString().trim();
          return _MomentCard(
            data: moment,
            onLike: () => _toggleMomentLike(momentIndex),
            onComment: () => _openMomentComments(moment),
            onSave: () => _toggleMomentBookmark(momentIndex),
            onRepost: () => _openRepostSheet(moment),
            onMore: () => _openMomentMoreSheet(moment, momentIndex),
            onShare: () => _shareMoment(moment),
            authorVerified: _verifiedCache[authorUid] ?? false,
            verifiedCache: _verifiedCache,
            photoCache: _photoCache,
            feedService: _feedService,
            // v88: pass CommentService down so _MomentBody can
            // resolve @-mention UIDs to UserRefs (same pattern as
            // the comment composer in MomentCommentTile).
            commentService: _commentService,
            // v90: pass the current viewer's connections cache
            // down so _MomentBody can fall back to client-side
            // @-tag resolution when the backend's `mentions[]`
            // field is empty (pre-v87a deploy or mention is of
            // a stranger to the viewer).
            myConnectionsByTag: _myConnectionsByTag,
            onAuthorTap: _onOpenUserProfile,
          );
        },
      ),
      ),
    );
  }

  Future<void> _openMomentComments(Map<String, dynamic> moment) async {
    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty) return;

    final momentId = _momentIdFromForeignId(
      (moment["foreignId"] ?? "").toString(),
      fallback: activityId,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => MomentCommentsSheet(
        activityId: activityId,
        commentService: _commentService,
        onAuthorTap: (authorUid) {
          if (authorUid.isEmpty) return;
          Navigator.of(sheetContext).pop();
          _onOpenUserProfile?.call(authorUid);
        },
        onOpenReplies: (parent) {
          // Pop the sheet, then push the replies sub-page.
          // Push ABOVE the sheet so the back button returns to

          // comments (not the feed).

          Navigator.of(sheetContext, rootNavigator: true).push(

            MaterialPageRoute<void>(

              builder: (_) => MomentCommentRepliesScreen(
                rootComment: parent,
                activityId: activityId,
                commentService: _commentService,
                onAuthorTap: (authorUid) {
                  if (authorUid.isEmpty) return;
                  _onOpenUserProfile?.call(authorUid);
                },
                onShareToConnection: (comment) =>
                    _shareCommentToConnection(sheetContext, comment, moment, momentId),
              ),
            ),
          );
        },
        onShareToConnection: (comment) =>
            _shareCommentToConnection(sheetContext, comment, moment, momentId),
      ),
    );

    await _loadTimelineMoments(reason: "after comments sheet");
  }

  /// Resolve a Firestore moment id from a Stream foreign_id, with a
  /// safe fallback when the foreign_id is missing.
  String _momentIdFromForeignId(String foreignId, {required String fallback}) {
    final f = foreignId.trim();
    if (f.startsWith("moment:")) return f.substring(7);
    return fallback;
  }

  /// Open the connection picker for a comment, then navigate to the chat
  /// once the shared-comment message has been posted.
  Future<void> _shareCommentToConnection(
    BuildContext sheetContext,
    Comment comment,
    Map<String, dynamic> moment,
    String momentId,
  ) async {
    final authorName = (moment["authorName"] ?? "").toString().trim();
    final text = (moment["text"] ?? "").toString().trim();
    await showCommentConnectionPicker(
      sheetContext,
      commentText: comment.text,
      commentAuthorName: comment.authorName,
      commentAuthorPhotoUrl: comment.authorPhotoUrl,
      momentId: momentId.isEmpty ? null : momentId,
      momentText: text.isEmpty ? null : text,
      momentAuthorName: authorName.isEmpty ? null : authorName,
      commentService: _commentService,
      onSent: (cid) async {
        // cid is the messaging:dm_uid1_uid2 channel id. Re-open via the
        // canonical router so the page renders with the right Stream
        // provider context. The router checks friend connection + creates
        // the channel if missing, then returns a Channel object.
        if (!mounted) return;
        try {
          final channel = await PingmeeMessageRequestRouter.openDirectChat(
            otherUid: _otherUidFromCid(cid, myUid: _authCurrentUid) ?? cid,
          );
          if (!context.mounted) return;
          Navigator.of(context).push(pingmeeChatRoute(channel));
        } catch (_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Comment shared. Open chat from the Inbox tab.")),
          );
        }
      },
    );
  }

  /// Best-effort reverse: extract the OTHER uid from a Stream cid like
  /// `messaging:dm_uid1_uid2`. Returns null if anything goes wrong.
  String? _otherUidFromCid(String cid, {String? myUid}) {
    final parts = cid.split(':');
    if (parts.length != 2) return null;
    final tail = parts[1];
    if (!tail.startsWith('dm_')) return null;
    final ids = tail.substring(3).split('_');
    if (ids.length != 2) return null;
    if (myUid != null && ids[0] == myUid) return ids[1];
    if (myUid != null && ids[1] == myUid) return ids[0];
    return ids[0];
  }

  /// Best-effort accessor for the current uid from the Auth instance.
  String? get _authCurrentUid => FirebaseAuth.instance.currentUser?.uid;

  Future<void> _toggleMomentLike(int index) async {
    if (index < 0 || index >= _timelineMoments.length) return;

    final moment = Map<String, dynamic>.from(_timelineMoments[index]);

    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty) return;

    // Extract Firestore document ID from foreignId (format: "moment:{firestoreId}")
    final foreignId = (moment["foreignId"] ?? "").toString().trim();
    final momentId = foreignId.startsWith("moment:")
        ? foreignId.substring(7)
        : activityId;

    if (_likingMomentIds.contains(activityId)) {
      debugPrint("🛑 Like ignored: already updating $activityId");
      return;
    }

    final currentlyLiked = moment["likedByMe"] == true;
    final reactionId = (moment["myLikeReactionId"] ?? "").toString().trim();
    final currentCount = moment["likeCount"] is num
        ? (moment["likeCount"] as num).toInt()
        : 0;

    _likingMomentIds.add(activityId);

    setState(() {
      _timelineMoments[index] = {
        ...moment,
        "likedByMe": !currentlyLiked,
        "likeCount": currentlyLiked
            ? (currentCount - 1).clamp(0, 999999)
            : currentCount + 1,
      };
    });

    try {
      final result = await _feedService.toggleMomentLike(
        activityId: activityId,
        currentlyLiked: currentlyLiked,
        reactionId: reactionId,
        momentId: momentId,
      );

      if (!mounted) return;

      final updated = Map<String, dynamic>.from(_timelineMoments[index]);

      setState(() {
        _timelineMoments[index] = {
          ...updated,
          "likedByMe": result["liked"] == true,
          "myLikeReactionId": (result["reactionId"] ?? "").toString(),
        };
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _timelineMoments[index] = moment;
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Couldn’t update like."),
        ),
      );
    } finally {
      _likingMomentIds.remove(activityId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_printedBuildLog) {
      _printedBuildLog = true;
      debugPrint("🟢 FeedTab build fired");
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final drawerOffset = _drawerAnimController.drive(
      Tween<double>(begin: 0, end: 280),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: Stack(
        children: [
          // ── Drawer overlay ─────────────────────────────────────
          if (_drawerAnimController.value > 0)
            GestureDetector(
              onTap: _toggleDrawer,
              child: AnimatedBuilder(
                animation: _drawerAnimController,
                builder: (context, _) => Container(
                  color: Colors.black.withOpacity(0.35 * _drawerAnimController.value),
                ),
              ),
            ),

          // ── Drawer panel ──────────────────────────────────────
          SizeTransition(
            sizeFactor: _drawerAnimController,
            axisAlignment: -1.0,
            axis: Axis.horizontal,
            child: _ThreadsDrawer(
              selected: _feedMode,
              onSelect: _selectFeedMode,
            ),
          ),

          // ── Tap-to-close touch target on feed peek strip ──────────
          // No visual overlay — just a transparent touch target so tapping
          // the feed area (right of the drawer edge) closes the drawer.
          AnimatedBuilder(
            animation: _drawerAnimController,
            builder: (context, _) {
              final animValue = _drawerAnimController.value;
              if (animValue <= 0) return const SizedBox.shrink();
              return Positioned(
                left: 280 * animValue,
                top: 0,
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleDrawer,
                  child: const SizedBox.expand(),
                ),
              );
            },
          ),

          // ── Main content (swipe right to close drawer) ──────
          GestureDetector(
            onHorizontalDragUpdate: _handleDragUpdate,
            onHorizontalDragEnd: _handleDragEnd,
            child: AnimatedBuilder(
              animation: _drawerAnimController,
              builder: (context, _) => Transform.translate(
              offset: Offset(drawerOffset.value, 0),
              child: SafeArea(
                child: Stack(
                  children: [
                    // Centre-top banner, positioned BEHIND the column.
                    // Sits at top: 0 of the stack (just below the safe-
                    // area) and is centred horizontally. The Column on
                    // top of it (the hamburger row + body) paints over
                    // the banner, so:
                    //   - the top of the banner is hidden behind the
                    //     hamburger row (which has a transparent bg);
                    //   - the share card's translucent white fill
                    //     (.88) shows the banner faintly through it;
                    //   - the banner peeks out on the left/right of
                    //     the hamburger button and above the share
                    //     card.
                    // The banner is in a Positioned so it does NOT push
                    // the share card (or anything else) down.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LayoutBuilder(
                        builder: (context, c) {
                          // 60% of the available row width, clamped so
                          // the banner stays small on every screen
                          // (140 px min, 240 px max) and remains
                          // narrower than the share card so its
                          // edges are visible around the card.
                          final double w = c.maxWidth;
                          final double bannerW =
                              (w * 0.6).clamp(140.0, 240.0);
                          return Center(
                            child: SizedBox(
                              width: bannerW,
                              height: bannerW / 1.5, // 1.5:1 aspect
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.asset(
                                  'assets/images/feed-center.png',
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Column(
                  children: [
                    // Threads-style header — just the hamburger; the notifications bell
                    // lives in the discover overlay's header on the map tab.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 16, 6),
                      child: Row(
                        children: [
                          // Hamburger / Threads menu button — always visible
                          Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              onTap: _toggleDrawer,
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Center(
                                  child: AnimatedBuilder(
                                    animation: _drawerAnimController,
                                    builder: (context, _) => Icon(
                                      _drawerAnimController.value > 0.5
                                          ? PhosphorIcons.x(PhosphorIconsStyle.bold)
                                          : PhosphorIcons.list(PhosphorIconsStyle.bold),
                                      size: 24,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),

                        ],
                      ),
                    ),
                    Expanded(
                      child: _buildMomentsBody(),
                    ),
                  ],
                    ),
                  ],
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

class _ThreadsDrawer extends StatelessWidget {
  final _FeedMode selected;
  final ValueChanged<_FeedMode> onSelect;

  const _ThreadsDrawer({
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Constrain background to just the menu content width, not full screen.
    // Box shadow is small (4px) so it doesn't spill past the content edge.
    return Container(
      width: 260, // only as wide as the menu content needs
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(2, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 8, 22, 4),
              child: Text(
                'Moments',
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 8),
              child: Divider(height: 1, color: Color(0xFFE4E6EB)),
            ),
            _DrawerItem(
              icon: PhosphorIcons.heart(PhosphorIconsStyle.light),
              label: 'Liked Moments',
              selected: selected == _FeedMode.liked,
              onTap: () => onSelect(_FeedMode.liked),
            ),
            _DrawerItem(
              icon: PhosphorIcons.bookmark(PhosphorIconsStyle.light),
              label: 'Saved Moments',
              selected: selected == _FeedMode.saved,
              onTap: () => onSelect(_FeedMode.saved),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
              child: Divider(height: 1, color: Color(0xFFE4E6EB)),
            ),
            _DrawerItem(
              icon: PhosphorIcons.userCircle(PhosphorIconsStyle.light),
              label: 'Connections',
              selected: selected == _FeedMode.following,
              onTap: () => onSelect(_FeedMode.following),
            ),
            _DrawerItem(
              icon: PhosphorIcons.mapPin(PhosphorIconsStyle.light),
              label: 'Around Me',
              selected: selected == _FeedMode.aroundMe,
              onTap: () => onSelect(_FeedMode.aroundMe),
            ),
            _DrawerItem(
              icon: PhosphorIcons.compass(PhosphorIconsStyle.light),
              label: 'Explore',
              selected: selected == _FeedMode.explore,
              onTap: () => onSelect(_FeedMode.explore),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 24,
                color: selected ? Colors.black : Colors.black54,
              ),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? Colors.black : Colors.black54,
                ),
              ),
              if (selected) ...[
                const Spacer(),
                Icon(
                  PhosphorIcons.check(PhosphorIconsStyle.bold),
                  size: 18,
                  color: AppColors.brandGreen,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateMomentPreviewCard extends StatelessWidget {
  final bool creating;
  final VoidCallback onCreateMoment;

  // v76: current user's profile photo URL. When non-null AND
  // non-empty, the card's leading 42x42 icon becomes a
  // ClipOval Image.network with the photo. When null/empty,
  // fall back to the original brand-green sparkle icon.
  final String? myPhotoUrl;

  const _CreateMomentPreviewCard({
    required this.creating,
    required this.onCreateMoment,
    this.myPhotoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: creating ? null : onCreateMoment,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.88),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.black.withOpacity(.05)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.04),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              // v76: leading avatar = current user's profile photo
              // when available, else the original brand-green
              // sparkle icon. See _buildLeadingAvatar().
              _buildLeadingAvatar(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  creating
                      ? "Posting your Moment..."
                      : "Share what’s happening around you.",
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: creating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        "Post",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: Colors.white,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v76: leading 42x42 avatar. Shows the current user's profile
  /// photo if we have a non-empty URL, otherwise falls back to the
  /// original brand-green sparkle icon. ClipOval makes the image
  /// a perfect circle; the thin brand-green border keeps the
  /// avatar visually framed inside the card.
  Widget _buildLeadingAvatar() {
    final url = myPhotoUrl;
    if (url == null || url.isEmpty) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: AppColors.brandGreen.withOpacity(.10),
          shape: BoxShape.circle,
        ),
        child: Icon(
          PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
          size: 20,
          color: AppColors.brandGreen,
        ),
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.brandGreen.withOpacity(.30),
          width: 1.4,
        ),
      ),
      child: ClipOval(
        child: Image.network(
          url,
          width: 42,
          height: 42,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 42,
            height: 42,
            color: AppColors.brandGreen.withOpacity(.10),
            alignment: Alignment.center,
            child: Icon(
              PhosphorIcons.user(PhosphorIconsStyle.fill),
              size: 20,
              color: AppColors.brandGreen,
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: 42,
              height: 42,
              color: AppColors.brandGreen.withOpacity(.10),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FeedModeTabs extends StatelessWidget {
  final _FeedMode selected;
  final ValueChanged<_FeedMode> onChanged;

  const _FeedModeTabs({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.78),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(.65)),
      ),
      child: Row(
        children: [
          _FeedModeTab(
            label: "Connections",
            selected: selected == _FeedMode.following,
            onTap: () => onChanged(_FeedMode.following),
          ),
          _FeedModeTab(
            label: "Around Me",
            selected: selected == _FeedMode.aroundMe,
            onTap: () => onChanged(_FeedMode.aroundMe),
          ),
          _FeedModeTab(
            label: "Explore",
            selected: selected == _FeedMode.explore,
            onTap: () => onChanged(_FeedMode.explore),
          ),
        ],
      ),
    );
  }
}

class _FeedModeTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FeedModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? Colors.black : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : Colors.black.withOpacity(.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedComingSoonState extends StatelessWidget {
  final IconData Function(PhosphorIconsStyle) icon;
  final String title;
  final String subtitle;

  const _FeedComingSoonState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.82),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.black.withOpacity(.055)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon(PhosphorIconsStyle.light),
                size: 42,
                color: Colors.black.withOpacity(.48),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  color: Colors.black.withOpacity(.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateMomentDraft {
  final String text;
  final List<_MomentPickedMedia> media;
  // v85: @mention UIDs the user picked in the composer. v85b
  // captures them client-side and forwards to the backend on submit.
  // The backend createMomentV2 already accepts a `mentions` field
  // (v85c writes it through to the activity + moment doc) but the
  // v85b push does NOT change the cloud function — v85c will.
  // Until v85c is deployed, mentions are sent but silently dropped
  // on the server. The composer UX is identical to comments.
  final List<String> mentions;
  // v92d: optional poll id from createFeedPoll. Set when the user
  // opens the poll composer, fills in the question + options, and
  // submits. The cloud function createMomentV2 stores it on the
  // activity + moment doc (v92b). Frontend reads it back via the
  // `poll` field in loadMyTimelineMoments and renders the inline
  // poll widget in the feed card (v92e).
  final String? pollId;
  // v94c: full poll question + options from the composer. When
  // these are set (and pollId is null), createMomentV2 creates
  // the chat poll itself on the backend and embeds the full poll
  // object on the activity. Takes precedence over pollId.
  final String? pollQuestion;
  final List<String>? pollOptions;

  const _CreateMomentDraft({
    required this.text,
    required this.media,
    this.mentions = const <String>[],
    this.pollId,
    this.pollQuestion,
    this.pollOptions,
  });
}

class _MomentPickedMedia {
  final String id;
  // type: image | video | sticker. Stickers are GIFs uploaded to
  // Firebase Storage via the v63 uploadCommentImage cloud function.
  final String type;
  final AssetEntity? asset;
  final File? file;
  final String? name;
  final Uint8List? previewBytes;
  // v85: kind is a more explicit discriminator ("sticker" for animated
  // GIFs, null for image/video). The backend preserves it through
  // createMomentV2 so the moment card can render the animated URL.
  final String? kind;
  // v85: for sticker items the GIF bytes have already been uploaded to
  // Firebase Storage by the time they land here — remoteUrl is the
  // public download URL. The draft consumer forwards it as the media
  // item's url (no second upload needed). Null for image/video items
  // (which still go through the existing Firebase Storage upload path).
  final String? remoteUrl;

  const _MomentPickedMedia({
    required this.id,
    required this.type,
    this.asset,
    this.file,
    this.name,
    this.previewBytes,
    this.kind,
    this.remoteUrl,
  });
}

class _CreateMomentSheet extends StatefulWidget {
  const _CreateMomentSheet();

  @override
  State<_CreateMomentSheet> createState() => _CreateMomentSheetState();
}

class _CreateMomentSheetState extends State<_CreateMomentSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  static const int _maxChars = 1000; // v91: was 500

  // v85: _media now also holds sticker items. The existing image/video
  // fields (asset, file, previewBytes) are still used for those items.
  // Stickers carry a non-null `kind` and `remoteUrl` (the already-uploaded
  // animated GIF URL).
  final List<_MomentPickedMedia> _media = [];

  // v85: mention picker state. Mirrors _CommentComposerState.
  final List<String> _mentionUids = <String>[];
  final Map<String, UserRef> _mentionedUsersCache = <String, UserRef>{};
  final CommentService _commentService = CommentService();
  bool _emojiOpen = false;
  bool _mentionPickerVisible = false;
  bool _uploadingImage = false;

  // v92d: poll composer state. Mirrors the chat poll composer's
  // contract (see chat_channel_page.dart _PingmeePollDraft). When
  // the user opens the poll composer and submits, we call
  // _feedService.createFeedPoll(...) to get a pollId, stash it on
  // _pollId, and the post handler forwards it via _CreateMomentDraft.
  // The question/options are kept for the post text (so the user
  // still sees what they asked) but the canonical poll lives on
  // Stream Feeds.
  String? _pollId;
  String _pollQuestion = "";
  final List<TextEditingController> _pollOptionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];
  final PingmeeFeedService _feedService = PingmeeFeedService();
  bool _creatingPoll = false;

  bool get _mediaFull => _media.length >= 4;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    // v92d: clean up the poll option controllers so we don't leak
    // TextEditingController state across composer opens.
    for (final c in _pollOptionCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (!_focusNode.hasFocus) {
      if (_emojiOpen) setState(() => _emojiOpen = false);
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
    }
  }

  // -----------------------------------------------------------------
  // Mention picker — same logic as CommentComposer.
  // -----------------------------------------------------------------

  void _onTextChanged() {
    if (!mounted) return;
    final text = _controller.text;
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final cursor = selection.baseOffset;
    if (cursor <= 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final before = text.substring(0, cursor);
    final atIndex = before.lastIndexOf("@");
    if (atIndex < 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final between = before.substring(atIndex + 1);
    if (between.contains(" ") || between.contains("\n")) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (between.length > 32) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (!_mentionPickerVisible) {
      setState(() => _mentionPickerVisible = true);
    }
  }

  void _insertAtCursor(String s) {
    final ctrl = _controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      final newText = ctrl.text + s;
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      return;
    }
    final newText = ctrl.text.replaceRange(sel.start, sel.end, s);
    final newCursor = sel.start + s.length;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  void _onPickMention(UserRef u) {
    final tag = "@${u.mentionTag} ";
    final ctrl = _controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      _insertAtCursor(tag);
    } else {
      final text = ctrl.text;
      final atIndex = text.lastIndexOf("@", sel.start - 1);
      if (atIndex >= 0) {
        final newText = text.replaceRange(atIndex, sel.start, tag);
        ctrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: atIndex + tag.length),
        );
      } else {
        _insertAtCursor(tag);
      }
    }
    if (!_mentionUids.contains(u.uid)) {
      _mentionUids.add(u.uid);
      _mentionedUsersCache[u.uid] = u;
    }
    setState(() => _mentionPickerVisible = false);
    _focusNode.requestFocus();
  }

  // -----------------------------------------------------------------
  // Image source sheet (camera or library) — same shape as
  // CommentComposer._showImageSourceSheet. Replaces the two separate
  // "Gallery" and "Camera" text buttons.
  // -----------------------------------------------------------------

  Future<void> _onTapImageButton() async {
    if (_mediaFull) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text(
                  "Take photo",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("camera"),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text(
                  "Choose from library",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("library"),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (picked == "camera") {
      await _pickMediaFromCamera();
    } else if (picked == "library") {
      await _pickMediaFromGallery();
    }
  }

  // -----------------------------------------------------------------
  // Image/video pickers — same as before, image/video items still go
  // through the Firebase Storage upload path in _createAndReloadMoment.
  // -----------------------------------------------------------------

  Future<void> _pickMediaFromGallery() async {
    if (_mediaFull) return;
    try {
      final maxPick = 4 - _media.length;
      final PermissionState permission =
          await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) return;

      final assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          maxAssets: maxPick,
          requestType: RequestType.common,
          selectedAssets: _media
              .where((m) => m.asset != null)
              .map((m) => m.asset!)
              .toList(),
        ),
      );
      if (assets == null || assets.isEmpty) return;

      final existingIds = _media.map((m) => m.id).toSet();
      for (final asset in assets) {
        if (_media.length >= 4) break;
        final id = "asset_${asset.id}";
        if (existingIds.contains(id)) continue;
        _media.add(
          _MomentPickedMedia(
            id: id,
            type: asset.type == AssetType.video ? "video" : "image",
            asset: asset,
            name: asset.title,
          ),
        );
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      debugPrint("❌ Moment gallery pick error: $e");
    }
  }

  Future<void> _pickMediaFromCamera() async {
    if (_mediaFull) return;
    try {
      XFile? captured;
      CameraPickerViewType? capturedType;
      await CameraPicker.pickFromCamera(
        context,
        pickerConfig: CameraPickerConfig(
          enableRecording: true,
          textDelegate: const EnglishCameraPickerTextDelegate(),
          onXFileCaptured: (
            XFile file,
            CameraPickerViewType viewType,
          ) {
            captured = file;
            capturedType = viewType;
            Navigator.of(context).pop();
            return true;
          },
        ),
      );
      if (captured == null) return;

      final file = File(captured!.path);
      if (!await file.exists()) return;

      final id = "cam_${DateTime.now().millisecondsSinceEpoch}";
      final ext = p.extension(file.path).toLowerCase();
      final isVideo =
          capturedType == CameraPickerViewType.video ||
          [".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi"].contains(ext);

      Uint8List? previewBytes;
      if (isVideo) {
        previewBytes = await video_thumb.VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: video_thumb.ImageFormat.JPEG,
          quality: 75,
        );
      }

      setState(() {
        _media.add(
          _MomentPickedMedia(
            id: id,
            type: isVideo ? "video" : "image",
            file: file,
            name: p.basename(file.path),
            previewBytes: previewBytes,
          ),
        );
      });
    } catch (e) {
      debugPrint("❌ Moment camera pick error: $e");
    }
  }

  // -----------------------------------------------------------------
  // Sticker picker — same GIPHY key, same showStickers:true,
  // showGIFs:false. Picks the best original-animated URL.
  // -----------------------------------------------------------------

  Future<void> _onPickSticker() async {
    if (kPingmeeGiphyApiKey.contains("PASTE_")) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Sticker library is not set up yet.")),
      );
      return;
    }
    if (_mediaFull) return;
    try {
      final gif = await GiphyGet.getGif(
        context: context,
        apiKey: kPingmeeGiphyApiKey,
        lang: GiphyLanguage.english,
        tabColor: Colors.black,
        debounceTimeInMilliseconds: 350,
        showGIFs: false,
        showStickers: true,
        showEmojis: false,
      );
      if (gif == null) return;

      final url = bestGiphyUrl(gif);
      if (url.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't load sticker.")),
        );
        return;
      }
      if (!mounted) return;
      // Download the bytes + upload via the v63 uploadCommentImage cloud
      // function (which is auth-gated + world-readable + returns a
      // public URL). Storage rules (storage.rules) allow
      // read/write on all paths so this works without rule changes.
      setState(() => _uploadingImage = true);
      try {
        final resp = await http.get(Uri.parse(url));
        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
          throw Exception("GIPHY fetch failed: ${resp.statusCode}");
        }
        // The localId is a placeholder — the cloud function uses it to
        // scope the storage path. The composer treats each picked
        // sticker as a draft of the current moment; the storage path
        // will be remapped to a moment-scoped path on submit in a
        // future push. For v85 we accept the slightly leaky
        // comments/-prefixed path because storage rules allow it.
        final localId =
            "sticker-${DateTime.now().millisecondsSinceEpoch}";
        final uploadedUrl = await _commentService.uploadCommentImage(
          activityId: "create-moment",
          commentIdLocal: localId,
          bytes: resp.bodyBytes,
          contentType: "image/gif",
        );
        if (!mounted) return;
        final id =
            (gif.id ?? "").toString().isNotEmpty ? gif.id!.toString() : localId;
        setState(() {
          _media.add(
            _MomentPickedMedia(
              id: "sticker_$id",
              type: "sticker",
              name: "sticker_$id.gif",
              kind: "sticker",
              remoteUrl: uploadedUrl,
            ),
          );
          _uploadingImage = false;
        });
      } catch (e) {
        debugPrint("❌ Sticker upload failed: $e");
        if (!mounted) return;
        setState(() => _uploadingImage = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't upload sticker.")),
        );
      }
    } catch (e) {
      debugPrint("❌ GIPHY sticker picker error: $e");
    }
  }

  void _removeMedia(_MomentPickedMedia item) {
    setState(() {
      _media.removeWhere((m) => m.id == item.id);
    });
  }

  bool get _canPost {
    final text = _controller.text.trim();
    // v94a: poll-only moments are now allowed (text/media are no
    // longer required when a poll is attached). The backend
    // createMomentV2 reads the embedded poll and renders it on the
    // activity's `poll` field.
    final hasPoll = _pollId != null && _pollId!.isNotEmpty;
    return (text.isNotEmpty || _media.isNotEmpty || hasPoll) &&
        text.length <= _maxChars;
  }

  void _onTapPost() {
    if (!_canPost) return;
    Navigator.pop(
      context,
      _CreateMomentDraft(
        text: _controller.text.trim(),
        media: List<_MomentPickedMedia>.from(_media),
        mentions: List<String>.from(_mentionUids),
        // v92d: pass pollId through to the caller. The poll was
        // already created via _openPollComposer on submit, and the
        // resulting pollId is stashed on _pollId.
        pollId: _pollId,
        // v94c: also pass the question + options from the local
        // poll composer state. The backend (createMomentV2 v94a)
        // will create the chat-hosted poll itself when pollName +
        // pollOptions are present, embedding the full poll object
        // on the activity. Takes precedence over pollId.
        pollQuestion: _pollQuestion.trim().isEmpty ? null : _pollQuestion.trim(),
        pollOptions: _pollOptionCtrls.isEmpty
            ? null
            : _pollOptionCtrls
                .map((c) => c.text.trim())
                .where((t) => t.isNotEmpty)
                .toList(),
      ),
    );
  }

  // v92d: open the poll composer. Mirrors _PingmeeCreatePollSheet
  // from chat_channel_page.dart. On submit, calls createFeedPoll
  // on the backend (v92a) to get a pollId, stashes it on _pollId,
  // and renders a small chip below the AttachmentBar so the user
  // can see the poll is attached. Tapping the chip removes it.
  Future<void> _openPollComposer() async {
    debugPrint("v92l _openPollComposer: invoked, _creatingPoll=$_creatingPoll");
    if (_creatingPoll) return;

    final draft = await showModalBottomSheet<_PollComposerDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _FeedPollComposerSheet(
        initialQuestion: "",
        initialOptions: null,
      ),
    );

    debugPrint("v92l _openPollComposer: sheet returned, draft=" +
        (draft == null ? "null" : "non-null(\${draft.question}, \${draft.options.length} opts)"));
    if (draft == null) return;
    if (!mounted) return;

    setState(() => _creatingPoll = true);
    try {
      debugPrint("v92l _openPollComposer: calling createFeedPoll...");
      final pollId = await _feedService.createFeedPoll(
        name: draft.question,
        options: draft.options,
      );
      debugPrint("v92l _openPollComposer: createFeedPoll returned pollId=$pollId");
      if (!mounted) return;
      setState(() {
        _pollId = pollId;
        _pollQuestion = draft.question;
        // Refresh the option ctrls with the final values so the chip
        // can render a preview.
        for (final c in _pollOptionCtrls) {
          c.dispose();
        }
        _pollOptionCtrls
          ..clear()
          ..addAll(draft.options.map((o) => TextEditingController(text: o)));
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text("Couldn't create poll: $e"),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _creatingPoll = false);
      }
    }
  }

  void _removePoll() {
    setState(() {
      _pollId = null;
      _pollQuestion = "";
      for (final c in _pollOptionCtrls) {
        c.dispose();
      }
      _pollOptionCtrls
        ..clear()
        ..addAll([
          TextEditingController(),
          TextEditingController(),
        ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(30),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
              border: Border.all(color: Colors.white.withOpacity(.70)),
            ),
            child: SafeArea(
              top: false,
              child: StatefulBuilder(
                builder: (context, setLocalState) {
                  final count = _controller.text.length;
                  final overLimit = count > _maxChars;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Sheet handle
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Header: title + Post button in the top right.
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Create Moment",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _canPost ? _onTapPost : null,
                            child: Text(
                              "Post",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w600,
                                color: _canPost
                                    ? AppColors.brandGreen
                                    : Colors.black.withOpacity(.25),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // TextField
                      TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        maxLines: 7,
                        minLines: 4,
                        maxLength: _maxChars + 20,
                        onChanged: (_) => setLocalState(() {}),
                        decoration: InputDecoration(
                          hintText: "What's happening around you?",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                            color: Colors.black.withOpacity(.38),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF3F4F6),
                          counterText: "",
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(16),
                        ),
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // v85: icon-only AttachmentBar matching the comment
                      // composer. @ | emoji | image | sticker.
                      AttachmentBar(
                        onTapMention: () {
                          setState(() {
                            _mentionPickerVisible = !_mentionPickerVisible;
                            if (_mentionPickerVisible) _emojiOpen = false;
                          });
                          if (_mentionPickerVisible) {
                            _insertAtCursor("@");
                            _focusNode.requestFocus();
                          }
                        },
                        onTapEmoji: () {
                          setState(() {
                            _emojiOpen = !_emojiOpen;
                            if (_emojiOpen) _mentionPickerVisible = false;
                          });
                          if (_emojiOpen) {
                            _focusNode.unfocus();
                          } else {
                            _focusNode.requestFocus();
                          }
                        },
                        onTapImage: _mediaFull ? () {} : _onTapImageButton,
                        onTapSticker: _mediaFull ? () {} : _onPickSticker,
                        mentionOpen: _mentionPickerVisible,
                        emojiOpen: _emojiOpen,
                        uploading: _uploadingImage,
                      ),

                      // v96b: poll composer removed. _pollId, _pollQuestion,
                      // _pollOptionCtrls, _openPollComposer, _FeedPollChip
                      // are still in the file as inert state so the
                      // build compiles, but no UI surfaces them.
                      const SizedBox(height: 0),

                      const SizedBox(height: 6),

                      // Hashtags hint + char count row
                      Row(
                        children: [
                          Icon(
                            PhosphorIcons.hash(PhosphorIconsStyle.bold),
                            size: 16,
                            color: Colors.black.withOpacity(.42),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              "Hashtags are detected automatically.",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.45),
                              ),
                            ),
                          ),
                          Text(
                            "$count/$_maxChars",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: overLimit
                                  ? const Color(0xFFB42318)
                                  : Colors.black.withOpacity(.42),
                            ),
                          ),
                        ],
                      ),

                      // v85: media preview strip (existing + sticker).
                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 96,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _media.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final item = _media[index];
                              return _MomentComposerMediaPreview(
                                item: item,
                                onRemove: () => _removeMedia(item),
                              );
                            },
                          ),
                        ),
                      ],

                      // v85: mention picker panel (same widget as comments)
                      if (_mentionPickerVisible)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: MentionPicker(
                            myUid:
                                FirebaseAuth.instance.currentUser?.uid ?? "",
                            commentService: _commentService,
                            onPickMention: _onPickMention,
                          ),
                        ),

                      // v85: emoji picker panel (same widget as comments)
                      if (_emojiOpen)
                        SizedBox(
                          height: 280,
                          child: EmojiPicker(
                            textEditingController: _controller,
                            config: Config(
                              height: 280,
                              checkPlatformCompatibility: true,
                              emojiViewConfig: const EmojiViewConfig(
                                columns: 7,
                                emojiSizeMax: 30,
                                backgroundColor: Colors.white,
                                verticalSpacing: 0,
                                horizontalSpacing: 0,
                              ),
                              viewOrderConfig: const ViewOrderConfig(
                                top: EmojiPickerItem.categoryBar,
                                middle: EmojiPickerItem.emojiView,
                                bottom: EmojiPickerItem.searchBar,
                              ),
                              categoryViewConfig: const CategoryViewConfig(
                                backgroundColor: Colors.white,
                                indicatorColor: Colors.black,
                                iconColor: Color(0xFF9CA3AF),
                                iconColorSelected: Colors.black,
                                dividerColor: Colors.transparent,
                              ),
                              bottomActionBarConfig: const BottomActionBarConfig(
                                backgroundColor: Colors.white,
                                buttonIconColor: Colors.black,
                              ),
                              searchViewConfig: const SearchViewConfig(
                                backgroundColor: Color(0xFFF3F4F6),
                                buttonIconColor: Colors.black,
                                hintText: "Search emoji",
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MomentComposerMediaButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _MomentComposerMediaButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(enabled ? .055 : .025),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                icon,
                size: 17,
                color: Colors.black.withOpacity(enabled ? .65 : .25),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.black.withOpacity(enabled ? .65 : .25),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentComposerMediaPreview extends StatelessWidget {
  final _MomentPickedMedia item;
  final VoidCallback onRemove;

  const _MomentComposerMediaPreview({
    required this.item,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    Widget image;

    if (item.file != null && item.type == "image") {
      image = Image.file(
        item.file!,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
      );
    } else if (item.file != null && item.type == "video") {
      if (item.previewBytes != null) {
        image = Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              item.previewBytes!,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
            ),
            const Center(
              child: Icon(
                Icons.play_circle_fill_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ],
        );
      } else {
        image = Container(
          width: 96,
          height: 96,
          color: Colors.black87,
          child: const Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        );
      }
    } else if (item.asset != null) {
      image = FutureBuilder<Uint8List?>(
        future: item.asset!.thumbnailDataWithSize(
          const ThumbnailSize(400, 400),
        ),
        builder: (context, snapshot) {
          final bytes = snapshot.data;

          if (bytes == null) {
            return Container(
              width: 96,
              height: 96,
              color: Colors.black.withOpacity(.06),
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          return Image.memory(
            bytes,
            width: 96,
            height: 96,
            fit: BoxFit.cover,
          );
        },
      );
    } else {
      image = Container(
        width: 96,
        height: 96,
        color: Colors.black.withOpacity(.06),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: [
          image,
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.72),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MomentCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;
  final VoidCallback onRepost;
  final VoidCallback onMore;
  final VoidCallback onShare;
  final bool authorVerified;
  final Map<String, bool> verifiedCache;
  /// Live photoUrl cache. Keyed by author uid. Used to render the
  /// user's CURRENT profile picture instead of the stale snapshot
  /// stored on the moment at creation time. Updated by per-author
  /// Firestore snapshot subscriptions on the feed tab.
  final Map<String, String> photoCache;
  final PingmeeFeedService feedService;
  /// v88: passed in from _FeedTabState so _MomentBody's
  /// resolveMentions callback can look up the UserRef for each
  /// mention UID. The card is a StatelessWidget, so it can't
  /// instantiate CommentService on its own; the parent passes it
  /// down. (Same pattern MomentCommentTile uses in the comments
  /// flow — see v66.)
  final CommentService commentService;
  /// v90: client-side @-mention fallback. The current viewer's
  /// connections cached by `mentionTag` (lowercased display name).
  /// Used by `_MomentBody` when the backend's `mentions[]` field
  /// is empty (pre-v87a deploy) so the @-tag in the moment text
  /// can still resolve to a tap target. Pass-through from
  /// `_FeedTabState` to keep the rendering path pure.
  final Map<String, UserRef>? myConnectionsByTag;
  /// Called when the user taps the avatar or display name. Receives
  /// the author's UID so the caller can navigate to that user's
  /// profile.
  final void Function(String authorUid)? onAuthorTap;

  const _MomentCard({
    required this.data,
    required this.onLike,
    required this.onComment,
    required this.onSave,
    required this.onRepost,
    required this.onMore,
    required this.onShare,
    required this.authorVerified,
    required this.verifiedCache,
    required this.photoCache,
    required this.feedService,
    required this.commentService,
    this.myConnectionsByTag,
    this.onAuthorTap,
  });

  String _text(String key) => (data[key] ?? "").toString().trim();

  String _prettyMomentTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return "";

    // Parse the time string into a DateTime, being defensive about
    // the format we receive. GetStream usually returns an ISO 8601
    // string with a Z or +HH:MM offset, but we also accept Unix
    // timestamps (in seconds or milliseconds) as a fallback, and we
    // ALWAYS compare the result against the current UTC time so the
    // "X hours ago" label does not get stuck at the user's timezone
    // offset (the previous version converted to local first, which
    // produced a constant 2h delta on devices whose local timezone
    // differed from the cloud function's UTC).
    DateTime? parsed;
    final asInt = int.tryParse(value);
    if (asInt != null && asInt > 0) {
      // Unix timestamp. Decide seconds vs milliseconds by magnitude.
      if (asInt >= 1000000000000) {
        parsed = DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
      } else {
        parsed = DateTime.fromMillisecondsSinceEpoch(asInt * 1000,
            isUtc: true);
      }
    } else {
      parsed = DateTime.tryParse(value);
    }
    if (parsed == null) return value;

    // Force the parsed DateTime into UTC for the diff. If the incoming
    // string had a Z or +HH:MM offset, DateTime.parse already gave us
    // an isUtc=true DateTime in absolute UTC. If the string was a bare
    // datetime with no offset (e.g. "2026-06-12T11:00:00"), Dart
    // treats it as local — that ambiguity is the root of the "always
    // 2h" bug. The cloud function is the source of truth, and the
    // function emits UTC, so we coerce local-parsed strings to UTC.
    final instant = parsed.isUtc
        ? parsed
        : DateTime.utc(
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
          );
    final now = DateTime.now().toUtc();
    final diff = now.difference(instant);

    if (diff.inSeconds < 60) return "now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m";
    if (diff.inHours < 24) return "${diff.inHours}h";
    if (diff.inDays < 7) return "${diff.inDays}d";

    // For older posts, show the local date so it reads naturally.
    final local = instant.toLocal();
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];

    return "${months[local.month - 1]} ${local.day}";
  }

  /// Compact a non-negative integer to a short "k" / "m" form for the
  /// action-bar labels. Below 1k the number is shown as-is. At or above
  /// 1k and below 1m we use one decimal place when the truncated value
  /// has not yet reached the next integer ("9.9k" not "10k"); at 10k and
  /// above the decimal is dropped. Same shape for the m range.
  ///
  /// Examples:
  ///   999       -> "999"
  ///   1000      -> "1k"
  ///   1500      -> "1.5k"
  ///   9999      -> "9.9k"
  ///   10000     -> "10k"
  ///   12345     -> "12k"
  ///   999999    -> "999k"
  ///   1000000   -> "1m"
  ///   1500000   -> "1.5m"
  ///   12345678  -> "12m"
  String _compactCount(int value) {
    if (value < 1000) return value.toString();
    if (value < 1000000) {
      final k = value / 1000.0;
      // One decimal when the integer part is 0-9, no decimal when 10+.
      return k < 10
          ? "${k.toStringAsFixed(1)}k"
          : "${k.round()}k";
    }
    final m = value / 1000000.0;
    return m < 10
        ? "${m.toStringAsFixed(1)}m"
        : "${m.round()}m";
  }

  @override
  Widget build(BuildContext context) {
    final authorName = _text("authorName").isNotEmpty
        ? _text("authorName")
        : "Pingmee user";

     final commentCount = data["commentCount"] is num
        ? (data["commentCount"] as num).toInt()
        : 0;   

    final authorUid = _text("authorUid");
    // Use the LIVE photoUrl from the cache (kept fresh by per-author
    // Firestore subscriptions) and fall back to the moment's snapshot
    // if the user doc hasn't been fetched yet.
    final authorPhotoUrl = photoCache[authorUid] ?? _text("authorPhotoUrl");
    // Body text: the user own text if any, else (for plain reposts
    // where the user did not type a quote) the original moment text.
    // The body block further down styles plain-repost text in mini-card
    // style (smaller, lighter) so it is clearly the source content and
    // not text the user wrote themselves. Quote reposts get the italic
    // quote style for the same reason.
    final ownText = _text("text");
    final time = _prettyMomentTime(_text("time"));
    final activityId = _text("id").isNotEmpty
        ? _text("id")
        : _text("foreignId").isNotEmpty
            ? _text("foreignId")
            : DateTime.now().microsecondsSinceEpoch.toString();
    final locationLabel = _text("locationLabel");
    final city = _text("city");
    final country = _text("country");

    final media = data["media"] is List
        ? List<Map<String, dynamic>>.from(
            (data["media"] as List).whereType<Map>().map(
                  (item) => Map<String, dynamic>.from(item),
                ),
          )
        : <Map<String, dynamic>>[];

    // v85: stickers are rendered separately from visualMedia. The
    // existing visualMedia filter treats kind == "sticker" as a still
    // image (it'd render the animated URL fine, but tile dimensions
    // for visualMedia assume photo aspect ratios). Pulling them out
    // here keeps the SharedMediaItem carousel a tidy row of photos
    // while stickers animate at their natural shape.
    final stickerMedia = media.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return kind == "sticker" && url.isNotEmpty;
    }).toList();

    final visualMedia = media.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();

      // Skip stickers — they're rendered above the visual carousel.
      if (kind == "sticker") return false;

      return url.isNotEmpty && (type == "image" || type == "video");
    }).toList();

    final locationLine = locationLabel.isNotEmpty
        ? locationLabel
        : city.isNotEmpty && country.isNotEmpty
            ? "$city, $country"
            : city.isNotEmpty
                ? city
                : country;
    final hashtags = data["hashtags"] is List
        ? List<String>.from((data["hashtags"] as List).map((e) => e.toString()))
        : <String>[];
    final likedByMe = data["likedByMe"] == true;
    final likeCount = data["likeCount"] is num
        ? (data["likeCount"] as num).toInt()
        : 0;    
    final savedByMe = data["savedByMe"] == true;
    final savedCount = data["savedCount"] is num
        ? (data["savedCount"] as num).toInt()
        : 0;
    final repostCount = data["repostCount"] is num
        ? (data["repostCount"] as num).toInt()
        : 0;
    final shareCount = data["shareCount"] is num
        ? (data["shareCount"] as num).toInt()
        : 0;

    final type = _text("type");
    final isRepost = type == "repost" || type == "quote";

    final originalAuthorName = _text("originalAuthorName");
    final originalText = _text("originalText");
    // Live cache needs the original author's uid, so a profile-pic change on
    // whoever was reposted shows up in the mini-card too (not just on the
    // outer author). Declared in the build method so we can resolve it from
    // photoCache inside the children list below.
    final originalAuthorUid = _text("originalAuthorUid");
    // Body text: ONLY the user own text. For a plain repost (no quote
    // typed) this is empty and the body block is skipped; the source
    // moment is shown only in the mini-card below. For a quote repost
    // this is the quote text the user wrote (rendered as a quote — see
    // the body block further down). We never fall back to the source's
    // text here, because that would make the body show the source's
    // content as if the user wrote it.
    final text = _text("text");
    final originalMedia = data["originalMedia"] is List
        ? List.from(data["originalMedia"])
        : data["media"] is List
            ? List.from(data["media"])
            : [];

    final repostLabel = type == "quote"
        ? "quoted a Moment"
        : type == "repost"
            ? "reposted a Moment"
            : "Moment"; 

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.black.withOpacity(.055)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.045),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _AuthorTapTarget(
                authorUid: _text("authorUid"),
                onAuthorTap: onAuthorTap,
                child: _MomentAvatar(photoUrl: authorPhotoUrl),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onAuthorTap == null || _text("authorUid").isEmpty
                      ? null
                      : () => onAuthorTap!(_text("authorUid")),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          if (authorVerified) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.verified_rounded,
                              size: 14,
                              color: Color(0xFF1D9BF0),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          repostLabel,
                          if (locationLine.isNotEmpty) locationLine,
                          if (time.isNotEmpty) time,
                        ].join(" · "),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                onTap: onMore,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                    size: 22,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
              ),
            ],
          ),
           if (text.isNotEmpty) ...[
            const SizedBox(height: 14),
            // Quote repost: the user is commenting on the source, so the
    // body is rendered as a quote (italic + lighter + curly quotes) to set
    // it apart from a regular post. Plain reposts are skipped entirely
    // (text is empty for them) and show only the mini-card. Regular
    // moments keep the normal post styling.
    // v87: @-mentions on the body text are rendered as blue
    // clickable TextSpans via _MomentBody. Quote reposts get the
    // same treatment (mentions on the quote text are tappable).
            if (isRepost)
              _MomentBody(
                text: '"$text"',
                mentions: data["mentions"] is List
                    ? List<String>.from(
                        (data["mentions"] as List)
                            .whereType<String>()
                            .where((s) => s.isNotEmpty),
                      )
                    : const <String>[],
                baseStyle: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14.5,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  height: 1.32,
                  color: Colors.black.withOpacity(.62),
                ),
                mentionStyle: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14.5,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                  height: 1.32,
                  color: const Color(0xFF1D9BF0),
                ),
                onMentionTap: onAuthorTap == null
                    ? (_) {}
                    : (uid) => onAuthorTap!(uid),
                // v88: _MomentBody resolves mentions via its own
                // widget.commentService (passed in below). Removes
                // the inline resolveMentions callback that was
                // referencing widget.commentService from inside
                // _MomentBody.build() — the wrong `widget` scope.
                commentService: commentService,
                // v90: client-side @-tag fallback so unresolved
                // mentions (backend mentions[] is empty) still
                // resolve when the @-tag matches a friend of the
                // current viewer.
                myConnectionsByTag: myConnectionsByTag,
              )
            else
              _MomentBody(
                text: text,
                mentions: data["mentions"] is List
                    ? List<String>.from(
                        (data["mentions"] as List)
                            .whereType<String>()
                            .where((s) => s.isNotEmpty),
                      )
                    : const <String>[],
                baseStyle: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.32,
                  color: Colors.black.withOpacity(.82),
                ),
                mentionStyle: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.32,
                  color: const Color(0xFF1D9BF0),
                ),
                onMentionTap: onAuthorTap == null
                    ? (_) {}
                    : (uid) => onAuthorTap!(uid),
                // v88: _MomentBody resolves mentions via its own
                // widget.commentService (passed in below). Removes
                // the inline resolveMentions callback that was
                // referencing widget.commentService from inside
                // _MomentBody.build() — the wrong `widget` scope.
                commentService: commentService,
                // v90: client-side @-tag fallback so unresolved
                // mentions (backend mentions[] is empty) still
                // resolve when the @-tag matches a friend of the
                // current viewer.
                myConnectionsByTag: myConnectionsByTag,
              ),
            const SizedBox(height: 8),
          ],
          // v80: Open Graph link preview. The v78 backend
          // createMomentV2 hook scrapes the first http(s) URL
          // in the text and stores the result as data.linkPreview.
          if (data["linkPreview"] is Map) ...[
            const SizedBox(height: 4),
            _LinkPreviewCard(
              preview:
                  Map<String, dynamic>.from(data["linkPreview"] as Map),
            ),
          ],
          // v92e: inline poll widget on the feed card. Rendered
          // when data["poll"] is a Map (the poll object from
          // Stream Feeds, v92b allowlist). Tapping an option calls
          // _feedService.castFeedPollVote (v92a cloud function)
          // and updates the local state with the fresh vote list.
          if (data["poll"] is Map) ...[
            const SizedBox(height: 8),
            _FeedPollWidget(
              activityId: activityId,
              poll: Map<String, dynamic>.from(data["poll"] as Map),
              feedService: feedService,
            ),
          ],
          
          if (hashtags.isNotEmpty) ...[
            const SizedBox(height: 3),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: hashtags.map((tag) {
                final label = tag.startsWith("#") ? tag : "#$tag";

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.045),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.62),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          // v85: sticker inline render — animated GIF at natural shape
          if (stickerMedia.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in stickerMedia)
                  _StickerInline(
                    url: (item["url"] ?? "").toString(),
                  ),
              ],
            ),
          ],

          if (visualMedia.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Media row. For a single tile we keep the natural-aspect
            // behaviour (the image's real shape, with a 45% cap on tall
            // portraits so they do not take over the feed). For a multi-
            // image carousel every tile shares one uniform height (about
            // 55% of the screen) and is cropped edge-to-edge so the row
            // looks like a tidy grid, not a stair-step of different shapes.
            // Tapping any tile opens the full-screen media viewer.
            LayoutBuilder(
              builder: (context, constraints) {
                final fullWidth = constraints.maxWidth;
                final screenHeight = MediaQuery.of(context).size.height;
                final itemWidth = visualMedia.length == 1
                    ? fullWidth
                    : fullWidth * 0.88;
                // Uniform row height for multi-image carousels; null for
                // single tiles so they keep their per-image aspect logic.
                final double? forcedHeight = visualMedia.length > 1
                    ? (screenHeight * 0.55).clamp(200.0, screenHeight)
                    : null;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int index = 0; index < visualMedia.length; index++) ...[
                          if (index > 0) const SizedBox(width: 10),
                          SharedMediaItem(
                            item: visualMedia[index],
                            index: index,
                            itemWidth: itemWidth,
                            maxHeight: screenHeight,
                            totalCount: visualMedia.length,
                            activityId: activityId,
                            forcedHeight: forcedHeight,
                            cornerRadius: 20,
                            onMediaTap: null,
                            onDefaultTap: () => _openMomentMediaViewer(
                              context: context,
                              images: visualMedia,
                              initialIndex: index,
                              activityId: activityId,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ],

          if (isRepost && (originalText.isNotEmpty || originalMedia.isNotEmpty)) ...[
            // Repost indicator above original content (shown on every repost,
            // not just plain reposts, so quote reposts also signal the source)
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  PhosphorIcons.repeat(PhosphorIconsStyle.bold),
                  size: 15,
                  color: Colors.black.withOpacity(.45),
                ),
                const SizedBox(width: 6),
                Text(
                  "Reposted",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.5,
                    fontWeight: FontWeight.w300,
                    color: Colors.black.withOpacity(.48),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _OriginalMomentMiniCard(
              authorName: originalAuthorName.isNotEmpty
                  ? originalAuthorName
                  : "Pingmee user",
              text: originalText,
              // Live cache first (falls back to snapshot) so a profile-pic
              // change shows up here too, not just on the outer author.
              authorPhotoUrl: photoCache[originalAuthorUid] ?? _text("originalAuthorPhotoUrl"),
              authorVerified: verifiedCache[originalAuthorUid] ?? false,
              originalMedia: originalMedia,
              onOriginalTap: () {
                // Build the original moment's data as if it were a standalone post
                final originalMoment = Map<String, dynamic>.from(data);
                originalMoment["authorName"] = originalAuthorName.isNotEmpty
                    ? originalAuthorName
                    : "Pingmee user";
                originalMoment["authorPhotoUrl"] = _text("originalAuthorPhotoUrl");
                originalMoment["authorUid"] = _text("originalAuthorUid");
                originalMoment["text"] = originalText;
                originalMoment["media"] = originalMedia;
                originalMoment["type"] = "moment";
                // Remove repost wrapper fields so it shows as a regular post
                originalMoment.remove("originalAuthorName");
                originalMoment.remove("originalAuthorPhotoUrl");
                originalMoment.remove("originalAuthorUid");
                originalMoment.remove("originalText");
                originalMoment.remove("originalMedia");
                originalMoment.remove("originalActivityId");
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MomentDetailScreen(
                      moment: originalMoment,
                      feedService: feedService,
                      authorVerified:
                          verifiedCache[_text("originalAuthorUid")] ?? false,
                      originalActivityId: _text("originalActivityId"),
                    ),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _MomentAction(
                icon: likedByMe
                    ? PhosphorIcons.heart(PhosphorIconsStyle.fill)
                    : PhosphorIcons.heart(PhosphorIconsStyle.regular),
                label: likeCount > 0 ? _compactCount(likeCount) : "",
                active: likedByMe,
                activeColor: const Color(0xFFEF4444), // red
                onTap: onLike,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
                label: commentCount > 0 ? _compactCount(commentCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onComment,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.repeat(PhosphorIconsStyle.bold),
                label: repostCount > 0 ? _compactCount(repostCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onRepost,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
                label: shareCount > 0 ? _compactCount(shareCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onShare,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: savedByMe
                    ? PhosphorIcons.bookmark(PhosphorIconsStyle.fill)
                    : PhosphorIcons.bookmark(PhosphorIconsStyle.regular),
                label: savedCount > 0 ? _compactCount(savedCount) : "",
                active: savedByMe,
                activeColor: AppColors.brandGreen,
                onTap: onSave,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MomentVideoViewerItem extends StatefulWidget {
  final String url;

  const _MomentVideoViewerItem({
    required this.url,
  });

  @override
  State<_MomentVideoViewerItem> createState() => _MomentVideoViewerItemState();
}

class _MomentVideoViewerItemState extends State<_MomentVideoViewerItem> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();

    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 2,
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _controller.value.isPlaying
              ? _controller.pause()
              : _controller.play();
        });
      },
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller),

              AnimatedOpacity(
                opacity:
                    _controller.value.isPlaying ? 0 : 1,
                duration: const Duration(
                  milliseconds: 180,
                ),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.pause_rounded,
                    size: 44,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _openMomentMediaViewer({
  required BuildContext context,
  required List<Map<String, dynamic>> images,
  required int initialIndex,
  required String activityId,
}) {
  if (images.isEmpty) return;

  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: true,
      barrierColor: Colors.black,
      pageBuilder: (_, __, ___) {
        return _MomentMediaViewerPage(
          images: images,
          initialIndex: initialIndex,
          activityId: activityId,
        );
      },
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
    ),
  );
}

class _MomentMediaViewerPage extends StatefulWidget {
  final List<Map<String, dynamic>> images;
  final int initialIndex;
  final String activityId;

  const _MomentMediaViewerPage({
    required this.images,
    required this.initialIndex,
    required this.activityId,
  });

  @override
  State<_MomentMediaViewerPage> createState() => _MomentMediaViewerPageState();
}

class _MomentMediaViewerPageState extends State<_MomentMediaViewerPage> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();

    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  String _urlAt(int index) {
    return (widget.images[index]["url"] ?? "").toString().trim();
  }

  String _heroTagFor(int index) {
    final url = _urlAt(index);
    return "moment_media_${widget.activityId}_${index}_${url.hashCode}";
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: (value) {
              setState(() => _index = value);
            },
            itemBuilder: (context, index) {
              final type = (widget.images[index]["type"] ?? "").toString();
              final url = (widget.images[index]["url"] ?? "").toString().trim();

              if (type == "video") {
                return _MomentVideoViewerItem(url: url);
              }

              return PhotoView(
                imageProvider: NetworkImage(url),
                heroAttributes: PhotoViewHeroAttributes(
                  tag: _heroTagFor(index),
                ),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3.0,
                backgroundDecoration: const BoxDecoration(
                  color: Colors.black,
                ),
                loadingBuilder: (context, event) {
                  return const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  );
                },
              );
            },
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.48),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.48),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        "${_index + 1}/${widget.images.length}",
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (widget.images.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(widget.images.length, (dotIndex) {
                    final selected = dotIndex == _index;

                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: selected ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white
                            : Colors.white.withOpacity(.38),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OriginalMomentMiniCard extends StatelessWidget {
  final String authorName;
  final String text;
  final String authorPhotoUrl;
  final bool authorVerified;
  final List originalMedia;
  final VoidCallback? onOriginalTap;

  const _OriginalMomentMiniCard({
    required this.authorName,
    required this.text,
    this.authorPhotoUrl = "",
    this.authorVerified = false,
    this.originalMedia = const [],
    this.onOriginalTap,
  });

  @override
  Widget build(BuildContext context) {
    // v85: stickers get their own inline render path. The carousel
    // filter excludes them (they animate at natural shape, not as
    // a still photo tile).
    final stickerItems = (originalMedia as List).whereType<Map>().where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return kind == "sticker" && url.isNotEmpty;
    }).toList();

    // Build media list for carousel (image/video only)
    final mediaItems = (originalMedia as List).whereType<Map>().where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      if (kind == "sticker") return false;
      return url.isNotEmpty && (type == "image" || type == "video");
    }).toList();

    final hasMedia = mediaItems.isNotEmpty;
    final hasSticker = stickerItems.isNotEmpty;

    return GestureDetector(
      onTap: onOriginalTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author row: avatar + name + verified badge (tight, badge next to name)
          Row(
            children: [
              if (authorPhotoUrl.isNotEmpty) ...[
                CircleAvatar(
                  radius: 13,
                  backgroundColor: Colors.grey.shade200,
                  backgroundImage: NetworkImage(authorPhotoUrl),
                ),
                const SizedBox(width: 7),
              ],
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      authorName.isNotEmpty ? authorName : "Pingmee user",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (authorVerified) ...[
                    const SizedBox(width: 2),
                    const Icon(
                      Icons.verified,
                      size: 14,
                      color: Color(0xFF1B9BEF),
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              text,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.32,
                color: Colors.black.withOpacity(.66),
              ),
            ),
            const SizedBox(height: 8),
          ],
          // v85: sticker inline render (animated, no carousel, no viewer)
          if (hasSticker) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final item in stickerItems)
                  _StickerInline(
                    url: (item["url"] ?? "").toString(),
                  ),
              ],
            ),
          ],

          // Horizontal media carousel
          if (hasMedia) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: mediaItems.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (ctx, i) {
                  final item = Map<String, dynamic>.from(mediaItems[i]);
                  final type = (item["type"] ?? "").toString().trim();
                  final url = (item["url"] ?? "").toString().trim();
                  final thumbUrl = (item["thumbUrl"] ?? "").toString().trim();

                  if (type == "video") {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          Image.network(
                            thumbUrl.isNotEmpty ? thumbUrl : url,
                            height: 90,
                            width: 120,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 90,
                              width: 120,
                              color: Colors.grey.shade300,
                              child: const Icon(Icons.videocam, size: 24),
                            ),
                          ),
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      url,
                      height: 90,
                      width: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 90,
                        width: 120,
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.image, size: 24),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

class _RepostAction {
  final String quoteText;
  // v85: quote-repost can carry media (image/video/sticker) +
  // @mentions. The plain-repost path passes empty lists here.
  final List<_MomentPickedMedia> media;
  final List<String> mentions;

  const _RepostAction({
    required this.quoteText,
    this.media = const <_MomentPickedMedia>[],
    this.mentions = const <String>[],
  });
}

class _RepostMomentSheet extends StatefulWidget {
  final Map<String, dynamic> moment;

  const _RepostMomentSheet({
    required this.moment,
  });

  @override
  State<_RepostMomentSheet> createState() => _RepostMomentSheetState();
}

class _RepostMomentSheetState extends State<_RepostMomentSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  static const int _maxChars = 1000; // v91: was 300

  // v85: staged media for the repost — same model as create moment.
  // Stickers land here with kind: "sticker" + remoteUrl: <uploaded URL>.
  final List<_MomentPickedMedia> _media = [];
  final List<String> _mentionUids = <String>[];
  final Map<String, UserRef> _mentionedUsersCache = <String, UserRef>{};
  final CommentService _commentService = CommentService();

  bool _emojiOpen = false;
  bool _mentionPickerVisible = false;
  bool _uploadingImage = false;

  String _text(String key) =>
      (widget.moment[key] ?? "").toString().trim();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (!_focusNode.hasFocus) {
      if (_emojiOpen) setState(() => _emojiOpen = false);
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
    }
  }

  void _onTextChanged() {
    if (!mounted) return;
    final text = _controller.text;
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final cursor = selection.baseOffset;
    if (cursor <= 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final before = text.substring(0, cursor);
    final atIndex = before.lastIndexOf("@");
    if (atIndex < 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final between = before.substring(atIndex + 1);
    if (between.contains(" ") || between.contains("\n")) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (between.length > 32) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (!_mentionPickerVisible) {
      setState(() => _mentionPickerVisible = true);
    }
  }

  void _insertAtCursor(String s) {
    final ctrl = _controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      final newText = ctrl.text + s;
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      return;
    }
    final newText = ctrl.text.replaceRange(sel.start, sel.end, s);
    final newCursor = sel.start + s.length;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  void _onPickMention(UserRef u) {
    final tag = "@${u.mentionTag} ";
    final ctrl = _controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      _insertAtCursor(tag);
    } else {
      final text = ctrl.text;
      final atIndex = text.lastIndexOf("@", sel.start - 1);
      if (atIndex >= 0) {
        final newText = text.replaceRange(atIndex, sel.start, tag);
        ctrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: atIndex + tag.length),
        );
      } else {
        _insertAtCursor(tag);
      }
    }
    if (!_mentionUids.contains(u.uid)) {
      _mentionUids.add(u.uid);
      _mentionedUsersCache[u.uid] = u;
    }
    setState(() => _mentionPickerVisible = false);
    _focusNode.requestFocus();
  }

  bool get _mediaFull => _media.length >= 4;

  Future<void> _onTapImageButton() async {
    if (_mediaFull) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text(
                  "Take photo",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("camera"),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text(
                  "Choose from library",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("library"),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (picked == "camera") {
      await _pickMediaFromCamera();
    } else if (picked == "library") {
      await _pickMediaFromGallery();
    }
  }

  Future<void> _pickMediaFromGallery() async {
    if (_mediaFull) return;
    try {
      final maxPick = 4 - _media.length;
      final PermissionState permission =
          await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) return;
      final assets = await AssetPicker.pickAssets(
        context,
        pickerConfig: AssetPickerConfig(
          maxAssets: maxPick,
          requestType: RequestType.common,
          selectedAssets: _media
              .where((m) => m.asset != null)
              .map((m) => m.asset!)
              .toList(),
        ),
      );
      if (assets == null || assets.isEmpty) return;
      final existingIds = _media.map((m) => m.id).toSet();
      for (final asset in assets) {
        if (_media.length >= 4) break;
        final id = "asset_${asset.id}";
        if (existingIds.contains(id)) continue;
        _media.add(
          _MomentPickedMedia(
            id: id,
            type: asset.type == AssetType.video ? "video" : "image",
            asset: asset,
            name: asset.title,
          ),
        );
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      debugPrint("❌ Repost gallery pick error: $e");
    }
  }

  Future<void> _pickMediaFromCamera() async {
    if (_mediaFull) return;
    try {
      XFile? captured;
      CameraPickerViewType? capturedType;
      await CameraPicker.pickFromCamera(
        context,
        pickerConfig: CameraPickerConfig(
          enableRecording: true,
          textDelegate: const EnglishCameraPickerTextDelegate(),
          onXFileCaptured: (
            XFile file,
            CameraPickerViewType viewType,
          ) {
            captured = file;
            capturedType = viewType;
            Navigator.of(context).pop();
            return true;
          },
        ),
      );
      if (captured == null) return;
      final file = File(captured!.path);
      if (!await file.exists()) return;
      final id = "cam_${DateTime.now().millisecondsSinceEpoch}";
      final ext = p.extension(file.path).toLowerCase();
      final isVideo =
          capturedType == CameraPickerViewType.video ||
          [".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi"].contains(ext);
      Uint8List? previewBytes;
      if (isVideo) {
        previewBytes = await video_thumb.VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: video_thumb.ImageFormat.JPEG,
          quality: 75,
        );
      }
      setState(() {
        _media.add(
          _MomentPickedMedia(
            id: id,
            type: isVideo ? "video" : "image",
            file: file,
            name: p.basename(file.path),
            previewBytes: previewBytes,
          ),
        );
      });
    } catch (e) {
      debugPrint("❌ Repost camera pick error: $e");
    }
  }

  Future<void> _onPickSticker() async {
    if (kPingmeeGiphyApiKey.contains("PASTE_")) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Sticker library is not set up yet.")),
      );
      return;
    }
    if (_mediaFull) return;
    try {
      final gif = await GiphyGet.getGif(
        context: context,
        apiKey: kPingmeeGiphyApiKey,
        lang: GiphyLanguage.english,
        tabColor: Colors.black,
        debounceTimeInMilliseconds: 350,
        showGIFs: false,
        showStickers: true,
        showEmojis: false,
      );
      if (gif == null) return;
      final url = bestGiphyUrl(gif);
      if (url.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't load sticker.")),
        );
        return;
      }
      if (!mounted) return;
      setState(() => _uploadingImage = true);
      try {
        final resp = await http.get(Uri.parse(url));
        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
          throw Exception("GIPHY fetch failed: ${resp.statusCode}");
        }
        final localId =
            "repost-sticker-${DateTime.now().millisecondsSinceEpoch}";
        final uploadedUrl = await _commentService.uploadCommentImage(
          activityId: "create-repost",
          commentIdLocal: localId,
          bytes: resp.bodyBytes,
          contentType: "image/gif",
        );
        if (!mounted) return;
        final id = (gif.id ?? "").toString().isNotEmpty
            ? gif.id!.toString()
            : localId;
        setState(() {
          _media.add(
            _MomentPickedMedia(
              id: "sticker_$id",
              type: "sticker",
              name: "sticker_$id.gif",
              kind: "sticker",
              remoteUrl: uploadedUrl,
            ),
          );
          _uploadingImage = false;
        });
      } catch (e) {
        debugPrint("❌ Repost sticker upload failed: $e");
        if (!mounted) return;
        setState(() => _uploadingImage = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't upload sticker.")),
        );
      }
    } catch (e) {
      debugPrint("❌ Repost GIPHY picker error: $e");
    }
  }

  void _removeMedia(_MomentPickedMedia item) {
    setState(() {
      _media.removeWhere((m) => m.id == item.id);
    });
  }

  bool get _canQuote {
    final text = _controller.text.trim();
    return text.isNotEmpty && text.length <= _maxChars;
  }

  bool get _canRepost => true; // Plain repost needs no text

  void _onTapRepost() {
    // Plain repost (no quote text, no media). Forwards the original
    // moment data unchanged.
    Navigator.pop(
      context,
      _RepostAction(quoteText: "", media: const [], mentions: const []),
    );
  }

  void _onTapQuote() {
    if (!_canQuote) return;
    Navigator.pop(
      context,
      _RepostAction(
        quoteText: _controller.text.trim(),
        media: List<_MomentPickedMedia>.from(_media),
        mentions: List<String>.from(_mentionUids),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final authorName = _text("authorName").isNotEmpty
        ? _text("authorName")
        : "Pingmee user";
    final text = _text("text");

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
            ),
            child: SafeArea(
              top: false,
              child: StatefulBuilder(
                builder: (context, setLocalState) {
                  final count = _controller.text.length;
                  final overLimit = count > _maxChars;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Sheet handle
                      Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Header: "Repost Moment" title + "repost" button
                      // (lowercase per Chris: 'the text for repost should
                      // say repost only')
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Repost Moment",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _canRepost ? _onTapRepost : null,
                            child: const Text(
                              "repost",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w600,
                                color: AppColors.brandGreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _OriginalMomentMiniCard(
                        authorName: authorName,
                        text: text,
                      ),
                      const SizedBox(height: 12),

                      // v85: icon-only AttachmentBar matching comments +
                      // create-moment composer. @ | emoji | image | sticker
                      AttachmentBar(
                        onTapMention: () {
                          setState(() {
                            _mentionPickerVisible = !_mentionPickerVisible;
                            if (_mentionPickerVisible) _emojiOpen = false;
                          });
                          if (_mentionPickerVisible) {
                            _insertAtCursor("@");
                            _focusNode.requestFocus();
                          }
                        },
                        onTapEmoji: () {
                          setState(() {
                            _emojiOpen = !_emojiOpen;
                            if (_emojiOpen) _mentionPickerVisible = false;
                          });
                          if (_emojiOpen) {
                            _focusNode.unfocus();
                          } else {
                            _focusNode.requestFocus();
                          }
                        },
                        onTapImage: _mediaFull ? () {} : _onTapImageButton,
                        onTapSticker: _mediaFull ? () {} : _onPickSticker,
                        mentionOpen: _mentionPickerVisible,
                        emojiOpen: _emojiOpen,
                        uploading: _uploadingImage,
                      ),
                      const SizedBox(height: 6),

                      // TextField
                      TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: 5,
                        minLines: 3,
                        maxLength: _maxChars + 20,
                        onChanged: (_) => setLocalState(() {}),
                        decoration: InputDecoration(
                          hintText: "Add your thoughts...",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                            color: Colors.black.withOpacity(.38),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF3F4F6),
                          counterText: "",
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.all(16),
                        ),
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Char count + media count
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              "Optional quote",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.45),
                              ),
                            ),
                          ),
                          Text(
                            "$count/$_maxChars",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: overLimit
                                  ? const Color(0xFFB42318)
                                  : Colors.black.withOpacity(.42),
                            ),
                          ),
                        ],
                      ),

                      // v85: media preview strip
                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 96,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _media.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              final item = _media[index];
                              return _MomentComposerMediaPreview(
                                item: item,
                                onRemove: () => _removeMedia(item),
                              );
                            },
                          ),
                        ),
                      ],

                      // v85: mention picker panel
                      if (_mentionPickerVisible)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: MentionPicker(
                            myUid:
                                FirebaseAuth.instance.currentUser?.uid ?? "",
                            commentService: _commentService,
                            onPickMention: _onPickMention,
                          ),
                        ),

                      // v85: emoji picker panel
                      if (_emojiOpen)
                        SizedBox(
                          height: 280,
                          child: EmojiPicker(
                            textEditingController: _controller,
                            config: Config(
                              height: 280,
                              checkPlatformCompatibility: true,
                              emojiViewConfig: const EmojiViewConfig(
                                columns: 7,
                                emojiSizeMax: 30,
                                backgroundColor: Colors.white,
                                verticalSpacing: 0,
                                horizontalSpacing: 0,
                              ),
                              viewOrderConfig: const ViewOrderConfig(
                                top: EmojiPickerItem.categoryBar,
                                middle: EmojiPickerItem.emojiView,
                                bottom: EmojiPickerItem.searchBar,
                              ),
                              categoryViewConfig: const CategoryViewConfig(
                                backgroundColor: Colors.white,
                                indicatorColor: Colors.black,
                                iconColor: Color(0xFF9CA3AF),
                                iconColorSelected: Colors.black,
                                dividerColor: Colors.transparent,
                              ),
                              bottomActionBarConfig: const BottomActionBarConfig(
                                backgroundColor: Colors.white,
                                buttonIconColor: Colors.black,
                              ),
                              searchViewConfig: const SearchViewConfig(
                                backgroundColor: Color(0xFFF3F4F6),
                                buttonIconColor: Colors.black,
                                hintText: "Search emoji",
                              ),
                            ),
                          ),
                        ),

                      // "Quote Moment" big button (per Chris: 'Quote
                      // moment as is' — the title stays as before)
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _canQuote ? _onTapQuote : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                Colors.black.withOpacity(.12),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          child: const Text(
                            "Quote Moment",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareMomentSheet extends StatelessWidget {
  final Map<String, dynamic> moment;

  const _ShareMomentSheet({
    required this.moment,
  });

  String _text(String key) => (moment[key] ?? "").toString().trim();

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final text = _text("text");

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
            ),
            child: SafeArea(
              top: false,
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
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "Share with friends",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: PhosphorIcon(
                          PhosphorIcons.x(PhosphorIconsStyle.regular),
                          size: 20,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Paper plane share button
                  ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen.withOpacity(.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: PhosphorIcon(
                          PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill),
                          size: 22,
                          color: AppColors.brandGreen,
                        ),
                      ),
                    ),
                    title: const Text(
                      "Send via Ping Chat",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    subtitle: Text(
                      text.length > 50 ? "\${text.substring(0, 50)}..." : text,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        color: Colors.black.withOpacity(.5),
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      // TODO: Open chat picker to share moment
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the avatar in a tap target that fires [onAuthorTap] with
/// the moment author's UID. If [onAuthorTap] is null or [authorUid]
/// is empty, the wrapper is a pass-through.
class _AuthorTapTarget extends StatelessWidget {
  final String authorUid;
  final void Function(String authorUid)? onAuthorTap;
  final Widget child;
  const _AuthorTapTarget({
    required this.authorUid,
    required this.onAuthorTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (onAuthorTap == null || authorUid.isEmpty) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onAuthorTap!(authorUid),
      child: child,
    );
  }
}

class _MomentAvatar extends StatelessWidget {
  final String photoUrl;

  const _MomentAvatar({
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withOpacity(.06),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: !hasPhoto
          ? Icon(
              PhosphorIcons.user(PhosphorIconsStyle.bold),
              size: 18,
              color: Colors.black.withOpacity(.55),
            )
          : null,
    );
  }
}

class _MomentAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;

  const _MomentAction({
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor = AppColors.brandGreen,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? activeColor
        : Colors.black.withOpacity(.62);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 2,
            vertical: 8,
          ),
          child: Row(
            children: [
              PhosphorIcon(
                icon,
                size: 22,
                color: color,
              ),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentMoreSheet extends StatelessWidget {
  final bool isOwner;
  final String? authorUidDisplay;

  const _MomentMoreSheet({
    required this.isOwner,
    this.authorUidDisplay,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassBottomSheet(
      child: SafeArea(
        top: false,
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
              // v97r: copy the moment's shareable link to the
              // system clipboard so it can be pasted anywhere.
              _MomentMoreTile(
                icon: PhosphorIcons.link(PhosphorIconsStyle.regular),
                title: "Copy link",
                onTap: () => Navigator.pop(context, "copy"),
              ),
              const SizedBox(height: 8),
              // v97r: hide this author's future moments from the
              // feed. Persists to users/{myUid}/not_interested/{authorUid}.
              _MomentMoreTile(
                icon: PhosphorIcons.eye(PhosphorIconsStyle.regular),
                title: "Not interested",
                onTap: () => Navigator.pop(context, "not_interested"),
              ),
              // v97r: hide this author's posts (silenced). The
              // author doesn't see this and isn't notified.
              // Persists to users/{myUid}/muted/{authorUid}.
              _MomentMoreTile(
                icon: PhosphorIcons.bellSlash(
                    PhosphorIconsStyle.regular),
                title: "Mute @" + (authorUidDisplay ?? "user"),
                onTap: () => Navigator.pop(context, "mute"),
              ),
              // v97r: stop seeing this author entirely. Stronger
              // than mute. Persists to users/{myUid}/restricted/{authorUid}.
              _MomentMoreTile(
                icon: PhosphorIcons.prohibit(
                    PhosphorIconsStyle.regular),
                title: "Restrict @" + (authorUidDisplay ?? "user"),
                danger: true,
                onTap: () => Navigator.pop(context, "restrict"),
              ),
              // v97r: navigate to the author's profile screen.
              _MomentMoreTile(
                icon: PhosphorIcons.user(PhosphorIconsStyle.regular),
                title: "View profile",
                onTap: () => Navigator.pop(context, "view_profile"),
              ),
              const SizedBox(height: 8),
              // Owner-only destructive action.
              if (isOwner)
                _MomentMoreTile(
                  icon: PhosphorIcons.trash(PhosphorIconsStyle.regular),
                  title: "Delete Moment",
                  danger: true,
                  onTap: () => Navigator.pop(context, "delete"),
                )
              else
                // Viewer-only report action.
                _MomentMoreTile(
                  icon: PhosphorIcons.flag(PhosphorIconsStyle.regular),
                  title: "Report Moment",
                  danger: false,
                  onTap: () => Navigator.pop(context, "report"),
                ),
              const SizedBox(height: 8),
              // Always-present Cancel row.
              _MomentMoreTile(
                icon: PhosphorIcons.x(PhosphorIconsStyle.regular),
                title: "Cancel",
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentMoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool danger;
  final VoidCallback onTap;

  const _MomentMoreTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFB42318) : Colors.black87;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xFFB42318).withOpacity(.08)
                : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              PhosphorIcon(
                icon,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentsEmptyCard extends StatelessWidget {
  const _MomentsEmptyCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.80),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.black.withOpacity(.055)),
      ),
      child: Column(
        children: [
          Icon(
            PhosphorIcons.mapPinArea(PhosphorIconsStyle.light),
            size: 42,
            color: Colors.black.withOpacity(.48),
          ),
          const SizedBox(height: 12),
          const Text(
            "Your area is quiet right now.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Start the first Moment here, or later we’ll widen your feed when nearby activity is low.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              height: 1.35,
              color: Colors.black.withOpacity(.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _MomentsCenterState extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool loading;
  final String? buttonLabel;
  final VoidCallback? onPressed;

  const _MomentsCenterState({
    required this.title,
    required this.subtitle,
    this.loading = false,
    this.buttonLabel,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.brandGreen,
                  ),
                ),
              )
            else
              Icon(
                PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
                size: 34,
                color: AppColors.brandGreen,
              ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: Colors.black.withOpacity(.55),
              ),
            ),
            if (buttonLabel != null && onPressed != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  buttonLabel!,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
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


// ============================================================
// Feed skeleton (content-loading placeholder)
// ============================================================

/// A self-animating stack of placeholder moment cards used while the
/// feed is booting or refreshing. Mirrors the real `_MomentCard`
/// shape (avatar + name + text + media + action bar) so the user
/// sees a believable content layout, not a centred green spinner.
class _FeedMomentsSkeleton extends StatefulWidget {
  final int itemCount;
  const _FeedMomentsSkeleton({this.itemCount = 4});

  @override
  State<_FeedMomentsSkeleton> createState() => _FeedMomentsSkeletonState();
}

class _FeedMomentsSkeletonState extends State<_FeedMomentsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = 0.55 + (_controller.value * 0.30);
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
          children: [
            // A faded create-moment preview at the top, just like the
            // real feed has at index 0.
            const _FeedSkeletonCreateBar(pulse: 0.55),
            const SizedBox(height: 12),
            for (int i = 0; i < widget.itemCount; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _FeedSkeletonMomentCard(
                // Vary the line count and media presence so the skeleton
                // doesn't look like 4 identical cards.
                withMedia: i % 2 == 0,
                textLines: i == 0 ? 3 : (i == 2 ? 1 : 2),
                pulse: pulse,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FeedSkeletonCreateBar extends StatelessWidget {
  final double pulse;
  const _FeedSkeletonCreateBar({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.055)),
      ),
      child: Row(
        children: [
          _FeedSkeletonBar(width: 36, height: 36, radius: 18, pulse: pulse),
          const SizedBox(width: 12),
          Expanded(
            child: _FeedSkeletonBar(
              width: double.infinity,
              height: 14,
              radius: 6,
              pulse: pulse,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedSkeletonMomentCard extends StatelessWidget {
  final bool withMedia;
  final int textLines;
  final double pulse;
  const _FeedSkeletonMomentCard({
    required this.withMedia,
    required this.textLines,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.055)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author row: avatar + 2 stacked name/time bars
          Row(
            children: [
              _FeedSkeletonBar(width: 40, height: 40, radius: 20, pulse: pulse),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FeedSkeletonBar(width: 130, height: 13, radius: 4, pulse: pulse),
                    const SizedBox(height: 6),
                    _FeedSkeletonBar(width: 80, height: 11, radius: 4, pulse: pulse),
                  ],
                ),
              ),
              _FeedSkeletonBar(width: 18, height: 18, radius: 9, pulse: pulse),
            ],
          ),
          // Text lines
          if (textLines > 0) ...[
            const SizedBox(height: 14),
            for (int i = 0; i < textLines; i++) ...[
              if (i > 0) const SizedBox(height: 7),
              _FeedSkeletonBar(
                width: i == textLines - 1 ? 180 : double.infinity,
                height: 13,
                radius: 4,
                pulse: pulse,
              ),
            ],
          ],
          // Media placeholder
          if (withMedia) ...[
            const SizedBox(height: 12),
            _FeedSkeletonBar(
              width: double.infinity,
              height: 200,
              radius: 18,
              pulse: pulse,
            ),
          ],
          // Action bar
          const SizedBox(height: 14),
          Row(
            children: [
              _FeedSkeletonBar(width: 52, height: 22, radius: 11, pulse: pulse),
              const SizedBox(width: 16),
              _FeedSkeletonBar(width: 52, height: 22, radius: 11, pulse: pulse),
              const SizedBox(width: 16),
              _FeedSkeletonBar(width: 52, height: 22, radius: 11, pulse: pulse),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedSkeletonBar extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final double pulse;
  const _FeedSkeletonBar({
    required this.width,
    required this.height,
    required this.radius,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Color.lerp(
          const Color(0xFFE6E8EC),
          const Color(0xFFF2F3F5),
          pulse,
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

// ============================================================================
// v97d: internal helper used by _MomentBody._buildRichText to
// sort mention and URL matches into a single left-to-right list
// of inline spans. Two kinds: mention (resolved through the
// mentions cache + onMentionTap) and url (rendered tappable with
// launchUrl).
enum _InlineKind { mention, url }

class _InlineSpan {
  const _InlineSpan._({
    required this.start,
    required this.end,
    required this.kind,
    required this.raw,
  });

  factory _InlineSpan.mention({
    required int start,
    required int end,
    required String raw,
  }) =>
      _InlineSpan._(start: start, end: end, kind: _InlineKind.mention, raw: raw);

  factory _InlineSpan.url({
    required int start,
    required int end,
    required String raw,
  }) =>
      _InlineSpan._(start: start, end: end, kind: _InlineKind.url, raw: raw);

  final int start;
  final int end;
  final _InlineKind kind;
  final String raw;

  bool get isMention => kind == _InlineKind.mention;
  bool get isUrl => kind == _InlineKind.url;
}

// // v80: _LinkPreviewCard - Open Graph link preview. Same shape as
// the one in shared_moment_widgets.dart (v78), but local to
// feed_tab.dart because _MomentCard lives here. The card
// displays the image (16:9), site name, title, and description
// scraped by the v78 createMomentV2 hook. Tapping opens the
// URL in the system browser via url_launcher.
// ============================================================================
class _LinkPreviewCard extends StatelessWidget {
  final Map<String, dynamic> preview;

  const _LinkPreviewCard({required this.preview});

  String _str(String key) {
    final v = preview[key];
    if (v == null) return "";
    return v.toString().trim();
  }

  Future<void> _onTap(BuildContext context) async {
    final url = _str("url");
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Couldn't open link: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _str("url");
    final title = _str("title");
    final description = _str("description");
    final image = _str("image");
    final siteName = _str("siteName");
    final type = _str("type");
    if (url.isEmpty && title.isEmpty && description.isEmpty) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTap(context),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.black.withOpacity(.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (image.isNotEmpty)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFF3F4F6),
                          alignment: Alignment.center,
                          child: Icon(
                            PhosphorIcons.link(PhosphorIconsStyle.regular),
                            size: 28,
                            color: Colors.black38,
                          ),
                        ),
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: const Color(0xFFF3F4F6),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.black54),
                              ),
                            ),
                          );
                        },
                      ),
                      // v97d: Play overlay for video link previews.
                      // The 'type' field comes from the backend's
                      // _scrapeLinkPreview ("video" for YouTube /
                      // Vimeo / Dailymotion or any page with
                      // og:video / og:type=video.*).
                      if (type == "video")
                        IgnorePointer(
                          child: Container(
                            color: Colors.black.withOpacity(.25),
                            alignment: Alignment.center,
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.6),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (siteName.isNotEmpty) ...[
                      Text(
                        siteName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: Colors.black.withOpacity(.88),
                        ),
                      ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.5,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                          color: Colors.black.withOpacity(.62),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// v85: _StickerInline - renders an animated GIF sticker (kind == "sticker")
// inline in the moment body block. Stickers are NOT tappable (matches the
// v72 comments convention - stickers animate inline, image attachments are
// the tappable ones for the full-screen viewer). BoxFit.contain keeps
// transparent backgrounds readable.
// ============================================================================
class _StickerInline extends StatelessWidget {
  final String url;

  const _StickerInline({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 220,
          maxHeight: 220,
        ),
        color: Colors.transparent,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            width: 96,
            height: 96,
            color: Colors.black.withOpacity(.06),
            alignment: Alignment.center,
            child: Icon(
              PhosphorIcons.sticker(PhosphorIconsStyle.regular),
              size: 28,
              color: Colors.black38,
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: 96,
              height: 96,
              color: Colors.black.withOpacity(.04),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// v87: _MomentBody - renders the moment text body with @-mentions as
// blue clickable TextSpans. Mirrors _CommentBody from comment_widgets.dart
// (v66). The mentions are resolved client-side via a per-card
// Map<uid, UserRef> cache; the renderer walks the text for the canonical
// @tag style (lowercased no-spaces) and matches each one against the
// resolved users' mentionTag. On tap, calls widget.onMentionTap(uid)
// which the card's parent wires to widget.onAuthorTap to open the
// profile (same as the avatar/name tap on the card header).
//
// If mentions is empty (the v85b composer captured UIDs but the backend
// didn't ship them — pre-v87a), the renderer falls back to the
// existing plain Text render with NO behavior change.
//
// Resolving the @tag back to a uid is per-render. The card calls
// widget.resolveMentions(mentions) once on first build, caches the
// result, and the body uses it. If a mention tag is missing from
// the cache (e.g. the viewer isn't friends with the mentioned user),
// the span renders as a non-tappable blue (matches the v68 comment
// convention) so the user still sees it's a mention.
// ============================================================================

class _MomentBody extends StatelessWidget {
  final String text;
  final List<String> mentions; // UIDs the backend stored
  final TextStyle? baseStyle;
  final TextStyle? mentionStyle;
  final ValueChanged<String> onMentionTap;
  final Future<Map<String, UserRef>> Function(List<String> uids)?
      resolveMentions;
  // v88: optional CommentService for the default mention resolver.
  // When `resolveMentions` is null AND `commentService` is non-null,
  // _MomentBody will resolve mentions via `commentService.lookupManyByUids`.
  // This is the default path used by the moment card — the parent
  // (_MomentCard) passes its own commentService down so the closure
  // captures a stable reference.
  final CommentService? commentService;
  // v90: optional client-side connections cache, keyed by the
  // friend's mentionTag (lowercased no-spaces display name). When
  // the backend `mentions[]` field is empty (pre-v87a deploy) AND
  // the @-tag in the moment text matches a friend of the current
  // viewer, the renderer can still resolve the mention to a
  // tappable span. The card passes this down from
  // _FeedTabState's _myConnectionsByTag.
  final Map<String, UserRef>? myConnectionsByTag;

  const _MomentBody({
    required this.text,
    required this.mentions,
    required this.onMentionTap,
    this.baseStyle,
    this.mentionStyle,
    this.resolveMentions,
    this.commentService,
    this.myConnectionsByTag,
  });

  // Pattern: @-token not at a word boundary. Same as _CommentBody
  // (v66) so the @-tag matching is consistent across surfaces.
  static final RegExp _mentionRe =
      RegExp(r"\B@([a-z0-9_.]+)", caseSensitive: false);

  // v97d: URL pattern. Captures full URLs with a scheme.
  // v97j: also matches bare URLs that start with www. or a
  // domain.tld pattern, so users don't need to type https://.
  // Bare matches get https:// prepended before launchUrl.
  static final RegExp _urlRe =
      RegExp(r'(https?://[^\\s]+)', caseSensitive: false);

  // Bare URL pattern: starts with www. or contains a dot in a
  // domain.tld pattern followed by a path. Conservative to
  // avoid false positives like "Hello.world" or "Dr.Smith".
  // Requires either "www." prefix OR a path component after the
  // domain.
  static final RegExp _urlBareRe = RegExp(
      r'(?<![A-Za-z0-9@/])(www\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\\s]*)?|'
      r'[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.[A-Za-z]{2,}(?:/[^\\s]*)?)',
      caseSensitive: false);

  static const String _urlTrailingPunct = ".,!?:;)]\"'";

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    final defaultBase = const TextStyle(
      fontFamily: "Nunito",
      fontSize: 15,
      fontWeight: FontWeight.w500,
      height: 1.32,
      color: Color(0xFF1A1A1A), // Colors.black87 with full opacity
    );
    final defaultMention = defaultBase.copyWith(
      color: const Color(0xFF1D9BF0), // X-blue (matches comment mentions)
      fontWeight: FontWeight.w600,
    );
    final base = baseStyle ?? defaultBase;
    final mention = mentionStyle ?? defaultMention;

    // v97k: detect @-mentions AND URL links (full or bare).
    final mentionMatches = _mentionRe.allMatches(text).toList();
    final urlMatches = _urlRe.allMatches(text).toList();
    final urlBareMatches = _urlBareRe.allMatches(text).toList();
    final hasUrl = urlMatches.isNotEmpty || urlBareMatches.isNotEmpty;
    if (mentions.isEmpty && mentionMatches.isEmpty && !hasUrl) {
      return Text(text, style: base);
    }
    final matches = mentionMatches;
    return FutureBuilder<Map<String, UserRef>>(
      future: _resolveMentions(mentions),
      builder: (context, snapshot) {
        final cache = snapshot.data ?? <String, UserRef>{};
        return _WidgetTreeBody(
          text: text,
          mentionMatches: mentionMatches,
          urlMatches: urlMatches,
          urlBareMatches: urlBareMatches,
          cache: cache,
          base: base,
          mention: mention,
          onMentionTap: onMentionTap,
          myConnectionsByTag: myConnectionsByTag,
        );
      },
    );
  }

  // v88: resolve mention UIDs to UserRefs. Uses the parent's
  // resolveMentions callback if provided, else falls back to the
  // widget's own commentService. The fallback path is what _MomentCard
  // uses — the card passes its commentService down, and the body
  // resolves the UIDs directly. The explicit callback path is
  // available for tests or alternate data sources.
  Future<Map<String, UserRef>> _resolveMentions(List<String> uids) async {
    if (uids.isEmpty) return const <String, UserRef>{};
    if (resolveMentions != null) {
      return resolveMentions!(uids);
    }
    if (commentService != null) {
      return commentService!.lookupManyByUids(uids);
    }
    return const <String, UserRef>{};
  }

  


}

// ============================================================================
// v97k: _WidgetTreeBody - replaces the Text.rich-based _buildRichText
// with a Widget-tree approach. Plain text fragments are Text widgets;
// URL spans are their own GestureDetector(Text) widgets. This eliminates
// any TextSpan rendering quirks that might truncate the colored region
// of a long URL. The Wrap layout lays them out inline; the URL widget's
// own gesture detector covers its full visible bounds.
// ============================================================================
class _WidgetTreeBody extends StatelessWidget {
  const _WidgetTreeBody({
    required this.text,
    required this.mentionMatches,
    required this.urlMatches,
    required this.urlBareMatches,
    required this.cache,
    required this.base,
    required this.mention,
    required this.onMentionTap,
    required this.myConnectionsByTag,
  });

  final String text;
  final List<RegExpMatch> mentionMatches;
  final List<RegExpMatch> urlMatches;
  final List<RegExpMatch> urlBareMatches;
  final Map<String, UserRef> cache;
  final TextStyle base;
  final TextStyle mention;
  final void Function(String mentionUid) onMentionTap;
  final Map<String, UserRef>? myConnectionsByTag;

  @override
  Widget build(BuildContext context) {
    // Build a flat list of inline tokens, then split into
    // (textSpan, urlSpan) pairs that the Wrap lays out inline.
    final tokens = <_Token>[];
    for (final m in mentionMatches) {
      tokens.add(_Token.mention(
        start: m.start,
        end: m.end,
        raw: m.group(1) ?? "",
      ));
    }
    for (final m in urlMatches) {
      tokens.add(_Token.url(
        start: m.start,
        end: m.end,
        raw: m.group(0) ?? "",
      ));
    }
    for (final m in urlBareMatches) {
      // Skip bare matches that overlap a full URL match.
      final mStart = m.start;
      final mEnd = m.end;
      bool overlaps = false;
      for (final t in tokens) {
        if (t.isUrl && mStart < t.end && mEnd > t.start) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) {
        tokens.add(_Token.url(
          start: mStart,
          end: mEnd,
          raw: "https://" + (m.group(0) ?? ""),
        ));
      }
    }
    tokens.sort((a, b) => a.start.compareTo(b.start));

    final children = <Widget>[];
    int cursor = 0;
    for (final t in tokens) {
      if (t.start > cursor) {
        children.add(Text(
          text.substring(cursor, t.start),
          style: base,
        ));
      }
      if (t.isMention) {
        final tag = t.raw.toLowerCase();
        final UserRef? resolved =
            cache[tag] ?? _maybeMyConn(tag);
        final String? uid = resolved?.uid;
        if (uid != null) {
          children.add(GestureDetector(
            onTap: () => onMentionTap(uid),
            child: Text("@\${t.raw}", style: mention),
          ));
        } else {
          children.add(Text("@\${t.raw}", style: mention));
        }
      } else {
        // v97m: URL rendered as plain text in the base color. No
        // GestureDetector, no color override. The link preview card
        // (when present) is the only tap target — it carries the
        // full URL via title_link.
        children.add(Text(t.raw, style: base));
      }
      cursor = t.end;
    }
    if (cursor < text.length) {
      children.add(Text(text.substring(cursor), style: base));
    }
    // v68 convention: a no-op GestureDetector wraps the Wrap so
    // the inner link/mention taps win the gesture arena over any
    // parent GestureDetector (e.g. card-level onLike/onComment).
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        children: children,
      ),
    );
  }

  UserRef? _maybeMyConn(String tag) {
    return myConnectionsByTag?[tag];
  }


}

enum _TokenKind { mention, url }

class _Token {
  const _Token._({
    required this.start,
    required this.end,
    required this.kind,
    required this.raw,
  });

  factory _Token.mention({
    required int start,
    required int end,
    required String raw,
  }) =>
      _Token._(start: start, end: end, kind: _TokenKind.mention, raw: raw);

  factory _Token.url({
    required int start,
    required int end,
    required String raw,
  }) =>
      _Token._(start: start, end: end, kind: _TokenKind.url, raw: raw);

  final int start;
  final int end;
  final _TokenKind kind;
  final String raw;

  bool get isMention => kind == _TokenKind.mention;
  bool get isUrl => kind == _TokenKind.url;
}

// v92d: data class for the poll composer bottom-sheet result.
// Mirrors the chat's _PingmeePollDraft.
class _PollComposerDraft {
  final String question;
  final List<String> options;

  const _PollComposerDraft({
    required this.question,
    required this.options,
  });
}

// v92d: poll composer bottom sheet. Mirrors _PingmeeCreatePollSheet
// from chat_channel_page.dart but is scoped to the feed composer.
// Returns a _PollComposerDraft via Navigator.pop on submit.
class _FeedPollComposerSheet extends StatefulWidget {
  final String initialQuestion;
  final List<String>? initialOptions;

  const _FeedPollComposerSheet({
    super.key,
    this.initialQuestion = "",
    this.initialOptions,
  });

  @override
  State<_FeedPollComposerSheet> createState() =>
      _FeedPollComposerSheetState();
}

class _FeedPollComposerSheetState extends State<_FeedPollComposerSheet> {
  late final TextEditingController _questionCtrl;
  late final List<TextEditingController> _optionCtrls;

  @override
  void initState() {
    super.initState();
    _questionCtrl = TextEditingController(text: widget.initialQuestion);
    final opts = widget.initialOptions ?? const ["", ""];
    _optionCtrls = opts.map((o) => TextEditingController(text: o)).toList();
  }

  @override
  void dispose() {
    _questionCtrl.dispose();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    if (_optionCtrls.length >= 8) return;
    setState(() {
      _optionCtrls.add(TextEditingController());
    });
  }

  void _removeOption(int index) {
    if (_optionCtrls.length <= 2) return;
    setState(() {
      final c = _optionCtrls.removeAt(index);
      c.dispose();
    });
  }

  void _submit() {
    final question = _questionCtrl.text.trim();
    final options = _optionCtrls
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (question.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(content: Text("Poll question is required.")),
      );
      return;
    }
    if (options.length < 2) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            "Add at least two poll options (you have ${options.length}).",
          ),
        ),
      );
      return;
    }
    // v92q: case-insensitive dedup. The user might type "7" and "7"
    // (same) or "Yes" and "yes" (semantically same) or " 7 " and "7"
    // (whitespace). Stream's createPoll rejects duplicates by
    // exact text match; case matters for them but not for the user.
    // Lowercase the comparison so the SnackBar fires for both
    // forms. Whitespace is already trimmed above.
    final seen = <String>{};
    String? duplicate;
    for (final o in options) {
      final key = o.toLowerCase();
      if (seen.contains(key)) {
        duplicate = o;
        break;
      }
      seen.add(key);
    }
    if (duplicate != null) {
      messenger?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            'Poll options must be unique. "$duplicate" is used twice.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).pop(
      _PollComposerDraft(question: question, options: options),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(14),
          constraints: BoxConstraints(
            maxHeight: media.size.height * .82,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  "Create poll",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.85),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  controller: _questionCtrl,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 15.5,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: "Ask a question...",
                    filled: true,
                    fillColor: const Color(0xFFF3F4F6),
                    counterText: "",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < _optionCtrls.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 4,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _optionCtrls[i],
                                  maxLength: 200,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: "Option ${i + 1}",
                                    filled: true,
                                    fillColor: const Color(0xFFF3F4F6),
                                    counterText: "",
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                    contentPadding: const EdgeInsets.all(14),
                                  ),
                                ),
                              ),
                              if (_optionCtrls.length > 2)
                                IconButton(
                                  icon: Icon(
                                    PhosphorIcons.x(PhosphorIconsStyle.bold),
                                    size: 18,
                                    color: Colors.black.withOpacity(.55),
                                  ),
                                  onPressed: () => _removeOption(i),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (_optionCtrls.length < 8)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: TextButton.icon(
                    onPressed: _addOption,
                    icon: Icon(
                      PhosphorIcons.plus(PhosphorIconsStyle.bold),
                      size: 16,
                    ),
                    label: const Text("Add option"),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black.withOpacity(.7),
                      textStyle: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text("Cancel"),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text("Create poll"),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// v92d: small chip below the AttachmentBar that shows the
// attached poll and lets the user remove it. Mirrors how the
// comment composer surfaces the active @-mentions.
class _FeedPollChip extends StatelessWidget {
  final String question;
  final List<String> options;
  final VoidCallback onRemove;

  const _FeedPollChip({
    super.key,
    required this.question,
    required this.options,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIcons.chartBar(PhosphorIconsStyle.bold),
            size: 18,
            color: Colors.black.withOpacity(.7),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  question.isEmpty ? "Poll" : question,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.85),
                  ),
                ),
                if (options.isNotEmpty)
                  Text(
                    "${options.length} options",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              PhosphorIcons.x(PhosphorIconsStyle.bold),
              size: 16,
              color: Colors.black.withOpacity(.55),
            ),
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// v92e: inline poll widget on the feed card. Mirrors the structure
// of _CommentAttachmentThumb / _LinkPreviewCard — a self-contained
// card rendered below the moment body. Reads the poll object that
// v92b allowlists on each activity (id, name, options, vote_count,
// vote_counts_by_option, latest_votes_by_option, own_votes). Tapping
// an option calls _feedService.castFeedPollVote (v92a) and rebuilds
// the local counts optimistically.
class _FeedPollWidget extends StatefulWidget {
  final String activityId;
  final Map<String, dynamic> poll;
  final PingmeeFeedService feedService;

  const _FeedPollWidget({
    super.key,
    required this.activityId,
    required this.poll,
    required this.feedService,
  });

  @override
  State<_FeedPollWidget> createState() => _FeedPollWidgetState();
}

class _FeedPollWidgetState extends State<_FeedPollWidget> {
  bool _casting = false;
  String? _selectedOptionId;
  // Local counts so the UI reflects the user's last tap immediately
  // before the server response comes back. Falls back to the poll's
  // own vote_counts_by_option on first render.
  late Map<String, int> _localCounts;
  late int _localTotal;

  @override
  void initState() {
    super.initState();
    _localCounts = _initialCounts(widget.poll);
    _localTotal = _localCounts.values.fold(0, (s, n) => s + n);
    // Pre-select the option the user already voted for (Stream
    // returns own_votes on GET).
    final ownVotes = widget.poll["own_votes"];
    if (ownVotes is List && ownVotes.isNotEmpty) {
      final first = ownVotes.first;
      if (first is Map && first["option_id"] is String) {
        _selectedOptionId = first["option_id"] as String;
      }
    }
  }

  Map<String, int> _initialCounts(Map<String, dynamic> poll) {
    final options = poll["options"];
    final byOption = poll["vote_counts_by_option"];
    if (options is! List) return <String, int>{};
    final out = <String, int>{};
    for (final opt in options) {
      if (opt is Map && opt["id"] is String) {
        final id = opt["id"] as String;
        int count = 0;
        if (byOption is Map && byOption[id] is num) {
          count = (byOption[id] as num).toInt();
        } else if (opt["vote_count"] is num) {
          count = (opt["vote_count"] as num).toInt();
        }
        out[id] = count;
      }
    }
    return out;
  }

  Future<void> _onVote(String optionId) async {
    if (_casting) return;
    if (widget.poll["is_closed"] == true) return;

    final previous = _selectedOptionId;
    setState(() {
      _casting = true;
      // Optimistic update: subtract from previous, add to new.
      if (previous != null && _localCounts.containsKey(previous)) {
        _localCounts[previous] = (_localCounts[previous] ?? 0) - 1;
      }
      _localCounts[optionId] = (_localCounts[optionId] ?? 0) + 1;
      _localTotal = _localCounts.values.fold(0, (s, n) => s + n);
      _selectedOptionId = optionId;
    });

    try {
      final pollId = (widget.poll["id"] ?? "").toString();
      if (pollId.isEmpty) return;
      await widget.feedService.castFeedPollVote(
        activityId: widget.activityId,
        pollId: pollId,
        optionId: optionId,
      );
    } catch (e) {
      // Roll back the optimistic update on failure.
      if (mounted) {
        setState(() {
          if (previous != null && _localCounts.containsKey(previous)) {
            _localCounts[previous] = (_localCounts[previous] ?? 0) + 1;
          }
          _localCounts[optionId] = (_localCounts[optionId] ?? 0) - 1;
          _localTotal = _localCounts.values.fold(0, (s, n) => s + n);
          _selectedOptionId = previous;
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text("Couldn't cast vote: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _casting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (widget.poll["name"] ?? "Poll").toString();
    final options = widget.poll["options"];
    final isClosed = widget.poll["is_closed"] == true;
    final total = _localTotal == 0 ? 1 : _localTotal;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIcons.chartBar(PhosphorIconsStyle.bold),
                size: 16,
                color: Colors.black.withOpacity(.7),
              ),
              const SizedBox(width: 6),
              Text(
                isClosed ? "Poll (closed)" : "Poll",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(.6),
                ),
              ),
              const Spacer(),
              if (_casting)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          if (options is List)
            for (final opt in options)
              _buildOption(
                opt is Map
                    ? Map<String, dynamic>.from(opt as Map)
                    : <String, dynamic>{},
                total: total,
              ),
        ],
      ),
    );
  }

  Widget _buildOption(
    Map<String, dynamic> opt, {
    required int total,
  }) {
    final id = (opt["id"] ?? "").toString();
    final text = (opt["text"] ?? "").toString();
    final count = _localCounts[id] ?? 0;
    final pct = ((count / (total == 0 ? 1 : total)) * 100).round();
    final isSelected = _selectedOptionId == id;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _onVote(id),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.black.withOpacity(.08)
                  : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected
                    ? Colors.black.withOpacity(.25)
                    : Colors.black.withOpacity(.08),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                    ),
                  ),
                ),
                if (count > 0 || isSelected) ...[
                  const SizedBox(width: 6),
                  Text(
                    "$pct%",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ],
                if (isSelected) ...[
                  const SizedBox(width: 4),
                  Icon(
                    PhosphorIcons.check(PhosphorIconsStyle.bold),
                    size: 14,
                    color: Colors.black.withOpacity(.75),
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


// v95b: rich Post button. When canPost is false, the button is
// greyed-out. When creating is true, it shows a spinner + a stage
// label driven by `creatingStage` (e.g. "Uploading media...",
// "Creating poll...", "Posting moment...", "Refreshing feed...")
// + a small linear progress bar. Tapping dispatches onTap (called
// only when canPost is true and creating is false).
// v95f: floating posting feedback overlay. The parent
// (_FeedTabState) inserts an OverlayEntry into the screen overlay
// while the post flow is running and removes it when done. The
// bar is a black-transparent rectangle with white text, no
// border, no rounded corners, full width, sitting at the bottom
// of the screen above the keyboard. Shows a spinner + the current
// upload stage label.
class _PostingOverlay extends StatelessWidget {
  // v95h: small centered rounded pill. Width 80, rounded borders
  // (BorderRadius 20), 0.9 alpha black background. White spinner
  // + white text. For new moments shows "Posting your moment...";
  // for reposts shows "Quoting moment...". The parent
  // (_FeedTabState) inserts/removes an OverlayEntry wrapping this
  // widget while the post flow is running.
  const _PostingOverlay({required this.stage, this.isQuote = false});

  final String? stage;
  final bool isQuote;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.viewInsets.bottom + 32,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 260,
              decoration: BoxDecoration(
                color: const Color(0x99000000), // 0.6 alpha black
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 14,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      (stage != null && stage!.isNotEmpty)
                          ? stage!
                          : (isQuote
                              ? "Quoting moment..."
                              : "Posting your moment..."),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
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
    );
  }
}
