import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Shared moment card and avatar widgets for liked/saved moments screens.
/// Keeps design consistent with feed without duplicating _MomentCard from feed_tab.dart.

class SharedMomentCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;
  final VoidCallback onRepost;
  final VoidCallback onMore;
  final VoidCallback onShare;
  final bool authorVerified;

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
    final commentCount = data["commentCount"] is num ? (data["commentCount"] as num).toInt() : 0;
    final authorPhotoUrl = _text("authorPhotoUrl");
    final text = _text("text");
    final time = _prettyMomentTime(_text("time"));
    final locationLabel = _text("locationLabel");
    final city = _text("city");
    final country = _text("country");
    final media = data["media"] is List
        ? List<Map<String, dynamic>>.from((data["media"] as List).whereType<Map>().map((item) => Map<String, dynamic>.from(item)))
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
            : city.isNotEmpty ? city : country;
    final hashtags = data["hashtags"] is List
        ? List<String>.from((data["hashtags"] as List).map((e) => e.toString()))
        : <String>[];
    final likedByMe = data["likedByMe"] == true;
    final likeCount = data["likeCount"] is num ? (data["likeCount"] as num).toInt() : 0;
    final savedByMe = data["savedByMe"] == true;
    final savedCount = data["savedCount"] is num ? (data["savedCount"] as num).toInt() : 0;
    final repostCount = data["repostCount"] is num ? (data["repostCount"] as num).toInt() : 0;
    final shareCount = data["shareCount"] is num ? (data["shareCount"] as num).toInt() : 0;
    final type = _text("type");
    final isRepost = type == "repost" || type == "quote";
    final originalAuthorName = _text("originalAuthorName");
    final originalText = _text("originalText");
    final repostLabel = type == "quote" ? "quoted a Moment" : type == "repost" ? "reposted a Moment" : "Moment";

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.black.withOpacity(.055)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(.045), blurRadius: 20, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SharedMomentAvatar(photoUrl: authorPhotoUrl),
              const SizedBox(width: 11),
              Expanded(
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
                      [repostLabel, if (locationLine.isNotEmpty) locationLine, if (time.isNotEmpty) time].join(" · "),
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
            const SizedBox(height: 10),
            Text(text, style: TextStyle(fontFamily: "Nunito", fontSize: 14.5, fontWeight: FontWeight.w400, height: 1.35, color: Colors.black.withOpacity(.80))),
          ],
          if (visualMedia.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SharedMediaGrid(media: visualMedia),
          ],
          if (isRepost && originalText.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SharedOriginalCard(authorName: originalAuthorName.isNotEmpty ? originalAuthorName : "Pingmee user", text: originalText),
          ],
          if (isRepost && text.isEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(PhosphorIcons.repeat(PhosphorIconsStyle.bold), size: 15, color: Colors.black.withOpacity(.45)),
                const SizedBox(width: 6),
                Text("Reposted", style: TextStyle(fontFamily: "Nunito", fontSize: 12.5, fontWeight: FontWeight.w800, color: Colors.black.withOpacity(.48))),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _SharedAction(
                icon: likedByMe ? PhosphorIcons.heart(PhosphorIconsStyle.fill) : PhosphorIcons.heart(PhosphorIconsStyle.regular),
                label: likeCount > 0 ? "$likeCount" : "",
                active: likedByMe,
                activeColor: const Color(0xFFEF4444),
                onTap: onLike,
              ),
              const SizedBox(width: 24),
              _SharedAction(
                icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
                label: commentCount > 0 ? "$commentCount" : "",
                active: false,
                activeColor: const Color(0xFF22C55E),
                onTap: onComment,
              ),
              const SizedBox(width: 24),
              _SharedAction(
                icon: PhosphorIcons.repeat(PhosphorIconsStyle.regular),
                label: repostCount > 0 ? "$repostCount" : "",
                active: false,
                activeColor: const Color(0xFF22C55E),
                onTap: onRepost,
              ),
              const SizedBox(width: 24),
              _SharedAction(
                icon: savedByMe ? PhosphorIcons.bookmark(PhosphorIconsStyle.fill) : PhosphorIcons.bookmark(PhosphorIconsStyle.regular),
                label: savedCount > 0 ? "$savedCount" : "",
                active: savedByMe,
                activeColor: const Color(0xFF22C55E),
                onTap: onSave,
              ),
              const Spacer(),
              Icon(PhosphorIcons.shareNetwork(PhosphorIconsStyle.regular), size: 20, color: Colors.black.withOpacity(.45)),
            ],
          ),
          if (hashtags.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              hashtags.map((t) => t.startsWith("#") ? t : "#$t").join("  "),
              style: TextStyle(fontFamily: "Nunito", fontSize: 13, fontWeight: FontWeight.w500, color: Colors.black.withOpacity(.38))),
          ],
        ],
      ),
    );
  }
}

class SharedMomentAvatar extends StatelessWidget {
  final String photoUrl;
  const SharedMomentAvatar({super.key, required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.isNotEmpty;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFE5E7EB),
        image: hasPhoto
            ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
            : null,
      ),
      child: !hasPhoto
          ? Icon(PhosphorIcons.user(PhosphorIconsStyle.light), size: 22, color: Colors.black.withOpacity(.35))
          : null,
    );
  }
}

class _SharedAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _SharedAction({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Colors.black.withOpacity(.45);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontFamily: "Nunito", fontSize: 13, fontWeight: FontWeight.w600, color: color)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SharedMediaGrid extends StatelessWidget {
  final List<Map<String, dynamic>> media;
  const _SharedMediaGrid({required this.media});

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    if (media.length == 1) {
      final url = (media[0]["url"] ?? "").toString();
      final type = (media[0]["type"] ?? "").toString();
      if (url.isEmpty) return const SizedBox.shrink();
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.network(url, fit: BoxFit.cover, width: double.infinity, height: 220, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      );
    }
    final count = media.length > 4 ? 4 : media.length;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(count, (i) {
        final url = (media[i]["url"] ?? "").toString();
        if (url.isEmpty) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(url, fit: BoxFit.cover, width: 110, height: 110, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        );
      }),
    );
  }
}

class _SharedOriginalCard extends StatelessWidget {
  final String authorName;
  final String text;
  const _SharedOriginalCard({required this.authorName, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(authorName, style: const TextStyle(fontFamily: "Nunito", fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.black87)),
          const SizedBox(height: 4),
          Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: "Nunito", fontSize: 13.5, fontWeight: FontWeight.w400, color: Colors.black.withOpacity(.70))),
        ],
      ),
    );
  }
}

// Public share sheet for moments — accessible from liked/saved moments screens.
// Mirrors _ShareMomentSheet from feed_tab.dart but with working share actions.
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
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "Share",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, size: 20, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen.withOpacity(.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Icon(PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill), size: 22, color: AppColors.brandGreen),
                    ),
                  ),
                  title: const Text("Copy moment text", style: TextStyle(fontFamily: "Nunito", fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    text.length > 50 ? '${text.substring(0, 50)}...' : text,
                    style: TextStyle(fontFamily: "Nunito", fontSize: 13, color: Colors.black.withOpacity(.5)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _copyText(context),
                ),
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Icon(Icons.link, size: 22, color: Colors.blue),
                    ),
                  ),
                  title: const Text("Copy link", style: TextStyle(fontFamily: "Nunito", fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                    "Copy shareable link to clipboard",
                    style: TextStyle(fontFamily: "Nunito", fontSize: 13, color: Colors.black45),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
