import 'dart:math';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/pings/ping_visibility.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/features/pings/ping_join_notifications.dart';
import 'package:ping_files/features/pings/ping_join_request_actions.dart';
import 'package:ping_files/features/pings/ping_join_notifications.dart';
import 'package:ping_files/features/pings/join_ping_invite_friends_screen.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';
import 'package:cloud_functions/cloud_functions.dart';

const String _messagesCollectionName = "messages";
const Color _manageBlack = Color(0xFF111827);
const Color _manageBlackSoft = Color(0xFFF3F4F6);

class _ManageGlassIconPill extends StatelessWidget {
  final IconData icon;
  final double size;
  final double radius;
  final double iconSize;

  const _ManageGlassIconPill({
    required this.icon,
    this.size = 42,
    this.radius = 15,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withOpacity(.070),
            Colors.black.withOpacity(.035),
          ],
        ),
        border: Border.all(
          color: Colors.black.withOpacity(.065),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, 5),
            color: Colors.black.withOpacity(.045),
          ),
        ],
      ),
      child: Center(
        child: PhosphorIcon(
          icon,
          size: iconSize,
          color: _manageBlack,
        ),
      ),
    );
  }
}

Future<void> openManagePingScreen({
  required BuildContext context,
  required String pingId,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ManagePingScreen(pingId: pingId),
    ),
  );
}

enum _PingInviteSendResult {
  sent,
  alreadyInvited,
  alreadyParticipant,
  failed,
}

class ManagePingScreen extends StatefulWidget {
  final String pingId;

  const ManagePingScreen({
    super.key,
    required this.pingId,
  });

  @override
  State<ManagePingScreen> createState() => _ManagePingScreenState();
}

class _ManagePingScreenState extends State<ManagePingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  bool _screenBusy = false;
  final Set<String> _memberBusyIds = <String>{};

  DocumentReference<Map<String, dynamic>> get _pingRef =>
      _db.collection("pings").doc(widget.pingId);

  CollectionReference<Map<String, dynamic>> get _participantsRef =>
      _pingRef.collection("participants");

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      _pingRef.collection(_messagesCollectionName);

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> get _activityRef =>
      _pingRef.collection("activity");

  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _s(dynamic v) => (v ?? "").toString().trim();

  int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  Future<bool> _logActivity({
    required String type,
    required String title,
    String? subtitle,
    Map<String, dynamic>? extra,
  }) async {
    final uid = _myUid;
    if (uid == null) return false;

    try {
      await _activityRef.add({
        "type": type,
        "title": title,
        "subtitle": subtitle ?? "",
        "actorUid": uid,
        "createdAt": FieldValue.serverTimestamp(),
        "extra": extra ?? <String, dynamic>{},
      });
      debugPrint("✅ activity logged: $type");
      return true;
    } on FirebaseException catch (e) {
      debugPrint("❌ activity log failed: ${e.code} ${e.message}");
      return false;
    } catch (e) {
      debugPrint("❌ activity log failed: $e");
      return false;
    }
  }

  bool _b(dynamic v) => v == true;

  DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  Map<String, dynamic> _map(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  void _goToTab(int index) {
    HapticFeedback.selectionClick();
    _tabController.animateTo(index);
  }

  String _formatCount(int value) {
    if (value < 1000) return value.toString();

    if (value < 1000000) {
      final k = value / 1000;
      if (value % 1000 == 0) return "${k.toStringAsFixed(0)}k";
      return k >= 10 ? "${k.toStringAsFixed(0)}k" : "${k.toStringAsFixed(1)}k";
    }

    final m = value / 1000000;
    if (value % 1000000 == 0) return "${m.toStringAsFixed(0)}m";
    return m >= 10 ? "${m.toStringAsFixed(0)}m" : "${m.toStringAsFixed(1)}m";
  }

  String _two(int n) => n.toString().padLeft(2, "0");

  String _dateShort(DateTime d) {
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];
    return "${d.day} ${months[d.month - 1]} ${d.year}";
  }

  String _relative(DateTime d) {
    final now = DateTime.now();
    final diff = d.difference(now);
    final past = diff.isNegative;
    final secs = diff.inSeconds.abs();

    if (secs < 60) return past ? "just now" : "in a moment";

    final mins = (secs / 60).floor();
    if (mins < 60) return past ? "${mins}m ago" : "in ${mins}m";

    final hours = (mins / 60).floor();
    if (hours < 24) return past ? "${hours}h ago" : "in ${hours}h";

    final days = (hours / 24).floor();
    return past ? "${days}d ago" : "in ${days}d";
  }

  String _remainingText(DateTime? endsAt) {
    if (endsAt == null) return "No end time";

    final now = DateTime.now();
    if (now.isAfter(endsAt)) return "Ended";

    final diff = endsAt.difference(now);
    final hours = diff.inHours;
    final mins = diff.inMinutes.remainder(60);

    if (hours <= 0) return "${mins}m left";
    return "${hours}h ${mins}m left";
  }

  String _locationLine(Map<String, dynamic> ping) {
    final location = _map(ping["location"]);
    final placeName = _s(location["placeName"]);
    final meetingPoint = _s(location["meetingPoint"]);

    if (placeName.isNotEmpty && meetingPoint.isNotEmpty) {
      return "$placeName · $meetingPoint";
    }
    if (meetingPoint.isNotEmpty) return meetingPoint;
    if (placeName.isNotEmpty) return placeName;
    return "Nearby";
  }

  int _messageCountFromPing(Map<String, dynamic> ping) {
    return _i(
      ping["messageCount"] ??
          ping["chatMessageCount"] ??
          ping["messagesCount"] ??
          ping["chatCount"],
    );
  }

  ({IconData icon, Color color}) _getCategoryStyle(String category) {
    final c = category.toLowerCase().trim();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.light),
        color: const Color(0xFF6C5CE7),
      );
    } else if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.light),
        color: const Color(0xFFE74C3C),
      );
    } else if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.light),
        color: const Color(0xFF9B59B6),
      );
    } else if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.light),
        color: const Color(0xFF3498DB),
      );
    } else if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.light),
        color: const Color(0xFFE67E22),
      );
    } else if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.light),
        color: const Color(0xFF1ABC9C),
      );
    } else if (c.contains("event")) {
      return (
        icon: PhosphorIcons.ticket(PhosphorIconsStyle.light),
        color: const Color(0xFFF39C12),
      );
    } else if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.light),
        color: const Color(0xFFE91E63),
      );
    } else if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.siren(PhosphorIconsStyle.light),
        color: const Color(0xFFFFB800),
      );
    } else if (c.contains("food")) {
      return (
        icon: PhosphorIcons.hamburger(PhosphorIconsStyle.light),
        color: const Color(0xFFFF6B6B),
      );
    } else if (c.contains("music")) {
      return (
        icon: PhosphorIcons.musicNotes(PhosphorIconsStyle.light),
        color: const Color(0xFFFF1744),
      );
    } else if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.light),
        color: const Color(0xFF2196F3),
      );
    }

    final customColors = [
      const Color(0xFF00BCD4),
      const Color(0xFF009688),
      const Color(0xFF8BC34A),
      const Color(0xFFFF5722),
      const Color(0xFF673AB7),
      const Color(0xFFE91E63),
    ];

    final customColor = customColors[category.hashCode.abs() % customColors.length];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
      color: customColor,
    );
  }

  Future<void> _openInviteFriendsScreen(Map<String, dynamic> ping) async {
    final myUid = _myUid;
    if (myUid == null) {
      _toast("You must be logged in.", isError: true);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _InviteFriendsScreen(
          ownerUid: myUid,
          pingId: widget.pingId,
          pingTitle: _s(ping["title"]).isEmpty ? "Untitled ping" : _s(ping["title"]),
          onInvite: (friend) => _sendPingInvite(
            ping: ping,
            friend: friend,
          ),
        ),
      ),
    );
  }

  Future<_PingInviteSendResult> _sendPingInvite({
    required Map<String, dynamic> ping,
    required _InviteFriendRecord friend,
  }) async {
    final myUid = _myUid;
    if (myUid == null) return _PingInviteSendResult.failed;

    try {
      final participantSnap = await _participantsRef.doc(friend.uid).get();
      if (participantSnap.exists) {
        final participantData = participantSnap.data() ?? <String, dynamic>{};
        final status = _s(participantData["status"]).toLowerCase();

        if (status == "approved" || status == "pending") {
          return _PingInviteSendResult.alreadyParticipant;
        }
      }

      final pingInviteRef = _pingRef.collection("invites").doc(friend.uid);
      final existingInviteSnap = await pingInviteRef.get();

      if (existingInviteSnap.exists) {
        final existingData = existingInviteSnap.data() ?? <String, dynamic>{};
        final existingStatus = _s(existingData["status"]).toLowerCase();

        if (existingStatus == "pending" || existingStatus == "sent") {
          return _PingInviteSendResult.alreadyInvited;
        }
      }

      final senderSnap = await _db.collection("users").doc(myUid).get();
      final senderData = senderSnap.data() ?? <String, dynamic>{};

      final senderName = _s(
        senderData["fullName"] ??
            senderData["displayName"] ??
            senderData["name"],
      );
      final senderUsername = _s(senderData["username"]);
      final senderPhotoUrl = _s(
        senderData["photoUrl"] ??
            senderData["profilePhotoUrl"] ??
            senderData["avatarUrl"],
      );

      final pingTitle = _s(ping["title"]).isEmpty ? "Untitled ping" : _s(ping["title"]);
      final pingCategory = _s(ping["category"]);
      final pingPrivacy = _s(ping["privacy"]).isEmpty ? "public" : _s(ping["privacy"]);
      final locationLine = _locationLine(ping);

      final recipientInviteRef = _db
          .collection("users")
          .doc(friend.uid)
          .collection("ping_invites")
          .doc(widget.pingId);

      final recipientNotifRef = _db
          .collection("users")
          .doc(friend.uid)
          .collection("notifications")
          .doc();

      final now = FieldValue.serverTimestamp();

      final payload = <String, dynamic>{
        "pingId": widget.pingId,
        "recipientUid": friend.uid,
        "senderUid": myUid,
        "senderName": senderName,
        "senderUsername": senderUsername,
        "senderPhotoUrl": senderPhotoUrl,
        "pingTitle": pingTitle,
        "pingCategory": pingCategory,
        "pingPrivacy": pingPrivacy,
        "locationLine": locationLine,
        "status": "pending",
        "source": "friend_picker",
        "createdAt": now,
        "updatedAt": now,
      };

      final notificationPayload = <String, dynamic>{
        "type": "ping_invite",
        "senderUid": myUid,
        "senderName": senderName,
        "senderUsername": senderUsername,
        "senderPhotoUrl": senderPhotoUrl,
        "pingId": widget.pingId,
        "pingTitle": pingTitle,
        "pingCategory": pingCategory,
        "pingPrivacy": pingPrivacy,
        "locationLine": locationLine,
        "title": "Ping invite",
        "body": pingTitle.isNotEmpty
            ? '$senderName invited you to "$pingTitle".'
            : "$senderName invited you to a ping.",
        "read": false,
        "status": "pending",
        "source": "friend_picker",
        "createdAt": now,
      };

      final batch = _db.batch();

      batch.set(pingInviteRef, payload);
      batch.set(recipientInviteRef, payload);
      batch.set(recipientNotifRef, notificationPayload);

      await batch.commit();

      await _logActivity(
        type: "friend_invited",
        title: "Friend invited",
        subtitle: "Sent an invite to ${friend.name}",
        extra: {
          "friendUid": friend.uid,
          "pingId": widget.pingId,
        },
      );

      return _PingInviteSendResult.sent;
    } catch (e) {
      debugPrint("❌ send ping invite failed: $e");
      return _PingInviteSendResult.failed;
    }
  }

  Future<void> _resolveJoinRequestNotifications({
    required String memberUid,
    required String actionState,
  }) async {
    final myUid = _myUid;
    if (myUid == null) return;

    final notifSnap = await _db
        .collection("users")
        .doc(myUid)
        .collection("notifications")
        .where("type", isEqualTo: "ping_join_request")
        .limit(50)
        .get();

    if (notifSnap.docs.isEmpty) return;

    final batch = _db.batch();

    for (final doc in notifSnap.docs) {
      final data = doc.data();
      if (_s(data["pingId"]) != widget.pingId) continue;
      if (_s(data["requestUid"]) != memberUid) continue;

      batch.set(doc.reference, {
        "actionState": actionState,
        "resolvedAt": FieldValue.serverTimestamp(),
        "read": true,
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }

  Future<void> _syncParticipantCount() async {
    try {
      final approvedSnap = await _participantsRef
          .where("status", isEqualTo: "approved")
          .get();

      await _pingRef.set({
        "participantCount": approvedSnap.docs.length,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("❌ sync participantCount failed: $e");
    }
  }

  Future<void> _showCapacitySheet(Map<String, dynamic> ping) async {
    final currentMembers = _i(ping["participantCount"]);
    final currentMax = _i(ping["maxMembers"]);

    final maxMembersCtrl = TextEditingController(
      text: currentMax > 0 ? currentMax.toString() : "",
    );

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);

        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: media.size.height * .58,
              child: _BottomSheetFrame(
                child: Column(
                  children: [
                    const _SheetHandle(),
                    const SizedBox(height: 10),
                    const _SheetTitle(
                      title: "Join limit",
                      subtitle: "Control how many people can be inside this ping.",
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          children: [
                            _SheetField(
                              label: "Max members",
                              controller: maxMembersCtrl,
                              hint: "Leave empty for unlimited",
                              maxLines: 1,
                              keyboardType: TextInputType.number,
                            ),
                            const SizedBox(height: 10),
                            _SurfaceCard(
                              child: Text(
                                currentMax > 0
                                    ? "$currentMembers/$currentMax people are currently inside."
                                    : "$currentMembers people are currently inside. No limit is set.",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                  color: Colors.black.withOpacity(.64),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _PrimaryActionButton(
                              label: "Save limit",
                              icon: PhosphorIcons.floppyDisk(
                                PhosphorIconsStyle.fill,
                              ),
                              onTap: () async {
                                final raw = maxMembersCtrl.text.trim();
                                final parsed = raw.isEmpty ? null : int.tryParse(raw);

                                if (raw.isNotEmpty && (parsed == null || parsed < 1)) {
                                  _toast("Max members must be at least 1.", isError: true);
                                  return;
                                }

                                if (parsed != null && parsed < currentMembers) {
                                  _toast(
                                    "You already have $currentMembers people inside. Limit cannot be lower than that.",
                                    isError: true,
                                  );
                                  return;
                                }

                                try {
                                  final payload = <String, dynamic>{
                                    "updatedAt": FieldValue.serverTimestamp(),
                                  };

                                  if (parsed == null) {
                                    payload["maxMembers"] = FieldValue.delete();
                                  } else {
                                    payload["maxMembers"] = parsed;
                                  }

                                  await _pingRef.set(payload, SetOptions(merge: true));

                                  await _logActivity(
                                    type: "capacity_changed",
                                    title: "Join limit updated",
                                    subtitle: parsed == null
                                        ? "Join limit removed"
                                        : "Join limit set to $parsed",
                                    extra: {
                                      "maxMembers": parsed,
                                      "participantCount": currentMembers,
                                    },
                                  );

                                  if (!mounted) return;
                                  Navigator.pop(sheetContext, true);
                                } catch (_) {
                                  _toast("Couldn't update join limit.", isError: true);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (saved == true) {
      _toast("Join limit updated.");
    }
  }

  Future<void> _denyPendingRequest(String uid) async {
    await _setMemberBusy(uid, true);

    try {
      final myUid = _myUid;
      if (myUid == null) {
        _toast("You must be logged in.", isError: true);
        return;
      }

      final didDeny = await denyPingJoinRequest(
        pingId: widget.pingId,
        memberUid: uid,
      );

      if (!didDeny) {
        _toast("Request already handled.");
        return;
      }

      await Future.wait([
        sendPingJoinDecisionNotification(
          recipientUid: uid,
          actorUid: myUid,
          pingId: widget.pingId,
          approved: false,
        ),
        _resolveJoinRequestNotifications(
          memberUid: uid,
          actionState: "denied",
        ),
      ]);

      _toast("Request denied.");
      await _logActivity(
        type: "member_denied",
        title: "Request denied",
        subtitle: "A join request was denied",
        extra: {
          "memberUid": uid,
        },
      );
    } catch (_) {
      _toast("Couldn't deny request.", isError: true);
    } finally {
      await _setMemberBusy(uid, false);
    }
  }

  Future<void> _setScreenBusy(bool value) async {
    if (!mounted) return;
    setState(() => _screenBusy = value);
  }

  Future<void> _setMemberBusy(String uid, bool value) async {
    if (!mounted) return;
    setState(() {
      if (value) {
        _memberBusyIds.add(uid);
      } else {
        _memberBusyIds.remove(uid);
      }
    });
  }

  Future<void> _approveMember(String uid) async {
    await _setMemberBusy(uid, true);

    try {
      final myUid = _myUid;
      if (myUid == null) {
        _toast("You must be logged in.", isError: true);
        return;
      }

      final didApprove = await approvePingJoinRequest(
        pingId: widget.pingId,
        memberUid: uid,
      );

      if (!didApprove) {
        _toast("Request already handled.");
        return;
      }

      await Future.wait([
        sendPingJoinDecisionNotification(
          recipientUid: uid,
          actorUid: myUid,
          pingId: widget.pingId,
          approved: true,
        ),
        _resolveJoinRequestNotifications(
          memberUid: uid,
          actionState: "approved",
        ),
      ]);

      _toast("Member approved.");
      await _logActivity(
        type: "member_approved",
        title: "Member approved",
        subtitle: "A pending request was accepted",
        extra: {
          "memberUid": uid,
        },
      );
    } catch (e) {
      final msg = e.toString();

      if (msg.contains("ping-full-on-approve")) {
        final pingSnap = await _pingRef.get();
        final pingData = pingSnap.data() ?? <String, dynamic>{};
        final maxMembers = _i(pingData["maxMembers"]);

        await _showCapacityReachedDialog(
          maxMembers: maxMembers > 0 ? maxMembers : 0,
        );
      } else {
        _toast("Couldn't approve member.", isError: true);
      }
    } finally {
      await _setMemberBusy(uid, false);
    }
  }

  Future<void> _toggleMute(_ParticipantEntry member) async {
    if (member.uid.isEmpty || member.isCreator) return;

    await _setMemberBusy(member.uid, true);

    try {
      await _participantsRef.doc(member.uid).set({
        "uid": member.uid,
        "mutedInChat": !member.mutedInChat,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _toast(member.mutedInChat ? "Member unmuted." : "Member muted.");
      await _logActivity(
        type: member.mutedInChat ? "member_unmuted" : "member_muted",
        title: member.mutedInChat ? "Member unmuted" : "Member muted",
        subtitle: "Chat permissions were updated",
        extra: {
          "memberUid": member.uid,
        },
      );
    } catch (_) {
      _toast("Couldn't update mute state.", isError: true);
    } finally {
      await _setMemberBusy(member.uid, false);
    }
  }

  Future<void> _removeMember(_ParticipantEntry member) async {
    if (member.uid.isEmpty || member.isCreator) return;

    await _setMemberBusy(member.uid, true);

    bool removedApprovedMember = false;

    try {
      final myUid = _myUid;
      if (myUid == null) {
        _toast("You must be logged in.", isError: true);
        return;
      }

      await _db.runTransaction((tx) async {
        final partRef = _participantsRef.doc(member.uid);
        final userRef = _db.collection("users").doc(member.uid);

        final snap = await tx.get(partRef);
        if (!snap.exists) return;

        final data = snap.data() ?? {};
        final status = _s(data["status"]).toLowerCase();
        final wasApproved = status == "approved";

        tx.delete(partRef);

        if (wasApproved) {
          removedApprovedMember = true;

          tx.update(_pingRef, {
            "participantCount": FieldValue.increment(-1),
          });

          tx.set(userRef, {
            "activePingId": FieldValue.delete(),
            "activePingStatus": FieldValue.delete(),
            "activePingJoinedAt": FieldValue.delete(),
          }, SetOptions(merge: true));
        }
      });

      await _syncParticipantCount();

      if (removedApprovedMember) {
        try {
          await PingmeeStreamChatService.instance.removePingChatMember(
            pingId: widget.pingId,
            memberUid: member.uid,
          );
        } catch (e) {
          debugPrint('❌ remove member from Stream ping chat failed: $e');
        }
      }

      if (removedApprovedMember) {
        await sendPingMemberRemovedNotification(
          recipientUid: member.uid,
          actorUid: myUid,
          pingId: widget.pingId,
        );
      }

      _toast("Member removed.");
      await _logActivity(
        type: "member_removed",
        title: "Member removed",
        subtitle: "A participant was removed from the ping",
        extra: {
          "memberUid": member.uid,
        },
      );
    } catch (_) {
      _toast("Couldn't remove member.", isError: true);
    } finally {
      await _setMemberBusy(member.uid, false);
    }
  }

  Future<void> _updatePrivacy(String privacy) async {
    await _setScreenBusy(true);

    try {
      await _pingRef.set({
        "privacy": privacy,
        ...PingVisibility.buildPingAudienceFields(privacy: privacy),
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _logActivity(
        type: "privacy_changed",
        title: "Visibility changed",
        subtitle: "Ping is now $privacy",
        extra: {
          "privacy": privacy,
        },
      );

      _toast("Visibility updated.");
    } catch (_) {
      _toast("Couldn't update visibility.", isError: true);
    } finally {
      await _setScreenBusy(false);
    }
  }

  Future<void> _setReadOnly(bool value) async {
    try {
      await _pingRef.set({
        "chatConfig": {
          "readOnly": value,
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _logActivity(
        type: value ? "chat_read_only_on" : "chat_read_only_off",
        title: value ? "Chat set to read only" : "Read only disabled",
        subtitle: value
            ? "Only announcements should happen now"
            : "Members can chat normally again",
      );

      _toast(value ? "Chat is now read only." : "Read only disabled.");
    } catch (_) {
      _toast("Couldn't update chat mode.", isError: true);
    }
  }

  Future<void> _reviveChat() async {
    await _setScreenBusy(true);

    try {
      final result = await FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('reactivatePingChat').call({
        'pingId': widget.pingId,
      });

      debugPrint('✅ reactivatePingChat result: ${result.data}');

      await _logActivity(
        type: 'chat_reactivated_local',
        title: 'Chat revived',
        subtitle: 'This expired ping chat was reopened',
      );

      _toast('Chat revived. Members can talk again.');
    } on FirebaseFunctionsException catch (e) {
      debugPrint('❌ reactivatePingChat failed: ${e.code} ${e.message}');
      _toast(
        e.message ?? "Couldn't revive chat.",
        isError: true,
      );
    } catch (e) {
      debugPrint('❌ reactivatePingChat failed: $e');
      _toast("Couldn't revive chat.", isError: true);
    } finally {
      await _setScreenBusy(false);
    }
  }

  Future<void> _setSlowMode(int seconds) async {
    try {
      await _pingRef.set({
        "chatConfig": {
          "slowModeSeconds": seconds,
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _logActivity(
        type: "slow_mode_changed",
        title: seconds == 0 ? "Slow mode disabled" : "Slow mode updated",
        subtitle: seconds == 0
            ? "Chat speed is back to normal"
            : "Members must wait $seconds seconds between messages",
        extra: {
          "seconds": seconds,
        },
      );

      _toast(seconds == 0 ? "Slow mode disabled." : "Slow mode updated.");
    } catch (_) {
      _toast("Couldn't update slow mode.", isError: true);
    }
  }

  Future<void> _showCapacityReachedDialog({
    required int maxMembers,
  }) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            "Ping is full",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            "You cannot approve more people because your join limit is set to $maxMembers. "
            "Increase the limit in Ping Settings if you want to allow more members.",
            style: const TextStyle(
              fontFamily: "Nunito",
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                "Okay",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _savePinnedMessage(String message) async {
    try {
      await _pingRef.set({
        "chatConfig": {
          "pinnedMessage": message.trim(),
          "pinnedUpdatedAt": FieldValue.serverTimestamp(),
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _logActivity(
        type: "pinned_message_saved",
        title: "Pinned message updated",
        subtitle: message.trim().isEmpty
            ? "Pinned message was cleared"
            : "Host updated the pinned message",
        extra: {
          "hasMessage": message.trim().isNotEmpty,
        },
      );

      _toast("Pinned message saved.");
    } catch (_) {
      _toast("Couldn't save pinned message.", isError: true);
    }
  }

  String _generateInviteCode(String title) {
    final clean = title
        .toUpperCase()
        .replaceAll(RegExp(r"[^A-Z0-9]"), "")
        .trim();

    final prefix = clean.isEmpty
        ? "PING"
        : clean.length >= 4
            ? clean.substring(0, 4)
            : clean.padRight(4, "X");

    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    final r = Random();
    final suffix = List.generate(
      4,
      (_) => chars[r.nextInt(chars.length)],
    ).join();

    return "$prefix-$suffix";
  }

  // Future<String> _ensureInviteCode(Map<String, dynamic> ping) async {
  //   final invite = _map(ping["invite"]);
  //   final existing = _s(invite["code"]);
  //   if (existing.isNotEmpty) return existing;

  //   final title = _s(ping["title"]);
  //   final code = _generateInviteCode(title);

  //   await _pingRef.set({
  //     "invite": {
  //       "code": code,
  //       "enabled": true,
  //       "uses": _i(invite["uses"]),
  //       "createdAt": FieldValue.serverTimestamp(),
  //     },
  //     "updatedAt": FieldValue.serverTimestamp(),
  //   }, SetOptions(merge: true));

  //   return code;
  // }

  // Future<void> _copyInviteLink(Map<String, dynamic> ping) async {
  //   try {
  //     final code = await _ensureInviteCode(ping);
  //     final link = Uri.https("pingmee.io", "/j/$code").toString();

  //     await Clipboard.setData(ClipboardData(text: link));

  //     await _logActivity(
  //       type: "invite_copied",
  //       title: "Invite link copied",
  //       subtitle: "Host copied the join link",
  //       extra: {
  //         "code": code,
  //         "link": link,
  //       },
  //     );

  //     _toast("Invite link copied.");
  //   } catch (_) {
  //     _toast("Couldn't copy invite link.", isError: true);
  //   }
  // }

  Future<void> _toggleInviteEnabled(bool enabled) async {
    try {
      await _pingRef.set({
        "invite": {
          "enabled": enabled,
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _logActivity(
        type: enabled ? "invite_enabled" : "invite_disabled",
        title: enabled ? "Invite link enabled" : "Invite link disabled",
        subtitle: enabled
            ? "People can join with the link again"
            : "Invite link access was turned off",
      );

      _toast(enabled ? "Invite link enabled." : "Invite link disabled.");
    } catch (_) {
      _toast("Couldn't update invite link.", isError: true);
    }
  }

  Future<void> _showExtendPingSheet(Map<String, dynamic> ping) async {
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);

        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: _BottomSheetFrame(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _SheetHandle(),
                    const SizedBox(height: 10),
                    const _SheetTitle(
                      title: "Extend ping",
                      subtitle: "Add more time without rebuilding the room. You can bring it back even after it ends if you want!",
                    ),
                    const SizedBox(height: 18),
                    _ActionRowButton(
                      icon: PhosphorIcons.clockCounterClockwise(
                        PhosphorIconsStyle.light,
                      ),
                      title: "Add 30 minutes",
                      subtitle: "Useful for short hangouts that are still alive.",
                      onTap: () => Navigator.pop(sheetContext, 30),
                    ),
                    const SizedBox(height: 10),
                    _ActionRowButton(
                      icon: PhosphorIcons.clock(PhosphorIconsStyle.light),
                      title: "Add 1 hour",
                      subtitle: "Good default when the ping is active.",
                      onTap: () => Navigator.pop(sheetContext, 60),
                    ),
                    const SizedBox(height: 10),
                    _ActionRowButton(
                      icon: PhosphorIcons.hourglassHigh(PhosphorIconsStyle.light),
                      title: "Add 2 hours",
                      subtitle: "Use when this becomes a real session.",
                      onTap: () => Navigator.pop(sheetContext, 120),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (result == null) return;

    try {
      final currentEndsAt = _ts(ping["endsAt"]) ?? DateTime.now();
      final base = currentEndsAt.isAfter(DateTime.now())
          ? currentEndsAt
          : DateTime.now();

      final next = base.add(Duration(minutes: result));

      await _pingRef.update({
        "endsAt": Timestamp.fromDate(next),
        "updatedAt": FieldValue.serverTimestamp(),
      });

      await _logActivity(
        type: "ping_extended",
        title: "Ping extended",
        subtitle: "Host added $result minutes",
        extra: {
          "minutesAdded": result,
          "newEndsAt": Timestamp.fromDate(next),
        },
      );

      _toast("Ping extended by $result minutes.");
    } catch (_) {
      _toast("Couldn't extend ping.", isError: true);
    }
  }

  Future<void> _showEditDetailsSheet(Map<String, dynamic> ping) async {
    final titleCtrl = TextEditingController(text: _s(ping["title"]));
    final descCtrl = TextEditingController(text: _s(ping["description"]));
    final maxMembersCtrl = TextEditingController(
      text: _i(ping["maxMembers"]) > 0 ? _i(ping["maxMembers"]).toString() : "",
    );

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);

        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: media.size.height * .88,
              child: _BottomSheetFrame(
                child: Column(
                  children: [
                    const _SheetHandle(),
                    const SizedBox(height: 10),
                    const _SheetTitle(
                      title: "Edit ping details",
                      subtitle: "Keep the room accurate and trustworthy.",
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          children: [
                            _SheetField(
                              label: "Title",
                              controller: titleCtrl,
                              hint: "Playing FIFA – top floor lounge",
                              maxLines: 1,
                              maxLength: 60,
                            ),
                            const SizedBox(height: 14),
                            _SheetField(
                              label: "Description",
                              controller: descCtrl,
                              hint:
                                  "What is happening, who should join, and what to expect.",
                              maxLines: 4,
                              maxLength: 180,
                            ),
                          
                            const SizedBox(height: 18),
                            _PrimaryActionButton(
                              label: "Save changes",
                              icon: PhosphorIcons.floppyDisk(
                                PhosphorIconsStyle.fill,
                              ),
                              onTap: () async {
                                final title = titleCtrl.text.trim();
                                final desc = descCtrl.text.trim();
                                final maxText = maxMembersCtrl.text.trim();

                                if (title.isEmpty) {
                                  _toast("Title is required.", isError: true);
                                  return;
                                }

                                final parsedMax = int.tryParse(maxText);
                                if (maxText.isNotEmpty &&
                                    (parsedMax == null || parsedMax < 1)) {
                                  _toast(
                                    "Max members must be at least 1.",
                                    isError: true,
                                  );
                                  return;
                                }

                                final approvedSnap = await _participantsRef
                                    .where("status", isEqualTo: "approved")
                                    .get();

                                final liveApprovedCount = approvedSnap.docs.length;

                                if (parsedMax != null && parsedMax < liveApprovedCount) {
                                  _toast(
                                    "You already have $liveApprovedCount people inside. Limit cannot be lower than that.",
                                    isError: true,
                                  );
                                  return;
                                }

                                try {
                                  await _pingRef.set({
                                    "title": title,
                                    "title_lc": title.toLowerCase(),
                                    "description": desc,
                                    "maxMembers": parsedMax,
                                    "updatedAt": FieldValue.serverTimestamp(),
                                  }, SetOptions(merge: true));

                                  await _logActivity(
                                    type: "details_updated",
                                    title: "Ping details updated",
                                    subtitle: "Title, description, or limits changed",
                                    extra: {
                                      "title": title,
                                      "maxMembers": parsedMax,
                                    },
                                  );

                                  if (!mounted) return;
                                  Navigator.pop(sheetContext, true);
                                } catch (_) {
                                  _toast("Couldn't save changes.", isError: true);
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (saved == true) {
      _toast("Ping updated.");
    }
    
  }

  Future<void> _confirmEndPing() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text(
            "End ping early?",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
            ),
          ),
          content: const Text(
            "This ends the ping now, disables invite access, and marks the room as closed.",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w400,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                "Cancel",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.65),
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB42318),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                "End ping",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    await _setScreenBusy(true);

    try {
      await _pingRef.set({
        "status": "ended",
        "endedEarly": true,
        "endedAt": FieldValue.serverTimestamp(),
        "endsAt": Timestamp.fromDate(DateTime.now()),
        "invite": {
          "enabled": false,
        },
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _toast("Ping ended.");
      await _logActivity(
        type: "ping_ended",
        title: "Ping ended early",
        subtitle: "Host closed the room before timer expiry",
      );
    } catch (_) {
      _toast("Couldn't end ping.", isError: true);
    } finally {
      await _setScreenBusy(false);
    }
  }

  void _toast(String message, {bool isError = false}) {
    final messenger = _messenger;
    if (!mounted || messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: isError
              ? const Color(0xFFB42318)
              : const Color(0xFF111827),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: Text(
            message,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final myUid = _myUid;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _pingRef.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFFF6F7FB),
            body: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
                ),
              ),
            ),
          );
        }

        final doc = snap.data!;
        if (!doc.exists || doc.data() == null) {
          return Scaffold(
            backgroundColor: const Color(0xFFF6F7FB),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          color: AppColors.brandGreen.withOpacity(.10),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: PhosphorIcon(
                            PhosphorIcons.warningCircle(
                              PhosphorIconsStyle.fill,
                            ),
                            size: 30,
                            color: AppColors.brandGreen,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "This ping no longer exists",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "The source data is gone.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w400,
                          color: Colors.black.withOpacity(.60),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _PrimaryActionButton(
                        label: "Go back",
                        icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.fill),
                        onTap: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final ping = doc.data()!;
        final creatorId = _s(ping["creatorId"]);
        final isCreator = myUid != null && myUid == creatorId;

        final pingCreatedAt = _ts(ping["createdAt"]) ?? _ts(ping["createdAtLocal"]);

        final title = _s(ping["title"]).isEmpty ? "Untitled ping" : _s(ping["title"]);
        final desc = _s(ping["description"]);
        final participantCount = _i(ping["participantCount"]);
        final messageCount = _messageCountFromPing(ping);
        final endsAt = _ts(ping["endsAt"]);
        final privacy = _s(ping["privacy"]).isEmpty ? "public" : _s(ping["privacy"]);
        final status = _s(ping["status"]).isEmpty ? "active" : _s(ping["status"]);
        final invite = _map(ping["invite"]);
        final inviteCode = _s(invite["code"]);
        final inviteUses = _i(invite["uses"]);
        final inviteEnabled = !_map(ping["invite"]).containsKey("enabled")
            ? true
            : _b(invite["enabled"]);

        final chatConfig = _map(ping["chatConfig"]);
        final readOnly = _b(chatConfig["readOnly"]);
        final slowModeSeconds = _i(chatConfig["slowModeSeconds"]);
        final pinnedMessage = _s(chatConfig["pinnedMessage"]);
        final category = _s(ping["category"]);
        final categoryStyle = _getCategoryStyle(category);

        if (!isCreator) {
          return Scaffold(
            backgroundColor: const Color(0xFFF6F7FB),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _IconGhostButton(
                      icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.light),
                      onTap: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827).withOpacity(.06),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: PhosphorIcon(
                          PhosphorIcons.shieldWarning(PhosphorIconsStyle.fill),
                          size: 30,
                          color: const Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "Creator access only",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "This dashboard belongs to the host.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                        color: Colors.black.withOpacity(.62),
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _participantsRef.snapshots(),
          builder: (context, participantsSnap) {
            final liveMemberCount = participantsSnap.hasData
                ? () {
                    final entries = participantsSnap.data!.docs
                        .map((d) => _ParticipantEntry.fromDoc(d))
                        .toList();

                    final approvedCount =
                        entries.where((e) => !e.isPending).length;

                    final hasCreatorEntry = creatorId.isNotEmpty &&
                        entries.any((e) => e.uid == creatorId);

                    return approvedCount + (hasCreatorEntry || creatorId.isEmpty ? 0 : 1);
                  }()
                : max(participantCount, creatorId.isNotEmpty ? 1 : 0);

            return Scaffold(
              backgroundColor: const Color(0xFFF6F7FB),
              body: Stack(
                children: [
                  SafeArea(
                    bottom: false,
                    child: NestedScrollView(
                      physics: const BouncingScrollPhysics(),
                      headerSliverBuilder: (context, innerBoxIsScrolled) {
                        return [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      _IconGhostButton(
                                        icon: PhosphorIcons.caretLeft(
                                          PhosphorIconsStyle.light,
                                        ),
                                        onTap: () => Navigator.pop(context),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              "Manage Ping dashboard",
                                              style: TextStyle(
                                                fontFamily: "Nunito",
                                                fontSize: 18,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.black87,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      _TopPill(
                                        icon: PhosphorIcons.sparkle(
                                          PhosphorIconsStyle.fill,
                                        ),
                                        label: "Owner",
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  _ManageHeroCard(
                                    title: title,
                                    description: desc,
                                    locationLine: _locationLine(ping),
                                    remaining: _remainingText(endsAt),
                                    members: liveMemberCount,
                                    messages: messageCount,
                                    status: status,
                                    accentColor: categoryStyle.color,
                                    accentIcon: categoryStyle.icon,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                              ),
                            ),
                          ),
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _PinnedTabBarDelegate(
                              height: 62,
                              child: Container(
                                color: const Color(0xFFF6F7FB),
                                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                                alignment: Alignment.center,
                                child: _OwnerTabStrip(controller: _tabController),
                              ),
                            ),
                          ),
                        ];
                      },
                      body: TabBarView(
                        controller: _tabController,
                        children: [
                          _OverviewTab(
                            pingId: widget.pingId,
                            ping: ping,
                            liveMemberCount: liveMemberCount,
                            formatCount: _formatCount,
                            formatDate: _dateShort,
                            relative: _relative,
                            onOpenMembers: () => _goToTab(1),
                            onInviteFriends: () => _openInviteFriendsScreen(ping),
                            onExtendPing: () => _showExtendPingSheet(ping),
                            onEditDetails: () => _showEditDetailsSheet(ping),
                            memberBusyIds: _memberBusyIds,
                            onApproveRequest: _approveMember,
                            onDenyRequest: _denyPendingRequest,
                          ),
                          _MembersTab(
                            pingId: widget.pingId,
                            participantsRef: _participantsRef,
                            memberBusyIds: _memberBusyIds,
                            onApprove: _approveMember,
                            onMuteToggle: _toggleMute,
                            onRemove: _removeMember,
                            formatCount: _formatCount,
                            relative: _relative,
                            creatorId: creatorId,
                            creatorJoinedAt: pingCreatedAt,
                          ),
                          _ChatTab(
                            messagesRef: _messagesRef,
                            activityRef: _activityRef,
                            participantsRef: _participantsRef,
                            ping: ping,
                            readOnly: readOnly,
                            slowModeSeconds: slowModeSeconds,
                            pinnedMessage: pinnedMessage,
                            onReadOnlyChanged: _setReadOnly,
                            onSlowModeChanged: _setSlowMode,
                            onSavePinnedMessage: _savePinnedMessage,
                            onReviveChat: _reviveChat,
                            relative: _relative,
                          ),
                          _SettingsTab(
                            ping: ping,
                            privacy: privacy,
                            screenBusy: _screenBusy,
                            onPrivacyChanged: _updatePrivacy,
                            onInviteFriends: () => _openInviteFriendsScreen(ping),
                            onEditDetails: () => _showEditDetailsSheet(ping),
                            onEditCapacity: () => _showCapacitySheet(ping),
                            onExtendPing: () => _showExtendPingSheet(ping),
                            onEndPing: _confirmEndPing,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_screenBusy)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Colors.black.withOpacity(.08),
                          child: const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor: AlwaysStoppedAnimation(
                                  AppColors.brandGreen,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final String pingId;
  final Map<String, dynamic> ping;
  final String Function(int) formatCount;
  final String Function(DateTime) formatDate;
  final String Function(DateTime) relative;
  final VoidCallback onOpenMembers;
  final VoidCallback onInviteFriends;
  final VoidCallback onExtendPing;
  final VoidCallback onEditDetails;
  final int liveMemberCount;
  final Set<String> memberBusyIds;
  final Future<void> Function(String uid) onApproveRequest;
  final Future<void> Function(String uid) onDenyRequest;

  const _OverviewTab({
    required this.pingId,
    required this.ping,
    required this.formatCount,
    required this.formatDate,
    required this.relative,
    required this.onOpenMembers,
    required this.onInviteFriends,
    required this.onExtendPing,
    required this.onEditDetails,
    required this.liveMemberCount,
    required this.memberBusyIds,
    required this.onApproveRequest,
    required this.onDenyRequest,
  });

  String _s(dynamic v) => (v ?? "").toString().trim();

  int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final viewCount = _i(ping["viewCount"]);
    final messageCount = _i(
      ping["messageCount"] ??
          ping["chatMessageCount"] ??
          ping["messagesCount"] ??
          ping["chatCount"],
    );
    final endsAt = _ts(ping["endsAt"]);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel("Ping health"),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  icon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                  label: "Members",
                  value: formatCount(liveMemberCount),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(
                  icon: PhosphorIcons.chatCircleText(
                    PhosphorIconsStyle.fill,
                  ),
                  label: "Messages",
                  value: formatCount(messageCount),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(
                  icon: PhosphorIcons.eye(PhosphorIconsStyle.fill),
                  label: "Views",
                  value: formatCount(viewCount),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SurfaceCard(
            child: Row(
              children: [
                _ManageGlassIconPill(
                  icon: PhosphorIcons.timer(PhosphorIconsStyle.fill),
                  size: 48,
                  radius: 16,
                  iconSize: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Time remaining",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        endsAt == null
                            ? "No timer set"
                            : (DateTime.now().isAfter(endsAt)
                                ? "Ended"
                                : "${relative(endsAt)} · ${formatDate(endsAt)}"),
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Quick actions"),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            shrinkWrap: true,
            childAspectRatio: 0.96,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _QuickActionTile(
                icon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                title: "Manage members",
                subtitle: "Approve, mute, remove",
                onTap: onOpenMembers,
              ),
              _QuickActionTile(
                icon: PhosphorIcons.userPlus(PhosphorIconsStyle.fill),
                title: "Invite connections",
                subtitle: "Send direct invites fast",
                // inviteStyle: true,
                onTap: onInviteFriends,
              ),
              _QuickActionTile(
                icon: PhosphorIcons.clockClockwise(
                  PhosphorIconsStyle.fill,
                ),
                title: "Extend ping",
                subtitle: "Add 30m, 1h, or 2h",
                onTap: onExtendPing,
              ),
              _QuickActionTile(
                icon: PhosphorIcons.notePencil(PhosphorIconsStyle.fill),
                title: "Edit details",
                subtitle: "Title, description, limits",
                onTap: onEditDetails,
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Activity feed"),
          const SizedBox(height: 10),
          _ActivityFeed(
            pingId: pingId,
            viewCount: viewCount,
            relative: relative,
            memberBusyIds: memberBusyIds,
            onApproveRequest: onApproveRequest,
            onDenyRequest: onDenyRequest,
          ),
        ],
      ),
    );
  }
}

class _MembersTab extends StatelessWidget {
  final String pingId;
  final CollectionReference<Map<String, dynamic>> participantsRef;
  final Set<String> memberBusyIds;
  final Future<void> Function(String uid) onApprove;
  final Future<void> Function(_ParticipantEntry member) onMuteToggle;
  final Future<void> Function(_ParticipantEntry member) onRemove;
  final String Function(int) formatCount;
  final String Function(DateTime) relative;

  final String creatorId;
  final DateTime? creatorJoinedAt;

  const _MembersTab({
    required this.pingId,
    required this.participantsRef,
    required this.memberBusyIds,
    required this.onApprove,
    required this.onMuteToggle,
    required this.onRemove,
    required this.formatCount,
    required this.relative,
    required this.creatorId,
    required this.creatorJoinedAt,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: participantsRef.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
              ),
            ),
          );
        }

        final docs = snap.data!.docs;
        final participants = docs
            .map((d) => _ParticipantEntry.fromDoc(d))
            .toList();

        // Force the host to always exist visually in Members tab.
        if (creatorId.isNotEmpty) {
          final existingCreatorIndex =
              participants.indexWhere((e) => e.uid == creatorId);

          if (existingCreatorIndex == -1) {
            participants.add(
              _ParticipantEntry.host(
                uid: creatorId,
                joinedAt: creatorJoinedAt,
              ),
            );
          } else {
            final existing = participants[existingCreatorIndex];
            participants[existingCreatorIndex] = _ParticipantEntry(
              uid: existing.uid,
              role: "creator",
              status: existing.status.isEmpty ? "approved" : existing.status,
              mutedInChat: false,
              joinedAt: existing.joinedAt ?? creatorJoinedAt,
            );
          }
        }

        participants.sort((a, b) {
          if (a.isCreator && !b.isCreator) return -1;
          if (!a.isCreator && b.isCreator) return 1;

          final at = a.joinedAt?.millisecondsSinceEpoch ?? 0;
          final bt = b.joinedAt?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });

        final pending = participants.where((e) => e.isPending).toList();
        final approved = participants.where((e) => !e.isPending).toList();
        final muted = approved.where((e) => e.mutedInChat).toList();

        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionLabel("People management"),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      icon: PhosphorIcons.users(PhosphorIconsStyle.fill),
                      label: "Joined",
                      value: formatCount(approved.length),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricTile(
                      icon: PhosphorIcons.hourglassSimpleMedium(
                        PhosphorIconsStyle.fill,
                      ),
                      label: "Pending",
                      value: formatCount(pending.length),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MetricTile(
                      icon: PhosphorIcons.speakerSlash(
                        PhosphorIconsStyle.fill,
                      ),
                      label: "Muted",
                      value: formatCount(muted.length),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (pending.isNotEmpty) ...[
                const _SectionLabel("Pending requests"),
                const SizedBox(height: 10),
                ...pending.map(
                  (member) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _MemberCard(
                      member: member,
                      busy: memberBusyIds.contains(member.uid),
                      relative: relative,
                      pendingMode: true,
                      onApprove: () => onApprove(member.uid),
                      onMuteToggle: () {},
                      onRemove: () => onRemove(member),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              const _SectionLabel("Members"),
              const SizedBox(height: 10),
              if (approved.isEmpty)
                _SurfaceCard(
                  child: Text(
                    "No active members yet.",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.62),
                    ),
                  ),
                )
              else
                ...approved.map(
                  (member) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _MemberCard(
                      member: member,
                      busy: memberBusyIds.contains(member.uid),
                      relative: relative,
                      pendingMode: false,
                      onApprove: null,
                      onMuteToggle: member.isCreator
                          ? null
                          : () => onMuteToggle(member),
                      onRemove: member.isCreator ? null : () => onRemove(member),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatTab extends StatefulWidget {
  final CollectionReference<Map<String, dynamic>> messagesRef;
  final CollectionReference<Map<String, dynamic>> activityRef;
  final CollectionReference<Map<String, dynamic>> participantsRef;
  final Map<String, dynamic> ping;
  final bool readOnly;
  final int slowModeSeconds;
  final String pinnedMessage;
  final Future<void> Function(bool value) onReadOnlyChanged;
  final Future<void> Function(int seconds) onSlowModeChanged;
  final Future<void> Function(String message) onSavePinnedMessage;
  final String Function(DateTime) relative;
  final Future<void> Function() onReviveChat;

  const _ChatTab({
    required this.messagesRef,
    required this.activityRef,
    required this.participantsRef,
    required this.ping,
    required this.readOnly,
    required this.slowModeSeconds,
    required this.pinnedMessage,
    required this.onReadOnlyChanged,
    required this.onSlowModeChanged,
    required this.onSavePinnedMessage,
    required this.relative,
    required this.onReviveChat,
  });

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatRevivedCard extends StatelessWidget {
  const _ChatRevivedCard();

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Row(
        children: [
          _ManageGlassIconPill(
            icon: PhosphorIcons.chatCircleDots(
              PhosphorIconsStyle.fill,
            ),
            size: 46,
            radius: 16,
            iconSize: 22,
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chat revived',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'This expired ping chat is open again. The ping itself is still expired.',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.7,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'Revived',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.brandGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviveChatCard extends StatelessWidget {
  const _ReviveChatCard({
    required this.onTap,
  });

  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Row(
        children: [
          _ManageGlassIconPill(
            icon: PhosphorIcons.chatCircleDots(
              PhosphorIconsStyle.fill,
            ),
            size: 46,
            radius: 16,
            iconSize: 22,
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Revive chat',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Reopen this expired ping chat without making the ping live again.',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.7,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          Material(
            color: const Color(0xFF111827),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Text(
                  'Revive',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatTabState extends State<_ChatTab> {
  late final TextEditingController _pinCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _pinCtrl = TextEditingController(text: widget.pinnedMessage);
  }

  @override
  void didUpdateWidget(covariant _ChatTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinnedMessage != widget.pinnedMessage &&
        widget.pinnedMessage != _pinCtrl.text) {
      _pinCtrl.text = widget.pinnedMessage;
    }
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    setState(() => _saving = true);
    try {
      await widget.onSavePinnedMessage(_pinCtrl.text);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _s(dynamic v) => (v ?? "").toString().trim();

  DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  bool _b(dynamic v) => v == true;

  Map<String, dynamic> _map(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  bool get _pingExpired {
    final status = _s(widget.ping['status']).toLowerCase();

    if (status == 'ended' ||
        status == 'expired' ||
        status == 'cancelled') {
      return true;
    }

    final endsAt = _ts(widget.ping['endsAt']);
    if (endsAt != null && !endsAt.isAfter(DateTime.now())) {
      return true;
    }

    return false;
  }

  bool get _chatWasRevived {
    final chatConfig = _map(widget.ping['chatConfig']);
    final chatLifecycle = _map(widget.ping['chatLifecycle']);

    return _b(chatConfig['manuallyReopened']) ||
        _b(chatLifecycle['manuallyReopened']);
  }

  bool get _chatWasClosed {
    final chatConfig = _map(widget.ping['chatConfig']);
    final chatLifecycle = _map(widget.ping['chatLifecycle']);

    final explicitlyClosed = widget.readOnly ||
        _b(chatConfig['readOnly']) ||
        _b(chatConfig['autoArchived']) ||
        _b(chatLifecycle['readOnly']) ||
        _b(chatLifecycle['autoArchived']);

    if (explicitlyClosed) return true;

    // If the creator revived the chat, old expiry timestamps should no longer
    // make the UI show "Revive" again.
    if (_chatWasRevived) return false;

    final chatReadOnlyAt = _ts(widget.ping['chatReadOnlyAt']);
    final chatAutoArchiveAt = _ts(widget.ping['chatAutoArchiveAt']);
    final now = DateTime.now();

    final readOnlyByTime =
        chatReadOnlyAt != null && !chatReadOnlyAt.isAfter(now);

    final archivedByTime =
        chatAutoArchiveAt != null && !chatAutoArchiveAt.isAfter(now);

    return readOnlyByTime || archivedByTime;
  }

  @override
  Widget build(BuildContext context) {
    const slowModes = [0, 15, 30, 60];

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel("Chat controls"),
            const SizedBox(height: 10),

            if (_chatWasRevived) ...[
              const _ChatRevivedCard(),
              const SizedBox(height: 12),
            ] else if (_chatWasClosed) ...[
              _ReviveChatCard(
                onTap: widget.onReviveChat,
              ),
              const SizedBox(height: 12),
            ],

            _SurfaceCard(
            child: Column(
              children: [
                _SettingSwitchRow(
                  title: "Read only mode",
                  subtitle: "Let the creator broadcast without reply noise.",
                  value: widget.readOnly,
                  onChanged: widget.onReadOnlyChanged,
                ),
                const SizedBox(height: 12),
                Container(
                  height: 1,
                  color: Colors.black.withOpacity(.06),
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Slow mode",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Use this when chat gets spammy or chaotic.",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w400,
                      color: Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: slowModes.map((seconds) {
                    final selected = widget.slowModeSeconds == seconds;
                    final label = seconds == 0 ? "Off" : "${seconds}s";
                    return _PillChoice(
                      label: label,
                      selected: selected,
                      onTap: () => widget.onSlowModeChanged(seconds),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Pinned message"),
          const SizedBox(height: 10),
          _SurfaceCard(
            child: Column(
              children: [
                TextField(
                  controller: _pinCtrl,
                  maxLines: 4,
                  maxLength: 160,
                  buildCounter: (
                    context, {
                    required int currentLength,
                    required bool isFocused,
                    required int? maxLength,
                  }) {
                    return null;
                  },
                  decoration: InputDecoration(
                    hintText: "Set the vibe, share the rules, or drop meetup instructions.",
                    filled: true,
                    fillColor: const Color(0xFFF4F6F8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: _MiniActionButton(
                    label: _saving ? "Saving..." : "Save pinned message",
                    icon: PhosphorIcons.pushPin(PhosphorIconsStyle.fill),
                    onTap: _saving ? null : _savePin,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Latest chat activity"),
          const SizedBox(height: 10),
          _LatestChatActivityPanel(
            activityRef: widget.activityRef,
            participantsRef: widget.participantsRef,
            relative: widget.relative,
          ),
        ],
      ),
    );
  }
}

DateTime? _chatActivityTs(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

String _chatActivityUserName(Map<String, dynamic>? data) {
  final d = data ?? <String, dynamic>{};

  final fullName = (d["fullName"] ?? "").toString().trim();
  final displayName = (d["displayName"] ?? "").toString().trim();
  final name = (d["name"] ?? "").toString().trim();

  final firstName = (d["firstName"] ?? "").toString().trim();
  final lastName = (d["lastName"] ?? "").toString().trim();

  final combined = [firstName, lastName]
      .where((part) => part.isNotEmpty)
      .join(" ")
      .trim();

  if (fullName.isNotEmpty) return fullName;
  if (displayName.isNotEmpty) return displayName;
  if (name.isNotEmpty) return name;
  if (combined.isNotEmpty) return combined;

  return "Someone";
}

class _ChatActivityItem {
  const _ChatActivityItem({
    required this.type,
    required this.nameUid,
    required this.createdAt,
    required this.subtitle,
    required this.icon,
  });

  final String type;
  final String nameUid;
  final DateTime? createdAt;
  final String subtitle;
  final IconData icon;

  bool get hasTime => createdAt != null;

  String titleFor(String name) {
    final safeName = name.trim().isEmpty ? "Someone" : name.trim();

    switch (type) {
      case "member_joined_chat":
        return "$safeName joined the chat";

      case "ping_huddle_started":
        return "$safeName started a huddle";

      case "pinned_message_saved":
        return "$safeName updated the pinned message";

      case "chat_read_only_on":
        return "$safeName enabled read-only mode";

      case "chat_read_only_off":
        return "$safeName disabled read-only mode";

      case "slow_mode_changed":
        return "$safeName updated slow mode";

      case "member_muted":
        return "$safeName muted a member";

      case "member_unmuted":
        return "$safeName unmuted a member";

      case "member_removed":
        return "$safeName removed a member";

      default:
        return "$safeName changed chat settings";
    }
  }

  static bool _isChatRelevant(String type) {
    return type == "ping_huddle_started" ||
        type == "pinned_message_saved" ||
        type == "chat_read_only_on" ||
        type == "chat_read_only_off" ||
        type == "slow_mode_changed" ||
        type == "member_muted" ||
        type == "member_unmuted" ||
        type == "member_removed";
  }

  static IconData _iconFor(String type) {
    switch (type) {
      case "member_joined_chat":
        return PhosphorIcons.userPlus(PhosphorIconsStyle.fill);

      case "ping_huddle_started":
        return PhosphorIcons.videoCamera(PhosphorIconsStyle.fill);

      case "pinned_message_saved":
        return PhosphorIcons.pushPin(PhosphorIconsStyle.fill);

      case "chat_read_only_on":
      case "chat_read_only_off":
        return PhosphorIcons.megaphone(PhosphorIconsStyle.fill);

      case "slow_mode_changed":
        return PhosphorIcons.timer(PhosphorIconsStyle.fill);

      case "member_muted":
      case "member_unmuted":
        return PhosphorIcons.speakerSlash(PhosphorIconsStyle.fill);

      case "member_removed":
        return PhosphorIcons.userMinus(PhosphorIconsStyle.fill);

      default:
        return PhosphorIcons.chatCircleText(PhosphorIconsStyle.fill);
    }
  }

  static _ChatActivityItem? fromActivityDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();

    final type = (data["type"] ?? "").toString().trim();
    if (!_isChatRelevant(type)) return null;

    final actorUid = (data["actorUid"] ?? "").toString().trim();

    return _ChatActivityItem(
      type: type,
      nameUid: actorUid,
      createdAt: _chatActivityTs(data["createdAt"]),
      subtitle: (data["subtitle"] ?? "").toString().trim(),
      icon: _iconFor(type),
    );
  }

  static _ChatActivityItem? fromParticipantDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();

    final status = (data["status"] ?? "").toString().trim().toLowerCase();

    final approved = status == "approved" ||
        status == "active" ||
        status == "joined" ||
        status == "member";

    if (!approved) return null;

    final uid = (data["uid"] ?? doc.id).toString().trim();
    if (uid.isEmpty) return null;

    final joinedAt = _chatActivityTs(
      data["joinedAt"] ??
          data["approvedAt"] ??
          data["createdAt"] ??
          data["updatedAt"],
    );

    if (joinedAt == null) return null;

    return _ChatActivityItem(
      type: "member_joined_chat",
      nameUid: uid,
      createdAt: joinedAt,
      subtitle: "They can now see and send messages in this ping chat.",
      icon: _iconFor("member_joined_chat"),
    );
  }
}

class _LatestChatActivityPanel extends StatelessWidget {
  const _LatestChatActivityPanel({
    required this.activityRef,
    required this.participantsRef,
    required this.relative,
  });

  final CollectionReference<Map<String, dynamic>> activityRef;
  final CollectionReference<Map<String, dynamic>> participantsRef;
  final String Function(DateTime date) relative;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: activityRef
          .orderBy("createdAt", descending: true)
          .limit(30)
          .snapshots(),
      builder: (context, activitySnap) {
        if (activitySnap.hasError) {
          return _SurfaceCard(
            child: Text(
              "Couldn't read chat activity.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.62),
              ),
            ),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: participantsRef.snapshots(),
          builder: (context, participantsSnap) {
            if (!activitySnap.hasData && !participantsSnap.hasData) {
              return const _SurfaceCard(
                child: SizedBox(
                  height: 80,
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation(
                          AppColors.brandGreen,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            final activityItems = (activitySnap.data?.docs ?? [])
                .map(_ChatActivityItem.fromActivityDoc)
                .whereType<_ChatActivityItem>()
                .toList();

            final joinedItems = (participantsSnap.data?.docs ?? [])
                .map(_ChatActivityItem.fromParticipantDoc)
                .whereType<_ChatActivityItem>()
                .toList();

            final items = <_ChatActivityItem>[
              ...activityItems,
              ...joinedItems,
            ]..sort((a, b) {
                final at = a.createdAt?.millisecondsSinceEpoch ?? 0;
                final bt = b.createdAt?.millisecondsSinceEpoch ?? 0;
                return bt.compareTo(at);
              });

            final visible = items.take(8).toList();

            if (visible.isEmpty) {
              return _SurfaceCard(
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.04),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: PhosphorIcon(
                          PhosphorIcons.chatCircleText(
                            PhosphorIconsStyle.light,
                          ),
                          size: 18,
                          color: Colors.black.withOpacity(.60),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "Chat activity will appear here once people join, huddle, or update chat controls.",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                          color: Colors.black.withOpacity(.62),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                for (int i = 0; i < visible.length; i++) ...[
                  _ChatActivityRow(
                    item: visible[i],
                    relative: relative,
                  ),
                  if (i != visible.length - 1) const SizedBox(height: 8),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _ChatActivityRow extends StatelessWidget {
  const _ChatActivityRow({
    required this.item,
    required this.relative,
  });

  final _ChatActivityItem item;
  final String Function(DateTime date) relative;

  Future<Map<String, dynamic>?> _loadUser() async {
    final uid = item.nameUid.trim();
    if (uid.isEmpty) return null;

    final snap = await FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .get();

    return snap.data();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _loadUser(),
      builder: (context, snap) {
        final name = _chatActivityUserName(snap.data);
        final time = item.createdAt == null ? "" : relative(item.createdAt!);

        return _SurfaceCard(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            children: [
              _ManageGlassIconPill(
                icon: item.icon,
                size: 42,
                radius: 14,
                iconSize: 19,
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.titleFor(name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.8,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                        height: 1.2,
                      ),
                    ),

                    if (item.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.4,
                          fontWeight: FontWeight.w400,
                          height: 1.25,
                          color: Colors.black.withOpacity(.56),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              if (time.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  time,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 11.6,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.38),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SettingsTab extends StatelessWidget {
  final Map<String, dynamic> ping;
  final String privacy;
  final bool screenBusy;
  final Future<void> Function(String privacy) onPrivacyChanged;
  final VoidCallback onInviteFriends;
  final VoidCallback onEditDetails;
  final VoidCallback onExtendPing;
  final VoidCallback onEndPing;
  final VoidCallback onEditCapacity;

  const _SettingsTab({
    required this.ping,
    required this.privacy,
    required this.screenBusy,
    required this.onPrivacyChanged,
    required this.onInviteFriends,
    required this.onEditDetails,
    required this.onExtendPing,
    required this.onEndPing,
    required this.onEditCapacity,
  });

  String _privacyLabel(String value) {
    final v = value.toLowerCase();
    if (v.contains("friends")) return "Friends";
    if (v.contains("verified")) return "Verified";
    return "Public";
  }

  int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    // final link = inviteCode.isEmpty
    //     ? "Tap copy to generate"
    //     : Uri.https("pingmee.io", "/j/$inviteCode").toString();

    final participantCount = _i(ping["participantCount"]);
    final maxMembers = _i(ping["maxMembers"]);
    final capacitySubtitle = maxMembers > 0
        ? "$participantCount/$maxMembers people inside"
        : "Unlimited joiners right now";    

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel("Visibility"),
          const SizedBox(height: 10),
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Current: ${_privacyLabel(privacy)}",
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Change who can see and join this ping while it is live.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    height: 1.35,
                    color: Colors.black.withOpacity(.60),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PillChoice(
                      label: "Public",
                      selected: privacy.toLowerCase() == "public",
                      onTap: () => onPrivacyChanged("public"),
                    ),
                    _PillChoice(
                      label: "Verified",
                      selected: privacy.toLowerCase() == "verified",
                      onTap: () => onPrivacyChanged("verified"),
                    ),
                    _PillChoice(
                      label: "Friends",
                      selected: privacy.toLowerCase() == "friends",
                      onTap: () => onPrivacyChanged("friends"),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Invites"),
          const SizedBox(height: 10),
          _ActionRowButton(
            icon: PhosphorIcons.userPlus(PhosphorIconsStyle.fill),
            title: "Invite connections",
            subtitle: "Send direct invites to your connections.",
            // inviteStyle: true,
            onTap: onInviteFriends,
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Ping controls"),
          const SizedBox(height: 10),
          _ActionRowButton(
            icon: PhosphorIcons.notePencil(PhosphorIconsStyle.fill),
            title: "Edit ping details",
            subtitle: "Title, description, limits, and accuracy.",
            onTap: onEditDetails,
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 10),
          _ActionRowButton(
            icon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
            title: "Join limit",
            subtitle: capacitySubtitle,
            onTap: onEditCapacity,
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 10),
          _ActionRowButton(
            icon: PhosphorIcons.clockClockwise(PhosphorIconsStyle.fill),
            title: "Extend ping",
            subtitle: "Give the room more life without recreating it.",
            onTap: onExtendPing,
          ),
          const SizedBox(height: 24),
          const _SectionLabel("Danger zone"),
          const SizedBox(height: 10),
          _DangerCard(
            title: "End ping early",
            subtitle: "Close the room now and disable invite access.",
            onTap: onEndPing,
          ),
        ],
      ),
    );
  }
}

class _ActivityFeed extends StatelessWidget {
  final String pingId;
  final int viewCount;
  final String Function(DateTime) relative;
  final Set<String> memberBusyIds;
  final Future<void> Function(String uid) onApproveRequest;
  final Future<void> Function(String uid) onDenyRequest;

  const _ActivityFeed({
    required this.pingId,
    required this.viewCount,
    required this.relative,
    required this.memberBusyIds,
    required this.onApproveRequest,
    required this.onDenyRequest,
  });

  DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  String _s(dynamic v) => (v ?? "").toString().trim();

  Map<String, dynamic> _map(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  String _displayNameFromUser(Map<String, dynamic> data) {
    final fullName = _s(data["fullName"]);
    if (fullName.isNotEmpty) return fullName;

    final username = _s(data["username"]);
    if (username.isNotEmpty) return "@$username";

    return "Someone";
  }

  _ActivityItem _itemFromActivityDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, String> namesByUid,
    Set<String> pendingUids,
  ) {
    final data = doc.data();
    final type = _s(data["type"]);
    final title = _s(data["title"]);
    final subtitle = _s(data["subtitle"]);
    final actorUid = _s(data["actorUid"]);
    final createdAt = _ts(data["createdAt"]);
    final extra = _map(data["extra"]);
    final memberUid = _s(extra["memberUid"]);

    final actorName = namesByUid[actorUid] ?? "Host";

    if (type == "join_request_received") {
      final displayName = namesByUid[memberUid] ?? namesByUid[actorUid] ?? "Someone";
      return _ActivityItem(
        icon: PhosphorIcons.hourglassSimpleMedium(PhosphorIconsStyle.fill),
        title: "$displayName requested to join",
        subtitle: createdAt == null ? "Recently" : relative(createdAt),
        color: const Color(0xFF4F46E5),
        sortTime: createdAt,
        memberUid: memberUid,
        showRequestActions: memberUid.isNotEmpty && pendingUids.contains(memberUid),
      );
    }

    IconData icon;
    Color color;

    switch (type) {
      case "invite_copied":
        icon = PhosphorIcons.copy(PhosphorIconsStyle.fill);
        color = const Color(0xFF0EA5E9);
        break;
      case "privacy_changed":
        icon = PhosphorIcons.eye(PhosphorIconsStyle.fill);
        color = const Color(0xFF8B5CF6);
        break;
      case "member_approved":
        icon = PhosphorIcons.checkCircle(PhosphorIconsStyle.fill);
        color = AppColors.brandGreen;
        break;
      case "member_removed":
      case "member_denied":
        icon = PhosphorIcons.xCircle(PhosphorIconsStyle.fill);
        color = const Color(0xFFB42318);
        break;
      default:
        icon = PhosphorIcons.sparkle(PhosphorIconsStyle.fill);
        color = Colors.black54;
    }

    return _ActivityItem(
      icon: icon,
      title: title.isEmpty ? "$actorName did something" : title,
      subtitle: createdAt == null
          ? (subtitle.isEmpty ? "Recently" : subtitle)
          : relative(createdAt),
      color: color,
      sortTime: createdAt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final participantsStream = FirebaseFirestore.instance
      .collection("pings")
      .doc(pingId)
      .collection("participants")
      .snapshots();

    final messagesStream = FirebaseFirestore.instance
        .collection("pings")
        .doc(pingId)
        .collection(_messagesCollectionName)
        .orderBy("createdAt", descending: true)
        .limit(3)
        .snapshots();

    final activityStream = FirebaseFirestore.instance
        .collection("pings")
        .doc(pingId)
        .collection("activity")
        .orderBy("createdAt", descending: true)
        .limit(8)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: participantsStream,
      builder: (context, partsSnap) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: messagesStream,
          builder: (context, msgSnap) {
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: activityStream,
              builder: (context, activitySnap) {
                final partDocs = partsSnap.data?.docs ?? const [];
                final msgDocs = msgSnap.data?.docs ?? const [];
                final activityDocs = activitySnap.data?.docs ?? const [];

                final uidSet = <String>{};

                for (final d in partDocs) {
                  final data = d.data();
                  final status = _s(data["status"]).toLowerCase();
                  final role = _s(data["role"]).toLowerCase();
                  final uid = _s(data["uid"]);

                  if (status == "pending") continue;
                  if (role == "creator") continue;
                  if (uid.isNotEmpty) uidSet.add(uid);
                }

                for (final d in msgDocs) {
                  final data = d.data();
                  final senderName = _s(
                    data["senderName"] ?? data["displayName"] ?? data["username"],
                  );
                  final senderUid = _s(data["senderId"] ?? data["uid"]);

                  if (senderName.isEmpty && senderUid.isNotEmpty) {
                    uidSet.add(senderUid);
                  }
                }

                for (final d in activityDocs) {
                  final data = d.data();
                  final actorUid = _s(data["actorUid"]);
                  if (actorUid.isNotEmpty) uidSet.add(actorUid);
                }

                final uidList = uidSet.take(10).toList();

                if (uidList.isEmpty) {
                  return _buildFeed(
                    namesByUid: const {},
                    partDocs: partDocs,
                    msgDocs: msgDocs,
                    activityDocs: activityDocs,
                  );
                }

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection("users")
                      .where(FieldPath.documentId, whereIn: uidList)
                      .snapshots(),
                  builder: (context, usersSnap) {
                    final namesByUid = <String, String>{};

                    if (usersSnap.hasData) {
                      for (final doc in usersSnap.data!.docs) {
                        namesByUid[doc.id] = _displayNameFromUser(doc.data());
                      }
                    }

                    return _buildFeed(
                      namesByUid: namesByUid,
                      partDocs: partDocs,
                      msgDocs: msgDocs,
                      activityDocs: activityDocs,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildFeed({
    required Map<String, String> namesByUid,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> partDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> msgDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> activityDocs,
  }) {
    final items = <_ActivityItem>[];
    final pendingUids = <String>{};

    for (final d in partDocs) {
      final data = d.data();
      final status = _s(data["status"]).toLowerCase();
      final role = _s(data["role"]).toLowerCase();
      final uid = _s(data["uid"]);
      final joinedAt = _ts(data["joinedAt"]);

      if (status == "pending" && uid.isNotEmpty) {
        pendingUids.add(uid);
        continue;
      }

      if (role == "creator") continue;

      final displayName = namesByUid[uid] ?? (uid.isEmpty ? "Someone" : uid);

      items.add(
        _ActivityItem(
          icon: PhosphorIcons.handWaving(PhosphorIconsStyle.fill),
          title: "$displayName joined",
          subtitle: joinedAt == null ? "Recently" : relative(joinedAt),
          color: AppColors.brandGreen,
          sortTime: joinedAt,
        ),
      );
    }

    for (final d in msgDocs) {
      final data = d.data();
      final senderUid = _s(data["senderId"] ?? data["uid"]);
      final sender = _s(
        data["senderName"] ??
            data["displayName"] ??
            data["username"] ??
            namesByUid[senderUid] ??
            "Someone",
      );
      final createdAt = _ts(data["createdAt"]);

      items.add(
        _ActivityItem(
          icon: PhosphorIcons.chatCircleDots(PhosphorIconsStyle.fill),
          title: "$sender sent a message",
          subtitle: createdAt == null ? "Recently" : relative(createdAt),
          color: const Color(0xFF6366F1),
          sortTime: createdAt,
        ),
      );
    }

    for (final d in activityDocs) {
      items.add(_itemFromActivityDoc(d, namesByUid, pendingUids));
    }

    if (viewCount > 0) {
      items.add(
        _ActivityItem(
          icon: PhosphorIcons.eye(PhosphorIconsStyle.fill),
          title: "$viewCount people viewed the ping",
          subtitle: "Awareness is not commitment",
          color: const Color(0xFFF59E0B),
          sortTime: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      );
    }

    items.sort((a, b) {
      final at = a.sortTime?.millisecondsSinceEpoch ?? 0;
      final bt = b.sortTime?.millisecondsSinceEpoch ?? 0;
      return bt.compareTo(at);
    });

    final shown = items.take(6).toList();

    if (shown.isEmpty) {
      return _SurfaceCard(
        child: Text(
          "No visible activity yet.",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w500,
            color: Colors.black.withOpacity(.62),
          ),
        ),
      );
    }

    return Column(
      children: shown.map((item) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ActivityRow(
            item: item,
            busy: item.memberUid != null && memberBusyIds.contains(item.memberUid),
            onApprove: item.memberUid == null
                ? null
                : () => onApproveRequest(item.memberUid!),
            onDeny: item.memberUid == null
                ? null
                : () => onDenyRequest(item.memberUid!),
          ),
        );
      }).toList(),
    );
  }
}

class _ParticipantEntry {
  final String uid;
  final String role;
  final String status;
  final bool mutedInChat;
  final DateTime? joinedAt;

  const _ParticipantEntry({
    required this.uid,
    required this.role,
    required this.status,
    required this.mutedInChat,
    required this.joinedAt,
  });

  factory _ParticipantEntry.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final rawStatus = (data["status"] ?? "").toString().trim().toLowerCase();

    return _ParticipantEntry(
      uid: (data["uid"] ?? doc.id).toString().trim(),
      role: (data["role"] ?? "").toString().trim().toLowerCase(),
      status: rawStatus.isEmpty ? "approved" : rawStatus,
      mutedInChat: data["mutedInChat"] == true,
      joinedAt: data["joinedAt"] is Timestamp
          ? (data["joinedAt"] as Timestamp).toDate()
          : null,
    );
  }

  factory _ParticipantEntry.host({
    required String uid,
    DateTime? joinedAt,
  }) {
    return _ParticipantEntry(
      uid: uid,
      role: "creator",
      status: "approved",
      mutedInChat: false,
      joinedAt: joinedAt,
    );
  }

  bool get isCreator => role == "creator";
  bool get isPending => status == "pending";
}

class _MemberCard extends StatelessWidget {
  final _ParticipantEntry member;
  final bool busy;
  final String Function(DateTime) relative;
  final bool pendingMode;
  final VoidCallback? onApprove;
  final VoidCallback? onMuteToggle;
  final VoidCallback? onRemove;

  const _MemberCard({
    required this.member,
    required this.busy,
    required this.relative,
    required this.pendingMode,
    required this.onApprove,
    required this.onMuteToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection("users")
          .doc(member.uid)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? {};
        final fullName = (data["fullName"] ?? "").toString().trim();
        final username = (data["username"] ?? "").toString().trim();
        final photoUrl = (data["photoUrl"] ?? "").toString().trim();
        final verification = (data["verification"] is Map)
            ? Map<String, dynamic>.from(data["verification"])
            : <String, dynamic>{};
        final verified = (verification["status"] ?? "") == "verified";

        final displayName = fullName.isEmpty ? "Pingmee user" : fullName;
        final sub = username.isEmpty
            ? (member.joinedAt == null ? "@unknown" : relative(member.joinedAt!))
            : "@$username";

        return _SurfaceCard(
          child: Column(
            children: [
              Row(
                children: [
                  _UserAvatar(
                    photoUrl: photoUrl,
                    fallback: displayName,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (member.uid.isEmpty) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ProfileTab(profileUid: member.uid),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                if (verified) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.verified_rounded,
                                    size: 16,
                                    color: Color(0xFF1D9BF0),
                                  ),
                                ],
                                if (member.isCreator) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreen.withOpacity(.12),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      "Host",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.brandGreen,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.56),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
                      ),
                    )
                  else
                    PhosphorIcon(
                      PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                      size: 18,
                      color: Colors.black.withOpacity(.35),
                    ),
                ],
              ),
              if (!member.isCreator) ...[
                const SizedBox(height: 12),
                Row(
                  children: pendingMode
                      ? [
                          Expanded(
                            child: _SoftActionButton(
                              label: "Approve",
                              icon: PhosphorIcons.check(
                                PhosphorIconsStyle.bold,
                              ),
                              onTap: busy ? null : onApprove,
                              strong: true,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SoftActionButton(
                              label: "Deny",
                              icon: PhosphorIcons.x(
                                PhosphorIconsStyle.bold,
                              ),
                              onTap: busy ? null : onRemove,
                              danger: true,
                            ),
                          ),
                        ]
                      : [
                          Expanded(
                            child: _SoftActionButton(
                              label: member.mutedInChat ? "Unmute" : "Mute",
                              icon: member.mutedInChat
                                  ? PhosphorIcons.speakerHigh(
                                      PhosphorIconsStyle.bold,
                                    )
                                  : PhosphorIcons.speakerSlash(
                                      PhosphorIconsStyle.bold,
                                    ),
                              onTap: busy ? null : onMuteToggle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SoftActionButton(
                              label: "Remove",
                              icon: PhosphorIcons.userMinus(
                                PhosphorIconsStyle.bold,
                              ),
                              onTap: busy ? null : onRemove,
                              danger: true,
                            ),
                          ),
                        ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ManageHeroCard extends StatelessWidget {
  final String title;
  final String description;
  final String locationLine;
  final String remaining;
  final int members;
  final int messages;
  final String status;
  final Color accentColor;
  final IconData accentIcon;

  const _ManageHeroCard({
    required this.title,
    required this.description,
    required this.locationLine,
    required this.remaining,
    required this.members,
    required this.messages,
    required this.status,
    required this.accentColor,
    required this.accentIcon,
  });

  @override
  Widget build(BuildContext context) {
    final active = status.toLowerCase() != "ended";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            accentColor.withOpacity(.18),
            accentColor.withOpacity(.07),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accentColor.withOpacity(.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.45),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: PhosphorIcon(
                    accentIcon,
                    size: 20,
                    color: accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      height: 1.08,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.82),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PhosphorIcon(
                      active
                          ? PhosphorIcons.record(PhosphorIconsStyle.fill)
                          : PhosphorIcons.stopCircle(PhosphorIconsStyle.fill),
                      size: 10,
                      color: active ? accentColor : const Color(0xFF6B7280),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      active ? "Live" : "Ended",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: active ? accentColor : const Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w400,
                height: 1.35,
                color: Colors.black.withOpacity(.66),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                size: 16,
                color: Colors.black.withOpacity(.56),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  locationLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.68),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.timer(PhosphorIconsStyle.fill),
                size: 16,
                color: Colors.black.withOpacity(.56),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  remaining,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.72),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeroStat(label: "Members", value: members.toString()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroStat(label: "Messages", value: messages.toString()),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroStat(label: "Remaining", value: remaining),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OwnerTabStrip extends StatelessWidget {
  final TabController controller;

  const _OwnerTabStrip({
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.black.withOpacity(.05),
        ),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        indicator: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(999),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.black.withOpacity(.56),
        labelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        tabs: const [
          Tab(text: "Overview"),
          Tab(text: "Members"),
          Tab(text: "Chat"),
          Tab(text: "Settings"),
        ],
      ),
    );
  }
}

class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _PinnedTabBarDelegate({
    required this.height,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _PinnedTabBarDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}

class _TopPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TopPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PhosphorIcon(
            icon,
            size: 16,
            color: AppColors.brandGreen,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: "Nunito",
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: .2,
        color: Colors.black.withOpacity(.82),
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.black.withOpacity(.04),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ManageGlassIconPill(
            icon: icon,
            size: 38,
            radius: 14,
            iconSize: 18,
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.54),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool inviteStyle;

  const _QuickActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.inviteStyle = false,
  });

  @override
  Widget build(BuildContext context) {

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.black.withOpacity(.04),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.035),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ManageGlassIconPill(
                  icon: icon,
                  size: 42,
                  radius: 15,
                  iconSize: 20,
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.4,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    color: Colors.black.withOpacity(.54),
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

class _ActivityItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final DateTime? sortTime;
  final String? memberUid;
  final bool showRequestActions;

  const _ActivityItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.sortTime,
    this.memberUid,
    this.showRequestActions = false,
  });
}

class _ActivityRow extends StatelessWidget {
  final _ActivityItem item;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onDeny;

  const _ActivityRow({
    required this.item,
    this.busy = false,
    this.onApprove,
    this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: item.color.withOpacity(.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: PhosphorIcon(
                    item.icon,
                    size: 20,
                    color: item.color,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.subtitle,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        color: Colors.black.withOpacity(.60),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (item.showRequestActions) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SoftActionButton(
                    label: "Approve",
                    icon: PhosphorIcons.check(PhosphorIconsStyle.bold),
                    onTap: busy ? null : onApprove,
                    strong: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SoftActionButton(
                    label: "Deny",
                    icon: PhosphorIcons.x(PhosphorIconsStyle.bold),
                    onTap: busy ? null : onDeny,
                    danger: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String label;
  final String value;

  const _HeroStat({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.78),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingSwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SettingSwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w400,
                  height: 1.35,
                  color: Colors.black.withOpacity(.56),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Switch.adaptive(
          value: value,
          activeColor: AppColors.brandGreen,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _PillChoice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PillChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _manageBlack : const Color(0xFFF4F6F8),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? Colors.white
                : Colors.black.withOpacity(.62),
          ),
        ),
      ),
    );
  }
}

class _MiniActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _MiniActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Opacity(
        opacity: disabled ? .55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _manageBlack,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                icon,
                size: 15,
                color: Colors.white,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _PrimaryActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: PhosphorIcon(
          icon,
          size: 18,
          color: Colors.white,
        ),
        label: Text(
          label,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _manageBlack,
          disabledBackgroundColor: _manageBlack.withOpacity(.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white.withOpacity(.70),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}

class _SoftActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool strong;
  final bool danger;

  const _SoftActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.strong = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? const Color(0xFFFEF2F2)
        : strong
            ? _manageBlack
            : _manageBlackSoft;

    final fg = danger
        ? const Color(0xFFB42318)
        : strong
            ? Colors.white
            : _manageBlack;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Opacity(
        opacity: onTap == null ? .50 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PhosphorIcon(
                icon,
                size: 16,
                color: fg,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRowButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool inviteStyle;

  const _ActionRowButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.inviteStyle = false,
  });

  @override
  Widget build(BuildContext context) {

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.black.withOpacity(.04),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.035),
              ),
            ],
          ),
          child: Row(
            children: [
              _ManageGlassIconPill(
                icon: icon,
                size: 46,
                radius: 16,
                iconSize: 21,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.8,
                        fontWeight: FontWeight.w500,
                        height: 1.28,
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                size: 16,
                color: Colors.black.withOpacity(.28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DangerCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DangerCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF5F5),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFB42318).withOpacity(.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.warning(PhosphorIconsStyle.fill),
                    size: 22,
                    color: const Color(0xFFB42318),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7F1D1D),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                        color: Color(0xFF991B1B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFFB42318),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconGhostButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _IconGhostButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(.05)),
        ),
        child: Center(
          child: PhosphorIcon(
            icon,
            size: 20,
            color: Colors.black.withOpacity(.72),
          ),
        ),
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String photoUrl;
  final String fallback;

  const _UserAvatar({
    required this.photoUrl,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;

    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withOpacity(.06),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: !hasPhoto
          ? Center(
              child: Text(
                fallback.trim().isEmpty ? "P" : fallback.trim()[0].toUpperCase(),
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            )
          : null,
    );
  }
}

class _BottomSheetFrame extends StatelessWidget {
  final Widget child;

  const _BottomSheetFrame({
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(28),
      ),
      child: Container(
        width: double.infinity,
        color: const Color(0xFFF8FAFC),
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + safeBottom),
        child: child,
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.12),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SheetTitle({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w400,
            height: 1.35,
            color: Colors.black.withOpacity(.58),
          ),
        ),
      ],
    );
  }
}

class _SheetField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;

  const _SheetField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.maxLines,
    this.maxLength,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          maxLength: maxLength,
          buildCounter: (
            context, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) {
            return null;
          },
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}

class _InviteFriendRecord {
  final String uid;
  final String name;
  final String username;
  final String photoUrl;
  final bool verified;

  const _InviteFriendRecord({
    required this.uid,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.verified,
  });

  String get searchHaystack =>
      "${name.toLowerCase()} ${username.toLowerCase()}";
}

class _InviteFriendsScreen extends StatefulWidget {
  final String ownerUid;
  final String pingId;
  final String pingTitle;
  final Future<_PingInviteSendResult> Function(_InviteFriendRecord friend) onInvite;

  const _InviteFriendsScreen({
    required this.ownerUid,
    required this.pingId,
    required this.pingTitle,
    required this.onInvite,
  });

  @override
  State<_InviteFriendsScreen> createState() => _InviteFriendsScreenState();
}

class _InviteFriendsScreenState extends State<_InviteFriendsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _busyIds = <String>{};

  bool _loading = true;
  String _query = "";
  List<_InviteFriendRecord> _friends = const [];

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
        final friendUid = (friendDoc.data()["friendId"] ?? "").toString().trim();
        if (friendUid.isEmpty) return null;

        final userSnap = await db.collection("users").doc(friendUid).get();
        final user = userSnap.data() ?? <String, dynamic>{};
        final verification =
            Map<String, dynamic>.from(user["verification"] ?? {});

        final fullName = (user["fullName"] ?? "Friend").toString().trim();
        final username = (user["username"] ?? "").toString().trim();
        final photoUrl = (user["photoUrl"] ?? "").toString().trim();

        return _InviteFriendRecord(
          uid: friendUid,
          name: fullName.isEmpty ? "Friend" : fullName,
          username: username,
          photoUrl: photoUrl,
          verified: verification["status"] == "verified",
        );
      }).toList();

      final records = (await Future.wait(futures))
          .whereType<_InviteFriendRecord>()
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

  Future<void> _handleInvite(_InviteFriendRecord friend) async {
    if (_busyIds.contains(friend.uid)) return;

    setState(() => _busyIds.add(friend.uid));

    try {
      final result = await widget.onInvite(friend);
      if (!mounted) return;

      switch (result) {
        case _PingInviteSendResult.sent:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("Invite sent to ${friend.name}."),
            ),
          );
          break;
        case _PingInviteSendResult.alreadyInvited:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("${friend.name} was already invited."),
            ),
          );
          break;
        case _PingInviteSendResult.alreadyParticipant:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("${friend.name} is already in this ping."),
            ),
          );
          break;
        case _PingInviteSendResult.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text("Couldn’t send invite."),
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
                final status = (data["status"] ?? "").toString().trim().toLowerCase();
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
                          "Invite friends",
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.pingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.55),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: "Search your connections",
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () => _searchCtrl.clear(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _friends.isEmpty
                          ? const _InviteEmptyState(
                              title: "No friends yet",
                              subtitle: "Make connections first, then invite them here.",
                            )
                          : filtered.isEmpty
                              ? const _InviteEmptyState(
                                  title: "No results",
                                  subtitle: "Try a different name or username.",
                                )
                              : ListView.separated(
                                  physics: const BouncingScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                                  itemCount: filtered.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (_, i) {
                                    final friend = filtered[i];
                                    final invited = invitedIds.contains(friend.uid);
                                    final busy = _busyIds.contains(friend.uid);

                                    return _InviteFriendTile(
                                      friend: friend,
                                      invited: invited,
                                      busy: busy,
                                      onInvite: invited ? null : () => _handleInvite(friend),
                                    );
                                  },
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

class _InviteFriendTile extends StatelessWidget {
  final _InviteFriendRecord friend;
  final bool invited;
  final bool busy;
  final VoidCallback? onInvite;

  const _InviteFriendTile({
    required this.friend,
    required this.invited,
    required this.busy,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = friend.photoUrl.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: const Color(0xFFF2F4F8),
            backgroundImage: hasPhoto ? NetworkImage(friend.photoUrl) : null,
            child: !hasPhoto
                ? Icon(
                    PhosphorIcons.user(PhosphorIconsStyle.light),
                    color: Colors.black.withOpacity(.50),
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
                        friend.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    if (friend.verified) ...[
                      const SizedBox(width: 6),
                      const _InviteVerifiedBadge(),
                    ],
                  ],
                ),
                if (friend.username.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    "@${friend.username}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 40,
            child: ElevatedButton(
              onPressed: (busy || invited) ? null : onInvite,
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: invited
                    ? Colors.black.withOpacity(.08)
                    : AppColors.brandGreen,
                foregroundColor: invited
                    ? Colors.black.withOpacity(.70)
                    : Colors.white,
                disabledBackgroundColor: invited
                    ? Colors.black.withOpacity(.08)
                    : AppColors.brandGreen.withOpacity(.55),
                disabledForegroundColor: invited
                    ? Colors.black.withOpacity(.70)
                    : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      invited ? "Invited" : "Invite",
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteVerifiedBadge extends StatelessWidget {
  const _InviteVerifiedBadge();

  @override
  Widget build(BuildContext context) {
    return Icon(
      PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
      size: 16,
      color: const Color(0xFF3B82F6),
    );
  }
}

class _InviteEmptyState extends StatelessWidget {
  final String title;
  final String subtitle;

  const _InviteEmptyState({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withOpacity(.10),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                PhosphorIcons.userPlus(PhosphorIconsStyle.light),
                color: AppColors.brandGreen,
                size: 28,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(.55),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}