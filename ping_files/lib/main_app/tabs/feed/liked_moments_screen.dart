import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'shared_moment_widgets.dart';

/// Displays moments the current user has liked.
/// Reuses the same look + workflow as the regular feed (SharedMomentCard).
class LikedMomentsScreen extends StatefulWidget {
  const LikedMomentsScreen({super.key});

  @override
  State<LikedMomentsScreen> createState() => _LikedMomentsScreenState();
}

class _LikedMomentsScreenState extends State<LikedMomentsScreen> {
  final PingmeeFeedService _feedService = PingmeeFeedService();
  final Set<String> _likingMomentIds = {};
  final Set<String> _savingMomentIds = {};

  List<Map<String, dynamic>> _moments = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() { _loading = false; _error = "Not signed in."; });
      return;
    }
    try {
      // Fetch liked + saved + all comments counts in parallel
      final likedSnap = await FirebaseFirestore.instance
          .collection("users").doc(uid).collection("liked_moments")
          .orderBy("likedAt", descending: true).get();

      final savedSnap = await FirebaseFirestore.instance
          .collection("users").doc(uid).collection("saved_moments")
          .get();
      final savedIds = savedSnap.docs.map((d) => d.id).toSet();

      if (likedSnap.docs.isEmpty) {
        setState(() { _loading = false; _moments = []; });
        return;
      }

      final momentIds = likedSnap.docs.map((d) => d.id).toList();
      final momentSnaps = await Future.wait(
        momentIds.map((id) => FirebaseFirestore.instance
            .collection("moments").doc(id).get()),
      );

      // Fetch author user data (username + photo + verified)
      final authorUids = <String>{};
      for (final ms in momentSnaps) {
        if (!ms.exists) continue;
        final authorUid = ms.data()?["authorUid"]?.toString().trim();
        if (authorUid != null && authorUid.isNotEmpty) {
          authorUids.add(authorUid);
        }
      }

      final userCache = <String, Map<String, dynamic>>{};
      await Future.forEach(authorUids, (authorUid) async {
        final userSnap = await FirebaseFirestore.instance
            .collection("users").doc(authorUid).get();
        if (userSnap.exists) {
          userCache[authorUid] = userSnap.data() ?? {};
        }
      });

      if (!mounted) return;
      setState(() {
        _moments = momentSnaps
            .where((ms) => ms.exists)
            .map((ms) {
              final d = Map<String, dynamic>.from(ms.data()!);
              d["id"] = ms.id;
              d["_id"] = ms.id;
              // Pull author info from users/{authorUid}
              final authorUid = d["authorUid"]?.toString().trim() ?? "";
              final userData = userCache[authorUid] ?? {};
              d["authorName"] = userData["username"]?.toString() ?? "Pingmee user";
              d["authorPhotoUrl"] = userData["photoUrl"]?.toString() ?? "";
              d["_authorVerified"] = userData["verification"]?["status"] == "verified";
              // User states
              d["likedByMe"] = true; // All moments here are liked
              d["savedByMe"] = savedIds.contains(ms.id);
              return d;
            })
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // --- Like (toggle: when user un-likes from this screen, the moment is removed via cloud function) ---

  Future<void> _toggleLike(Map<String, dynamic> moment, int idx) async {
    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty || _likingMomentIds.contains(activityId)) return;

    final foreignId = (moment["foreignId"] ?? "").toString().trim();
    final momentId = foreignId.startsWith("moment:")
        ? foreignId.substring(7)
        : activityId;

    _likingMomentIds.add(activityId);
    final currentlyLiked = _moments[idx]["likedByMe"] == true;
    final currentCount = _moments[idx]["likeCount"] is num
        ? (_moments[idx]["likeCount"] as num).toInt()
        : 0;

    setState(() {
      _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
      _moments[idx]["likedByMe"] = !currentlyLiked;
      _moments[idx]["likeCount"] = currentlyLiked
          ? (currentCount - 1).clamp(0, 999999)
          : currentCount + 1;
    });

    try {
      final result = await _feedService.toggleMomentLike(
        activityId: activityId,
        currentlyLiked: currentlyLiked,
        reactionId: (moment["myLikeReactionId"] ?? "").toString(),
        momentId: momentId,
      );
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["likedByMe"] = result["liked"] == true;
        _moments[idx]["myLikeReactionId"] = (result["reactionId"] ?? "").toString();
      });
      // If the user just unliked, remove it from the list
      if (result["liked"] != true) {
        setState(() => _moments.removeAt(idx));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["likedByMe"] = currentlyLiked;
        _moments[idx]["likeCount"] = currentCount;
      });
    } finally {
      _likingMomentIds.remove(activityId);
    }
  }

  // --- Save (toggle bookmark) ---

  Future<void> _toggleSave(Map<String, dynamic> moment, int idx) async {
    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty || _savingMomentIds.contains(activityId)) return;

    _savingMomentIds.add(activityId);
    final currentlySaved = _moments[idx]["savedByMe"] == true;
    final currentCount = _moments[idx]["savedCount"] is num
        ? (_moments[idx]["savedCount"] as num).toInt()
        : 0;

    setState(() {
      _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
      _moments[idx]["savedByMe"] = !currentlySaved;
      _moments[idx]["savedCount"] = currentlySaved
          ? (currentCount - 1).clamp(0, 999999)
          : currentCount + 1;
    });

    try {
      final result = await _feedService.toggleMomentBookmark(
        activityId: activityId,
        currentlySaved: currentlySaved,
        reactionId: "",
        momentId: activityId,
      );
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["savedByMe"] = result["saved"] == true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["savedByMe"] = currentlySaved;
        _moments[idx]["savedCount"] = currentCount;
      });
    } finally {
      _savingMomentIds.remove(activityId);
    }
  }

  // --- Comments (reuses the same sheet the feed uses) ---

  Future<void> _openComments(Map<String, dynamic> moment) async {
    final activityId = (moment["id"] ?? "").toString().trim();
    if (activityId.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsMomentSheet(activityId: activityId, feedService: _feedService),
    );
    // Reload the moment so the comment count and any new info refreshes
    await _refreshOne(activityId);
  }

  Future<void> _refreshOne(String momentId) async {
    final idx = _moments.indexWhere((m) => (m["id"] ?? "") == momentId);
    if (idx < 0) return;
    try {
      final ms = await FirebaseFirestore.instance
          .collection("moments").doc(momentId).get();
      if (!ms.exists || !mounted) return;
      setState(() {
        final d = Map<String, dynamic>.from(ms.data()!);
        d["id"] = ms.id;
        d["_id"] = ms.id;
        // Preserve myLikeReactionId + interaction state on refresh
        d["likedByMe"] = _moments[idx]["likedByMe"] ?? true;
        d["savedByMe"] = _moments[idx]["savedByMe"] ?? false;
        d["myLikeReactionId"] = _moments[idx]["myLikeReactionId"] ?? "";
        d["_authorVerified"] = _moments[idx]["_authorVerified"] ?? false;
        _moments[idx] = d;
      });
    } catch (_) {/* ignore */}
  }

  // --- Repost (reuses the same sheet the feed uses) ---

  Future<void> _openRepost(Map<String, dynamic> moment) async {
    final action = await showModalBottomSheet<RepostAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RepostMomentSheet(moment: moment),
    );
    if (action == null) return;
    try {
      await _feedService.createMomentRepost(originalMoment: moment, quoteText: action.quoteText);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(action.quoteText.trim().isEmpty ? "Moment reposted." : "Quote Moment posted.")),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't repost Moment.")),
      );
    }
  }

  // --- More (report / delete) ---

  Future<void> _openMore(Map<String, dynamic> moment, int idx) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? "";
    final authorUid = (moment["authorUid"] ?? "").toString().trim();
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
          content: const Text("This removes the Moment from your feed. This cannot be undone."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete")),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
      final activityId = (moment["id"] ?? "").toString().trim();
      final foreignId = (moment["foreignId"] ?? "").toString().trim();
      if (activityId.isEmpty || foreignId.isEmpty) return;
      try {
        await _feedService.deleteMoment(activityId: activityId, foreignId: foreignId);
        if (!mounted) return;
        setState(() => _moments.removeAt(idx));
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

  // --- Share (reuses the same sheet the feed uses) ---

  Future<void> _shareMoment(Map<String, dynamic> moment) async {
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ShareMomentSheet(moment: moment),
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
        title: const Text("Liked Moments", style: TextStyle(
          fontFamily: "Nunito", fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black87,
        )),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _moments.isEmpty
                  ? const _EmptyLikedState()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                        itemCount: _moments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 14),
                        itemBuilder: (ctx, idx) {
                          final m = _moments[idx];
                          return SharedMomentCard(
                            data: m,
                            authorVerified: m["_authorVerified"] == true,
                            onLike: () => _toggleLike(m, idx),
                            onComment: () => _openComments(m),
                            onSave: () => _toggleSave(m, idx),
                            onRepost: () => _openRepost(m),
                            onMore: () => _openMore(m, idx),
                            onShare: () => _shareMoment(m),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _EmptyLikedState extends StatelessWidget {
  const _EmptyLikedState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(PhosphorIcons.heart(PhosphorIconsStyle.light), size: 64, color: Colors.black.withOpacity(.18)),
          const SizedBox(height: 16),
          Text("No liked moments yet", style: TextStyle(
            fontFamily: "Nunito", fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black.withOpacity(.45),
          )),
          const SizedBox(height: 8),
          Text("Moments you like will show up here.", style: TextStyle(
            fontFamily: "Nunito", fontSize: 14, fontWeight: FontWeight.w400, color: Colors.black.withOpacity(.35),
          )),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(PhosphorIcons.warningCircle(PhosphorIconsStyle.light), size: 52, color: Colors.black.withOpacity(.25)),
          const SizedBox(height: 14),
          Text("Something went wrong", style: TextStyle(fontFamily: "Nunito", fontSize: 16, fontWeight: FontWeight.w700, color: Colors.black.withOpacity(.45))),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center, style: TextStyle(fontFamily: "Nunito", fontSize: 12, color: Colors.black.withOpacity(.55))),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text("Try again", style: TextStyle(fontFamily: "Nunito", fontSize: 14))),
        ],
      ),
    );
  }
}
