import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/pings/manage_ping_screen.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'package:ping_files/main_app/tabs/feed/liked_moments_screen.dart';
import 'package:ping_files/main_app/tabs/feed/saved_moments_screen.dart';
import 'package:ping_files/main_app/tabs/feed/moment_detail_screen.dart';
import 'package:ping_files/main_app/tabs/feed/shared_moment_widgets.dart' show SharedMediaItem;
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/main_app/tabs/profile/profile_engagement_screen.dart';
import 'package:ping_files/features/pings/ping_join_notifications.dart';
import 'package:ping_files/features/pings/ping_join_request_actions.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/features/events/event_details_screen.dart';
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

  const FeedTab({super.key, this.onOpenUserProfile});

  @override
  State<FeedTab> createState() => _FeedTabState();
}

/// Public alias for the FeedTab's State so the main app shell can
/// hold a GlobalKey<FeedTabState> and call scrollToTop() on it.
typedef FeedTabState = _FeedTabState;

class _FeedTabState extends State<FeedTab> with SingleTickerProviderStateMixin {
  final PingmeeFeedService _feedService = PingmeeFeedService();

  /// Convenience getter for the parent-supplied onOpenUserProfile
  /// callback. Used by the feed's moment cards to navigate to a
  /// tapped user's profile.
  void Function(String authorUid)? get _onOpenUserProfile =>
      widget.onOpenUserProfile;

  StreamSubscription<User?>? _authSub;
  _FeedMode _feedMode = _FeedMode.following;

  bool _feedBooted = false;
  bool _bootingFeed = false;
  bool _printedBuildLog = false;

  String? _feedBootError;
  String? _bootedUid;

  List<Map<String, dynamic>> _timelineMoments = [];
  Map<String, bool> _verifiedCache = {};

  bool _loadingMoments = false;
  bool _loadingMore = false;
  bool _creatingMoment = false;

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
    _feedScrollController.removeListener(_onFeedScroll);
    _feedScrollController.dispose();
    _authSub?.cancel();
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

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _MomentMoreSheet(isOwner: isOwner),
    );

    if (action == null) return;

    final activityId = (moment["id"] ?? "").toString().trim();
    final foreignId = (moment["foreignId"] ?? "").toString().trim();

    if (activityId.isEmpty || foreignId.isEmpty) return;

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

    try {
      await _feedService.createMomentRepost(
        originalMoment: moment,
        quoteText: action.quoteText,
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

    setState(() {
      _bootingFeed = true;
      _feedBootError = null;
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
    if (_loadingMoments) return;

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
    );
  }

  Future<void> _createAndReloadMoment(
    String text, {
    List<_MomentPickedMedia> pickedMedia = const [],
  }) async {
    if (_creatingMoment) return;

    setState(() => _creatingMoment = true);

    try {
      final media = <Map<String, dynamic>>[];

      for (int i = 0; i < pickedMedia.length; i++) {
        final item = pickedMedia[i];

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
      debugPrint("🧪 Moment media before create: count=${media.length}");
      for (final item in media) {
        debugPrint("🧪 Moment media item=$item");
      }

      final createResult = await _feedService.createMoment(
        text: text,
        media: media,
      );

      debugPrint("🧪 createMoment result mediaCount=${createResult["mediaCount"]}");
      debugPrint("🧪 createMoment result media=${createResult["media"]}");
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
        setState(() => _creatingMoment = false);
      }
    }
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
      child: ListView.separated(
        controller: _feedScrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
        itemCount: _timelineMoments.length + 1 + footerCount,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _CreateMomentPreviewCard(
              creating: _creatingMoment,
              onCreateMoment: _openCreateMomentSheet,
            );
          }

          final momentIndex = index - 1;
          if (momentIndex >= _timelineMoments.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.brandGreen),
              ),
            );
          }

          final moment = _timelineMoments[momentIndex];

          return _MomentCard(
            data: moment,
            onLike: () => _toggleMomentLike(momentIndex),
            onComment: () => _openMomentComments(moment),
            onSave: () => _toggleMomentBookmark(momentIndex),
            onRepost: () => _openRepostSheet(moment),
            onMore: () => _openMomentMoreSheet(moment, momentIndex),
            onShare: () => _shareMoment(moment),
            authorVerified: _verifiedCache[(moment["authorUid"] ?? "").toString().trim()] ?? false,
            verifiedCache: _verifiedCache,
            feedService: _feedService,
            onAuthorTap: _onOpenUserProfile,
          );
        },
      ),
    );
  }

  Future<void> _openMomentComments(Map<String, dynamic> moment) async {
    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MomentCommentsSheet(
        activityId: activityId,
        feedService: _feedService,
      ),
    );

    await _loadTimelineMoments(reason: "after comments sheet");
  }

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
                child: Column(
                  children: [
                    // Threads-style header — just hamburger + bell when closed
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 6),
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
                          if (uid != null) _NotificationsBell(uid: uid),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _buildMomentsBody(),
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

  const _CreateMomentPreviewCard({
    required this.creating,
    required this.onCreateMoment,
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
              Container(
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
              ),
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

  const _CreateMomentDraft({
    required this.text,
    required this.media,
  });
}

class _MomentPickedMedia {
  final String id;
  final String type; // image | video
  final AssetEntity? asset;
  final File? file;
  final String? name;
  final Uint8List? previewBytes;

  const _MomentPickedMedia({
    required this.id,
    required this.type,
    this.asset,
    this.file,
    this.name,
    this.previewBytes,
  });
}

class _CreateMomentSheet extends StatefulWidget {
  const _CreateMomentSheet();

  @override
  State<_CreateMomentSheet> createState() => _CreateMomentSheetState();
}

class _CreateMomentSheetState extends State<_CreateMomentSheet> {
  final TextEditingController _controller = TextEditingController();

  static const int _maxChars = 500;

  final List<_MomentPickedMedia> _media = [];

  bool get _mediaFull => _media.length >= 4;

  Future<void> _pickMediaFromGallery() async {
    if (_mediaFull) return;

    try {
      final maxPick = 4 - _media.length;

      final PermissionState permission =
          await PhotoManager.requestPermissionExtend();

      if (!permission.isAuth) {
        return;
      }

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
          [
            ".mp4",
            ".mov",
            ".m4v",
            ".webm",
            ".mkv",
            ".avi",
          ].contains(ext);

      Uint8List? previewBytes;

      if (isVideo) {
        previewBytes =
            await video_thumb.VideoThumbnail.thumbnailData(
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

  void _removeMedia(_MomentPickedMedia item) {
    setState(() {
      _media.removeWhere((m) => m.id == item.id);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canPost {
    final text = _controller.text.trim();
    return (text.isNotEmpty || _media.isNotEmpty) && text.length <= _maxChars;
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
                            onPressed: _canPost
                                ? () {
                                    Navigator.pop(
                                      context,
                                      _CreateMomentDraft(
                                        text: _controller.text.trim(),
                                        media: List<_MomentPickedMedia>.from(_media),
                                      ),
                                    );
                                  }
                                : null,
                            child: Text(
                              "Post",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w800,
                                color: _canPost
                                    ? AppColors.brandGreen
                                    : Colors.black.withOpacity(.25),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _controller,
                        autofocus: true,
                        maxLines: 7,
                        minLines: 4,
                        maxLength: _maxChars + 20,
                        onChanged: (_) => setLocalState(() {}),
                        decoration: InputDecoration(
                          hintText: "What’s happening around you?",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
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

                      Row(
                        children: [
                          _MomentComposerMediaButton(
                            icon: PhosphorIcons.image(PhosphorIconsStyle.bold),
                            label: "Gallery",
                            onTap: _mediaFull ? null : _pickMediaFromGallery,
                          ),
                          const SizedBox(width: 10),
                          _MomentComposerMediaButton(
                            icon: PhosphorIcons.camera(PhosphorIconsStyle.bold),
                            label: "Camera",
                            onTap: _mediaFull ? null : _pickMediaFromCamera,
                          ),
                          const Spacer(),
                          Text(
                            "${_media.length}/4",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.black.withOpacity(.42),
                            ),
                          ),
                        ],
                      ),

                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 96,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _media.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 10),
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

                      const SizedBox(height: 10),
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
                                fontWeight: FontWeight.w700,
                                color: Colors.black.withOpacity(.45),
                              ),
                            ),
                          ),
                          Text(
                            "$count/$_maxChars",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: overLimit
                                  ? const Color(0xFFB42318)
                                  : Colors.black.withOpacity(.42),
                            ),
                          ),
                        ],
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
  final PingmeeFeedService feedService;
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
    required this.feedService,
    this.onAuthorTap,
  });

  String _text(String key) => (data[key] ?? "").toString().trim();

  String _prettyMomentTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return "";

    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;

    final local = parsed.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    if (diff.inSeconds < 60) return "now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m";
    if (diff.inHours < 24) return "${diff.inHours}h";
    if (diff.inDays < 7) return "${diff.inDays}d";

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

  @override
  Widget build(BuildContext context) {
    final authorName = _text("authorName").isNotEmpty
        ? _text("authorName")
        : "Pingmee user";

     final commentCount = data["commentCount"] is num
        ? (data["commentCount"] as num).toInt()
        : 0;   

    final authorPhotoUrl = _text("authorPhotoUrl");
    final text = _text("text");
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

    final visualMedia = media.where((item) {
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();

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
            Text(
              text,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 15,
                fontWeight: FontWeight.w500,
                height: 1.32,
                color: Colors.black.withOpacity(.82),
              ),
            ),
            const SizedBox(height: 8),
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
            if (text.isEmpty) ...[
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
            ],
            _OriginalMomentMiniCard(
              authorName: originalAuthorName.isNotEmpty
                  ? originalAuthorName
                  : "Pingmee user",
              text: originalText,
              authorPhotoUrl: _text("originalAuthorPhotoUrl"),
              authorVerified: verifiedCache[_text("originalAuthorUid")] ?? false,
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
                label: likeCount > 0 ? "$likeCount" : "",
                active: likedByMe,
                activeColor: const Color(0xFFEF4444), // red
                onTap: onLike,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
                label: commentCount > 0 ? "$commentCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onComment,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.repeat(PhosphorIconsStyle.bold),
                label: repostCount > 0 ? "$repostCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onRepost,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
                label: shareCount > 0 ? "$shareCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onShare,
              ),
              const SizedBox(width: 24),
              _MomentAction(
                icon: savedByMe
                    ? PhosphorIcons.bookmark(PhosphorIconsStyle.fill)
                    : PhosphorIcons.bookmark(PhosphorIconsStyle.regular),
                label: savedCount > 0 ? "$savedCount" : "",
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
    // Build media list for carousel (image/video only)
    final mediaItems = (originalMedia as List).whereType<Map>().where((item) {
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return url.isNotEmpty && (type == "image" || type == "video");
    }).toList();

    final hasMedia = mediaItems.isNotEmpty;

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

  const _RepostAction({
    required this.quoteText,
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

  static const int _maxChars = 300;

  String _text(String key) => (widget.moment[key] ?? "").toString().trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canQuote {
    final text = _controller.text.trim();
    return text.isNotEmpty && text.length <= _maxChars;
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
                            onPressed: () {
                              Navigator.pop(
                                context,
                                const _RepostAction(quoteText: ""),
                              );
                            },
                            child: const Text(
                              "Repost",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w800,
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
                      TextField(
                        controller: _controller,
                        maxLines: 5,
                        minLines: 3,
                        maxLength: _maxChars + 20,
                        onChanged: (_) => setLocalState(() {}),
                        decoration: InputDecoration(
                          hintText: "Add your thoughts...",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              "Optional quote",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.black.withOpacity(.45),
                              ),
                            ),
                          ),
                          Text(
                            "$count/$_maxChars",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: overLimit
                                  ? const Color(0xFFB42318)
                                  : Colors.black.withOpacity(.42),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _canQuote
                              ? () {
                                  Navigator.pop(
                                    context,
                                    _RepostAction(
                                      quoteText: _controller.text.trim(),
                                    ),
                                  );
                                }
                              : null,
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
                              fontWeight: FontWeight.w800,
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

class _MomentCommentsSheet extends StatefulWidget {
  final String activityId;
  final PingmeeFeedService feedService;

  const _MomentCommentsSheet({
    required this.activityId,
    required this.feedService,
  });

  @override
  State<_MomentCommentsSheet> createState() => _MomentCommentsSheetState();
}

class _MomentCommentsSheetState extends State<_MomentCommentsSheet> {
  final TextEditingController _controller = TextEditingController();

  bool _loading = true;
  bool _sending = false;
  String? _error;

  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final comments = await widget.feedService.loadMomentComments(
        activityId: widget.activityId,
      );

      if (!mounted) return;

      setState(() {
        _comments = comments;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = "Couldn’t load comments.";
      });
    }
  }

  Future<void> _sendComment() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    try {
      await widget.feedService.addMomentComment(
        activityId: widget.activityId,
        text: text,
      );

      _controller.clear();
      await _loadComments();
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn’t add comment.")),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: MediaQuery.of(context).size.height * .82,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
            ),
            child: SafeArea(
              top: false,
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
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Comments",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.brandGreen,
                              ),
                            ),
                          )
                        : _error != null
                            ? Center(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : _comments.isEmpty
                                ? Center(
                                    child: Text(
                                      "No comments yet. Start it.",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black.withOpacity(.55),
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      0,
                                      18,
                                      18,
                                    ),
                                    itemCount: _comments.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      return _MomentCommentTile(
                                        data: _comments[index],
                                      );
                                    },
                                  ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        top: BorderSide(
                          color: Colors.black.withOpacity(.06),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendComment(),
                            decoration: InputDecoration(
                              hintText: "Add a comment...",
                              hintStyle: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w600,
                                color: Colors.black.withOpacity(.38),
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF3F4F6),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: _sending ? null : _sendComment,
                          borderRadius: BorderRadius.circular(18),
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Center(
                              child: _sending
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : Icon(
                                      PhosphorIcons.paperPlaneTilt(
                                        PhosphorIconsStyle.fill,
                                      ),
                                      color: Colors.white,
                                      size: 19,
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
      ),
    );
  }
}

class _MomentCommentTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _MomentCommentTile({
    required this.data,
  });

  String _text(String key) => (data[key] ?? "").toString().trim();

  @override
  Widget build(BuildContext context) {
    final name = _text("authorName").isNotEmpty
        ? _text("authorName")
        : "Pingmee user";
    final photoUrl = _text("authorPhotoUrl");
    final text = _text("text");

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MomentAvatar(photoUrl: photoUrl),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: Colors.black.withOpacity(.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

  const _MomentMoreSheet({
    required this.isOwner,
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
              // Action row — Delete when you own the moment, Report otherwise.
              // Mirrors the design used in MomentDetailScreen's MomentMoreSheet:
              // flag icon for Report, trash icon in red for Delete.
              if (isOwner)
                _MomentMoreTile(
                  icon: PhosphorIcons.trash(PhosphorIconsStyle.regular),
                  title: "Delete Moment",
                  danger: true,
                  onTap: () => Navigator.pop(context, "delete"),
                )
              else
                _MomentMoreTile(
                  icon: PhosphorIcons.flag(PhosphorIconsStyle.regular),
                  title: "Report Moment",
                  danger: false,
                  onTap: () => Navigator.pop(context, "report"),
                ),
              const SizedBox(height: 8),
              // Always-present Cancel row — lets the user dismiss the sheet
              // even when there is no destructive action to confirm.
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

class _NotificationsBell extends StatelessWidget {
  final String uid;
  const _NotificationsBell({required this.uid});

  @override
  Widget build(BuildContext context) {
    final unreadStream = FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .collection("notifications")
        .where("read", isEqualTo: false)
        .limit(1)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: unreadStream,
      builder: (context, snap) {
        final hasUnread = (snap.data?.docs.isNotEmpty ?? false);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: Colors.transparent,
                builder: (_) => NotificationsSheet(uid: uid),
              );
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.80),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(.55)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                    color: Colors.black.withOpacity(.06),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                    child: Icon(
                      PhosphorIcons.bell(PhosphorIconsStyle.light),
                      color: Colors.black.withOpacity(.78),
                      size: 22,
                    ),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.8),
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
}

class NotificationsSheet extends StatefulWidget {
  final String uid;
  const NotificationsSheet({super.key, required this.uid});

  @override
  State<NotificationsSheet> createState() => _NotificationsSheetState();
}

class _NotificationsSheetState extends State<NotificationsSheet> {
  static const int _initialLimit = 15;
  static const int _step = 15;
  static const int _maxLimit = 50;

  int _currentLimit = _initialLimit;
  final ScrollController _scrollController = ScrollController();

  void _loadMore() {
    if (_currentLimit >= _maxLimit) return;

    setState(() {
      _currentLimit = (_currentLimit + _step).clamp(_initialLimit, _maxLimit);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection("users")
        .doc(widget.uid)
        .collection("notifications")
        .orderBy("createdAt", descending: true)
        .limit(_currentLimit)
        .snapshots();

    return _GlassBottomSheet(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.86,
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
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Notifications",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final unread = await FirebaseFirestore.instance
                          .collection("users")
                          .doc(widget.uid)
                          .collection("notifications")
                          .where("read", isEqualTo: false)
                          .get();

                      final batch = FirebaseFirestore.instance.batch();
                      for (final doc in unread.docs) {
                        batch.update(doc.reference, {"read": true});
                      }
                      await batch.commit();
                    },
                    child: const Text(
                      "Mark all read",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: stream,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const _NotificationsLoadingList();
                  }

                  if (snap.hasError) {
                    return const Center(
                      child: Text(
                        "Couldn’t load notifications",
                        style: TextStyle(fontFamily: "Nunito"),
                      ),
                    );
                  }

                  final docs = snap.data?.docs ?? [];

                  if (docs.isEmpty) {
                    return Center(
                      child: Text(
                        "No notifications yet.",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                    );
                  }

                  final sections = _NotificationSections.fromDocs(docs);

                  final canLoadMore =
                      docs.length >= _currentLimit && _currentLimit < _maxLimit;

                  return ListView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                    children: [
                      if (sections.today.isNotEmpty) ...[
                        const _SkeletonSectionHeader("Today"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.today, widget.uid),
                        const SizedBox(height: 18),
                      ],
                      if (sections.thisWeek.isNotEmpty) ...[
                        const _SkeletonSectionHeader("This week"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.thisWeek, widget.uid),
                        const SizedBox(height: 18),
                      ],
                      if (sections.earlier.isNotEmpty) ...[
                        const _SkeletonSectionHeader("Earlier"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.earlier, widget.uid),
                        const SizedBox(height: 18),
                      ],

                      if (canLoadMore)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: _loadMore,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black,
                                side: BorderSide(
                                  color: Colors.black,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                backgroundColor: Colors.white.withOpacity(.75),
                              ),
                              child: Text(
                                _currentLimit + _step >= _maxLimit
                                    ? "Load last notifications"
                                    : "Load more notifications",
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildNotificationTiles(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String uid,
  ) {
    return List.generate(docs.length, (i) {
      final doc = docs[i];
      return Padding(
        padding: EdgeInsets.only(bottom: i == docs.length - 1 ? 0 : 10),
        child: _NotificationTile(
          currentUid: uid,
          notifRef: doc.reference,
          data: doc.data(),
        ),
      );
    });
  }
}

class _NotificationTile extends StatefulWidget {
  final String currentUid;
  final DocumentReference<Map<String, dynamic>> notifRef;
  final Map<String, dynamic> data;

  const _NotificationTile({
    required this.currentUid,
    required this.notifRef,
    required this.data,
  });

  @override
  State<_NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<_NotificationTile> {
  bool _busy = false;

  Future<void> _openNotificationTarget(
    BuildContext context, {
    required bool read,
    required String type,
    required String senderUid,
    required String pingId,
    required String eventId,
  }) async {
    if (!read) {
      await widget.notifRef.set({"read": true}, SetOptions(merge: true));
    }

    if ((type == "ping_joined" ||
          type == "ping_join_request" ||
          type == "ping_member_left") &&
      pingId.isNotEmpty) {
    if (!context.mounted) return;
    await openManagePingScreen(
      context: context,
      pingId: pingId,
    );
    return;
  }

  if ((type == "event_cohost_invite" ||
          type == "event_cohost_invite_denied" ||
          type == "event_cohost_invite_accepted") &&
      eventId.isNotEmpty) {
    if (!context.mounted) return;
    await _openEventPreview(
      context,
      eventId: eventId,
    );
    return;
  }

  if (type == "ping_invite" && pingId.isNotEmpty) {
    if (!context.mounted) return;
    await openPingDetailsSheet(
      context: context,
      pingId: pingId,
    );
    return;
  }

    if (type == "profile_view") {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileEngagementScreen(uid: widget.currentUid),
        ),
      );
      return;
    }

    if (type == "community_invite") {
      return;
    }

    if (senderUid.isNotEmpty) {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileTab(profileUid: senderUid),
        ),
      );
    }
  }

  Future<void> _openEventPreview(
    BuildContext context, {
    required String eventId,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection("events")
        .doc(eventId)
        .get();

    if (!snap.exists) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Event no longer exists.")),
      );
      return;
    }

    final data = snap.data() ?? <String, dynamic>{};

    if (!context.mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventDetailsScreen(
          data: EventDetailsData.fromMap(snap.id, data),
        ),
      ),
    );
  }

  Future<void> _handleEventCohostInviteAction({
    required bool approve,
  }) async {
    if (_busy) return;

    final data = widget.data;
    final eventId = (data["eventId"] ?? "").toString().trim();
    final inviterUid = (data["senderUid"] ?? "").toString().trim();
    final eventTitle = (data["eventTitle"] ?? "").toString().trim();
    final eventCoverImageUrl =
        (data["eventCoverImageUrl"] ?? "").toString().trim();
    final eventCoverPresetAssetPath =
        (data["eventCoverPresetAssetPath"] ?? "").toString().trim();

    final currentUid = widget.currentUid;
    if (eventId.isEmpty || currentUid.isEmpty) {
      debugPrint("❌ cohost action aborted: missing eventId/currentUid");
      return;
    }

    setState(() => _busy = true);

    try {
      final db = FirebaseFirestore.instance;
      final eventRef = db.collection("events").doc(eventId);
      final hostRef = eventRef.collection("hosts").doc(currentUid);

      debugPrint("▶️ cohost action start");
      debugPrint("  approve=$approve");
      debugPrint("  eventId=$eventId");
      debugPrint("  currentUid=$currentUid");
      debugPrint("  inviterUid=$inviterUid");

      await db.runTransaction((tx) async {
        final eventSnap = await tx.get(eventRef);
        final hostSnap = await tx.get(hostRef);

        debugPrint("  event exists=${eventSnap.exists}");
        debugPrint("  host exists=${hostSnap.exists}");

        if (!eventSnap.exists) {
          throw Exception("Event no longer exists.");
        }

        if (!hostSnap.exists) {
          throw Exception("Host invite doc not found.");
        }

        final hostData = hostSnap.data() ?? <String, dynamic>{};

        debugPrint("  hostData=$hostData");

        final Map<String, dynamic> nextHostData;

        if (approve) {
          nextHostData = {
            "uid": currentUid,
            "role": "cohost",
            "status": "active",
            "invitedBy": hostData["invitedBy"],
            "invitedAt": hostData["invitedAt"],
            "respondedAt": FieldValue.serverTimestamp(),
            "addedAt": FieldValue.serverTimestamp(),
          };
        } else {
          nextHostData = {
            "uid": currentUid,
            "role": "cohost",
            "status": "declined",
            "invitedBy": hostData["invitedBy"],
            "invitedAt": hostData["invitedAt"],
            "respondedAt": FieldValue.serverTimestamp(),
          };
        }

        debugPrint("  nextHostKeys=${nextHostData.keys.toList()}");
        debugPrint("  nextHostStatus=${nextHostData["status"]}");

        tx.set(
          hostRef,
          nextHostData,
          SetOptions(merge: false),
        );

        if (approve && inviterUid.isNotEmpty && inviterUid != currentUid) {
          final acceptNotifRef = db
              .collection("users")
              .doc(inviterUid)
              .collection("notifications")
              .doc();

          debugPrint("  sending accept notification to $inviterUid");

          tx.set(
            acceptNotifRef,
            {
              "type": "event_cohost_invite_accepted",
              "eventId": eventId,
              "eventTitle": eventTitle,
              "eventCoverImageUrl": eventCoverImageUrl,
              "eventCoverPresetAssetPath": eventCoverPresetAssetPath,
              "senderUid": currentUid,
              "recipientUid": inviterUid,
              "title": "Co-host invite accepted",
              "body": eventTitle.isNotEmpty
                  ? 'accepted your co-host invite for "$eventTitle".'
                  : "accepted your co-host invite.",
              "createdAt": FieldValue.serverTimestamp(),
              "read": false,
            },
          );
        }

        if (!approve && inviterUid.isNotEmpty && inviterUid != currentUid) {
          final denyNotifRef = db
              .collection("users")
              .doc(inviterUid)
              .collection("notifications")
              .doc();

          debugPrint("  sending decline notification to $inviterUid");

          tx.set(
            denyNotifRef,
            {
              "type": "event_cohost_invite_denied",
              "eventId": eventId,
              "eventTitle": eventTitle,
              "eventCoverImageUrl": eventCoverImageUrl,
              "eventCoverPresetAssetPath": eventCoverPresetAssetPath,
              "senderUid": currentUid,
              "recipientUid": inviterUid,
              "title": "Co-host invite declined",
              "body": eventTitle.isNotEmpty
                  ? 'declined your co-host invite for "$eventTitle".'
                  : "declined your co-host invite.",
              "createdAt": FieldValue.serverTimestamp(),
              "read": false,
            },
          );
        }

        tx.set(
          widget.notifRef,
          {
            "actionState": approve ? "approved" : "denied",
            "resolvedAt": FieldValue.serverTimestamp(),
            "read": true,
          },
          SetOptions(merge: true),
        );
      });

      debugPrint("✅ cohost action success");

      if (!mounted) return;

      if (approve) {
        await _openEventPreview(
          context,
          eventId: eventId,
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Co-host invite declined.")),
        );
      }
    } on FirebaseException catch (e, st) {
      debugPrint("🔥 FirebaseException on cohost action");
      debugPrint("  code=${e.code}");
      debugPrint("  message=${e.message}");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            "Firebase ${e.code}: ${e.message ?? 'unknown error'}",
          ),
        ),
      );
    } catch (e, st) {
      debugPrint("🔥 generic error on cohost action: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst("Exception: ", ""),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleRequestAction({
    required bool approve,
  }) async {
    if (_busy) return;

    final data = widget.data;
    final pingId = (data["pingId"] ?? "").toString().trim();
    final requestUid =
        (data["requestUid"] ?? data["senderUid"] ?? "").toString().trim();

    if (pingId.isEmpty || requestUid.isEmpty) return;

    setState(() => _busy = true);

    try {
      final changed = approve
          ? await approvePingJoinRequest(
              pingId: pingId,
              memberUid: requestUid,
            )
          : await denyPingJoinRequest(
              pingId: pingId,
              memberUid: requestUid,
            );

      if (!changed) {
        await widget.notifRef.set({
          "actionState": approve ? "approved" : "denied",
          "resolvedAt": FieldValue.serverTimestamp(),
          "read": true,
        }, SetOptions(merge: true));

        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Request already handled.")),
        );
        return;
      }

      await Future.wait([
        sendPingJoinDecisionNotification(
          recipientUid: requestUid,
          actorUid: widget.currentUid,
          pingId: pingId,
          approved: approve,
        ),
        widget.notifRef.set({
          "actionState": approve ? "approved" : "denied",
          "resolvedAt": FieldValue.serverTimestamp(),
          "read": true,
        }, SetOptions(merge: true)),
      ]);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            approve ? "Request approved." : "Request denied.",
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final msg = e.toString();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            msg.contains("ping-full-on-approve")
                ? "Ping is full. Increase the limit in Ping Settings first."
                : "Couldn't update request.",
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;

    final type = (data["type"] ?? "").toString();
    final senderUid = (data["senderUid"] ?? "").toString();
    final senderName = (data["senderName"] ?? "").toString();
    final senderPhotoUrlStored = (data["senderPhotoUrl"] ?? "").toString();
    final eventId = (data["eventId"] ?? "").toString().trim();
    final pingId = (data["pingId"] ?? "").toString();
    final pingTitle = (data["pingTitle"] ?? "").toString();
    final requestUid = (data["requestUid"] ?? senderUid).toString();
    final actionState =
        (data["actionState"] ?? "pending").toString().trim().toLowerCase();
    final read = data["read"] == true;
    final createdAt = _notificationDateFrom(data["createdAt"]);
    final relativeTime = _relativeTimeShort(createdAt);
    final viewerCity = (data["viewerCity"] ?? "").toString().trim();
    final canViewEngagement = type == "profile_view";

    final senderRef = senderUid.isNotEmpty
        ? FirebaseFirestore.instance.collection("users").doc(senderUid)
        : null;
    final canManageEventCohostInvite =
        type == "event_cohost_invite" && actionState == "pending";    

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: senderRef?.snapshots(),
      builder: (context, senderSnap) {
        final senderData = senderSnap.data?.data() ?? {};
        final liveName = (senderData["fullName"] ?? "").toString().trim();
        final livePhotoUrl = (senderData["photoUrl"] ?? "").toString().trim();
        final canVisitCommunity = type == "community_invite";

        final displayName = liveName.isNotEmpty
            ? liveName
            : (senderName.isNotEmpty ? senderName : "Someone");

        final displayPhotoUrl = livePhotoUrl.isNotEmpty
            ? livePhotoUrl
            : senderPhotoUrlStored;

        final canViewPing =
            (type == "ping_joined" ||
                type == "ping_member_left" ||
                type == "ping_invite") &&
            pingId.isNotEmpty;

        final canManageRequest = type == "ping_join_request" &&
            pingId.isNotEmpty &&
            requestUid.isNotEmpty;

        final pingButtonLabel =
            type == "ping_invite" ? "View ping" : "Manage ping";

        final pingButtonIcon = type == "ping_invite"
            ? PhosphorIcons.mapPin(PhosphorIconsStyle.fill)
            : PhosphorIcons.gearSix(PhosphorIconsStyle.fill);

        TextSpan boldNameSpan(String name) {
          return TextSpan(
            text: name,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
            ),
          );
        }    

        String displayTitle;
        InlineSpan displayBody;

        if (type == "friend_request" || type == "connection_request") {
          displayTitle = "Connection request";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " sent you a "),
              const TextSpan(
                text: "connection",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(text: " request."),
            ],
          );
        } else if (type == "friend_accept" || type == "connection_accept") {
          displayTitle = "Connection accepted";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " accepted your "),
              const TextSpan(
                text: "connection",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(text: " request."),
            ],
          );
        } else if (type == "event_cohost_invite_accepted") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite accepted";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' accepted your co-host invite for "$eventTitle".'
                    : " accepted your co-host invite.",
              ),
            ],
          );
        }  
        else if (type == "event_cohost_invite_denied") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite declined";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' declined your co-host invite for "$eventTitle".'
                    : " declined your co-host invite.",
              ),
            ],
          );
        } else if (type == "ping_joined") {
          displayTitle = "Ping update";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " joined your ping."),
            ],
          );
        } else if (type == "ping_join_request") {
          displayTitle = "Join request";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' requested to join "$pingTitle".'
                    : " requested to join your ping.",
              ),
            ],
          );
        } else if (type == "ping_request_approved") {
          displayTitle = "Join request approved";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' approved your request to join "$pingTitle".'
                    : " approved your join request.",
              ),
            ],
          );
        } else if (type == "ping_request_denied") {
          displayTitle = "Join request denied";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' denied your request to join "$pingTitle".'
                    : " denied your join request.",
              ),
            ],
          );
        } else if (type == "event_cohost_invite") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' invited you to co-host "$eventTitle".'
                    : " invited you to co-host an event.",
              ),
            ],
          );
        } else if (type == "ping_member_removed") {
          displayTitle = "Removed from ping";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' removed you from "$pingTitle".'
                    : " removed you from a ping.",
              ),
            ],
          );
        } else if (type == "ping_member_left") {
          displayTitle = "Member left";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " left your ping."),
            ],
          );
        } else if (type == "community_invite") {
          final communityName = ((data["communitySnapshot"] ?? {})["name"] ?? "")
              .toString()
              .trim();

          displayTitle = "Community invite";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: communityName.isNotEmpty
                    ? " invited you to check out $communityName."
                    : " invited you to check out a community.",
              ),
            ],
          );
        }
        else if (type == "profile_view") {
          displayTitle = "Profile view";

          final actorName = displayName != "Someone"
              ? displayName
              : (viewerCity.isNotEmpty ? "Someone from $viewerCity" : "Someone");

          displayBody = TextSpan(
            children: [
              boldNameSpan(actorName),
              const TextSpan(text: " viewed your profile."),
            ],
          );
        } else if (type == "ping_invite") {
            displayTitle = "Ping invite";
            displayBody = TextSpan(
              children: [
                boldNameSpan(displayName),
                TextSpan(
                  text: pingTitle.isNotEmpty
                      ? ' invited you to "$pingTitle".'
                      : " invited you to a ping.",
                ),
              ],
            );
          }
          else {
          final rawTitle = (data["title"] ?? "").toString();
          final rawBody = (data["body"] ?? "").toString();

          displayTitle = rawTitle.isNotEmpty ? rawTitle : "Notification";
          displayBody = TextSpan(
            text: rawBody.isNotEmpty ? rawBody : "Open to view details.",
          );
        }

        final isEventCohostInvite = type == "event_cohost_invite";
        final eventCoverImageUrl =
            (data["eventCoverImageUrl"] ?? "").toString().trim();
        final eventCoverPresetAssetPath =
            (data["eventCoverPresetAssetPath"] ?? "").toString().trim();

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openNotificationTarget(
              context,
              read: read,
              type: type,
              senderUid: senderUid,
              pingId: pingId,
              eventId: eventId,
            ),
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.80),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.black.withOpacity(.06)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  isEventCohostInvite
                      ? _EventNotificationCoverThumb(
                          imageUrl: eventCoverImageUrl,
                          presetAssetPath: eventCoverPresetAssetPath,
                        )
                      : _NotificationAvatar(
                          photoUrl: displayPhotoUrl,
                          type: type,
                        ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                displayTitle,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            if (relativeTime.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Text(
                                relativeTime,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: Colors.black.withOpacity(.42),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        RichText(
                          text: TextSpan(
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w400,
                              fontSize: 13.5,
                              color: Colors.black.withOpacity(.62),
                              height: 1.28,
                            ),
                            children: [displayBody],
                          ),
                        ),
                        if (canManageEventCohostInvite) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _handleEventCohostInviteAction(
                                            approve: true,
                                          ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.brandGreen,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: const Text(
                                    "Accept",
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
                                  onPressed: _busy
                                      ? null
                                      : () => _handleEventCohostInviteAction(
                                            approve: false,
                                          ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFB42318).withOpacity(.10),
                                    foregroundColor: const Color(0xFFB42318),
                                    elevation: 0,
                                    shadowColor: Colors.transparent,
                                    surfaceTintColor: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: const Text(
                                    "Deny",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFB42318),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (canManageRequest) ...[
                          const SizedBox(height: 12),
                          if (actionState == "pending")
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _handleRequestAction(
                                              approve: true,
                                            ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.brandGreen,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    child: _busy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Text(
                                            "Approve",
                                            style: TextStyle(
                                              fontFamily: "Nunito",
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _handleRequestAction(
                                              approve: false,
                                            ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFFB42318),
                                      side: const BorderSide(
                                        color: Color(0xFFB42318),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    child: const Text(
                                      "Deny",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: actionState == "approved"
                                    ? AppColors.brandGreen.withOpacity(.10)
                                    : const Color(0xFFB42318).withOpacity(.10),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                actionState == "approved"
                                    ? "Request approved"
                                    : "Request denied",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: actionState == "approved"
                                      ? AppColors.brandGreen
                                      : const Color(0xFFB42318),
                                ),
                              ),
                            ),
                        ],
                        if (canViewPing) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _openNotificationTarget(
                                context,
                                read: read,
                                type: type,
                                senderUid: senderUid,
                                pingId: pingId,
                                eventId: eventId,
                              ),
                              icon: PhosphorIcon(
                                pingButtonIcon,
                                size: 16,
                                color: Colors.white,
                              ),
                              label: Text(
                                pingButtonLabel,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (canViewEngagement) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _openNotificationTarget(
                                context,
                                read: read,
                                type: type,
                                senderUid: senderUid,
                                pingId: pingId,
                                eventId: eventId,
                              ),
                              icon: PhosphorIcon(
                                PhosphorIcons.chartLineUp(
                                  PhosphorIconsStyle.fill,
                                ),
                                size: 16,
                                color: Colors.white,
                              ),
                              label: const Text(
                                "View engagement",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (canVisitCommunity) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                if (!read) {
                                  await widget.notifRef.set(
                                    {"read": true},
                                    SetOptions(merge: true),
                                  );
                                }
                                // wired later
                              },
                              icon: PhosphorIcon(
                                PhosphorIcons.arrowSquareOut(
                                  PhosphorIconsStyle.fill,
                                ),
                                size: 16,
                                color: Colors.white,
                              ),
                              label: const Text(
                                "Visit community",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!read) ...[
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SkeletonSectionHeader extends StatelessWidget {
  final String title;
  const _SkeletonSectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        title,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Colors.black.withOpacity(.95),
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _NotificationAvatar extends StatelessWidget {
  final String photoUrl;
  final String type;

  const _NotificationAvatar({
    required this.photoUrl,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;
    final badge = _NotificationBadgeStyle.fromType(type);

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandGreen.withOpacity(.10),
              image: hasPhoto
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: !hasPhoto
                ? Icon(
                    PhosphorIcons.user(PhosphorIconsStyle.light),
                    color: AppColors.brandGreen,
                    size: 20,
                  )
                : null,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: badge.background,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Center(
                child: PhosphorIcon(
                  badge.icon,
                  size: 11,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventNotificationCoverThumb extends StatelessWidget {
  final String imageUrl;
  final String presetAssetPath;

  const _EventNotificationCoverThumb({
    required this.imageUrl,
    required this.presetAssetPath,
  });

  @override
  Widget build(BuildContext context) {
    final hasNetwork = imageUrl.trim().isNotEmpty;
    final hasAsset = presetAssetPath.trim().isNotEmpty;

    ImageProvider? provider;
    if (hasNetwork) {
      provider = NetworkImage(imageUrl);
    } else if (hasAsset) {
      provider = AssetImage(presetAssetPath);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.08),
          image: provider != null
              ? DecorationImage(
                  image: provider,
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: provider == null
            ? Icon(
                PhosphorIcons.calendarDots(PhosphorIconsStyle.fill),
                size: 18,
                color: Colors.black.withOpacity(.55),
              )
            : null,
      ),
    );
  }
}

class _NotificationsLoadingList extends StatefulWidget {
  const _NotificationsLoadingList();

  @override
  State<_NotificationsLoadingList> createState() =>
      _NotificationsLoadingListState();
}

class _NotificationsLoadingListState extends State<_NotificationsLoadingList>
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
        final pulse = 0.58 + (_controller.value * 0.24);

        return ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [
            const _SkeletonSectionHeader("Today"),
            const SizedBox(height: 10),
            ...List.generate(
              3,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NotificationTileSkeleton(opacity: pulse),
              ),
            ),
            const SizedBox(height: 18),
            const _SkeletonSectionHeader("This week"),
            const SizedBox(height: 10),
            ...List.generate(
              2,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NotificationTileSkeleton(opacity: pulse),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NotificationTileSkeleton extends StatelessWidget {
  final double opacity;
  const _NotificationTileSkeleton({required this.opacity});

  @override
  Widget build(BuildContext context) {
    Color bone(double base) => Colors.black.withOpacity(base * opacity);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.80),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bone(.07),
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
                      child: Container(
                        height: 13,
                        decoration: BoxDecoration(
                          color: bone(.08),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 42,
                      height: 11,
                      decoration: BoxDecoration(
                        color: bone(.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  height: 11,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: bone(.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: .72,
                  child: Container(
                    height: 11,
                    decoration: BoxDecoration(
                      color: bone(.05),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FractionallySizedBox(
                  widthFactor: .42,
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen.withOpacity(.10 * opacity),
                      borderRadius: BorderRadius.circular(16),
                    ),
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

class _NotificationSections {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> today;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> thisWeek;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> earlier;

  const _NotificationSections({
    required this.today,
    required this.thisWeek,
    required this.earlier,
  });

  factory _NotificationSections.fromDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfWeek = startOfToday.subtract(
      Duration(days: startOfToday.weekday - 1),
    );

    final today = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final thisWeek = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final earlier = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    for (final doc in docs) {
      final data = doc.data();
      final createdAt = _notificationDateFrom(data["createdAt"]);

      if (createdAt == null) {
        earlier.add(doc);
        continue;
      }

      final local = createdAt.toLocal();

      if (!local.isBefore(startOfToday)) {
        today.add(doc);
      } else if (!local.isBefore(startOfWeek)) {
        thisWeek.add(doc);
      } else {
        earlier.add(doc);
      }
    }

    return _NotificationSections(
      today: today,
      thisWeek: thisWeek,
      earlier: earlier,
    );
  }
}

DateTime? _notificationDateFrom(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

String _relativeTimeShort(DateTime? value) {
  if (value == null) return "";

  final now = DateTime.now();
  final local = value.toLocal();
  final diff = now.difference(local);

  if (diff.inSeconds < 10) return "just now";
  if (diff.inMinutes < 1) return "${diff.inSeconds}s ago";
  if (diff.inHours < 1) return "${diff.inMinutes}m ago";
  if (diff.inDays < 1) return "${diff.inHours}h ago";
  if (diff.inDays < 7) return "${diff.inDays}d ago";

  final weeks = (diff.inDays / 7).floor();
  if (weeks < 5) return "${weeks}w ago";

  final months = (diff.inDays / 30).floor();
  if (months < 12) return "${months}mo ago";

  final years = (diff.inDays / 365).floor();
  return "${years}y ago";
}

class _NotificationBadgeStyle {
  final IconData icon;
  final Color background;

  const _NotificationBadgeStyle({
    required this.icon,
    required this.background,
  });

  factory _NotificationBadgeStyle.fromType(String type) {
    switch (type) {
      case "friend_request":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userPlus(PhosphorIconsStyle.fill),
          background: const Color(0xFF2F6BFF),
        );
      case "friend_accept":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userCheck(PhosphorIconsStyle.fill),
          background: const Color(0xFF1E4ED8),
        );
      case "ping_joined":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
          background: const Color(0xFFE5484D),
        );
      case "ping_join_request":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.hourglassSimpleMedium(PhosphorIconsStyle.fill),
          background: const Color(0xFF4F46E5),
        );
      case "ping_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );  
      case "event_cohost_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.calendarPlus(PhosphorIconsStyle.fill),
          background: const Color(0xFF7C3AED),
        );  
      case "event_cohost_invite_denied":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );  
      case "event_cohost_invite_accepted":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );  
      case "ping_request_approved":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );
      case "ping_request_denied":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );
      case "ping_member_removed":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userMinus(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );
      case "ping_member_left":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.signOut(PhosphorIconsStyle.fill),
          background: const Color(0xFF6B7280),
        );  
      case "community_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.usersFour(PhosphorIconsStyle.fill),
          background: const Color(0xFF2F6BFF),
        );  
      default:
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.bell(PhosphorIconsStyle.fill),
          background: const Color(0xFF6B7280),
        );
    }
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
