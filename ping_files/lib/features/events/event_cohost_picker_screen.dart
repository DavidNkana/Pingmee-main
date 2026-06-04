import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class EventCohostPickerScreen extends StatefulWidget {
  final String eventId;
  final Color themeSolid;
  final Color themeTop;
  final Color themeBottom;

  const EventCohostPickerScreen({
    super.key,
    required this.eventId,
    required this.themeSolid,
    required this.themeTop,
    required this.themeBottom,
  });

  @override
  State<EventCohostPickerScreen> createState() => _EventCohostPickerScreenState();
}

class _EventCohostPickerScreenState extends State<EventCohostPickerScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _sending = false;
  String _search = "";

  final List<_FriendCohostItem> _friends = [];
  final Set<String> _activeHostIds = <String>{};
  final Set<String> _pendingHostIds = <String>{};

  Color get _sheetFill =>
      Color.alphaBlend(Colors.black.withOpacity(.26), widget.themeBottom.withOpacity(.84));

  Color get _sheetBorder => Colors.white.withOpacity(.10);
  Color get _panelFill => Colors.white.withOpacity(.075);
  Color get _panelBorder => Colors.white.withOpacity(.10);
  Color get _softText => Colors.white.withOpacity(.88);
  Color get _mutedText => Colors.white.withOpacity(.62);

  LinearGradient get _screenGradient => LinearGradient(
        colors: [widget.themeTop, widget.themeBottom],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _search = _searchCtrl.text.trim().toLowerCase();
      });
    });
    _boot();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() => _loading = true);

    try {
      final db = FirebaseFirestore.instance;

      final friendsSnap = await db
          .collection("users")
          .doc(uid)
          .collection("friends")
          .orderBy(FieldPath.documentId)
          .get();

      final friendIds = friendsSnap.docs
          .map((doc) {
            final data = doc.data();
            final raw = (data["friendId"] ?? "").toString().trim();
            return raw.isNotEmpty ? raw : doc.id;
          })
          .where((id) => id.isNotEmpty && id != uid)
          .toList();

      final usersById = await _fetchUsersByIds(friendIds);

      final hostsSnap = await db
          .collection("events")
          .doc(widget.eventId)
          .collection("hosts")
          .get();

      final active = <String>{};
      final pending = <String>{};

      for (final doc in hostsSnap.docs) {
        final data = doc.data();
        final hostUid = (data["uid"] ?? doc.id).toString();
        final status = (data["status"] ?? "").toString();

        if (status == "active") active.add(hostUid);
        if (status == "pending") pending.add(hostUid);
      }

      final items = <_FriendCohostItem>[];

      for (final friendId in friendIds) {
        final user = usersById[friendId];
        if (user == null) continue;

        final verification =
            Map<String, dynamic>.from(user["verification"] ?? {});
        final verified = verification["status"] == "verified";

        items.add(
          _FriendCohostItem(
            uid: friendId,
            name: (user["fullName"] ?? "Friend").toString(),
            username: (user["username"] ?? "").toString(),
            photoUrl: (user["photoUrl"] ?? "").toString(),
            verified: verified,
          ),
        );
      }

      if (!mounted) return;

      setState(() {
        _friends
          ..clear()
          ..addAll(items);
        _activeHostIds
          ..clear()
          ..addAll(active);
        _pendingHostIds
          ..clear()
          ..addAll(pending);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<Map<String, Map<String, dynamic>>> _fetchUsersByIds(
    List<String> ids,
  ) async {
    final db = FirebaseFirestore.instance;
    final out = <String, Map<String, dynamic>>{};

    for (int i = 0; i < ids.length; i += 10) {
      final chunk = ids.skip(i).take(10).toList();
      final snap = await db
          .collection("users")
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final doc in snap.docs) {
        out[doc.id] = doc.data();
      }
    }

    return out;
  }

  Future<void> _inviteCohost(_FriendCohostItem item) async {
    if (_sending) return;
    if (_activeHostIds.contains(item.uid) || _pendingHostIds.contains(item.uid)) {
      return;
    }

    final activePlusPending = _activeHostIds.length + _pendingHostIds.length - 1;
    if (activePlusPending >= 6) {
      _showSnack("You can only have 6 co-hosts.");
      return;
    }

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    setState(() => _sending = true);

    try {
      final db = FirebaseFirestore.instance;
      final eventRef = db.collection("events").doc(widget.eventId);
      final hostRef = eventRef.collection("hosts").doc(item.uid);

      await db.runTransaction((tx) async {
        final eventSnap = await tx.get(eventRef);
        final hostSnap = await tx.get(hostRef);

        if (!eventSnap.exists) {
          throw Exception("Event not found.");
        }

        final eventData = eventSnap.data() ?? {};
        final creatorId = (eventData["creatorId"] ?? "").toString();
        if (creatorId != myUid) {
          throw Exception("Only the owner can invite co-hosts.");
        }

        final coHostUids =
            List<String>.from(eventData["coHostUids"] ?? const <String>[]);

        if (hostSnap.exists) {
          final hostData = hostSnap.data() ?? {};
          final status = (hostData["status"] ?? "").toString();
          if (status == "active" || status == "pending") {
            throw Exception("This friend is already invited.");
          }
        }

        tx.set(hostRef, {
          "uid": item.uid,
          "role": "cohost",
          "status": "pending",
          "invitedBy": myUid,
          "invitedAt": FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final cover = Map<String, dynamic>.from(eventData["cover"] ?? const {});
        final eventTitle = (eventData["title"] ?? "").toString().trim();

        String coverImageUrl = "";
        if ((cover["type"] ?? "") == "uploaded") {
          coverImageUrl = (cover["imageUrl"] ?? "").toString().trim();
        }

        String coverPresetAssetPath = "";
        if ((cover["type"] ?? "") == "preset") {
          coverPresetAssetPath = (cover["presetAssetPath"] ?? "").toString().trim();
        }

        tx.set(
          db.collection("users").doc(item.uid).collection("notifications").doc(),
          {
            "type": "event_cohost_invite",
            "eventId": widget.eventId,
            "eventTitle": eventTitle,
            "eventCoverImageUrl": coverImageUrl,
            "eventCoverPresetAssetPath": coverPresetAssetPath,
            "senderUid": myUid,
            "recipientUid": item.uid,
            "title": "Co-host invite",
            "body": eventTitle.isNotEmpty
                ? 'You were invited to co-host "$eventTitle".'
                : "You were invited to co-host an event.",
            "actionState": "pending",
            "createdAt": FieldValue.serverTimestamp(),
            "read": false,
          },
        );
      });

      if (!mounted) return;
      setState(() {
        _pendingHostIds.add(item.uid);
        _sending = false;
      });

      _showSnack("Co-host invite sent.");
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _showSnack(e.toString().replaceFirst("Exception: ", ""));
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _friends.where((f) {
      if (_search.isEmpty) return true;
      return f.name.toLowerCase().contains(_search) ||
          f.username.toLowerCase().contains(_search);
    }).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(gradient: _screenGradient),
        child: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withOpacity(.02),
                        Colors.transparent,
                        Colors.black.withOpacity(.12),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      child: _buildComposerSheet(filtered),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          _circleGlassButton(
            icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Invite co-host",
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(.96),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Search your friends and send invitations",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _mutedText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerSheet(List<_FriendCohostItem> filtered) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      decoration: BoxDecoration(
        color: _sheetFill,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: _sheetBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.12),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchCard(),
          const SizedBox(height: 18),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(widget.themeSolid),
                ),
              ),
            )
          else if (filtered.isEmpty)
            _emptyCard("No friends found.")
          else
            ...filtered.map((item) {
              final active = _activeHostIds.contains(item.uid);
              final pending = _pendingHostIds.contains(item.uid);

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _panelFill,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _panelBorder),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: Colors.white.withOpacity(.12),
                      backgroundImage: item.photoUrl.isNotEmpty
                          ? NetworkImage(item.photoUrl)
                          : null,
                      child: item.photoUrl.isEmpty
                          ? Icon(
                              PhosphorIcons.user(PhosphorIconsStyle.bold),
                              color: Colors.white,
                              size: 18,
                            )
                          : null,
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
                                  item.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _softText,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              if (item.verified) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  PhosphorIcons.sealCheck(
                                    PhosphorIconsStyle.fill,
                                  ),
                                  size: 16,
                                  color: widget.themeSolid,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.username.isEmpty ? "" : "@${item.username}",
                            style: TextStyle(
                              color: _mutedText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _stateButton(
                      label: active
                          ? "Co-host"
                          : pending
                              ? "Pending"
                              : "Invite",
                      filled: !(active || pending),
                      onTap: active || pending ? null : () => _inviteCohost(item),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildSearchCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _panelFill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _panelBorder),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.bold),
            size: 18,
            color: Colors.white.withOpacity(.8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Search friends",
                hintStyle: TextStyle(
                  color: Colors.white.withOpacity(.45),
                ),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panelFill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _panelBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: _mutedText,
        ),
      ),
    );
  }

  Widget _circleGlassButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withOpacity(.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Widget _stateButton({
    required String label,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    final bg = filled ? widget.themeSolid : Colors.white.withOpacity(.10);
    final fg = Colors.white;
    final border = filled ? widget.themeSolid : Colors.white.withOpacity(.14);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _FriendCohostItem {
  final String uid;
  final String name;
  final String username;
  final String photoUrl;
  final bool verified;

  const _FriendCohostItem({
    required this.uid,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.verified,
  });
}