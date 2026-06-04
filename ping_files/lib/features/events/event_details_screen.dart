import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:url_launcher/url_launcher.dart';

class EventDetailsData {
  final String id;
  final String title;
  final String? subtitle;
  final String? description;

  final String themeId;

  final String privacy;
  final String access;
  final bool requireRegistration;

  final String venueType;
  final String? locationText;
  final String? venueSubtitle;
  final String? meetupInstructions;

  final List<DateTimeRange> sessions;

  final List<Map<String, dynamic>> media;

  final int attendeeCount;
  final int? maxAttendees;

  final String? category;
  final List<String> tags;

  final String? hostName;
  final String? hostLabel;

  final String? coverImageUrl;
  final String? presetAssetPath;
  final List<int>? gradientCoverColors;
  final int? solidCoverColorValue;

  final bool isAttending;
  final bool isSaved;

  const EventDetailsData({
    required this.id,
    required this.title,
    required this.themeId,
    required this.privacy,
    required this.access,
    required this.requireRegistration,
    required this.venueType,
    required this.sessions,
    required this.attendeeCount,
    this.subtitle,
    this.description,
    this.locationText,
    this.venueSubtitle,
    this.meetupInstructions,
    this.media = const [],
    this.maxAttendees,
    this.category,
    this.tags = const [],
    this.hostName,
    this.hostLabel,
    this.coverImageUrl,
    this.presetAssetPath,
    this.gradientCoverColors,
    this.solidCoverColorValue,
    this.isAttending = false,
    this.isSaved = false,
  });

  static List<Map<String, dynamic>> _toMapList(dynamic value) {
    if (value is! List) return const [];

    return value
        .whereType<Map>()
        .map((e) => e.map((key, val) => MapEntry(key.toString(), val)))
        .toList();
  }

  factory EventDetailsData.fromMap(String id, Map<String, dynamic> map) {
    final cover = _asMap(map['cover']);
    final venue = _asMap(map['venue']);
    debugPrint("🧭 Event meetupInstructions: ${map['meetupInstructions']}");
    debugPrint("🧭 Venue map: $venue");

    final parsedSessions = ((map['sessions'] as List?) ?? const [])
        .map<DateTimeRange?>((raw) {
          final item = _asMap(raw);
          final start = _toDateTime(item['startAt']);
          final end = _toDateTime(item['endAt']);
          if (start == null || end == null) return null;
          return DateTimeRange(start: start, end: end);
        })
        .whereType<DateTimeRange>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    if (parsedSessions.isEmpty) {
      final start = _toDateTime(map['startsAt']);
      final end = _toDateTime(map['endsAt']);
      if (start != null && end != null) {
        parsedSessions.add(DateTimeRange(start: start, end: end));
      }
    }

    return EventDetailsData(
      id: id,
      title: _nonEmpty(map['title']) ?? 'Untitled event',
      subtitle: _nonEmpty(map['subtitle']),
      description: _nonEmpty(map['description']),
      themeId: _nonEmpty(map['themeId']) ??
          _nonEmpty(map['theme']) ??
          _nonEmpty(map['selectedTheme']) ??
          'pink_nova',
      privacy: _nonEmpty(map['privacy']) ?? 'public',
      access: _nonEmpty(map['access']) ?? 'everyone',
      requireRegistration: map['requireRegistration'] == true,
      venueType: _nonEmpty(map['venueType']) ??
          _nonEmpty(venue['type']) ??
          'inPerson',
      locationText: _nonEmpty(map['locationText']) ??
          _nonEmpty(venue['name']) ??
          _nonEmpty(venue['label']) ??
          _nonEmpty(venue['linkOrPlatform']),
      venueSubtitle: _nonEmpty(venue['formattedAddress']) ??
          _nonEmpty(venue['linkOrPlatform']),
      meetupInstructions: _nonEmpty(map['meetupInstructions']) ??
          _nonEmpty(venue['meetupInstructions']) ??
          _nonEmpty(venue['instructions']),
      sessions: parsedSessions,
      attendeeCount: _toInt(map['attendeeCount']) ?? 0,
      maxAttendees: _toInt(map['maxAttendees']),
      media: _toMapList(map['media']),
      category: _nonEmpty(map['category']),
      tags: _toStringList(map['tags']),
      hostName: _nonEmpty(map['hostName']) ??
          _nonEmpty(map['creatorName']) ??
          _nonEmpty(map['ownerName']),
      hostLabel: _nonEmpty(map['hostLabel']) ?? 'Host',
      coverImageUrl: _nonEmpty(cover['imageUrl']),
      presetAssetPath: _nonEmpty(cover['presetAssetPath']),
      gradientCoverColors: _toIntList(cover['gradientColors']),
      solidCoverColorValue: _toInt(cover['colorValue']),
      isAttending: map['viewerIsAttending'] == true || map['isAttending'] == true,
      isSaved: map['viewerIsSaved'] == true || map['isSaved'] == true,
    );
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return <String, dynamic>{};
  }

  static String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static List<String> _toStringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static List<int>? _toIntList(dynamic value) {
    if (value is! List) return null;
    final list = value.whereType<num>().map((e) => e.toInt()).toList();
    return list.isEmpty ? null : list;
  }
}

Future<void> _openEventExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class EventDetailsScreen extends StatefulWidget {
  final EventDetailsData data;
  final VoidCallback? onAttend;
  final VoidCallback? onShare;
  final VoidCallback? onSave;
  final VoidCallback? onMore;

  const EventDetailsScreen({
    super.key,
    required this.data,
    this.onAttend,
    this.onShare,
    this.onSave,
    this.onMore,
  });

  @override
  State<EventDetailsScreen> createState() => _EventDetailsScreenState();
}

class _EventDetailsScreenState extends State<EventDetailsScreen> {
  late bool _isAttending = widget.data.isAttending;
  late bool _isSaved = widget.data.isSaved;

  EventDetailsData? _liveData;

  EventDetailsData get data => _liveData ?? widget.data;

  @override
  void initState() {
    super.initState();
    _loadFreshEventDetails();
  }

  static const List<_EventThemePalette> _eventThemes = [
    _EventThemePalette(
      id: 'pink_nova',
      top: Color(0xFFA86AA0),
      bottom: Color(0xFF243B68),
      solid: Color(0xFFE85ED5),
    ),
    _EventThemePalette(
      id: 'violet_dusk',
      top: Color(0xFF9A84FF),
      bottom: Color(0xFF2E206D),
      solid: Color(0xFF8B5CF6),
    ),
    _EventThemePalette(
      id: 'ocean_night',
      top: Color(0xFF68B7FF),
      bottom: Color(0xFF153C78),
      solid: Color(0xFF3298FF),
    ),
    _EventThemePalette(
      id: 'emerald_night',
      top: Color(0xFF73E3BF),
      bottom: Color(0xFF0B4E4B),
      solid: Color(0xFF16C784),
    ),
    _EventThemePalette(
      id: 'sunset_blaze',
      top: Color(0xFFFF9A7A),
      bottom: Color(0xFF653049),
      solid: Color(0xFFFF6B57),
    ),
    _EventThemePalette(
      id: 'amber_smoke',
      top: Color(0xFFF6CB75),
      bottom: Color(0xFF6B4722),
      solid: Color(0xFFF0A827),
    ),
    _EventThemePalette(
      id: 'berry_wave',
      top: Color(0xFFF29BCE),
      bottom: Color(0xFF4A245B),
      solid: Color(0xFFE95FAF),
    ),
    _EventThemePalette(
      id: 'teal_ink',
      top: Color(0xFF75E0DE),
      bottom: Color(0xFF184C64),
      solid: Color(0xFF21C7C9),
    ),
  ];

  _EventThemePalette get _theme {
    return _eventThemes.firstWhere(
      (theme) => theme.id == data.themeId,
      orElse: () => _eventThemes.first,
    );
  }

  String _firstName(Map<String, dynamic>? user) {
    final fullName = (user?["fullName"] ?? "").toString().trim();
    if (fullName.isNotEmpty) return fullName.split(RegExp(r"\s+")).first;

    final username = (user?["username"] ?? "").toString().trim();
    if (username.isNotEmpty) return username;

    return "Guest";
  }

  String _namesSentence(List<String> names) {
    if (names.isEmpty) return "Be the first one going.";
    if (names.length == 1) return "${names.first} is going.";
    if (names.length == 2) return "${names[0]} and ${names[1]} are going.";

    final head = names.sublist(0, names.length - 1).join(", ");
    return "$head and ${names.last} are going.";
  }

  Future<void> _loadFreshEventDetails() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection("events")
          .doc(widget.data.id)
          .get();

      final map = snap.data();
      if (!mounted || map == null) return;

      final fresh = EventDetailsData.fromMap(widget.data.id, map);

      debugPrint("🧭 Fresh event meetupInstructions: ${fresh.meetupInstructions}");

      setState(() {
        _liveData = fresh;
        _isAttending = fresh.isAttending;
        _isSaved = fresh.isSaved;
      });
    } catch (e) {
      debugPrint("⚠️ Could not refresh event details: $e");
    }
  }

  void _openEventMediaViewer(
    BuildContext context, {
    required List<Map<String, dynamic>> media,
    required int initialIndex,
  }) {
    final viewable = media.where((m) {
      final type = (m["type"] ?? "").toString().toLowerCase();
      return type == "image" || type == "video";
    }).toList();

    if (viewable.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EventMediaViewer(
          media: viewable,
          initialIndex: initialIndex.clamp(0, viewable.length - 1),
        ),
      ),
    );
  }

  Widget _goingAvatar(Map<String, dynamic>? user) {
    final photoUrl = (user?["photoUrl"] ?? "").toString().trim();
    final name = _firstName(user);
    final initial = name.isEmpty ? "P" : name[0].toUpperCase();

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _themeSolid.withOpacity(.18),
        border: Border.all(color: Colors.white, width: 2),
        image: photoUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: photoUrl.isEmpty
          ? Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            )
          : null,
    );
  }

  Widget _extraGoingAvatar(int count) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withOpacity(.12),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Center(
        child: Text(
          "+$count",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Color get _themeSolid => _theme.solid;
  Color get _themeTop => _theme.top;
  Color get _themeBottom => _theme.bottom;
  Color get _softText => Colors.white.withOpacity(.88);
  Color get _mutedText => Colors.white.withOpacity(.66);
  Color get _border => Colors.white.withOpacity(.10);
  Color get _panelFill => Colors.white.withOpacity(.08);

  String get _primaryCtaLabel {
    if (_isAttending) return "You're going";
    if (data.requireRegistration) return 'Request to attend';
    return 'Attend';
  }

  Color get _heroCoverBorder =>
      Color.alphaBlend(
        Colors.black.withOpacity(.42),
        _themeSolid.withOpacity(.70),
      );

  Color get _heroCoverGlow => _themeSolid.withOpacity(.16);

  IconData get _primaryCtaIcon {
    if (_isAttending) {
      return PhosphorIcons.checkCircle(PhosphorIconsStyle.fill);
    }
    return PhosphorIcons.ticket(PhosphorIconsStyle.bold);
  }

  Future<void> _openProfile(BuildContext context, String uid) async {
    final trimmed = uid.trim();
    if (trimmed.isEmpty) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileTab(profileUid: trimmed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color.alphaBlend(Colors.black.withOpacity(.72), _themeTop),
              Color.alphaBlend(Colors.black.withOpacity(.38), _themeBottom),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withOpacity(.03),
                        Colors.transparent,
                        Colors.black.withOpacity(.18),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
              CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 120),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildTopBar(context),
                          const SizedBox(height: 10),
                          _buildHeroCard(),
                          const SizedBox(height: 14),
                          _buildQuickFacts(),
                          const SizedBox(height: 14),
                          _buildDetailsStackCard(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoingSection() {
    return _inlineSection(
      title: 'Going',
      icon: PhosphorIcons.usersThree(PhosphorIconsStyle.bold),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection("events")
            .doc(widget.data.id)
            .collection("hosts")
            .snapshots(),
        builder: (context, hostSnap) {
          final hostIds = (hostSnap.data?.docs ?? const [])
              .where((doc) {
                final data = doc.data();
                final status = (data["status"] ?? "").toString().toLowerCase();
                return status == "active";
              })
              .map((doc) => (doc.data()["uid"] ?? doc.id).toString().trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection("events")
                .doc(widget.data.id)
                .collection("attendees")
                .snapshots(),
            builder: (context, attendeeSnap) {
              final attendeeIds = (attendeeSnap.data?.docs ?? const [])
                  .where((doc) {
                    final data = doc.data();
                    final status = (data["status"] ?? "").toString().toLowerCase();
                    return status == "approved" || status == "going" || status.isEmpty;
                  })
                  .map((doc) => (doc.data()["uid"] ?? doc.id).toString().trim())
                  .where((uid) => uid.isNotEmpty)
                  .toSet();

              final goingIds = <String>{
                ...hostIds,
                ...attendeeIds,
              }.take(8).toList();

              final totalCount = hostIds.length + attendeeIds.difference(hostIds).length;

              if (goingIds.isEmpty) {
                return Text(
                  'No one is going yet.',
                  style: TextStyle(
                    color: _mutedText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                );
              }

              return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                future: FirebaseFirestore.instance
                    .collection("users")
                    .where(FieldPath.documentId, whereIn: goingIds)
                    .get(),
                builder: (context, userSnap) {
                  final usersById = {
                    for (final doc in userSnap.data?.docs ?? const [])
                      doc.id: doc.data(),
                  };

                  final names = goingIds
                      .map((id) => _firstName(usersById[id]))
                      .where((name) => name.isNotEmpty)
                      .take(4)
                      .toList();

                  final extra = totalCount - names.length;

                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.06),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withOpacity(.08)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 38,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (int i = 0; i < goingIds.length && i < 5; i++)
                                Positioned(
                                  left: i * 26.0,
                                  child: _goingAvatar(usersById[goingIds[i]]),
                                ),
                              if (totalCount > 5)
                                Positioned(
                                  left: 5 * 26.0,
                                  child: _extraGoingAvatar(totalCount - 5),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          totalCount == 1
                              ? '1 person is going.'
                              : '$totalCount people are going.',
                          style: TextStyle(
                            color: _softText,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          extra > 0
                              ? '${names.join(", ")} and $extra other${extra == 1 ? "" : "s"} are going.'
                              : _namesSentence(names),
                          style: TextStyle(
                            color: _mutedText,
                            fontSize: 12.8,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  void _openEventCoverViewer() {
    final imageUrl = (data.coverImageUrl ?? '').trim();
    final assetPath = (data.presetAssetPath ?? '').trim();

    if (imageUrl.isEmpty && assetPath.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) {
          final provider = imageUrl.isNotEmpty
              ? NetworkImage(imageUrl)
              : AssetImage(assetPath) as ImageProvider;

          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SizedBox.expand(
                  child: PhotoView(
                    imageProvider: provider,
                    backgroundDecoration: const BoxDecoration(
                      color: Colors.black,
                    ),
                    basePosition: Alignment.center,
                    minScale: PhotoViewComputedScale.contained,
                    initialScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 4,
                  ),
                ),

                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: _circleButton(
                        icon: PhosphorIcons.x(PhosphorIconsStyle.bold),
                        onTap: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Row(
      children: [
        _circleButton(
          icon: PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 12),
        Text(
          'Event details',
          style: TextStyle(
            color: Colors.white.withOpacity(.96),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: .1,
          ),
        ),
      ],
    );
  }

  Widget _buildHeroCard() {
    final firstSession =
        data.sessions.isNotEmpty ? data.sessions.first : null;

    return Container(
      height: 420,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: _heroCoverBorder,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _heroCoverGlow,
            blurRadius: 14,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(.22),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: _openEventCoverViewer,
        child: Padding(
        padding: const EdgeInsets.all(6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildCover(),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withOpacity(.38),
                      Colors.black.withOpacity(.24),
                      Colors.black.withOpacity(.74),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 16,
                child: _heroPill(
                  icon: _venueIcon(data.venueType),
                  label: _venueLabel(data.venueType),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: _heroPill(
                  icon: PhosphorIcons.lockKeyOpen(PhosphorIconsStyle.bold),
                  label: _privacyLabel(data.privacy),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (data.category != null || firstSession != null)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (data.category != null)
                            _heroMetaChip(_capitalise(data.category!)),
                          if (firstSession != null)
                            _heroMetaChip(_formatDayLine(firstSession)),
                        ],
                      ),
                    if (data.category != null || firstSession != null)
                      const SizedBox(height: 14),
                    Text(
                      data.title,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        height: 1.04,
                      ),
                    ),
                    if ((data.subtitle ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        data.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(.82),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withOpacity(.10)),
                          ),
                          child: Icon(
                            PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            data.hostName != null
                                ? '${data.hostName} • ${data.hostLabel ?? "Host"}'
                                : 'Event details',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(.90),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
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
      )
    );
  }

  Widget _buildCover() {
    if ((data.coverImageUrl ?? '').isNotEmpty) {
      return Image.network(
        data.coverImageUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackCover(),
      );
    }

    if ((data.presetAssetPath ?? '').isNotEmpty) {
      return Image.asset(
        data.presetAssetPath!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackCover(),
      );
    }

    return _buildFallbackCover();
  }

  Widget _buildFallbackCover() {
    final gradientColors = data.gradientCoverColors;
    final solidColor = data.solidCoverColorValue != null
        ? Color(data.solidCoverColorValue!)
        : _themeSolid;

    return Container(
      decoration: BoxDecoration(
        gradient: gradientColors != null && gradientColors.length >= 2
            ? LinearGradient(
                colors: gradientColors.map((e) => Color(e)).toList(),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : LinearGradient(
                colors: [
                  Color.lerp(solidColor, Colors.white, .12)!,
                  solidColor,
                  Color.lerp(solidColor, Colors.black, .20)!,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _GridPainter(
                lineColor: Colors.white.withOpacity(.09),
              ),
            ),
          ),
          Positioned(
            left: 20,
            top: 26,
            child: Icon(
              PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
              size: 42,
              color: Colors.white.withOpacity(.11),
            ),
          ),
          Positioned(
            right: 26,
            top: 42,
            child: Icon(
              PhosphorIcons.starFour(PhosphorIconsStyle.fill),
              size: 20,
              color: Colors.white.withOpacity(.12),
            ),
          ),
          Center(
            child: Container(
              width: 118,
              height: 118,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.18),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withOpacity(.16)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.18),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(
                PhosphorIcons.calendarStar(PhosphorIconsStyle.fill),
                size: 54,
                color: Colors.white.withOpacity(.94),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _goingFactTile() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection("events")
          .doc(widget.data.id)
          .collection("hosts")
          .snapshots(),
      builder: (context, hostSnap) {
        final hostIds = (hostSnap.data?.docs ?? const [])
            .where((doc) {
              final data = doc.data();
              final status = (data["status"] ?? "").toString().toLowerCase();
              return status == "active";
            })
            .map((doc) => (doc.data()["uid"] ?? doc.id).toString().trim())
            .where((uid) => uid.isNotEmpty)
            .toSet();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection("events")
              .doc(widget.data.id)
              .collection("attendees")
              .snapshots(),
          builder: (context, attendeeSnap) {
            final attendeeIds = (attendeeSnap.data?.docs ?? const [])
                .where((doc) {
                  final data = doc.data();
                  final status = (data["status"] ?? "").toString().toLowerCase();
                  return status == "approved" ||
                      status == "going" ||
                      status.isEmpty;
                })
                .map((doc) => (doc.data()["uid"] ?? doc.id).toString().trim())
                .where((uid) => uid.isNotEmpty)
                .toSet();

            final totalCount = hostIds.length + attendeeIds.difference(hostIds).length;

            return _factTile(
              icon: PhosphorIcons.usersThree(PhosphorIconsStyle.bold),
              label: 'Going',
              value: data.maxAttendees != null
                  ? '$totalCount/${data.maxAttendees}'
                  : '$totalCount',
            );
          },
        );
      },
    );
  }

  Widget _buildQuickFacts() {
    return Row(
      children: [
        Expanded(
          child: _goingFactTile(),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _factTile(
            icon: PhosphorIcons.clockCountdown(PhosphorIconsStyle.bold),
            label: 'Access',
            value: data.requireRegistration ? 'Approval' : 'Open',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _factTile(
            icon: PhosphorIcons.mapPin(PhosphorIconsStyle.bold),
            label: 'Venue',
            value: _venueLabel(data.venueType),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsStackCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.black.withOpacity(.18),
          _themeBottom.withOpacity(.62),
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGoingSection(),
          _sectionDivider(),
          _buildLocationSection(),
          _sectionDivider(),
          _buildHostSection(),
          _sectionDivider(),
          _buildScheduleSection(),        
          _sectionDivider(),
          _buildAboutSection(),
          _sectionDivider(),
          _buildAccessSection(),
          _sectionDivider(),
          _buildMediaSection(),
          _sectionDivider(),
          _buildDiscoverySection(),
        ],
      ),
    );
  }

  Widget _mediaFallback(String type) {
    return Center(
      child: Icon(
        type == 'video'
            ? PhosphorIcons.videoCamera(PhosphorIconsStyle.bold)
            : PhosphorIcons.image(PhosphorIconsStyle.bold),
        color: Colors.white.withOpacity(.72),
        size: 24,
      ),
    );
  }

  Widget _eventFileTile(String name) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: Colors.white.withOpacity(.08),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              PhosphorIcons.file(PhosphorIconsStyle.bold),
              color: Colors.white.withOpacity(.82),
              size: 24,
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _mutedText,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaSection() {
    final media = data.media;

    return _inlineSection(
      title: 'Media',
      icon: PhosphorIcons.images(PhosphorIconsStyle.bold),
      child: media.isEmpty
          ? Text(
              'No media added.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : GridView.builder(
              itemCount: media.length.clamp(0, 6),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1,
              ),
              itemBuilder: (_, index) {
                final item = media[index];
                final type = (item['type'] ?? '').toString().toLowerCase();
                final url = (item['url'] ?? '').toString();
                final thumbUrl = (item['thumbUrl'] ?? '').toString();
                final name = (item['name'] ?? 'File').toString();

                if (type == 'file') {
                  return GestureDetector(
                    onTap: () {
                      if (url.isNotEmpty) _openEventExternalUrl(url);
                    },
                    child: _eventFileTile(name),
                  );
                }

                final image = type == 'video' ? thumbUrl : url;

                return GestureDetector(
                  onTap: () => _openEventMediaViewer(
                    context,
                    media: media,
                    initialIndex: index,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      color: Colors.white.withOpacity(.08),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (image.isNotEmpty)
                            Image.network(
                              image,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _mediaFallback(type),
                            )
                          else
                            _mediaFallback(type),

                          if (type == 'video')
                            Center(
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(.50),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _sectionDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Container(
        height: 1,
        color: Colors.white.withOpacity(.08),
      ),
    );
  }

  Widget _inlineSection({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _themeSolid.withOpacity(.18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _themeSolid.withOpacity(.20)),
              ),
              child: Icon(
                icon,
                size: 17,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                color: Colors.white.withOpacity(.95),
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    );
  }

  Widget _buildHostSection() {
    return _inlineSection(
      title: 'Hosts',
      icon: PhosphorIcons.crownSimple(PhosphorIconsStyle.bold),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection("events")
            .doc(widget.data.id)
            .collection("hosts")
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(_themeSolid),
              ),
            );
          }

          final docs = snapshot.data?.docs ?? const [];

          final hostDocs = docs.where((doc) {
            final data = doc.data();
            final role = (data["role"] ?? "").toString().trim().toLowerCase();
            final status = (data["status"] ?? "").toString().trim().toLowerCase();

            return status == "active" && (role == "owner" || role == "cohost");
          }).toList()
            ..sort((a, b) {
              final aRole = (a.data()["role"] ?? "").toString().trim().toLowerCase();
              final bRole = (b.data()["role"] ?? "").toString().trim().toLowerCase();

              final aPriority = aRole == "owner" ? 0 : 1;
              final bPriority = bRole == "owner" ? 0 : 1;

              return aPriority.compareTo(bPriority);
            });

          if (hostDocs.isEmpty) {
            return Text(
              widget.data.hostName ?? 'No active hosts yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            );
          }

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.06),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(.08)),
            ),
            child: Column(
              children: List.generate(hostDocs.length, (index) {
                final doc = hostDocs[index];

                return Column(
                  children: [
                    _buildLiveHostTile(doc),
                    if (index != hostDocs.length - 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 58, right: 12),
                        child: Divider(
                          height: 1,
                          color: Colors.white.withOpacity(.07),
                        ),
                      ),
                  ],
                );
              }),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveHostTile(
    QueryDocumentSnapshot<Map<String, dynamic>> hostDoc,
  ) {
    final hostData = hostDoc.data();
    final uid = ((hostData["uid"] ?? hostDoc.id).toString()).trim();
    final role = (hostData["role"] ?? "").toString().trim().toLowerCase();

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection("users").doc(uid).get(),
      builder: (context, snapshot) {
        final user = snapshot.data?.data() ?? const <String, dynamic>{};

        final fullName = ((user["fullName"] ?? "").toString().trim().isNotEmpty)
            ? (user["fullName"] ?? "").toString().trim()
            : (role == "owner"
                ? (widget.data.hostName ?? "Event host")
                : "Co-host");

        final photoUrl = (user["photoUrl"] ?? "").toString().trim();

        final headline = ((user["headline"] ??
                    user["intro"] ??
                    user["bio"] ??
                    "")
                .toString()
                .trim()
                .isNotEmpty)
            ? (user["headline"] ?? user["intro"] ?? user["bio"]).toString().trim()
            : "No headline yet";

        final verification =
            Map<String, dynamic>.from(user["verification"] ?? const {});
        final verified = verification["status"] == "verified";

        return InkWell(
          onTap: uid.isEmpty ? null : () => _openProfile(context, uid),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: _themeSolid.withOpacity(.18),
                  backgroundImage:
                      photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                  child: photoUrl.isEmpty
                      ? Icon(
                          PhosphorIcons.userCircle(PhosphorIconsStyle.fill),
                          size: 15,
                          color: Colors.white,
                        )
                      : null,
                ),
                const SizedBox(width: 10),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _softText,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (verified) ...[
                            const SizedBox(width: 5),
                            Icon(
                              PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                              size: 14,
                              color: _themeSolid,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _mutedText,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),
                Icon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                  size: 15,
                  color: Colors.white.withOpacity(.42),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAboutSection() {
    final text = (data.description ?? '').trim();

    return _inlineSection(
      title: 'About',
      icon: PhosphorIcons.notePencil(PhosphorIconsStyle.bold),
      child: text.isEmpty
          ? Text(
              'No description yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.5,
              ),
            )
          : _formattedEventDescription(text),
    );
  }

  Widget _inlineFormattedText(String text) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*.*?\*\*|__.*?__)');

    int current = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > current) {
        spans.add(_normalSpan(text.substring(current, match.start)));
      }

      final token = match.group(0)!;

      if (token.startsWith('**')) {
        spans.add(_normalSpan(
          token.substring(2, token.length - 2),
          bold: true,
        ));
      } else if (token.startsWith('__')) {
        spans.add(_normalSpan(
          token.substring(2, token.length - 2),
          underline: true,
        ));
      }

      current = match.end;
    }

    if (current < text.length) {
      spans.add(_normalSpan(text.substring(current)));
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }

  TextSpan _normalSpan(
    String text, {
    bool bold = false,
    bool underline = false,
  }) {
    return TextSpan(
      text: text,
      style: TextStyle(
        color: _softText,
        fontSize: 14,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
        height: 1.5,
        decoration: underline ? TextDecoration.underline : TextDecoration.none,
        decorationColor: _softText,
        decorationThickness: 1.4,
      ),
    );
  }

  Widget _formattedEventDescription(String raw) {
    final lines = raw.split('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        final trimmed = line.trim();

        if (trimmed.isEmpty) {
          return const SizedBox(height: 10);
        }

        if (trimmed.startsWith('# ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              trimmed.substring(2),
              style: TextStyle(
                color: _softText,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
          );
        }

        if (trimmed.startsWith('## ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              trimmed.substring(3),
              style: TextStyle(
                color: _softText,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          );
        }

        if (trimmed.startsWith('- ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '•',
                  style: TextStyle(
                    color: _themeSolid,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _inlineFormattedText(trimmed.substring(2))),
              ],
            ),
          );
        }

        if (RegExp(r'^\d+\.\s').hasMatch(trimmed)) {
          final splitIndex = trimmed.indexOf(' ');
          final number = trimmed.substring(0, splitIndex);

          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  number,
                  style: TextStyle(
                    color: _themeSolid,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _inlineFormattedText(trimmed.substring(splitIndex + 1))),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _inlineFormattedText(trimmed),
        );
      }).toList(),
    );
  }

  Widget _buildScheduleSection() {
    return _inlineSection(
      title: 'Schedule',
      icon: PhosphorIcons.calendarDots(PhosphorIconsStyle.bold),
      child: data.sessions.isEmpty
          ? Text(
              'No schedule yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : SizedBox(
              height: 126,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: data.sessions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final session = data.sessions[index];

                  return SizedBox(
                    width: MediaQuery.of(context).size.width * .72,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.06),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white.withOpacity(.08)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: _themeSolid.withOpacity(.18),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              PhosphorIcons.clock(PhosphorIconsStyle.fill),
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
                                  'Session ${index + 1}',
                                  style: TextStyle(
                                    color: _softText,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  _formatSessionRange(session),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _softText,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          //   if (widget.data.sessions.length > 1) ...[
          //   const SizedBox(height: 10),
          //   Text(
          //     'Swipe left to see more sessions →',
          //     style: TextStyle(
          //       color: _mutedText,
          //       fontSize: 12,
          //       fontWeight: FontWeight.w600,
          //     ),
          //   ),
          // ],
    );
  }

  Widget _buildLocationSection() {
    final location = (data.locationText ?? '').trim();
    final venueSubtitle = (data.venueSubtitle ?? '').trim();
    final instructions = (data.meetupInstructions ?? '').trim();

    debugPrint("🧭 DETAILS location=$location");
    debugPrint("🧭 DETAILS venueSubtitle=$venueSubtitle");
    debugPrint("🧭 DETAILS furtherInstructions=$instructions");

    return _inlineSection(
      title: 'Location',
      icon: _venueIcon(data.venueType),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            location.isEmpty
                ? (data.venueType == 'virtual'
                    ? 'Virtual event'
                    : 'Location not added')
                : location,
            style: TextStyle(
              color: _softText,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              height: 1.35,
            ),
          ),

          if (venueSubtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              venueSubtitle,
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ],

          if (instructions.isNotEmpty) ...[
            const SizedBox(height: 14),

            Container(
              height: 1,
              width: double.infinity,
              color: Colors.white.withOpacity(.08),
            ),

            const SizedBox(height: 14),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  PhosphorIcons.path(PhosphorIconsStyle.bold),
                  size: 16,
                  color: _themeSolid,
                ),
                const SizedBox(width: 10),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Further instructions",
                        style: TextStyle(
                          color: _softText,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        instructions,
                        style: TextStyle(
                          color: _mutedText,
                          fontSize: 12.8,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAccessSection() {
    return _inlineSection(
      title: 'Access',
      icon: PhosphorIcons.shieldCheckered(PhosphorIconsStyle.bold),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _infoChip(
            icon: PhosphorIcons.lockKeyOpen(PhosphorIconsStyle.bold),
            label: _privacyLabel(data.privacy),
          ),
          _infoChip(
            icon: PhosphorIcons.userCircleCheck(PhosphorIconsStyle.bold),
            label: _accessLabel(data.access),
          ),
          _infoChip(
            icon: PhosphorIcons.ticket(PhosphorIconsStyle.bold),
            label: data.requireRegistration
                ? 'Registration required'
                : 'Free join',
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoverySection() {
    final tags = <String>[
      if ((data.category ?? '').trim().isNotEmpty)
        _capitalise(data.category!),
      ...data.tags,
    ];

    return _inlineSection(
      title: 'Discovery',
      icon: PhosphorIcons.hash(PhosphorIconsStyle.bold),
      child: tags.isEmpty
          ? Text(
              'No tags yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              children: tags.take(12).map((tag) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.06),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withOpacity(.08)),
                  ),
                  child: Text(
                    tag.startsWith('#') ? tag : '#$tag',
                    style: TextStyle(
                      color: _softText,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildAboutCard() {
    final text = (widget.data.description ?? '').trim();

    return _glassCard(
      title: 'About',
      icon: PhosphorIcons.notePencil(PhosphorIconsStyle.bold),
      child: Text(
        text.isEmpty ? 'No description yet.' : text,
        style: TextStyle(
          color: text.isEmpty ? _mutedText : _softText,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildScheduleCard() {
    return _glassCard(
      title: 'Schedule',
      icon: PhosphorIcons.calendarDots(PhosphorIconsStyle.bold),
      child: widget.data.sessions.isEmpty
          ? Text(
              'No schedule yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : Column(
              children: List.generate(widget.data.sessions.length, (index) {
                final session = widget.data.sessions[index];
                final last = index == widget.data.sessions.length - 1;

                return Container(
                  margin: EdgeInsets.only(bottom: last ? 0 : 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.06),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withOpacity(.08)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _themeSolid.withOpacity(.18),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          PhosphorIcons.clock(PhosphorIconsStyle.fill),
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
                              'Session ${index + 1}',
                              style: TextStyle(
                                color: _softText,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _formatSessionRange(session),
                              style: TextStyle(
                                color: _softText,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
    );
  }

  Widget _buildLocationCard() {
    final location = (widget.data.locationText ?? '').trim();
    final venueSubtitle = (widget.data.venueSubtitle ?? '').trim();
    final instructions = (data.meetupInstructions ?? '').trim();

    return _glassCard(
      title: 'Location',
      icon: _venueIcon(widget.data.venueType),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            location.isEmpty
                ? (widget.data.venueType == 'virtual'
                    ? 'Virtual event'
                    : 'Location not added')
                : location,
            style: TextStyle(
              color: _softText,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              height: 1.35,
            ),
          ),
          if (venueSubtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              venueSubtitle,
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ],
          if (instructions.isNotEmpty) ...[
            const SizedBox(height: 14),

            Container(
              height: 1,
              width: double.infinity,
              color: Colors.white.withOpacity(.08),
            ),

            const SizedBox(height: 14),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  PhosphorIcons.path(PhosphorIconsStyle.bold),
                  size: 16,
                  color: _themeSolid,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Further instructions",
                        style: TextStyle(
                          color: _softText,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        instructions,
                        style: TextStyle(
                          color: _mutedText,
                          fontSize: 12.8,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAccessCard() {
    return _glassCard(
      title: 'Access',
      icon: PhosphorIcons.shieldCheckered(PhosphorIconsStyle.bold),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _infoChip(
            icon: PhosphorIcons.lockKeyOpen(PhosphorIconsStyle.bold),
            label: _privacyLabel(widget.data.privacy),
          ),
          _infoChip(
            icon: PhosphorIcons.userCircleCheck(PhosphorIconsStyle.bold),
            label: _accessLabel(widget.data.access),
          ),
          _infoChip(
            icon: PhosphorIcons.ticket(PhosphorIconsStyle.bold),
            label: widget.data.requireRegistration
                ? 'Registration required'
                : 'Free join',
          ),
        ],
      ),
    );
  }

  Widget _buildTagsCard() {
    final tags = <String>[
      if ((widget.data.category ?? '').trim().isNotEmpty)
        _capitalise(widget.data.category!),
      ...widget.data.tags,
    ];

    return _glassCard(
      title: 'Discovery',
      icon: PhosphorIcons.hash(PhosphorIconsStyle.bold),
      child: tags.isEmpty
          ? Text(
              'No tags yet.',
              style: TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              children: tags.take(12).map((tag) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.06),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withOpacity(.08)),
                  ),
                  child: Text(
                    tag.startsWith('#') ? tag : '#$tag',
                    style: TextStyle(
                      color: _softText,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildHostCard() {
    return _glassCard(
      title: 'Host',
      icon: PhosphorIcons.crownSimple(PhosphorIconsStyle.bold),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _themeSolid.withOpacity(.20),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _themeSolid.withOpacity(.22)),
            ),
            child: Icon(
              PhosphorIcons.userCircle(PhosphorIconsStyle.fill),
              size: 24,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              data.hostName ?? 'Event host',
              style: TextStyle(
                color: _softText,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(.24),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(.12)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _isAttending = !_isAttending;
                      });
                      widget.onAttend?.call();
                    },
                    child: Container(
                      height: 58,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color.lerp(_themeSolid, Colors.white, .08)!,
                            _themeSolid,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: _themeSolid.withOpacity(.28),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _primaryCtaIcon,
                            size: 18,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _primaryCtaLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _smallActionButton(
                  icon: _isSaved
                      ? PhosphorIcons.bookmarkSimple(PhosphorIconsStyle.fill)
                      : PhosphorIcons.bookmarkSimple(PhosphorIconsStyle.bold),
                  onTap: () {
                    setState(() {
                      _isSaved = !_isSaved;
                    });
                    widget.onSave?.call();
                  },
                ),
                const SizedBox(width: 10),
                _smallActionButton(
                  icon: PhosphorIcons.shareNetwork(PhosphorIconsStyle.bold),
                  onTap: widget.onShare,
                ),
                const SizedBox(width: 10),
                _smallActionButton(
                  icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                  onTap: widget.onMore,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _glassCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.black.withOpacity(.18),
          _themeBottom.withOpacity(.62),
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _themeSolid.withOpacity(.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _themeSolid.withOpacity(.20)),
                ),
                child: Icon(
                  icon,
                  size: 17,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  color: Colors.white.withOpacity(.95),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _factTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.black.withOpacity(.14),
          _themeBottom.withOpacity(.54),
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: Colors.white.withOpacity(.92),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(
              color: _mutedText,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _softText,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroPill({
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroMetaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(.12)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withOpacity(.92),
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _infoChip({
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _panelFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white.withOpacity(.92)),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: _softText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.12),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(.10)),
          ),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }

  Widget _smallActionButton({
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 58,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.10),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(.10)),
        ),
        child: Icon(
          icon,
          size: 20,
          color: Colors.white,
        ),
      ),
    );
  }

  String _privacyLabel(String raw) {
    switch (raw.toLowerCase()) {
      case 'connections':
        return 'Friends';
      case 'inviteonly':
      case 'invite_only':
      case 'invite-only':
        return 'Invite only';
      case 'public':
      default:
        return 'Public';
    }
  }

  String _accessLabel(String raw) {
    switch (raw.toLowerCase()) {
      case 'connectionsonly':
      case 'connections_only':
      case 'friends':
        return 'Friends only';
      case 'verifiedonly':
      case 'verified_only':
        return 'Verified only';
      case 'everyone':
      default:
        return 'Everyone';
    }
  }

  String _venueLabel(String raw) {
    return raw.toLowerCase() == 'virtual' ? 'Virtual' : 'In person';
  }

  IconData _venueIcon(String raw) {
    return raw.toLowerCase() == 'virtual'
        ? PhosphorIcons.videoCamera(PhosphorIconsStyle.bold)
        : PhosphorIcons.mapPin(PhosphorIconsStyle.bold);
  }

  String _capitalise(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }

  String _formatDayLine(DateTimeRange range) {
    final sameDay = range.start.year == range.end.year &&
        range.start.month == range.end.month &&
        range.start.day == range.end.day;

    if (sameDay) {
      return '${_weekdayShort(range.start.weekday)}, ${_monthShort(range.start.month)} ${range.start.day}';
    }

    return '${_monthShort(range.start.month)} ${range.start.day} - ${_monthShort(range.end.month)} ${range.end.day}';
  }

  String _formatSessionRange(DateTimeRange range) {
    final sameDay = range.start.year == range.end.year &&
        range.start.month == range.end.month &&
        range.start.day == range.end.day;

    if (sameDay) {
      return '${_weekdayShort(range.start.weekday)}, ${_monthShort(range.start.month)} ${range.start.day} • ${_formatTime(range.start)} - ${_formatTime(range.end)}';
    }

    return '${_weekdayShort(range.start.weekday)}, ${_monthShort(range.start.month)} ${range.start.day} ${_formatTime(range.start)}\n'
        'to ${_weekdayShort(range.end.weekday)}, ${_monthShort(range.end.month)} ${range.end.day} ${_formatTime(range.end)}';
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $suffix';
  }

  String _weekdayShort(int weekday) {
    const values = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return values[(weekday - 1).clamp(0, 6)];
  }

  String _monthShort(int month) {
    const values = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return values[(month - 1).clamp(0, 11)];
  }
}

class _EventThemePalette {
  final String id;
  final Color top;
  final Color bottom;
  final Color solid;

  const _EventThemePalette({
    required this.id,
    required this.top,
    required this.bottom,
    required this.solid,
  });
}

class _GridPainter extends CustomPainter {
  final Color lineColor;

  const _GridPainter({
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 28.0;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor;
  }
}

class _EventMediaViewer extends StatefulWidget {
  final List<Map<String, dynamic>> media;
  final int initialIndex;

  const _EventMediaViewer({
    required this.media,
    required this.initialIndex,
  });

  @override
  State<_EventMediaViewer> createState() => _EventMediaViewerState();
}

class _EventMediaViewerState extends State<_EventMediaViewer> {
  late final PageController _page;
  late int _index;

  final Map<int, VideoPlayerController> _video = {};
  final Map<int, ChewieController> _chewie = {};

  String _s(dynamic value) => (value ?? "").toString().trim();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    _prepareVideo(_index);
  }

  Future<void> _prepareVideo(int i) async {
    if (i < 0 || i >= widget.media.length) return;

    final item = widget.media[i];
    final type = _s(item["type"]).toLowerCase();
    final url = _s(item["url"]);

    if (type != "video" || url.isEmpty || _video.containsKey(i)) return;

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _video[i] = controller;

    await controller.initialize();

    if (!mounted) return;

    _chewie[i] = ChewieController(
      videoPlayerController: controller,
      autoPlay: i == _index,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
    );

    setState(() {});
  }

  void _next() {
    if (_index >= widget.media.length - 1) {
      Navigator.pop(context);
      return;
    }

    _page.nextPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _previous() {
    if (_index <= 0) return;

    _page.previousPage(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    for (final c in _chewie.values) {
      c.dispose();
    }
    for (final v in _video.values) {
      v.dispose();
    }
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (details) {
          final width = MediaQuery.of(context).size.width;
          if (details.globalPosition.dx < width / 2) {
            _previous();
          } else {
            _next();
          }
        },
        onVerticalDragUpdate: (details) {
          if ((details.primaryDelta ?? 0) > 10) {
            Navigator.pop(context);
          }
        },
        child: SafeArea(
          child: Stack(
            children: [
              PageView.builder(
                controller: _page,
                itemCount: widget.media.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _prepareVideo(i);
                  _prepareVideo(i + 1);
                },
                itemBuilder: (_, i) {
                  final item = widget.media[i];
                  final type = _s(item["type"]).toLowerCase();
                  final url = _s(item["url"]);
                  final thumb = _s(item["thumbUrl"]);

                  if (type == "video") {
                    final chewie = _chewie[i];

                    return Center(
                      child: chewie != null
                          ? Chewie(controller: chewie)
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                if (thumb.isNotEmpty)
                                  Image.network(thumb, fit: BoxFit.contain),
                                const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ],
                            ),
                    );
                  }

                  return PhotoView(
                    imageProvider: NetworkImage(url),
                    backgroundDecoration: const BoxDecoration(
                      color: Colors.black,
                    ),
                    minScale: PhotoViewComputedScale.contained,
                    initialScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 3,
                  );
                },
              ),

              Positioned(
                top: 12,
                left: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}