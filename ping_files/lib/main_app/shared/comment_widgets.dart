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

import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/theme/colors2.dart';

// ============================================================================
// CommentAttachment — image or sticker attached to a comment. Matches the
// v63 backend shape so render-side can be wire-format exact.
// ============================================================================

class CommentAttachment {
  /// "image" or "sticker".
  final String kind;

  /// The public URL of the asset (Firebase Storage for images; Giphy CDN for
  /// stickers).
  final String url;

  /// Optional thumbnail. Stickers use the Giphy preview URL.
  final String? thumbUrl;

  /// Pixel dimensions when known. Null for stickers that the GIPHY picker
  /// doesn't return dimensions for.
  final int? width;
  final int? height;

  /// GIPHY's id for the sticker. Null for images.
  final String? stickerId;

  /// "giphy" for now. Null for plain images.
  final String? stickerSource;

  const CommentAttachment({
    required this.kind,
    required this.url,
    this.thumbUrl,
    this.width,
    this.height,
    this.stickerId,
    this.stickerSource,
  });

  factory CommentAttachment.fromMap(Map<String, dynamic> map) {
    int? n(String k) {
      final v = map[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    return CommentAttachment(
      kind: (map["kind"] ?? "").toString() == "sticker" ? "sticker" : "image",
      url: (map["url"] ?? "").toString(),
      thumbUrl: (map["thumbUrl"] as String?)?.isNotEmpty == true
          ? map["thumbUrl"] as String
          : null,
      width: n("width"),
      height: n("height"),
      stickerId: (map["stickerId"] as String?)?.isNotEmpty == true
          ? map["stickerId"] as String
          : null,
      stickerSource: (map["stickerSource"] as String?)?.isNotEmpty == true
          ? map["stickerSource"] as String
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        "kind": kind,
        "url": url,
        if (thumbUrl != null) "thumbUrl": thumbUrl,
        if (width != null) "width": width,
        if (height != null) "height": height,
        if (stickerId != null) "stickerId": stickerId,
        if (stickerSource != null) "stickerSource": stickerSource,
      };
}

// ============================================================================
// UserRef — lightweight user reference used by:
//   * the @-mention picker (searchConnections result)
//   * the per-sheet _mentionedUsersCache (lookupManyByUids result)
// All fields are denormalized copies of users/{uid} so the render path can
// build blue clickable TextSpans without a second read.
// ============================================================================

class UserRef {
  final String uid;
  final String fullName;
  final String username;
  final String photoUrl;

  const UserRef({
    required this.uid,
    required this.fullName,
    required this.username,
    required this.photoUrl,
  });

  /// Lowercased, no-spaces display name used as the @-tag (e.g. "John Doe"
  /// -> "johndoe"). Falls back to uid when name is empty.
  String get mentionTag {
    final s = (fullName.isNotEmpty ? fullName : username)
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9]"), "");
    return s.isNotEmpty ? s : uid;
  }

  factory UserRef.fromFirestore(
    String uid,
    Map<String, dynamic> data,
  ) {
    String s(String k) => (data[k] ?? "").toString().trim();
    final first = s("firstName");
    final last = s("lastName");
    final full = s("fullName").isNotEmpty
        ? s("fullName")
        : (first.isNotEmpty || last.isNotEmpty
            ? "$first $last".trim()
            : "");
    return UserRef(
      uid: uid,
      fullName: full.isNotEmpty ? full : "Pingmee user",
      username: s("username"),
      photoUrl: s("photoUrl").isNotEmpty
          ? s("photoUrl")
          : (s("profileImage").isNotEmpty ? s("profileImage") : ""),
    );
  }
}

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
  final String? myLikeReactionId;
  final String? mySaveReactionId;

  /// v64: UIDs the author @-mentioned in this comment. The render path
  /// builds blue clickable TextSpans for these.
  final List<String> mentions;

  /// v64: image or sticker attachments (usually 0 or 1).
  final List<CommentAttachment> attachments;

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
    this.mentions = const <String>[],
    this.attachments = const <CommentAttachment>[],
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
      mentions: (map["mentions"] is List)
          ? (map["mentions"] as List)
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList()
          : <String>[],
      attachments: (map["attachments"] is List)
          ? (map["attachments"] as List)
              .whereType<Map>()
              .map((m) => CommentAttachment.fromMap(
                    Map<String, dynamic>.from(m),
                  ))
              .toList()
          : <CommentAttachment>[],
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
    List<String>? mentions,
    List<CommentAttachment>? attachments,
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
      mentions: mentions ?? this.mentions,
      attachments: attachments ?? this.attachments,
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
  ///   4. v64: store `mentions` (UIDs) and `attachments` (images/stickers)
  ///      on the reaction data, and write a `comment_mention` notification
  ///      to every mentioned UID (skip self).
  Future<Comment> addComment({
    required String activityId,
    required String text,
    String? parentCommentId,
    String? rootCommentId,
    List<String> mentions = const <String>[],
    List<CommentAttachment> attachments = const <CommentAttachment>[],
  }) async {
    debugPrint("🟢 CommentService.addComment activityId=$activityId"
        " parentId=$parentCommentId rootId=$rootCommentId"
        " mentions=${mentions.length} attachments=${attachments.length}");

    try {
      final callable = _functions.httpsCallable("addMomentComment");
      final result = await callable.call({
        "activityId": activityId,
        "text": text,
        if (parentCommentId != null && parentCommentId.isNotEmpty)
          "parentCommentId": parentCommentId,
        if (rootCommentId != null && rootCommentId.isNotEmpty)
          "rootCommentId": rootCommentId,
        if (mentions.isNotEmpty) "mentions": mentions,
        if (attachments.isNotEmpty)
          "attachments": attachments.map((a) => a.toMap()).toList(),
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

  // ------------------------------------------------------------------
  // v64: @-mention helpers + image upload.
  // ------------------------------------------------------------------

  /// Return up to [limit] connections of [myUid] (capped at 10 by the
  /// comment composer), optionally filtered by [query] (case-insensitive
  /// substring against fullName or username). Reads
  /// `users/{myUid}.friendIds` then resolves each friend's public fields
  /// via a single `whereIn` lookup.
  Future<List<UserRef>> searchConnections(
    String myUid, {
    String? query,
    int limit = 10,
  }) async {
    final me = myUid.trim();
    if (me.isEmpty) return <UserRef>[];

    final cap = limit.clamp(1, 25);
    final q = (query ?? "").trim().toLowerCase();

    try {
      final db = FirebaseFirestore.instance;

      // 1. Read the user's friendIds. We pull all of them and filter
      // client-side so a small friends list (<= 200) resolves in one
      // whereIn batch. Cloud Functions doesn't have a "users by id" RPC
      // we can lean on; the Firestore whereIn has a 30-id cap per call,
      // so we chunk if the friend list ever gets very large.
      final myDoc = await db.collection("users").doc(me).get();
      final data = myDoc.data();
      final raw = (data?["friendIds"] is List)
          ? (data!["friendIds"] as List)
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList()
          : <String>[];
      if (raw.isEmpty) return <UserRef>[];

      // 2. Resolve each friend via chunked whereIn (30 per batch).
      final resolved = <UserRef>[];
      for (var i = 0; i < raw.length && resolved.length < cap * 3;
          i += 30) {
        final chunk = raw.sublist(i, (i + 30).clamp(0, raw.length));
        final snap = await db
            .collection("users")
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final d in snap.docs) {
          resolved.add(UserRef.fromFirestore(d.id, d.data()));
        }
      }

      // 3. Optional substring filter.
      final filtered = q.isEmpty
          ? resolved
          : resolved
              .where((u) =>
                  u.fullName.toLowerCase().contains(q) ||
                  u.username.toLowerCase().contains(q))
              .toList();

      // 4. Sort: prefix matches first, then alphabetical, then cap.
      filtered.sort((a, b) {
        final aFull = a.fullName.toLowerCase();
        final bFull = b.fullName.toLowerCase();
        final aUser = a.username.toLowerCase();
        final bUser = b.username.toLowerCase();
        final aPrefix = aFull.startsWith(q) || aUser.startsWith(q);
        final bPrefix = bFull.startsWith(q) || bUser.startsWith(q);
        if (aPrefix != bPrefix) return aPrefix ? -1 : 1;
        return aFull.compareTo(bFull);
      });

      return filtered.take(cap).toList();
    } on FirebaseException catch (e) {
      debugPrint("🔥 searchConnections failed: ${e.message}");
      return <UserRef>[];
    } catch (e, st) {
      debugPrint("🔥 searchConnections unexpected: $e");
      debugPrintStack(stackTrace: st);
      return <UserRef>[];
    }
  }

  /// Resolve a batch of UIDs to UserRef in one Firestore whereIn call.
  /// Used by the per-sheet `_mentionedUsersCache` warmup.
  Future<Map<String, UserRef>> lookupManyByUids(
    List<String> uids,
  ) async {
    final cleaned = uids
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (cleaned.isEmpty) return <String, UserRef>{};

    try {
      final db = FirebaseFirestore.instance;
      final out = <String, UserRef>{};
      for (var i = 0; i < cleaned.length; i += 30) {
        final chunk = cleaned.sublist(
          i,
          (i + 30).clamp(0, cleaned.length),
        );
        final snap = await db
            .collection("users")
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final d in snap.docs) {
          out[d.id] = UserRef.fromFirestore(d.id, d.data());
        }
      }
      return out;
    } on FirebaseException catch (e) {
      debugPrint("🔥 lookupManyByUids failed: ${e.message}");
      return <String, UserRef>{};
    }
  }

  /// Upload a single image to Firebase Storage via the v63
  /// `uploadCommentImage` cloud function. Returns the public URL on
  /// success. Throws on error.
  Future<String> uploadCommentImage({
    required String activityId,
    required String commentIdLocal,
    required Uint8List bytes,
    String contentType = "image/jpeg",
  }) async {
    final cleanActivityId = activityId.trim();
    final cleanLocal = commentIdLocal.trim().isEmpty
        ? "local-${DateTime.now().millisecondsSinceEpoch}"
        : commentIdLocal.trim();
    if (cleanActivityId.isEmpty) {
      throw StateError("activityId is required");
    }
    if (bytes.isEmpty) {
      throw StateError("image bytes are empty");
    }

    final b64 = base64Encode(bytes);
    final callable = _functions.httpsCallable("uploadCommentImage");
    final result = await callable.call({
      "activityId": cleanActivityId,
      "commentIdLocal": cleanLocal,
      "contentType": contentType,
      "base64": b64,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    final url = (data["url"] ?? "").toString();
    if (url.isEmpty) {
      throw StateError("uploadCommentImage returned an empty url");
    }
    return url;
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
          // Reply (rounded chat-circle, matches the moment card's comment icon)
          _CommentActionButton(
            icon: PhosphorIcons.chatCircle(PhosphorIconsStyle.regular),
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
          // Save (active state is green, matches brand)
          _CommentActionButton(
            icon: saved
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            color: saved ? AppColors.brandGreen : Colors.black54,
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
                    fontWeight: FontWeight.w500,
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
    this.size = 32,
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
                color: Color(0xFF1D9BF0),
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

  /// Optional. Tapping the 3-dot menu in the top-right of the bubble.
  /// The parent (sheet) typically shows a Report action.
  final VoidCallback? onMore;

  /// v66: per-sheet cache of UserRef by uid. The renderer uses this to
  /// resolve a clicked @-mention to the mentioned user's uid so the
  /// parent can navigate to their profile.
  final Map<String, UserRef> mentionedUsersCache;

  /// v66: called when the user taps a blue @-mention span in the comment
  /// body. The parent (sheet) typically forwards to onAuthorTap so the
  /// profile navigation is identical for avatars and mentions.
  final ValueChanged<String> onMentionTap;

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
    this.onMore,
    this.mentionedUsersCache = const <String, UserRef>{},
    this.onMentionTap = _noopMentionTap,
  });

  static void _noopMentionTap(String uid) {}

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Author name + optional inline blue tick
                      // (X-blue, same as the verified badge in the feed)
                      GestureDetector(
                        onTap: onAuthorTap,
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                comment.authorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
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
                      const SizedBox(height: 2),
                      // v66: comment body — text (with @-mentions as
                      // blue clickable spans) PLUS any image/sticker
                      // attachments stacked below.
                      _CommentBody(
                        comment: comment,
                        mentionedUsersCache: mentionedUsersCache,
                        onMentionTap: onMentionTap,
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
        if (onMore != null)
          // 3-dot sits OUTSIDE the grey bubble, on the far right of the
          // row, top-aligned with the author name.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: IconButton(
              icon: const Icon(Icons.more_horiz_rounded, size: 18),
              onPressed: onMore,
              color: Colors.black.withOpacity(.55),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
              tooltip: "More",
            ),
          ),
      ],
    );
  }
}


// ============================================================================
// v66: _CommentBody — renders a comment's text PLUS any attachments.
//
// Text:
//   * Walks the text for @-mention patterns and wraps them in TextSpans.
//   * Mention spans are X-blue (Color(0xFF1D9BF0)) + clickable. The
//     click handler resolves the lowercased no-spaces tag back to a
//     uid by reverse-looking-up [mentionedUsersCache] (whose keys are
//     uids and whose values carry the fullName used to compute the
//     mentionTag). When the cache has the user, the span's recognizer
//     fires [onMentionTap] with the resolved uid.
//   * The remaining text is rendered with the existing font / color
//     (Nunito 13.5, w500, color .72 opacity) so the rest of the body
//     reads as plain comment text.
//
// Attachments:
//   * kind == "image"      -> ClipRRect thumbnail, max 220x220, BoxFit.cover.
//   * kind == "sticker"    -> inline GIPHY image, max 140 tall, BoxFit.contain.
//   * Stacked below the text in a Column with 6-px spacing.
// ============================================================================

class _CommentBody extends StatelessWidget {
  final Comment comment;
  final Map<String, UserRef> mentionedUsersCache;
  final ValueChanged<String> onMentionTap;

  const _CommentBody({
    required this.comment,
    required this.mentionedUsersCache,
    required this.onMentionTap,
  });

  // Pattern: @-token not at a word boundary. We require a non-word
  // boundary before the @ so we don't match email addresses; the @ may
  // be at position 0 of the text (start of comment).
  static final RegExp _mentionRe = RegExp(r"\B@([a-z0-9_.]+)", caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    final text = comment.text;
    final hasAttachments = comment.attachments.isNotEmpty;

    // Build a single child if neither text nor attachments are present
    // (e.g. a comment that's only an attachment with empty text).
    if (text.trim().isEmpty && !hasAttachments) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text.isNotEmpty) _buildText(context),
        if (hasAttachments) ...[
          if (text.isNotEmpty) const SizedBox(height: 6),
          for (final att in comment.attachments)
            Padding(
              padding: EdgeInsets.only(
                top: att == comment.attachments.first ? 0 : 6,
              ),
              child: _CommentAttachmentThumb(attachment: att),
            ),
        ],
      ],
    );
  }

  Widget _buildText(BuildContext context) {
    final text = comment.text;
    final matches = _mentionRe.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          height: 1.3,
          color: Colors.black.withOpacity(.72),
        ),
      );
    }

    // Build a reverse-lookup: mentionTag (lowercased no-spaces) -> uid.
    // Skip entries whose mentionTag is empty.
    final tagToUid = <String, String>{};
    for (final entry in mentionedUsersCache.entries) {
      final tag = entry.value.mentionTag;
      if (tag.isNotEmpty) {
        tagToUid[tag] = entry.key;
      }
    }

    final spans = <InlineSpan>[];
    int cursor = 0;
    final baseStyle = TextStyle(
      fontFamily: "Nunito",
      fontSize: 13.5,
      fontWeight: FontWeight.w500,
      height: 1.3,
      color: Colors.black.withOpacity(.72),
    );
    final mentionStyle = baseStyle.copyWith(
      color: const Color(0xFF1D9BF0),
      fontWeight: FontWeight.w600,
    );
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start), style: baseStyle));
      }
      final raw = m.group(1) ?? "";
      final tag = raw.toLowerCase();
      final resolvedUid = tagToUid[tag];
      if (resolvedUid == null) {
        // Cache miss for this mention tag — render as plain styled text
        // (still X-blue so the user sees it's a mention, but no tap
        // handler because we don't have a uid to navigate to yet).
        spans.add(TextSpan(text: "@$raw", style: mentionStyle));
      } else {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => onMentionTap(resolvedUid);
        spans.add(TextSpan(
          text: "@$raw",
          style: mentionStyle,
          recognizer: recognizer,
        ));
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
    }
    return Text.rich(TextSpan(children: spans));
  }
}

// ============================================================================
// v66: _CommentAttachmentThumb — renders a single CommentAttachment
// inside the comment body. Image: thumbnail (max 220x220). Sticker:
// inline GIPHY image (max 140 tall). Tapping is a no-op for now; the
// bubble-level onBubbleTap / onAuthorTap callbacks still cover the
// surrounding gestures. (Future work: a tap-to-fullscreen view.)
// ============================================================================

class _CommentAttachmentThumb extends StatelessWidget {
  final CommentAttachment attachment;

  const _CommentAttachmentThumb({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final url = (attachment.thumbUrl != null &&
            attachment.thumbUrl!.isNotEmpty)
        ? attachment.thumbUrl!
        : attachment.url;
    if (url.isEmpty) return const SizedBox.shrink();

    final isSticker = attachment.kind == "sticker";
    final maxW = isSticker ? 140.0 : 220.0;
    final maxH = isSticker ? 140.0 : 220.0;
    final fit = isSticker ? BoxFit.contain : BoxFit.cover;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Image.network(
          url,
          fit: fit,
          errorBuilder: (_, __, ___) => Container(
            width: maxW,
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF1F4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isSticker
                  ? PhosphorIcons.sticker(PhosphorIconsStyle.regular)
                  : PhosphorIcons.image(PhosphorIconsStyle.regular),
              size: 24,
              color: Colors.black38,
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: maxW,
              height: 80,
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
