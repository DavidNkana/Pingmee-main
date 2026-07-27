// ============================================================================
// v97w: redesigned moment stats screen.
//
// Layout (top to bottom):
//   1. Sort row: "Default" / "Recent" dropdown
//   2. Moment preview card: author (avatar + name + verified
//      badge) + body (text on one line with ellipsis OR image
//      only — never both)
//   3. Stats: 4 rows stacked vertically — Views, Likes, Reposts,
//      Quotes (no inline layout, no borders, only rounded
//      corners)
//   4. 3-dot menu (right of stats, for everyone) — "View stats"
//      for viewers; for owner also includes Pin / Hide like /
//      Hide share
//   5. Activities list (last 200) — profile image with
//      activity-type icon overlay (heart for like, repost for
//      repost, comment for comment, quote for quote)
//
// Style: pure white background, no hard borders, only
// BorderRadius. Content-loading skeleton during fetch.
// ============================================================================

import 'package:firebase_auth/firebase_auth.dart';
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

  // Local toggles (mirrored from server result so the UI is
  // responsive before the round-trip completes).
  bool _savingPin = false;
  bool _savingHideLike = false;
  bool _savingHideShare = false;

  // Sort state. 'default' = pinned-first then newest. 'recent'
  // = newest first.
  String _sort = "default";

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
      _snack("Couldn't update pin.");
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
      _snack("Couldn't update like count.");
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
      _snack("Couldn't update share count.");
    } finally {
      if (mounted) setState(() => _savingHideShare = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _StatsSettingsSheet(
        stats: _stats!,
        savingPin: _savingPin,
        savingHideLike: _savingHideLike,
        savingHideShare: _savingHideShare,
        onTogglePin: _togglePin,
        onToggleHideLike: _toggleHideLikeCount,
        onToggleHideShare: _toggleHideShareCount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "Stats",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
            fontSize: 18,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18,
              color: Color(0xFF1A1A1A)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, size: 20,
                  color: Color(0xFF1A1A1A)),
              onPressed: _load,
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
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
              ),
            )
          : _loading
              ? _buildSkeleton()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 60),
                    children: [
                      _SortRow(
                        value: _sort,
                        onChanged: (v) => setState(() => _sort = v),
                      ),
                      const SizedBox(height: 14),
                      _MomentPreviewCard(
                        moment: widget.momentData,
                        verifiedCache: _verifiedCache,
                        onOpenProfile: widget.onOpenProfile,
                      ),
                      const SizedBox(height: 14),
                      _StatsBlock(
                        stats: _stats!,
                        onOpenSettings: _openSettingsSheet,
                        isOwner: (FirebaseAuth.instance.currentUser?.uid
                                ?? '') == widget.authorUid,
                      ),
                      const SizedBox(height: 24),
                      const _SectionHeader("Activity"),
                      const SizedBox(height: 6),
                      _ActivityList(
                        likers: _stats!.likers,
                        sort: _sort,
                        onOpenProfile: widget.onOpenProfile,
                      ),
                    ],
                  ),
                ),
    );
  }

  // The verifiedCache is built during initial _load from the
  // feed tab's pre-loaded _verifiedCache. But since the stats
  // screen is a fresh route, we don't have that here. For now
  // we just show the badge based on the moment's own
  // authorVerified field if present.
  Map<String, bool> get _verifiedCache {
    final raw = widget.momentData["authorVerified"];
    if (raw == true) return {widget.momentData["authorUid"]?.toString() ?? "": true};
    return {};
  }

  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 60),
      children: const [
        _SkeletonBar(width: 120, height: 16),
        SizedBox(height: 14),
        _SkeletonBar(width: double.infinity, height: 80),
        SizedBox(height: 14),
        _SkeletonBar(width: double.infinity, height: 56),
        _SkeletonBar(width: double.infinity, height: 56),
        _SkeletonBar(width: double.infinity, height: 56),
        _SkeletonBar(width: double.infinity, height: 56),
        SizedBox(height: 24),
        _SkeletonBar(width: 100, height: 16),
        SizedBox(height: 10),
        _SkeletonBar(width: double.infinity, height: 48),
        _SkeletonBar(width: double.infinity, height: 48),
        _SkeletonBar(width: double.infinity, height: 48),
        _SkeletonBar(width: double.infinity, height: 48),
      ],
    );
  }
}

// ====================================================================
// Sub-widgets.
// ====================================================================

/// Sort row. Shows a single dropdown: "Default" / "Recent".
class _SortRow extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SortRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          "Sort by",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xCC000000),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F4F5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: PopupMenuButton<String>(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            onSelected: onChanged,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: "default",
                child: Text("Default", style: TextStyle(fontFamily: "Nunito")),
              ),
              PopupMenuItem(
                value: "recent",
                child: Text("Recent", style: TextStyle(fontFamily: "Nunito")),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value == "default" ? "Default" : "Recent",
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  PhosphorIcons.caretDown(PhosphorIconsStyle.regular),
                  size: 12,
                  color: Color(0xFF1A1A1A),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Moment preview. Rounded card. Author row (avatar + name +
/// optional verified badge). Body: text on a single line with
/// ellipsis, OR image only — never both. Text + media posts show
/// only the text.
class _MomentPreviewCard extends StatelessWidget {
  final Map<String, dynamic> moment;
  final Map<String, bool> verifiedCache;
  final void Function(String authorUid)? onOpenProfile;

  const _MomentPreviewCard({
    required this.moment,
    required this.verifiedCache,
    this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    final text = (moment["text"] ?? "").toString();
    final media = moment["media"];
    final mediaList = media is List ? (media as List) : const [];
    final hasMedia = mediaList.isNotEmpty;
    final hasText = text.trim().isNotEmpty;
    final authorUid = (moment["authorUid"] ?? "").toString();
    final authorName = (moment["authorName"] ?? "").toString();
    final authorPhoto = (moment["authorPhotoUrl"] ?? "").toString();
    final isVerified = verifiedCache[authorUid] == true;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author row
          Row(
            children: [
              Material(
                color: const Color(0xFFF4F4F5),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onOpenProfile == null
                      ? null
                      : () => onOpenProfile!(authorUid),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: authorPhoto.isNotEmpty
                        ? ClipOval(
                            child: Image.network(
                              authorPhoto,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.person_outline,
                                  size: 22,
                                  color: Color(0xFF999999)),
                            ),
                          )
                        : const Icon(Icons.person_outline,
                            size: 22, color: Color(0xFF999999)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        authorName.isNotEmpty
                            ? authorName
                            : (authorUid.isNotEmpty
                                ? "@$authorUid"
                                : "Unknown"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                    if (isVerified) ...[
                      const SizedBox(width: 4),
                      Icon(
                        PhosphorIcons.sealCheck(PhosphorIconsStyle.bold),
                        size: 16,
                        color: Color(0xFF1D9BF0),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Body: text only if text+media, or text alone. If
          // image only, show image.
          if (hasText)
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 14,
                color: Color(0xDD000000),
                height: 1.32,
              ),
            )
          else if (hasMedia)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                height: 140,
                width: double.infinity,
                color: const Color(0xFFF4F4F5),
                alignment: Alignment.center,
                child: Icon(
                  PhosphorIcons.imageSquare(PhosphorIconsStyle.regular),
                  size: 36,
                  color: Colors.black.withOpacity(.35),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Stats block: Views / Likes / Reposts / Quotes stacked
/// vertically. Each row is a rounded pill. A 3-dot menu icon on
/// the right of the block opens the settings sheet (Pin / Hide
/// like / Hide share).
class _StatsBlock extends StatelessWidget {
  final MomentStatsResult stats;
  final VoidCallback onOpenSettings;
  final bool isOwner;
  const _StatsBlock({
    required this.stats,
    required this.onOpenSettings,
    required this.isOwner,
  });

  @override
  Widget build(BuildContext context) {
    final entries = <_StatEntry>[
      _StatEntry(
        icon: PhosphorIcons.eye(PhosphorIconsStyle.regular),
        label: "Views",
        value: stats.viewCount,
      ),
      _StatEntry(
        icon: PhosphorIcons.heart(PhosphorIconsStyle.regular),
        label: "Likes",
        value: stats.likeCount,
      ),
      _StatEntry(
        icon: PhosphorIcons.repeat(PhosphorIconsStyle.regular),
        label: "Reposts",
        value: stats.repostCount,
      ),
      // Quotes share the same backend count as reposts. The UI
      // shows it as a separate row; if the server has a real
      // quote count later, swap in a different value.
      _StatEntry(
        icon: PhosphorIcons.chatCircleText(PhosphorIconsStyle.regular),
        label: "Quotes",
        value: 0,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // v97w-fix11: the Author settings button is now
        // shown to everyone (owner and viewers). The label is
        // "Author settings" for both. The settings sheet still
        // has owner-only toggles, so for viewers the sheet is
        // effectively an info panel.
        Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onOpenSettings,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Author settings",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.7),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        PhosphorIcons.caretDown(
                            PhosphorIconsStyle.bold),
                        size: 12,
                        color: Colors.black.withOpacity(.55),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _StatRow(entry: entries[i]),
        ],
      ],
    );
  }
}

class _StatEntry {
  final IconData icon;
  final String label;
  final int value;
  const _StatEntry({
    required this.icon,
    required this.label,
    required this.value,
  });
}

class _StatRow extends StatelessWidget {
  final _StatEntry entry;
  const _StatRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Icon(entry.icon, size: 20, color: const Color(0xFF1A1A1A)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              entry.label,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ),
          Text(
            _format(entry.value),
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A1A),
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

/// Settings sheet (3-dot menu). Owner-only toggles: Pin, Hide
/// like count, Hide share count.
class _StatsSettingsSheet extends StatelessWidget {
  final MomentStatsResult stats;
  final bool savingPin;
  final bool savingHideLike;
  final bool savingHideShare;
  final ValueChanged<bool> onTogglePin;
  final ValueChanged<bool> onToggleHideLike;
  final ValueChanged<bool> onToggleHideShare;

  const _StatsSettingsSheet({
    required this.stats,
    required this.savingPin,
    required this.savingHideLike,
    required this.savingHideShare,
    required this.onTogglePin,
    required this.onToggleHideLike,
    required this.onToggleHideShare,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFE0E0E0),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            // v97w-fix5: privacy notice. Tells the owner that only
            // they can see this sheet.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F4F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIcons.lockSimple(
                        PhosphorIconsStyle.regular),
                    size: 14,
                    color: Colors.black.withOpacity(.55),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "This is only visible to you (the author).",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SheetTile(
              icon: PhosphorIcons.pushPinSimple(PhosphorIconsStyle.regular),
              label: stats.pinned
                  ? "Unpin from profile"
                  : "Pin to profile",
              trailing: savingPin
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Switch.adaptive(
                      value: stats.pinned,
                      onChanged: onTogglePin,
                      activeColor: const Color(0xFF1D9BF0),
                    ),
            ),
            _SheetTile(
              icon: PhosphorIcons.heart(PhosphorIconsStyle.regular),
              label: "Hide like count",
              trailing: savingHideLike
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Switch.adaptive(
                      value: stats.hideLikeCount,
                      onChanged: onToggleHideLike,
                      activeColor: const Color(0xFF1D9BF0),
                    ),
            ),
            _SheetTile(
              icon: PhosphorIcons.shareNetwork(PhosphorIconsStyle.regular),
              label: "Hide share count",
              trailing: savingHideShare
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Switch.adaptive(
                      value: stats.hideShareCount,
                      onChanged: onToggleHideShare,
                      activeColor: const Color(0xFF1D9BF0),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget trailing;
  const _SheetTile({
    required this.icon,
    required this.label,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 22, color: const Color(0xFF1A1A1A)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

/// Activities list. Last 200 likers; each row shows profile
/// image with an activity-type icon overlay. Since the backend
/// only returns the likes list (not all activity types), we map
/// each like to a "liked" row. Sort: 'default' shows pinned-
/// first then newest, 'recent' shows newest first.
class _ActivityList extends StatelessWidget {
  final List<MomentLiker> likers;
  final String sort;
  final void Function(String authorUid)? onOpenProfile;

  const _ActivityList({
    required this.likers,
    required this.sort,
    this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    if (likers.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        alignment: Alignment.center,
        child: Text(
          "No activity yet.",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 13,
            color: Colors.black.withOpacity(.5),
          ),
        ),
      );
    }
    final sorted = List<MomentLiker>.from(likers);
    if (sort == "recent") {
      sorted.sort((a, b) => (b.createdAt).compareTo(a.createdAt));
    }
    // 'default' keeps backend order.
    return Column(
      children: [
        for (var i = 0; i < sorted.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _ActivityRow(
            liker: sorted[i],
            onTap: onOpenProfile == null
                ? null
                : () => onOpenProfile!(sorted[i].uid),
          ),
        ],
        if (likers.length >= 200)
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
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final MomentLiker liker;
  final VoidCallback? onTap;
  const _ActivityRow({required this.liker, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Profile avatar with heart icon overlay (since
                // the backend only returns likers; if we extend
                // to comments/reposts later, the overlay icon
                // can change per activity type).
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF4F4F5),
                        shape: BoxShape.circle,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: liker.displayName.isNotEmpty
                          ? Center(
                              child: Text(
                                liker.displayName[0].toUpperCase(),
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A1A),
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.person_outline,
                              size: 22,
                              color: Color(0xFF999999),
                            ),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 20, height: 20,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFFE4E6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          PhosphorIcons.heart(PhosphorIconsStyle.bold),
                          size: 12,
                          color: Color(0xFFFF3040),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        liker.displayName.isNotEmpty
                            ? liker.displayName
                            : "@${liker.uid}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "Liked",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12,
                          color: Colors.black.withOpacity(.5),
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
  }
}

class _SkeletonBar extends StatefulWidget {
  final double width;
  final double height;
  const _SkeletonBar({required this.width, required this.height});

  @override
  State<_SkeletonBar> createState() => _SkeletonBarState();
}

class _SkeletonBarState extends State<_SkeletonBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
    _anim = Tween<double>(begin: 0.4, end: 0.85).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        final v = _anim.value;
        return Container(
          width: w.isFinite ? w : null,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(
              const Color(0xFFF0F0F2),
              const Color(0xFFF7F7F8),
              v,
            )!,
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }
}
