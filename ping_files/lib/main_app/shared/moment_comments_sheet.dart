// ============================================================================
// moment_comments_sheet.dart — the public MomentCommentsSheet that replaces
// the two private/public sheets that used to live in feed_tab.dart and
// shared_moment_widgets.dart.
//
// Architecture:
//   * The sheet is purely UI; all network calls go through CommentService
//     (passed in as a constructor argument) so the same code path runs for
//     the feed and the moment detail screen.
//   * Reply composer is inline — the sheet swaps the bottom composer from
//     "Add a comment…" to "Replying to @name…" with a clear (X) chip.
//   * "View N replies" pill on a top-level comment navigates the parent
//     (via onOpenReplies callback) to MomentCommentRepliesScreen, which
//     renders the root + all its descendants in chronological order.
//   * "Send to connection" is exposed as a callback (onShareToConnection)
//     so the parent can decide whether to open the connection picker first
//     (v53 wires that up) or skip the picker for direct sends.
// ============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:giphy_get/giphy_get.dart';
import 'package:image_picker/image_picker.dart';

import 'package:ping_files/main_app/shared/comment_widgets.dart';
import 'package:ping_files/theme/colors2.dart';

// Re-use the same GIPHY key as the chat channel so a single billing
// identity covers the app.
const String kPingmeeGiphyApiKey = 'g3wdgZSfWXCPsRDJn4fosL6bXjtYgQXJ';

// ============================================================================
// Comment sort dropdown — Top / Recent
// ============================================================================

enum _CommentSort { top, recent }

extension _CommentSortLabel on _CommentSort {
  String get label {
    switch (this) {
      case _CommentSort.top:
        return "Top";
      case _CommentSort.recent:
        return "Recent";
    }
  }
}

class _CommentSortDropdown extends StatelessWidget {
  final _CommentSort value;
  final ValueChanged<_CommentSort?> onChanged;

  const _CommentSortDropdown({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_CommentSort>(
      onSelected: onChanged,
      tooltip: "Sort comments",
      offset: const Offset(0, 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      color: Colors.white,
      itemBuilder: (_) => _CommentSort.values
          .map((s) => PopupMenuItem<_CommentSort>(
                value: s,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s == value)
                      const Icon(Icons.check_rounded, size: 16, color: Colors.black87)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text(
                      s.label,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value.label,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: Colors.black.withOpacity(.55),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MomentCommentsSheet — public, replaces the two private sheets.
// ============================================================================

class MomentCommentsSheet extends StatefulWidget {
  final String activityId;
  final CommentService commentService;
  final bool Function(Comment comment)? authorIsVerified;

  /// Called when the user taps the avatar / name on any comment. The parent
  /// typically navigates to the user's profile tab.
  final void Function(String authorUid)? onAuthorTap;

  /// Called when the user taps "View N replies" on a top-level comment. The
  /// parent navigates to MomentCommentRepliesScreen. If null, the sheet
  /// does nothing on that tap.
  final void Function(Comment parentComment)? onOpenReplies;

  /// Called when the user taps the paper-plane on a comment. The parent
  /// opens its connection picker (v53) and then calls
  /// commentService.sendToConnection(...). If null, the sheet falls back
  /// to a SnackBar (no-op).
  final Future<void> Function(Comment comment)? onShareToConnection;

  const MomentCommentsSheet({
    super.key,
    required this.activityId,
    required this.commentService,
    this.authorIsVerified,
    this.onAuthorTap,
    this.onOpenReplies,
    this.onShareToConnection,
  });

  @override
  State<MomentCommentsSheet> createState() => _MomentCommentsSheetState();
}

class _MomentCommentsSheetState extends State<MomentCommentsSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  bool _loading = true;
  bool _sending = false;
  String? _error;

  List<Comment> _comments = [];

  /// Per-sheet verified-author cache. Populated lazily by
  /// _refreshVerifiedCache after _loadComments returns.
  /// Mirrors the parent feed_tab's _verifiedCache but is sheet-local
  /// so the sheet can resolve verified flags even for comment authors
  /// who never appeared in a moment in this session.
  final Map<String, bool> _verifiedCache = {};

  /// v65: per-sheet @-mention user cache. Populated lazily by
  /// _refreshMentionedUsersCache after a comment with `mentions` is
  /// loaded. Same copy-paste pattern as _verifiedCache from v61/v62.
  final Map<String, UserRef> _mentionedUsersCache = {};

  /// Top-level only, sorted by the current sort mode. Replies (where
  /// parentId is non-empty) are excluded.
  List<Comment> get _topLevelSorted {
    final list = _comments.where((c) => c.isTopLevel).toList();
    switch (_sort) {
      case _CommentSort.recent:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _CommentSort.top:
        list.sort((a, b) {
          // Threads-style "top" ranking:
          //   1. Liked-by-me first (your comments pinned)
          //   2. Like count desc
          //   3. Reply count desc
          //   4. Newest first as a tiebreaker
          if (a.likedByMe != b.likedByMe) {
            return a.likedByMe ? -1 : 1;
          }
          if (a.likeCount != b.likeCount) {
            return b.likeCount.compareTo(a.likeCount);
          }
          if (a.replyCount != b.replyCount) {
            return b.replyCount.compareTo(a.replyCount);
          }
          return b.createdAt.compareTo(a.createdAt);
        });
    }
    return list;
  }

  /// Non-null when the composer is in "reply mode" for a specific parent.
  /// All replies are added with parentCommentId = this id and
  /// rootCommentId = either this id (if the parent was top-level) or the
  /// parent's own rootId.
  Comment? _replyingTo;

  /// Current sort order for the top-level list. Replies in the
  /// sub-page are always chronological.
  _CommentSort _sort = _CommentSort.top;

  /// Per-comment in-flight flags so the user can't double-tap a heart or
  /// bookmark while the request is in flight.
  final Set<String> _pendingLikes = <String>{};
  final Set<String> _pendingSaves = <String>{};

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _controller.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final list = await widget.commentService.loadComments(
        activityId: widget.activityId,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        _comments = list;
        _loading = false;
      });

      // Refresh the per-sheet verified cache for any unknown author
      // (uids that the parent's _verifiedCache doesn't know about
      // because they never appeared as a moment author in this
      // session). The optimistic "You" row has an empty authorUid
      // and is correctly skipped here.
      await _refreshVerifiedCache();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load comments.";
      });
    }
  }

  /// Resolves whether the comment's author is verified. The parent's
  /// [authorIsVerified] callback is authoritative (it may know about
  /// uids we don't have cached). The per-sheet [_verifiedCache] is
  /// the fallback for comment authors the parent doesn't know
  /// about. Empty authorUid (the optimistic "You" row) is always
  /// false.
  bool _isAuthorVerified(Comment c) {
    final uid = c.authorUid.trim();
    if (uid.isEmpty) return false;
    if (widget.authorIsVerified != null) {
      if (widget.authorIsVerified!(c)) return true;
    }
    return _verifiedCache[uid] ?? false;
  }

  /// Reads the loaded comments, batches a whereIn query for any author
  /// uid not already in the cache (or in the parent's
  /// [authorIsVerified] callback), populates the cache from the
  /// `verification.status` field, and rebuilds. Empty uids (the
  /// optimistic "You" row) are skipped.
  Future<void> _refreshVerifiedCache() async {
    // Also resolve the current user's verified flag (so the local
    // user gets a tick on their own comments if they are verified).
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me != null && me.isNotEmpty &&
        widget.authorIsVerified == null &&
        !_verifiedCache.containsKey(me)) {
      try {
        final myDoc = await FirebaseFirestore.instance
            .collection("users")
            .doc(me)
            .get();
        if (myDoc.exists && mounted) {
          final v = myDoc.data()?["verification"];
          bool isVerified = false;
          if (v is bool) {
            isVerified = v;
          } else if (v is Map) {
            isVerified = v["status"] == "verified";
          }
          setState(() {
            _verifiedCache[me] = isVerified;
          });
        }
      } catch (_) {
        // Non-fatal.
      }
    }

    final unknown = <String>{};
    for (final c in _comments) {
      final uid = c.authorUid.trim();
      if (uid.isEmpty) continue;
      // The parent's callback is the source of truth (it may know
      // about uids we don't). Only fall back to Firestore when the
      // callback also returns false (which means the parent doesn't
      // know either).
      if (widget.authorIsVerified == null) {
        if (!_verifiedCache.containsKey(uid)) unknown.add(uid);
      } else {
        if (widget.authorIsVerified!(c)) continue;
        if (!_verifiedCache.containsKey(uid)) unknown.add(uid);
      }
    }
    if (unknown.isEmpty) return;

    // Firestore `whereIn` is limited to 10 per query; chunk.
    for (var i = 0; i < unknown.length; i += 10) {
      final chunk = unknown
          .skip(i)
          .take(10)
          .toList();
      try {
        final snap = await FirebaseFirestore.instance
            .collection("users")
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        if (!mounted) return;
        final next = <String, bool>{};
        for (final doc in snap.docs) {
          final d = doc.data();
          final v = d["verification"];
          bool isVerified = false;
          if (v is bool) {
            isVerified = v;
          } else if (v is Map) {
            isVerified = v["status"] == "verified";
          }
          next[doc.id] = isVerified;
        }
        setState(() {
          _verifiedCache.addAll(next);
        });
      } catch (_) {
        // Non-fatal: just don't show ticks for these authors.
      }
    }
  }

  // ------------------------------------------------------------------
  // Reply composer
  // ------------------------------------------------------------------

  void _enterReplyMode(Comment parent) {
    setState(() {
      _replyingTo = parent;
      _controller.clear();
    });
    _composerFocus.requestFocus();
  }

  void _exitReplyMode() {
    setState(() {
      _replyingTo = null;
      _controller.clear();
    });
    _composerFocus.unfocus();
  }

  /// v65: send a comment with optional mentions and attachments.
  /// Called by the new [CommentComposer]. `text` is positional to match
  /// the [CommentComposerSend] typedef declared at the bottom of this file.
  Future<void> _sendComment(
    String text, {
    List<String> mentions = const <String>[],
    List<CommentAttachment> attachments = const <CommentAttachment>[],
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty && attachments.isEmpty) return;
    if (_sending) return;

    final replyParent = _replyingTo;
    final optimistic = Comment(
      id: "optimistic_${DateTime.now().millisecondsSinceEpoch}",
      userId: "",
      text: cleanText,
      authorUid: "",
      authorName: "You",
      authorPhotoUrl: "",
      createdAt: DateTime.now().toIso8601String(),
      parentId: replyParent?.id,
      rootId: replyParent?.rootId ?? replyParent?.id,
      mentionedUid: replyParent?.authorUid,
      likeCount: 0,
      savedCount: 0,
      replyCount: 0,
      likedByMe: false,
      savedByMe: false,
      mentions: mentions,
      attachments: attachments,
    );

    setState(() {
      _sending = true;
      _comments = [..._comments, optimistic];
    });
    _controller.clear();

    try {
      final real = await widget.commentService.addComment(
        activityId: widget.activityId,
        text: cleanText,
        parentCommentId: replyParent?.id,
        rootCommentId: replyParent?.rootId ?? replyParent?.id,
        mentions: mentions,
        attachments: attachments,
      );


      if (!mounted) return;
      setState(() {
        // Replace the optimistic row with the server-confirmed one, OR
        // append the server one if the optimistic row was lost.
        final idx = _comments.indexWhere((c) => c.id == optimistic.id);
        if (idx >= 0) {
          _comments = [..._comments]..[idx] = real;
        } else {
          _comments = [..._comments, real];
        }
        // If this was a top-level comment, nothing to bump. If this was
        // a reply, bump the parent's replyCount in-place.
        if (replyParent != null) {
          final p = _comments.indexWhere((c) => c.id == replyParent.id);
          if (p >= 0) {
            _comments[p] = _comments[p].copyWith(
              replyCount: _comments[p].replyCount + 1,
            );
          }
        }
        _replyingTo = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Drop the optimistic row
        _comments = _comments.where((c) => c.id != optimistic.id).toList();
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't add comment.")),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleLike(Comment comment) async {
    if (_pendingLikes.contains(comment.id)) return;
    _pendingLikes.add(comment.id);

    final wasLiked = comment.likedByMe;
    final reactionId = comment.myLikeReactionId ?? "";

    // Optimistic flip
    setState(() {
      final i = _comments.indexWhere((c) => c.id == comment.id);
      if (i >= 0) {
        _comments[i] = _comments[i].copyWith(
          likedByMe: !wasLiked,
          likeCount: (_comments[i].likeCount + (wasLiked ? -1 : 1)).clamp(0, 999999),
        );
      }
    });

    try {
      final result = await widget.commentService.toggleLike(
        activityId: widget.activityId,
        commentId: comment.id,
        currentlyLiked: wasLiked,
        reactionId: reactionId,
      );
      if (!mounted) return;
      setState(() {
        final i = _comments.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _comments[i] = _comments[i].copyWith(
            likedByMe: result["liked"] == true,
            myLikeReactionId: (result["reactionId"] as String?)?.isNotEmpty == true
                ? result["reactionId"] as String
                : "",
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      // Roll back
      setState(() {
        final i = _comments.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _comments[i] = _comments[i].copyWith(
            likedByMe: wasLiked,
            likeCount: (_comments[i].likeCount + (wasLiked ? 1 : -1))
                .clamp(0, 999999),
          );
        }
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update like.")),
      );
    } finally {
      _pendingLikes.remove(comment.id);
    }
  }

  Future<void> _toggleSave(Comment comment) async {
    if (_pendingSaves.contains(comment.id)) return;
    _pendingSaves.add(comment.id);

    final wasSaved = comment.savedByMe;
    final reactionId = comment.mySaveReactionId ?? "";

    setState(() {
      final i = _comments.indexWhere((c) => c.id == comment.id);
      if (i >= 0) {
        _comments[i] = _comments[i].copyWith(
          savedByMe: !wasSaved,
          savedCount:
              (_comments[i].savedCount + (wasSaved ? -1 : 1)).clamp(0, 999999),
        );
      }
    });

    try {
      final result = await widget.commentService.toggleSave(
        activityId: widget.activityId,
        commentId: comment.id,
        currentlySaved: wasSaved,
        reactionId: reactionId,
      );
      if (!mounted) return;
      setState(() {
        final i = _comments.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _comments[i] = _comments[i].copyWith(
            savedByMe: result["saved"] == true,
            mySaveReactionId: (result["reactionId"] as String?)?.isNotEmpty == true
                ? result["reactionId"] as String
                : "",
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _comments.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _comments[i] = _comments[i].copyWith(
            savedByMe: wasSaved,
            savedCount:
                (_comments[i].savedCount + (wasSaved ? 1 : -1)).clamp(0, 999999),
          );
        }
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update save.")),
      );
    } finally {
      _pendingSaves.remove(comment.id);
    }
  }

  // ------------------------------------------------------------------
  // Send-to-connection callback
  // ------------------------------------------------------------------

  Future<void> _onShareToConnection(Comment comment) async {
    final cb = widget.onShareToConnection;
    if (cb == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Sharing is not enabled in this context yet."),
        ),
      );
      return;
    }
    await cb(comment);
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

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
            height: MediaQuery.of(context).size.height * .85,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Header row: title left, sort dropdown middle-right,
                  // 3-dot more icon far right.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            "Comments",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        _CommentSortDropdown(
                          value: _sort,
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _sort = v);
                          },
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(
                            Icons.more_horiz_rounded,
                            size: 20,
                          ),
                          onPressed: _openSheetMoreMenu,
                          color: Colors.black87,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: "More",
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.black,
                              ),
                            ),
                          )
                        : _error != null
                            ? Center(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              )
                            : _comments.isEmpty
                                ? Center(
                                    child: Text(
                                      "No comments yet. Start it.",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w500,
                                        color:
                                            Colors.black.withOpacity(.55),
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      0,
                                      18,
                                      18,
                                    ),
                                    itemCount: _topLevelSorted.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      final c = _topLevelSorted[index];
                                      return _buildTopLevelRow(c);
                                    },
                                  ),
                  ),
                  _buildComposer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopLevelRow(Comment c) {
    // 1) The top-level tile itself.
    // 2) Any direct replies whose parentId == c.id (1 visible level).
    // 3) A "View N replies" pill (left-indented) ONLY if there are MORE
    //    replies on the server than the visible ones — currently the cloud
    //    function returns the count but not the children when listing
    //    top-level, so the pill always shows when replyCount > 0.
    final hasReplies = c.replyCount > 0;
    final visibleReplies = _comments
        .where((r) => r.parentId == c.id)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MomentCommentTile(
          comment: c,
          authorVerified:
              _isAuthorVerified(c),
          onLike: () => _toggleLike(c),
          onReply: () => _enterReplyMode(c),
          onSendToConnection: () => _onShareToConnection(c),
          onSave: () => _toggleSave(c),
          onAuthorTap: () => widget.onAuthorTap?.call(c.authorUid),
          onBubbleTap: hasReplies
              ? () => widget.onOpenReplies?.call(c)
              : null,
          onMore: () => _openMoreSheet(c),
          mentionedUsersCache: _mentionedUsersCache,
          onMentionTap: (uid) => widget.onAuthorTap?.call(uid),
        ),
        if (visibleReplies.isNotEmpty)
          _CommentBranch(
            // The branch line runs from the OG comment's avatar column
            // down to the last visible reply. The width is a fixed 28-px
            // indent so the replies align under the bubble body.
            childCount: visibleReplies.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in visibleReplies) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: MomentCommentTile(
                      comment: r,
                      authorVerified: _isAuthorVerified(r),
                      onLike: () => _toggleLike(r),
                      onReply: () => _enterReplyMode(c),
                      onSendToConnection: () => _onShareToConnection(r),
                      onSave: () => _toggleSave(r),
                      onAuthorTap: () =>
                          widget.onAuthorTap?.call(r.authorUid),
                      onMore: () => _openMoreSheet(r),
                      mentionedUsersCache: _mentionedUsersCache,
                      onMentionTap: (uid) => widget.onAuthorTap?.call(uid),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (hasReplies)
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 4),
            child: GestureDetector(
              onTap: () => widget.onOpenReplies?.call(c),
              behavior: HitTestBehavior.opaque,
              child: Text(
                "View ${c.replyCount} ${c.replyCount == 1 ? 'reply' : 'replies'}",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(.55),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Sheet-level more menu (header 3-dot on the right of the
  /// "Comments" title). Opens a small bottom sheet with sheet-level
  /// actions.
  Future<void> _openSheetMoreMenu() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Container(
            color: Colors.white,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(
                      Icons.flag_outlined,
                      color: Color(0xFFEF4444),
                    ),
                    title: const Text(
                      "Report spam",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop("report_spam"),
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.link_rounded,
                      color: Colors.black87,
                    ),
                    title: const Text(
                      "Copy link to all comments",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop("copy_link"),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (picked == "report_spam") {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            "Thanks. We'll review this thread.",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    } else if (picked == "copy_link") {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            "Link copied!",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }
  }

  Future<void> _openMoreSheet(Comment c) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Container(
            color: Colors.white,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(
                      Icons.flag_outlined,
                      color: Color(0xFFEF4444),
                    ),
                    title: const Text(
                      "Report comment",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop("report"),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked == "report" && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            "Thanks. We'll review this comment.",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }
  }

  Widget _buildComposer() {
    final replyingTo = _replyingTo;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (replyingTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Row(
                children: [
                  Icon(
                    PhosphorIcons.arrowBendUpLeft(
                        PhosphorIconsStyle.regular),
                    size: 13,
                    color: Colors.black54,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      "Reply to this comment",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.6),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _exitReplyMode,
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          CommentComposer(
            controller: _controller,
            focusNode: _composerFocus,
            hintText: replyingTo == null
                ? "Add a comment…"
                : "Reply to this comment…",
            sending: _sending,
            myUid: FirebaseAuth.instance.currentUser?.uid ?? "",
            commentService: widget.commentService,
            activityId: widget.activityId,
            mentionedUsersCache: _mentionedUsersCache,
            onRefreshMentionedCache: _refreshMentionedUsersCache,
            onSend: _sendComment,
          ),
        ],
      ),
    );
  }

  /// v65: lazy-populate the per-sheet _mentionedUsersCache for any
  /// comment whose `mentions` we don't already have. Mirrors
  /// _refreshVerifiedCache (v61/v62) but resolves UserRef via
  /// CommentService.lookupManyByUids.
  Future<void> _refreshMentionedUsersCache() async {
    final missing = <String>{};
    for (final c in _comments) {
      for (final uid in c.mentions) {
        if (uid.isNotEmpty && !_mentionedUsersCache.containsKey(uid)) {
          missing.add(uid);
        }
      }
    }
    if (missing.isEmpty) return;
    final fetched = await widget.commentService
        .lookupManyByUids(missing.toList());
    if (!mounted) return;
    if (fetched.isEmpty) return;
    setState(() {
      _mentionedUsersCache.addAll(fetched);
    });
  }
}

// ============================================================================
// _CommentBranch — vertical curved line connecting an OG comment to its
// visible replies. The line lives in a CustomPaint and occupies a fixed
// 28-px column on the left. The avatar of the OG comment sits in that
// column; the bubble of each reply is indented past the line so the
// branch clearly belongs to the OG comment.
//
// Visual:
//   • The curve goes from the OG bubble's BOTTOM-LEFT corner, down past
//     each reply, and ends at the BOTTOM-LEFT of the LAST reply.
//   • A short horizontal "tick" at each reply's top connects the curve
//     to the reply bubble.
//   • Curve width is 2 px in black at 18% opacity — subtle but visible.
// ============================================================================

class _CommentBranch extends StatelessWidget {
  final int childCount;
  final Widget child;

  const _CommentBranch({
    required this.childCount,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 18),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 18,
              child: CustomPaint(
                painter: _CommentBranchPainter(childCount: childCount),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _CommentBranchPainter extends CustomPainter {
  final int childCount;
  _CommentBranchPainter({required this.childCount});

  @override
  void paint(Canvas canvas, Size size) {
    if (childCount <= 0) return;
    final paint = Paint()
      ..color = Colors.black.withOpacity(.18)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Single vertical line down the left edge. The visual indent of each
    // reply tile is provided by the parent Padding, so this painter only
    // needs one straight line + a small horizontal tick at the top so the
    // line clearly connects to the OG comment above.
    final w = size.width;
    final h = size.height;
    final x = w * 0.4; // 40% from the left (slight right-of-center anchor)

    // Top tick: a short horizontal stroke that visually "starts" the
    // branch from the OG bubble. 12 px long.
    canvas.drawLine(
      Offset(x, 0),
      Offset(x + 12, 0),
      paint,
    );

    // Vertical line down to the bottom of the last reply.
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, h),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CommentBranchPainter old) =>
      old.childCount != childCount;
}

// ============================================================================
// MomentCommentRepliesScreen — the Threads-style sub-page that shows one
// root comment plus all its descendants (replies) in chronological order.
// Tapping the back arrow or system back pops back to MomentCommentsSheet
// with the sheet's optimistic state preserved.
// ============================================================================

class MomentCommentRepliesScreen extends StatefulWidget {
  final Comment rootComment;
  final String activityId;
  final CommentService commentService;
  final bool Function(Comment comment)? authorIsVerified;
  final void Function(String authorUid)? onAuthorTap;
  final Future<void> Function(Comment comment)? onShareToConnection;

  const MomentCommentRepliesScreen({
    super.key,
    required this.rootComment,
    required this.activityId,
    required this.commentService,
    this.authorIsVerified,
    this.onAuthorTap,
    this.onShareToConnection,
  });

  @override
  State<MomentCommentRepliesScreen> createState() =>
      _MomentCommentRepliesScreenState();
}

class _MomentCommentRepliesScreenState
    extends State<MomentCommentRepliesScreen> {
  /// Per-screen verified-author cache. Mirrors the same field on
  /// _MomentCommentsSheetState. Duplicated here (instead of a mixin)
  /// to keep the patch minimal; refactor to a shared mixin later.
  final Map<String, bool> _verifiedCache = {};

  /// v65: per-sheet @-mention user cache. Same pattern as the
  /// _MomentCommentsSheetState.
  final Map<String, UserRef> _mentionedUsersCache = {};

  final TextEditingController _controller = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  bool _loading = true;
  bool _sending = false;
  String? _error;

  /// The root comment is always shown pinned at the top. Replies follow.
  List<Comment> _replies = [];

  final Set<String> _pendingLikes = <String>{};
  final Set<String> _pendingSaves = <String>{};

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  @override
  void dispose() {
    _controller.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // One call: rootCommentId=root.id returns root + every descendant.
      // We discard the root row in the list (it's pinned at the top with
      // its own tile).
      final all = await widget.commentService.loadComments(
        activityId: widget.activityId,
        limit: 100,
        rootCommentId: widget.rootComment.id,
      );
      if (!mounted) return;
      setState(() {
        _replies = all.where((c) => c.id != widget.rootComment.id).toList();
        _loading = false;
      });

      // Same as the main sheet: one-time batched Firestore lookup
      // for the verified flag of any reply / root author we don't
      // know about.
      await _refreshVerifiedCache();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load replies.";
      });
    }
  }

  /// v65: send a reply with optional mentions and attachments.
  /// `text` is positional to match the [CommentComposerSend] typedef.
  Future<void> _sendReply(
    String text, {
    List<String> mentions = const <String>[],
    List<CommentAttachment> attachments = const <CommentAttachment>[],
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty && attachments.isEmpty) return;
    if (_sending) return;

    setState(() {
      _sending = true;
    });
    _controller.clear();

    try {
      final reply = await widget.commentService.addComment(
        activityId: widget.activityId,
        text: cleanText,
        parentCommentId: widget.rootComment.id,
        rootCommentId: widget.rootComment.id,
        mentions: mentions,
        attachments: attachments,
      );


      if (!mounted) return;
      setState(() {
        _replies = [..._replies, reply];
        _sending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't add reply.")),
      );
    }
  }

  Future<void> _toggleLike(Comment comment) async {
    if (_pendingLikes.contains(comment.id)) return;
    _pendingLikes.add(comment.id);
    final wasLiked = comment.likedByMe;
    final reactionId = comment.myLikeReactionId ?? "";
    setState(() {
      final i = _replies.indexWhere((c) => c.id == comment.id);
      if (i >= 0) {
        _replies[i] = _replies[i].copyWith(
          likedByMe: !wasLiked,
          likeCount:
              (_replies[i].likeCount + (wasLiked ? -1 : 1)).clamp(0, 999999),
        );
      }
    });
    try {
      final result = await widget.commentService.toggleLike(
        activityId: widget.activityId,
        commentId: comment.id,
        currentlyLiked: wasLiked,
        reactionId: reactionId,
      );
      if (!mounted) return;
      setState(() {
        final i = _replies.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _replies[i] = _replies[i].copyWith(
            likedByMe: result["liked"] == true,
            myLikeReactionId:
                (result["reactionId"] as String?)?.isNotEmpty == true
                    ? result["reactionId"] as String
                    : "",
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _replies.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _replies[i] = _replies[i].copyWith(
            likedByMe: wasLiked,
            likeCount: (_replies[i].likeCount + (wasLiked ? 1 : -1))
                .clamp(0, 999999),
          );
        }
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update like.")),
      );
    } finally {
      _pendingLikes.remove(comment.id);
    }
  }

  Future<void> _toggleSave(Comment comment) async {
    if (_pendingSaves.contains(comment.id)) return;
    _pendingSaves.add(comment.id);
    final wasSaved = comment.savedByMe;
    final reactionId = comment.mySaveReactionId ?? "";
    setState(() {
      final i = _replies.indexWhere((c) => c.id == comment.id);
      if (i >= 0) {
        _replies[i] = _replies[i].copyWith(
          savedByMe: !wasSaved,
          savedCount:
              (_replies[i].savedCount + (wasSaved ? -1 : 1)).clamp(0, 999999),
        );
      }
    });
    try {
      final result = await widget.commentService.toggleSave(
        activityId: widget.activityId,
        commentId: comment.id,
        currentlySaved: wasSaved,
        reactionId: reactionId,
      );
      if (!mounted) return;
      setState(() {
        final i = _replies.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _replies[i] = _replies[i].copyWith(
            savedByMe: result["saved"] == true,
            mySaveReactionId:
                (result["reactionId"] as String?)?.isNotEmpty == true
                    ? result["reactionId"] as String
                    : "",
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _replies.indexWhere((c) => c.id == comment.id);
        if (i >= 0) {
          _replies[i] = _replies[i].copyWith(
            savedByMe: wasSaved,
            savedCount: (_replies[i].savedCount + (wasSaved ? 1 : -1))
                .clamp(0, 999999),
          );
        }
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't update save.")),
      );
    } finally {
      _pendingSaves.remove(comment.id);
    }
  }

  Future<void> _onShareToConnection(Comment comment) async {
    final cb = widget.onShareToConnection;
    if (cb == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Sharing is not enabled in this context yet."),
        ),
      );
      return;
    }
    await cb(comment);
  }
  /// Reply-level more menu (per-comment 3-dot in the replies list).
  Future<void> _openRepliesMoreSheet(Comment c) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Container(
            color: Colors.white,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(
                      Icons.flag_outlined,
                      color: Color(0xFFEF4444),
                    ),
                    title: const Text(
                      "Report comment",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop("report"),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked == "report" && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            "Thanks. We'll review this comment.",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }
  }


  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  /// Resolves whether the comment's author is verified. Same logic
  /// as _MomentCommentsSheetState._isAuthorVerified. Kept in sync
  /// (todo: extract to a shared mixin).
  bool _isAuthorVerified(Comment c) {
    final uid = c.authorUid.trim();
    if (uid.isEmpty) return false;
    if (widget.authorIsVerified != null) {
      if (widget.authorIsVerified!(c)) return true;
    }
    return _verifiedCache[uid] ?? false;
  }

  /// Same logic as _MomentCommentsSheetState._refreshVerifiedCache.
  Future<void> _refreshVerifiedCache() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me != null && me.isNotEmpty &&
        widget.authorIsVerified == null &&
        !_verifiedCache.containsKey(me)) {
      try {
        final myDoc = await FirebaseFirestore.instance
            .collection("users")
            .doc(me)
            .get();
        if (myDoc.exists && mounted) {
          final v = myDoc.data()?["verification"];
          bool isVerified = false;
          if (v is bool) {
            isVerified = v;
          } else if (v is Map) {
            isVerified = v["status"] == "verified";
          }
          setState(() {
            _verifiedCache[me] = isVerified;
          });
        }
      } catch (_) {
        // Non-fatal.
      }
    }

    final unknown = <String>{};
    for (final c in _replies) {
      final uid = c.authorUid.trim();
      if (uid.isEmpty) continue;
      if (widget.authorIsVerified == null) {
        if (!_verifiedCache.containsKey(uid)) unknown.add(uid);
      } else {
        if (widget.authorIsVerified!(c)) continue;
        if (!_verifiedCache.containsKey(uid)) unknown.add(uid);
      }
    }
    // Also include the root comment author — the root tile uses this
    // helper too.
    final rootUid = widget.rootComment.authorUid.trim();
    if (rootUid.isNotEmpty &&
        !_verifiedCache.containsKey(rootUid) &&
        (widget.authorIsVerified == null ||
            !widget.authorIsVerified!(widget.rootComment))) {
      unknown.add(rootUid);
    }
    if (unknown.isEmpty) return;

    for (var i = 0; i < unknown.length; i += 10) {
      final chunk = unknown
          .skip(i)
          .take(10)
          .toList();
      try {
        final snap = await FirebaseFirestore.instance
            .collection("users")
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        if (!mounted) return;
        final next = <String, bool>{};
        for (final doc in snap.docs) {
          final d = doc.data();
          final v = d["verification"];
          bool isVerified = false;
          if (v is bool) {
            isVerified = v;
          } else if (v is Map) {
            isVerified = v["status"] == "verified";
          }
          next[doc.id] = isVerified;
        }
        setState(() {
          _verifiedCache.addAll(next);
        });
      } catch (_) {
        // Non-fatal.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
          color: Colors.black87,
        ),
        title: const Text(
          "Replies",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        centerTitle: false,
      ),
      body: Column(
        children: [
          // Pinned root comment
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: MomentCommentTile(
              comment: widget.rootComment,
              authorVerified:
                  _isAuthorVerified(widget.rootComment) ||
                      false,
              onLike: () => _toggleLike(widget.rootComment),
              onReply: () {
                // Replies to a reply: the parent is the root, so we just
                // focus the composer (and we don't surface a "Replying to"
                // pill — the pinned root tile at the top makes the context
                // clear).
                _composerFocus.requestFocus();
              },
              onSendToConnection: () =>
                  _onShareToConnection(widget.rootComment),
              onSave: () => _toggleSave(widget.rootComment),
              onAuthorTap: () =>
                  widget.onAuthorTap?.call(widget.rootComment.authorUid),
              mentionedUsersCache: _mentionedUsersCache,
              onMentionTap: (uid) => widget.onAuthorTap?.call(uid),
            ),
          ),
          Divider(height: 1, color: Colors.black.withOpacity(.06)),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.black),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : _replies.isEmpty
                        ? Center(
                            child: Text(
                              "No replies yet.",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.55),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding:
                                const EdgeInsets.fromLTRB(18, 14, 18, 18),
                            itemCount: _replies.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final r = _replies[index];
                              return MomentCommentTile(
                                comment: r,
                                authorVerified: _isAuthorVerified(r),
                                onLike: () => _toggleLike(r),
                                onReply: () => _composerFocus.requestFocus(),
                                onSendToConnection: () =>
                                    _onShareToConnection(r),
                                onSave: () => _toggleSave(r),
                                onAuthorTap: () =>
                                    widget.onAuthorTap?.call(r.authorUid),
                                onMore: () => _openRepliesMoreSheet(r),
                                mentionedUsersCache: _mentionedUsersCache,
                                onMentionTap: (uid) =>
                                    widget.onAuthorTap?.call(uid),
                              );
                            },
                          ),
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Reply to this comment" pill (always shown in replies screen).
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(
                  PhosphorIcons.arrowBendUpLeft(
                      PhosphorIconsStyle.regular),
                  size: 13,
                  color: Colors.black54,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    "Reply to this comment",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withOpacity(.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          CommentComposer(
            controller: _controller,
            focusNode: _composerFocus,
            hintText: "Reply to this comment…",
            sending: _sending,
            myUid: FirebaseAuth.instance.currentUser?.uid ?? "",
            commentService: widget.commentService,
            activityId: widget.activityId,
            mentionedUsersCache: _mentionedUsersCache,
            onRefreshMentionedCache: _refreshMentionedUsersCache,
            onSend: _sendReply,
          ),
        ],
      ),
    );
  }

  /// v65: lazy-populate the per-sheet _mentionedUsersCache for the
  /// replies list. Mirrors _MomentCommentsSheetState.
  Future<void> _refreshMentionedUsersCache() async {
    final missing = <String>{};
    for (final c in _replies) {
      for (final uid in c.mentions) {
        if (uid.isNotEmpty && !_mentionedUsersCache.containsKey(uid)) {
          missing.add(uid);
        }
      }
    }
    if (missing.isEmpty) return;
    final fetched = await widget.commentService
        .lookupManyByUids(missing.toList());
    if (!mounted) return;
    if (fetched.isEmpty) return;
    setState(() {
      _mentionedUsersCache.addAll(fetched);
    });
  }
}



// ============================================================================
// v65: MentionPicker — a floating popup that appears above the composer
// when the user types '@'. Shows up to 10 connection chips (avatar + name +
// username). As the user types after the '@', the list filters by name /
// username substring (case-insensitive). Tapping a chip inserts
// '@<mentionTag> ' at the current cursor position in the composer
// TextField via the onPickMention callback.
// ============================================================================

class MentionPicker extends StatefulWidget {
  final String myUid;
  final CommentService commentService;
  final ValueChanged<UserRef> onPickMention;

  const MentionPicker({
    super.key,
    required this.myUid,
    required this.commentService,
    required this.onPickMention,
  });

  @override
  State<MentionPicker> createState() => _MentionPickerState();
}

class _MentionPickerState extends State<MentionPicker> {
  final TextEditingController _queryCtrl = TextEditingController();

  Timer? _debounce;
  List<UserRef> _results = const <UserRef>[];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _runSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  void _runSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted) return;
      setState(() => _loading = true);
      final list = await widget.commentService.searchConnections(
        widget.myUid,
        query: _queryCtrl.text,
        limit: 10,
      );
      if (!mounted) return;
      setState(() {
        _results = list;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 280),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _queryCtrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (_) => _runSearch(),
              decoration: InputDecoration(
                isDense: true,
                hintText: "Search connections",
                hintStyle: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.4),
                ),
                prefixIcon: Icon(
                  PhosphorIcons.magnifyingGlass(
                      PhosphorIconsStyle.regular),
                  size: 16,
                  color: Colors.black.withOpacity(.55),
                ),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.black.withOpacity(.6)),
                        ),
                      ),
                    )
                  : _results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 16),
                          child: Text(
                            _queryCtrl.text.trim().isEmpty
                                ? "No connections yet."
                                : "No matches.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: Colors.black.withOpacity(.55),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            thickness: 0.5,
                            color: Colors.black.withOpacity(.06),
                          ),
                          itemBuilder: (_, i) {
                            final u = _results[i];
                            return InkWell(
                              onTap: () => widget.onPickMention(u),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                child: Row(
                                  children: [
                                    ClipOval(
                                      child: u.photoUrl.isNotEmpty
                                          ? Image.network(
                                              u.photoUrl,
                                              width: 28,
                                              height: 28,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (_, __, ___) => Container(
                                                width: 28,
                                                height: 28,
                                                color: const Color(
                                                    0xFFEFF1F4),
                                                child: Icon(
                                                  PhosphorIcons.user(
                                                      PhosphorIconsStyle
                                                          .regular),
                                                  size: 16,
                                                  color: Colors.black26,
                                                ),
                                              ),
                                            )
                                          : Container(
                                              width: 28,
                                              height: 28,
                                              color:
                                                  const Color(0xFFEFF1F4),
                                              child: Icon(
                                                PhosphorIcons.user(
                                                    PhosphorIconsStyle
                                                        .regular),
                                                size: 16,
                                                color: Colors.black26,
                                              ),
                                            ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // v70: show @username as the
                                          // PRIMARY text so the user can
                                          // see exactly what tag will
                                          // be inserted. fullName becomes
                                          // the smaller secondary text.
                                          if (u.username.isNotEmpty)
                                            Text(
                                              "@${u.username}",
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: "Nunito",
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF1D9BF0),
                                              ),
                                            )
                                          else
                                            Text(
                                              u.fullName,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: "Nunito",
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.black87,
                                              ),
                                            ),
                                          if (u.fullName.isNotEmpty &&
                                              u.fullName !=
                                                  (u.username.isNotEmpty
                                                      ? u.username
                                                      : u.fullName))
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(
                                                      top: 1),
                                              child: Text(
                                                u.fullName,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow
                                                        .ellipsis,
                                                style: TextStyle(
                                                  fontFamily: "Nunito",
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w500,
                                                  color: Colors.black
                                                      .withOpacity(.55),
                                                ),
                                              ),
                                            ),
                                        ],
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
        ),
      ),
    );
  }
}

// ============================================================================
// v65: AttachmentBar — a thin icon row that sits ABOVE the composer
// TextField. 4 buttons: @, emoji, image, sticker.
// ============================================================================

class AttachmentBar extends StatelessWidget {
  final VoidCallback onTapMention;
  final VoidCallback onTapEmoji;
  final VoidCallback onTapImage;
  final VoidCallback onTapSticker;

  final bool mentionOpen;
  final bool emojiOpen;
  final bool stickerOpen;
  final bool uploading;

  const AttachmentBar({
    super.key,
    required this.onTapMention,
    required this.onTapEmoji,
    required this.onTapImage,
    required this.onTapSticker,
    this.mentionOpen = false,
    this.emojiOpen = false,
    this.stickerOpen = false,
    this.uploading = false,
  });

  @override
  Widget build(BuildContext context) {
    final inactive = Colors.black.withOpacity(.55);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          _BarButton(
            iconData: PhosphorIcons.at(PhosphorIconsStyle.regular),
            color: mentionOpen ? Colors.black : inactive,
            tooltip: "Mention",
            onTap: onTapMention,
          ),
          _BarButton(
            iconData: PhosphorIcons.smiley(PhosphorIconsStyle.regular),
            color: emojiOpen ? Colors.black : inactive,
            tooltip: "Emoji",
            onTap: onTapEmoji,
          ),
          _BarButton(
            iconData: PhosphorIcons.image(PhosphorIconsStyle.regular),
            color: inactive,
            tooltip: "Image",
            onTap: uploading ? null : onTapImage,
            uploading: uploading,
          ),
          _BarButton(
            iconData: PhosphorIcons.sticker(PhosphorIconsStyle.regular),
            color: stickerOpen ? Colors.black : inactive,
            tooltip: "Sticker",
            onTap: onTapSticker,
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData iconData;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;
  final bool uploading;

  const _BarButton({
    required this.iconData,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.uploading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: uploading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.black54),
                    ),
                  )
                : Icon(iconData, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// v65: CommentComposer — the new composer used by BOTH the main sheet
// and the replies screen.
// ============================================================================

typedef CommentComposerSend = Future<void> Function(
  String text, {
  List<String> mentions,
  List<CommentAttachment> attachments,
});

class CommentComposer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final bool sending;
  final String myUid;
  final CommentService commentService;
  final String activityId;

  final Map<String, UserRef> mentionedUsersCache;
  final Future<void> Function() onRefreshMentionedCache;

  final CommentComposerSend onSend;

  const CommentComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.sending,
    required this.myUid,
    required this.commentService,
    required this.activityId,
    required this.mentionedUsersCache,
    required this.onRefreshMentionedCache,
    required this.onSend,
  });

  @override
  State<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<CommentComposer> {
  final ImagePicker _imagePicker = ImagePicker();

  final List<String> _mentionUids = <String>[];

  String? _pendingImageUrl;
  int? _pendingImageWidth;
  int? _pendingImageHeight;
  String? _pendingStickerUrl;
  String? _pendingStickerThumb;
  String? _pendingStickerId;

  bool _emojiOpen = false;
  bool _mentionPickerVisible = false;
  bool _uploadingImage = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus && mounted) {
      if (_emojiOpen) setState(() => _emojiOpen = false);
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
    }
  }

  void _onTextChanged() {
    if (!mounted) return;
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final cursor = selection.baseOffset;
    if (cursor <= 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final before = text.substring(0, cursor);
    final atIndex = before.lastIndexOf('@');
    if (atIndex < 0) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    final between = before.substring(atIndex + 1);
    if (between.contains(' ') || between.contains('\n')) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (between.length > 32) {
      if (_mentionPickerVisible) {
        setState(() => _mentionPickerVisible = false);
      }
      return;
    }
    if (!_mentionPickerVisible) {
      setState(() => _mentionPickerVisible = true);
    }
  }

  void _insertAtCursor(String s) {
    final ctrl = widget.controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      final newText = ctrl.text + s;
      ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      return;
    }
    final newText = ctrl.text.replaceRange(sel.start, sel.end, s);
    final newCursor = sel.start + s.length;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  void _onPickMention(UserRef u) {
    final tag = '@${u.mentionTag} ';
    final ctrl = widget.controller;
    final sel = ctrl.selection;
    if (!sel.isValid) {
      _insertAtCursor(tag);
    } else {
      final text = ctrl.text;
      final atIndex = text.lastIndexOf('@', sel.start - 1);
      if (atIndex >= 0) {
        final newText = text.replaceRange(atIndex, sel.start, tag);
        ctrl.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: atIndex + tag.length),
        );
      } else {
        _insertAtCursor(tag);
      }
    }
    if (!_mentionUids.contains(u.uid)) {
      _mentionUids.add(u.uid);
      widget.mentionedUsersCache[u.uid] = u;
    }
    setState(() => _mentionPickerVisible = false);
    widget.focusNode.requestFocus();
  }

  Future<void> _onPickImageFromGallery() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1920,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _uploadImage(bytes, _mimeForFileName(picked.name));
    } on PlatformException catch (e) {
      _toast("Couldn't pick image: ${e.message ?? e.code}");
    } catch (_) {
      _toast("Couldn't pick image.");
    }
  }

  Future<void> _onPickImageFromCamera() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
        maxWidth: 1920,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _uploadImage(bytes, _mimeForFileName(picked.name));
    } on PlatformException catch (e) {
      _toast("Couldn't take photo: ${e.message ?? e.code}");
    } catch (_) {
      _toast("Couldn't take photo.");
    }
  }

  String _mimeForFileName(String name) {
    final n = name.toLowerCase();
    if (n.endsWith(".png")) return "image/png";
    if (n.endsWith(".gif")) return "image/gif";
    if (n.endsWith(".webp")) return "image/webp";
    return "image/jpeg";
  }

  Future<void> _uploadImage(Uint8List bytes, String contentType) async {
    setState(() => _uploadingImage = true);
    try {
      final localId =
          "local-${DateTime.now().millisecondsSinceEpoch}";
      final url = await widget.commentService.uploadCommentImage(
        activityId: widget.activityId,
        commentIdLocal: localId,
        bytes: bytes,
        contentType: contentType,
      );
      if (!mounted) return;
      setState(() {
        _pendingImageUrl = url;
        _pendingImageWidth = null;
        _pendingImageHeight = null;
        _uploadingImage = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploadingImage = false);
      _toast("Couldn't upload image.");
    }
  }

  Future<void> _showImageSourceSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text(
                  "Take photo",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("camera"),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text(
                  "Choose from library",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop("library"),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (picked == "camera") {
      await _onPickImageFromCamera();
    } else if (picked == "library") {
      await _onPickImageFromGallery();
    }
  }

  Future<void> _onPickSticker() async {
    if (kPingmeeGiphyApiKey.contains('PASTE_')) {
      _toast("Sticker library is not set up yet.");
      return;
    }
    try {
      final gif = await GiphyGet.getGif(
        context: context,
        apiKey: kPingmeeGiphyApiKey,
        lang: GiphyLanguage.english,
        tabColor: Colors.black,
        debounceTimeInMilliseconds: 350,
        showGIFs: false,
        showStickers: true,
        showEmojis: false,
      );
      if (gif == null) return;
      final url = _bestGiphyUrl(gif);
      final previewUrl = _bestGiphyPreviewUrl(gif);
      if (url.isEmpty) {
        _toast("Couldn't load sticker.");
        return;
      }
      final id = (gif.id ?? "").toString();
      if (!mounted) return;
      setState(() {
        _pendingStickerUrl = url;
        _pendingStickerThumb = previewUrl.isNotEmpty ? previewUrl : url;
        _pendingStickerId = id.isNotEmpty ? id : null;
      });
    } catch (_) {
      _toast("Couldn't open sticker library.");
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<void> _onTapSend() async {
    final text = widget.controller.text;
    final clean = text.trim();
    final pendingImage = _pendingImageUrl;
    final pendingSticker = _pendingStickerUrl;

    if (clean.isEmpty &&
        pendingImage == null &&
        pendingSticker == null) {
      return;
    }

    final attachments = <CommentAttachment>[];
    if (pendingImage != null) {
      attachments.add(CommentAttachment(
        kind: "image",
        url: pendingImage,
        width: _pendingImageWidth,
        height: _pendingImageHeight,
      ));
    }
    if (pendingSticker != null) {
      attachments.add(CommentAttachment(
        kind: "sticker",
        url: pendingSticker,
        thumbUrl: _pendingStickerThumb,
        stickerId: _pendingStickerId,
        stickerSource: "giphy",
      ));
    }

    final mentions = List<String>.from(_mentionUids);

    setState(() {
      _pendingImageUrl = null;
      _pendingImageWidth = null;
      _pendingImageHeight = null;
      _pendingStickerUrl = null;
      _pendingStickerThumb = null;
      _pendingStickerId = null;
      _mentionUids.clear();
    });

    await widget.onSend(
      clean,
      mentions: mentions,
      attachments: attachments,
    );

    if (widget.controller.text.isNotEmpty) {
      widget.controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAttachment = _pendingImageUrl != null ||
        _pendingStickerUrl != null;

    // v70: AnimatedPadding lifts the entire composer (including the
    // MentionPicker stacked above the TextField) above the keyboard so
    // the picker never gets squeezed under it.
    return AnimatedPadding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasAttachment)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _AttachmentPreview(
              imageUrl: _pendingImageUrl,
              stickerUrl: _pendingStickerUrl,
              stickerThumb: _pendingStickerThumb,
              onClear: () {
                setState(() {
                  _pendingImageUrl = null;
                  _pendingImageWidth = null;
                  _pendingImageHeight = null;
                  _pendingStickerUrl = null;
                  _pendingStickerThumb = null;
                  _pendingStickerId = null;
                });
              },
            ),
          ),
        AttachmentBar(
          onTapMention: () {
            setState(() {
              _mentionPickerVisible = !_mentionPickerVisible;
              if (_mentionPickerVisible) _emojiOpen = false;
            });
            if (_mentionPickerVisible) {
              _insertAtCursor('@');
              widget.focusNode.requestFocus();
            }
          },
          onTapEmoji: () {
            setState(() {
              _emojiOpen = !_emojiOpen;
              if (_emojiOpen) _mentionPickerVisible = false;
            });
            if (_emojiOpen) {
              widget.focusNode.unfocus();
            } else {
              widget.focusNode.requestFocus();
            }
          },
          onTapImage: _showImageSourceSheet,
          onTapSticker: _onPickSticker,
          mentionOpen: _mentionPickerVisible,
          emojiOpen: _emojiOpen,
          uploading: _uploadingImage,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _onTapSend(),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.38),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF3F4F6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: widget.sending ? null : _onTapSend,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Center(
                  child: widget.sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white),
                          ),
                        )
                      : Icon(
                          PhosphorIcons.paperPlaneTilt(
                              PhosphorIconsStyle.fill),
                          color: Colors.white,
                          size: 19,
                        ),
                ),
              ),
            ),
          ],
        ),
        if (_mentionPickerVisible)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: MentionPicker(
              myUid: widget.myUid,
              commentService: widget.commentService,
              onPickMention: _onPickMention,
            ),
          ),
        if (_emojiOpen)
          SizedBox(
            height: 280,
            child: EmojiPicker(
              textEditingController: widget.controller,
              config: Config(
                height: 280,
                checkPlatformCompatibility: true,
                emojiViewConfig: const EmojiViewConfig(
                  columns: 7,
                  emojiSizeMax: 30,
                  backgroundColor: Colors.white,
                  verticalSpacing: 0,
                  horizontalSpacing: 0,
                ),
                viewOrderConfig: const ViewOrderConfig(
                  top: EmojiPickerItem.categoryBar,
                  middle: EmojiPickerItem.emojiView,
                  bottom: EmojiPickerItem.searchBar,
                ),
                categoryViewConfig: const CategoryViewConfig(
                  backgroundColor: Colors.white,
                  indicatorColor: Colors.black,
                  iconColor: Color(0xFF9CA3AF),
                  iconColorSelected: Colors.black,
                  dividerColor: Colors.transparent,
                ),
                bottomActionBarConfig: const BottomActionBarConfig(
                  backgroundColor: Colors.white,
                  buttonIconColor: Colors.black,
                ),
                searchViewConfig: const SearchViewConfig(
                  backgroundColor: Color(0xFFF3F4F6),
                  buttonIconColor: Colors.black,
                  hintText: 'Search emoji',
                ),
              ),
            ),
          ),
      ],
    ),
    );
  }
}

// ============================================================================
// v65: _AttachmentPreview — small inline preview of a staged image or
// sticker above the TextField. The user can clear it with the X button.
// ============================================================================

class _AttachmentPreview extends StatelessWidget {
  final String? imageUrl;
  final String? stickerUrl;
  final String? stickerThumb;
  final VoidCallback onClear;

  const _AttachmentPreview({
    this.imageUrl,
    this.stickerUrl,
    this.stickerThumb,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl ?? stickerUrl ?? stickerThumb;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    final isSticker = imageUrl == null;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 96),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.network(
              url,
              fit: isSticker ? BoxFit.contain : BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                child: Icon(
                  isSticker
                      ? PhosphorIcons.sticker(PhosphorIconsStyle.regular)
                      : PhosphorIcons.image(PhosphorIconsStyle.regular),
                  size: 24,
                  color: Colors.black38,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: onClear,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: Colors.black87,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// v65: GIPHY URL helpers. Copied verbatim from chat_channel_page.dart so the
// comment sticker pipeline returns the same shape the chat uses.
// ============================================================================

String _tryReadGiphyUrl(Object? Function() read) {
  final value = read()?.toString().trim() ?? '';
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  return '';
}

String _bestGiphyUrl(GiphyGif gif) {
  final dynamic g = gif;
  final candidates = [
    _tryReadGiphyUrl(() => g.images?.original?.url),
    _tryReadGiphyUrl(() => g.images?.downsized?.url),
    _tryReadGiphyUrl(() => g.images?.fixedHeight?.url),
    _tryReadGiphyUrl(() => g.images?.fixedWidth?.url),
    _tryReadGiphyUrl(() => g.images?.previewGif?.url),
  ];
  for (final url in candidates) {
    if (url.isNotEmpty) return url;
  }
  return '';
}

String _bestGiphyPreviewUrl(GiphyGif gif) {
  final dynamic g = gif;
  final candidates = [
    _tryReadGiphyUrl(() => g.images?.fixedHeightSmallStill?.url),
    _tryReadGiphyUrl(() => g.images?.fixedWidthSmallStill?.url),
    _tryReadGiphyUrl(() => g.images?.downsizedStill?.url),
    _tryReadGiphyUrl(() => g.images?.originalStill?.url),
    _tryReadGiphyUrl(() => g.images?.previewGif?.url),
  ];
  for (final url in candidates) {
    if (url.isNotEmpty) return url;
  }
  return _bestGiphyUrl(gif);
}
