// ============================================================================
// connection_picker_sheet.dart — the "send to a connection" picker used by
// the comments sheet and (in v54) the moment share sheet.
//
// Flow:
//   1. The caller (e.g. MomentCommentsSheet._onShareToConnection) shows this
//      sheet as a modal bottom sheet.
//   2. The sheet reads the current user's `friendIds` from
//      `users/{myUid}/friendIds` and looks up each friend's profile doc.
//   3. Tapping a friend calls CommentService.sendToConnection with the
//      comment + moment context, then invokes the parent callback
//      [onSent] with the new Stream Chat `cid`.
//   4. The parent (typically the moment's host widget) then navigates to
//      ChatChannelPage with the cid and an optional comment-preview seed.
//
// Search: a simple text filter on `fullName` / `username` for >5 friends.
// For 5 or fewer friends, search is hidden.
// ============================================================================

import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/main_app/shared/comment_widgets.dart';
import 'package:ping_files/theme/colors2.dart';

// ============================================================================
// Public API
// ============================================================================

/// Shows the connection picker as a modal bottom sheet. The [onSent]
/// callback fires when the comment has been posted to the chosen friend's
/// chat, with the Stream Chat `cid` (e.g. "messaging:dm_uid1_uid2") so the
/// caller can navigate to it.
Future<void> showCommentConnectionPicker(
  BuildContext context, {
  required String commentText,
  String? commentAuthorName,
  String? commentAuthorPhotoUrl,
  String? momentId,
  String? momentText,
  String? momentAuthorName,
  String? note,
  required CommentService commentService,
  required void Function(String cid) onSent,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ConnectionPickerSheet(
      commentText: commentText,
      commentAuthorName: commentAuthorName,
      commentAuthorPhotoUrl: commentAuthorPhotoUrl,
      momentId: momentId,
      momentText: momentText,
      momentAuthorName: momentAuthorName,
      note: note,
      commentService: commentService,
      onSent: onSent,
    ),
  );
}

// ============================================================================
// Sheet
// ============================================================================

class ConnectionPickerSheet extends StatefulWidget {
  final String commentText;
  final String? commentAuthorName;
  final String? commentAuthorPhotoUrl;
  final String? momentId;
  final String? momentText;
  final String? momentAuthorName;
  final String? note;
  final CommentService commentService;
  final void Function(String cid) onSent;

  const ConnectionPickerSheet({
    super.key,
    required this.commentText,
    required this.commentService,
    required this.onSent,
    this.commentAuthorName,
    this.commentAuthorPhotoUrl,
    this.momentId,
    this.momentText,
    this.momentAuthorName,
    this.note,
  });

  @override
  State<ConnectionPickerSheet> createState() => _ConnectionPickerSheetState();
}

class _ConnectionPickerSheetState extends State<ConnectionPickerSheet> {
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  String? _error;
  List<_Connection> _all = [];
  String? _sendingToUid;
  String? _search;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final me = FirebaseAuth.instance.currentUser;
      if (me == null) {
        setState(() {
          _loading = false;
          _error = "Not signed in.";
        });
        return;
      }

      final meDoc =
          await FirebaseFirestore.instance.collection("users").doc(me.uid).get();
      final data = meDoc.data() ?? <String, dynamic>{};
      final ids = List<String>.from(data["friendIds"] ?? const <String>[]);
      if (ids.isEmpty) {
        setState(() {
          _loading = false;
          _all = [];
        });
        return;
      }

      // Look up each friend in batches of 10 (Firestore `in` is limited
      // to 10 / 30 depending on operator). We use 10 to be safe.
      final out = <_Connection>[];
      for (var i = 0; i < ids.length; i += 10) {
        final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
        final snap = await FirebaseFirestore.instance
            .collection("users")
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final d = doc.data();
          out.add(_Connection(
            uid: doc.id,
            fullName: (d["fullName"] ?? "").toString().trim(),
            username: (d["username"] ?? "").toString().trim(),
            photoUrl: (d["photoUrl"] ?? "").toString().trim(),
            verification: d["verification"] == true,
          ));
        }
      }

      // Stable sort: alphabetical by fullName (fallback to username).
      out.sort((a, b) {
        final an = a.fullName.isNotEmpty ? a.fullName : a.username;
        final bn = b.fullName.isNotEmpty ? b.fullName : b.username;
        return an.toLowerCase().compareTo(bn.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _all = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load your connections.";
      });
    }
  }

  Future<void> _send(_Connection c) async {
    if (_sendingToUid != null) return;
    setState(() => _sendingToUid = c.uid);

    try {
      final cid = await widget.commentService.sendToConnection(
        otherUid: c.uid,
        commentText: widget.commentText,
        commentAuthorName: widget.commentAuthorName,
        commentAuthorPhotoUrl: widget.commentAuthorPhotoUrl,
        momentId: widget.momentId,
        momentText: widget.momentText,
        momentAuthorName: widget.momentAuthorName,
        note: widget.note,
      );

      if (!mounted) return;
      // Pop the sheet, then fire the callback so the parent can navigate.
      Navigator.of(context).pop();
      widget.onSent(cid);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sendingToUid = null);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text("Couldn't share the comment. Try again."),
        ),
      );
    }
  }

  List<_Connection> get _filtered {
    final q = _search?.trim().toLowerCase() ?? "";
    if (q.isEmpty) return _all;
    return _all.where((c) {
      return c.fullName.toLowerCase().contains(q) ||
          c.username.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final filtered = _filtered;
    final showSearch = _all.length > 5;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * .82,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(30)),
            ),
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
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            "Send to a connection",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 22,
                            color: Colors.black.withOpacity(.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showSearch)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _search = v),
                        decoration: InputDecoration(
                          hintText: "Search connections…",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            color: Colors.black.withOpacity(.38),
                          ),
                          prefixIcon: Icon(
                            PhosphorIcons.magnifyingGlass(
                                PhosphorIconsStyle.regular),
                            color: Colors.black54,
                            size: 18,
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF3F4F6),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  Flexible(
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
                            : filtered.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 32, vertical: 32),
                                      child: Text(
                                        _all.isEmpty
                                            ? "You don't have any connections yet. Add some from the Discover tab."
                                            : "No matches for \"${_search ?? ""}\".",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontFamily: "Nunito",
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.black.withOpacity(.55),
                                        ),
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      12,
                                    ),
                                    itemCount: filtered.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 4),
                                    itemBuilder: (context, index) {
                                      final c = filtered[index];
                                      return _buildRow(c);
                                    },
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

  Widget _buildRow(_Connection c) {
    final isLoading = _sendingToUid == c.uid;
    return InkWell(
      onTap: isLoading ? null : () => _send(c),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            _PickerAvatar(photoUrl: c.photoUrl, verified: c.verification),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    c.fullName.isNotEmpty ? c.fullName : c.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                  if (c.username.isNotEmpty)
                    Text(
                      "@${c.username}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.5),
                      ),
                    ),
                ],
              ),
            ),
            if (isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.regular),
                size: 18,
                color: Colors.black54,
              ),
          ],
        ),
      ),
    );
  }
}

class _Connection {
  final String uid;
  final String fullName;
  final String username;
  final String photoUrl;
  final bool verification;

  _Connection({
    required this.uid,
    required this.fullName,
    required this.username,
    required this.photoUrl,
    required this.verification,
  });
}

class _PickerAvatar extends StatelessWidget {
  final String photoUrl;
  final bool verified;

  const _PickerAvatar({required this.photoUrl, required this.verified});

  @override
  Widget build(BuildContext context) {
    final url = photoUrl.trim();
    Widget avatar;
    if (url.isEmpty) {
      avatar = Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: Color(0xFFEFF1F4),
          shape: BoxShape.circle,
        ),
        child: Icon(
          PhosphorIcons.user(PhosphorIconsStyle.regular),
          size: 22,
          color: Colors.black26,
        ),
      );
    } else {
      avatar = ClipOval(
        child: Image.network(
          url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 44,
            height: 44,
            color: const Color(0xFFEFF1F4),
            child: Icon(
              PhosphorIcons.user(PhosphorIconsStyle.regular),
              size: 22,
              color: Colors.black26,
            ),
          ),
        ),
      );
    }

    if (!verified) return avatar;

    return SizedBox(
      width: 50,
      height: 50,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: 3, left: 3, child: avatar),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: AppColors.brandGreen,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
