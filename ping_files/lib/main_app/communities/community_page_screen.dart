// ping_files/main_app/communities/community_page_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ping_files/theme/colors2.dart';

class CommunityPageScreen extends StatefulWidget {
  const CommunityPageScreen({
    super.key,
    required this.communityId,
    this.onBack,
    this.onEditCommunity,
    this.onCreateEvent,
    this.onCreateTask,
    this.onCreatePost,
    this.onOpenMenu,
    this.onSubscribeTap,
  });

  final String communityId;
  final VoidCallback? onBack;
  final void Function(String communityId, Map<String, dynamic> data)?
      onEditCommunity;
  final void Function(String communityId, Map<String, dynamic> data)?
      onCreateEvent;
  final void Function(String communityId, Map<String, dynamic> data)?
      onCreateTask;
  final void Function(String communityId, Map<String, dynamic> data)?
      onCreatePost;
  final void Function(String communityId, Map<String, dynamic> data)? onOpenMenu;
  final void Function(String communityId, Map<String, dynamic> data)?
      onSubscribeTap;

  @override
  State<CommunityPageScreen> createState() => _CommunityPageScreenState();
}

class _CommunityPageScreenState extends State<CommunityPageScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docRef = FirebaseFirestore.instance
        .collection('communities')
        .doc(widget.communityId);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: docRef.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _CommunityLoadingScreen();
        }

        if (!snap.hasData || !snap.data!.exists) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F8F3),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AppColors.brandGreen.withOpacity(.10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          PhosphorIconsRegular.usersThree,
                          size: 30,
                          color: AppColors.brandGreen,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Community not found',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This community may have been removed or not finished yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                          color: Colors.black.withOpacity(.58),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final data = snap.data!.data() ?? <String, dynamic>{};
        final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
        final ownerUid = (data['ownerUid'] ?? '').toString();
        final isOwner = ownerUid.isNotEmpty && ownerUid == currentUid;

        return Scaffold(
          backgroundColor: const Color(0xFFF7F8F3),
          body: NestedScrollView(
            physics: const BouncingScrollPhysics(),
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: _CommunityHeaderCard(
                      data: data,
                      isOwner: isOwner,
                      onBack: widget.onBack ?? () => Navigator.pop(context),
                      onEdit: isOwner && widget.onEditCommunity != null
                          ? () => widget.onEditCommunity!(widget.communityId, data)
                          : null,
                      onCreateEvent: isOwner && widget.onCreateEvent != null
                          ? () => widget.onCreateEvent!(widget.communityId, data)
                          : null,
                      onOpenMenu: widget.onOpenMenu != null
                          ? () => widget.onOpenMenu!(widget.communityId, data)
                          : null,
                      onSubscribeTap:
                          !isOwner && widget.onSubscribeTap != null
                              ? () => widget.onSubscribeTap!(widget.communityId, data)
                              : null,
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _PinnedTabBarDelegate(
                    height: 70,
                    child: Container(
                      color: const Color(0xFFF7F8F3),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      alignment: Alignment.center,
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.black.withOpacity(.05),
                          ),
                        ),
                        child: TabBar(
                          controller: _tabs,
                          indicator: BoxDecoration(
                            color: AppColors.brandGreen.withOpacity(.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          dividerColor: Colors.transparent,
                          labelColor: AppColors.brandGreen,
                          unselectedLabelColor: Colors.black54,
                          labelStyle: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                          unselectedLabelStyle: const TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                          tabs: const [
                            Tab(text: 'About'),
                            Tab(text: 'Events'),
                            Tab(text: 'Tasks'),
                            Tab(text: 'Posts'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ];
            },
            body: TabBarView(
              controller: _tabs,
              children: [
                _AboutTab(
                  data: data,
                  isOwner: isOwner,
                  onEditCommunity: isOwner && widget.onEditCommunity != null
                      ? () => widget.onEditCommunity!(widget.communityId, data)
                      : null,
                ),
                _EventsTab(
                  communityId: widget.communityId,
                  isOwner: isOwner,
                  onCreate: isOwner && widget.onCreateEvent != null
                      ? () => widget.onCreateEvent!(widget.communityId, data)
                      : null,
                ),
                _TasksTab(
                  communityId: widget.communityId,
                  isOwner: isOwner,
                  onCreate: isOwner && widget.onCreateTask != null
                      ? () => widget.onCreateTask!(widget.communityId, data)
                      : null,
                ),
                _PostsTab(
                  communityId: widget.communityId,
                  isOwner: isOwner,
                  onCreate: isOwner && widget.onCreatePost != null
                      ? () => widget.onCreatePost!(widget.communityId, data)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CommunityHeaderCard extends StatelessWidget {
  const _CommunityHeaderCard({
    required this.data,
    required this.isOwner,
    required this.onBack,
    this.onEdit,
    this.onCreateEvent,
    this.onOpenMenu,
    this.onSubscribeTap,
  });

  final Map<String, dynamic> data;
  final bool isOwner;
  final VoidCallback onBack;
  final VoidCallback? onEdit;
  final VoidCallback? onCreateEvent;
  final VoidCallback? onOpenMenu;
  final VoidCallback? onSubscribeTap;

  @override
  Widget build(BuildContext context) {
    final themeColor = _readThemeColor(data);
    final communityName = _readString(
      data,
      const ['name', 'communityName'],
      fallback: 'Community name',
    );
    final headline = _readString(
      data,
      const ['headline'],
      fallback: 'A real community with real energy.',
    );
    final category = _readString(
      data,
      const ['category', 'communityCategory'],
      fallback: 'Community',
    );
    final city = _readString(
      data,
      const ['baseCity', 'city', 'locationName', 'baseLocationName'],
      fallback: '',
    );
    final website = _readString(
      data,
      const ['website'],
      fallback: '',
    );
    final photoUrl = _readString(
      data,
      const ['photoUrl', 'profilePhotoUrl'],
      fallback: '',
    );
    final coverUrl = _readString(
      data,
      const ['coverUrl', 'coverPhotoUrl'],
      fallback: '',
    );

    final subscribersCount = _readInt(
      data,
      const ['subscribersCount'],
      fallback: 0,
    );
    final eventsCount = _readInt(
      data,
      const ['eventsCount'],
      fallback: 0,
    );
    final radiusKm = _readInt(
      data,
      const ['radiusKm', 'discoveryRadiusKm'],
      fallback: 0,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              blurRadius: 26,
              offset: const Offset(0, 12),
              color: Colors.black.withOpacity(.06),
            ),
          ],
        ),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  child: _CommunityCover(
                    coverUrl: coverUrl,
                    themeColor: themeColor,
                  ),
                ),
                Positioned(
                  top: 14,
                  left: 14,
                  child: _CircleIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: onBack,
                  ),
                ),
                Positioned(
                  top: 14,
                  right: 14,
                  child: Row(
                    children: [
                      if (isOwner && onOpenMenu != null)
                        _CircleIconButton(
                          icon: Icons.more_horiz_rounded,
                          onTap: onOpenMenu!,
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 18,
                  bottom: -34,
                  child: _CommunityAvatar(
                    photoUrl: photoUrl,
                    themeColor: themeColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 44),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _MetricChip(
                        label: 'Subscribers',
                        value: formatCompactCount(subscribersCount),
                      ),
                      const SizedBox(width: 10),
                      _MetricChip(
                        label: 'Events',
                        value: formatCompactCount(eventsCount),
                      ),
                    ],
                  ),
                  if (website.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _launchExternal(context, website),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              PhosphorIconsRegular.globeHemisphereWest,
                              size: 16,
                              color: AppColors.brandGreen,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _stripUrlProtocol(website),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.brandGreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    communityName,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    headline,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: Colors.black.withOpacity(.62),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _HeaderInfoPill(
                        icon: PhosphorIconsRegular.usersThree,
                        text: category,
                      ),
                      if (radiusKm > 0)
                        _HeaderInfoPill(
                          icon: PhosphorIconsRegular.mapPinArea,
                          text: '$radiusKm km radius',
                        ),
                      if (city.trim().isNotEmpty)
                        _HeaderInfoPill(
                          icon: PhosphorIconsRegular.mapPin,
                          text: city,
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (isOwner)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: onCreateEvent,
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: AppColors.brandGreen,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Icon(
                                  PhosphorIconsBold.plus,
                                  size: 18,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'Create event',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: onEdit,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: Colors.black.withOpacity(.08),
                              ),
                              backgroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  PhosphorIconsRegular.pencilSimple,
                                  size: 18,
                                  color: Colors.black.withOpacity(.72),
                                ),
                                const SizedBox(width: 8),
                                const Flexible(
                                  child: Text(
                                    'Edit community',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (onOpenMenu != null) ...[
                          const SizedBox(width: 10),
                          _ActionDotsButton(onTap: onOpenMenu!),
                        ],
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: onSubscribeTap,
                        style: ElevatedButton.styleFrom(
                          elevation: 0,
                          backgroundColor: AppColors.brandGreen,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          'Subscribe',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
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
}

class _AboutTab extends StatelessWidget {
  const _AboutTab({
    required this.data,
    required this.isOwner,
    this.onEditCommunity,
  });

  final Map<String, dynamic> data;
  final bool isOwner;
  final VoidCallback? onEditCommunity;

  @override
  Widget build(BuildContext context) {
    final bio = _readString(
      data,
      const ['bio', 'shortBio'],
      fallback: 'This community has not added a bio yet.',
    );

    final website = _readString(data, const ['website'], fallback: '');
    final email = _readString(data, const ['email'], fallback: '');
    final phone = _readString(data, const ['phone'], fallback: '');
    final category = _readString(
      data,
      const ['category', 'communityCategory'],
      fallback: 'Community',
    );
    final radiusKm = _readInt(
      data,
      const ['radiusKm', 'discoveryRadiusKm'],
      fallback: 0,
    );
    final city = _readString(
      data,
      const ['baseCity', 'city', 'locationName', 'baseLocationName'],
      fallback: '',
    );
    final hoursMode = _readString(data, const ['hoursMode'], fallback: 'none');
    final hours = _readHoursMap(data);
    final socials = _readVisibleSocials(data);

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        _SectionCard(
          title: 'About',
          child: Text(
            bio,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14.5,
              fontWeight: FontWeight.w500,
              height: 1.5,
              color: Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Community info',
          child: Column(
            children: [
              _InfoRow(
                icon: PhosphorIconsRegular.usersThree,
                label: 'Category',
                value: category,
              ),
              if (radiusKm > 0)
                _InfoRow(
                  icon: PhosphorIconsRegular.mapPinArea,
                  label: 'Discovery radius',
                  value: '$radiusKm km',
                ),
              if (city.trim().isNotEmpty)
                _InfoRow(
                  icon: PhosphorIconsRegular.mapPin,
                  label: 'Base location',
                  value: city,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Contact',
          child: Column(
            children: [
              if (website.trim().isNotEmpty)
                _InfoRow(
                  icon: PhosphorIconsRegular.globeHemisphereWest,
                  label: 'Website',
                  value: _stripUrlProtocol(website),
                  tappable: true,
                  onTap: () => _launchExternal(context, website),
                ),
              if (email.trim().isNotEmpty)
                _InfoRow(
                  icon: PhosphorIconsRegular.envelopeSimple,
                  label: 'Email',
                  value: email,
                  tappable: true,
                  onTap: () => _launchMail(context, email),
                ),
              if (phone.trim().isNotEmpty)
                _InfoRow(
                  icon: PhosphorIconsRegular.phone,
                  label: 'Phone',
                  value: phone,
                  tappable: true,
                  onTap: () => _launchPhone(context, phone),
                ),
              if (website.trim().isEmpty &&
                  email.trim().isEmpty &&
                  phone.trim().isEmpty)
                Text(
                  'No contact details added yet.',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.56),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Hours',
          child: _HoursBlock(
            hoursMode: hoursMode,
            hours: hours,
          ),
        ),
        if (socials.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Socials',
            child: Column(
              children: socials
                  .map(
                    (entry) => _InfoRow(
                      icon: PhosphorIconsRegular.linkSimple,
                      label: entry.platform,
                      value: entry.displayValue,
                      tappable: entry.url.trim().isNotEmpty,
                      onTap: entry.url.trim().isNotEmpty
                          ? () => _launchExternal(context, entry.url)
                          : null,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        if (isOwner && onEditCommunity != null) ...[
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: onEditCommunity,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.black.withOpacity(.08)),
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Text(
              'Edit community details',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _EventsTab extends StatelessWidget {
  const _EventsTab({
    required this.communityId,
    required this.isOwner,
    this.onCreate,
  });

  final String communityId;
  final bool isOwner;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('communities')
        .doc(communityId)
        .collection('events')
        .limit(20)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const _TabLoadingView();
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return _EmptyTabState(
            icon: PhosphorIconsRegular.calendarDots,
            title: isOwner ? 'No events yet' : 'Events coming soon',
            subtitle: isOwner
                ? 'Create the first event so this community feels alive immediately.'
                : 'This community has not published any events yet.',
            buttonLabel: isOwner ? 'Create first event' : null,
            onTap: isOwner ? onCreate : null,
          );
        }

        return ListView.separated(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final title = _readString(data, const ['title', 'name'], fallback: 'Untitled event');
            final venue = _readString(
              data,
              const ['venueName', 'locationName', 'placeName', 'location'],
              fallback: 'Location coming soon',
            );
            final when = _formatDateTime(
              data['startAt'] ?? data['scheduledStartAt'] ?? data['createdAt'],
            );

            return _SimpleContentCard(
              icon: PhosphorIconsRegular.calendarDots,
              title: title,
              subtitle: when.isEmpty ? venue : '$when\n$venue',
            );
          },
        );
      },
    );
  }
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({
    required this.communityId,
    required this.isOwner,
    this.onCreate,
  });

  final String communityId;
  final bool isOwner;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('communities')
        .doc(communityId)
        .collection('tasks')
        .limit(20)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const _TabLoadingView();
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return _EmptyTabState(
            icon: PhosphorIconsRegular.briefcase,
            title: isOwner ? 'No tasks yet' : 'Tasks coming soon',
            subtitle: isOwner
                ? 'Publish the first task, role, or volunteer opportunity.'
                : 'This community has not posted any tasks yet.',
            buttonLabel: isOwner ? 'Create first task' : null,
            onTap: isOwner ? onCreate : null,
          );
        }

        return ListView.separated(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final title = _readString(data, const ['title'], fallback: 'Untitled task');
            final type = _readString(
              data,
              const ['compensationType', 'status'],
              fallback: 'Open',
            );
            final description = _readString(
              data,
              const ['description'],
              fallback: '',
            );

            return _SimpleContentCard(
              icon: PhosphorIconsRegular.briefcase,
              title: title,
              subtitle: description.trim().isEmpty ? type : '$type\n$description',
            );
          },
        );
      },
    );
  }
}

class _PostsTab extends StatelessWidget {
  const _PostsTab({
    required this.communityId,
    required this.isOwner,
    this.onCreate,
  });

  final String communityId;
  final bool isOwner;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('communities')
        .doc(communityId)
        .collection('posts')
        .limit(20)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const _TabLoadingView();
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return _EmptyTabState(
            icon: PhosphorIconsRegular.notePencil,
            title: isOwner ? 'No posts yet' : 'Posts coming soon',
            subtitle: isOwner
                ? 'Post a short intro or first update so the page does not feel empty.'
                : 'This community has not posted anything yet.',
            buttonLabel: isOwner ? 'Create first post' : null,
            onTap: isOwner ? onCreate : null,
          );
        }

        return ListView.separated(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final content = _readString(
              data,
              const ['content', 'text', 'caption'],
              fallback: 'Community update',
            );
            final when = _formatDateTime(data['createdAt']);

            return _SimpleContentCard(
              icon: PhosphorIconsRegular.broadcast,
              title: when.isEmpty ? 'Update' : when,
              subtitle: content,
            );
          },
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.04),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.tappable = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool tappable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 17,
              color: AppColors.brandGreen,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.48),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: tappable ? FontWeight.w600 : FontWeight.w500,
                    height: 1.4,
                    color: tappable ? AppColors.brandGreen : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!tappable || onTap == null) return body;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: body,
    );
  }
}

class _HoursBlock extends StatelessWidget {
  const _HoursBlock({
    required this.hoursMode,
    required this.hours,
  });

  final String hoursMode;
  final Map<String, List<Map<String, String>>> hours;

  @override
  Widget build(BuildContext context) {
    if (hoursMode == 'always_open') {
      return Text(
        'Always open',
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: Colors.black.withOpacity(.82),
        ),
      );
    }

    if (hoursMode == 'none' || hours.isEmpty) {
      return Text(
        'No hours shown',
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.black.withOpacity(.56),
        ),
      );
    }

    final orderedDays = const [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];

    final labels = {
      'monday': 'Monday',
      'tuesday': 'Tuesday',
      'wednesday': 'Wednesday',
      'thursday': 'Thursday',
      'friday': 'Friday',
      'saturday': 'Saturday',
      'sunday': 'Sunday',
    };

    final items = orderedDays.where((day) {
      final rows = hours[day] ?? const [];
      return rows.any((row) {
        final open = (row['open'] ?? '').trim();
        final close = (row['close'] ?? '').trim();
        return open.isNotEmpty && close.isNotEmpty;
      });
    }).toList();

    if (items.isEmpty) {
      return Text(
        'No hours shown',
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.black.withOpacity(.56),
        ),
      );
    }

    return Column(
      children: items.map((day) {
        final rows = hours[day] ?? const [];
        final validRows = rows.where((row) {
          final open = (row['open'] ?? '').trim();
          final close = (row['close'] ?? '').trim();
          return open.isNotEmpty && close.isNotEmpty;
        }).toList();

        final text = validRows
            .map((row) => '${row['open']} - ${row['close']}')
            .join(', ');

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              SizedBox(
                width: 90,
                child: Text(
                  labels[day] ?? day,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.66),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _SimpleContentCard extends StatelessWidget {
  const _SimpleContentCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.04),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              icon,
              color: AppColors.brandGreen,
              size: 20,
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
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                    height: 1.2,
                  ),
                ),
                if (subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      color: Colors.black.withOpacity(.60),
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

class _EmptyTabState extends StatelessWidget {
  const _EmptyTabState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.buttonLabel,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? buttonLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 110),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.04),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen.withOpacity(.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  icon,
                  size: 28,
                  color: AppColors.brandGreen,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                  color: Colors.black.withOpacity(.58),
                ),
              ),
              if (buttonLabel != null && onTap != null) ...[
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: AppColors.brandGreen,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(
                    buttonLabel!,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TabLoadingView extends StatelessWidget {
  const _TabLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        color: AppColors.brandGreen,
      ),
    );
  }
}

class _CommunityLoadingScreen extends StatelessWidget {
  const _CommunityLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF7F8F3),
      body: Center(
        child: CircularProgressIndicator(
          color: AppColors.brandGreen,
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8F3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.56),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderInfoPill extends StatelessWidget {
  const _HeaderInfoPill({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8F3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: Colors.black54,
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommunityCover extends StatelessWidget {
  const _CommunityCover({
    required this.coverUrl,
    required this.themeColor,
  });

  final String coverUrl;
  final Color themeColor;

  @override
  Widget build(BuildContext context) {
    if (coverUrl.trim().isNotEmpty) {
      return SizedBox(
        height: 220,
        width: double.infinity,
        child: Image.network(
          coverUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }

    return _fallback();
  }

  Widget _fallback() {
    return Container(
      height: 220,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            themeColor.withOpacity(.95),
            themeColor.withOpacity(.78),
            const Color(0xFFF7D94C),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 18,
            right: 22,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: -14,
            bottom: -20,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.07),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommunityAvatar extends StatelessWidget {
  const _CommunityAvatar({
    required this.photoUrl,
    required this.themeColor,
  });

  final String photoUrl;
  final Color themeColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      height: 74,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: photoUrl.trim().isNotEmpty
            ? Image.network(
                photoUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallbackAvatar(),
              )
            : _fallbackAvatar(),
      ),
    );
  }

  Widget _fallbackAvatar() {
    return Container(
      color: themeColor.withOpacity(.12),
      child: const Center(
        child: Icon(
          PhosphorIconsRegular.usersThree,
          size: 28,
          color: AppColors.brandGreen,
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(.94),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }
}

class _ActionDotsButton extends StatelessWidget {
  const _ActionDotsButton({
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.black.withOpacity(.08),
            ),
          ),
          child: const Icon(
            Icons.more_horiz_rounded,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }
}

class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  _PinnedTabBarDelegate({
    required this.height,
    required this.child,
  });

  final double height;
  final Widget child;

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
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(covariant _PinnedTabBarDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}

class _VisibleSocial {
  const _VisibleSocial({
    required this.platform,
    required this.displayValue,
    required this.url,
  });

  final String platform;
  final String displayValue;
  final String url;
}

String formatCompactCount(int value) {
  final abs = value.abs();

  String stripZero(String s) {
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (abs < 1000) return value.toString();

  if (abs < 1000000) {
    final k = value / 1000;
    final text =
        abs >= 10000 ? k.toStringAsFixed(0) : stripZero(k.toStringAsFixed(1));
    return '${text}k';
  }

  if (abs < 1000000000) {
    final m = value / 1000000;
    final text =
        abs >= 10000000 ? m.toStringAsFixed(0) : stripZero(m.toStringAsFixed(1));
    return '${text}m';
  }

  final b = value / 1000000000;
  final text =
      abs >= 10000000000 ? b.toStringAsFixed(0) : stripZero(b.toStringAsFixed(1));
  return '${text}b';
}

String _readString(
  Map<String, dynamic> data,
  List<String> keys, {
  String fallback = '',
}) {
  for (final key in keys) {
    final value = data[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return fallback;
}

int _readInt(
  Map<String, dynamic> data,
  List<String> keys, {
  int fallback = 0,
}) {
  for (final key in keys) {
    final value = data[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return fallback;
}

Color _readThemeColor(Map<String, dynamic> data) {
  final raw = data['themeColorValue'] ?? data['themeColor'];

  if (raw is int) return Color(raw);

  if (raw is String) {
    final clean = raw.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final parsed = int.tryParse('FF$clean', radix: 16);
      if (parsed != null) return Color(parsed);
    }
    if (clean.length == 8) {
      final parsed = int.tryParse(clean, radix: 16);
      if (parsed != null) return Color(parsed);
    }
  }

  return AppColors.brandGreen;
}

Map<String, List<Map<String, String>>> _readHoursMap(Map<String, dynamic> data) {
  final raw = data['hours'] ?? data['selectedHours'];
  final result = <String, List<Map<String, String>>>{};

  if (raw is! Map) return result;

  raw.forEach((key, value) {
    if (key == null) return;

    final day = key.toString().trim().toLowerCase();
    if (value is! List) return;

    final rows = <Map<String, String>>[];

    for (final item in value) {
      if (item is! Map) continue;

      final open = (item['open'] ?? '').toString().trim();
      final close = (item['close'] ?? '').toString().trim();

      rows.add({
        'open': open,
        'close': close,
      });
    }

    result[day] = rows;
  });

  return result;
}

List<_VisibleSocial> _readVisibleSocials(Map<String, dynamic> data) {
  final raw = data['socials'];
  final items = <_VisibleSocial>[];

  if (raw is! Map) return items;

  raw.forEach((key, value) {
    if (value is! Map) return;

    final platform = (value['platform'] ?? key).toString().trim();
    final handle = (value['handle'] ?? '').toString().trim();
    final url = (value['url'] ?? '').toString().trim();
    final visible = (value['visible'] ?? true) == true;

    if (!visible) return;
    if (handle.isEmpty && url.isEmpty) return;

    final displayValue = handle.isNotEmpty
        ? (handle.startsWith('@') ? handle : '@$handle')
        : _stripUrlProtocol(url);

    items.add(
      _VisibleSocial(
        platform: platform.isEmpty ? key.toString() : platform,
        displayValue: displayValue,
        url: url,
      ),
    );
  });

  items.sort((a, b) => a.platform.compareTo(b.platform));
  return items;
}

String _stripUrlProtocol(String url) {
  return url
      .replaceFirst(RegExp(r'^https?:\/\/'), '')
      .replaceFirst(RegExp(r'^www\.'), '');
}

String _formatDateTime(dynamic raw) {
  DateTime? dt;

  if (raw is Timestamp) dt = raw.toDate();
  if (raw is DateTime) dt = raw;

  if (dt == null) return '';

  return DateFormat('EEE, d MMM • h:mm a').format(dt);
}

Future<void> _launchExternal(BuildContext context, String raw) async {
  final normalized = raw.trim().startsWith('http://') ||
          raw.trim().startsWith('https://')
      ? raw.trim()
      : 'https://${raw.trim()}';

  final uri = Uri.tryParse(normalized);
  if (uri == null) {
    _showTinySnack(context, 'Invalid link.');
    return;
  }

  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    _showTinySnack(context, 'Could not open link.');
  }
}

Future<void> _launchMail(BuildContext context, String email) async {
  final uri = Uri(
    scheme: 'mailto',
    path: email.trim(),
  );

  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    _showTinySnack(context, 'Could not open email app.');
  }
}

Future<void> _launchPhone(BuildContext context, String phone) async {
  final uri = Uri(
    scheme: 'tel',
    path: phone.trim(),
  );

  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    _showTinySnack(context, 'Could not open phone dialer.');
  }
}

void _showTinySnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
}