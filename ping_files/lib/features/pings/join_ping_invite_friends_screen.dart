import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/theme/colors2.dart';

enum JoinPingInviteSendResult {
  sent,
  uninvited,
  alreadyInvited,
  alreadyParticipant,
  failed,
}

class JoinPingInviteFriendRecord {
  final String uid;
  final String name;
  final String username;
  final String photoUrl;
  final bool verified;

  const JoinPingInviteFriendRecord({
    required this.uid,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.verified,
  });

  String get searchHaystack =>
      "${name.toLowerCase()} ${username.toLowerCase()}";
}

class JoinPingInviteFriendsScreen extends StatefulWidget {
  final String ownerUid;
  final String pingId;
  final String pingTitle;
  final Future<JoinPingInviteSendResult> Function(
    JoinPingInviteFriendRecord friend,
  ) onInvite;
  final Future<bool> Function(
    JoinPingInviteFriendRecord friend,
  ) onUninvite;

  const JoinPingInviteFriendsScreen({
    super.key,
    required this.ownerUid,
    required this.pingId,
    required this.pingTitle,
    required this.onInvite,
    required this.onUninvite,
  });

  @override
  State<JoinPingInviteFriendsScreen> createState() =>
      _JoinPingInviteFriendsScreenState();
}

class _JoinPingInviteFriendsScreenState
    extends State<JoinPingInviteFriendsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _busyIds = <String>{};

  bool _loading = true;
  String _query = "";
  List<JoinPingInviteFriendRecord> _friends =
      const <JoinPingInviteFriendRecord>[];

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _loadFriends();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {
      _query = _searchCtrl.text.trim().toLowerCase();
    });
  }

  Future<void> _loadFriends() async {
    setState(() => _loading = true);

    try {
      final db = FirebaseFirestore.instance;

      final friendsSnap = await db
          .collection("users")
          .doc(widget.ownerUid)
          .collection("friends")
          .get();

      final futures = friendsSnap.docs.map((friendDoc) async {
        final friendUid =
            (friendDoc.data()["friendId"] ?? "").toString().trim();
        if (friendUid.isEmpty) return null;

        final userSnap = await db.collection("users").doc(friendUid).get();
        final user = userSnap.data() ?? <String, dynamic>{};
        final verification =
            Map<String, dynamic>.from(user["verification"] ?? {});

        final fullName = (user["fullName"] ?? "Friend").toString().trim();
        final username = (user["username"] ?? "").toString().trim();
        final photoUrl = (user["photoUrl"] ?? "").toString().trim();

        return JoinPingInviteFriendRecord(
          uid: friendUid,
          name: fullName.isEmpty ? "Friend" : fullName,
          username: username,
          photoUrl: photoUrl,
          verified:
              (verification["status"] ?? "").toString().trim().toLowerCase() ==
              "verified",
        );
      }).toList();

      final records = (await Future.wait(futures))
          .whereType<JoinPingInviteFriendRecord>()
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _friends = records;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _handleToggleInvite(
    JoinPingInviteFriendRecord friend, {
    required bool alreadyInvited,
  }) async {
    if (_busyIds.contains(friend.uid)) return;

    setState(() => _busyIds.add(friend.uid));

    try {
      if (alreadyInvited) {
        final removed = await widget.onUninvite(friend);
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              removed
                  ? "Invite removed for ${friend.name}."
                  : "Couldn't remove invite.",
            ),
          ),
        );
        return;
      }

      final result = await widget.onInvite(friend);
      if (!mounted) return;

      switch (result) {
        case JoinPingInviteSendResult.sent:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("Invite sent to ${friend.name}."),
            ),
          );
          break;
        case JoinPingInviteSendResult.uninvited:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("Invite removed for ${friend.name}."),
            ),
          );
          break;
        case JoinPingInviteSendResult.alreadyInvited:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("${friend.name} was already invited."),
            ),
          );
          break;
        case JoinPingInviteSendResult.alreadyParticipant:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("${friend.name} is already in this ping."),
            ),
          );
          break;
        case JoinPingInviteSendResult.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("Couldn't send invite."),
            ),
          );
          break;
      }
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(friend.uid));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _friends.where((friend) {
      if (_query.isEmpty) return true;
      return friend.searchHaystack.contains(_query);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection("pings")
              .doc(widget.pingId)
              .collection("invites")
              .snapshots(),
          builder: (context, inviteSnap) {
            final invitedIds = <String>{};

            if (inviteSnap.hasData) {
              for (final doc in inviteSnap.data!.docs) {
                final data = doc.data();
                final status = (data["status"] ?? "")
                    .toString()
                    .trim()
                    .toLowerCase();
                if (status == "pending" || status == "sent") {
                  invitedIds.add(doc.id);
                }
              }
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          "Invite connections",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: "Search connections",
                        prefixIcon: Icon(
                          PhosphorIcons.magnifyingGlass(
                            PhosphorIconsStyle.light,
                          ),
                          size: 20,
                          color: Colors.black.withOpacity(.48),
                        ),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () => _searchCtrl.clear(),
                                icon: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(.10),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 14,
                                    color: Colors.black.withOpacity(.62),
                                  ),
                                ),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 15,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.8,
                              valueColor: AlwaysStoppedAnimation(
                                AppColors.brandGreen,
                              ),
                            ),
                          ),
                        )
                      : filtered.isEmpty
                          ? const _JoinInviteEmptyState()
                          : ListView.separated(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                              itemBuilder: (context, index) {
                                final friend = filtered[index];
                                final busy = _busyIds.contains(friend.uid);
                                final alreadyInvited =
                                    invitedIds.contains(friend.uid);

                                return _JoinInviteFriendTile(
                                  friend: friend,
                                  busy: busy,
                                  alreadyInvited: alreadyInvited,
                                  onInvite: () => _handleToggleInvite(
                                    friend,
                                    alreadyInvited: alreadyInvited,
                                  ),
                                );
                              },
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemCount: filtered.length,
                            ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _JoinInviteFriendTile extends StatelessWidget {
  final JoinPingInviteFriendRecord friend;
  final bool busy;
  final bool alreadyInvited;
  final VoidCallback? onInvite;

  const _JoinInviteFriendTile({
    required this.friend,
    required this.busy,
    required this.alreadyInvited,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = friend.username.isEmpty ? "" : "@${friend.username}";

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        children: [
          _JoinInviteAvatar(
            photoUrl: friend.photoUrl,
            fallback: friend.name,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        friend.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    if (friend.verified) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.verified_rounded,
                        size: 16,
                        color: Color(0xFF1D9BF0),
                      ),
                    ],
                  ],
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (busy)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
              ),
            )
          else
            TextButton(
              onPressed: onInvite,
              style: TextButton.styleFrom(
                backgroundColor: alreadyInvited
                    ? const Color(0xFFEDEFF2)
                    : AppColors.brandGreen,
                foregroundColor: alreadyInvited
                    ? Colors.black.withOpacity(.72)
                    : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                elevation: 0,
              ),
              child: Text(
                alreadyInvited ? "Invited" : "Invite",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  color: alreadyInvited
                      ? Colors.black.withOpacity(.72)
                      : Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _JoinInviteAvatar extends StatelessWidget {
  final String photoUrl;
  final String fallback;

  const _JoinInviteAvatar({
    required this.photoUrl,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;
    final initial =
        fallback.trim().isEmpty ? "F" : fallback.trim().characters.first;

    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brandGreen.withOpacity(.12),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: hasPhoto
          ? null
          : Center(
              child: Text(
                initial.toUpperCase(),
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
    );
  }
}

class _JoinInviteEmptyState extends StatelessWidget {
  const _JoinInviteEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.05),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: PhosphorIcon(
                  PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                  size: 26,
                  color: Colors.black.withOpacity(.60),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              "No friends found",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Try a different search or add more friends first.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.56),
              ),
            ),
          ],
        ),
      ),
    );
  }
}