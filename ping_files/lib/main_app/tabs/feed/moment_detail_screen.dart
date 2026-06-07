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
    }
  }

  Future<void> _fetchOriginalStats() async {
    setState(() => _loadingOriginal = true);
    try {
      final data = await widget.feedService.loadSingleActivity(
        widget.originalActivityId!,
      );
      if (!mounted) return;
      if (data["ok"] == true && data["activity"] != null) {
        final orig = Map<String, dynamic>.from(data["activity"]);
        setState(() {
          // Use the original's true engagement stats
          _moment["likeCount"] = orig["likeCount"];
          _moment["commentCount"] = orig["commentCount"];
          // Keep current user's like/bookmark state from the original activity
          _moment["likedByMe"] = orig["likedByMe"] == true;
          _moment["savedByMe"] = orig["savedByMe"] == true;
          _moment["myLikeReactionId"] = orig["myLikeReactionId"] ?? "";
          _moment["myBookmarkReactionId"] = orig["myBookmarkReactionId"] ?? "";
          _moment["id"] = orig["id"];
          _loadingOriginal = false;
        });
      } else {
        setState(() => _loadingOriginal = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingOriginal = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_liking) return;
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
    setState(() {});
  }

  Future<void> _toggleSave() async {
    if (_saving) return;
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
      body: SingleChildScrollView(
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
      ),
    );
  }
}
