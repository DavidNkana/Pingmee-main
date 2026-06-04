import 'dart:async';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:ping_files/features/pings/join_ping_sheet.dart';
import 'package:ping_files/features/pings/manage_ping_screen.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:google_fonts/google_fonts.dart';

/// Call this to open the redesigned Ping Details.
Future<void> openPingDetailsSheet({
  required BuildContext context,
  required String pingId,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(.35),
    builder: (_) => _PingDetailsFullScreen(pingId: pingId),
  );
}

Future<void> _openExternalUrl(String url) async {
  final u = Uri.tryParse(url);
  if (u == null) return;

  await launchUrl(u, mode: LaunchMode.externalApplication);
}

/// Full-screen-ish sheet (looks like a screen, but is a modal).
class _PingDetailsFullScreen extends StatelessWidget {
  final String pingId;
  const _PingDetailsFullScreen({required this.pingId});

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(28),
        topRight: Radius.circular(28),
      ),
      child: Container(
        height: h * 0.95,
        width: double.infinity,
        color: const Color(0xFFF6F7F9),
        child: SafeArea(
          top: false,
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream:
                FirebaseFirestore.instance
                    .collection("pings")
                    .doc(pingId)
                    .snapshots(),
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

              final doc = snap.data!;
              if (!doc.exists || doc.data() == null) {
                return _EmptyState(onClose: () => Navigator.pop(context));
              }

              final data = doc.data()!;
              return _PingDetailsBody(
                pingId: pingId,
                ping: data,
                onClose: () => Navigator.pop(context),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PingDetailsBody extends StatefulWidget {
  final String pingId;
  final Map<String, dynamic> ping;
  final VoidCallback onClose;

  const _PingDetailsBody({
    required this.pingId,
    required this.ping,
    required this.onClose,
  });

  @override
  State<_PingDetailsBody> createState() => _PingDetailsBodyState();
}

class _PingDetailsBodyState extends State<_PingDetailsBody> {
  bool _viewRecorded = false;
  bool _recordingView = false;
  bool _savingPing = false;

  @override
    void initState() {
      super.initState();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeRecordView();
      });
    }

    @override
    void didUpdateWidget(covariant _PingDetailsBody oldWidget) {
      super.didUpdateWidget(oldWidget);

      if (oldWidget.pingId != widget.pingId) {
        _viewRecorded = false;
        _recordingView = false;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _maybeRecordView();
        });
      }
    }

  Future<void> _maybeRecordView() async {
    if (_viewRecorded || _recordingView) return;

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return;

    _recordingView = true;

    final pingRef = FirebaseFirestore.instance.collection("pings").doc(widget.pingId);
    final viewRef = pingRef.collection("views").doc(myUid);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        debugPrint("👀 transaction started");

        final pingSnap = await tx.get(pingRef);
        debugPrint("👀 ping exists: ${pingSnap.exists}");

        if (!pingSnap.exists) return;

        final pingData = pingSnap.data() as Map<String, dynamic>;
        final creatorId = _extractCreatorId(pingData["creatorId"]);
        debugPrint("👀 creatorId from tx: $creatorId");

        if (creatorId == myUid) {
          debugPrint("👀 skipping view: creator opened own ping");
          return;
        }

        final viewSnap = await tx.get(viewRef);
        debugPrint("👀 existing view doc: ${viewSnap.exists}");

        if (viewSnap.exists) {
          debugPrint("👀 skipping view: already counted");
          return;
        }

        tx.set(viewRef, {
          "uid": myUid,
          "viewedAt": FieldValue.serverTimestamp(),
        });

        tx.update(pingRef, {
          "viewCount": FieldValue.increment(1),
        });

        debugPrint("👀 queued view doc + increment");
      });

      debugPrint("✅ view transaction completed");
      _viewRecorded = true;
    } on FirebaseException catch (e, st) {
      debugPrint("❌ record view FirebaseException");
      debugPrint("code: ${e.code}");
      debugPrint("message: ${e.message}");
      debugPrint(st.toString());
    } catch (e, st) {
      debugPrint("❌ record view unknown error: $e");
      debugPrint(st.toString());
    } finally {
      _recordingView = false;
    }
  }

  bool get _isCreatorNow {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final creatorId = _extractCreatorId(widget.ping["creatorId"]);

    return myUid != null && creatorId.isNotEmpty && myUid == creatorId;
  }

  /// Get reverse geocoded location name from geopoint
  Future<String> _getRealLocationName(Map<String, dynamic> location) async {
    try {
      final geopoint = location["geopoint"];
      if (geopoint == null) {
        return location["placeName"]?.toString() ?? "Nearby";
      }

      final placemarks = await placemarkFromCoordinates(
        geopoint.latitude,
        geopoint.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        final parts = <String>[];

        if (place.locality != null && place.locality!.isNotEmpty) {
          parts.add(place.locality!);
        } else if (place.subAdministrativeArea != null &&
            place.subAdministrativeArea!.isNotEmpty) {
          parts.add(place.subAdministrativeArea!);
        }

        if (place.administrativeArea != null &&
            place.administrativeArea!.isNotEmpty) {
          parts.add(place.administrativeArea!);
        }

        if (place.country != null && place.country!.isNotEmpty) {
          parts.add(place.country!);
        }

        if (parts.isNotEmpty) {
          return parts.join(", ");
        }
      }
    } catch (e) {
      debugPrint("❌ Reverse geocoding failed: $e");
    }

    return location["placeName"]?.toString() ?? "Nearby";
  }

  String _s(dynamic v) => (v ?? "").toString().trim();

  DateTime? _ts(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    return null;
  }

  String _two(int n) => n.toString().padLeft(2, "0");

  String _clock(DateTime d) => "${_two(d.hour)}:${_two(d.minute)}";

  String _clock12(DateTime d) {
    final hour12 = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
    final minute = _two(d.minute);
    final suffix = d.hour >= 12 ? "PM" : "AM";
    return "$hour12:$minute $suffix";
  }

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
    final s = diff.inSeconds.abs();

    if (s < 60) return past ? "just now" : "in a moment";
    final m = (s / 60).floor();
    if (m < 60) return past ? "${m}m ago" : "in ${m}m";
    final h = (m / 60).floor();
    if (h < 24) return past ? "${h}h ago" : "in ${h}h";
    final days = (h / 24).floor();
    return past ? "${days}d ago" : "in ${days}d";
  }

  String _extractCreatorId(dynamic raw) {
    if (raw == null) return "";
    if (raw is String) return raw.trim();
    if (raw is DocumentReference) return raw.id.trim();
    if (raw is Map) {
      // handle common shapes
      final v = raw["id"] ?? raw["uid"] ?? raw["creatorId"];
      if (v is String) return v.trim();
      if (v is DocumentReference) return v.id.trim();
    }
    return "";
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
      return "This ping is private.";
    }
    return "This ping is public and anyone nearby can join.";
  }

  /// Get icon and color for a ping category
  /// Handles both standard categories and custom user-defined categories
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
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.light),
        color: const Color(0xFFF39C12),
      );
    } else if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.light),
        color: const Color(0xFFE91E63),
      );
    } else if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.light),
        color: const Color(0xFFFFB800),
      );
    } else if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.light),
        color: const Color(0xFFFF6B6B),
      );
    } else if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.light),
        color: const Color(0xFFFF1744),
      );
    } else if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.light),
        color: const Color(0xFF2196F3),
      );
    }

    // Custom category: generate color hash-based on category name
    final hash = category.hashCode;
    final customColors = [
      const Color(0xFF00BCD4), // Cyan
      const Color(0xFF009688), // Teal
      const Color(0xFF8BC34A), // Light Green
      const Color(0xFFFF5722), // Deep Orange
      const Color(0xFF673AB7), // Deep Purple
      const Color(0xFFE91E63), // Pink
    ];
    final customColor = customColors[hash.abs() % customColors.length];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
      color: customColor,
    );
  }

    DocumentReference<Map<String, dynamic>> _savedPingRef(String uid) {
      return FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .collection("saved_pings")
          .doc(widget.pingId);
    }

    bool get _canSavePingNow {
      final rawStatus = _s(widget.ping["status"]).toLowerCase();
      if (rawStatus == "ended" || rawStatus == "expired") return false;

      final endsAt = _ts(widget.ping["endsAt"]);
      if (endsAt != null && !endsAt.isAfter(DateTime.now())) return false;

      return true;
    }

    bool get _pingExpiredNow {
      final rawStatus = _s(widget.ping["status"]).toLowerCase();

      if (rawStatus == "ended" ||
          rawStatus == "expired" ||
          rawStatus == "cancelled") {
        return true;
      }

      final endsAt = _ts(widget.ping["endsAt"]);
      if (endsAt != null && !endsAt.isAfter(DateTime.now())) {
        return true;
      }

      return false;
    }

    Map<String, dynamic> _savedPingPayload(String uid) {
      return {
        "pingId": widget.pingId,
        "savedBy": uid,
        "creatorId": _extractCreatorId(widget.ping["creatorId"]),
        "title": _s(widget.ping["title"]),
        "category": _s(widget.ping["category"]),
        "privacy": _s(widget.ping["privacy"]).isEmpty
            ? "public"
            : _s(widget.ping["privacy"]),
        "participantCount": (widget.ping["participantCount"] is num)
            ? (widget.ping["participantCount"] as num).toInt()
            : 0,
        "mediaCount": (widget.ping["mediaCount"] is num)
            ? (widget.ping["mediaCount"] as num).toInt()
            : 0,
        "status": _s(widget.ping["status"]).isEmpty
            ? "active"
            : _s(widget.ping["status"]),
        "endsAt": widget.ping["endsAt"],
        "savedAt": FieldValue.serverTimestamp(),
      };
    }

    void _showPingToast(String message) {
      if (!mounted) return;

      final overlay = Overlay.of(context, rootOverlay: true);

      late OverlayEntry entry;

      entry = OverlayEntry(
        builder: (_) => Positioned(
          top: MediaQuery.of(context).padding.top + 18,
          left: 18,
          right: 18,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 180),
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, (1 - value) * -10),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.88),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                        color: Colors.black.withOpacity(.18),
                      ),
                    ],
                  ),
                  child: Text(
                    message,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      overlay.insert(entry);

      Future.delayed(const Duration(milliseconds: 1500), () {
        if (entry.mounted) entry.remove();
      });
    }

    Future<void> _toggleSavePing({
      required bool isCurrentlySaved,
    }) async {
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null || _savingPing) return;

      if (!_canSavePingNow && !isCurrentlySaved) {
        _showPingToast("This ping has already expired.");
        return;
      }

      setState(() {
        _savingPing = true;
      });

      try {
        HapticFeedback.selectionClick();

        final ref = _savedPingRef(myUid);

        if (isCurrentlySaved) {
          await ref.delete();
          _showPingToast("Removed from saved pings.");
        } else {
          await ref.set(
            _savedPingPayload(myUid),
            SetOptions(merge: true),
          );
          _showPingToast("Ping saved.");
        }
      } on FirebaseException catch (e) {
        debugPrint("❌ save ping FirebaseException: ${e.code} ${e.message}");
        _showPingToast("Couldn’t update saved pings.");
      } catch (e) {
        debugPrint("❌ save ping unknown error: $e");
        _showPingToast("Couldn’t update saved pings.");
      } finally {
        if (mounted) {
          setState(() {
            _savingPing = false;
          });
        }
      }
    }

    String _heroImageUrl(List<Map<String, dynamic>> media) {
      for (final item in media) {
        final type = _s(item["type"]).toLowerCase();
        final url = _s(item["url"]);
        final thumbUrl = _s(item["thumbUrl"]);

        if (type == "image" && url.isNotEmpty) return url;
        if (type == "video" && thumbUrl.isNotEmpty) return thumbUrl;
        if (url.isNotEmpty) return url;
      }
      return "";
    }

    String _heroWhenLine({
      required DateTime? scheduledStartAt,
      required DateTime? scheduledEndAt,
      required DateTime? createdAt,
    }) {
      final start = scheduledStartAt ?? createdAt;
      if (start == null) return "Time not set";

      if (scheduledEndAt != null) {
        return "${_dateShort(start)} · ${_clock12(start)} - ${_clock12(scheduledEndAt)}";
      }

      return "${_dateShort(start)} · ${_clock12(start)}";
    }

    String _heroWhereLine({
      required String placeName,
      required String meetingPoint,
    }) {
      if (placeName.isNotEmpty && meetingPoint.isNotEmpty) {
        return "$placeName · $meetingPoint";
      }
      if (meetingPoint.isNotEmpty) return meetingPoint;
      if (placeName.isNotEmpty) return placeName;
      return "Nearby";
    }

    String _privacyShortLabel(String privacy) {
      final p = privacy.trim().toLowerCase();
      if (p.contains("friends")) return "Friends";
      if (p.contains("verified")) return "Verified";
      if (p.contains("private")) return "Private";
      return "Public";
    }

  @override
  Widget build(BuildContext context) {
    final creatorId = _extractCreatorId(widget.ping["creatorId"]);
    final isCreator = _isCreatorNow;
    final showExpiredForViewer = !isCreator && _pingExpiredNow;

    final viewCount = (widget.ping["viewCount"] is num)
        ? (widget.ping["viewCount"] as num).toInt()
        : 0;

    final createdAt =
        _ts(widget.ping["createdAt"]) ?? _ts(widget.ping["createdAtLocal"]);
    final endsAt = _ts(widget.ping["endsAt"]);
    final scheduledStartAt = _ts(widget.ping["scheduledStartAt"]);
    final scheduledEndAt = _ts(widget.ping["scheduledEndAt"]);

    final title = _s(widget.ping["title"]).isEmpty
        ? "Untitled ping"
        : _s(widget.ping["title"]);

    final desc = _s(widget.ping["description"]);
    final category = _s(widget.ping["category"]).isEmpty
        ? "General"
        : _s(widget.ping["category"]);
    final categoryStyle = _getCategoryStyle(category);
    final privacy = _s(widget.ping["privacy"]).isEmpty
        ? "public"
        : _s(widget.ping["privacy"]);

    final tags = (widget.ping["tags"] is List)
        ? List<String>.from(widget.ping["tags"])
        : <String>[];

    final participantCount = (widget.ping["participantCount"] is num)
        ? (widget.ping["participantCount"] as num).toInt()
        : 0;

    final location = (widget.ping["location"] is Map)
        ? Map<String, dynamic>.from(widget.ping["location"])
        : <String, dynamic>{};

    final placeName = _s(location["placeName"]);
    final meetingPoint = _s(location["meetingPoint"]);
    const gap = SizedBox(height: 20);

    final media = (widget.ping["media"] is List)
        ? List<Map<String, dynamic>>.from(widget.ping["media"])
        : <Map<String, dynamic>>[];

    final heroImageUrl = _heroImageUrl(media);
    final whenLine = _heroWhenLine(
      scheduledStartAt: scheduledStartAt,
      scheduledEndAt: scheduledEndAt,
      createdAt: createdAt,
    );
    final whereLine = _heroWhereLine(
      placeName: placeName,
      meetingPoint: meetingPoint,
    );

    const sectionTitleStyle = TextStyle(
      fontFamily: "Nunito",
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Colors.black87,
      letterSpacing: 0.2,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              _IconCircle(
                iconWidget: PhosphorIcon(
                  PhosphorIcons.caretLeft(PhosphorIconsStyle.light),
                  color: Colors.black.withOpacity(.70),
                ),
                onTap: widget.onClose,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Ping Details",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withOpacity(.86),
                  ),
                ),
              ),
              if (isCreator) ...[
                _ViewCountBadge(count: viewCount),
                const SizedBox(width: 10),
              ] else ...[
                Builder(
                  builder: (context) {
                    final myUid = FirebaseAuth.instance.currentUser?.uid;

                    if (myUid == null) {
                      return const SizedBox.shrink();
                    }

                    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: _savedPingRef(myUid).snapshots(),
                      builder: (context, savedSnap) {
                        final isSaved = savedSnap.data?.exists ?? false;

                        return _IconCircle(
                          onTap: _savingPing
                              ? null
                              : () => _toggleSavePing(
                                    isCurrentlySaved: isSaved,
                                  ),
                          iconWidget: _savingPing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation(
                                      AppColors.brandGreen,
                                    ),
                                  ),
                                )
                              : PhosphorIcon(
                                  isSaved
                                      ? PhosphorIcons.bookmarkSimple(
                                          PhosphorIconsStyle.fill,
                                        )
                                      : PhosphorIcons.bookmarkSimple(
                                          PhosphorIconsStyle.light,
                                        ),
                                  color: !_canSavePingNow && !isSaved
                                      ? Colors.black.withOpacity(.28)
                                      : isSaved
                                          ? AppColors.brandGreen
                                          : Colors.black.withOpacity(.70),
                                ),
                        );
                      },
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PingHeroCard(
                  title: title,
                  imageUrl: heroImageUrl,
                  mediaCount: media.length,
                  categoryStyle: categoryStyle,
                  onTap: media.isEmpty
                      ? null
                      : () => _openPingMediaViewer(
                            context,
                            media: media,
                            initialIndex: 0,
                          ),
                ),

                const SizedBox(height: 34),

                _PingOverviewCard(
                  category: category,
                  categoryStyle: categoryStyle,
                  whenLine: whenLine,
                  whereLine: whereLine,
                  privacyLabel: _privacyShortLabel(privacy),
                  participantCount: participantCount,
                ),

                if (showExpiredForViewer) ...[
                  const SizedBox(height: 10),
                  const _PingExpiredNoticeCard(),
                ],

                const SizedBox(height: 10),
                _GoingCountCard(pingId: widget.pingId),

                gap,
                Text("Host", style: sectionTitleStyle),
                const SizedBox(height: 8),
                _CreatorHeader(
                  creatorId: creatorId,
                  isCreator: isCreator,
                ),

                gap,
                Text("About this ping", style: sectionTitleStyle),
                const SizedBox(height: 8),
                _AboutPingCard(
                  description: desc,
                  tags: tags,
                ),

                gap,
                Text("Timing", style: sectionTitleStyle),
                const SizedBox(height: 8),
                _PingTimingCard(
                  scheduledStartAt: scheduledStartAt,
                  scheduledEndAt: scheduledEndAt,
                  createdAt: createdAt,
                  endsAt: endsAt,
                  dateShort: _dateShort,
                  clock12: _clock12,
                  relative: _relative,
                ),

                gap,
                Text("Media", style: sectionTitleStyle),
                const SizedBox(height: 8),
                _Card(
                  child: media.isNotEmpty
                      ? _MediaPreviewGrid(
                          media: media,
                          onOpen: (i) => _openPingMediaViewer(
                            context,
                            media: media,
                            initialIndex: i,
                          ),
                        )
                      : Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.04),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: PhosphorIcon(
                                  PhosphorIcons.camera(PhosphorIconsStyle.light),
                                  size: 18,
                                  color: Colors.black.withOpacity(.55),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                "No media added",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black.withOpacity(.62),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),

                const SizedBox(height: 28),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCreator)
                _ManagePingButton(pingId: widget.pingId)
              else if (showExpiredForViewer)
                const _ExpiredPingButton()
              else
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: (() {
                    final myUid = FirebaseAuth.instance.currentUser?.uid;
                    if (myUid == null) return null;

                    return FirebaseFirestore.instance
                        .collection("pings")
                        .doc(widget.pingId)
                        .collection("participants")
                        .doc(myUid)
                        .snapshots();
                  })(),
                  builder: (context, snap) {
                    final data = snap.data?.data();
                    final status = _s(data?["status"]).toLowerCase();

                    if (status == "approved") {
                      return _OpenPingButton(pingId: widget.pingId);
                    }

                    return _JoinPingButton(pingId: widget.pingId);
                  },
                ),
              const _RespectNote(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Streams real creator data from users/{creatorId}
class _CreatorHeader extends StatelessWidget {
  final String creatorId;
  final bool isCreator;

  const _CreatorHeader({
    required this.creatorId,
    required this.isCreator,
  });

  String _s(dynamic v) => (v ?? "").toString().trim();

  void _openProfile(BuildContext context) {
    final targetUid = creatorId.trim();
    if (targetUid.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileTab(profileUid: targetUid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (creatorId.trim().isEmpty) {
      return _Card(
        child: Row(
          children: const [
            CircleAvatar(radius: 22, backgroundColor: Color(0xFFEFEFEF)),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                "Missing creatorId on this ping",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance
              .collection("users")
              .doc(creatorId)
              .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return _Card(
            child: Text(
              "❌ User read error: ${snap.error}",
              style: const TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }

        if (snap.connectionState == ConnectionState.waiting) {
          return _Card(
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.grey.shade200,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    "Loading creator...",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        if (!snap.hasData || !snap.data!.exists || snap.data!.data() == null) {
          return _Card(
            child: Text(
              "⚠️ No users/$creatorId document found",
              style: const TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }

        final data = snap.data!.data()!;
        final fullName = _s(data["fullName"]);
        final username = _s(data["username"]);
        final photoUrl = _s(data["photoUrl"]);

        final verification = Map<String, dynamic>.from(
          data["verification"] ?? {},
        );
        final verified = verification["status"] == "verified";

        final rawNote = _s(data["note"]);
        final noteUpdatedAt = data["noteUpdatedAt"];

        DateTime? noteTime;
        if (noteUpdatedAt is Timestamp) {
          noteTime = noteUpdatedAt.toDate();
        }

        final now = DateTime.now();
        final isNoteFresh =
            noteTime != null && now.difference(noteTime).inHours < 24;
        final note = (isNoteFresh) ? rawNote : "";

        return InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            _openProfile(context);
          },
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _Card(
                child: Row(
                  children: [
                    _Avatar(
                      photoUrl: photoUrl,
                      fallbackText:
                          username.isNotEmpty
                              ? username
                              : (fullName.isNotEmpty ? fullName : "P"),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  fullName.isNotEmpty ? fullName : "Pingmee user",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
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
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            username.isNotEmpty ? "@$username" : "@unknown",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.black.withOpacity(.62),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                      size: 18,
                      color: Colors.black.withOpacity(.40),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: -60,
                left: 38,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _openProfile(context);
                  },
                  child: _StickyNoteBubble(
                    text: note,
                    isOwner: isCreator,
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

class _PlayfulGreenSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _PlayfulGreenSurface({
    required this.borderRadius,
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: borderRadius,
        ),
        child: Stack(
          children: [
            child,
          ],
        ),
      ),
    );
  }
}

class _PlayfulGreenDoodles extends StatelessWidget {
  const _PlayfulGreenDoodles();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _PingExpiredNoticeCard extends StatelessWidget {
  const _PingExpiredNoticeCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(.055),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.black.withOpacity(.06),
              ),
            ),
            child: Center(
              child: PhosphorIcon(
                PhosphorIcons.clockCountdown(PhosphorIconsStyle.fill),
                size: 20,
                color: Colors.black.withOpacity(.70),
              ),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Ping expired",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  "This ping has ended, so you can no longer join it.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.8,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.56),
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

class _ExpiredPingButton extends StatelessWidget {
  const _ExpiredPingButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 54,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.075),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.black.withOpacity(.06),
        ),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          PhosphorIcon(
            PhosphorIcons.clockCountdown(PhosphorIconsStyle.fill),
            size: 20,
            color: Colors.black.withOpacity(.52),
          ),

          const SizedBox(width: 8),

          Text(
            "Ping expired",
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.black.withOpacity(.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _JoinPingButton extends StatelessWidget {
  final String pingId;
  const _JoinPingButton({required this.pingId});

  Future<void> _openJoinFlow(BuildContext context) async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final rootContext = rootNavigator.context;

    Navigator.of(context).pop();

    await Future.delayed(const Duration(milliseconds: 120));
    if (!rootNavigator.mounted) return;

    await openJoinPingSheet(
      context: rootContext,
      pingId: pingId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PrimaryButton(
      label: "Join Ping",
      icon: Icons.flash_on_rounded,
      onTap: () => _openJoinFlow(context),
    );
  }
}

class _OpenPingButton extends StatelessWidget {
  final String pingId;
  const _OpenPingButton({required this.pingId});

  Future<void> _openPing(BuildContext context) async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final rootContext = rootNavigator.context;

    Navigator.of(context).pop();

    await Future.delayed(const Duration(milliseconds: 120));
    if (!rootNavigator.mounted) return;

    await openJoinPingSheet(
      context: rootContext,
      pingId: pingId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PrimaryButton(
      label: "Open Ping",
      icon: Icons.chat_rounded,
      onTap: () => _openPing(context),
    );
  }
}

class _ManagePingButton extends StatelessWidget {
  final String pingId;
  const _ManagePingButton({required this.pingId});

  void _manage(BuildContext context) {
    openManagePingScreen(
      context: context,
      pingId: pingId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PrimaryButton(
      label: "Manage Ping",
      icon: Icons.settings_rounded,
      onTap: () => _manage(context),
    );
  }
}

/// ---------------- UI atoms ----------------

class _EmptyState extends StatelessWidget {
  final VoidCallback onClose;
  const _EmptyState({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.hourglass_empty_rounded,
              size: 40,
              color: AppColors.brandGreen,
            ),
            const SizedBox(height: 10),
            const Text(
              "This ping can't be found",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w500,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            _PrimaryButton(
              label: "Go back",
              icon: Icons.arrow_back_rounded,
              onTap: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _IconCircle extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onTap;

  const _IconCircle({
    this.icon,
    this.iconWidget,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.75),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          child: iconWidget ?? Icon(icon, color: Colors.black.withOpacity(.70)),
        ),
      ),
    );
  }
}

class _ViewCountBadge extends StatelessWidget {
  final int count;

  const _ViewCountBadge({required this.count});

  String _formatCount(int value) {
    if (value < 1000) return value.toString();

    if (value < 1000000) {
      final k = value / 1000;
      if (value % 1000 == 0) {
        return "${k.toStringAsFixed(0)}k";
      }
      return k >= 10
          ? "${k.toStringAsFixed(0)}k"
          : "${k.toStringAsFixed(1)}k";
    }

    final m = value / 1000000;
    if (value % 1000000 == 0) {
      return "${m.toStringAsFixed(0)}m";
    }
    return m >= 10
        ? "${m.toStringAsFixed(0)}m"
        : "${m.toStringAsFixed(1)}m";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.85),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIcons.eye(PhosphorIconsStyle.light),
            size: 16,
            color: Colors.black.withOpacity(.62),
          ),
          const SizedBox(width: 6),
          Text(
            _formatCount(count),
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.black.withOpacity(.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  const _KeyValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.black.withOpacity(.56),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}

class _GlassCategoryPill extends StatelessWidget {
  final String category;
  final ({IconData icon, Color color}) style;
  const _GlassCategoryPill({required this.category, required this.style});

  @override
  Widget build(BuildContext context) {
    final tint = style.color;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: Colors.white.withOpacity(.45),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(style.icon, size: 16, color: tint),
              const SizedBox(width: 8),
              Text(
                category,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.black.withOpacity(.80),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StickyTitleNote extends StatelessWidget {
  final String title;
  const _StickyTitleNote({required this.title});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.02,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              color: const Color(0xFFFFF3A6),
              child: Text(
                title,
                style: GoogleFonts.patrickHand(
                  fontSize: 28,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(.86),
                ),
              ),
            ),
          ),
          Positioned(
            top: -10,
            right: 10,
            child: Transform.rotate(
              angle: 0.18,
              child: Icon(
                Icons.push_pin_rounded,
                size: 28,
                color: Colors.redAccent.withOpacity(.92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickyNoteBubble extends StatelessWidget {
  final String text;
  final bool isOwner;

  const _StickyNoteBubble({
    required this.text,
    required this.isOwner,
  });

  @override
  Widget build(BuildContext context) {
    final t = text.trim();
    final isEmpty = t.isEmpty;

    final display = isEmpty
        ? (isOwner ? "Share a note…" : "I'm live 👋")
        : t;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Transform.rotate(
          angle: -0.03,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF4E77D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black.withOpacity(.08)),
              boxShadow: [
                BoxShadow(
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Text(
              display,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.patrickHand(
                fontSize: 17,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: isEmpty
                    ? Colors.black.withOpacity(.45)
                    : Colors.black.withOpacity(.82),
              ),
            ),
          ),
        ),

        Positioned(
          top: -8,
          left: 18,
          child: Transform.rotate(
            angle: -0.20,
            child: Container(
              width: 34,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.55),
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                    color: Colors.black.withOpacity(.08),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GoingCountCard extends StatelessWidget {
  final String pingId;

  const _GoingCountCard({
    required this.pingId,
  });

  String _s(dynamic v) => (v ?? "").toString().trim();

  String _displayNameFromUser(Map<String, dynamic>? data) {
    if (data == null) return "P";

    final fullName = _s(data["fullName"]);
    if (fullName.isNotEmpty) return fullName;

    final username = _s(data["username"]);
    if (username.isNotEmpty) return username;

    return "P";
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

  String _buildPeopleAlreadyInText(int count) {
    if (count <= 0) return "Be the first one in.";
    if (count == 1) return "1 person is already in.";
    return "$count people are already in.";
  }

  String _buildGoingText(List<String> firstNames, int totalCount) {
    if (totalCount <= 0) return "Be the first one going.";

    final visible = firstNames.where((e) => e.trim().isNotEmpty).toList();
    final others = totalCount - visible.length;

    if (visible.isEmpty) {
      return totalCount == 1
          ? "1 person is going."
          : "$totalCount people are going.";
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

  bool _isStillGoing(Map<String, dynamic> data) {
    final status = _s(data["status"]).toLowerCase();
    final role = _s(data["role"]).toLowerCase();

    if (role == "creator") return true;
    return status == "approved" || status.isEmpty;
  }

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

        final going = docs.where((doc) {
          final data = doc.data();
          return _isStillGoing(data);
        }).toList();

        going.sort((a, b) {
          final aData = a.data();
          final bData = b.data();

          final aRole = _s(aData["role"]).toLowerCase();
          final bRole = _s(bData["role"]).toLowerCase();

          if (aRole == "creator" && bRole != "creator") return -1;
          if (aRole != "creator" && bRole == "creator") return 1;

          final aJoined = aData["joinedAt"] is Timestamp
              ? (aData["joinedAt"] as Timestamp).toDate().millisecondsSinceEpoch
              : 0;
          final bJoined = bData["joinedAt"] is Timestamp
              ? (bData["joinedAt"] as Timestamp).toDate().millisecondsSinceEpoch
              : 0;

          return bJoined.compareTo(aJoined);
        });

        final count = going.length;
        const visibleLimit = 5;

        final visibleIds = going
            .map((doc) {
              final data = doc.data();
              final uid = _s(data["uid"]);
              return uid.isNotEmpty ? uid : doc.id;
            })
            .where((id) => id.isNotEmpty)
            .take(visibleLimit)
            .toList();

        final overflowCount = count - visibleIds.length;

        if (visibleIds.isEmpty) {
          return _Card(
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandGreen.withOpacity(.12),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      "P",
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ),
                ),
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

            final orderedUsers = visibleIds.map((id) => usersById[id]).toList();

            final visibleFirstNames = orderedUsers
                .map((user) => _firstNameFromUser(user))
                .toList();

            final peopleText = _buildPeopleAlreadyInText(count);
            final goingText = _buildGoingText(visibleFirstNames, count);

            final stackItems = visibleIds.length + (overflowCount > 0 ? 1 : 0);
            final stackWidth = 38 + ((stackItems - 1) * 26.0);

            return _Card(
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
                                child: _GoingFaceAvatar(
                                  photoUrl: _s(usersById[visibleIds[i]]?["photoUrl"]),
                                  fallback: _displayNameFromUser(usersById[visibleIds[i]]),
                                ),
                              ),
                            if (overflowCount > 0)
                              Positioned(
                                left: visibleIds.length * 26.0,
                                top: 0,
                                child: _GoingExtraAvatar(count: overflowCount),
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

class _GoingFaceAvatar extends StatelessWidget {
  final String photoUrl;
  final String fallback;

  const _GoingFaceAvatar({
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
                  fontWeight: FontWeight.w700,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
    );
  }
}

class _GoingExtraAvatar extends StatelessWidget {
  final int count;

  const _GoingExtraAvatar({
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withOpacity(.08),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Center(
        child: Text(
          "+$count",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.black.withOpacity(.72),
          ),
        ),
      ),
    );
  }
}

class _MeetingPointCard extends StatelessWidget {
  final String placeName;
  final String meetingPoint;
  final Map<String, dynamic> location;
  final Future<String> Function(Map<String, dynamic> location) getRealLocationName;

  const _MeetingPointCard({
    required this.placeName,
    required this.meetingPoint,
    required this.location,
    required this.getRealLocationName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: PhosphorIcon(
                PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
                size: 22,
                color: AppColors.brandGreen,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FutureBuilder<String>(
                  future: getRealLocationName(location),
                  builder: (context, snapshot) {
                    final display =
                        (snapshot.data ?? placeName).trim().isEmpty
                            ? "Nearby"
                            : (snapshot.data ?? placeName).trim();
                    return Text(
                      display,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                        height: 1.15,
                      ),
                    );
                  },
                ),
                if (meetingPoint.trim().isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 180,
                      height: 1,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.12),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    meetingPoint,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withOpacity(.70),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PingHeroCard extends StatelessWidget {
  final String title;
  final String imageUrl;
  final int mediaCount;
  final ({IconData icon, Color color}) categoryStyle;
  final VoidCallback? onTap;

  const _PingHeroCard({
    required this.title,
    required this.imageUrl,
    required this.mediaCount,
    required this.categoryStyle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl.trim().isNotEmpty;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: AspectRatio(
              aspectRatio: 1.12,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasImage)
                    Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _fallback(),
                    )
                  else
                    _fallback(),

                  Positioned(
                    top: 14,
                    right: 14,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (mediaCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.92),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PhosphorIcon(
                                  PhosphorIcons.images(
                                    PhosphorIconsStyle.light,
                                  ),
                                  size: 15,
                                  color: Colors.black.withOpacity(.72),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  "$mediaCount",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black.withOpacity(.76),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: -20,
          child: _StickyTitleNote(title: title),
        ),
      ],
    );
  }

  Widget _fallback() {
    return Container(
      color: const Color(0xFFF3F6F8),
      child: Center(
        child: Container(
          width: 108,
          height: 108,
          decoration: BoxDecoration(
            color: categoryStyle.color.withOpacity(.12),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Center(
            child: Icon(
              categoryStyle.icon,
              size: 48,
              color: categoryStyle.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _PingOverviewCard extends StatelessWidget {
  final String category;
  final ({IconData icon, Color color}) categoryStyle;
  final String whenLine;
  final String whereLine;
  final String privacyLabel;
  final int participantCount;

  const _PingOverviewCard({
    required this.category,
    required this.categoryStyle,
    required this.whenLine,
    required this.whereLine,
    required this.privacyLabel,
    required this.participantCount,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GlassCategoryPill(
            category: category,
            style: categoryStyle,
          ),
          const SizedBox(height: 14),

          _OverviewInfoRow(
            icon: PhosphorIcons.mapPin(PhosphorIconsStyle.light),
            text: whereLine,
          ),
          const SizedBox(height: 10),

          _OverviewInfoRow(
            icon: PhosphorIcons.calendarBlank(PhosphorIconsStyle.light),
            text: whenLine,
          ),
          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: _OverviewStatTile(
                  label: "Going",
                  value: participantCount == 1
                      ? "1 person"
                      : "$participantCount people",
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _OverviewStatTile(
                  label: "Access",
                  value: privacyLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopMetaPill extends StatelessWidget {
  final String label;

  const _TopMetaPill({
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6F8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.black.withOpacity(.70),
        ),
      ),
    );
  }
}

class _OverviewInfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _OverviewInfoRow({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: PhosphorIcon(
              icon,
              size: 17,
              color: Colors.black.withOpacity(.64),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              text,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.25,
                color: Colors.black.withOpacity(.74),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _OverviewStatTile extends StatelessWidget {
  final String label;
  final String value;

  const _OverviewStatTile({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.black.withOpacity(.50),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: Icon(icon, color: Colors.white, size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w500,
            fontSize: 15,
            color: Colors.white,
          ),
        ),
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
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

class _ScheduleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ScheduleRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.brandGreen.withOpacity(.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: PhosphorIcon(icon, size: 18, color: AppColors.brandGreen),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.black.withOpacity(.55),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(.82),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Card({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool strong;

  const _Pill({
    required this.icon,
    required this.text,
    this.strong = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.brandGreen),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
              fontSize: 12,
              color: Colors.black.withOpacity(.74),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  final String text;
  const _TagPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.brandGreen.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
        // border: Border.all(color: AppColors.brandGreen.withOpacity(.18)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w400,
          fontSize: 12,
          color: AppColors.brandGreen,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String photoUrl;
  final String fallbackText;
  const _Avatar({required this.photoUrl, required this.fallbackText});

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;

    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withOpacity(.06),
        image:
            hasPhoto
                ? DecorationImage(
                  image: NetworkImage(photoUrl),
                  fit: BoxFit.cover,
                )
                : null,
      ),
      child:
          !hasPhoto
              ? Center(
                child: Text(
                  fallbackText.isNotEmpty ? fallbackText[0].toUpperCase() : "P",
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                  ),
                ),
              )
              : null,
    );
  }
}

/// Simple preview grid (images/thumbs). Keep it light for now.
class _MediaPreviewGrid extends StatelessWidget {
  final List<Map<String, dynamic>> media;
  final void Function(int index)? onOpen;

  const _MediaPreviewGrid({required this.media, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final count = media.length.clamp(0, 6);

    return GridView.builder(
      itemCount: count,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemBuilder: (_, i) {
        final m = media[i];
        final type = (m["type"] ?? "").toString();
        final url = (m["url"] ?? "").toString();
        final thumbUrl = (m["thumbUrl"] ?? "").toString();
        final name = (m["name"] ?? "File").toString();

        // ✅ FILE TILE
        if (type == "file") {
          return InkWell(
            onTap: () {
              if (url.isNotEmpty) _openExternalUrl(url);
            },
            borderRadius: BorderRadius.circular(18),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Container(
                color: const Color(0xFFF2F4F8),
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      PhosphorIcons.file(PhosphorIconsStyle.light),
                      size: 24,
                      color: Colors.black.withOpacity(.70),
                    ),
                    const SizedBox(height: 6),

                    // ✅ Flexible text so it never overflows
                    Expanded(
                      child: Center(
                        child: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w900,
                            fontSize: 10.5,
                            height: 1.05,
                            color: Colors.black.withOpacity(.72),
                          ),
                        ),
                      ),
                    ),

                    // ✅ keep the hint small or remove it
                    Text(
                      "Open",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                        color: Colors.black.withOpacity(.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // ✅ IMAGE / VIDEO (existing)
        final previewUrl = thumbUrl.isNotEmpty ? thumbUrl : url;

        return InkWell(
          onTap: onOpen == null ? null : () => onOpen!(i),
          borderRadius: BorderRadius.circular(18),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (previewUrl.isNotEmpty)
                  Image.network(previewUrl, fit: BoxFit.cover)
                else
                  Container(color: Colors.black12),

                if (type == "video")
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_arrow_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            "Video",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _JoinArtworkCard extends StatelessWidget {
  final ({IconData icon, Color color}) categoryStyle;

  const _JoinArtworkCard({
    required this.categoryStyle,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: double.infinity,
        color: Colors.white,
        child: Image.asset(
          "assets/images/ping_details.png",
          width: double.infinity,
          fit: BoxFit.fitWidth, // full width, no zoom/crop
          alignment: Alignment.topCenter,
          errorBuilder: (_, __, ___) {
            return Container(
              height: 180,
              alignment: Alignment.center,
              color: Colors.white,
              child: Text(
                "Couldn't load ping_details.png",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(.55),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RespectNote extends StatelessWidget {
  const _RespectNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        "Be respectful • Meet in safe public places • Report bad behavior",
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12,
          color: Colors.black.withOpacity(.55),
        ),
      ),
    );
  }
}

class _CategoryHeaderSection extends StatelessWidget {
  final String category;
  final ({IconData icon, Color color}) categoryStyle;

  const _CategoryHeaderSection({
    required this.category,
    required this.categoryStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            categoryStyle.color.withOpacity(.08),
            categoryStyle.color.withOpacity(.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: categoryStyle.color.withOpacity(.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              categoryStyle.icon,
              color: categoryStyle.color,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Ping Category",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.55),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  category.isEmpty ? "General" : category,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: categoryStyle.color,
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

class _CategoryPill extends StatelessWidget {
  final String text;
  final ({IconData icon, Color color}) style;

  const _CategoryPill({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.brandGreen.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 16, color: AppColors.brandGreen),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: AppColors.brandGreen,
            ),
          ),
        ],
      ),
    );
  }
}

/// Meta pill for participant count and other meta info
class _MetaPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _MetaPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Privacy pill showing privacy level
class _PrivacyPill extends StatelessWidget {
  final String text;
  final String privacy;
  final Color color;

  const _PrivacyPill({
    required this.text,
    required this.privacy,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            privacy.toLowerCase().contains("private")
                ? PhosphorIcons.lock(PhosphorIconsStyle.light)
                : PhosphorIcons.globe(PhosphorIconsStyle.light),
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Location pill
class _LocationPill extends StatelessWidget {
  final String text;
  final Color color;

  const _LocationPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    // color provided by caller (category color)
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIcons.mapPin(PhosphorIconsStyle.light),
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Timing pill with label and time info
class _TimingPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String relative;
  final String time;
  final Color color;

  const _TimingPill({
    required this.icon,
    required this.label,
    required this.relative,
    required this.time,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  fontSize: 10,
                  color: color.withOpacity(.7),
                ),
              ),
              Text(
                relative,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Expiry pill showing when ping ends
class _ExpiryPill extends StatelessWidget {
  final DateTime endsAt;
  final String relative;
  final String time;
  final Color color;

  const _ExpiryPill({
    required this.endsAt,
    required this.relative,
    required this.time,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isExpired = DateTime.now().isAfter(endsAt);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isExpired
                ? PhosphorIcons.hourglass(PhosphorIconsStyle.light)
                : PhosphorIcons.hourglassHigh(PhosphorIconsStyle.light),
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isExpired ? "Ended" : "Ends",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w500,
                  fontSize: 10,
                  color: color.withOpacity(.7),
                ),
              ),
              Text(
                relative,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Enhanced tag pill for hashtags
class _EnhancedTagPill extends StatelessWidget {
  final String text;
  final Color color;

  const _EnhancedTagPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w600,
          fontSize: 11,
          color: Colors.black.withOpacity(.78),
        ),
      ),
    );
  }
}

void _openPingMediaViewer(
  BuildContext context, {
  required List<Map<String, dynamic>> media,
  required int initialIndex,
}) {
  final viewable =
      media.where((m) {
        final t = (m["type"] ?? "").toString();
        return t == "image" || t == "video";
      }).toList();

  if (viewable.isEmpty) return;

  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      pageBuilder:
          (_, __, ___) => _PingMediaViewer(
            media: viewable,
            initialIndex: initialIndex.clamp(0, viewable.length - 1),
          ),
      transitionsBuilder:
          (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
    ),
  );
}

class _PingMediaViewer extends StatefulWidget {
  final List<Map<String, dynamic>> media;
  final int initialIndex;

  const _PingMediaViewer({required this.media, required this.initialIndex});

  @override
  State<_PingMediaViewer> createState() => _PingMediaViewerState();
}

class _ThoughtBubbleFB extends StatelessWidget {
  final String text;

  const _ThoughtBubbleFB({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = text.trim();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Transform.rotate(
          angle: -0.03,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 210),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF4E77D),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              t,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.patrickHand(
                fontSize: 17,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: Colors.black.withOpacity(.82),
              ),
            ),
          ),
        ),
        Positioned(
          top: -8,
          left: 18,
          child: Transform.rotate(
            angle: -0.20,
            child: Container(
              width: 34,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.55),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PingMediaViewerState extends State<_PingMediaViewer> {
  late final PageController _page;
  late DateTime _touchStart;
  int _index = 0;

  // STORY ENGINE
  Timer? _timer;
  bool _isPaused = false;
  late List<double> _progress;

  // video
  final Map<int, VideoPlayerController> _vp = {};
  final Map<int, ChewieController> _chewie = {};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: widget.initialIndex);

    // progress bars
    _progress = List.generate(widget.media.length, (_) => 0.0);

    // preload
    _ensureVideoReady(_index);
    _ensureVideoReady(_index + 1);

    // START STORY ENGINE
    _startCurrent();                  
  }

  @override
  void dispose() {
    for (final c in _chewie.values) {
      c.dispose();
    }
    for (final v in _vp.values) {
      v.dispose();
    }
    _page.dispose();
    _timer?.cancel();
    super.dispose();
  }

  String _s(dynamic v) => (v ?? "").toString().trim();

  Future<void> _ensureVideoReady(int i) async {
    if (i < 0 || i >= widget.media.length) return;

    final m = widget.media[i];
    final type = _s(m["type"]);
    final url = _s(m["url"]);

    if (type != "video") return;
    if (url.isEmpty) return;
    if (_vp.containsKey(i)) return; // already init

    try {
      final vp = VideoPlayerController.networkUrl(Uri.parse(url));
      _vp[i] = vp;
      await vp.initialize();

      final chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: false,
        looping: false,
        allowFullScreen: false, // we already are fullscreen
        allowMuting: true,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.brandGreen,
          handleColor: AppColors.brandGreen,
          bufferedColor: Colors.white24,
          backgroundColor: Colors.white12,
        ),
      );

      _chewie[i] = chewie;

      if (mounted) setState(() {});
    } catch (_) {
      // don't crash viewer if a video fails
      if (mounted) setState(() {});
    }
  }

  void _startCurrent() {
    _timer?.cancel();

    final m = widget.media[_index];
    final type = (m["type"] ?? "").toString();

    if (type == "video") {
      _playVideo();
    } else {
      _startImageTimer();
    }
  }

  void _startImageTimer() {
    const total = Duration(seconds: 5);
    const step = 50;

    int elapsed = 0;

    _timer = Timer.periodic(Duration(milliseconds: step), (t) {
      if (_isPaused) return;

      elapsed += step;

      setState(() {
        _progress[_index] = elapsed / total.inMilliseconds;
      });

      if (elapsed >= total.inMilliseconds) {
        t.cancel();
        _next();
      }
    });
  }

  void _playVideo() {
    final controller = _vp[_index];
    if (controller == null || !controller.value.isInitialized) return;

    controller.play();

    controller.addListener(() {
      if (!mounted) return;

      final pos = controller.value.position;
      final dur = controller.value.duration;

      if (dur.inMilliseconds == 0) return;

      setState(() {
        _progress[_index] =
            pos.inMilliseconds / dur.inMilliseconds;
      });

      if (pos >= dur) {
        _next();
      }
    });
  }

  void _next() {
    if (_index < widget.media.length - 1) {
      setState(() {
        _progress[_index] = 1.0;
        _index++;
      });

      _page.jumpToPage(_index);
      _ensureVideoReady(_index);
      _startCurrent();
    } else {
      Navigator.pop(context);
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() {
        _progress[_index] = 0.0;
        _index--;
      });

      _page.jumpToPage(_index);
      _startCurrent();
    }
  }

  void _pause() {
    _isPaused = true;
    _vp[_index]?.pause();
  }

  void _resume() {
    _isPaused = false;
    _vp[_index]?.play();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.media.length;

    return Scaffold(
      backgroundColor: Colors.black.withOpacity(.92),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,

        onTapDown: (details) {
          _touchStart = DateTime.now();
          _pause();
        },

        onTapUp: (details) {
          final elapsed =
              DateTime.now().difference(_touchStart).inMilliseconds;

          final w = MediaQuery.of(context).size.width;
          final isLeft = details.globalPosition.dx < w / 2;

          // Only navigate if it's a QUICK TAP
          if (elapsed < 200) {
            if (isLeft) {
              _previous();
            } else {
              _next();
            }
          }

          _resume();
        },

        onTapCancel: () {
          _resume();
        },

        onVerticalDragUpdate: (details) {
          if (details.primaryDelta != null &&
              details.primaryDelta! > 10) {
            Navigator.pop(context);
          }
        },

        child: SafeArea(
          child: Stack(
          children: [
            PageView.builder(
              controller: _page,
              physics: const NeverScrollableScrollPhysics(), // 🚫 disable swipe
              itemCount: total,
              onPageChanged: (i) {
                setState(() => _index = i);

                _ensureVideoReady(i);
                _ensureVideoReady(i + 1);
                _ensureVideoReady(i - 1);

                _startCurrent(); // 🔥 restart engine
              },
              itemBuilder: (_, i) {
                final m = widget.media[i];
                final type = _s(m["type"]);
                final url = _s(m["url"]);
                final thumb = _s(m["thumbUrl"]);

                if (type == "video") {
                  final chewie = _chewie[i];

                  return Center(
                    child: AspectRatio(
                      aspectRatio:
                          (_vp[i]?.value.isInitialized ?? false)
                              ? _vp[i]!.value.aspectRatio
                              : (16 / 9),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child:
                            chewie != null
                                ? Chewie(controller: chewie)
                                : Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (thumb.isNotEmpty)
                                      Image.network(thumb, fit: BoxFit.cover)
                                    else
                                      Container(color: Colors.black26),
                                    const Center(
                                      child: SizedBox(
                                        width: 30,
                                        height: 30,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                      ),
                    ),
                  );
                }

                

                // Image (zoom + pan)
                return PhotoView(
                  backgroundDecoration: const BoxDecoration(
                    color: Colors.transparent,
                  ),
                  imageProvider: NetworkImage(url),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3.0,
                  heroAttributes: PhotoViewHeroAttributes(tag: "ping_media_$i"),
                  loadingBuilder:
                      (_, __) => const Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                      ),
                  errorBuilder:
                      (_, __, ___) => const Center(
                        child: Text(
                          "Couldn't load media",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w900,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                );
              },
            ),

            

            Positioned(
              top: 10,
              left: 8,
              right: 8,
              child: Row(
                children: List.generate(widget.media.length, (i) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _progress[i].clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Enhanced pill/tag with subtle animation and hover effect
  Widget _buildEnhancedPill({
    required String label,
    required Color backgroundColor,
    required Color textColor,
    VoidCallback? onTap,
    bool isSelected = false,
    bool showIcon = false,
    IconData? icon,
  }) {
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color:
                isSelected
                    ? backgroundColor.withOpacity(1.0)
                    : backgroundColor.withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIcon && icon != null) ...[
                Icon(icon, size: 14, color: textColor),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Category chip with visual badge
  Widget _buildCategoryChip({
    required String label,
    required Color color,
    String? badge,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Status indicator tag with animation
  Widget _buildStatusTag({
    required String status,
    required Color statusColor,
    bool isAnimated = false,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: statusColor.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child:
            isAnimated
                ? TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 800),
                  builder: (context, value, child) {
                    return Opacity(opacity: 0.7 + (value * 0.3), child: child);
                  },
                  child: _buildStatusContent(status, statusColor),
                )
                : _buildStatusContent(status, statusColor),
      ),
    );
  }

  Widget _buildStatusContent(String status, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          status,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  /// Tag group with horizontal scroll (if needed)
  Widget _buildTagGroup({
    required List<String> tags,
    required Color primaryColor,
    bool scrollable = false,
  }) {
    final tagWidgets =
        tags
            .map(
              (tag) => _buildEnhancedPill(
                label: tag,
                backgroundColor: primaryColor,
                textColor: Colors.white,
              ),
            )
            .toList();

    if (scrollable && tags.length > 4) {
      return SizedBox(
        height: 32,
        child: ListView(scrollDirection: Axis.horizontal, children: tagWidgets),
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: tagWidgets);
  }
}

class _AboutPingCard extends StatelessWidget {
  final String description;
  final List<String> tags;

  const _AboutPingCard({
    required this.description,
    required this.tags,
  });

  @override
  Widget build(BuildContext context) {
    final cleanDescription = description.trim();
    final cleanTags = tags
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.035),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cleanDescription.isEmpty
                ? "No extra details were added for this ping yet."
                : cleanDescription,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 15,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: cleanDescription.isEmpty
                  ? Colors.black.withOpacity(.45)
                  : Colors.black.withOpacity(.78),
            ),
          ),

          if (cleanTags.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              height: 1,
              color: Colors.black.withOpacity(.06),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: cleanTags.map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tag.startsWith("#") ? tag : "#$tag",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.brandGreen,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _PingTimingCard extends StatelessWidget {
  final DateTime? scheduledStartAt;
  final DateTime? scheduledEndAt;
  final DateTime? createdAt;
  final DateTime? endsAt;

  final String Function(DateTime) dateShort;
  final String Function(DateTime) clock12;
  final String Function(DateTime) relative;

  const _PingTimingCard({
    required this.scheduledStartAt,
    required this.scheduledEndAt,
    required this.createdAt,
    required this.endsAt,
    required this.dateShort,
    required this.clock12,
    required this.relative,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.035),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.86),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: Colors.white.withOpacity(.82),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    _TimingInfoRow(
                      label: "Date",
                      value: scheduledStartAt != null
                          ? dateShort(scheduledStartAt!)
                          : "Not set",
                      icon: PhosphorIcons.calendarBlank(
                        PhosphorIconsStyle.light,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _TimingSoftDivider(),
                    const SizedBox(height: 14),
                    _TimingInfoRow(
                      label: "Starts",
                      value: scheduledStartAt != null
                          ? clock12(scheduledStartAt!)
                          : "Not set",
                      icon: PhosphorIcons.playCircle(
                        PhosphorIconsStyle.light,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _TimingSoftDivider(),
                    const SizedBox(height: 14),
                    _TimingInfoRow(
                      label: "Ends",
                      value: scheduledEndAt != null
                          ? clock12(scheduledEndAt!)
                          : "Not set",
                      icon: PhosphorIcons.stopCircle(
                        PhosphorIconsStyle.light,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: _TimingMiniCard(
                      label: "Created",
                      value: createdAt != null ? relative(createdAt!) : "Unknown",
                      icon: PhosphorIcons.sparkle(
                        PhosphorIconsStyle.light,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TimingMiniCard(
                      label: "Expires",
                      value: endsAt != null ? relative(endsAt!) : "Unknown",
                      icon: PhosphorIcons.hourglassHigh(
                        PhosphorIconsStyle.light,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimingInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _TimingInfoRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: PhosphorIcon(
              icon,
              size: 18,
              color: Colors.black.withOpacity(.58),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Colors.black.withOpacity(.58),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ),
      ],
    );
  }
}

class _TimingMiniCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _TimingMiniCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.82),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(.78),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            icon,
            size: 18,
            color: Colors.black.withOpacity(.52),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.black.withOpacity(.48),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimingSoftDivider extends StatelessWidget {
  const _TimingSoftDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 1,
      color: Colors.black.withOpacity(.06),
    );
  }
}

class _PingTagsCard extends StatelessWidget {
  final List<String> tags;
  final Color accentColor;

  const _PingTagsCard({
    required this.tags,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.035),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -18,
            bottom: -10,
            child: IgnorePointer(
              child: Icon(
                PhosphorIcons.hashStraight(PhosphorIconsStyle.light),
                size: 118,
                color: Colors.black.withOpacity(.04),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(.10),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: PhosphorIcon(
                        PhosphorIcons.hashStraight(PhosphorIconsStyle.fill),
                        size: 22,
                        color: accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "PING TAGS",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                        color: Colors.black.withOpacity(.32),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "Quick cues that help people understand the vibe faster.",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(.60),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: tags
                    .map(
                      (t) => _AliveTagPill(
                        text: "#$t",
                        color: accentColor,
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AliveTagPill extends StatelessWidget {
  final String text;
  final Color color;

  const _AliveTagPill({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withOpacity(.18),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w800,
          fontSize: 12,
          color: color.withOpacity(.92),
        ),
      ),
    );
  }
}

class _SimpleTagsCard extends StatelessWidget {
  final List<String> tags;
  final Color color;

  const _SimpleTagsCard({
    required this.tags,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.035),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: tags
            .map(
              (t) => _SimpleColorTagPill(
                text: "#$t",
                color: color,
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SimpleColorTagPill extends StatelessWidget {
  final String text;
  final Color color;

  const _SimpleColorTagPill({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
  }
}