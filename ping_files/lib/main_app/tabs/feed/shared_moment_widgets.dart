import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'pingmee_feed_service.dart';

/// Shared moment card, share sheet, comments sheet, repost sheet, more sheet.
/// Reused by the regular feed, the Liked Moments screen, and the Saved Moments screen
/// so the design and workflow stay identical across the three places.

// ============================================================
// SharedMomentCard — same look as the feed's _MomentCard
// ============================================================

class SharedMomentCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;
  final VoidCallback onRepost;
  final VoidCallback onMore;
  final VoidCallback onShare;
  final bool authorVerified;
  final bool originalAuthorVerified;
  final void Function(BuildContext, List<Map<String, dynamic>>, int, String)? onMediaTap;
  /// Called when the repost/quote original card is tapped — navigates to the
  /// original post's own detail screen showing true likes/comments/saves.
  final VoidCallback? onOriginalTap;
  /// Called when the moment's author avatar or display name is tapped.
  /// Receives the author's UID so the caller can navigate to their
  /// profile. May be null in previews or test contexts.
  final void Function(String authorUid)? onAuthorTap;

  const SharedMomentCard({
    super.key,
    required this.data,
    required this.onLike,
    required this.onComment,
    required this.onSave,
    required this.onRepost,
    required this.onMore,
    required this.onShare,
    required this.authorVerified,
    this.originalAuthorVerified = false,
    this.onMediaTap,
    this.onOriginalTap,
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
    const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    return "${months[local.month - 1]} ${local.day}";
  }

  @override
  Widget build(BuildContext context) {
    final authorName = _text("authorName").isNotEmpty ? _text("authorName") : "Pingmee user";
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

    List<Map<String, dynamic>> _parseMediaList(List source) {
      return source.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    }

    final media = data["media"] is List
        ? _parseMediaList(data["media"] as List)
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
    final likeCount = data["likeCount"] is num ? (data["likeCount"] as num).toInt() : 0;
    final savedByMe = data["savedByMe"] == true;
    final savedCount = data["savedCount"] is num ? (data["savedCount"] as num).toInt() : 0;
    final commentCount = data["commentCount"] is num ? (data["commentCount"] as num).toInt() : 0;
    final repostCount = data["repostCount"] is num ? (data["repostCount"] as num).toInt() : 0;
    final shareCount = data["shareCount"] is num ? (data["shareCount"] as num).toInt() : 0;

    final type = _text("type");
    final isRepost = type == "repost" || type == "quote";
    final originalAuthorName = _text("originalAuthorName");
    final originalText = _text("originalText");
    final originalAuthorPhotoUrl = _text("originalAuthorPhotoUrl");
    // Try originalMedia first, then fall back to media (GetStream may store original media here)
    final rawOriginalMedia = data["originalMedia"] is List
        ? _parseMediaList(data["originalMedia"] as List)
        : data["media"] is List
            ? _parseMediaList(data["media"] as List)
            : <Map<String, dynamic>>[];
    final originalMedia = rawOriginalMedia;
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
                child: SharedMomentAvatar(photoUrl: authorPhotoUrl),
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
                            const Icon(Icons.verified_rounded, size: 14, color: Color(0xFF1D9BF0)),
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
                  child: Icon(PhosphorIcons.dotsThree(PhosphorIconsStyle.bold), size: 22, color: Colors.black.withOpacity(.55)),
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
          ],
          if (hashtags.isNotEmpty) ...[
            const SizedBox(height: 3),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: hashtags.map((tag) {
                final label = tag.startsWith("#") ? tag : "#$tag";
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
            // Variable-height media row.
            //
            // Each item is sized to the IMAGE'S natural aspect ratio instead of
            // a fixed 230px box. Width is full card width for a single image,
            // and 88% of card width for each item when there are multiple
            // (so the user can tell there is more by the visible edge of the
            // next item).
            //
            // Tall portrait images are capped to MediaQuery height so the card
            // never exceeds one screen — the full image is still viewable by
            // tapping, which opens the existing full-screen media viewer.
            LayoutBuilder(
              builder: (context, constraints) {
                final fullWidth = constraints.maxWidth;
                final screenHeight = MediaQuery.of(context).size.height;
                final maxRowHeight = screenHeight; // never exceed 1 screen tall
                final itemWidth = visualMedia.length == 1
                    ? fullWidth
                    : fullWidth * 0.88;
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
                            maxHeight: maxRowHeight,
                            totalCount: visualMedia.length,
                            activityId: activityId,
                            onMediaTap: onMediaTap == null
                                ? null
                                : () => onMediaTap!(
                                    context, visualMedia, index, activityId),
                            onDefaultTap: () => openSharedMomentMediaViewer(
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
          // Show original content for reposts (text and/or media)
          if (isRepost && (originalText.isNotEmpty || originalMedia.isNotEmpty)) ...[
            const SizedBox(height: 12),
            // Repost indicator above original content
            if (text.isEmpty) ...[
              Row(
                children: [
                  Icon(PhosphorIcons.repeat(PhosphorIconsStyle.bold), size: 15, color: Colors.black.withOpacity(.45)),
                  const SizedBox(width: 6),
                  Text("Reposted", style: TextStyle(fontFamily: "Nunito", fontSize: 12.5, fontWeight: FontWeight.w300, color: Colors.black.withOpacity(.48))),
                ],
              ),
              const SizedBox(height: 8),
            ],
            GestureDetector(
              onTap: onOriginalTap,
              child: SharedOriginalCard(
                authorName: originalAuthorName.isNotEmpty ? originalAuthorName : "Pingmee user",
                text: originalText,
                authorPhotoUrl: originalAuthorPhotoUrl,
                authorVerified: originalAuthorVerified,
                originalMedia: originalMedia,
                activityId: activityId,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              SharedMomentAction(
                icon: likedByMe ? PhosphorIcons.heart(PhosphorIconsStyle.fill) : PhosphorIcons.heart(PhosphorIconsStyle.regular),
                label: likeCount > 0 ? "$likeCount" : "",
                active: likedByMe,
                activeColor: const Color(0xFFEF4444),
                onTap: onLike,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
                label: commentCount > 0 ? "$commentCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onComment,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.repeat(PhosphorIconsStyle.bold),
                label: repostCount > 0 ? "$repostCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onRepost,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
                label: shareCount > 0 ? "$shareCount" : "",
                activeColor: AppColors.brandGreen,
                onTap: onShare,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: savedByMe ? PhosphorIcons.bookmark(PhosphorIconsStyle.fill) : PhosphorIcons.bookmark(PhosphorIconsStyle.regular),
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

/// Invisible GestureDetector wrapper that fires [onAuthorTap] with
/// the moment author's UID when the wrapped child is tapped. The
/// child is shown as-is; the wrapper only adds the tap behaviour.
/// If either [authorUid] is empty or [onAuthorTap] is null, the
/// wrapper is a pass-through (no tap handling).
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

class SharedMomentAvatar extends StatelessWidget {
  final String photoUrl;
  const SharedMomentAvatar({super.key, required this.photoUrl});

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
            ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
            : null,
      ),
      child: !hasPhoto
          ? Icon(PhosphorIcons.user(PhosphorIconsStyle.bold), size: 18, color: Colors.black.withOpacity(.55))
          : null,
    );
  }
}

class SharedMomentAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;

  const SharedMomentAction({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor = AppColors.brandGreen,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Colors.black.withOpacity(.62);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            children: [
              PhosphorIcon(icon, size: 22, color: color),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 5),
                Text(label, style: TextStyle(fontFamily: "Nunito", fontSize: 12, fontWeight: FontWeight.w600, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SharedOriginalCard extends StatelessWidget {
  final String authorName;
  final String text;
  final String authorPhotoUrl;
  final bool authorVerified;
  final List<Map<String, dynamic>> originalMedia;
  final String activityId;

  const SharedOriginalCard({
    super.key,
    required this.authorName,
    required this.text,
    this.authorPhotoUrl = "",
    this.authorVerified = false,
    this.originalMedia = const [],
    this.activityId = "",
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = authorPhotoUrl.trim().isNotEmpty;
    final visualMedia = originalMedia.where((item) {
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return url.isNotEmpty && (type == "image" || type == "video");
    }).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Author row: avatar + name + verified badge
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(.08),
                  image: hasPhoto
                      ? DecorationImage(image: NetworkImage(authorPhotoUrl), fit: BoxFit.cover)
                      : null,
                ),
                child: !hasPhoto
                    ? Icon(PhosphorIcons.user(PhosphorIconsStyle.bold), size: 13, color: Colors.black.withOpacity(.55))
                    : null,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        authorName,
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
                        Icons.verified_rounded,
                        size: 13,
                        color: Color(0xFF1D9BF0),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.32,
                color: Colors.black.withOpacity(.70),
              ),
            ),
          ],
          // Original media carousel
          if (visualMedia.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: visualMedia.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final item = visualMedia[index];
                  final mtype = (item["type"] ?? "").toString();
                  final url = (item["url"] ?? "").toString().trim();
                  final thumbUrl = (item["thumbUrl"] ?? "").toString().trim();
                  final displayUrl = mtype == "video" && thumbUrl.isNotEmpty ? thumbUrl : url;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 120,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            displayUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.black.withOpacity(.08),
                              child: const Icon(Icons.broken_image, size: 22, color: Colors.black26),
                            ),
                          ),
                          if (mtype == "video")
                            Center(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(.45),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// Media viewer — used by both feed and liked/saved screens
// ============================================================

/// A single media tile in the horizontally-scrolling media row on a
/// Moment card. The tile's height is derived from the image's natural
/// aspect ratio, capped at the device screen height, so a tall portrait
/// image fills the available card area without distorting or being
/// cropped. Tapping opens the full-screen media viewer for the original
/// (un-cropped, full-resolution) view.
class SharedMediaItem extends StatefulWidget {
  final Map<String, dynamic> item;
  final int index;
  final double itemWidth;
  final double maxHeight;
  final int totalCount;
  final String activityId;
  final VoidCallback? onMediaTap;
  final VoidCallback onDefaultTap;

  const SharedMediaItem({
    required this.item,
    required this.index,
    required this.itemWidth,
    required this.maxHeight,
    required this.totalCount,
    required this.activityId,
    required this.onMediaTap,
    required this.onDefaultTap,
  });

  @override
  State<SharedMediaItem> createState() => _SharedMediaItemState();
}

class _SharedMediaItemState extends State<SharedMediaItem> {
  double? _aspect; // width / height of the image, once known
  ImageStreamListener? _listener;

  @override
  void dispose() {
    final stream = _imageStream();
    if (stream != null && _listener != null) {
      stream.removeListener(_listener!);
    }
    super.dispose();
  }

  String get _displayUrl {
    final mtype = (widget.item["type"] ?? "").toString();
    final url = (widget.item["url"] ?? "").toString().trim();
    final thumbUrl = (widget.item["thumbUrl"] ?? "").toString().trim();
    return mtype == "video" && thumbUrl.isNotEmpty ? thumbUrl : url;
  }

  ImageStream? _imageStream() {
    if (_displayUrl.isEmpty) return null;
    return NetworkImage(_displayUrl).resolve(const ImageConfiguration());
  }

  void _attachListener() {
    final stream = _imageStream();
    if (stream == null) return;
    _listener = ImageStreamListener((ImageInfo info, bool _) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if (w <= 0 || h <= 0) return;
      if (!mounted) return;
      setState(() => _aspect = w / h);
      // Once we have the aspect, we don't need to listen anymore.
      stream.removeListener(_listener!);
    }, onError: (Object _, StackTrace? __) {
      // Leave _aspect null — fallback to a 4:3 frame so the layout
      // still works and the errorBuilder shows the broken-image icon.
    });
    stream.addListener(_listener!);
  }

  @override
  void initState() {
    super.initState();
    _attachListener();
  }

  @override
  Widget build(BuildContext context) {
    final mtype = (widget.item["type"] ?? "").toString();
    final url = (widget.item["url"] ?? "").toString().trim();
    final heroTag = "moment_media_${widget.activityId}_${widget.index}_${url.hashCode}";

    // Decide the frame height:
    //  - landscape images: about 60% of screen height
    //  - square images:    full item width (1:1)
    //  - portrait images:  derive from aspect ratio, capped at maxHeight
    //  - unknown aspect:   fall back to 75% of screen height
    final screenH = MediaQuery.of(context).size.height;
    final fallback = screenH * 0.75;
    final aspect = _aspect;
    double itemHeight;
    if (aspect == null) {
      // Still loading or errored — fall back to a comfortable preview size.
      itemHeight = fallback;
    } else if (aspect >= 1.0) {
      // Landscape or square — natural height capped to ~60% of screen so
      // wide photos do not push the card taller than the rest of the feed.
      itemHeight = (widget.itemWidth / aspect).clamp(120.0, screenH * 0.6);
    } else {
      // Portrait — natural aspect, capped at one screen height so a very
      // tall image still fits in the card. A single tall portrait is
      // rendered as a smaller "shrinked" preview so it does not take over
      // the whole feed on its own; multi-image carousels use the full
      // natural aspect.
      final byAspect = widget.itemWidth / aspect;
      if (widget.totalCount == 1) {
        // Single tall portrait — shrinked preview (~45% of screen) keeps
        // the feed scannable.
        itemHeight = byAspect.clamp(160.0, screenH * 0.45);
      } else {
        // Multi-image carousel portrait — full natural fit, capped at the
        // row's maxHeight (one screen).
        itemHeight = byAspect.clamp(160.0, widget.maxHeight);
      }
    }

    return GestureDetector(
      onTap: widget.onMediaTap ?? widget.onDefaultTap,
      child: Hero(
        tag: heroTag,
        // The ClipRRect's rounded border is the ONLY border the user sees
        // around media — no other chrome, no letterbox, no backdrop.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: widget.itemWidth,
            height: itemHeight,
            child: Stack(
              // Pass loose (not StackFit.expand) so the image lays out at
              // its natural size within a box that already matches its
              // aspect — no letterbox, no crop, no extra edges.
              fit: StackFit.loose,
              children: [
                if (mtype == "video")
                  _InlineVideoPlayer(
                    url: widget.item["url"]?.toString() ?? "",
                    thumbUrl: _displayUrl,
                    onOpenFullscreen: widget.onMediaTap ?? widget.onDefaultTap,
                  )
                else
                  Positioned.fill(
                    child: Image.network(
                      _displayUrl,
                      // SizedBox is already sized to the image's natural
                      // aspect, so we do not need a BoxFit. Without one the
                      // image lays out at its natural size.
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: Colors.black.withOpacity(.045),
                          child: const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      },
                      errorBuilder: (_, __, ___) {
                        return Container(
                          color: Colors.black.withOpacity(.055),
                          child: Center(
                            child: Icon(
                              PhosphorIcons.imageBroken(PhosphorIconsStyle.bold),
                              size: 28,
                              color: Colors.black.withOpacity(.38),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                // The carousel counter is hidden for video tiles so it does
                // not compete with the sound toggle in the corner.
                if (mtype != "video" && widget.totalCount > 1)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.62),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        "${widget.index + 1}/${widget.totalCount}",
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
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

void openSharedMomentMediaViewer({
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
      pageBuilder: (_, __, ___) => SharedMomentMediaViewerPage(
        images: images,
        initialIndex: initialIndex,
        activityId: activityId,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class SharedMomentMediaViewerPage extends StatefulWidget {
  final List<Map<String, dynamic>> images;
  final int initialIndex;
  final String activityId;
  const SharedMomentMediaViewerPage({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.activityId,
  });

  @override
  State<SharedMomentMediaViewerPage> createState() => _SharedMomentMediaViewerPageState();
}

class _SharedMomentMediaViewerPageState extends State<SharedMomentMediaViewerPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final item = widget.images[i];
                final mtype = (item["type"] ?? "").toString();
                final url = (item["url"] ?? "").toString().trim();
                final heroTag = "moment_media_${widget.activityId}_${i}_${url.hashCode}";
                if (mtype == "video") {
                  return Hero(
                    tag: heroTag,
                    child: SharedMomentVideoItem(url: url),
                  );
                }
                return Hero(
                  tag: heroTag,
                  child: InteractiveViewer(
                    child: Center(
                      child: Image.network(url, fit: BoxFit.contain),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
              ),
            ),
            if (widget.images.length > 1)
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      "${_index + 1}/${widget.images.length}",
                      style: const TextStyle(color: Colors.white, fontFamily: "Nunito", fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SharedMomentVideoItem extends StatefulWidget {
  final String url;
  const SharedMomentVideoItem({super.key, required this.url});

  @override
  State<SharedMomentVideoItem> createState() => _SharedMomentVideoItemState();
}

class _SharedMomentVideoItemState extends State<SharedMomentVideoItem> {
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
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          _controller.value.isPlaying ? _controller.pause() : _controller.play();
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
                opacity: _controller.value.isPlaying ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), shape: BoxShape.circle),
                  child: const Icon(Icons.pause_rounded, color: Colors.white, size: 44),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// CommentsSheet — used by feed, liked, saved screens
// ============================================================

class CommentsMomentSheet extends StatefulWidget {
  final String activityId;
  final PingmeeFeedService feedService;
  const CommentsMomentSheet({super.key, required this.activityId, required this.feedService});

  @override
  State<CommentsMomentSheet> createState() => _CommentsMomentSheetState();
}

class _CommentsMomentSheetState extends State<CommentsMomentSheet> {
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
      final comments = await widget.feedService.loadMomentComments(activityId: widget.activityId);
      if (!mounted) return;
      setState(() {
        _comments = comments;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load comments.";
      });
    }
  }

  Future<void> _sendComment() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.feedService.addMomentComment(activityId: widget.activityId, text: text);
      _controller.clear();
      await _loadComments();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't add comment.")),
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.black.withOpacity(.12), borderRadius: BorderRadius.circular(999))),
                  const SizedBox(height: 14),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text("Comments", style: TextStyle(fontFamily: "Nunito", fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black87)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen)))
                        : _error != null
                            ? Center(child: Text(_error!, style: const TextStyle(fontFamily: "Nunito", fontWeight: FontWeight.w700)))
                            : _comments.isEmpty
                                ? Center(child: Text("No comments yet. Start it.", style: TextStyle(fontFamily: "Nunito", fontWeight: FontWeight.w700, color: Colors.black.withOpacity(.55))))
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                                    itemCount: _comments.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      final c = _comments[index];
                                      final name = (c["authorName"] ?? "").toString().trim();
                                      final photo = (c["authorPhotoUrl"] ?? "").toString().trim();
                                      final txt = (c["text"] ?? "").toString().trim();
                                      return Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          SharedMomentAvatar(photoUrl: photo),
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
                                                  Text(name.isNotEmpty ? name : "Pingmee user", style: const TextStyle(fontFamily: "Nunito", fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black87)),
                                                  const SizedBox(height: 2),
                                                  Text(txt, style: TextStyle(fontFamily: "Nunito", fontSize: 13.5, fontWeight: FontWeight.w500, color: Colors.black.withOpacity(.72))),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: Colors.black.withOpacity(.06))),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 4,
                            decoration: InputDecoration(
                              hintText: "Add a comment…",
                              hintStyle: TextStyle(fontFamily: "Nunito", color: Colors.black.withOpacity(.4)),
                              filled: true,
                              fillColor: const Color(0xFFF1F1F1),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _sending ? null : _sendComment,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(18)),
                            child: Center(
                              child: _sending
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                                  : Icon(PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill), color: Colors.white, size: 19),
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

// ============================================================
// RepostMomentSheet — quote or plain repost
// ============================================================

class RepostAction {
  final String quoteText;
  const RepostAction({required this.quoteText});
}

class RepostMomentSheet extends StatefulWidget {
  final Map<String, dynamic> moment;
  const RepostMomentSheet({super.key, required this.moment});

  @override
  State<RepostMomentSheet> createState() => _RepostMomentSheetState();
}

class _RepostMomentSheetState extends State<RepostMomentSheet> {
  final TextEditingController _controller = TextEditingController();
  String _text(String key) => (widget.moment[key] ?? "").toString().trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authorName = _text("authorName").isNotEmpty ? _text("authorName") : "Pingmee user";
    final text = _text("text");
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.black.withOpacity(.12), borderRadius: BorderRadius.circular(999))),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(child: Text("Repost", style: TextStyle(fontFamily: "Nunito", fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black87))),
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 20, color: Colors.black54)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controller,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: "Add a quote (optional)",
                      hintStyle: TextStyle(fontFamily: "Nunito", color: Colors.black.withOpacity(.4)),
                      filled: true,
                      fillColor: const Color(0xFFF1F1F1),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.04),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SharedMomentAvatar(photoUrl: _text("authorPhotoUrl")),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(authorName, style: const TextStyle(fontFamily: "Nunito", fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black87)),
                              const SizedBox(height: 4),
                              Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: "Nunito", fontSize: 13, fontWeight: FontWeight.w500, color: Colors.black.withOpacity(.7))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, RepostAction(quoteText: _controller.text.trim())),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                      child: const Text("Repost", style: TextStyle(fontFamily: "Nunito", fontWeight: FontWeight.w800)),
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

// ============================================================
// MomentMoreSheet — owner actions
// ============================================================

/// Three-dot action sheet used by MomentDetailScreen, LikedMomentsScreen,
/// and SavedMomentsScreen. Mirrors the look of the main feed's
/// _MomentMoreSheet: a drag handle, a single action row
/// (Delete Moment if owner, Report Moment otherwise), and a Cancel row
/// so the user can always dismiss the sheet explicitly.
class MomentMoreSheet extends StatelessWidget {
  final bool isOwner;
  const MomentMoreSheet({super.key, required this.isOwner});

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
          ),
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
                  if (isOwner)
                    _MomentMoreActionTile(
                      icon: Icons.delete_outline_rounded,
                      title: "Delete Moment",
                      danger: true,
                      onTap: () => Navigator.pop(context, "delete"),
                    )
                  else
                    _MomentMoreActionTile(
                      icon: Icons.flag_outlined,
                      title: "Report Moment",
                      danger: false,
                      onTap: () => Navigator.pop(context, "report"),
                    ),
                  const SizedBox(height: 8),
                  _MomentMoreActionTile(
                    icon: Icons.close_rounded,
                    title: "Cancel",
                    danger: false,
                    onTap: () => Navigator.pop(context),
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

class _MomentMoreActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool danger;
  final VoidCallback onTap;
  const _MomentMoreActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFEF4444) : Colors.black87;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xFFEF4444).withOpacity(.08)
                : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

// ============================================================
// ShareMomentSheet — already implemented; keep
// ============================================================

class ShareMomentSheet extends StatelessWidget {
  final Map<String, dynamic> moment;
  const ShareMomentSheet({super.key, required this.moment});

  String _text(String key) => (moment[key] ?? "").toString().trim();

  Future<void> _copyText(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _text("text")));
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Text copied!", style: TextStyle(fontFamily: "Nunito"))),
      );
    }
  }

  Future<void> _copyLink(BuildContext context) async {
    final text = _text("text");
    final excerpt = text.length > 100 ? '${text.substring(0, 100)}...' : text;
    await Clipboard.setData(ClipboardData(text: '$excerpt\n\nShared from Pingmee'));
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Copied to clipboard!", style: TextStyle(fontFamily: "Nunito"))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text("text");
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 16),
                Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.black.withOpacity(.12), borderRadius: BorderRadius.circular(999))),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      const Expanded(child: Text("Share", style: TextStyle(fontFamily: "Nunito", fontSize: 18, fontWeight: FontWeight.w800, color: Colors.black87))),
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 20, color: Colors.black54)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: AppColors.brandGreen.withOpacity(.12), borderRadius: BorderRadius.circular(12)), child: Center(child: Icon(PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill), size: 22, color: AppColors.brandGreen))),
                  title: const Text("Copy moment text", style: TextStyle(fontFamily: "Nunito", fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(text.length > 50 ? '${text.substring(0, 50)}...' : text, style: TextStyle(fontFamily: "Nunito", fontSize: 13, color: Colors.black.withOpacity(.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _copyText(context),
                ),
                ListTile(
                  leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.blue.withOpacity(.12), borderRadius: BorderRadius.circular(12)), child: const Center(child: Icon(Icons.link, size: 22, color: Colors.blue))),
                  title: const Text("Copy link", style: TextStyle(fontFamily: "Nunito", fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: const Text("Copy shareable link to clipboard", style: TextStyle(fontFamily: "Nunito", fontSize: 13, color: Colors.black45), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _copyLink(context),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted-by-default inline video player used by [SharedMediaItem] for
/// `mtype == "video"` tiles.
///
/// Behaviour:
///   * Initializes a [VideoPlayerController] from the network URL.
///   * Shows the video thumb as a poster while it initialises.
///   * Autoplays (muted) when more than 40% of the tile is on screen, and
///     pauses again when it scrolls out.
///   * Exposes a sound toggle in the bottom-right corner. Tapping it
///     unmutes / re-mutes.
///   * Tapping anywhere else on the video opens the full-screen viewer
///     (the parent passes [onOpenFullscreen] for this).
class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  final String thumbUrl;
  final VoidCallback onOpenFullscreen;

  const _InlineVideoPlayer({
    required this.url,
    required this.thumbUrl,
    required this.onOpenFullscreen,
  });

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _muted = true;
  bool _currentlyVisible = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    if (widget.url.isEmpty) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(_muted ? 0.0 : 1.0);
      setState(() {
        _controller = controller;
        _initialized = true;
      });
      if (_currentlyVisible) {
        await controller.play();
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final visible = info.visibleFraction > 0.4;
    if (visible == _currentlyVisible) return;
    _currentlyVisible = visible;
    if (_controller == null || !_initialized) return;
    if (visible) {
      _controller!.play();
    } else {
      _controller!.pause();
    }
  }

  Future<void> _toggleMute() async {
    if (_controller == null || !_initialized) return;
    setState(() => _muted = !_muted);
    await _controller!.setVolume(_muted ? 0.0 : 1.0);
    if (!_muted && _currentlyVisible) {
      await _controller!.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onOpenFullscreen,
      behavior: HitTestBehavior.opaque,
      child: VisibilityDetector(
        key: ValueKey("inline_video_${widget.url.hashCode}"),
        onVisibilityChanged: _onVisibilityChanged,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.thumbUrl.isNotEmpty)
              Image.network(
                widget.thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.black.withOpacity(.4),
                ),
              )
            else
              Container(color: Colors.black.withOpacity(.4)),
            if (_initialized && _controller != null)
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.size.width,
                  height: _controller!.value.size.height,
                  child: VideoPlayer(_controller!),
                ),
              ),
            if (!_initialized && _error == null)
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            if (_error != null)
              const Center(
                child: Icon(
                  Icons.broken_image,
                  color: Colors.white70,
                  size: 32,
                ),
              ),
            if (_initialized && _error == null)
              Positioned(
                right: 10,
                bottom: 10,
                child: GestureDetector(
                  onTap: _toggleMute,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.55),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
