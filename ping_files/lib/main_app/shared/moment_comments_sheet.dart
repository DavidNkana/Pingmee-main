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
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/main_app/shared/comment_widgets.dart';
import 'package:ping_files/theme/colors2.dart';

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

  /// Non-null when the composer is in "reply mode" for a specific parent.
  /// All replies are added with parentCommentId = this id and
  /// rootCommentId = either this id (if the parent was top-level) or the
  /// parent's own rootId.
  Comment? _replyingTo;

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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load comments.";
      });
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

  Future<void> _sendComment() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final replyParent = _replyingTo;
    final optimistic = Comment(
      id: "optimistic_${DateTime.now().millisecondsSinceEpoch}",
      userId: "",
      text: text,
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
    );

    setState(() {
      _sending = true;
      _comments = [..._comments, optimistic];
    });
    _controller.clear();

    try {
      final real = await widget.commentService.addComment(
        activityId: widget.activityId,
        text: text,
        parentCommentId: replyParent?.id,
        rootCommentId: replyParent?.rootId ?? replyParent?.id,
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

  // ------------------------------------------------------------------
  // Like + Save
  // ------------------------------------------------------------------

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
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 18),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Comments",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.brandGreen,
                              ),
                            ),
                          )
                        : _error != null
                            ? Center(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : _comments.isEmpty
                                ? Center(
                                    child: Text(
                                      "No comments yet. Start it.",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w700,
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
                                    itemCount: _comments.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (context, index) {
                                      final c = _comments[index];
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
    // Top-level row = the comment tile + a "View N replies" pill if replies
    // exist.
    final hasReplies = c.replyCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MomentCommentTile(
          comment: c,
          authorVerified:
              (widget.authorIsVerified?.call(c) ?? false) || c.authorUid == "",
          onLike: () => _toggleLike(c),
          onReply: () => _enterReplyMode(c),
          onSendToConnection: () => _onShareToConnection(c),
          onSave: () => _toggleSave(c),
          onAuthorTap: () =>
              widget.onAuthorTap?.call(c.authorUid),
          onBubbleTap: hasReplies
              ? () => widget.onOpenReplies?.call(c)
              : null,
        ),
        if (hasReplies)
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 6),
            child: GestureDetector(
              onTap: () => widget.onOpenReplies?.call(c),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18,
                    height: 1,
                    color: Colors.black.withOpacity(.18),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "View ${c.replyCount} ${c.replyCount == 1 ? "reply" : "replies"}",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
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
                      "Replying to ${replyingTo.authorName}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _composerFocus,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendComment(),
                  decoration: InputDecoration(
                    hintText: replyingTo == null
                        ? "Add a comment…"
                        : "Reply to ${replyingTo.authorName}…",
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
                onTap: _sending ? null : _sendComment,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Center(
                    child: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
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
        ],
      ),
    );
  }
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load replies.";
      });
    }
  }

  Future<void> _sendReply() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() {
      _sending = true;
    });
    _controller.clear();

    try {
      final reply = await widget.commentService.addComment(
        activityId: widget.activityId,
        text: text,
        parentCommentId: widget.rootComment.id,
        rootCommentId: widget.rootComment.id,
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

  // ------------------------------------------------------------------
  // Like / Save — same optimistic-flip pattern as the sheet
  // ------------------------------------------------------------------

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

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

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
            fontWeight: FontWeight.w800,
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
                  (widget.authorIsVerified?.call(widget.rootComment) ??
                          false) ||
                      widget.rootComment.authorUid == "",
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
            ),
          ),
          Divider(height: 1, color: Colors.black.withOpacity(.06)),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : _replies.isEmpty
                        ? Center(
                            child: Text(
                              "No replies yet.",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
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
                                authorVerified: (widget.authorIsVerified
                                            ?.call(r) ??
                                        false) ||
                                    r.authorUid == "",
                                onLike: () => _toggleLike(r),
                                onReply: () => _composerFocus.requestFocus(),
                                onSendToConnection: () =>
                                    _onShareToConnection(r),
                                onSave: () => _toggleSave(r),
                                onAuthorTap: () =>
                                    widget.onAuthorTap?.call(r.authorUid),
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
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _composerFocus,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendReply(),
              decoration: InputDecoration(
                hintText: "Reply to this thread…",
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
            onTap: _sending ? null : _sendReply,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Center(
                child: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
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
    );
  }
}
