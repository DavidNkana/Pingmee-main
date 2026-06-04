import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'shared_moment_widgets.dart';

/// Displays moments the current user has liked.
class LikedMomentsScreen extends StatefulWidget {
  const LikedMomentsScreen({super.key});

  @override
  State<LikedMomentsScreen> createState() => _LikedMomentsScreenState();
}

class _LikedMomentsScreenState extends State<LikedMomentsScreen> {
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
      final snap = await FirebaseFirestore.instance
          .collection("users").doc(uid).collection("liked_moments")
          .orderBy("likedAt", descending: true).get();

      if (snap.docs.isEmpty) {
        setState(() { _loading = false; _moments = []; });
        return;
      }

      final momentIds = snap.docs.map((d) => d.id).toList();
      final momentSnaps = await Future.wait(
        momentIds.map((id) => FirebaseFirestore.instance
            .collection("moments").doc(id).get()),
      );

      final verifiedCache = <String, bool>{};
      for (final ms in momentSnaps) {
        if (!ms.exists) continue;
        final authorUid = ms.data()?["authorUid"]?.toString() ?? "";
        if (authorUid.isNotEmpty && !verifiedCache.containsKey(authorUid)) {
          final userSnap = await FirebaseFirestore.instance
              .collection("users").doc(authorUid).get();
          verifiedCache[authorUid] = userSnap.data()?["verification"]?["status"] == "verified";
        }
      }

      if (!mounted) return;
      setState(() {
        _moments = momentSnaps
            .where((ms) => ms.exists)
            .map((ms) {
              final d = Map<String, dynamic>.from(ms.data()!);
              d["_id"] = ms.id;
              final authorUid = d["authorUid"]?.toString() ?? "";
              d["_authorVerified"] = verifiedCache[authorUid] ?? false;
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
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final ref = FirebaseFirestore.instance.collection("users").doc(uid).collection("liked_moments").doc(momentId);
    final doc = await ref.get();
    final wasLiked = doc.exists;
    if (wasLiked) {
      await ref.delete();
      FirebaseFirestore.instance.collection("moments").doc(momentId).update({"likeCount": FieldValue.increment(-1)});
    } else {
      await ref.set({"likedAt": FieldValue.serverTimestamp()});
      FirebaseFirestore.instance.collection("moments").doc(momentId).update({"likeCount": FieldValue.increment(1)});
    }
    if (!mounted) return;
    setState(() {
      final current = _moments[idx]["likedByMe"] == true;
      _moments[idx]["likedByMe"] = !current;
      _moments[idx]["likeCount"] = ((_moments[idx]["likeCount"] ?? 0) as num).toInt() + (current ? -1 : 1);
    });
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
                            onSave: () {},
                            onRepost: () {},
                            onMore: () {},
                            onShare: () {},
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
