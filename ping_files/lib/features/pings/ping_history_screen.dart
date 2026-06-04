import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/features/pings/manage_ping_screen.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PingHistoryScreen extends StatelessWidget {
  const PingHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null || uid.isEmpty) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6F7FB),
        body: Center(
          child: Text(
            'You need to be logged in.',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7FB),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                child: Row(
                  children: [
                    _HistoryIconButton(
                      icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ping History',
                            style: TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF111827),
                              letterSpacing: -.4,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Created and joined pings live here.',
                            style: TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 13.2,
                              fontWeight: FontWeight.w400,
                              color: Colors.black45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              Container(
                height: 44,
                margin: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF2F7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: TabBar(
                  dividerColor: Colors.transparent,
                  indicator: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                        color: Colors.black.withOpacity(.055),
                      ),
                    ],
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: const Color(0xFF111827),
                  unselectedLabelColor: Colors.black.withOpacity(.42),
                  labelStyle: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const [
                    Tab(text: 'Created'),
                    Tab(text: 'Joined'),
                  ],
                ),
              ),

              Expanded(
                child: TabBarView(
                  children: [
                    _CreatedPingsHistory(uid: uid),
                    _JoinedPingsHistory(uid: uid),
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

class _CreatedPingsHistory extends StatelessWidget {
  const _CreatedPingsHistory({
    required this.uid,
  });

  final String uid;

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('pings')
        .where('creatorId', isEqualTo: uid)
        .limit(80);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('❌ created ping history failed: ${snap.error}');

          return const _HistoryEmptyState(
            icon: PhosphorIcons.warningCircle,
            title: 'Couldn’t load created pings',
            subtitle: 'Try again in a moment.',
          );
        }

        if (!snap.hasData) {
          return const _HistoryLoadingList();
        }

        final items = snap.data!.docs.map((doc) {
          return _PingHistoryItem.fromPingDoc(
            pingId: doc.id,
            data: doc.data(),
            relation: _PingHistoryRelation.created,
          );
        }).toList()
          ..sort(_sortHistoryItems);

        if (items.isEmpty) {
          return const _HistoryEmptyState(
            icon: PhosphorIcons.mapPinArea,
            title: 'No created pings yet',
            subtitle: 'Pings you create will appear here.',
          );
        }

        return _HistoryList(
          items: items,
          onTap: (item) {
            openManagePingScreen(
              context: context,
              pingId: item.pingId,
            );
          },
        );
      },
    );
  }
}

class _JoinedPingsHistory extends StatefulWidget {
  const _JoinedPingsHistory({
    required this.uid,
  });

  final String uid;

  @override
  State<_JoinedPingsHistory> createState() => _JoinedPingsHistoryState();
}

class _JoinedPingsHistoryState extends State<_JoinedPingsHistory> {
  bool _syncStarted = false;
  bool _syncing = false;
  bool _syncFailed = false;
  bool _syncTimedOut = false;

  @override
  void initState() {
    super.initState();
    unawaited(_syncHistory());
  }

  Future<void> _syncHistory() async {
    if (_syncStarted) return;

    _syncStarted = true;

    if (mounted) {
      setState(() {
        _syncing = true;
        _syncFailed = false;
        _syncTimedOut = false;
      });
    }

    try {
      debugPrint('⏳ syncMyPingHistory starting...');

      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('syncMyPingHistory')
          .call()
          .timeout(const Duration(seconds: 18));

      debugPrint('✅ syncMyPingHistory result: ${result.data}');

      if (!mounted) return;

      setState(() {
        _syncing = false;
        _syncFailed = false;
        _syncTimedOut = false;
      });
    } on TimeoutException catch (error) {
      debugPrint('⏱️ syncMyPingHistory timed out: $error');

      if (!mounted) return;

      setState(() {
        _syncing = false;
        _syncFailed = false;
        _syncTimedOut = true;
      });
    } catch (error) {
      debugPrint('❌ syncMyPingHistory failed: $error');

      if (!mounted) return;

      setState(() {
        _syncing = false;
        _syncFailed = true;
        _syncTimedOut = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid)
        .collection('ping_history')
        .where('role', isEqualTo: 'joined')
        .limit(120);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('❌ joined ping history failed: ${snap.error}');

          return const _HistoryEmptyState(
            icon: PhosphorIcons.warningCircle,
            title: 'Couldn’t load joined pings',
            subtitle: 'Try again in a moment.',
          );
        }

        if (!snap.hasData) {
          return const _HistoryLoadingList();
        }

        final items = snap.data!.docs.map((doc) {
          return _PingHistoryItem.fromHistoryDoc(
            pingId: doc.id,
            data: doc.data(),
          );
        }).toList()
          ..sort(_sortHistoryItems);

        if (items.isEmpty) {
          if (_syncing) {
            return const _HistoryEmptyState(
              icon: PhosphorIcons.clockCountdown,
              title: 'Syncing joined pings',
              subtitle: 'We’re checking your ping history now.',
            );
          }

          if (_syncFailed) {
            return const _HistoryEmptyState(
              icon: PhosphorIcons.warningCircle,
              title: 'Couldn’t sync joined pings',
              subtitle: 'The history worker failed. Try again later.',
            );
          }

          if (_syncTimedOut) {
            return const _HistoryEmptyState(
              icon: PhosphorIcons.clockCountdown,
              title: 'History is taking longer',
              subtitle: 'Open this screen again in a moment.',
            );
          }

          return const _HistoryEmptyState(
            icon: PhosphorIcons.usersThree,
            title: 'No joined pings yet',
            subtitle: 'Pings you join will appear here.',
          );
        }

        return _HistoryList(
          items: items,
          onTap: (item) {
            openPingDetailsSheet(
              context: context,
              pingId: item.pingId,
            );
          },
        );
      },
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.items,
    required this.onTap,
  });

  final List<_PingHistoryItem> items;
  final ValueChanged<_PingHistoryItem> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = items[index];

        return _PingHistoryCard(
          item: item,
          onTap: () => onTap(item),
        );
      },
    );
  }
}

class _PingHistoryCard extends StatelessWidget {
  const _PingHistoryCard({
    required this.item,
    required this.onTap,
  });

  final _PingHistoryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = item.statusLabel;
    final expired = item.isExpired;
    final categoryStyle = _categoryStyle(item.category);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        splashColor: Colors.black.withOpacity(.035),
        highlightColor: Colors.black.withOpacity(.02),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Colors.black.withOpacity(.045),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.045),
              ),
            ],
          ),
          child: Row(
            children: [
              _PingHistoryVisual(
                imageUrl: item.imageUrl,
                icon: categoryStyle.icon,
                color: categoryStyle.color,
              ),

              const SizedBox(width: 13),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _HistoryMiniBadge(
                          label: item.relationLabel,
                          dark: item.relation == _PingHistoryRelation.created,
                        ),
                      ],
                    ),

                    const SizedBox(height: 5),

                    Text(
                      item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12.8,
                        height: 1.24,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.50),
                      ),
                    ),

                    const SizedBox(height: 9),

                    Row(
                      children: [
                        _HistoryStatusPill(
                          label: status,
                          expired: expired,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.timeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 12.2,
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withOpacity(.42),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Icon(
                PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                size: 18,
                color: Colors.black.withOpacity(.28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PingHistoryVisual extends StatelessWidget {
  const _PingHistoryVisual({
    required this.imageUrl,
    required this.icon,
    required this.color,
  });

  final String imageUrl;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.network(
          imageUrl,
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }

    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withOpacity(.18),
            color.withOpacity(.075),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(.12),
        ),
      ),
      child: Center(
        child: PhosphorIcon(
          icon,
          size: 27,
          color: color,
        ),
      ),
    );
  }
}

class _HistoryMiniBadge extends StatelessWidget {
  const _HistoryMiniBadge({
    required this.label,
    required this.dark,
  });

  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF111827) : const Color(0xFFEFF2F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: dark ? Colors.white : Colors.black.withOpacity(.58),
          height: 1,
        ),
      ),
    );
  }
}

class _HistoryStatusPill extends StatelessWidget {
  const _HistoryStatusPill({
    required this.label,
    required this.expired,
  });

  final String label;
  final bool expired;

  @override
  Widget build(BuildContext context) {
    final color = expired ? const Color(0xFF6B7280) : AppColors.brandGreen;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1,
        ),
      ),
    );
  }
}

class _HistoryIconButton extends StatelessWidget {
  const _HistoryIconButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Center(
            child: PhosphorIcon(
              icon,
              size: 20,
              color: const Color(0xFF111827),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryLoadingList extends StatelessWidget {
  const _HistoryLoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, __) {
        return Container(
          height: 90,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.72),
            borderRadius: BorderRadius.circular(26),
          ),
        );
      },
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData Function(PhosphorIconsStyle style) icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.055),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: PhosphorIcon(
                  icon(PhosphorIconsStyle.light),
                  size: 30,
                  color: Colors.black.withOpacity(.50),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13.2,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(.48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _PingHistoryRelation {
  created,
  joined,
}

class _PingHistoryItem {
  const _PingHistoryItem({
    required this.pingId,
    required this.title,
    required this.category,
    required this.privacy,
    required this.locationLine,
    required this.imageUrl,
    required this.participantCount,
    required this.mediaCount,
    required this.createdAt,
    required this.endsAt,
    required this.status,
    required this.relation,
    this.participantStatus = '',
  });

  final String pingId;
  final String title;
  final String category;
  final String privacy;
  final String locationLine;
  final String imageUrl;
  final int participantCount;
  final int mediaCount;
  final DateTime? createdAt;
  final DateTime? endsAt;
  final String status;
  final _PingHistoryRelation relation;
  final String participantStatus;

  factory _PingHistoryItem.fromPingDoc({
    required String pingId,
    required Map<String, dynamic> data,
    required _PingHistoryRelation relation,
    Map<String, dynamic>? participant,
  }) {
    final location = data['location'] is Map
        ? Map<String, dynamic>.from(data['location'] as Map)
        : <String, dynamic>{};

    final placeName = _s(location['placeName']);
    final meetingPoint = _s(location['meetingPoint']);

    final locationLine = placeName.isNotEmpty && meetingPoint.isNotEmpty
        ? '$placeName · $meetingPoint'
        : meetingPoint.isNotEmpty
            ? meetingPoint
            : placeName.isNotEmpty
                ? placeName
                : 'Nearby';

    return _PingHistoryItem(
      pingId: pingId,
      title: _s(data['title']).isEmpty ? 'Untitled ping' : _s(data['title']),
      category: _s(data['category']).isEmpty ? 'General' : _s(data['category']),
      privacy: _s(data['privacy']).isEmpty ? 'public' : _s(data['privacy']),
      locationLine: locationLine,
      imageUrl: _firstMediaImage(data),
      participantCount: _int(data['participantCount']),
      mediaCount: _int(data['mediaCount']),
      createdAt: _date(data['createdAtLocal']) ?? _date(data['createdAt']),
      endsAt: _date(data['endsAt']),
      status: _s(data['status']).isEmpty ? 'active' : _s(data['status']),
      relation: relation,
      participantStatus: _s(participant?['status']),
    );
  }

  factory _PingHistoryItem.fromHistoryDoc({
    required String pingId,
    required Map<String, dynamic> data,
  }) {
    return _PingHistoryItem(
      pingId: _s(data['pingId']).isEmpty ? pingId : _s(data['pingId']),
      title: _s(data['title']).isEmpty ? 'Untitled ping' : _s(data['title']),
      category: _s(data['category']).isEmpty ? 'General' : _s(data['category']),
      privacy: _s(data['privacy']).isEmpty ? 'public' : _s(data['privacy']),
      locationLine: _s(data['locationLine']).isEmpty
          ? 'Nearby'
          : _s(data['locationLine']),
      imageUrl: _firstMediaImage(data),
      participantCount: _int(data['participantCount']),
      mediaCount: _int(data['mediaCount']),
      createdAt: _date(data['createdAtLocal']) ?? _date(data['createdAt']),
      endsAt: _date(data['endsAt']),
      status: _s(data['status']).isEmpty ? 'active' : _s(data['status']),
      relation: _PingHistoryRelation.joined,
      participantStatus: _s(data['participantStatus']),
    );
  }

  bool get isExpired {
    final s = status.toLowerCase();

    if (s == 'ended' || s == 'expired' || s == 'cancelled') return true;

    final end = endsAt;
    if (end != null && !end.isAfter(DateTime.now())) return true;

    return false;
  }

  String get relationLabel {
    switch (relation) {
      case _PingHistoryRelation.created:
        return 'Created';
      case _PingHistoryRelation.joined:
        return participantStatus.toLowerCase() == 'left' ? 'Left' : 'Joined';
    }
  }

  String get statusLabel {
    if (isExpired) return 'Expired';
    return 'Active';
  }

  String get subtitle {
    return '$locationLine • ${_prettyPrivacy(privacy)} • '
        '${_compact(participantCount)} joined';
  }

  String get timeLabel {
    final end = endsAt;
    if (end == null) return 'No end time';

    if (isExpired) return 'Ended ${_relative(end)}';
    return 'Ends ${_relative(end)}';
  }
}

int _sortHistoryItems(_PingHistoryItem a, _PingHistoryItem b) {
  final aTime = a.endsAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final bTime = b.endsAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  return bTime.compareTo(aTime);
}

String _s(dynamic v) => (v ?? '').toString().trim();

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

DateTime? _date(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

String _firstMediaImage(Map<String, dynamic> data) {
  final media = data['media'];
  if (media is! List) return '';

  for (final raw in media) {
    if (raw is! Map) continue;

    final item = Map<String, dynamic>.from(raw);
    final type = _s(item['type']).toLowerCase();
    final thumbUrl = _s(item['thumbUrl']);
    final url = _s(item['url']);

    if (type == 'image') {
      if (url.isNotEmpty) return url;
      if (thumbUrl.isNotEmpty) return thumbUrl;
    }

    if (type == 'video') {
      if (thumbUrl.isNotEmpty) return thumbUrl;
      if (url.isNotEmpty) return url;
    }
  }

  return '';
}

String _prettyPrivacy(String value) {
  final v = value.toLowerCase();
  if (v.contains('friends')) return 'Connections';
  if (v.contains('verified')) return 'Verified';
  if (v.contains('private')) return 'Private';
  return 'Public';
}

String _compact(int value) {
  if (value < 1000) return value.toString();

  final k = value / 1000;
  if (value < 1000000) {
    return k >= 10 ? '${k.toStringAsFixed(0)}k' : '${k.toStringAsFixed(1)}k';
  }

  final m = value / 1000000;
  return m >= 10 ? '${m.toStringAsFixed(0)}m' : '${m.toStringAsFixed(1)}m';
}

String _relative(DateTime value) {
  final diff = value.difference(DateTime.now());
  final past = diff.isNegative;
  final seconds = diff.inSeconds.abs();

  if (seconds < 60) return past ? 'just now' : 'soon';

  final minutes = seconds ~/ 60;
  if (minutes < 60) return past ? '${minutes}m ago' : 'in ${minutes}m';

  final hours = minutes ~/ 60;
  if (hours < 24) return past ? '${hours}h ago' : 'in ${hours}h';

  final days = hours ~/ 24;
  return past ? '${days}d ago' : 'in ${days}d';
}

({IconData icon, Color color}) _categoryStyle(String category) {
  final c = category.toLowerCase().trim();

  if (c.contains('study')) {
    return (
      icon: PhosphorIcons.books(PhosphorIconsStyle.light),
      color: const Color(0xFF6C5CE7),
    );
  }
  if (c.contains('gym')) {
    return (
      icon: PhosphorIcons.fire(PhosphorIconsStyle.light),
      color: const Color(0xFFE74C3C),
    );
  }
  if (c.contains('gaming') || c.contains('game')) {
    return (
      icon: PhosphorIcons.gameController(PhosphorIconsStyle.light),
      color: const Color(0xFF9B59B6),
    );
  }
  if (c.contains('network')) {
    return (
      icon: PhosphorIcons.handshake(PhosphorIconsStyle.light),
      color: const Color(0xFF3498DB),
    );
  }
  if (c.contains('food')) {
    return (
      icon: PhosphorIcons.hamburger(PhosphorIconsStyle.light),
      color: const Color(0xFFFF6B6B),
    );
  }
  if (c.contains('music')) {
    return (
      icon: PhosphorIcons.musicNotes(PhosphorIconsStyle.light),
      color: const Color(0xFFFF1744),
    );
  }
  if (c.contains('sport')) {
    return (
      icon: PhosphorIcons.basketball(PhosphorIconsStyle.light),
      color: const Color(0xFF2196F3),
    );
  }

  return (
    icon: PhosphorIcons.mapPinArea(PhosphorIconsStyle.light),
    color: AppColors.brandGreen,
  );
}