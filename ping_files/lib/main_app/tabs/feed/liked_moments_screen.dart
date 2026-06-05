import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'shared_moment_widgets.dart';

/// Displays moments the current user has liked.
/// Reuses the regular feed's data load + UI — just filters to liked ones.
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
  Map<String, bool> _verifiedCache = {};
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
      // 1) Load the user's liked moment IDs (Firestore doc IDs) from Firestore.
      // 2) Load the full timeline from GetStream via the same service the feed uses.
      // 3) Keep only moments whose firestore momentId is in the liked set.
      final likedSnap = await FirebaseFirestore.instance
          .collection("users").doc(uid).collection("liked_moments")
          .orderBy("likedAt", descending: true)
          .get();
      final likedFirestoreIds = likedSnap.docs.map((d) => d.id).toSet();

      final timeline = await _feedService.loadMyTimelineMoments();
      if (!mounted) return;

      // Derive firestore momentId from foreignId (format: "moment:{firestoreId}")
      // and keep only moments the user has liked.
      final filtered = <Map<String, dynamic>>[];
      for (final m in timeline) {
        final foreignId = (m["foreignId"] ?? "").toString().trim();
        if (!foreignId.startsWith("moment:")) continue;
        final momentId = foreignId.substring(7);
        if (likedFirestoreIds.contains(momentId)) {
          filtered.add(m);
        }
      }

      // Build verified cache from unique author uids (same pattern the feed uses).
      // Also look up original author uid for reposts (to show verified badge on repost card).
      final cache = <String, bool>{};
      final uids = <String>{};
      for (final m in filtered) {
        final a = (m["authorUid"] ?? "").toString().trim();
        if (a.isNotEmpty) uids.add(a);
        // Also cache the original author for reposts
        final o = (m["originalAuthorUid"] ?? "").toString().trim();
        if (o.isNotEmpty) uids.add(o);
      }
      for (final a in uids) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection("users").doc(a).get();
          final verification = Map<String, dynamic>.from(snap.data()?["verification"] ?? {});
          cache[a] = (verification["status"] ?? "").toString().toLowerCase() == "verified";
        } catch (_) {
          cache[a] = false;
        }
      }

      if (!mounted) return;
      setState(() {
        _moments = filtered;
        _verifiedCache = cache;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // --- Helpers (same pattern as the feed) ---

  String _activityId(Map<String, dynamic> m) => (m["id"] ?? "").toString().trim();
  String _foreignId(Map<String, dynamic> m) => (m["foreignId"] ?? "").toString().trim();
  String _momentIdFromForeign(Map<String, dynamic> m) {
    final f = _foreignId(m);
    return f.startsWith("moment:") ? f.substring(7) : _activityId(m);
  }

  // --- Like (optimistic UI; if user unlikes, remove from list) ---

  Future<void> _toggleLike(Map<String, dynamic> moment, int idx) async {
    final activityId = _activityId(moment);
    if (activityId.isEmpty || _likingMomentIds.contains(activityId)) return;
    _likingMomentIds.add(activityId);

    final currentlyLiked = moment["likedByMe"] == true;
    final reactionId = (moment["myLikeReactionId"] ?? "").toString().trim();
    final currentCount = moment["likeCount"] is num
        ? (moment["likeCount"] as num).toInt()
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
        reactionId: reactionId,
        momentId: _momentIdFromForeign(moment),
      );
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["likedByMe"] = result["liked"] == true;
        _moments[idx]["myLikeReactionId"] = (result["reactionId"] ?? "").toString();
      });
      // If user just unliked, drop it from the Liked list.
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

  // --- Save (optimistic UI; if user unsaves, remove from list) ---

  Future<void> _toggleSave(Map<String, dynamic> moment, int idx) async {
    final activityId = _activityId(moment);
    if (activityId.isEmpty || _savingMomentIds.contains(activityId)) return;
    _savingMomentIds.add(activityId);

    final currentlySaved = moment["savedByMe"] == true;
    final currentCount = moment["savedCount"] is num
        ? (moment["savedCount"] as num).toInt()
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
        momentId: _momentIdFromForeign(moment),
      );
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["savedByMe"] = result["saved"] == true;
      });
      if (result["saved"] != true) {
        setState(() => _moments.removeAt(idx));
      }
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

  // --- Comments ---

  Future<void> _openComments(Map<String, dynamic> moment) async {
    final activityId = _activityId(moment);
    if (activityId.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsMomentSheet(activityId: activityId, feedService: _feedService),
    );
    await _load();
  }

  // --- Repost ---

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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(action.quoteText.trim().isEmpty ? "Moment reposted." : "Quote Moment posted."),
      ));
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't repost Moment.")),
      );
    }
  }

  // --- More (delete if owner) ---

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
      final activityId = _activityId(moment);
      final foreignId = _foreignId(moment);
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

  // --- Share ---

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
                            authorVerified: _verifiedCache[
                                (m["authorUid"] ?? "").toString().trim()] ?? false,
                            originalAuthorVerified: _verifiedCache[
                                (m["originalAuthorUid"] ?? "").toString().trim()] ?? false,
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
