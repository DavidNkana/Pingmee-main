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
import 'package:url_launcher/url_launcher.dart';

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
    // Parse defensively. GetStream usually returns ISO 8601 with a Z or
    // +HH:MM offset, but we also accept Unix timestamps (s or ms) as a
    // fallback. We always compare against the current UTC time so the
    // "X hours ago" label does not get stuck at the user local
    // timezone offset (the previous version compared a toLocal() value
    // against a local now(), which produced a constant delta on devices
    // whose local timezone differed from the cloud function UTC).
    DateTime? parsed;
    final asInt = int.tryParse(value);
    if (asInt != null && asInt > 0) {
      if (asInt >= 1000000000000) {
        parsed = DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
      } else {
        parsed = DateTime.fromMillisecondsSinceEpoch(asInt * 1000, isUtc: true);
      }
    } else {
      parsed = DateTime.tryParse(value);
    }
    if (parsed == null) return value;
    // Coerce a local-parsed string to UTC (the cloud function is the
    // source of truth and emits UTC).
    final instant = parsed.isUtc
        ? parsed
        : DateTime.utc(parsed.year, parsed.month, parsed.day,
            parsed.hour, parsed.minute, parsed.second);
    final now = DateTime.now().toUtc();
    final diff = now.difference(instant);
    if (diff.inSeconds < 60) return "now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m";
    if (diff.inHours < 24) return "${diff.inHours}h";
    if (diff.inDays < 7) return "${diff.inDays}d";
    final local = instant.toLocal();
    const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    return "${months[local.month - 1]} ${local.day}";
  }

  /// Compact a non-negative integer to a short "k" / "m" form for the
  /// action-bar labels. Below 1k the number is shown as-is. At or above
  /// 1k and below 1m we use one decimal place when the truncated value
  /// has not yet reached the next integer ("9.9k" not "10k"); at 10k and
  /// above the decimal is dropped. Same shape for the m range.
  ///
  /// Examples:
  ///   999       -> "999"
  ///   1000      -> "1k"
  ///   1500      -> "1.5k"
  ///   9999      -> "9.9k"
  ///   10000     -> "10k"
  ///   12345     -> "12k"
  ///   999999    -> "999k"
  ///   1000000   -> "1m"
  ///   1500000   -> "1.5m"
  ///   12345678  -> "12m"
  String _compactCount(int value) {
    if (value < 1000) return value.toString();
    if (value < 1000000) {
      final k = value / 1000.0;
      return k < 10
          ? "${k.toStringAsFixed(1)}k"
          : "${k.round()}k";
    }
    final m = value / 1000000.0;
    return m < 10
        ? "${m.toStringAsFixed(1)}m"
        : "${m.round()}m";
  }

  @override
  Widget build(BuildContext context) {
    final authorName = _text("authorName").isNotEmpty ? _text("authorName") : "Pingmee user";
    final authorPhotoUrl = _text("authorPhotoUrl");
    // Body text: the user own text if any, else (for plain reposts
    // where the user did not type a quote) the original moment text.
    // The body block further down styles plain-repost text in mini-card
    // style (smaller, lighter) so it is clearly the source content and
    // not text the user wrote themselves. Quote reposts get the italic
    // quote style for the same reason.
    final ownText = _text("text");
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

    // v85: stickers rendered separately (animated, not still photos)
    final stickerMedia = media.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return kind == "sticker" && url.isNotEmpty;
    }).toList();

    final visualMedia = media.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      if (kind == "sticker") return false;
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
    // Body text: ONLY the user own text. For a plain repost (no quote
    // typed) this is empty and the body block is skipped; the source
    // moment is shown only in the mini-card below. For a quote repost
    // this is the quote text the user wrote (rendered as a quote — see
    // the body block further down). We never fall back to the source's
    // text here, because that would make the body show the source's
    // content as if the user wrote it.
    final text = _text("text");
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
            // Quote repost: the user is commenting on the source, so the
            // body is rendered as a quote (italic + lighter + curly quotes)
            // to set it apart from a regular post. Plain reposts are skipped
            // entirely (text is empty for them) and show only the mini-card.
            // Regular moments keep the normal post styling.
            if (isRepost)
              _TappableRichText(
                text: '“$text”',
                baseStyle: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14.5,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  height: 1.32,
                  color: Color(0x9E000000), // black 0.62
                ),
              )
            else
              _TappableRichText(
                text: text,
                baseStyle: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.32,
                  color: Color(0xD1000000), // black 0.82
                ),
              ),
          ],
          // v78: Open Graph link preview (if the moment text
          // contained a URL, the v78 backend scraped its
          // og:* tags and stored the result as data.linkPreview).
          if (data["linkPreview"] is Map) ...[
            const SizedBox(height: 10),
            _LinkPreviewCard(
              preview:
                  Map<String, dynamic>.from(data["linkPreview"] as Map),
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
          // v85: sticker inline render (animated, BoxFit.contain)
          if (stickerMedia.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in stickerMedia)
                  _StickerInline(
                    url: (item["url"] ?? "").toString(),
                  ),
              ],
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
                // Multi-image carousels share a uniform height so the row
                // looks like a tidy grid. Single tiles keep the per-image
                // aspect logic (with the 45% shrinked preview for tall
                // portraits).
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
                            maxHeight: maxRowHeight,
                            totalCount: visualMedia.length,
                            activityId: activityId,
                            forcedHeight: forcedHeight,
                            cornerRadius: 20,
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
            // Repost indicator above original content (shown on every repost,
            // not just plain reposts, so quote reposts also signal the source)
            Row(
              children: [
                Icon(PhosphorIcons.repeat(PhosphorIconsStyle.bold), size: 15, color: Colors.black.withOpacity(.45)),
                const SizedBox(width: 6),
                Text("Reposted", style: TextStyle(fontFamily: "Nunito", fontSize: 12.5, fontWeight: FontWeight.w300, color: Colors.black.withOpacity(.48))),
              ],
            ),
            const SizedBox(height: 8),
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
                label: likeCount > 0 ? _compactCount(likeCount) : "",
                active: likedByMe,
                activeColor: const Color(0xFFEF4444),
                onTap: onLike,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
                label: commentCount > 0 ? _compactCount(commentCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onComment,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.repeat(PhosphorIconsStyle.bold),
                label: repostCount > 0 ? _compactCount(repostCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onRepost,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
                label: shareCount > 0 ? _compactCount(shareCount) : "",
                activeColor: AppColors.brandGreen,
                onTap: onShare,
              ),
              const SizedBox(width: 24),
              SharedMomentAction(
                icon: savedByMe ? PhosphorIcons.bookmark(PhosphorIconsStyle.fill) : PhosphorIcons.bookmark(PhosphorIconsStyle.regular),
                label: savedCount > 0 ? _compactCount(savedCount) : "",
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
    // v85: stickers get their own inline render path
    final stickerItems = originalMedia.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      return kind == "sticker" && url.isNotEmpty;
    }).toList();

    final visualMedia = originalMedia.where((item) {
      final kind = (item["kind"] ?? "").toString().trim();
      final type = (item["type"] ?? "").toString().trim();
      final url = (item["url"] ?? "").toString().trim();
      if (kind == "sticker") return false;
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
            _TappableRichText(
              text: text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              baseStyle: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.32,
                color: Color(0xB3000000), // black 0.70
              ),
            ),
          ],
          // v85: sticker inline render in original card
          if (stickerItems.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final item in stickerItems)
                  _StickerInline(
                    url: (item["url"] ?? "").toString(),
                  ),
              ],
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

  /// If non-null, the tile is forced to this exact height (overriding the
  /// per-image aspect-ratio logic). Used by the parent row to make every
  /// tile in a multi-image carousel share a uniform height so the row
  /// looks like a tidy grid instead of a stair-step of different shapes.
  final double? forcedHeight;

  /// Corner radius for the tile's rounded border. The default of 20 gives
  /// the standard "full moment" feel; pass a smaller value (e.g. 14) for
  /// a subtle preview look on shrinked single-image tiles.
  final double cornerRadius;

  const SharedMediaItem({
    required this.item,
    required this.index,
    required this.itemWidth,
    required this.maxHeight,
    required this.totalCount,
    required this.activityId,
    required this.onMediaTap,
    required this.onDefaultTap,
    this.forcedHeight,
    this.cornerRadius = 20,
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
    if (widget.forcedHeight != null) {
      // The parent row has decided on a uniform height for every tile in
      // a multi-image carousel. Use it exactly so the row looks tidy.
      itemHeight = widget.forcedHeight!;
    } else if (aspect == null) {
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
      // the whole feed on its own.
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

    // For multi-image carousels (forcedHeight) the parent has set a
    // uniform box height for the whole row, so we crop each tile to
    // fill the box (BoxFit.cover, StackFit.expand). For a single-image
    // tile, we keep the natural-aspect, no-letterbox behaviour.
    final bool uniformFill = widget.forcedHeight != null;

    return GestureDetector(
      onTap: widget.onMediaTap ?? widget.onDefaultTap,
      child: Hero(
        tag: heroTag,
        // The ClipRRect's rounded border is the ONLY border the user sees
        // around media — no other chrome, no letterbox, no backdrop.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.cornerRadius),
          child: SizedBox(
            width: widget.itemWidth,
            height: itemHeight,
            child: Stack(
              fit: uniformFill ? StackFit.expand : StackFit.loose,
              children: [
                if (mtype == "video")
                  _InlineVideoPlayer(
                    url: widget.item["url"]?.toString() ?? "",
                    thumbUrl: _displayUrl,
                    onOpenFullscreen: widget.onMediaTap ?? widget.onDefaultTap,
                  )
                else if (uniformFill)
                  Positioned.fill(
                    child: Image.network(
                      _displayUrl,
                      // Fill the uniform box edge-to-edge by cropping
                      // (no letterbox on a multi-image row).
                      fit: BoxFit.cover,
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

// ============================================================================
// v97b: _TappableRichText - split a moment body into plain
// text spans and tappable URL spans. URLs are detected with a
// regex, styled blue + underlined, and tap to open in the
// system browser via url_launcher. Trailing punctuation
// (.,!?:;) stays outside the tappable span so the link
// matches what the user typed.
// ============================================================================
class _TappableRichText extends StatelessWidget {
  const _TappableRichText({
    required this.text,
    required this.baseStyle,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.onMentionTap,
  });

  final String text;
  final TextStyle baseStyle;
  final int? maxLines;
  final TextOverflow overflow;
  final void Function(String mentionUid)? onMentionTap;

  // https:// or http:// followed by non-whitespace. Captures the
  // URL without the trailing punctuation; the punctuation
  // is restored as a plain text segment after the URL.
  static final RegExp _urlRe =
      RegExp(r'(https?://[^\s]+)', caseSensitive: false);

  // Characters that, if present at the end of a URL match, belong
  // to the surrounding sentence rather than the URL itself.
  static const String _trailingPunct = '.,!?:;)]"\'';

  // @-mention pattern (reused from the comment composer).
  static final RegExp _mentionRe =
      RegExp(r'@([A-Za-z0-9_]{3,32})');

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    final spans = <InlineSpan>[];

    // Walk through the text, finding URLs and @-mentions in
    // order so we render them with the right precedence.
    int cursor = 0;
    final matches = <_MatchSpan>[];
    for (final m in _urlRe.allMatches(text)) {
      matches.add(_MatchSpan(m.start, m.end, _MatchKind.url,
          m.group(0) ?? ''));
    }
    for (final m in _mentionRe.allMatches(text)) {
      matches.add(_MatchSpan(m.start, m.end, _MatchKind.mention,
          m.group(0) ?? ''));
    }
    matches.sort((a, b) => a.start.compareTo(b.start));

    for (final m in matches) {
      // Plain text before this match.
      if (m.start > cursor) {
        spans.add(TextSpan(
          text: text.substring(cursor, m.start),
          style: baseStyle,
        ));
      }
      if (m.kind == _MatchKind.url) {
        // Strip trailing punctuation back into plain text.
        var url = m.text;
        var trailing = '';
        while (url.isNotEmpty &&
            _trailingPunct.contains(url.characters.last)) {
          trailing = url.characters.last + trailing;
          url = url.substring(0, url.length - 1);
        }
        final tappableStyle = baseStyle.copyWith(
          color: AppColors.brandGreen,
          decoration: TextDecoration.underline,
        );
        if (url.isNotEmpty) {
          spans.add(TextSpan(
            text: url,
            style: tappableStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _openUrl(context, url),
          ));
        }
        if (trailing.isNotEmpty) {
          spans.add(TextSpan(
            text: trailing,
            style: baseStyle,
          ));
        }
      } else {
        // @-mention
        spans.add(TextSpan(
          text: m.text,
          style: baseStyle.copyWith(
            color: AppColors.brandGreen,
            fontWeight: FontWeight.w600,
          ),
          recognizer: onMentionTap == null
              ? null
              : (TapGestureRecognizer()
                ..onTap = () => onMentionTap!(m.text.substring(1))),
        ));
      }
      cursor = m.end;
    }
    // Trailing plain text after the last match.
    if (cursor < text.length) {
      spans.add(TextSpan(
        text: text.substring(cursor),
        style: baseStyle,
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Couldn't open link: $e")),
      );
    }
  }
}

enum _MatchKind { url, mention }

class _MatchSpan {
  const _MatchSpan(this.start, this.end, this.kind, this.text);
  final int start;
  final int end;
  final _MatchKind kind;
  final String text;
}

// ============================================================================
// v78: _LinkPreviewCard - Open Graph link preview. Used by
// SharedMomentCard to render the linkPreview field set by
// the v78 backend's createMomentV2 hook (which scrapes
// og:title / og:description / og:image / og:site_name).
// Tapping the card opens the URL in the system browser via
// url_launcher. Falls back gracefully when fields are missing.
// ============================================================================
class _LinkPreviewCard extends StatelessWidget {
  final Map<String, dynamic> preview;

  const _LinkPreviewCard({required this.preview});

  String _str(String key) {
    final v = preview[key];
    if (v == null) return "";
    return v.toString().trim();
  }

  Future<void> _onTap(BuildContext context) async {
    final url = _str("url");
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Couldn't open link: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _str("url");
    final title = _str("title");
    final description = _str("description");
    final image = _str("image");
    final siteName = _str("siteName");
    final type = _str("type");
    if (url.isEmpty && title.isEmpty && description.isEmpty) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTap(context),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.black.withOpacity(.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (image.isNotEmpty)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFF3F4F6),
                          alignment: Alignment.center,
                          child: Icon(
                            PhosphorIcons.link(PhosphorIconsStyle.regular),
                            size: 28,
                            color: Colors.black38,
                          ),
                        ),
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            color: const Color(0xFFF3F4F6),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.black54),
                              ),
                            ),
                          );
                        },
                      ),
                      // v97b: video Play overlay. The linkPreview
                      // type field comes from the backend's
                      // _scrapeLinkPreview which sets "video" for
                      // YouTube / Vimeo / Dailymotion hostnames or
                      // any page with og:video / og:type=video.*.
                      if (type == "video")
                        IgnorePointer(
                          child: Container(
                            color: Colors.black.withOpacity(.25),
                            alignment: Alignment.center,
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.6),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (siteName.isNotEmpty) ...[
                      Text(
                        siteName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: Colors.black.withOpacity(.88),
                        ),
                      ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.5,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                          color: Colors.black.withOpacity(.62),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// v85: _StickerInline - animated GIF sticker render for moment cards.
// Same shape as the one in feed_tab.dart. Kept local to this file
// because SharedMomentCard lives here and the visual parity between
// the public (SharedMomentCard) and private (_MomentCard) cards
// matters. (The same v80 lesson applies: "moment card" exists in
// two places in this codebase.)
// ============================================================================
class _StickerInline extends StatelessWidget {
  final String url;

  const _StickerInline({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 220,
          maxHeight: 220,
        ),
        color: Colors.transparent,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            width: 96,
            height: 96,
            color: Colors.black.withOpacity(.06),
            alignment: Alignment.center,
            child: Icon(
              PhosphorIcons.sticker(PhosphorIconsStyle.regular),
              size: 28,
              color: Colors.black38,
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: 96,
              height: 96,
              color: Colors.black.withOpacity(.04),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }
}
