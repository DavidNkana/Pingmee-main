import 'dart:math' as math;
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';

class ProfileEngagementScreen extends StatefulWidget {
  final String uid;

  const ProfileEngagementScreen({
    super.key,
    required this.uid,
  });

  @override
  State<ProfileEngagementScreen> createState() =>
      _ProfileEngagementScreenState();
}

class _ProfileEngagementScreenState extends State<ProfileEngagementScreen> {
  int _rangeDays = 30;

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    if (myUid == null || myUid != widget.uid) {
      return Scaffold(
        backgroundColor: const Color(0xFFEFF2F7),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                "This page is only available to the profile owner.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.68),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final cutoff = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(days: 90)),
  );

  final viewsRef = FirebaseFirestore.instance
      .collection("users")
      .doc(widget.uid)
      .collection("profile_views")
      .where("viewedAt", isGreaterThanOrEqualTo: cutoff)
      .orderBy("viewedAt", descending: true);

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: viewsRef.snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];

            final chartData = _buildChartData(docs, _rangeDays);
            final totalInRange =
                chartData.fold<int>(0, (sum, item) => sum + item.value);

            final cityCounts = _buildCityCounts(docs, _rangeDays);
            final topCities = cityCounts.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));

            final recentViewers = _buildRecentViewers(docs).take(8).toList();
            final allTimeViews = docs.length;
            final todayViews = _countTodayViews(docs);
            final uniqueCities = cityCounts.keys.length;

            return CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      children: [
                        _TopIconButton(
                          icon: PhosphorIcons.arrowLeft(
                            PhosphorIconsStyle.bold,
                          ),
                          onTap: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "Engagement",
                            style: const TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.88),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.black.withOpacity(.06)),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                            color: Colors.black.withOpacity(.05),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "See who’s checking your profile and where your audience usually comes from.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              height: 1.3,
                              color: Colors.black.withOpacity(.60),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _StatCard(
                                  title: "Profile Views",
                                  value: _formatCompactCount(allTimeViews),
                                  subtitle: "All time",
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _StatCard(
                                  title: "Audience",
                                  value: _formatCompactCount(uniqueCities),
                                  subtitle: "Cities in ${_rangeDays}d",
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _StatCard(
                                  title: "Today",
                                  value: _formatCompactCount(todayViews),
                                  subtitle: "Views today",
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _StatCard(
                                  title: "Period Total",
                                  value: _formatCompactCount(totalInRange),
                                  subtitle: "Last $_rangeDays days",
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        _RangeChip(
                          label: "7D",
                          selected: _rangeDays == 7,
                          onTap: () => setState(() => _rangeDays = 7),
                        ),
                        const SizedBox(width: 8),
                        _RangeChip(
                          label: "30D",
                          selected: _rangeDays == 30,
                          onTap: () => setState(() => _rangeDays = 30),
                        ),
                        const SizedBox(width: 8),
                        _RangeChip(
                          label: "90D",
                          selected: _rangeDays == 90,
                          onTap: () => setState(() => _rangeDays = 90),
                        ),
                      ],
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: _GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Profile views",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "How many views you’ve received over the last $_rangeDays days",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.black.withOpacity(.58),
                            ),
                          ),
                          const SizedBox(height: 18),
                          if (chartData.every((e) => e.value == 0))
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 34),
                              alignment: Alignment.center,
                              child: Text(
                                "No profile views yet.",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.black.withOpacity(.55),
                                ),
                              ),
                            )
                          else
                            _MiniBarChart(data: chartData),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: _GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Audience insights",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Where your viewers are usually from",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.black.withOpacity(.58),
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (topCities.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                "No audience location data yet.",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.black.withOpacity(.55),
                                ),
                              ),
                            )
                          else
                            ...topCities.take(8).map(
                              (entry) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _AudienceTile(
                                  city: entry.key,
                                  count: entry.value,
                                  maxCount: topCities.first.value,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: _GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Recent viewers",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Latest people who viewed your profile",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                              color: Colors.black.withOpacity(.58),
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (recentViewers.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                "No recent viewers yet.",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.black.withOpacity(.55),
                                ),
                              ),
                            )
                          else
                            FutureBuilder<Map<String, Map<String, dynamic>>>(
                              future: _loadViewerProfiles(recentViewers),
                              builder: (context, profileSnap) {
                                final profiles = profileSnap.data ?? {};

                                return Column(
                                  children: List.generate(recentViewers.length, (index) {
                                    final item = recentViewers[index];
                                    final profile = profiles[item.viewerUid];

                                    return Padding(
                                      padding: EdgeInsets.only(
                                        bottom: index == recentViewers.length - 1 ? 0 : 10,
                                      ),
                                      child: _RecentViewerTile(
                                        item: item,
                                        profile: profile,
                                        timeText: _timeAgo(item.viewedAt),
                                        onTap: () async {
                                          await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ProfileTab(profileUid: item.viewerUid),
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  }),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<_RecentViewerItem> _buildRecentViewers(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final cutoff = DateTime.now().subtract(const Duration(days: 90));
    final items = <_RecentViewerItem>[];

    for (final doc in docs) {
      final data = doc.data();

      final viewerUid = (data["viewerUid"] ?? "").toString().trim();
      if (viewerUid.isEmpty) continue;

      final city = (data["viewerCity"] ?? data["viewerDisplayLocation"] ?? "Unknown")
          .toString()
          .trim();

      DateTime? viewedAt;
      final ts = data["viewedAt"];
      if (ts is Timestamp) {
        viewedAt = ts.toDate();
      } else {
        final dayKey = (data["dayKey"] ?? "").toString().trim();
        if (dayKey.isNotEmpty) {
          viewedAt = DateTime.tryParse(dayKey);
        }
      }

      if (viewedAt == null) continue;
      if (viewedAt.isBefore(cutoff)) continue;

      items.add(
        _RecentViewerItem(
          viewerUid: viewerUid,
          city: city.isEmpty ? "Unknown" : city,
          viewedAt: viewedAt,
        ),
      );
    }

    items.sort((a, b) {
      final aTime = a.viewedAt?.millisecondsSinceEpoch ?? 0;
      final bTime = b.viewedAt?.millisecondsSinceEpoch ?? 0;
      return bTime.compareTo(aTime);
    });

    return items;
  }

  Future<Map<String, Map<String, dynamic>>> _loadViewerProfiles(
    List<_RecentViewerItem> items,
  ) async {
    final ids = items
        .map((e) => e.viewerUid)
        .where((e) => e.trim().isNotEmpty)
        .toSet()
        .toList();

    final results = <String, Map<String, dynamic>>{};

    await Future.wait(
      ids.map((uid) async {
        try {
          final snap = await FirebaseFirestore.instance
              .collection("users")
              .doc(uid)
              .get();

          if (snap.exists) {
            results[uid] = snap.data() ?? {};
          }
        } catch (_) {}
      }),
    );

    return results;
  }

  String _timeAgo(DateTime? dateTime) {
    if (dateTime == null) return "Recently";

    final diff = DateTime.now().difference(dateTime);

    if (diff.inSeconds < 60) return "Just now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
    if (diff.inHours < 24) return "${diff.inHours}h ago";
    if (diff.inDays == 1) return "Yesterday";
    if (diff.inDays < 7) return "${diff.inDays}d ago";
    if (diff.inDays < 30) return "${(diff.inDays / 7).floor()}w ago";

    return DateFormat("d MMM").format(dateTime);
  }

  int _countTodayViews(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final todayKey = _dayKey(DateTime.now());
    return docs.where((doc) {
      final data = doc.data();
      final key = (data["dayKey"] ?? "").toString();
      if (key.isNotEmpty) return key == todayKey;

      final ts = data["viewedAt"];
      if (ts is Timestamp) {
        return _dayKey(ts.toDate()) == todayKey;
      }
      return false;
    }).length;
  }
  

  List<_BarPoint> _buildChartData(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int rangeDays,
  ) {
    final now = DateTime.now();
    final ninetyDayCutoff = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 90));

    final counts = <String, int>{};

    for (final doc in docs) {
      final data = doc.data();

      DateTime? viewedAt;
      final ts = data["viewedAt"];
      if (ts is Timestamp) {
        viewedAt = ts.toDate();
      } else {
        final key = (data["dayKey"] ?? "").toString();
        if (key.isNotEmpty) {
          viewedAt = DateTime.tryParse(key);
        }
      }

      if (viewedAt == null) continue;
      if (viewedAt.isBefore(ninetyDayCutoff)) continue;

      final key = _dayKey(viewedAt);
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final items = <_BarPoint>[];

    for (int i = rangeDays - 1; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: i));
      final key = _dayKey(day);

      items.add(
        _BarPoint(
          label: DateFormat(rangeDays <= 7 ? "E" : "d").format(day),
          value: counts[key] ?? 0,
          fullLabel: DateFormat("d MMM").format(day),
        ),
      );
    }

    return items;
  }

  Map<String, int> _buildCityCounts(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int rangeDays,
  ) {
    final now = DateTime.now();
    final rangeCutoff = now.subtract(Duration(days: rangeDays - 1));
    final ninetyDayCutoff = now.subtract(const Duration(days: 90));

    final map = <String, int>{};

    for (final doc in docs) {
      final data = doc.data();

      final city = (data["viewerCity"] ?? data["viewerDisplayLocation"] ?? "")
          .toString()
          .trim();
      if (city.isEmpty) continue;

      DateTime? viewedAt;
      final ts = data["viewedAt"];
      if (ts is Timestamp) {
        viewedAt = ts.toDate();
      } else {
        final key = (data["dayKey"] ?? "").toString();
        if (key.isNotEmpty) {
          viewedAt = DateTime.tryParse(key);
        }
      }

      if (viewedAt == null) continue;
      if (viewedAt.isBefore(ninetyDayCutoff)) continue;
      if (viewedAt.isBefore(rangeCutoff)) continue;

      map[city] = (map[city] ?? 0) + 1;
    }

    return map;
  }

  String _dayKey(DateTime date) {
    return DateFormat("yyyy-MM-dd").format(date);
  }

  String _formatCompactCount(int value) {
    final abs = value.abs();

    String stripZero(String s) {
      return s.endsWith(".0") ? s.substring(0, s.length - 2) : s;
    }

    if (abs < 1000) return value.toString();

    if (abs < 1000000) {
      final k = value / 1000;
      final text = abs >= 10000
          ? k.toStringAsFixed(0)
          : stripZero(k.toStringAsFixed(1));
      return "${text}k";
    }

    final m = value / 1000000;
    final text = abs >= 10000000
        ? m.toStringAsFixed(0)
        : stripZero(m.toStringAsFixed(1));
    return "${text}m";
  }
}

class _BarPoint {
  final String label;
  final String fullLabel;
  final int value;

  const _BarPoint({
    required this.label,
    required this.value,
    required this.fullLabel,
  });
}

class _RecentViewerItem {
  final String viewerUid;
  final String city;
  final DateTime? viewedAt;

  const _RecentViewerItem({
    required this.viewerUid,
    required this.city,
    required this.viewedAt,
  });
}

class _RecentViewerTile extends StatelessWidget {
  final _RecentViewerItem item;
  final Map<String, dynamic>? profile;
  final String timeText;
  final VoidCallback onTap;

  const _RecentViewerTile({
    required this.item,
    required this.profile,
    required this.timeText,
    required this.onTap,
  });

  String _pickName() {
    final displayName = (profile?["displayName"] ??
            profile?["fullName"] ??
            profile?["name"] ??
            "")
        .toString()
        .trim();

    final username = (profile?["username"] ?? "").toString().trim();

    if (displayName.isNotEmpty) return displayName;
    if (username.isNotEmpty) return username;
    if (item.city.isNotEmpty && item.city != "Unknown") {
      return "Someone from ${item.city}";
    }
    return "Someone";
  }

  String _pickSubtitle(String title) {
    final hasRealName =
        !(title.startsWith("Someone from") || title == "Someone");

    if (hasRealName && item.city.isNotEmpty && item.city != "Unknown") {
      return "${item.city} • $timeText";
    }
    return timeText;
  }

  String? _photoUrl() {
    final raw = (profile?["photoUrl"] ??
            profile?["profilePhotoUrl"] ??
            profile?["avatarUrl"] ??
            "")
        .toString()
        .trim();

    return raw.isEmpty ? null : raw;
  }

  @override
  Widget build(BuildContext context) {
    final title = _pickName();
    final subtitle = _pickSubtitle(title);
    final photoUrl = _photoUrl();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.76),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.black.withOpacity(.05)),
          ),
          child: Row(
            children: [
              if (photoUrl != null)
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    image: DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    ),
                  ),
                )
              else
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen.withOpacity(.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    title.isNotEmpty ? title[0].toUpperCase() : "?",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.brandGreen,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "$title viewed your profile",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        height: 1.25,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8FB),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                  size: 16,
                  color: Colors.black.withOpacity(.66),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(.84),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black.withOpacity(.06)),
          ),
          child: Icon(icon, size: 20, color: Colors.black87),
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;

  const _GlassCard({
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.82),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.black.withOpacity(.06)),
            boxShadow: [
              BoxShadow(
                blurRadius: 16,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.05),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAF8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.62),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: Colors.black.withOpacity(.52),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.brandGreen : Colors.white.withOpacity(.84),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? AppColors.brandGreen
                  : Colors.black.withOpacity(.06),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniBarChart extends StatelessWidget {
  final List<_BarPoint> data;

  const _MiniBarChart({
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final maxValue = math.max(
      1,
      data.fold<int>(0, (maxSoFar, item) => math.max(maxSoFar, item.value)),
    );

    return Column(
      children: [
        SizedBox(
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: data.map((item) {
              final factor = item.value / maxValue;
              final height = math.max(8.0, 120 * factor);

              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        item.value == 0 ? "" : item.value.toString(),
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: Colors.black.withOpacity(.48),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: height,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              AppColors.brandGreen,
                              AppColors.brandGreen.withOpacity(.35),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                data.first.fullLabel,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.48),
                ),
              ),
            ),
            Text(
              data[data.length ~/ 2].fullLabel,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
                color: Colors.black.withOpacity(.48),
              ),
            ),
            Expanded(
              child: Text(
                data.last.fullLabel,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.48),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AudienceTile extends StatelessWidget {
  final String city;
  final int count;
  final int maxCount;

  const _AudienceTile({
    required this.city,
    required this.count,
    required this.maxCount,
  });

  @override
  Widget build(BuildContext context) {
    final progress = maxCount == 0 ? 0.0 : count / maxCount;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.75),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen.withOpacity(.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  PhosphorIcons.mapPin(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  city,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              Text(
                count.toString(),
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.68),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.black.withOpacity(.05),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.brandGreen,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            count == 1
                ? "1 person from $city viewed your profile"
                : "$count people from $city viewed your profile",
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              height: 1.3,
              color: Colors.black.withOpacity(.58),
            ),
          ),
        ],
      ),
    );
  }
}