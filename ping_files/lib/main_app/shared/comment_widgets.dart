// ============================================================================
// comment_widgets.dart — shared comment primitives used by both the feed
// comments sheet and the moment detail comments sheet.
//
// Public surface:
//   * Comment  — typed model for a single comment row (the same shape Stream
//               returns from `loadMomentComments` / `loadCommentReplies`).
//   * CommentService — thin wrapper around the v50 cloud functions:
//                       - loadMomentComments (top-level)
//                       - loadCommentReplies  (parentId or rootId filter)
//                       - addMomentComment   (top-level or reply)
//                       - toggleCommentLike
//                       - toggleCommentSave
//                       - sendCommentToConnection
//   * CommentActionBar — the 4-icon row beneath every comment (Like / Reply /
//                       Send to connection / Save). Same fill as the moment
//                       card's action bar so the language is consistent.
//   * CommentAvatar   — small avatar with verified badge, reused across all
//                       comment tiles and reply tiles.
//   * MomentCommentTile — the grey-bubble comment row, used at every depth.
//   * MomentCommentRepliesScreen — Threads-style sub-page opened when a
//                       comment has >0 replies (taps the "View N replies"
//                       pill to open).
// ============================================================================

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/theme/colors2.dart';

// ============================================================================
// Comment model
// ============================================================================

class Comment {
  final String id;
  final String userId;
  final String text;
  final String authorUid;
  final String authorName;
  final String authorPhotoUrl;
  final String createdAt;

  /// Immediate parent comment id (null for top-level comments).
  final String? parentId;

  /// Top-level comment id of the thread this comment belongs to (null for
  /// top-level comments). Same as `id` for top-level rows.
  final String? rootId;

  /// The author of the parent comment (the user being replied to). Null for
  /// top-level rows.
  final String? mentionedUid;

  final int likeCount;
  final int savedCount;
  final int replyCount;
  final bool likedByMe;
  final bool savedByMe;

  /// Per-comment "send to connection" reaction id, when the current user has
  /// bookmarked/sent this comment into a chat. Mirrors the moment's
  /// myLikeReactionId field.
  String? myLikeReactionId;
  String? mySaveReactionId;

  const Comment({
    required this.id,
    required this.userId,
    required this.text,
    required this.authorUid,
    required this.authorName,
    required this.authorPhotoUrl,
    required this.createdAt,
    required this.parentId,
    required this.rootId,
    required this.mentionedUid,
    required this.likeCount,
    required this.savedCount,
    required this.replyCount,
    required this.likedByMe,
    required this.savedByMe,
    this.myLikeReactionId,
    this.mySaveReactionId,
  });

  bool get isTopLevel => parentId == null || parentId!.isEmpty;

  factory Comment.fromMap(Map<String, dynamic> map) {
    String s(String k) => (map[k] ?? "").toString().trim();
    int i(String k) {
      final v = map[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    return Comment(
      id: s("id"),
      userId: s("userId"),
      text: s("text"),
      authorUid: s("authorUid").isNotEmpty ? s("authorUid") : s("userId"),
      authorName: s("authorName").isNotEmpty ? s("authorName") : "Pingmee user",
      authorPhotoUrl: s("authorPhotoUrl"),
      createdAt: s("createdAt"),
      parentId: map["parentId"] == null
          ? null
          : (map["parentId"] as String?) ?? "",
      rootId: map["rootId"] == null
          ? null
          : (map["rootId"] as String?) ?? "",
      mentionedUid: map["mentionedUid"] == null
          ? null
          : (map["mentionedUid"] as String?) ?? "",
      likeCount: i("likeCount"),
      savedCount: i("savedCount"),
      replyCount: i("replyCount"),
      likedByMe: map["likedByMe"] == true,
      savedByMe: map["savedByMe"] == true,
      myLikeReactionId:
          (map["myLikeReactionId"] as String?)?.isNotEmpty == true
              ? map["myLikeReactionId"] as String
              : null,
      mySaveReactionId:
          (map["mySaveReactionId"] as String?)?.isNotEmpty == true
              ? map["mySaveReactionId"] as String
              : null,
    );
  }

  Comment copyWith({
    int? likeCount,
    int? savedCount,
    int? replyCount,
    bool? likedByMe,
    bool? savedByMe,
    String? myLikeReactionId,
    String? mySaveReactionId,
  }) {
    return Comment(
      id: id,
      userId: userId,
      text: text,
      authorUid: authorUid,
      authorName: authorName,
      authorPhotoUrl: authorPhotoUrl,
      createdAt: createdAt,
      parentId: parentId,
      rootId: rootId,
      mentionedUid: mentionedUid,
      likeCount: likeCount ?? this.likeCount,
      savedCount: savedCount ?? this.savedCount,
      replyCount: replyCount ?? this.replyCount,
      likedByMe: likedByMe ?? this.likedByMe,
      savedByMe: savedByMe ?? this.savedByMe,
      myLikeReactionId: myLikeReactionId ?? this.myLikeReactionId,
      mySaveReactionId: mySaveReactionId ?? this.mySaveReactionId,
    );
  }
}

// ============================================================================
// CommentService — thin cloud-functions wrapper.
// All methods throw on error; callers are expected to show a SnackBar.
// ============================================================================

class CommentService {
  CommentService({
    FirebaseFunctions? functions,
  }) : _functions = functions ??
            FirebaseFunctions.instanceFor(region: "us-central1");

  final FirebaseFunctions _functions;

  /// Load the top-level comments for a moment. Pass [parentCommentId] or
  /// [rootCommentId] to load the children of one thread (used by the
  /// Threads-style "View N replies" sub-page).
  Future<List<Comment>> loadComments({
    required String activityId,
    int limit = 30,
    String? parentCommentId,
    String? rootCommentId,
  }) async {
    debugPrint("🟢 CommentService.loadComments activityId=$activityId"
        " parentId=$parentCommentId rootId=$rootCommentId");

    try {
      final callable = _functions.httpsCallable("loadMomentComments");
      final result = await callable.call({
        "activityId": activityId,
        "limit": limit,
        if (parentCommentId != null && parentCommentId.isNotEmpty)
          "parentCommentId": parentCommentId,
        if (rootCommentId != null && rootCommentId.isNotEmpty)
          "rootCommentId": rootCommentId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final raw = data["comments"];
      final comments = raw is List
          ? raw
              .map((item) =>
                  Comment.fromMap(Map<String, dynamic>.from(item as Map)))
              .toList()
          : <Comment>[];

      debugPrint("✅ loadComments count=${comments.length}");
      return comments;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 loadComments failed code=${e.code} message=${e.message}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  /// Add a comment. Pass [parentCommentId] to write a reply — the cloud
  /// function will:
  ///   1. Look up the parent's author to set `mentionedUid`.
  ///   2. Write the reaction with `kind: "comment"` and `data.parentId`.
  ///   3. Write a notification to the parent's author (skipped for self-replies).
  Future<Comment> addComment({
    required String activityId,
    required String text,
    String? parentCommentId,
    String? rootCommentId,
  }) async {
    debugPrint("🟢 CommentService.addComment activityId=$activityId"
        " parentId=$parentCommentId rootId=$rootCommentId");

    try {
      final callable = _functions.httpsCallable("addMomentComment");
      final result = await callable.call({
        "activityId": activityId,
        "text": text,
        if (parentCommentId != null && parentCommentId.isNotEmpty)
          "parentCommentId": parentCommentId,
        if (rootCommentId != null && rootCommentId.isNotEmpty)
          "rootCommentId": rootCommentId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final c = (data["comment"] is Map)
          ? Comment.fromMap(Map<String, dynamic>.from(data["comment"] as Map))
          : Comment(
              id: "",
              userId: "",
              text: text,
              authorUid: "",
              authorName: "",
              authorPhotoUrl: "",
              createdAt: "",
              parentId: parentCommentId,
              rootId: rootCommentId ?? parentCommentId,
              mentionedUid: null,
              likeCount: 0,
              savedCount: 0,
              replyCount: 0,
              likedByMe: false,
              savedByMe: false,
            );

      debugPrint("✅ addComment id=${c.id}");
      return c;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 addComment failed code=${e.code} message=${e.message}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  /// Toggle the current user's like on a single comment. Returns
  /// `{liked, reactionId}`.
  Future<Map<String, dynamic>> toggleLike({
    required String activityId,
    required String commentId,
    required bool currentlyLiked,
    required String reactionId,
  }) async {
    debugPrint("🟢 CommentService.toggleLike commentId=$commentId"
        " currentlyLiked=$currentlyLiked");

    try {
      final callable = _functions.httpsCallable("toggleCommentLike");
      final result = await callable.call({
        "activityId": activityId,
        "commentId": commentId,
        "currentlyLiked": currentlyLiked,
        "reactionId": reactionId,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      return {
        "liked": data["liked"] == true,
        "reactionId": (data["reactionId"] ?? "").toString(),
      };
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 toggleLike failed code=${e.code} message=${e.message}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  /// Toggle the current user's save on a single comment.
  Future<Map<String, dynamic>> toggleSave({
    required String activityId,
    required String commentId,
    String? momentId,
    required bool currentlySaved,
    required String reactionId,
  }) async {
    debugPrint("🟢 CommentService.toggleSave commentId=$commentId"
        " currentlySaved=$currentlySaved");

    try {
      final callable = _functions.httpsCallable("toggleCommentSave");
      final result = await callable.call({
        "activityId": activityId,
        "commentId": commentId,
        "momentId": momentId,
        "currentlySaved": currentlySaved,
        "reactionId": reactionId,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      return {
        "saved": data["saved"] == true,
        "reactionId": (data["reactionId"] ?? "").toString(),
      };
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 toggleSave failed code=${e.code} message=${e.message}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  /// Open (or re-use) a direct chat with [otherUid] and post a pre-formatted
  /// "shared comment" message. Returns the Stream Chat `cid` so the caller
  /// can navigate to the chat with the comment preview card on top.
  Future<String> sendToConnection({
    required String otherUid,
    required String commentText,
    String? commentAuthorName,
    String? commentAuthorPhotoUrl,
    String? momentId,
    String? momentText,
    String? momentAuthorName,
    String? note,
  }) async {
    debugPrint("🟢 CommentService.sendToConnection otherUid=$otherUid"
        " commentAuthor=$commentAuthorName");

    try {
      final callable = _functions.httpsCallable("sendCommentToConnection");
      final result = await callable.call({
        "otherUid": otherUid,
        "commentText": commentText,
        "commentAuthorName": commentAuthorName,
        "commentAuthorPhotoUrl": commentAuthorPhotoUrl,
        "momentId": momentId,
        "momentText": momentText,
        "momentAuthorName": momentAuthorName,
        "note": note,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final cid = (data["cid"] ?? "").toString();
      debugPrint("✅ sendToConnection cid=$cid");
      return cid;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 sendToConnection failed code=${e.code}"
          " message=${e.message}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }
}

// ============================================================================
// CommentActionBar — the 4-icon row beneath every comment.
// 4 actions, in this order: Like / Reply / Send to connection / Save.
// No repost, no more, no share-sheet on individual comments.
// Active state for Like + Save mirrors the moment card's like/save pattern:
// filled red heart when liked, filled black bookmark when saved.
// ============================================================================

class CommentActionBar extends StatelessWidget {
  final Comment comment;

  /// Called when the user taps the heart.
  final Future<void> Function() onLike;

  /// Called when the user taps the reply bubble. The parent (sheet) decides
  /// whether to open a reply sub-composer, focus a global composer with a
  /// "Replying to @user" pill, or navigate to the thread sub-page.
  final VoidCallback onReply;

  /// Called when the user taps the paper-plane. The parent typically opens
  /// a connection picker and then calls CommentService.sendToConnection.
  final Future<void> Function() onSendToConnection;

  /// Called when the user taps the bookmark.
  final Future<void> Function() onSave;

  const CommentActionBar({
    super.key,
    required this.comment,
    required this.onLike,
    required this.onReply,
    required this.onSendToConnection,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final liked = comment.likedByMe;
    final saved = comment.savedByMe;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          // Like
          _CommentActionButton(
            icon: liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            color: liked ? const Color(0xFFEF4444) : Colors.black54,
            count: comment.likeCount > 0 ? _friendlyCount(comment.likeCount) : null,
            onTap: () => onLike(),
            semanticLabel: liked ? "Unlike comment" : "Like comment",
          ),
          const SizedBox(width: 14),
          // Reply
          _CommentActionButton(
            icon: Icons.mode_comment_outlined,
            color: Colors.black54,
            count: comment.replyCount > 0
                ? _friendlyCount(comment.replyCount)
                : null,
            onTap: onReply,
            semanticLabel: "Reply",
          ),
          const SizedBox(width: 14),
          // Send to connection
          _CommentActionButton(
            icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
            color: Colors.black54,
            onTap: () => onSendToConnection(),
            semanticLabel: "Send to a connection",
          ),
          const SizedBox(width: 14),
          // Save
          _CommentActionButton(
            icon: saved
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            color: saved ? Colors.black : Colors.black54,
            count: comment.savedCount > 0
                ? _friendlyCount(comment.savedCount)
                : null,
            onTap: () => onSave(),
            semanticLabel: saved ? "Unsave comment" : "Save comment",
          ),
        ],
      ),
    );
  }

  static String _friendlyCount(int n) {
    if (n < 1000) return "$n";
    if (n < 10000) {
      final v = (n / 1000).toStringAsFixed(1);
      return v.endsWith(".0") ? "${v.substring(0, 1)}K" : "${v}K";
    }
    if (n < 1000000) return "${(n / 1000).floor()}K";
    return "${(n / 1000000).toStringAsFixed(1)}M";
  }
}

class _CommentActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String? count;
  final VoidCallback onTap;
  final String semanticLabel;

  const _CommentActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.semanticLabel,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: color),
              if (count != null) ...[
                const SizedBox(width: 4),
                Text(
                  count!,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// CommentAvatar — small (28-px) avatar with optional verified badge, used by
// every comment tile + reply tile. Reuses the same verified-badge anchor
// as SharedMomentAvatar (Stack with clipBehavior: Clip.none).
// ============================================================================

class CommentAvatar extends StatelessWidget {
  final String photoUrl;
  final double size;
  final bool verified;

  const CommentAvatar({
    super.key,
    required this.photoUrl,
    this.size = 28,
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final url = photoUrl.trim();
    Widget avatar;
    if (url.isEmpty) {
      avatar = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFEFF1F4),
          shape: BoxShape.circle,
        ),
        child: Icon(
          PhosphorIcons.user(PhosphorIconsStyle.regular),
          size: size * 0.55,
          color: Colors.black26,
        ),
      );
    } else {
      avatar = ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: const Color(0xFFEFF1F4),
            child: Icon(
              PhosphorIcons.user(PhosphorIconsStyle.regular),
              size: size * 0.55,
              color: Colors.black26,
            ),
          ),
        ),
      );
    }

    if (!verified) return avatar;

    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: 0, top: 0, child: avatar),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: size * 0.45,
              height: size * 0.45,
              decoration: BoxDecoration(
                color: AppColors.brandGreen,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// MomentCommentTile — the grey-bubble row, used at every depth.
//
// Visual language mirrors the existing _MomentCommentTile but adds:
//   * CommentActionBar (4 actions) underneath the bubble
//   * "Replying to @name" pill for reply rows
//   * Tap-anywhere-on-bubble callback (so the parent can navigate to the
//     moment detail screen, profile, or a thread page)
// ============================================================================

class MomentCommentTile extends StatelessWidget {
  final Comment comment;

  /// true if the parent author (mentionedUid) is verified — drives the
  /// green badge on the avatar.
  final bool authorVerified;

  /// Called when the user taps the heart.
  final Future<void> Function() onLike;

  /// Called when the user taps the reply bubble.
  final VoidCallback onReply;

  /// Called when the user taps the paper-plane.
  final Future<void> Function() onSendToConnection;

  /// Called when the user taps the bookmark.
  final Future<void> Function() onSave;

  /// Called when the user taps the avatar or author name.
  final VoidCallback onAuthorTap;

  /// Called when the user taps the bubble body (typically to open a thread
  /// sub-page for a top-level comment with replies).
  final VoidCallback? onBubbleTap;

  /// Optional. If non-null, shown on reply rows as a clickable pill at the
  /// top of the bubble.
  final VoidCallback? onParentAuthorTap;

  const MomentCommentTile({
    super.key,
    required this.comment,
    required this.authorVerified,
    required this.onLike,
    required this.onReply,
    required this.onSendToConnection,
    required this.onSave,
    required this.onAuthorTap,
    this.onBubbleTap,
    this.onParentAuthorTap,
  });

  @override
  Widget build(BuildContext context) {
    final isReply = !comment.isTopLevel;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onAuthorTap,
          behavior: HitTestBehavior.opaque,
          child: CommentAvatar(
            photoUrl: comment.authorPhotoUrl,
            verified: authorVerified,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Bubble
              GestureDetector(
                onTap: onBubbleTap,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Reply context pill
                      if (isReply &&
                          comment.mentionedUid != null &&
                          comment.mentionedUid!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: GestureDetector(
                            onTap: onParentAuthorTap,
                            behavior: HitTestBehavior.opaque,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  PhosphorIcons
                                      .arrowBendUpLeft(
                                          PhosphorIconsStyle.regular),
                                  size: 11,
                                  color: Colors.black54,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  "Replying to comment",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black.withOpacity(.55),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Author name
                      GestureDetector(
                        onTap: onAuthorTap,
                        behavior: HitTestBehavior.opaque,
                        child: Text(
                          comment.authorName,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Comment text
                      Text(
                        comment.text,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: Colors.black.withOpacity(.72),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Action bar
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: CommentActionBar(
                  comment: comment,
                  onLike: onLike,
                  onReply: onReply,
                  onSendToConnection: onSendToConnection,
                  onSave: onSave,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
