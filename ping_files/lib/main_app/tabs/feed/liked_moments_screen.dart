import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/tabs/feed/pingmee_feed_service.dart';
import 'shared_moment_widgets.dart';

/// Displays moments the current user has liked.
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
      // Fetch liked moments and saved moments in parallel
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

      // Collect unique author UIDs and fetch user data (username + verified)
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
              d["_id"] = ms.id;
              final authorUid = d["authorUid"]?.toString().trim() ?? "";
              final userData = userCache[authorUid] ?? {};
              d["authorName"] = userData["username"]?.toString() ?? "Pingmee user";
              d["authorPhotoUrl"] = userData["photoUrl"]?.toString() ?? "";
              d["_authorVerified"] = userData["verification"]?["status"] == "verified";
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

  Future<void> _toggleLike(String momentId, int idx) async {
    if (_likingMomentIds.contains(momentId)) return;
    final currentlyLiked = _moments[idx]["likedByMe"] == true;
    _likingMomentIds.add(momentId);

    setState(() {
      _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
      _moments[idx]["likedByMe"] = !currentlyLiked;
      _moments[idx]["likeCount"] = ((_moments[idx]["likeCount"] ?? 0) as num).toInt() + (currentlyLiked ? -1 : 1);
    });

    try {
      final result = await _feedService.toggleMomentLike(
        activityId: momentId,
        currentlyLiked: currentlyLiked,
        reactionId: "",
        momentId: momentId,
      );
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["likedByMe"] = result["liked"] == true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
        _moments[idx]["likedByMe"] = currentlyLiked;
      });
    } finally {
      _likingMomentIds.remove(momentId);
    }
  }

  Future<void> _toggleSave(String momentId, int idx) async {
    if (_savingMomentIds.contains(momentId)) return;
    final currentlySaved = _moments[idx]["savedByMe"] == true;
    _savingMomentIds.add(momentId);

    setState(() {
      _moments[idx] = Map<String, dynamic>.from(_moments[idx]);
      _moments[idx]["savedByMe"] = !currentlySaved;
    });

    try {
      final result = await _feedService.toggleMomentBookmark(
        activityId: momentId,
        currentlySaved: currentlySaved,
        reactionId: "",
        momentId: momentId,
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
      });
    } finally {
      _savingMomentIds.remove(momentId);
    }
  }

  Future<void> _shareMoment(Map<String, dynamic> moment) async {
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ShareMomentSheet(moment: moment),
      );
    } catch (_) {
      // Cancelled silently
    }
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
                  ? _EmptyLikedState()
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
                            onLike: () => _toggleLike(m["_id"], idx),
                            onComment: () {},
                            onSave: () => _toggleSave(m["_id"], idx),
                            onRepost: () {},
                            onMore: () {},
                            onShare: () => _shareMoment(m),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _EmptyLikedState extends StatelessWidget {
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
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text("Try again", style: TextStyle(fontFamily: "Nunito", fontSize: 14))),
        ],
      ),
    );
  }
}
