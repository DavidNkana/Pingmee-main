import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'shared_moment_widgets.dart';

/// Full-screen single moment view — reuses SharedMomentCard exactly as it appears
/// in the feed, liked screen, and saved screen. Shows the moment with its own
/// true like/comment/save counts (not the quote/repost wrapper's counts).
///
/// If opened for a repost/quote's original moment, pass originalActivityId to
/// fetch and display the original's true engagement stats.
class MomentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> moment;
  final PingmeeFeedService feedService;
  final bool authorVerified;
  final bool originalAuthorVerified;
  /// When provided, the screen will fetch the original moment's true stats
  /// (likeCount, commentCount, etc.) from this GetStream activity ID.
  final String? originalActivityId;

  const MomentDetailScreen({
    super.key,
    required this.moment,
    required this.feedService,
    this.authorVerified = false,
    this.originalAuthorVerified = false,
    this.originalActivityId,
  });

  @override
  State<MomentDetailScreen> createState() => _MomentDetailScreenState();
}

class _MomentDetailScreenState extends State<MomentDetailScreen> {
  late Map<String, dynamic> _moment;
  bool _liking = false;
  bool _saving = false;
  bool _loadingOriginal = false;
  bool _originalResolved = false;
  bool _originalFetchFailed = false;
  bool _originalStatsUnavailable = false; // true when function returned ok:false

  /// True when this screen is opened for a repost/quote's original moment
  /// AND the original activity's true stats have not yet been loaded.
  /// While true, the screen MUST NOT show action buttons or render the
  /// wrapper's stats — we don't yet know if the wrapper's counts belong
  /// to the original or to the repost.
  bool get _isResolvingOriginal =>
      widget.originalActivityId != null && !_originalResolved;

  String get _activityId {
    final id = (_moment["id"] ?? "").toString().trim();
    if (id.isNotEmpty) return id;
    final fid = (_moment["foreignId"] ?? "").toString().trim();
    return fid.isNotEmpty ? fid : DateTime.now().microsecondsSinceEpoch.toString();
  }

  String _momentIdFromForeign() {
    final f = (_moment["foreignId"] ?? "").toString().trim();
    return f.startsWith("moment:") ? f.substring(7) : _activityId;
  }

  @override
  void initState() {
    super.initState();
    _moment = Map<String, dynamic>.from(widget.moment);
    if (widget.originalActivityId != null) {
      _fetchOriginalStats();
    } else {
      // No original to resolve — the moment passed in is already canonical.
      _originalResolved = true;
    }
  }

  Future<void> _fetchOriginalStats() async {
    setState(() {
      _loadingOriginal = true;
      _originalFetchFailed = false;
    });
    try {
      final data = await widget.feedService.loadSingleActivity(
        widget.originalActivityId!,
      );
      if (!mounted) return;
      // Log what we got so future debugging is trivial.
      // ignore: avoid_print
      print("[MomentDetail] loadSingleActivity response: ok=${data["ok"]} "
          "hasActivity=${data["activity"] != null} "
          "error=${data["error"] ?? "<none>"}");

      if (data["ok"] == true && data["activity"] != null) {
        final orig = Map<String, dynamic>.from(data["activity"]);
        setState(() {
          // Use the original's true engagement stats — never the repost/quote
          // wrapper's counts. The wrapper's counts include reactions on the
          // repost/quote card itself (e.g. 20 likes on the repost), which is
          // NOT what users expect to see when they open the original.
          _moment["likeCount"] = orig["likeCount"];
          _moment["commentCount"] = orig["commentCount"];
          _moment["savedCount"] = orig["savedCount"];
          // Keep current user's like/bookmark state from the original activity
          _moment["likedByMe"] = orig["likedByMe"] == true;
          _moment["savedByMe"] = orig["savedByMe"] == true;
          _moment["myLikeReactionId"] = orig["myLikeReactionId"] ?? "";
          _moment["myBookmarkReactionId"] = orig["myBookmarkReactionId"] ?? "";
          _moment["id"] = orig["id"];
          _moment["foreignId"] = orig["foreignId"] ?? _moment["foreignId"];
          _loadingOriginal = false;
          _originalResolved = true;
        });
      } else {
        // Cloud function returned a structured "not found" — not a hard error.
        // Fall back to the wrapper moment's counts (so the user at least sees
        // SOMETHING) and mark resolved. Mark the moment so we can show a
        // subtle "couldn't verify" indicator in the UI if needed.
        if (!mounted) return;
        setState(() {
          _loadingOriginal = false;
          _originalResolved = true;
          _originalStatsUnavailable = true;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print("[MomentDetail] loadSingleActivity threw: $e");
      if (!mounted) return;
      // Real network/permission error — only THEN do we show the error state.
      setState(() {
        _loadingOriginal = false;
        _originalFetchFailed = true;
      });
    }
  }

  Future<void> _toggleLike() async {
    if (_liking) return;
    if (_isResolvingOriginal) return; // don't act on the wrapper's activity
    _liking = true;

    final currentlyLiked = _moment["likedByMe"] == true;
    final reactionId = (_moment["myLikeReactionId"] ?? "").toString().trim();
    final currentCount = _moment["likeCount"] is num
        ? (_moment["likeCount"] as num).toInt()
        : 0;

    setState(() {
      _moment["likedByMe"] = !currentlyLiked;
      _moment["likeCount"] = currentlyLiked
          ? (currentCount - 1).clamp(0, 999999)
          : currentCount + 1;
    });

    try {
      final result = await widget.feedService.toggleMomentLike(
        activityId: _activityId,
        currentlyLiked: currentlyLiked,
        reactionId: reactionId,
        momentId: _momentIdFromForeign(),
      );
      if (!mounted) return;
      setState(() {
        _moment["likedByMe"] = result["liked"] == true;
        _moment["myLikeReactionId"] = (result["reactionId"] ?? "").toString();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _moment["likedByMe"] = currentlyLiked;
        _moment["likeCount"] = currentCount;
      });
    } finally {
      _liking = false;
    }
  }

  Future<void> _openComments() async {
    if (_isResolvingOriginal) return; // don't act on the wrapper's activity
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsMomentSheet(
        activityId: _activityId,
        feedService: widget.feedService,
      ),
    );
    // Refresh counts after comments change
    if (mounted) setState(() {});
  }

  Future<void> _toggleSave() async {
    if (_saving) return;
    if (_isResolvingOriginal) return; // don't act on the wrapper's activity
    _saving = true;

    final currentlySaved = _moment["savedByMe"] == true;
    final currentCount = _moment["savedCount"] is num
        ? (_moment["savedCount"] as num).toInt()
        : 0;

    setState(() {
      _moment["savedByMe"] = !currentlySaved;
      _moment["savedCount"] = currentlySaved
          ? (currentCount - 1).clamp(0, 999999)
          : currentCount + 1;
    });

    try {
      final result = await widget.feedService.toggleMomentBookmark(
        activityId: _activityId,
        currentlySaved: currentlySaved,
        reactionId: _moment["myBookmarkReactionId"] ?? "",
        momentId: _momentIdFromForeign(),
      );
      if (!mounted) return;
      setState(() {
        _moment["savedByMe"] = result["saved"] == true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _moment["savedByMe"] = currentlySaved;
        _moment["savedCount"] = currentCount;
      });
    } finally {
      _saving = false;
    }
  }

  Future<void> _openRepost() async {
    final action = await showModalBottomSheet<RepostAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RepostMomentSheet(moment: _moment),
    );
    if (action == null) return;
    try {
      await widget.feedService.createMomentRepost(
        originalMoment: _moment,
        quoteText: action.quoteText,
      );
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
        const SnackBar(content: Text("Couldn't repost Moment.")),
      );
    }
  }

  Future<void> _openMore() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? "";
    final authorUid = (_moment["authorUid"] ?? "").toString().trim();
    final isOwner = currentUid.isNotEmpty && currentUid == authorUid;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => MomentMoreSheet(isOwner: isOwner),
    );
    if (action == null || !mounted) return;

    if (action == "delete" && isOwner) {
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
      if (confirm != true || !mounted) return;
      final activityId = _activityId;
      final foreignId = (_moment["foreignId"] ?? "").toString().trim();
      if (activityId.isEmpty || foreignId.isEmpty) return;
      try {
        await widget.feedService.deleteMoment(
          activityId: activityId,
          foreignId: foreignId,
        );
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Moment deleted.")),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Couldn't delete Moment.")),
        );
      }
    } else if (action == "report") {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Report submitted. Thank you.")),
      );
    }
  }

  Future<void> _shareMoment() async {
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ShareMomentSheet(moment: _moment),
      );
    } catch (_) {/* cancelled silently */}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black87, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Moment",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        centerTitle: true,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 1) Fetch failed — never show the wrapper's wrong numbers; offer retry.
    if (_originalFetchFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PhosphorIconsRegular.cloudWarning,
                size: 56,
                color: Colors.black54,
              ),
              const SizedBox(height: 16),
              const Text(
                "Couldn't load this Moment's stats",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "We need the original Moment's like, comment and save counts before we can show this screen.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loadingOriginal
                    ? null
                    : () {
                        setState(() {
                          _originalFetchFailed = false;
                          _originalStatsUnavailable = false;
                        });
                        _fetchOriginalStats();
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  _loadingOriginal ? "Loading..." : "Try again",
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 2) Still resolving the original — show a skeleton, NOT the wrapper stats.
    if (_isResolvingOriginal) {
      return const _MomentDetailSkeleton();
    }

    // 3) Resolved (or no original to resolve) — render with the canonical stats.
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      child: SharedMomentCard(
        data: _moment,
        authorVerified: widget.authorVerified,
        originalAuthorVerified: widget.originalAuthorVerified,
        onLike: _toggleLike,
        onComment: _openComments,
        onSave: _toggleSave,
        onRepost: _openRepost,
        onMore: _openMore,
        onShare: _shareMoment,
      ),
    );
  }
}

/// Lightweight skeleton placeholder shown while we fetch the original moment's
/// real engagement stats. We deliberately do NOT render the wrapper moment's
/// counts in this state — those belong to the repost/quote, not the original.
class _MomentDetailSkeleton extends StatelessWidget {
  const _MomentDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author row
          Row(
            children: [
              const _SkeletonBox(width: 40, height: 40, radius: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _SkeletonBox(width: 140, height: 14, radius: 4),
                    SizedBox(height: 6),
                    _SkeletonBox(width: 90, height: 12, radius: 4),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Body lines
          const _SkeletonBox(width: double.infinity, height: 14, radius: 4),
          const SizedBox(height: 8),
          const _SkeletonBox(width: double.infinity, height: 14, radius: 4),
          const SizedBox(height: 8),
          const _SkeletonBox(width: 220, height: 14, radius: 4),
          const SizedBox(height: 24),
          // Action row
          Row(
            children: const [
              _SkeletonBox(width: 60, height: 24, radius: 12),
              SizedBox(width: 18),
              _SkeletonBox(width: 60, height: 24, radius: 12),
              SizedBox(width: 18),
              _SkeletonBox(width: 60, height: 24, radius: 12),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(
              const Color(0xFFE6E8EC),
              const Color(0xFFF2F3F5),
              t,
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}
