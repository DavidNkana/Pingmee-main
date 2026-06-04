import 'dart:ui';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/pings/join_ping_invite_friends_screen.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/features/pings/ping_join_notifications.dart';
import 'package:ping_files/features/chat/pingmee_chat_routes.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';

Future<void> openJoinPingSheet({
  required BuildContext context,
  required String pingId,
}) async {
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(.35),
    builder: (_) => _JoinPingSheet(
      pingId: pingId,
      hostContext: context,
    ),
  );
}

class _JoinPingSheet extends StatefulWidget {
  final String pingId;
  final BuildContext hostContext;

  const _JoinPingSheet({
    required this.pingId,
    required this.hostContext,
  });

  @override
  State<_JoinPingSheet> createState() => _JoinPingSheetState();
}

class _JoinPingSheetState extends State<_JoinPingSheet> {
  late final PageController _pageController;

  bool _busy = false;
  bool _localNotifyOnApproval = true;
  int _pageIndex = 0;
  String? _lastSyncedStateKey;

  DocumentReference<Map<String, dynamic>> get _pingRef =>
      FirebaseFirestore.instance.collection("pings").doc(widget.pingId);

  CollectionReference<Map<String, dynamic>> get _participantsRef =>
      _pingRef.collection("participants");

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      _pingRef.collection("messages");
  CollectionReference<Map<String, dynamic>> get _activityRef =>
      _pingRef.collection("activity");

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  String? _bannerMessage;
  bool _bannerIsError = false;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;

    _bannerTimer?.cancel();

    setState(() {
      _bannerMessage = message;
      _bannerIsError = isError;
    });

    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _bannerMessage = null;
      });
    });

    debugPrint("🍞 banner shown: $message");
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

  Future<void> _goToPage(int index) async {
    if (!_pageController.hasClients) return;
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  String _stateKeyFor(_JoinRuntime runtime) {
    if (runtime.isApproved) return "approved";
    if (runtime.isPending) return "pending";
    return "preview";
  }

  int _pageForStateKey(String key) {
    switch (key) {
      case "approved":
        return 1;
      case "pending":
        return 2;
      default:
        return 0;
    }
  }

  Future<bool> _uninviteFriendFromJoin({
    required _JoinRuntime runtime,
    required JoinPingInviteFriendRecord friend,
  }) async {
    final myUid = _myUid;
    if (myUid == null) return false;

    try {
      final pingInviteRef = _pingRef.collection("invites").doc(friend.uid);

      final recipientInviteRef = FirebaseFirestore.instance
          .collection("users")
          .doc(friend.uid)
          .collection("ping_invites")
          .doc(runtime.pingId);

      final batch = FirebaseFirestore.instance.batch();
      batch.delete(pingInviteRef);
      batch.delete(recipientInviteRef);
      await batch.commit();

      return true;
    } catch (e) {
      debugPrint("❌ uninvite from join failed: $e");
      return false;
    }
  }

  Future<void> _logJoinRequestActivity({
    required String joinerUid,
    required String pingTitle,
  }) async {
    try {
      await _activityRef.add({
        "type": "join_request_received",
        "title": "New join request",
        "subtitle": "Someone wants to join $pingTitle",
        "actorUid": joinerUid,
        "createdAt": FieldValue.serverTimestamp(),
        "extra": {
          "memberUid": joinerUid,
        },
      });
    } catch (e) {
      debugPrint("❌ join request activity log failed: $e");
    }
  }

  Future<void> _finishPing(_JoinRuntime runtime) async {
    final uid = runtime.myUid;
    if (uid == null) return;
    if (_busy) return;

    setState(() => _busy = true);

    final userRef = FirebaseFirestore.instance.collection("users").doc(uid);
    final partRef = _participantsRef.doc(uid);

    bool leftApprovedPing = false;

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final userSnap = await tx.get(userRef);
        final userData = userSnap.data() ?? <String, dynamic>{};
        final activePingId = (userData["activePingId"] ?? "").toString().trim();

        final partSnap = await tx.get(partRef);
        final partData = partSnap.data() ?? <String, dynamic>{};
        final status = _s(partData["status"]).toLowerCase();

        if (activePingId == runtime.pingId) {
          tx.set(userRef, {
            "activePingId": FieldValue.delete(),
            "activePingStatus": FieldValue.delete(),
            "activePingJoinedAt": FieldValue.delete(),
          }, SetOptions(merge: true));
        }

        if (partSnap.exists) {
          if (status == "approved") {
            leftApprovedPing = true;

            tx.set(partRef, {
              "status": "left",
              "leftAt": FieldValue.serverTimestamp(),
              "updatedAt": FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

            tx.set(_pingRef, {
              "participantCount": FieldValue.increment(-1),
            }, SetOptions(merge: true));
          } else if (status == "pending") {
            tx.delete(partRef);
          }
        }
      });

      await _syncParticipantCount();

      if (leftApprovedPing) {
        try {
          await PingmeeStreamChatService.instance.removePingChatMember(
            pingId: runtime.pingId,
          );
        } catch (e) {
          debugPrint('❌ remove self from Stream ping chat failed: $e');
        }
      }

      if (leftApprovedPing &&
          runtime.creatorId.trim().isNotEmpty &&
          runtime.creatorId != uid) {
        await sendPingMemberLeftNotification(
          creatorUid: runtime.creatorId,
          memberUid: uid,
          pingId: runtime.pingId,
        );
      }

      if (!mounted) return;
      _toast("Done. You can join another ping now.");
      Navigator.pop(context);
    } catch (e) {
      _toast("Couldn't finish ping right now.", isError: true);
      debugPrint("❌ finish ping failed: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _syncPageToRuntime(_JoinRuntime runtime) {
    final nextKey = _stateKeyFor(runtime);
    if (_lastSyncedStateKey == nextKey) return;

    _lastSyncedStateKey = nextKey;
    final targetPage = _pageForStateKey(nextKey);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      if (_pageIndex != targetPage) {
        setState(() => _pageIndex = targetPage);
      }

      await _goToPage(targetPage);
    });
  }

  Future<void> _openInviteFriendsScreen(_JoinRuntime runtime) async {
    final myUid = _myUid;
    if (myUid == null) {
      _toast("You must be logged in.", isError: true);
      return;
    }

    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => JoinPingInviteFriendsScreen(
          ownerUid: myUid,
          pingId: runtime.pingId,
          pingTitle: runtime.title,
          onInvite: (friend) => _sendPingInviteFromJoin(
            runtime: runtime,
            friend: friend,
          ),
          onUninvite: (friend) => _uninviteFriendFromJoin(
            runtime: runtime,
            friend: friend,
          ),
        ),
      ),
    );
  }

  Future<JoinPingInviteSendResult> _sendPingInviteFromJoin({
    required _JoinRuntime runtime,
    required JoinPingInviteFriendRecord friend,
  }) async {
    final myUid = _myUid;
    if (myUid == null) return JoinPingInviteSendResult.failed;

    try {
      final participantSnap = await _participantsRef.doc(friend.uid).get();
      if (participantSnap.exists) {
        final participantData = participantSnap.data() ?? <String, dynamic>{};
        final status =
            (participantData["status"] ?? "").toString().trim().toLowerCase();

        if (status == "approved" || status == "pending") {
          return JoinPingInviteSendResult.alreadyParticipant;
        }
      }

      final pingInviteRef = _pingRef.collection("invites").doc(friend.uid);
      final existingInviteSnap = await pingInviteRef.get();

      if (existingInviteSnap.exists) {
        final existingData = existingInviteSnap.data() ?? <String, dynamic>{};
        final existingStatus =
            (existingData["status"] ?? "").toString().trim().toLowerCase();

        if (existingStatus == "pending" || existingStatus == "sent") {
          return JoinPingInviteSendResult.alreadyInvited;
        }
      }

      final senderSnap = await FirebaseFirestore.instance
          .collection("users")
          .doc(myUid)
          .get();

      final senderData = senderSnap.data() ?? <String, dynamic>{};

      final senderName = (senderData["fullName"] ??
              senderData["displayName"] ??
              senderData["name"] ??
              "")
          .toString()
          .trim();

      final senderUsername = (senderData["username"] ?? "").toString().trim();
      final senderPhotoUrl = (senderData["photoUrl"] ??
              senderData["profilePhotoUrl"] ??
              senderData["avatarUrl"] ??
              "")
          .toString()
          .trim();

      final recipientInviteRef = FirebaseFirestore.instance
          .collection("users")
          .doc(friend.uid)
          .collection("ping_invites")
          .doc(runtime.pingId);

      final recipientNotifRef = FirebaseFirestore.instance
          .collection("users")
          .doc(friend.uid)
          .collection("notifications")
          .doc();

      final now = FieldValue.serverTimestamp();

      final invitePayload = <String, dynamic>{
        "pingId": runtime.pingId,
        "recipientUid": friend.uid,
        "senderUid": myUid,
        "senderName": senderName,
        "senderUsername": senderUsername,
        "senderPhotoUrl": senderPhotoUrl,
        "pingTitle": runtime.title,
        "pingCategory": runtime.category,
        "pingPrivacy": runtime.privacyRaw,
        "locationLine": runtime.locationLine,
        "status": "pending",
        "source": "friend_picker",
        "createdAt": now,
        "updatedAt": now,
      };

      final notificationPayload = <String, dynamic>{
        "type": "ping_invite",
        "read": false,
        "createdAt": now,

        "senderUid": myUid,
        "senderName": senderName,
        "senderUsername": senderUsername,
        "senderPhotoUrl": senderPhotoUrl,

        "pingId": runtime.pingId,
        "pingTitle": runtime.title,
        "pingCategory": runtime.category,
        "pingPrivacy": runtime.privacyRaw,
        "locationLine": runtime.locationLine,

        "title": "Ping invite",
        "body": runtime.title.isNotEmpty
            ? '$senderName invited you to "${runtime.title}".'
            : "$senderName invited you to a ping.",

        "status": "pending",
        "source": "friend_picker",
      };

      final batch = FirebaseFirestore.instance.batch();

      batch.set(pingInviteRef, invitePayload);
      batch.set(recipientInviteRef, invitePayload);
      batch.set(recipientNotifRef, notificationPayload);

      await batch.commit();

      await _activityRef.add({
        "type": "friend_invited",
        "title": "Friend invited",
        "subtitle": "Invite sent to ${friend.name}",
        "actorUid": myUid,
        "createdAt": FieldValue.serverTimestamp(),
        "extra": {
          "friendUid": friend.uid,
          "pingId": runtime.pingId,
        },
      });

      return JoinPingInviteSendResult.sent;
    } catch (e) {
      debugPrint("❌ join sheet invite failed: $e");
      return JoinPingInviteSendResult.failed;
    }
  }

  Future<void> _submitJoin(_JoinRuntime runtime) async {
    final uid = runtime.myUid;
    if (uid == null) {
      _toast("You must be logged in.", isError: true);
      return;
    }
    final userRef = FirebaseFirestore.instance.collection("users").doc(uid);

    if (_busy) return;

    setState(() => _busy = true);

    try {
      final joinedInstantly =
          await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
        final partRef = _participantsRef.doc(uid);

        final userSnap = await tx.get(userRef);
        final userData = userSnap.data() ?? <String, dynamic>{};
        final rawActivePingId = _s(userData["activePingId"]);

        final partSnap = await tx.get(partRef);
        final pingSnap = await tx.get(_pingRef);
        final pingData = pingSnap.data() ?? <String, dynamic>{};
        final maxMembers = _i(pingData["maxMembers"]);
        final participantCount = _i(pingData["participantCount"]);
        final now = DateTime.now();

        final chatAutoArchiveAt = _ts(pingData["chatAutoArchiveAt"]);
        final chatLifecycle = pingData["chatLifecycle"] is Map
            ? Map<String, dynamic>.from(pingData["chatLifecycle"] as Map)
            : <String, dynamic>{};

        final autoArchived = chatLifecycle["autoArchived"] == true ||
            pingData["chatAutoArchived"] == true;

        if (autoArchived ||
            (chatAutoArchiveAt != null && !chatAutoArchiveAt.isAfter(now))) {
          throw Exception("ping-chat-archived");
        }

        if (runtime.creatorId == uid) {
          throw Exception("creator-cannot-join-own-ping");
        }

        if (partSnap.exists) {
          final existing = partSnap.data() ?? <String, dynamic>{};
          final existingStatus = _s(existing["status"]).toLowerCase();

          if (existingStatus == "approved") {
            tx.set(userRef, {
              "activePingId": runtime.pingId,
              "activePingStatus": "approved",
              "activePingJoinedAt": existing["joinedAt"] ?? FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            return true;
          }

          if (existingStatus == "pending") {
            tx.set(userRef, {
              "activePingId": runtime.pingId,
              "activePingStatus": "pending",
              "activePingJoinedAt": existing["requestedAt"] ?? FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            return false;
          }
        }

        if (maxMembers > 0 && participantCount >= maxMembers) {
          throw Exception("ping-full");
        }

        if (rawActivePingId.isNotEmpty && rawActivePingId != runtime.pingId) {
          final otherPingRef = FirebaseFirestore.instance
              .collection("pings")
              .doc(rawActivePingId);

          final otherPartRef = otherPingRef.collection("participants").doc(uid);
          final otherPartSnap = await tx.get(otherPartRef);

          if (!otherPartSnap.exists) {
            tx.set(userRef, {
              "activePingId": FieldValue.delete(),
              "activePingStatus": FieldValue.delete(),
              "activePingJoinedAt": FieldValue.delete(),
            }, SetOptions(merge: true));
          } else {
            final otherPartData = otherPartSnap.data() ?? <String, dynamic>{};
            final otherPartStatus = _s(otherPartData["status"]).toLowerCase();

            final stillAttached =
                otherPartStatus == "approved" || otherPartStatus == "pending";

            if (!stillAttached) {
              tx.set(userRef, {
                "activePingId": FieldValue.delete(),
                "activePingStatus": FieldValue.delete(),
                "activePingJoinedAt": FieldValue.delete(),
              }, SetOptions(merge: true));
            } else {
              final otherPingSnap = await tx.get(otherPingRef);
              final otherPingData = otherPingSnap.data() ?? <String, dynamic>{};
              final otherPingStatus = _s(otherPingData["status"]).toLowerCase();
              final otherEndsAt = _ts(otherPingData["endsAt"]);

              final otherPingStillLive =
                  otherPingSnap.exists &&
                  otherPingStatus != "ended" &&
                  otherPingStatus != "cancelled" &&
                  (otherEndsAt == null || otherEndsAt.isAfter(DateTime.now()));

              if (otherPingStillLive) {
                throw Exception("another-active-ping");
              }

              tx.set(userRef, {
                "activePingId": FieldValue.delete(),
                "activePingStatus": FieldValue.delete(),
                "activePingJoinedAt": FieldValue.delete(),
              }, SetOptions(merge: true));
            }
          }
        }
        final data = <String, dynamic>{
          "uid": uid,
          "role": "member",
          "mutedInChat": false,
          "notifyOnApproval": _localNotifyOnApproval,
          "updatedAt": FieldValue.serverTimestamp(),
        };

        if (runtime.requiresApproval) {
          tx.set(partRef, {
            ...data,
            "status": "pending",
            "requestedAt": FieldValue.serverTimestamp(),
          });

          tx.set(userRef, {
            "activePingId": runtime.pingId,
            "activePingStatus": "pending",
            "activePingJoinedAt": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          return false;
        } else {
          tx.set(partRef, {
            ...data,
            "status": "approved",
            "joinedAt": FieldValue.serverTimestamp(),
            "approvedAt": FieldValue.serverTimestamp(),
          });

          tx.set(userRef, {
            "activePingId": runtime.pingId,
            "activePingStatus": "approved",
            "activePingJoinedAt": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          tx.set(_pingRef, {
            "participantCount": FieldValue.increment(1),
          }, SetOptions(merge: true));

          return true;
        }
      });

      if (joinedInstantly) {
        await _sendPingJoinedNotification(
          creatorUid: runtime.creatorId,
          pingId: runtime.pingId,
          pingTitle: runtime.title,
          joinerUid: uid,
        );
      }

      if (!joinedInstantly && runtime.requiresApproval) {
        await _logJoinRequestActivity(
          joinerUid: uid,
          pingTitle: runtime.title,
        );

        await sendPingJoinRequestNotification(
          creatorUid: runtime.creatorId,
          requesterUid: uid,
          pingId: runtime.pingId,
        );
      }

      await _syncParticipantCount();

      if (!mounted) return;

      HapticFeedback.selectionClick();
      _toast(
        runtime.requiresApproval ? "Join request sent." : "You joined the ping.",
      );
    } catch (e) {
        if (!mounted) return;

        final msg = e.toString();

        if (msg.contains("ping-full")) {
          _toast("Ping already full.", isError: true);
        } else if (msg.contains("another-active-ping")) {
          _toast("You are already attending another Ping.", isError: true);
        } else if (msg.contains("creator-cannot-join-own-ping")) {
          _toast("You already own this ping.", isError: true);
        } else if (msg.contains("ping-chat-archived")) {
          _toast("This ping has ended and its chat is archived.", isError: true);
        } else {
          _toast("Couldn't continue right now.", isError: true);
        }

        debugPrint("❌ submit join failed: $e");
      } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancelPending(_JoinRuntime runtime) async {
    final uid = runtime.myUid;
    if (uid == null || !runtime.isPending || _busy) return;

    setState(() => _busy = true);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final partRef = _participantsRef.doc(uid);
        final userRef = FirebaseFirestore.instance.collection("users").doc(uid);

        final snap = await tx.get(partRef);
        if (!snap.exists) return;

        final data = snap.data() ?? <String, dynamic>{};
        final status = _s(data["status"]).toLowerCase();
        if (status != "pending") return;

        tx.delete(partRef);

        tx.set(userRef, {
          "activePingId": FieldValue.delete(),
          "activePingStatus": FieldValue.delete(),
          "activePingJoinedAt": FieldValue.delete(),
        }, SetOptions(merge: true));
      });

      HapticFeedback.selectionClick();
      _toast("Request cancelled.");
    } catch (_) {
      _toast("Couldn't cancel request.", isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateNotifyOnApproval(
    _JoinRuntime runtime,
    bool value,
  ) async {
    final uid = runtime.myUid;
    if (uid == null) return;

    setState(() => _localNotifyOnApproval = value);

    try {
      await _participantsRef.doc(uid).set({
        "uid": uid,
        "notifyOnApproval": value,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      _toast("Couldn't update approval notifications.", isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final myUid = _myUid;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(28),
      ),
      child: Container(
        height: h * .93,
        width: double.infinity,
        color: const Color(0xFFF6F7FB),
        child: Stack(
          children: [
            SafeArea(
              top: false,
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _pingRef.snapshots(),
                builder: (context, pingSnap) {
                  if (!pingSnap.hasData) {
                    return const _JoinLoadingState();
                  }

                  final pingDoc = pingSnap.data!;
                  if (!pingDoc.exists || pingDoc.data() == null) {
                    return _JoinMissingState(
                      onClose: () => Navigator.pop(context),
                    );
                  }

                  final ping = pingDoc.data()!;

                  if (myUid == null) {
                    final runtime = _JoinRuntime(
                      pingId: widget.pingId,
                      ping: ping,
                      myUid: null,
                      participant: null,
                    );

                    _syncPageToRuntime(runtime);

                    return _JoinSheetScaffold(
                      pageController: _pageController,
                      pageIndex: _pageIndex,
                      onClose: () => Navigator.pop(context),
                      onDotTap: (i) async {
                        setState(() => _pageIndex = i);
                        await _goToPage(i);
                      },
                      children: [
                        _JoinPreviewPage(
                          runtime: runtime,
                          busy: false,
                          onPrimaryTap: () {
                            _toast("You must be logged in.", isError: true);
                          },
                          onOpenInside: () => _goToPage(1),
                          onOpenPending: () => _goToPage(2),
                        ),
                        _InsidePingPage(
                          runtime: runtime,
                          messagesRef: _messagesRef,
                          onInviteFriends: () => _openInviteFriendsScreen(runtime),
                          participantsRef: _participantsRef,
                          busy: _busy,
                          onExitPing: () => _finishPing(runtime),
                        ),
                        _PendingApprovalPage(
                          runtime: runtime,
                          busy: false,
                          notifyOnApproval: _localNotifyOnApproval,
                          onNotifyChanged: (_) {},
                          onCancelRequest: null,
                          onBackToPreview: () => _goToPage(0),
                        ),
                      ],
                    );
                  }

                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: _participantsRef.doc(myUid).snapshots(),
                    builder: (context, partSnap) {
                      final participant = partSnap.hasData && partSnap.data!.exists
                          ? _ParticipantRecord.fromDoc(partSnap.data!)
                          : null;

                      final runtime = _JoinRuntime(
                        pingId: widget.pingId,
                        ping: ping,
                        myUid: myUid,
                        participant: participant,
                      );

                      final notifyValue =
                          participant?.notifyOnApproval ?? _localNotifyOnApproval;

                      if (_localNotifyOnApproval != notifyValue) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          setState(() => _localNotifyOnApproval = notifyValue);
                        });
                      }

                      _syncPageToRuntime(runtime);

                      return _JoinSheetScaffold(
                        pageController: _pageController,
                        pageIndex: _pageIndex,
                        onClose: () => Navigator.pop(context),
                        onDotTap: (i) async {
                          setState(() => _pageIndex = i);
                          await _goToPage(i);
                        },
                        children: [
                         _JoinPreviewPage(
                          runtime: runtime,
                          busy: _busy,
                          onPrimaryTap: runtime.isApproved
                              ? () => _goToPage(1)
                              : runtime.isPending
                                  ? () => _goToPage(2)
                                  : () => _submitJoin(runtime),
                          onOpenInside: () => _goToPage(1),
                          onOpenPending: () => _goToPage(2),
                        ),
                          _InsidePingPage(
                            runtime: runtime,
                            messagesRef: _messagesRef,
                            onInviteFriends: () => _openInviteFriendsScreen(runtime),
                            participantsRef: _participantsRef,
                            busy: _busy,
                            onExitPing: () => _finishPing(runtime),
                          ),
                          _PendingApprovalPage(
                            runtime: runtime,
                            busy: _busy,
                            notifyOnApproval: _localNotifyOnApproval,
                            onNotifyChanged: (value) =>
                                _updateNotifyOnApproval(runtime, value),
                            onCancelRequest: runtime.isPending
                                ? () => _cancelPending(runtime)
                                : null,
                            onBackToPreview: () => _goToPage(0),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            if (_bannerMessage != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: IgnorePointer(
                  ignoring: true,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: _bannerMessage == null ? 0 : 1,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 180),
                      offset: _bannerMessage == null
                          ? const Offset(0, 0.12)
                          : Offset.zero,
                      child: _InlineBanner(
                        message: _bannerMessage!,
                        isError: _bannerIsError,
                      ),
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

class _JoinSheetScaffold extends StatelessWidget {
  final PageController pageController;
  final int pageIndex;
  final VoidCallback onClose;
  final ValueChanged<int> onDotTap;
  final List<Widget> children;

  const _JoinSheetScaffold({
    required this.pageController,
    required this.pageIndex,
    required this.onClose,
    required this.onDotTap,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 10),
        const _SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
          child: Row(
            children: [
              _IconGhostButton(
                icon: PhosphorIcons.x(PhosphorIconsStyle.light),
                onTap: onClose,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "Join Ping",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              _PageDots(
                currentIndex: pageIndex,
                onTap: onDotTap,
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView(
            controller: pageController,
            onPageChanged: onDotTap,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _JoinPreviewPage extends StatelessWidget {
  final _JoinRuntime runtime;
  final bool busy;
  final VoidCallback onPrimaryTap;
  final VoidCallback onOpenInside;
  final VoidCallback onOpenPending;

  const _JoinPreviewPage({
    required this.runtime,
    required this.busy,
    required this.onPrimaryTap,
    required this.onOpenInside,
    required this.onOpenPending,
  });

  String get _primaryLabel {
    if (runtime.isApproved) return "Open ping";
    if (runtime.isPending) return "View pending status";
    return runtime.requiresApproval ? "Request to join" : "Join ping";
  }

  IconData get _primaryIcon {
    if (runtime.isApproved) {
      return PhosphorIcons.arrowSquareOut(PhosphorIconsStyle.fill);
    }
    if (runtime.isPending) {
      return PhosphorIcons.hourglass(PhosphorIconsStyle.fill);
    }
    return runtime.requiresApproval
        ? PhosphorIcons.handWaving(PhosphorIconsStyle.fill)
        : PhosphorIcons.doorOpen(PhosphorIconsStyle.fill);
  }

  @override
  Widget build(BuildContext context) {
    final categoryStyle = _getCategoryStyle(runtime.category);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel("Ping preview"),
                const SizedBox(height: 10),
                _MapSnippetCard(
                  title: runtime.title,
                  locationLine: runtime.locationLine,
                  distanceText: runtime.distanceText,
                  accentColor: categoryStyle.color,
                ),
                const SizedBox(height: 14),
                _JoinHeaderCard(
                  title: runtime.title,
                  description: runtime.description,
                  category: runtime.category.isEmpty ? "General" : runtime.category,
                  remaining: runtime.remainingText,
                  privacyLabel: runtime.privacyLabel,
                  capacity: runtime.capacityPillLabel,
                  accentColor: categoryStyle.color,
                  accentIcon: categoryStyle.icon,
                ),
                const SizedBox(height: 14),
                _PreviewPeopleCard(
                  pingId: runtime.pingId,
                  maxMembers: runtime.maxMembers,
                ),
                const SizedBox(height: 14),
                _SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Why join now",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _ReasonRow(
                        icon: PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                        title: "It is grounded in place",
                        subtitle:
                            "You already know where this is before you commit.",
                      ),
                      const SizedBox(height: 12),
                      _ReasonRow(
                        icon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                        title: "It feels human",
                        subtitle:
                            "Real member names beat a dead number every time.",
                      ),
                      const SizedBox(height: 12),
                      _ReasonRow(
                        icon: runtime.requiresApproval
                            ? PhosphorIcons.hourglassSimpleMedium(
                                PhosphorIconsStyle.fill,
                              )
                            : PhosphorIcons.lightning(PhosphorIconsStyle.fill),
                        title: runtime.requiresApproval
                            ? "Approval keeps it controlled"
                            : "Joining is instant",
                        subtitle: runtime.requiresApproval
                            ? "The host sees your request in Manage Ping."
                            : "You go straight inside without dead waiting.",
                      ),
                    ],
                  ),
                ),
                if (runtime.isApproved) ...[
                  const SizedBox(height: 14),
                  _SurfaceCard(
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: AppColors.brandGreen.withOpacity(.10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: PhosphorIcon(
                              PhosphorIcons.checkCircle(
                                PhosphorIconsStyle.fill,
                              ),
                              size: 20,
                              color: AppColors.brandGreen,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            "You are already in this ping.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        _MiniPillAction(
                          label: "Open",
                          onTap: onOpenInside,
                        ),
                      ],
                    ),
                  ),
                ],
                if (runtime.isPending) ...[
                  const SizedBox(height: 14),
                  _SurfaceCard(
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: PhosphorIcon(
                              PhosphorIcons.hourglassHigh(
                                PhosphorIconsStyle.fill,
                              ),
                              size: 20,
                              color: const Color(0xFF4F46E5),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            "Your request is waiting for approval.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        _MiniPillAction(
                          label: "View",
                          onTap: onOpenPending,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
          child: _PrimaryActionButton(
            label: busy ? "Working..." : _primaryLabel,
            icon: _primaryIcon,
            onTap: busy ? null : onPrimaryTap,
          ),
        ),
      ],
    );
  }
}

class _InsidePingPage extends StatelessWidget {
  final _JoinRuntime runtime;
  final CollectionReference<Map<String, dynamic>> messagesRef;
  final CollectionReference<Map<String, dynamic>> participantsRef;
  final bool busy;
  final VoidCallback onExitPing;
  final VoidCallback onInviteFriends;

  const _InsidePingPage({
    required this.runtime,
    required this.messagesRef,
    required this.participantsRef,
    required this.busy,
    required this.onExitPing,
    required this.onInviteFriends,
  });

  @override
  Widget build(BuildContext context) {
    if (!runtime.isApproved) {
      return _LockedStatePage(
        icon: PhosphorIcons.chatCircleText(PhosphorIconsStyle.fill),
        title: "You are not inside yet",
        subtitle: runtime.isPending
            ? "Your request is waiting for the host."
            : "Join first, then the chat and members become real.",
      );
    }

    final categoryStyle = _getCategoryStyle(runtime.category);
    final accentColor = categoryStyle.color;

    return DefaultTabController(
      length: 4,
      child: NestedScrollView(
        physics: const BouncingScrollPhysics(),
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: _InsideHeaderCard(
                  runtime: runtime,
                  accentColor: accentColor,
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedTabBarDelegate(
                height: 70,
                child: Container(
                  color: const Color(0xFFF6F7FB),
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  alignment: Alignment.center,
                  child: _InsideTabStrip(
                    accentColor: accentColor,
                  ),
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _InsideChatTab(
              runtime: runtime,
              accentColor: accentColor,
            ),
            _InsideMembersTab(
              runtime: runtime,
              participantsRef: participantsRef,
              onInviteFriends: onInviteFriends,
            ),
            _InsideInfoTab(runtime: runtime),
            _InsideExitTab(
              runtime: runtime,
              busy: busy,
              onExitPing: onExitPing,
            ),
          ],
        ),
      ),
    );
  }
}

class _InsideTabStrip extends StatelessWidget {
  final Color accentColor;

  const _InsideTabStrip({
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: TabBar(
        isScrollable: true,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        indicator: BoxDecoration(
          color: accentColor,
          borderRadius: BorderRadius.circular(999),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: Colors.black87,
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
          Tab(text: "Chat"),
          Tab(text: "Members"),
          Tab(text: "Info"),
          Tab(text: "Exit"),
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

class _PendingApprovalPage extends StatelessWidget {
  final _JoinRuntime runtime;
  final bool busy;
  final bool notifyOnApproval;
  final ValueChanged<bool> onNotifyChanged;
  final VoidCallback? onCancelRequest;
  final VoidCallback onBackToPreview;

  const _PendingApprovalPage({
    required this.runtime,
    required this.busy,
    required this.notifyOnApproval,
    required this.onNotifyChanged,
    required this.onCancelRequest,
    required this.onBackToPreview,
  });

  @override
  Widget build(BuildContext context) {
    if (!runtime.isPending) {
      return _LockedStatePage(
        icon: PhosphorIcons.hourglassHigh(PhosphorIconsStyle.fill),
        title: "No pending request right now",
        subtitle:
            "Request access from the preview page, then this state becomes live.",
      );
    }

    final categoryStyle = _getCategoryStyle(runtime.category);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel("Pending approval"),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFEEF2FF),
                        Color(0xFFF5F3FF),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(
                      color: const Color(0xFF4F46E5).withOpacity(.10),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.78),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.hourglass_top_rounded,
                                size: 20,
                                color: Color(0xFF4F46E5),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              "Request sent",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          _StatusPill(
                            text: "Waiting",
                            bg: const Color(0xFF4F46E5).withOpacity(.10),
                            fg: const Color(0xFF4F46E5),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "The host can approve you from Manage Ping in real time. Do not treat this like a dead end.",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w400,
                          height: 1.35,
                          color: Colors.black.withOpacity(.68),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SurfaceCard(
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: categoryStyle.color.withOpacity(.10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: PhosphorIcon(
                            categoryStyle.icon,
                            size: 20,
                            color: categoryStyle.color,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              runtime.title,
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
                              runtime.locationLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w400,
                                color: Colors.black.withOpacity(.58),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusPill(
                        text: runtime.distanceText,
                        bg: Colors.black.withOpacity(.04),
                        fg: Colors.black.withOpacity(.70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SurfaceCard(
                  child: _SettingSwitchRow(
                    title: "Notify me when approved",
                    subtitle:
                        "You can close the app and still get pulled back in later.",
                    value: notifyOnApproval,
                    onChanged: busy ? null : onNotifyChanged,
                  ),
                ),
                const SizedBox(height: 14),
                _SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "What happens next",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const _PendingStepRow(
                        index: "1",
                        text: "Your request appears in the creator dashboard.",
                      ),
                      const SizedBox(height: 10),
                      const _PendingStepRow(
                        index: "2",
                        text: "The host approves or denies you.",
                      ),
                      const SizedBox(height: 10),
                      const _PendingStepRow(
                        index: "3",
                        text: "If approved, this sheet moves you inside instantly.",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
          child: Column(
            children: [
              _GhostActionButton(
                label: "Back to preview",
                icon: PhosphorIcons.arrowLeft(PhosphorIconsStyle.light),
                onTap: onBackToPreview,
              ),
              const SizedBox(height: 10),
              _DangerActionButton(
                label: busy ? "Working..." : "Cancel request",
                icon: PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
                onTap: busy ? null : onCancelRequest,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InsideChatTab extends StatefulWidget {
  final _JoinRuntime runtime;
  final Color accentColor;

  const _InsideChatTab({
    required this.runtime,
    required this.accentColor,
  });

  @override
  State<_InsideChatTab> createState() => _InsideChatTabState();
}

class _InsideChatTabState extends State<_InsideChatTab> {
  bool _opening = false;

  Future<void> _openPingChat() async {
    if (_opening) return;

    if (!widget.runtime.isApproved && !widget.runtime.isCreator) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Join this ping first before opening chat.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _opening = true);

    try {
      final channel = await PingmeeStreamChatService.instance.openPingChat(
        widget.runtime.pingId,
      );

      if (!mounted) return;

      await Navigator.of(context, rootNavigator: true).push(
        pingmeeChatRoute(channel),
      );
    } catch (error, stack) {
      debugPrint('❌ open ping chat from join sheet failed: $error');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      final raw = error.toString().toLowerCase();

      final message = raw.contains('timeout') ||
              raw.contains('took longer') ||
              raw.contains('connection') ||
              raw.contains('aborted')
          ? 'Chat is taking longer than usual. Check your connection and try again.'
          : 'Could not open ping chat. Try again.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: widget.accentColor.withOpacity(.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: PhosphorIcon(
                        PhosphorIcons.chatsCircle(
                          PhosphorIconsStyle.fill,
                        ),
                        size: 22,
                        color: widget.accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Ping group chat',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Everyone approved inside this ping can talk here. Pending members stay locked out.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.35,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
              const SizedBox(height: 16),
              _PrimaryActionButton(
                label: _opening ? 'Opening...' : 'Open group chat',
                icon: PhosphorIcons.chatCircleText(
                  PhosphorIconsStyle.fill,
                ),
                onTap: _opening ? null : _openPingChat,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InsideMembersTab extends StatelessWidget {
  final _JoinRuntime runtime;
  final CollectionReference<Map<String, dynamic>> participantsRef;
  final VoidCallback onInviteFriends;

  const _InsideMembersTab({
    required this.runtime,
    required this.participantsRef,
    required this.onInviteFriends,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: participantsRef.orderBy("joinedAt", descending: true).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
              ),
            ),
          );
        }

        final members = snap.data!.docs
            .map((e) => _ParticipantRecord.fromDoc(e))
            .where((e) => e.status == "approved")
            .toList()
          ..sort((a, b) {
            if (a.isCreator && !b.isCreator) return -1;
            if (!a.isCreator && b.isCreator) return 1;
            final at = a.joinedAt?.millisecondsSinceEpoch ?? 0;
            final bt = b.joinedAt?.millisecondsSinceEpoch ?? 0;
            return bt.compareTo(at);
          });

        return ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          children: [
            _SurfaceCard(
              child: InkWell(
                onTap: onInviteFriends,
                borderRadius: BorderRadius.circular(18),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: PhosphorIcon(
                          PhosphorIcons.userPlus(PhosphorIconsStyle.fill),
                          size: 20,
                          color: Colors.white
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Invite connections",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Bring people you trust into this ping.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w400,
                              height: 1.3,
                              color: Colors.black.withOpacity(.56),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    PhosphorIcon(
                      PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                      color: Colors.black.withOpacity(.38),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (members.isEmpty)
              _SurfaceCard(
                child: Text(
                  "No members are visible yet.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.62),
                  ),
                ),
              )
            else
              ...members.map(
                (member) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MemberPreviewCard(member: member),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InsideInfoTab extends StatelessWidget {
  final _JoinRuntime runtime;

  const _InsideInfoTab({
    required this.runtime,
  });

  @override
  Widget build(BuildContext context) {
    final categoryStyle = _getCategoryStyle(runtime.category);

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      children: [
        _SurfaceCard(
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: categoryStyle.color.withOpacity(.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: PhosphorIcon(
                    categoryStyle.icon,
                    size: 20,
                    color: categoryStyle.color,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  runtime.category.isEmpty ? "General" : runtime.category,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              _StatusPill(
                text: runtime.privacyLabel,
                bg: Colors.black.withOpacity(.04),
                fg: Colors.black.withOpacity(.70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (runtime.description.isNotEmpty)
          _SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Description",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  runtime.description,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: Colors.black.withOpacity(.68),
                  ),
                ),
              ],
            ),
          ),
        if (runtime.description.isNotEmpty) const SizedBox(height: 10),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Location",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                runtime.locationLine,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.72),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                runtime.distanceText,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.56),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Privacy",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _privacySentence(runtime.privacyRaw),
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                  color: Colors.black.withOpacity(.66),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Time",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                runtime.remainingText,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MapSnippetCard extends StatelessWidget {
  final String title;
  final String locationLine;
  final String distanceText;
  final Color accentColor;

  const _MapSnippetCard({
    required this.title,
    required this.locationLine,
    required this.distanceText,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            accentColor.withOpacity(.10),
            accentColor.withOpacity(.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accentColor.withOpacity(.12),
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _MapGridPainter(
                lineColor: Colors.black.withOpacity(.05),
              ),
            ),
          ),
          Positioned(
            left: 18,
            top: 18,
            right: 18,
            child: Row(
              children: [
                _TopSoftPill(
                  icon: PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                  label: locationLine,
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 52,
            bottom: 0,
            child: Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.82),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                    size: 28,
                    color: accentColor,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.88),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                distanceText,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.72),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JoinHeaderCard extends StatelessWidget {
  final String title;
  final String description;
  final String category;
  final String remaining;
  final String privacyLabel;
  final String capacity;
  final Color accentColor;
  final IconData accentIcon;

  const _JoinHeaderCard({
    required this.title,
    required this.description,
    required this.category,
    required this.remaining,
    required this.privacyLabel,
    required this.capacity,
    required this.accentColor,
    required this.accentIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            accentColor.withOpacity(.18),
            accentColor.withOpacity(.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accentColor.withOpacity(.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.50),
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
            ],
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              description,
              maxLines: 3,
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(
                text: category,
                bg: Colors.white.withOpacity(.70),
                fg: Colors.black.withOpacity(.74),
              ),
              _StatusPill(
                text: privacyLabel,
                bg: Colors.white.withOpacity(.70),
                fg: Colors.black.withOpacity(.74),
              ),
              _StatusPill(
                text: remaining,
                bg: Colors.white.withOpacity(.70),
                fg: Colors.black.withOpacity(.74),
              ),
              _StatusPill(
                text: capacity,
                bg: Colors.white.withOpacity(.70),
                fg: Colors.black.withOpacity(.74),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewPeopleCard extends StatelessWidget {
  final String pingId;
  final int maxMembers;

  const _PreviewPeopleCard({
    required this.pingId,
    required this.maxMembers,
  });

  @override
  Widget build(BuildContext context) {
    final participantsRef = FirebaseFirestore.instance
        .collection("pings")
        .doc(pingId)
        .collection("participants");

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: participantsRef.snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];

        final approved = docs
            .map((d) => _ParticipantRecord.fromDoc(d))
            .where((e) => e.status == "approved")
            .toList()
          ..sort((a, b) {
            if (a.isCreator && !b.isCreator) return -1;
            if (!a.isCreator && b.isCreator) return 1;

            final at = a.joinedAt?.millisecondsSinceEpoch ??
                a.approvedAt?.millisecondsSinceEpoch ??
                a.requestedAt?.millisecondsSinceEpoch ??
                0;
            final bt = b.joinedAt?.millisecondsSinceEpoch ??
                b.approvedAt?.millisecondsSinceEpoch ??
                b.requestedAt?.millisecondsSinceEpoch ??
                0;

            return bt.compareTo(at);
          });

        final count = approved.length;
        const visibleLimit = 5;

        final visibleIds = approved
            .map((e) => e.uid)
            .where((e) => e.trim().isNotEmpty)
            .take(visibleLimit)
            .toList();

        final overflowCount = count - visibleIds.length;

        if (visibleIds.isEmpty) {
          return _SurfaceCard(
            child: Row(
              children: [
                const _SmallFaceAvatar(),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Be the first one in.",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.72),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection("users")
              .where(FieldPath.documentId, whereIn: visibleIds)
              .get(),
          builder: (context, userSnap) {
            final userDocs = userSnap.data?.docs ?? const [];

            final usersById = {
              for (final doc in userDocs) doc.id: doc.data(),
            };

            final orderedUsers = visibleIds
                .map((id) => usersById[id])
                .toList();

            final visibleFirstNames = orderedUsers
                .map((user) => _firstNameFromUser(user))
                .toList();

            final peopleText = _buildPeopleAlreadyInText(count, maxMembers);
            final goingText = _buildGoingText(visibleFirstNames, count);

            final stackItems = visibleIds.length + (overflowCount > 0 ? 1 : 0);
            final stackWidth = 38 + ((stackItems - 1) * 26.0);

            return _SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: stackWidth,
                        height: 38,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (int i = 0; i < visibleIds.length; i++)
                              Positioned(
                                left: i * 26.0,
                                top: 0,
                                child: _SmallFaceAvatar(
                                  photoUrl: _s(usersById[visibleIds[i]]?["photoUrl"]),
                                  fallback: _displayNameFromUser(usersById[visibleIds[i]]),
                                ),
                              ),
                            if (overflowCount > 0)
                              Positioned(
                                left: visibleIds.length * 26.0,
                                top: 0,
                                child: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(.06),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFFF6F7FB),
                                      width: 2,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    "+$overflowCount",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black.withOpacity(.70),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          peopleText,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                            color: Colors.black.withOpacity(.72),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 1,
                    width: double.infinity,
                    color: Colors.black.withOpacity(.06),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    goingText,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: Colors.black.withOpacity(.66),
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

class _InsideHeaderCard extends StatelessWidget {
  final _JoinRuntime runtime;
  final Color accentColor;

  const _InsideHeaderCard({
    required this.runtime,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              colors: [
                accentColor.withOpacity(.20),
                accentColor.withOpacity(.10),
                Colors.white.withOpacity(.30),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Colors.white.withOpacity(.42),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 24,
                offset: const Offset(0, 12),
                color: accentColor.withOpacity(.10),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.34),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: Colors.white.withOpacity(.32),
                  ),
                ),
                child: Center(
                  child: PhosphorIcon(
                    PhosphorIcons.chatCircleText(PhosphorIconsStyle.fill),
                    size: 20,
                    color: accentColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      runtime.title,
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
                    const SizedBox(height: 6),
                    Text(
                      runtime.description.isEmpty
                          ? "You are inside the ping now."
                          : runtime.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        color: Colors.black.withOpacity(.66),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _StatusPill(
                          text: runtime.locationLine,
                          bg: Colors.white.withOpacity(.55),
                          fg: Colors.black.withOpacity(.74),
                        ),
                        _StatusPill(
                          text: runtime.remainingText,
                          bg: Colors.white.withOpacity(.55),
                          fg: Colors.black.withOpacity(.74),
                        ),
                      ],
                    ),
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

class _InsideExitTab extends StatelessWidget {
  final _JoinRuntime runtime;
  final bool busy;
  final VoidCallback onExitPing;

  const _InsideExitTab({
    required this.runtime,
    required this.busy,
    required this.onExitPing,
  });

  @override
  Widget build(BuildContext context) {
    if (!runtime.isApproved) {
      return _LockedStatePage(
        icon: PhosphorIcons.signOut(PhosphorIconsStyle.fill),
        title: "You are not inside yet",
        subtitle: "Exit controls only appear after you are inside the ping.",
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
      children: [
        _SurfaceCard(
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3F2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Center(
                  child: Icon(
                    Icons.logout_rounded,
                    size: 20,
                    color: Color(0xFFB42318),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Leave this ping",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "This removes you from the active ping so you can join another one.",
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
        ),
        const SizedBox(height: 10),
        _SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Before you exit",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 10),
              _PendingStepRow(
                index: "1",
                text: "Your active ping status gets cleared.",
              ),
              const SizedBox(height: 10),
              _PendingStepRow(
                index: "2",
                text: "You stop appearing as an active approved member here.",
              ),
              const SizedBox(height: 10),
              _PendingStepRow(
                index: "3",
                text: "You are free to join another ping immediately.",
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _DangerActionButton(
          label: busy ? "Working..." : "Done with ping",
          icon: PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
          onTap: busy ? null : onExitPing,
        ),
      ],
    );
  }
}

class _MemberPreviewCard extends StatelessWidget {
  final _ParticipantRecord member;

  const _MemberPreviewCard({
    required this.member,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection("users").doc(member.uid).snapshots(),
      builder: (context, snap) {
        final user = snap.data?.data() ?? <String, dynamic>{};
        final fullName = _s(user["fullName"]);
        final username = _s(user["username"]);
        final photoUrl = _s(user["photoUrl"]);
        final verification = user["verification"] is Map
            ? Map<String, dynamic>.from(user["verification"])
            : <String, dynamic>{};
        final verified = _s(verification["status"]).toLowerCase() == "verified";

        final displayName = fullName.isEmpty ? "Pingmee user" : fullName;
        final sub = username.isEmpty
            ? (member.joinedAt == null ? "@unknown" : _relative(member.joinedAt!))
            : "@$username";

        return _SurfaceCard(
          child: InkWell(
            onTap: () {
              if (member.uid.trim().isEmpty) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProfileTab(profileUid: member.uid),
                ),
              );
            },
            borderRadius: BorderRadius.circular(18),
            child: Row(
              children: [
                _UserAvatar(
                  photoUrl: photoUrl,
                  fallback: displayName,
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
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: "Nunito",
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
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w400,
                          color: Colors.black.withOpacity(.58),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                PhosphorIcon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                  size: 18,
                  color: Colors.black.withOpacity(.36),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SystemJoinTile extends StatelessWidget {
  final DateTime? joinedAt;
  final Color accentColor;

  const _SystemJoinTile({
    required this.joinedAt,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              joinedAt == null
                  ? "You joined · just now"
                  : "You joined · ${_relative(joinedAt!)}",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.78),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedStatePage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _LockedStatePage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: _SurfaceCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.05),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: PhosphorIcon(
                    icon,
                    size: 24,
                    color: Colors.black.withOpacity(.64),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
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
      ),
    );
  }
}

class _PendingStepRow extends StatelessWidget {
  final String index;
  final String text;

  const _PendingStepRow({
    required this.index,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFFEEF2FF),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Center(
            child: Text(
              index,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4F46E5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w400,
              height: 1.35,
              color: Colors.black.withOpacity(.66),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReasonRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _ReasonRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                blurRadius: 14,
                offset: const Offset(0, 7),
                color: Colors.black.withOpacity(.10),
              ),
            ],
          ),
          child: Center(
            child: PhosphorIcon(
              icon,
              size: 18,
              color: Colors.white,
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
                  fontSize: 13.8,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  height: 1.35,
                  color: Colors.black.withOpacity(.58),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _JoinLoadingState extends StatelessWidget {
  const _JoinLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
        ),
      ),
    );
  }
}

class _JoinMissingState extends StatelessWidget {
  final VoidCallback onClose;

  const _JoinMissingState({
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.05),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: PhosphorIcon(
                  PhosphorIcons.warningCircle(PhosphorIconsStyle.fill),
                  size: 28,
                  color: Colors.black.withOpacity(.72),
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
            const SizedBox(height: 16),
            _PrimaryActionButton(
              label: "Go back",
              icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.fill),
              onTap: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantRecord {
  final String uid;
  final String role;
  final String status;
  final bool mutedInChat;
  final bool notifyOnApproval;
  final DateTime? requestedAt;
  final DateTime? joinedAt;
  final DateTime? approvedAt;

  const _ParticipantRecord({
    required this.uid,
    required this.role,
    required this.status,
    required this.mutedInChat,
    required this.notifyOnApproval,
    required this.requestedAt,
    required this.joinedAt,
    required this.approvedAt,
  });

  factory _ParticipantRecord.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? <String, dynamic>{};

    return _ParticipantRecord(
      uid: _s(data["uid"]).isEmpty ? doc.id : _s(data["uid"]),
      role: _s(data["role"]).toLowerCase(),
      status: _s(data["status"]).isEmpty
          ? "approved"
          : _s(data["status"]).toLowerCase(),
      mutedInChat: _b(data["mutedInChat"]),
      notifyOnApproval: !_map(data).containsKey("notifyOnApproval")
          ? true
          : _b(data["notifyOnApproval"]),
      requestedAt: _ts(data["requestedAt"]),
      joinedAt: _ts(data["joinedAt"]),
      approvedAt: _ts(data["approvedAt"]),
    );
  }

  bool get isCreator => role == "creator";
}

class _JoinRuntime {
  final String pingId;
  final Map<String, dynamic> ping;
  final String? myUid;
  final _ParticipantRecord? participant;

  const _JoinRuntime({
    required this.pingId,
    required this.ping,
    required this.myUid,
    required this.participant,
  });

  String get creatorId => _extractCreatorId(ping["creatorId"]);

  bool get isCreator =>
      myUid != null && creatorId.isNotEmpty && creatorId == myUid;

  bool get isApproved =>
      participant != null && participant!.status.toLowerCase() == "approved";

  bool get isPending =>
      participant != null && participant!.status.toLowerCase() == "pending";

  bool get requiresApproval {
    final joinMode = _s(ping["joinMode"]).toLowerCase();
    final privacy = _s(ping["privacy"]).toLowerCase();

    if (_b(ping["requiresApproval"])) return true;
    if (_b(ping["approvalRequired"])) return true;
    if (_b(ping["inviteOnly"])) return true;
    if (joinMode == "approval" ||
        joinMode == "request" ||
        joinMode == "invite_only" ||
        joinMode == "inviteonly") {
      return true;
    }
    if (privacy == "private") return true;

    return false;
  }

  String get title {
    final t = _s(ping["title"]);
    return t.isEmpty ? "Untitled ping" : t;
  }

  String get description => _s(ping["description"]);

  String get category => _s(ping["category"]);

  String get privacyRaw => _s(ping["privacy"]).isEmpty ? "public" : _s(ping["privacy"]);

  String get privacyLabel {
    final p = privacyRaw.toLowerCase();
    if (p.contains("friends")) return "Friends";
    if (p.contains("verified")) return "Verified";
    if (p.contains("private")) return "Private";
    return "Public";
  }

  int get participantCount => _i(ping["participantCount"]);

  int get maxMembers {
    final raw = _i(ping["maxMembers"]);
    return raw > 0 ? raw : 0;
  }

  bool get hasMemberLimit => maxMembers > 0;

  bool get isFull => hasMemberLimit && participantCount >= maxMembers;

  int get remainingSpots {
    if (!hasMemberLimit) return 0;
    final remaining = maxMembers - participantCount;
    return remaining < 0 ? 0 : remaining;
  }

  String get capacityPillLabel {
    if (!hasMemberLimit) return "Unlimited";
    return "$participantCount/$maxMembers inside";
  }

  String get capacitySubtitle {
    if (!hasMemberLimit) {
      return participantCount == 1
          ? "1 person is already in."
          : "$participantCount people are already in.";
    }

    if (isFull) return "Room is full";
    if (remainingSpots == 1) return "1 spot left";
    return "$remainingSpots spots left";
  }

  String get locationLine => _locationLine(ping);

  String get distanceText => _distanceText(ping);

  String get remainingText => _remainingText(_ts(ping["endsAt"]));

  DateTime? get joinedAtOrRequestedAt =>
      participant?.joinedAt ?? participant?.approvedAt ?? participant?.requestedAt;
}

class _PageDots extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _PageDots({
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (index) {
        final selected = index == currentIndex;
        return GestureDetector(
          onTap: () => onTap(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: EdgeInsets.only(left: index == 0 ? 0 : 8),
            width: selected ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.brandGreen
                  : Colors.black.withOpacity(.14),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        );
      }),
    );
  }
}

class _TopSoftPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TopSoftPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.82),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              icon,
              size: 14,
              color: Colors.black.withOpacity(.72),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
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
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;

  const _StatusPill({
    required this.text,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}

class _MiniPillAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MiniPillAction({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
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
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF111827),
          disabledBackgroundColor: const Color(0xFF111827).withOpacity(.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white.withOpacity(.70),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
    );
  }
}

class _GhostActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _GhostActionButton({
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
          backgroundColor: const Color(0xFF111827),
          disabledBackgroundColor: const Color(0xFF111827).withOpacity(.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white.withOpacity(.70),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
    );
  }
}

class _DangerActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _DangerActionButton({
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
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFB42318),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
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

class _SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _SurfaceCard({
    required this.child,
    super.key,
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

  String _displayNameFromUser(Map<String, dynamic>? data) {
    if (data == null) return "P";

    final fullName = _s(data["fullName"]);
    if (fullName.isNotEmpty) return fullName;

    final username = _s(data["username"]);
    if (username.isNotEmpty) return username;

    return "P";
  }

  String _buildPeopleAlreadyInText(int count, int maxMembers) {
    if (count <= 0) return "Be the first one in.";

    if (count == 1) return "1 person is already in.";
    return "$count people are already in.";
  }

  String _firstNameFromUser(Map<String, dynamic>? data) {
    if (data == null) return "Ping";

    final fullName = _s(data["fullName"]).trim();
    if (fullName.isNotEmpty) {
      final parts = fullName.split(RegExp(r"\s+"));
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        return parts.first.trim();
      }
    }

    final username = _s(data["username"]).trim();
    if (username.isNotEmpty) return username;

    return "Ping";
  }

  String _buildGoingText(List<String> firstNames, int totalCount) {
    if (totalCount <= 0) return "Be the first one going.";

    final visible = firstNames.where((e) => e.trim().isNotEmpty).toList();
    final others = totalCount - visible.length;

    if (visible.isEmpty) {
      return totalCount == 1 ? "1 person is going." : "$totalCount people are going.";
    }

    if (others > 0) {
      return "${visible.join(', ')} and $others other${others == 1 ? '' : 's'} are going.";
    }

    if (visible.length == 1) return "${visible.first} is going.";
    if (visible.length == 2) return "${visible[0]} and ${visible[1]} are going.";

    final head = visible.sublist(0, visible.length - 1).join(', ');
    final tail = visible.last;
    return "$head and $tail are going.";
  }

class _SmallFaceAvatar extends StatelessWidget {
  final String photoUrl;
  final String fallback;

  const _SmallFaceAvatar({
    this.photoUrl = "",
    this.fallback = "P",
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;
    final initial = fallback.trim().isEmpty
        ? "P"
        : fallback.trim()[0].toUpperCase();

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brandGreen.withOpacity(.12),
        border: Border.all(color: Colors.white, width: 2),
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
                initial,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  final String text;

  const _InitialAvatar({
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.brandGreen.withOpacity(.12),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.brandGreen,
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

class _MapGridPainter extends CustomPainter {
  final Color lineColor;

  const _MapGridPainter({
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    const gap = 28.0;

    for (double x = 0; x <= size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    for (double y = 0; y <= size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MapGridPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor;
  }
}

Future<void> _sendPingJoinedNotification({
  required String creatorUid,
  required String pingId,
  required String pingTitle,
  required String joinerUid,
}) async {
  if (creatorUid.trim().isEmpty) return;
  if (creatorUid == joinerUid) return;

  final db = FirebaseFirestore.instance;

  try {
    final joinerSnap = await db.collection("users").doc(joinerUid).get();
    final joinerData = joinerSnap.data() ?? <String, dynamic>{};

    final joinerName = _s(joinerData["fullName"]);
    final joinerPhotoUrl = _s(joinerData["photoUrl"]);

    await db
        .collection("users")
        .doc(creatorUid)
        .collection("notifications")
        .add({
      "type": "ping_joined",
      "title": "New member joined",
      "body": joinerName.isNotEmpty
          ? "$joinerName joined your ping."
          : "Someone joined your ping.",
      "senderUid": joinerUid,
      "senderName": joinerName,
      "senderPhotoUrl": joinerPhotoUrl,
      "pingId": pingId,
      "pingTitle": pingTitle,
      "read": false,
      "createdAt": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    debugPrint("❌ ping joined notification failed: $e");
  }
}

String _s(dynamic v) => (v ?? "").toString().trim();

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

bool _b(dynamic v) => v == true;

Map<String, dynamic> _map(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

DateTime? _ts(dynamic v) {
  if (v is Timestamp) return v.toDate();
  return null;
}

String _extractCreatorId(dynamic raw) {
  if (raw == null) return "";
  if (raw is String) return raw.trim();
  if (raw is DocumentReference) return raw.id.trim();
  if (raw is Map) {
    final v = raw["id"] ?? raw["uid"] ?? raw["creatorId"];
    if (v is String) return v.trim();
    if (v is DocumentReference) return v.id.trim();
  }
  return "";
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

String _distanceText(Map<String, dynamic> ping) {
  final location = _map(ping["location"]);

  final rawMeters = location["distanceMeters"] ??
      ping["distanceMeters"] ??
      location["proximityMeters"] ??
      ping["proximityMeters"];

  if (rawMeters is num) {
    final meters = rawMeters.toDouble();
    if (meters < 1000) return "${meters.round()} m away";
    return "${(meters / 1000).toStringAsFixed(1)} km away";
  }

  final rawKm = location["distanceKm"] ?? ping["distanceKm"];
  if (rawKm is num) {
    return "${rawKm.toDouble().toStringAsFixed(1)} km away";
  }

  return "Nearby";
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

String _privacySentence(String privacy) {
  final p = privacy.trim().toLowerCase();

  if (p.contains("friends")) {
    return "Only your friends can see and join this ping.";
  }
  if (p.contains("verified")) {
    return "Only verified users can see and join this ping.";
  }
  if (p.contains("private")) {
    return "This ping is controlled by the host and may require approval.";
  }
  return "This ping is public and anyone nearby can join.";
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

class _InlineBanner extends StatelessWidget {
  final String message;
  final bool isError;

  const _InlineBanner({
    required this.message,
    required this.isError,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isError
        ? const Color(0xFFB42318)
        : const Color(0xFF111827);

    final icon = isError
        ? PhosphorIcons.warningCircle(PhosphorIconsStyle.fill)
        : PhosphorIcons.info(PhosphorIconsStyle.fill);

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 8),
              color: Colors.black.withOpacity(.18),
            ),
          ],
        ),
        child: Row(
          children: [
            PhosphorIcon(
              icon,
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}