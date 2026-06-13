// Notifications panel moved from feed_tab.dart in this round so the bell
// sits on the map/discovery tab next to the existing map button.
//
// The bell, the bottom sheet, the tile, the avatar, the loading skeletons,
// the section grouping and the unread-dot colour are all identical to the
// previous feed version; only the bell's *visual style* was changed to
// match the map tab's top-right "refresh location" button (46x46, dark
// fill, rounded 16, white icon) so the icon family stays consistent.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/events/event_details_screen.dart';
import 'package:ping_files/features/pings/manage_ping_screen.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/features/pings/ping_join_notifications.dart';
import 'package:ping_files/features/pings/ping_join_request_actions.dart';

class NotificationsBell extends StatelessWidget {
  final String uid;
  const NotificationsBell({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    final unreadStream = FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .collection("notifications")
        .where("read", isEqualTo: false)
        .limit(1)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: unreadStream,
      builder: (context, snap) {
        final hasUnread = (snap.data?.docs.isNotEmpty ?? false);

        // Styled to match the map tab's top-right "refresh location" button
        // (46x46, dark fill, rounded 16, white icon) so the bell feels native
        // to the map UI rather than a feed-style glass pill.
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: Colors.transparent,
                builder: (_) => NotificationsSheet(uid: uid),
              );
            },
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.84),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(.08)),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                    child: Icon(
                      PhosphorIcons.bell(PhosphorIconsStyle.regular),
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: 9,
                      top: 9,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class NotificationsSheet extends StatefulWidget {
  final String uid;
  const NotificationsSheet({super.key, required this.uid});

  @override
  State<NotificationsSheet> createState() => _NotificationsSheetState();
}

class _NotificationsSheetState extends State<NotificationsSheet> {
  static const int _initialLimit = 15;
  static const int _step = 15;
  static const int _maxLimit = 50;

  int _currentLimit = _initialLimit;
  final ScrollController _scrollController = ScrollController();

  void _loadMore() {
    if (_currentLimit >= _maxLimit) return;

    setState(() {
      _currentLimit = (_currentLimit + _step).clamp(_initialLimit, _maxLimit);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection("users")
        .doc(widget.uid)
        .collection("notifications")
        .orderBy("createdAt", descending: true)
        .limit(_currentLimit)
        .snapshots();

    return _GlassBottomSheet(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.86,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Notifications",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final unread = await FirebaseFirestore.instance
                          .collection("users")
                          .doc(widget.uid)
                          .collection("notifications")
                          .where("read", isEqualTo: false)
                          .get();

                      final batch = FirebaseFirestore.instance.batch();
                      for (final doc in unread.docs) {
                        batch.update(doc.reference, {"read": true});
                      }
                      await batch.commit();
                    },
                    child: const Text(
                      "Mark all read",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: stream,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const _NotificationsLoadingList();
                  }

                  if (snap.hasError) {
                    return const Center(
                      child: Text(
                        "Couldn’t load notifications",
                        style: TextStyle(fontFamily: "Nunito"),
                      ),
                    );
                  }

                  final docs = snap.data?.docs ?? [];

                  if (docs.isEmpty) {
                    return Center(
                      child: Text(
                        "No notifications yet.",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                    );
                  }

                  final sections = _NotificationSections.fromDocs(docs);

                  final canLoadMore =
                      docs.length >= _currentLimit && _currentLimit < _maxLimit;

                  return ListView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                    children: [
                      if (sections.today.isNotEmpty) ...[
                        const _SkeletonSectionHeader("Today"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.today, widget.uid),
                        const SizedBox(height: 18),
                      ],
                      if (sections.thisWeek.isNotEmpty) ...[
                        const _SkeletonSectionHeader("This week"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.thisWeek, widget.uid),
                        const SizedBox(height: 18),
                      ],
                      if (sections.earlier.isNotEmpty) ...[
                        const _SkeletonSectionHeader("Earlier"),
                        const SizedBox(height: 10),
                        ..._buildNotificationTiles(sections.earlier, widget.uid),
                        const SizedBox(height: 18),
                      ],

                      if (canLoadMore)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: _loadMore,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black,
                                side: BorderSide(
                                  color: Colors.black,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                backgroundColor: Colors.white.withOpacity(.75),
                              ),
                              child: Text(
                                _currentLimit + _step >= _maxLimit
                                    ? "Load last notifications"
                                    : "Load more notifications",
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildNotificationTiles(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String uid,
  ) {
    return List.generate(docs.length, (i) {
      final doc = docs[i];
      return Padding(
        padding: EdgeInsets.only(bottom: i == docs.length - 1 ? 0 : 10),
        child: _NotificationTile(
          currentUid: uid,
          notifRef: doc.reference,
          data: doc.data(),
        ),
      );
    });
  }
}

class _NotificationTile extends StatefulWidget {
  final String currentUid;
  final DocumentReference<Map<String, dynamic>> notifRef;
  final Map<String, dynamic> data;

  const _NotificationTile({
    required this.currentUid,
    required this.notifRef,
    required this.data,
  });

  @override
  State<_NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<_NotificationTile> {
  bool _busy = false;

  Future<void> _openNotificationTarget(
    BuildContext context, {
    required bool read,
    required String type,
    required String senderUid,
    required String pingId,
    required String eventId,
  }) async {
    if (!read) {
      await widget.notifRef.set({"read": true}, SetOptions(merge: true));
    }

    if ((type == "ping_joined" ||
          type == "ping_join_request" ||
          type == "ping_member_left") &&
      pingId.isNotEmpty) {
    if (!context.mounted) return;
    await openManagePingScreen(
      context: context,
      pingId: pingId,
    );
    return;
  }

  if ((type == "event_cohost_invite" ||
          type == "event_cohost_invite_denied" ||
          type == "event_cohost_invite_accepted") &&
      eventId.isNotEmpty) {
    if (!context.mounted) return;
    await _openEventPreview(
      context,
      eventId: eventId,
    );
    return;
  }

  if (type == "ping_invite" && pingId.isNotEmpty) {
    if (!context.mounted) return;
    await openPingDetailsSheet(
      context: context,
      pingId: pingId,
    );
    return;
  }

    if (type == "profile_view") {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileEngagementScreen(uid: widget.currentUid),
        ),
      );
      return;
    }

    if (type == "community_invite") {
      return;
    }

    if (senderUid.isNotEmpty) {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileTab(profileUid: senderUid),
        ),
      );
    }
  }

  Future<void> _openEventPreview(
    BuildContext context, {
    required String eventId,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection("events")
        .doc(eventId)
        .get();

    if (!snap.exists) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Event no longer exists.")),
      );
      return;
    }

    final data = snap.data() ?? <String, dynamic>{};

    if (!context.mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventDetailsScreen(
          data: EventDetailsData.fromMap(snap.id, data),
        ),
      ),
    );
  }

  Future<void> _handleEventCohostInviteAction({
    required bool approve,
  }) async {
    if (_busy) return;

    final data = widget.data;
    final eventId = (data["eventId"] ?? "").toString().trim();
    final inviterUid = (data["senderUid"] ?? "").toString().trim();
    final eventTitle = (data["eventTitle"] ?? "").toString().trim();
    final eventCoverImageUrl =
        (data["eventCoverImageUrl"] ?? "").toString().trim();
    final eventCoverPresetAssetPath =
        (data["eventCoverPresetAssetPath"] ?? "").toString().trim();

    final currentUid = widget.currentUid;
    if (eventId.isEmpty || currentUid.isEmpty) {
      debugPrint("❌ cohost action aborted: missing eventId/currentUid");
      return;
    }

    setState(() => _busy = true);

    try {
      final db = FirebaseFirestore.instance;
      final eventRef = db.collection("events").doc(eventId);
      final hostRef = eventRef.collection("hosts").doc(currentUid);

      debugPrint("▶️ cohost action start");
      debugPrint("  approve=$approve");
      debugPrint("  eventId=$eventId");
      debugPrint("  currentUid=$currentUid");
      debugPrint("  inviterUid=$inviterUid");

      await db.runTransaction((tx) async {
        final eventSnap = await tx.get(eventRef);
        final hostSnap = await tx.get(hostRef);

        debugPrint("  event exists=${eventSnap.exists}");
        debugPrint("  host exists=${hostSnap.exists}");

        if (!eventSnap.exists) {
          throw Exception("Event no longer exists.");
        }

        if (!hostSnap.exists) {
          throw Exception("Host invite doc not found.");
        }

        final hostData = hostSnap.data() ?? <String, dynamic>{};

        debugPrint("  hostData=$hostData");

        final Map<String, dynamic> nextHostData;

        if (approve) {
          nextHostData = {
            "uid": currentUid,
            "role": "cohost",
            "status": "active",
            "invitedBy": hostData["invitedBy"],
            "invitedAt": hostData["invitedAt"],
            "respondedAt": FieldValue.serverTimestamp(),
            "addedAt": FieldValue.serverTimestamp(),
          };
        } else {
          nextHostData = {
            "uid": currentUid,
            "role": "cohost",
            "status": "declined",
            "invitedBy": hostData["invitedBy"],
            "invitedAt": hostData["invitedAt"],
            "respondedAt": FieldValue.serverTimestamp(),
          };
        }

        debugPrint("  nextHostKeys=${nextHostData.keys.toList()}");
        debugPrint("  nextHostStatus=${nextHostData["status"]}");

        tx.set(
          hostRef,
          nextHostData,
          SetOptions(merge: false),
        );

        if (approve && inviterUid.isNotEmpty && inviterUid != currentUid) {
          final acceptNotifRef = db
              .collection("users")
              .doc(inviterUid)
              .collection("notifications")
              .doc();

          debugPrint("  sending accept notification to $inviterUid");

          tx.set(
            acceptNotifRef,
            {
              "type": "event_cohost_invite_accepted",
              "eventId": eventId,
              "eventTitle": eventTitle,
              "eventCoverImageUrl": eventCoverImageUrl,
              "eventCoverPresetAssetPath": eventCoverPresetAssetPath,
              "senderUid": currentUid,
              "recipientUid": inviterUid,
              "title": "Co-host invite accepted",
              "body": eventTitle.isNotEmpty
                  ? 'accepted your co-host invite for "$eventTitle".'
                  : "accepted your co-host invite.",
              "createdAt": FieldValue.serverTimestamp(),
              "read": false,
            },
          );
        }

        if (!approve && inviterUid.isNotEmpty && inviterUid != currentUid) {
          final denyNotifRef = db
              .collection("users")
              .doc(inviterUid)
              .collection("notifications")
              .doc();

          debugPrint("  sending decline notification to $inviterUid");

          tx.set(
            denyNotifRef,
            {
              "type": "event_cohost_invite_denied",
              "eventId": eventId,
              "eventTitle": eventTitle,
              "eventCoverImageUrl": eventCoverImageUrl,
              "eventCoverPresetAssetPath": eventCoverPresetAssetPath,
              "senderUid": currentUid,
              "recipientUid": inviterUid,
              "title": "Co-host invite declined",
              "body": eventTitle.isNotEmpty
                  ? 'declined your co-host invite for "$eventTitle".'
                  : "declined your co-host invite.",
              "createdAt": FieldValue.serverTimestamp(),
              "read": false,
            },
          );
        }

        tx.set(
          widget.notifRef,
          {
            "actionState": approve ? "approved" : "denied",
            "resolvedAt": FieldValue.serverTimestamp(),
            "read": true,
          },
          SetOptions(merge: true),
        );
      });

      debugPrint("✅ cohost action success");

      if (!mounted) return;

      if (approve) {
        await _openEventPreview(
          context,
          eventId: eventId,
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Co-host invite declined.")),
        );
      }
    } on FirebaseException catch (e, st) {
      debugPrint("🔥 FirebaseException on cohost action");
      debugPrint("  code=${e.code}");
      debugPrint("  message=${e.message}");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            "Firebase ${e.code}: ${e.message ?? 'unknown error'}",
          ),
        ),
      );
    } catch (e, st) {
      debugPrint("🔥 generic error on cohost action: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst("Exception: ", ""),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleRequestAction({
    required bool approve,
  }) async {
    if (_busy) return;

    final data = widget.data;
    final pingId = (data["pingId"] ?? "").toString().trim();
    final requestUid =
        (data["requestUid"] ?? data["senderUid"] ?? "").toString().trim();

    if (pingId.isEmpty || requestUid.isEmpty) return;

    setState(() => _busy = true);

    try {
      final changed = approve
          ? await approvePingJoinRequest(
              pingId: pingId,
              memberUid: requestUid,
            )
          : await denyPingJoinRequest(
              pingId: pingId,
              memberUid: requestUid,
            );

      if (!changed) {
        await widget.notifRef.set({
          "actionState": approve ? "approved" : "denied",
          "resolvedAt": FieldValue.serverTimestamp(),
          "read": true,
        }, SetOptions(merge: true));

        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text("Request already handled.")),
        );
        return;
      }

      await Future.wait([
        sendPingJoinDecisionNotification(
          recipientUid: requestUid,
          actorUid: widget.currentUid,
          pingId: pingId,
          approved: approve,
        ),
        widget.notifRef.set({
          "actionState": approve ? "approved" : "denied",
          "resolvedAt": FieldValue.serverTimestamp(),
          "read": true,
        }, SetOptions(merge: true)),
      ]);

      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            approve ? "Request approved." : "Request denied.",
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final msg = e.toString();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            msg.contains("ping-full-on-approve")
                ? "Ping is full. Increase the limit in Ping Settings first."
                : "Couldn't update request.",
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;

    final type = (data["type"] ?? "").toString();
    final senderUid = (data["senderUid"] ?? "").toString();
    final senderName = (data["senderName"] ?? "").toString();
    final senderPhotoUrlStored = (data["senderPhotoUrl"] ?? "").toString();
    final eventId = (data["eventId"] ?? "").toString().trim();
    final pingId = (data["pingId"] ?? "").toString();
    final pingTitle = (data["pingTitle"] ?? "").toString();
    final requestUid = (data["requestUid"] ?? senderUid).toString();
    final actionState =
        (data["actionState"] ?? "pending").toString().trim().toLowerCase();
    final read = data["read"] == true;
    final createdAt = _notificationDateFrom(data["createdAt"]);
    final relativeTime = _relativeTimeShort(createdAt);
    final viewerCity = (data["viewerCity"] ?? "").toString().trim();
    final canViewEngagement = type == "profile_view";

    final senderRef = senderUid.isNotEmpty
        ? FirebaseFirestore.instance.collection("users").doc(senderUid)
        : null;
    final canManageEventCohostInvite =
        type == "event_cohost_invite" && actionState == "pending";    

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: senderRef?.snapshots(),
      builder: (context, senderSnap) {
        final senderData = senderSnap.data?.data() ?? {};
        final liveName = (senderData["fullName"] ?? "").toString().trim();
        final livePhotoUrl = (senderData["photoUrl"] ?? "").toString().trim();
        final canVisitCommunity = type == "community_invite";

        final displayName = liveName.isNotEmpty
            ? liveName
            : (senderName.isNotEmpty ? senderName : "Someone");

        final displayPhotoUrl = livePhotoUrl.isNotEmpty
            ? livePhotoUrl
            : senderPhotoUrlStored;

        final canViewPing =
            (type == "ping_joined" ||
                type == "ping_member_left" ||
                type == "ping_invite") &&
            pingId.isNotEmpty;

        final canManageRequest = type == "ping_join_request" &&
            pingId.isNotEmpty &&
            requestUid.isNotEmpty;

        final pingButtonLabel =
            type == "ping_invite" ? "View ping" : "Manage ping";

        final pingButtonIcon = type == "ping_invite"
            ? PhosphorIcons.mapPin(PhosphorIconsStyle.fill)
            : PhosphorIcons.gearSix(PhosphorIconsStyle.fill);

        TextSpan boldNameSpan(String name) {
          return TextSpan(
            text: name,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
            ),
          );
        }    

        String displayTitle;
        InlineSpan displayBody;

        if (type == "friend_request" || type == "connection_request") {
          displayTitle = "Connection request";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " sent you a "),
              const TextSpan(
                text: "connection",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(text: " request."),
            ],
          );
        } else if (type == "friend_accept" || type == "connection_accept") {
          displayTitle = "Connection accepted";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " accepted your "),
              const TextSpan(
                text: "connection",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(text: " request."),
            ],
          );
        } else if (type == "event_cohost_invite_accepted") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite accepted";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' accepted your co-host invite for "$eventTitle".'
                    : " accepted your co-host invite.",
              ),
            ],
          );
        }  
        else if (type == "event_cohost_invite_denied") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite declined";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' declined your co-host invite for "$eventTitle".'
                    : " declined your co-host invite.",
              ),
            ],
          );
        } else if (type == "ping_joined") {
          displayTitle = "Ping update";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " joined your ping."),
            ],
          );
        } else if (type == "ping_join_request") {
          displayTitle = "Join request";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' requested to join "$pingTitle".'
                    : " requested to join your ping.",
              ),
            ],
          );
        } else if (type == "ping_request_approved") {
          displayTitle = "Join request approved";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' approved your request to join "$pingTitle".'
                    : " approved your join request.",
              ),
            ],
          );
        } else if (type == "ping_request_denied") {
          displayTitle = "Join request denied";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' denied your request to join "$pingTitle".'
                    : " denied your join request.",
              ),
            ],
          );
        } else if (type == "event_cohost_invite") {
          final eventTitle = (data["eventTitle"] ?? "").toString().trim();

          displayTitle = "Co-host invite";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: eventTitle.isNotEmpty
                    ? ' invited you to co-host "$eventTitle".'
                    : " invited you to co-host an event.",
              ),
            ],
          );
        } else if (type == "ping_member_removed") {
          displayTitle = "Removed from ping";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: pingTitle.isNotEmpty
                    ? ' removed you from "$pingTitle".'
                    : " removed you from a ping.",
              ),
            ],
          );
        } else if (type == "ping_member_left") {
          displayTitle = "Member left";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              const TextSpan(text: " left your ping."),
            ],
          );
        } else if (type == "community_invite") {
          final communityName = ((data["communitySnapshot"] ?? {})["name"] ?? "")
              .toString()
              .trim();

          displayTitle = "Community invite";
          displayBody = TextSpan(
            children: [
              boldNameSpan(displayName),
              TextSpan(
                text: communityName.isNotEmpty
                    ? " invited you to check out $communityName."
                    : " invited you to check out a community.",
              ),
            ],
          );
        }
        else if (type == "profile_view") {
          displayTitle = "Profile view";

          final actorName = displayName != "Someone"
              ? displayName
              : (viewerCity.isNotEmpty ? "Someone from $viewerCity" : "Someone");

          displayBody = TextSpan(
            children: [
              boldNameSpan(actorName),
              const TextSpan(text: " viewed your profile."),
            ],
          );
        } else if (type == "ping_invite") {
            displayTitle = "Ping invite";
            displayBody = TextSpan(
              children: [
                boldNameSpan(displayName),
                TextSpan(
                  text: pingTitle.isNotEmpty
                      ? ' invited you to "$pingTitle".'
                      : " invited you to a ping.",
                ),
              ],
            );
          }
          else {
          final rawTitle = (data["title"] ?? "").toString();
          final rawBody = (data["body"] ?? "").toString();

          displayTitle = rawTitle.isNotEmpty ? rawTitle : "Notification";
          displayBody = TextSpan(
            text: rawBody.isNotEmpty ? rawBody : "Open to view details.",
          );
        }

        final isEventCohostInvite = type == "event_cohost_invite";
        final eventCoverImageUrl =
            (data["eventCoverImageUrl"] ?? "").toString().trim();
        final eventCoverPresetAssetPath =
            (data["eventCoverPresetAssetPath"] ?? "").toString().trim();

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openNotificationTarget(
              context,
              read: read,
              type: type,
              senderUid: senderUid,
              pingId: pingId,
              eventId: eventId,
            ),
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.80),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.black.withOpacity(.06)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  isEventCohostInvite
                      ? _EventNotificationCoverThumb(
                          imageUrl: eventCoverImageUrl,
                          presetAssetPath: eventCoverPresetAssetPath,
                        )
                      : _NotificationAvatar(
                          photoUrl: displayPhotoUrl,
                          type: type,
                        ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                displayTitle,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            if (relativeTime.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Text(
                                relativeTime,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: Colors.black.withOpacity(.42),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        RichText(
                          text: TextSpan(
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w400,
                              fontSize: 13.5,
                              color: Colors.black.withOpacity(.62),
                              height: 1.28,
                            ),
                            children: [displayBody],
                          ),
                        ),
                        if (canManageEventCohostInvite) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _handleEventCohostInviteAction(
                                            approve: true,
                                          ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.brandGreen,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: const Text(
                                    "Accept",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _handleEventCohostInviteAction(
                                            approve: false,
                                          ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFB42318).withOpacity(.10),
                                    foregroundColor: const Color(0xFFB42318),
                                    elevation: 0,
                                    shadowColor: Colors.transparent,
                                    surfaceTintColor: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: const Text(
                                    "Deny",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFB42318),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (canManageRequest) ...[
                          const SizedBox(height: 12),
                          if (actionState == "pending")
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _handleRequestAction(
                                              approve: true,
                                            ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.brandGreen,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    child: _busy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Text(
                                            "Approve",
                                            style: TextStyle(
                                              fontFamily: "Nunito",
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _handleRequestAction(
                                              approve: false,
                                            ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFFB42318),
                                      side: const BorderSide(
                                        color: Color(0xFFB42318),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    child: const Text(
                                      "Deny",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          else
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: actionState == "approved"
                                    ? AppColors.brandGreen.withOpacity(.10)
                                    : const Color(0xFFB42318).withOpacity(.10),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                actionState == "approved"
                                    ? "Request approved"
                                    : "Request denied",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                  color: actionState == "approved"
                                      ? AppColors.brandGreen
                                      : const Color(0xFFB42318),
                                ),
                              ),
                            ),
                        ],
                        if (canViewPing) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _openNotificationTarget(
                                context,
                                read: read,
                                type: type,
                                senderUid: senderUid,
                                pingId: pingId,
                                eventId: eventId,
                              ),
                              icon: PhosphorIcon(
                                pingButtonIcon,
                                size: 16,
                                color: Colors.white,
                              ),
                              label: Text(
                                pingButtonLabel,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (canViewEngagement) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => _openNotificationTarget(
                                context,
                                read: read,
                                type: type,
                                senderUid: senderUid,
                                pingId: pingId,
                                eventId: eventId,
                              ),
                              icon: PhosphorIcon(
                                PhosphorIcons.chartLineUp(
                                  PhosphorIconsStyle.fill,
                                ),
                                size: 16,
                                color: Colors.white,
                              ),
                              label: const Text(
                                "View engagement",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (canVisitCommunity) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                if (!read) {
                                  await widget.notifRef.set(
                                    {"read": true},
                                    SetOptions(merge: true),
                                  );
                                }
                                // wired later
                              },
                              icon: PhosphorIcon(
                                PhosphorIcons.arrowSquareOut(
                                  PhosphorIconsStyle.fill,
                                ),
                                size: 16,
                                color: Colors.white,
                              ),
                              label: const Text(
                                "Visit community",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!read) ...[
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SkeletonSectionHeader extends StatelessWidget {
  final String title;
  const _SkeletonSectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        title,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Colors.black.withOpacity(.95),
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _NotificationAvatar extends StatelessWidget {
  final String photoUrl;
  final String type;

  const _NotificationAvatar({
    required this.photoUrl,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;
    final badge = _NotificationBadgeStyle.fromType(type);

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandGreen.withOpacity(.10),
              image: hasPhoto
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: !hasPhoto
                ? Icon(
                    PhosphorIcons.user(PhosphorIconsStyle.light),
                    color: AppColors.brandGreen,
                    size: 20,
                  )
                : null,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: badge.background,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Center(
                child: PhosphorIcon(
                  badge.icon,
                  size: 11,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventNotificationCoverThumb extends StatelessWidget {
  final String imageUrl;
  final String presetAssetPath;

  const _EventNotificationCoverThumb({
    required this.imageUrl,
    required this.presetAssetPath,
  });

  @override
  Widget build(BuildContext context) {
    final hasNetwork = imageUrl.trim().isNotEmpty;
    final hasAsset = presetAssetPath.trim().isNotEmpty;

    ImageProvider? provider;
    if (hasNetwork) {
      provider = NetworkImage(imageUrl);
    } else if (hasAsset) {
      provider = AssetImage(presetAssetPath);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.08),
          image: provider != null
              ? DecorationImage(
                  image: provider,
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: provider == null
            ? Icon(
                PhosphorIcons.calendarDots(PhosphorIconsStyle.fill),
                size: 18,
                color: Colors.black.withOpacity(.55),
              )
            : null,
      ),
    );
  }
}

class _NotificationsLoadingList extends StatefulWidget {
  const _NotificationsLoadingList();

  @override
  State<_NotificationsLoadingList> createState() =>
      _NotificationsLoadingListState();
}

class _NotificationsLoadingListState extends State<_NotificationsLoadingList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = 0.58 + (_controller.value * 0.24);

        return ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [
            const _SkeletonSectionHeader("Today"),
            const SizedBox(height: 10),
            ...List.generate(
              3,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NotificationTileSkeleton(opacity: pulse),
              ),
            ),
            const SizedBox(height: 18),
            const _SkeletonSectionHeader("This week"),
            const SizedBox(height: 10),
            ...List.generate(
              2,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NotificationTileSkeleton(opacity: pulse),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NotificationTileSkeleton extends StatelessWidget {
  final double opacity;
  const _NotificationTileSkeleton({required this.opacity});

  @override
  Widget build(BuildContext context) {
    Color bone(double base) => Colors.black.withOpacity(base * opacity);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.80),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bone(.07),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 13,
                        decoration: BoxDecoration(
                          color: bone(.08),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 42,
                      height: 11,
                      decoration: BoxDecoration(
                        color: bone(.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  height: 11,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: bone(.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: .72,
                  child: Container(
                    height: 11,
                    decoration: BoxDecoration(
                      color: bone(.05),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FractionallySizedBox(
                  widthFactor: .42,
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen.withOpacity(.10 * opacity),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationSections {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> today;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> thisWeek;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> earlier;

  const _NotificationSections({
    required this.today,
    required this.thisWeek,
    required this.earlier,
  });

  factory _NotificationSections.fromDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfWeek = startOfToday.subtract(
      Duration(days: startOfToday.weekday - 1),
    );

    final today = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final thisWeek = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final earlier = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    for (final doc in docs) {
      final data = doc.data();
      final createdAt = _notificationDateFrom(data["createdAt"]);

      if (createdAt == null) {
        earlier.add(doc);
        continue;
      }

      final local = createdAt.toLocal();

      if (!local.isBefore(startOfToday)) {
        today.add(doc);
      } else if (!local.isBefore(startOfWeek)) {
        thisWeek.add(doc);
      } else {
        earlier.add(doc);
      }
    }

    return _NotificationSections(
      today: today,
      thisWeek: thisWeek,
      earlier: earlier,
    );
  }
}

DateTime? _notificationDateFrom(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

String _relativeTimeShort(DateTime? value) {
  if (value == null) return "";

  final now = DateTime.now();
  final local = value.toLocal();
  final diff = now.difference(local);

  if (diff.inSeconds < 10) return "just now";
  if (diff.inMinutes < 1) return "${diff.inSeconds}s ago";
  if (diff.inHours < 1) return "${diff.inMinutes}m ago";
  if (diff.inDays < 1) return "${diff.inHours}h ago";
  if (diff.inDays < 7) return "${diff.inDays}d ago";

  final weeks = (diff.inDays / 7).floor();
  if (weeks < 5) return "${weeks}w ago";

  final months = (diff.inDays / 30).floor();
  if (months < 12) return "${months}mo ago";

  final years = (diff.inDays / 365).floor();
  return "${years}y ago";
}

class _NotificationBadgeStyle {
  final IconData icon;
  final Color background;

  const _NotificationBadgeStyle({
    required this.icon,
    required this.background,
  });

  factory _NotificationBadgeStyle.fromType(String type) {
    switch (type) {
      case "friend_request":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userPlus(PhosphorIconsStyle.fill),
          background: const Color(0xFF2F6BFF),
        );
      case "friend_accept":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userCheck(PhosphorIconsStyle.fill),
          background: const Color(0xFF1E4ED8),
        );
      case "ping_joined":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
          background: const Color(0xFFE5484D),
        );
      case "ping_join_request":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.hourglassSimpleMedium(PhosphorIconsStyle.fill),
          background: const Color(0xFF4F46E5),
        );
      case "ping_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );  
      case "event_cohost_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.calendarPlus(PhosphorIconsStyle.fill),
          background: const Color(0xFF7C3AED),
        );  
      case "event_cohost_invite_denied":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );  
      case "event_cohost_invite_accepted":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );  
      case "ping_request_approved":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFF16A34A),
        );
      case "ping_request_denied":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.xCircle(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );
      case "ping_member_removed":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.userMinus(PhosphorIconsStyle.fill),
          background: const Color(0xFFB42318),
        );
      case "ping_member_left":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.signOut(PhosphorIconsStyle.fill),
          background: const Color(0xFF6B7280),
        );  
      case "community_invite":
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.usersFour(PhosphorIconsStyle.fill),
          background: const Color(0xFF2F6BFF),
        );  
      default:
        return _NotificationBadgeStyle(
          icon: PhosphorIcons.bell(PhosphorIconsStyle.fill),
          background: const Color(0xFF6B7280),
        );
    }
  }
}
