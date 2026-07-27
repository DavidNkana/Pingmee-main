// ============================================================================
// v97u-2: Moment stats screen. Owner-only.
//
// Loads counts + last 200 likers via PingmeeFeedService.getMomentStats.
// Three toggle rows: Pin to profile, Hide like count, Hide share
// count. Toggles call setMomentFlags and update local state.
//
// Last 200 likers are rendered as a scrollable list. Tap a row to
// navigate to the user's profile (the existing onOpenUserProfile
// callback from the host tab).
// ============================================================================

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pingmee_feed_service.dart';

class MomentStatsScreen extends StatefulWidget {
  final String activityId;
  final String foreignId;
  final String authorUid;
  final Map<String, dynamic> momentData;
  final void Function(String authorUid)? onOpenProfile;

  const MomentStatsScreen({
    super.key,
    required this.activityId,
    required this.foreignId,
    required this.authorUid,
    required this.momentData,
    this.onOpenProfile,
  });

  @override
  State<MomentStatsScreen> createState() => _MomentStatsScreenState();
}

class _MomentStatsScreenState extends State<MomentStatsScreen> {
  final _feedService = PingmeeFeedService();

  MomentStatsResult? _stats;
  bool _loading = true;
  String? _error;

  bool _savingPin = false;
  bool _savingHideLike = false;
  bool _savingHideShare = false;

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
      final stats = await _feedService.getMomentStats(
        activityId: widget.activityId,
        foreignId: widget.foreignId,
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load stats.";
        _loading = false;
      });
    }
  }

  Future<void> _togglePin(bool value) async {
    setState(() => _savingPin = true);
    try {
      await _feedService.setMomentFlags(
        activityId: widget.activityId,
        foreignId: widget.foreignId,
        pinned: value,
      );
      if (!mounted) return;
      setState(() {
        _stats = MomentStatsResult(
          viewCount: _stats!.viewCount,
          likeCount: _stats!.likeCount,
          commentCount: _stats!.commentCount,
          saveCount: _stats!.saveCount,
          repostCount: _stats!.repostCount,
          pinned: value,
          hideLikeCount: _stats!.hideLikeCount,
          hideShareCount: _stats!.hideShareCount,
          pinnedAt: value ? DateTime.now().toUtc().toIso8601String() : "",
          likers: _stats!.likers,
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update pin.")),
      );
    } finally {
      if (mounted) setState(() => _savingPin = false);
    }
  }

  Future<void> _toggleHideLikeCount(bool value) async {
    setState(() => _savingHideLike = true);
    try {
      await _feedService.setMomentFlags(
        activityId: widget.activityId,
        foreignId: widget.foreignId,
        hideLikeCount: value,
      );
      if (!mounted) return;
      setState(() {
        _stats = MomentStatsResult(
          viewCount: _stats!.viewCount,
          likeCount: _stats!.likeCount,
          commentCount: _stats!.commentCount,
          saveCount: _stats!.saveCount,
          repostCount: _stats!.repostCount,
          pinned: _stats!.pinned,
          hideLikeCount: value,
          hideShareCount: _stats!.hideShareCount,
          pinnedAt: _stats!.pinnedAt,
          likers: _stats!.likers,
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update like count.")),
      );
    } finally {
      if (mounted) setState(() => _savingHideLike = false);
    }
  }

  Future<void> _toggleHideShareCount(bool value) async {
    setState(() => _savingHideShare = true);
    try {
      await _feedService.setMomentFlags(
        activityId: widget.activityId,
        foreignId: widget.foreignId,
        hideShareCount: value,
      );
      if (!mounted) return;
      setState(() {
        _stats = MomentStatsResult(
          viewCount: _stats!.viewCount,
          likeCount: _stats!.likeCount,
          commentCount: _stats!.commentCount,
          saveCount: _stats!.saveCount,
          repostCount: _stats!.repostCount,
          pinned: _stats!.pinned,
          hideLikeCount: _stats!.hideLikeCount,
          hideShareCount: value,
          pinnedAt: _stats!.pinnedAt,
          likers: _stats!.likers,
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update share count.")),
      );
    } finally {
      if (mounted) setState(() => _savingHideShare = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Moment stats",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              onPressed: _load,
              tooltip: "Reload",
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    color: Color(0xFFB42318),
                  ),
                ),
              ),
            )
          : _stats == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 60),
                    children: [
                      _MomentPreviewCard(
                        text: (widget.momentData["text"] ?? "").toString(),
                        media: widget.momentData["media"],
                      ),
                      const SizedBox(height: 18),
                      _StatsRow(stats: _stats!),
                      const SizedBox(height: 24),
                      const _SectionTitle("Controls"),
                      _ToggleTile(
                        icon: PhosphorIcons.pushPinSimple(
                            PhosphorIconsStyle.regular),
                        title: "Pin to profile",
                        subtitle:
                            "Pinned moments appear at the top of your Moments tab.",
                        value: _stats!.pinned,
                        loading: _savingPin,
                        onChanged: _togglePin,
                      ),
                      _ToggleTile(
                        icon: PhosphorIcons.heart(
                            PhosphorIconsStyle.regular),
                        title: "Hide like count",
                        subtitle:
                            "Other people won't see how many likes this has.",
                        value: _stats!.hideLikeCount,
                        loading: _savingHideLike,
                        onChanged: _toggleHideLikeCount,
                      ),
                      _ToggleTile(
                        icon: PhosphorIcons.shareNetwork(
                            PhosphorIconsStyle.regular),
                        title: "Hide share count",
                        subtitle:
                            "Other people won't see the share button on this Moment.",
                        value: _stats!.hideShareCount,
                        loading: _savingHideShare,
                        onChanged: _toggleHideShareCount,
                      ),
                      const SizedBox(height: 24),
                      const _SectionTitle("Liked by"),
                      if (_stats!.likers.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 18),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(.04),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            "No likes yet.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              color: Color(0xCC000000),
                            ),
                          ),
                        )
                      else
                        ..._stats!.likers.map(
                          (l) => _LikerTile(
                            liker: l,
                            onTap: widget.onOpenProfile == null
                                ? null
                                : () => widget.onOpenProfile!(l.uid),
                          ),
                        ),
                      if (_stats!.likers.length >= 200)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            "Showing the most recent 200.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12,
                              color: Colors.black.withOpacity(.45),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

// ====================================================================
// Sub-widgets.
// ====================================================================

class _MomentPreviewCard extends StatelessWidget {
  final String text;
  final dynamic media;
  const _MomentPreviewCard({required this.text, this.media});

  @override
  Widget build(BuildContext context) {
    final mediaList = media is List ? media as List : const [];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 15,
                fontWeight: FontWeight.w500,
                height: 1.32,
                color: Color(0xE6000000),
              ),
            ),
          if (text.isNotEmpty && mediaList.isNotEmpty)
            const SizedBox(height: 10),
          if (mediaList.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                height: 110,
                width: double.infinity,
                color: Colors.black.withOpacity(.05),
                child: const Center(
                  child: Icon(Icons.image_outlined,
                      color: Colors.black38, size: 28),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final MomentStatsResult stats;
  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: "Views",
            value: stats.viewCount,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            label: "Likes",
            value: stats.likeCount,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            label: "Comments",
            value: stats.commentCount,
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final int value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _format(value),
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A1A),
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.55),
            ),
          ),
        ],
      ),
    );
  }

  String _format(int n) {
    if (n >= 1000000) return (n / 1000000).toStringAsFixed(1) + "M";
    if (n >= 1000) return (n / 1000).toStringAsFixed(1) + "K";
    return n.toString();
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.black.withOpacity(.55),
        ),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool loading;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.loading,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(.07)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: Colors.black87),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeColor: const Color(0xFF1D9BF0),
            ),
        ],
      ),
    );
  }
}

class _LikerTile extends StatelessWidget {
  final MomentLiker liker;
  final VoidCallback? onTap;
  const _LikerTile({required this.liker, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor:
                      Colors.black.withOpacity(.06),
                  child: Text(
                    liker.displayName.isNotEmpty
                        ? liker.displayName[0].toUpperCase()
                        : liker.uid.isNotEmpty
                            ? liker.uid[0].toUpperCase()
                            : "?",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    liker.displayName.isNotEmpty
                        ? liker.displayName
                        : "@${liker.uid}",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                Icon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.regular),
                  size: 16,
                  color: Colors.black.withOpacity(.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
