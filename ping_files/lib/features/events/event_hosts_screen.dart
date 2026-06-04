import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/features/events/event_cohost_picker_screen.dart';
import 'package:lottie/lottie.dart';

class EventHostsScreen extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  final Color themeSolid;
  final Color themeTop;
  final Color themeBottom;
  final bool showCreatedPopup;

  const EventHostsScreen({
    super.key,
    required this.eventId,
    required this.eventTitle,
    required this.themeSolid,
    required this.themeTop,
    required this.themeBottom,
    this.showCreatedPopup = false,
  });

@override
State<EventHostsScreen> createState() => _EventHostsScreenState();
}

class _EventHostsScreenState extends State<EventHostsScreen> {
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

    if (widget.showCreatedPopup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showEventCreatedPopup();
      });
    }
  }    

  Future<void> _showEventCreatedPopup() async {
    if (!mounted) return;

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(.72),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) {
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
            Navigator.of(context, rootNavigator: true).pop();
          }
        });

        return Stack(
          fit: StackFit.expand,
          children: [
            // left confetti
            IgnorePointer(
              child: Lottie.network(
                'https://assets10.lottiefiles.com/packages/lf20_obhph3sh.json',
                repeat: true,
                fit: BoxFit.cover,
              ),
            ),

            // right confetti mirrored
            IgnorePointer(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..scale(-1.0, 1.0),
                child: Lottie.network(
                  'https://assets10.lottiefiles.com/packages/lf20_obhph3sh.json',
                  repeat: true,
                  fit: BoxFit.cover,
                ),
              ),
            ),

            Center(
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 260,
                        child: Lottie.network(
                          'https://assets10.lottiefiles.com/packages/lf20_touohxv0.json',
                          repeat: true,
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "Event created!",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 34,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "Now invite co-hosts to help run it.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withOpacity(.78),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  _buildTopBar(context),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      child: _buildComposerSheet(context),
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

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _circleGlassButton(
            icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Invite hosts",
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(.96),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Owner, co-hosts, and pending invites",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _mutedText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroHeader() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(.10),
              Colors.white.withOpacity(.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.14),
              blurRadius: 22,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: widget.themeSolid.withOpacity(.18),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: widget.themeSolid.withOpacity(.30)),
              ),
              child: Icon(
                PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.eventTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 23,
                      height: 1.08,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Manage who owns the room, who helps run it, and who is still waiting for approval.",
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(.76),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvitePanel(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panelFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _panelBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: widget.themeSolid.withOpacity(.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: widget.themeSolid.withOpacity(.24)),
            ),
            child: Icon(
              PhosphorIcons.userPlus(PhosphorIconsStyle.bold),
              size: 18,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Invite co-hosts",
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: _softText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Bring in up to 6 people to help manage the event.",
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _mutedText,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _inviteButton(context),
        ],
      ),
    );
  }

  Widget _buildComposerSheet(BuildContext context) {
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
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection("events")
            .doc(widget.eventId)
            .collection("hosts")
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(widget.themeSolid),
                ),
              ),
            );
          }

          final docs = snapshot.data!.docs;

          final ownerDocs = docs.where((d) {
            final data = d.data();
            return (data["role"] ?? "") == "owner" &&
                (data["status"] ?? "") == "active";
          }).toList();

          final activeCohosts = docs.where((d) {
            final data = d.data();
            return (data["role"] ?? "") == "cohost" &&
                (data["status"] ?? "") == "active";
          }).toList();

          final pendingCohosts = docs.where((d) {
            final data = d.data();
            return (data["role"] ?? "") == "cohost" &&
                (data["status"] ?? "") == "pending";
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInvitePanel(context),
              _thinDivider(),
              _groupHeader(
                title: "Owner",
                subtitle: "The person with final control of the event.",
              ),
              const SizedBox(height: 14),
              if (ownerDocs.isEmpty)
                _emptyCard("No active owner found.")
              else
                ...ownerDocs.map(
                  (doc) => _hostTile(
                    uid: (doc.data()["uid"] ?? doc.id).toString(),
                    roleLabel: "Owner",
                    statusLabel: "Active",
                    statusFill: widget.themeSolid.withOpacity(.16),
                    statusBorder: widget.themeSolid.withOpacity(.28),
                  ),
                ),
              _thinDivider(),
              _groupHeader(
                title: "Co-hosts",
                subtitle: "People helping run the event right now.",
              ),
              const SizedBox(height: 14),
              if (activeCohosts.isEmpty)
                _emptyCard("No active co-hosts yet.")
              else
                ...activeCohosts.map(
                  (doc) => _hostTile(
                    uid: (doc.data()["uid"] ?? doc.id).toString(),
                    roleLabel: "Co-host",
                    statusLabel: "Active",
                    statusFill: widget.themeSolid.withOpacity(.16),
                    statusBorder: widget.themeSolid.withOpacity(.28),
                  ),
                ),
              _thinDivider(),
              _groupHeader(
                title: "Pending",
                subtitle: "Invites sent but not active yet.",
              ),
              const SizedBox(height: 14),
              if (pendingCohosts.isEmpty)
                _emptyCard("No pending invites.")
              else
                ...pendingCohosts.map(
                  (doc) => _hostTile(
                    uid: (doc.data()["uid"] ?? doc.id).toString(),
                    roleLabel: "Co-host",
                    statusLabel: "Pending",
                    statusFill: Colors.white.withOpacity(.08),
                    statusBorder: Colors.white.withOpacity(.12),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _groupHeader({
    required String title,
    String? subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.white.withOpacity(.90),
            letterSpacing: .2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: _mutedText,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }

  Widget _thinDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Container(
        height: 1,
        color: Colors.white.withOpacity(.08),
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

  Widget _hostTile({
    required String uid,
    required String roleLabel,
    required String statusLabel,
    required Color statusFill,
    required Color statusBorder,
  }) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection("users").doc(uid).get(),
      builder: (context, snapshot) {
        final user = snapshot.data?.data() ?? <String, dynamic>{};

        final fullName = (user["fullName"] ?? "User").toString();
        final username = (user["username"] ?? "").toString();
        final photoUrl = (user["photoUrl"] ?? "").toString();
        final verification =
            Map<String, dynamic>.from(user["verification"] ?? {});
        final verified = verification["status"] == "verified";

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
                backgroundImage:
                    photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                child: photoUrl.isEmpty
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
                            fullName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _softText,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (verified) ...[
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
                      roleLabel + (username.isNotEmpty ? " • @$username" : ""),
                      style: TextStyle(
                        color: _mutedText,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: statusFill,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: statusBorder),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: Colors.white.withOpacity(.96),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        );
      },
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

  Widget _inviteButton(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection("events").doc(widget.eventId).get(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? <String, dynamic>{};
        final creatorId = (data["creatorId"] ?? "").toString();
        final isOwner = creatorId == myUid;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: !isOwner
                ? null
                : () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EventCohostPickerScreen(
                          eventId: widget.eventId,
                          themeSolid: widget.themeSolid,
                          themeTop: widget.themeTop,
                          themeBottom: widget.themeBottom,
                        ),
                      ),
                    );
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: isOwner ? widget.themeSolid : Colors.white.withOpacity(.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isOwner ? widget.themeSolid : Colors.white.withOpacity(.10),
                ),
              ),
              child: Text(
                "Invite co-host",
                style: TextStyle(
                  color: Colors.white.withOpacity(isOwner ? 1 : .55),
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}