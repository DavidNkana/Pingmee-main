import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/features/chat/chat_display_helpers.dart';
import 'package:ping_files/features/chat/new_chat_screen.dart';
import 'package:ping_files/features/chat/pingmee_chat_routes.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter/rendering.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/features/chat/message_request_router.dart';

enum _ChatFilter {
  all,
  unread,
  verified,
  pings,
}

enum _ChatSection {
  inbox,
  requests,
}

enum _MuteDurationChoice {
  oneHour,
  eightHours,
  twentyFourHours,
  forever,
}

firestore.DocumentReference<Map<String, dynamic>>? _chatPrefsRefFor(
  Channel channel,
) {
  final uid = fb.FirebaseAuth.instance.currentUser?.uid;
  if (uid == null || uid.isEmpty) return null;

  final rawCid = (channel.cid ?? channel.id ?? '').toString().trim();
  if (rawCid.isEmpty) return null;

  final safeDocId = Uri.encodeComponent(rawCid);

  return firestore.FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('chatPrefs')
      .doc(safeDocId);
}

DateTime? _chatDateFrom(Object? value) {
  if (value is firestore.Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

DateTime? _chatLastSeenFromUserData(Map<String, dynamic>? data) {
  if (data == null) return null;

  return _chatDateFrom(
    data['lastSeen'] ??
        data['lastSeenAt'] ??
        data['lastActiveAt'] ??
        data['lastOnlineAt'] ??
        data['updatedAt'],
  );
}

bool _chatUserIsVerified(Map<String, dynamic>? data) {
  final verification = Map<String, dynamic>.from(
    data?['verification'] ?? {},
  );

  return verification['status'] == 'verified';
}

bool _chatIsReallyOnlineFromUserData(Map<String, dynamic>? data) {
  if (data == null) return false;

  final rawOnline = data['online'] == true;
  final rawIsOnline = data['isOnline'] == true;
  final presence = (data['presence'] ?? '').toString().trim().toLowerCase();

  final saysOnline = rawOnline || rawIsOnline || presence == 'online';
  if (!saysOnline) return false;

  final lastSeen = _chatLastSeenFromUserData(data);

  // If you do not have lastSeen yet, don't trust old online flags blindly.
  if (lastSeen == null) return false;

  final diff = DateTime.now().difference(lastSeen.toLocal());

  if (diff.isNegative) return true;

  // Online only if seen within the last 2 minutes.
  return diff.inMinutes < 2;
}

String _chatLastActiveShortLabel(DateTime? value) {
  if (value == null) return '';

  final local = value.toLocal();
  final diff = DateTime.now().difference(local);

  if (diff.isNegative) return 'now';
  if (diff.inSeconds < 30) return 'now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';

  return '${local.day}/${local.month}';
}

String _friendlyInboxErrorMessage(
  Object? error, {
  required String fallback,
}) {
  final raw = (error ?? '').toString().toLowerCase();

  if (raw.contains('timeout') || raw.contains('timed out')) {
    return 'This is taking longer than usual. Check your connection and try again.';
  }

  if (raw.contains('network') ||
      raw.contains('socket') ||
      raw.contains('connection') ||
      raw.contains('host lookup') ||
      raw.contains('offline') ||
      raw.contains('unavailable')) {
    return 'You seem to be offline. Check your internet and try again.';
  }

  if (raw.contains('permission') ||
      raw.contains('denied') ||
      raw.contains('unauthorized')) {
    return 'We could not load your chats right now. Please try again.';
  }

  if (raw.contains('stream') ||
      raw.contains('channel') ||
      raw.contains('querychannels') ||
      raw.contains('ws') ||
      raw.contains('websocket')) {
    return 'Chat is having trouble connecting. Try again in a moment.';
  }

  return fallback;
}

bool _requestDocBlocksInbox(Map<String, dynamic>? data) {
  if (data == null) return false;

  final status = (data['status'] ?? '').toString().trim().toLowerCase();

  // Accepted requests become normal inbox chats.
  if (status == 'accepted') return false;

  // Pending, declined, empty/broken request docs should not appear
  // in the RECEIVER'S inbox.
  return true;
}

Stream<Set<String>> _incomingRequestBlockedUserIdsStream() {
  final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

  if (myUid == null || myUid.isEmpty) {
    return Stream<Set<String>>.value(<String>{});
  }

  return firestore.FirebaseFirestore.instance
      .collection('users')
      .doc(myUid)
      .collection('message_requests_in')
      .snapshots()
      .map((snap) {
    return snap.docs
        .where((doc) => _requestDocBlocksInbox(doc.data()))
        .map((doc) {
          final data = doc.data();
          final fromUid = (data['fromUid'] ?? doc.id).toString().trim();

          return fromUid.isNotEmpty ? fromUid : doc.id;
        })
        .where((uid) => uid.trim().isNotEmpty)
        .toSet();
  });
}

Stream<int> _pendingMessageRequestCountStream() {
  final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

  if (myUid == null || myUid.isEmpty) {
    return Stream<int>.value(0);
  }

  return firestore.FirebaseFirestore.instance
      .collection('users')
      .doc(myUid)
      .collection('message_requests_in')
      .snapshots()
      .map((snap) {
    return snap.docs.where((doc) {
      final data = doc.data();
      final status = (data['status'] ?? '').toString().trim().toLowerCase();
      return status == 'pending';
    }).length;
  });
}

bool _chatPrefsArchived(Map<String, dynamic>? data) {
  return data?['archived'] == true;
}

DateTime? _chatPrefsMutedUntil(Map<String, dynamic>? data) {
  final value = data?['mutedUntil'];

  if (value is firestore.Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}

bool _chatPrefsManualUnread(Map<String, dynamic>? data) {
  return data?['manualUnread'] == true;
}

String _chatPrefsManualUnreadMessageId(Map<String, dynamic>? data) {
  return (data?['manualUnreadMessageId'] ?? '').toString().trim();
}

Future<void> _setChatManualUnread({
  required Channel channel,
  required Message? message,
}) async {
  final ref = _chatPrefsRefFor(channel);
  if (ref == null || message == null) return;

  final messageId = message.id.trim();

  await ref.set({
    'manualUnread': true,
    'manualUnreadMessageId': messageId,
    'manualUnreadAt': firestore.FieldValue.serverTimestamp(),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

Future<void> _clearChatManualUnread(Channel channel) async {
  final ref = _chatPrefsRefFor(channel);
  if (ref == null) return;

  await ref.set({
    'manualUnread': false,
    'manualUnreadMessageId': firestore.FieldValue.delete(),
    'manualUnreadAt': firestore.FieldValue.delete(),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

bool _chatPrefsMuteExpired(Map<String, dynamic>? data) {
  if (data?['muted'] != true) return false;

  final until = _chatPrefsMutedUntil(data);

  // No mutedUntil means "Until I change it".
  if (until == null) return false;

  return !until.isAfter(DateTime.now());
}

bool _chatPrefsMuted(Map<String, dynamic>? data) {
  if (data?['muted'] != true) return false;

  final until = _chatPrefsMutedUntil(data);

  // Permanent mute.
  if (until == null) return true;

  return until.isAfter(DateTime.now());
}

DateTime? _chatPrefsMutedSeenAt(Map<String, dynamic>? data) {
  final value = data?['mutedSeenMessageAt'];

  if (value is firestore.Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}

String _chatPrefsMutedSeenMessageId(Map<String, dynamic>? data) {
  return (data?['mutedSeenMessageId'] ?? '').toString().trim();
}

Message? _newerMessage(Message? a, Message? b) {
  if (a == null) return b;
  if (b == null) return a;

  final aTime = a.createdAt;
  final bTime = b.createdAt;

  return bTime.isAfter(aTime) ? b : a;
}

bool _mutedChatHasUnseenMessage({
  required bool muted,
  required Message? lastMessage,
  required String? currentUid,
  required Map<String, dynamic>? prefsData,
}) {
  if (!muted) return false;
  if (lastMessage == null) return false;

  final senderUid = lastMessage.user?.id ?? '';
  if (senderUid.isEmpty) return false;

  // Your own message should not create a green unread state.
  if (currentUid != null && currentUid.isNotEmpty && senderUid == currentUid) {
    return false;
  }

  final messageId = lastMessage.id.trim();
  final seenMessageId = _chatPrefsMutedSeenMessageId(prefsData);

  // Strongest check: if we already saw this exact message, do not show badge.
  if (messageId.isNotEmpty && seenMessageId.isNotEmpty) {
    if (messageId == seenMessageId) return false;
  }

  final messageTime = lastMessage.createdAt;

  final mutedSeenAt = _chatPrefsMutedSeenAt(prefsData);

  if (mutedSeenAt == null) return true;

  // Use milliseconds to avoid tiny timestamp precision fights.
  return messageTime.millisecondsSinceEpoch >
      mutedSeenAt.millisecondsSinceEpoch;
}

Future<void> _markMutedChatSeen({
  required Channel channel,
  required Message? fallbackLastMessage,
}) async {
  final ref = _chatPrefsRefFor(channel);

  final latestLastMessage = _newerMessage(
    fallbackLastMessage,
    channel.state?.lastMessage,
  );

  final createdAt = latestLastMessage?.createdAt;
  final messageId = (latestLastMessage?.id ?? '').trim();

  if (ref == null || createdAt == null) return;

  try {
    await channel.markRead();
  } catch (_) {
    // Do not block the local muted-seen state if Stream read-state fails.
  }

  await ref.set({
    'mutedSeenMessageId': messageId,
    'mutedSeenMessageAt': firestore.Timestamp.fromDate(DateTime.now()),
    'mutedSeenLastMessageAt': firestore.Timestamp.fromDate(createdAt),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

Future<void> _setChatMuted({
  required Channel channel,
  required DateTime? mutedUntil,
}) async {
  final ref = _chatPrefsRefFor(channel);

  try {
    await channel.mute();
  } catch (_) {
    // Keep local app state working even if Stream mute fails.
  }

  if (ref == null) return;

  await ref.set({
    'muted': true,
    'mutedAt': firestore.FieldValue.serverTimestamp(),
    'mutedUntil': mutedUntil == null
        ? firestore.FieldValue.delete()
        : firestore.Timestamp.fromDate(mutedUntil),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

Future<void> _clearChatMuted(Channel channel) async {
  final ref = _chatPrefsRefFor(channel);

  // Do NOT swallow this silently. If Stream stays muted,
  // push/message notification behavior stays muted too.
  await channel.unmute();

  if (ref == null) return;

  await ref.set({
    'muted': false,

    // Clear mute duration/state.
    'mutedUntil': firestore.FieldValue.delete(),
    'mutedAt': firestore.FieldValue.delete(),

    // Clear custom muted unread tracking too.
    'mutedSeenMessageId': firestore.FieldValue.delete(),
    'mutedSeenMessageAt': firestore.FieldValue.delete(),
    'mutedSeenLastMessageAt': firestore.FieldValue.delete(),

    'unmutedAt': firestore.FieldValue.serverTimestamp(),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

bool pingmeeMatchesPingChannelQuery({
  required Channel channel,
  required Message? lastMessage,
  required String query,
}) {
  final cleanQuery = query.trim().toLowerCase();
  if (cleanQuery.isEmpty) return true;

  final title = pingmeeChannelTitle(channel).toLowerCase();
  final subtitle = pingmeePingChannelSubtitle(channel).toLowerCase();
  final message = (lastMessage?.text ?? '').toLowerCase();

  return title.contains(cleanQuery) ||
      subtitle.contains(cleanQuery) ||
      message.contains(cleanQuery);
}

class PingmeeChatTab extends StatefulWidget {
  const PingmeeChatTab({
    super.key,
    this.onNavVisibilityChanged,
  });

  final ValueChanged<bool>? onNavVisibilityChanged;

  @override
  State<PingmeeChatTab> createState() => _PingmeeChatTabState();
}

class _PingmeeChatTabState extends State<PingmeeChatTab> {
  late Future<StreamChatClient> _connectFuture;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey<_ChannelListBodyState> _channelListKey =
      GlobalKey<_ChannelListBodyState>();

    DateTime _lastNavSignalAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _navHidden = false;

  void _setShellNavHidden(bool hidden) {
    if (_navHidden == hidden) return;

    _navHidden = hidden;
    widget.onNavVisibilityChanged?.call(hidden);
  }

  bool _handleChatScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    if (notification is! ScrollUpdateNotification) return false;

    final delta = notification.scrollDelta;
    if (delta == null) return false;

    final now = DateTime.now();
    if (now.difference(_lastNavSignalAt).inMilliseconds < 70) {
      return false;
    }

    if (delta.abs() < 3) return false;

    _lastNavSignalAt = now;

    // Content moving up / user scrolling down page => hide nav.
    if (delta > 0 && notification.metrics.pixels > 12) {
      _setShellNavHidden(true);
    }

    // Content moving down / user scrolling back toward top => show nav.
    if (delta < 0) {
      _setShellNavHidden(false);
    }

    return false;
  }

  String _query = '';
  _ChatFilter _filter = _ChatFilter.all;
  _ChatSection _section = _ChatSection.inbox;

  @override
  void initState() {
    super.initState();

    _connectFuture = PingmeeStreamChatService.instance.connectCurrentUser();

    _searchFocusNode.addListener(() {
      if (mounted) {
        setState(() {});
      }
      if (_searchFocusNode.hasFocus) {
        _setShellNavHidden(true);
      } else {
        _setShellNavHidden(false);
      }
    });
  }

  @override
  void dispose() {
    _setShellNavHidden(false);
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshVisibleChats() async {
    final listState = _channelListKey.currentState;

    if (listState != null) {
      await listState.refreshChats();
      return;
    }

    await _retry();
  }

  Future<void> _retry() async {
    setState(() {
      _connectFuture = PingmeeStreamChatService.instance.connectCurrentUser();
    });
  }

  void _openCreateChatCategorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateChatCategorySheet(),
    );
  }

  void _openNewChat() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NewChatScreen(),
      ),
    );
  }

  void _openMoreMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MoreAction(
                  icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
                  title: 'Archived chats',
                  onTap: () {
                    Navigator.of(context).pop();

                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const _ArchivedChatsScreen(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                _MoreAction(
                  icon: PhosphorIcons.gearSix(PhosphorIconsStyle.light),
                  title: 'Chat settings',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StreamChatClient>(
      future: _connectFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _ChatLoadingState();
        }

        if (snap.hasError || !snap.hasData) {
          debugPrint('❌ Chat connect failed: ${snap.error}');

          return _ChatErrorState(
            message: _friendlyInboxErrorMessage(
              snap.error,
              fallback: 'We could not load your chats. Please try again.',
            ),
            onRetry: _retry,
          );
        }

        final client = snap.data!;

        return StreamChat(
          client: client,
          child: Builder(
            builder: (context) {
              return Scaffold(
                resizeToAvoidBottomInset: false,
                backgroundColor: Colors.white,
                body: SafeArea(
                  bottom: false,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleChatScrollNotification,
                    child: RefreshIndicator(
                      color: const Color(0xFF111827),
                      backgroundColor: Colors.white,
                      displacement: 34,
                      edgeOffset: 0,
                      notificationPredicate: (notification) => notification.depth == 0,
                      onRefresh: _refreshVisibleChats,
                      child: NestedScrollView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                      headerSliverBuilder: (context, innerBoxIsScrolled) {
                        return [
                          SliverToBoxAdapter(
                            child: _InboxHeader(
                              controller: _searchController,
                              searchFocusNode: _searchFocusNode,
                              query: _query,
                              filter: _filter,
                              section: _section,
                              onNewChat: _openNewChat,
                              onQueryChanged: (value) {
                                setState(() {
                                  _query = value.trim().toLowerCase();
                                });
                              },
                              onFilterChanged: (value) {
                                setState(() {
                                  _filter = value;
                                });
                              },
                              onSectionChanged: (value) {
                                setState(() {
                                  _section = value;
                                });
                              },
                              onCreateCategory: _openCreateChatCategorySheet,
                              onMore: _openMoreMenu,
                            ),
                          ),
                        ];
                      },
                      body: _ConnectedChannelListGate(
                        channelListKey: _channelListKey,
                        client: client,
                        query: _query,
                        filter: _filter,
                        section: _section,
                        compactBottomSpacing: _searchFocusNode.hasFocus,
                        onRetry: _retry,
                        onNavVisibilityChanged: widget.onNavVisibilityChanged,
                      ),
                    ),
                  ),
                ),
                )
              );
            },
          ),
        );
      },
    );
  }
}

class _InboxHeader extends StatelessWidget {
  const _InboxHeader({
    required this.controller,
    required this.searchFocusNode,
    required this.query,
    required this.onQueryChanged,
    required this.onMore,
    required this.filter,
    required this.section,
    required this.onFilterChanged,
    required this.onSectionChanged,
    required this.onCreateCategory,
    required this.onNewChat,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onMore;
  final _ChatFilter filter;
  final ValueChanged<_ChatFilter> onFilterChanged;
  final VoidCallback onCreateCategory;
  final VoidCallback onNewChat;
  final _ChatSection section;
  final ValueChanged<_ChatSection> onSectionChanged;
  final FocusNode searchFocusNode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Chats',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                    color: Color(0xFF111827),
                  ),
                ),
              ),

              // Main action: start new chat
              Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: onNewChat,
                  customBorder: const CircleBorder(),
                  splashColor: Colors.white.withOpacity(.16),
                  highlightColor: Colors.white.withOpacity(.08),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                      color: AppColors.brandGreen,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      PhosphorIcons.plus(PhosphorIconsStyle.bold),
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Secondary action: more menu with archived unread badge
              _ArchivedUnreadBadge(onTap: onMore),
            ],
          ),

          const SizedBox(height: 10),

          Container(
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(999),
            ),
            child: TextField(
              controller: controller,
              focusNode: searchFocusNode,
              onChanged: onQueryChanged,
              textInputAction: TextInputAction.search,
              cursorColor: AppColors.brandGreen,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111827),
              ),
              decoration: InputDecoration(
                hintText: 'Search people or messages',
                hintStyle: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14.5,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.32),
                ),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 8),
                  child: Icon(
                    PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
                    size: 18,
                    color: Colors.black.withOpacity(.38),
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        splashRadius: 18,
                        onPressed: () {
                          controller.clear();
                          onQueryChanged('');
                        },
                        icon: Icon(
                          PhosphorIcons.x(PhosphorIconsStyle.bold),
                          size: 15,
                          color: Colors.black.withOpacity(.34),
                        ),
                      ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.only(
                  top: 11,
                  bottom: 11,
                  right: 14,
                ),
              ),
            ),
          ),

          const SizedBox(height: 14),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Padding(
              //   padding: const EdgeInsets.only(left: 2, bottom: 8),
              //   child: Row(
              //     children: [
              //       Text(
              //         'Active now',
              //         style: TextStyle(
              //           fontFamily: 'Nunito',
              //           fontSize: 13,
              //           fontWeight: FontWeight.w600,
              //           color: Colors.black.withOpacity(.62),
              //         ),
              //       ),
              //       const SizedBox(width: 6),
              //       Container(
              //         width: 6,
              //         height: 6,
              //         decoration: const BoxDecoration(
              //           color: AppColors.brandGreen,
              //           shape: BoxShape.circle,
              //         ),
              //       ),
              //     ],
              //   ),
              // ),
              _OnlinePeopleStrip(
                onNewChat: onNewChat,
              ),
            ],
          ),

          const SizedBox(height: 10),

          _ChatFilterTabs(
            activeFilter: filter,
            activeSection: section,
            onFilterChanged: onFilterChanged,
            onSectionChanged: onSectionChanged,
          ),
        ],
      ),
    );
  }
}

class _CurrentUserChatHeaderAvatar extends StatelessWidget {
  const _CurrentUserChatHeaderAvatar();

  String _photoFrom(Map<String, dynamic>? data) {
    final d = data ?? <String, dynamic>{};

    return (d['photoUrl'] ??
            d['photoURL'] ??
            d['profilePhotoUrl'] ??
            d['avatarUrl'] ??
            d['image'] ??
            '')
        .toString()
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final uid = fb.FirebaseAuth.instance.currentUser?.uid;

    if (uid == null || uid.isEmpty) {
      return const _FallbackChatHeaderAvatar();
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snap) {
        final photoUrl = _photoFrom(snap.data?.data());

        if (photoUrl.isEmpty) {
          return const _FallbackChatHeaderAvatar();
        }

        return CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.brandGreen.withOpacity(.10),
          backgroundImage: NetworkImage(photoUrl),
        );
      },
    );
  }
}

class _FallbackChatHeaderAvatar extends StatelessWidget {
  const _FallbackChatHeaderAvatar();

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: AppColors.brandGreen.withOpacity(.10),
      child: Icon(
        PhosphorIcons.user(PhosphorIconsStyle.light),
        size: 18,
        color: AppColors.brandGreen,
      ),
    );
  }
}

class _OnlinePeopleStrip extends StatefulWidget {
  const _OnlinePeopleStrip({
    required this.onNewChat,
  });

  final VoidCallback onNewChat;

  @override
  State<_OnlinePeopleStrip> createState() => _OnlinePeopleStripState();
}

class _OnlinePeopleStripState extends State<_OnlinePeopleStrip> {
  String? _openingUid;

  bool _isOnline(Map<String, dynamic> data) {
    return _chatIsReallyOnlineFromUserData(data);
  }

  String _nameFrom(Map<String, dynamic> data) {
    final fullName = (data['fullName'] ?? '').toString().trim();
    final displayName = (data['displayName'] ?? '').toString().trim();
    final name = (data['name'] ?? '').toString().trim();

    final firstName = (data['firstName'] ?? '').toString().trim();
    final lastName = (data['lastName'] ?? '').toString().trim();

    final combined = [firstName, lastName]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .trim();

    if (fullName.isNotEmpty) return fullName;
    if (displayName.isNotEmpty) return displayName;
    if (name.isNotEmpty) return name;
    if (combined.isNotEmpty) return combined;

    return 'User';
  }

  String _firstName(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    return parts.isEmpty ? value : parts.first;
  }

  String _photoFrom(Map<String, dynamic> data) {
    return (data['photoUrl'] ??
            data['photoURL'] ??
            data['avatarUrl'] ??
            data['image'] ??
            '')
        .toString()
        .trim();
  }

  Future<void> _openChat(BuildContext context, String uid) async {
    if (_openingUid != null) return;

    setState(() {
      _openingUid = uid;
    });

    try {
      final channel = await PingmeeMessageRequestRouter.openDirectChat(
        otherUid: uid,
      );

      if (!mounted || !context.mounted) return;

      await Navigator.of(context).push(
        pingmeeChatRoute(channel),
      );
    } catch (error) {
      if (!mounted || !context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open chat: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _openingUid = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

    return SizedBox(
      height: 88,
      child: StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
        stream: firestore.FirebaseFirestore.instance
            .collection('users')
            .limit(40)
            .snapshots(),
        builder: (context, snap) {
          final allDocs = (snap.data?.docs ?? []).where((doc) {
          if (doc.id == myUid) return false;
          return true;
        }).toList();

        final onlineDocs = allDocs.where((doc) {
          return _isOnline(doc.data());
        }).toList();

        final recentDocs = allDocs.where((doc) {
          final data = doc.data();

          if (_isOnline(data)) return false;

          final lastSeen = _chatLastSeenFromUserData(data);
          if (lastSeen == null) return false;

          final diff = DateTime.now().difference(lastSeen.toLocal());

          // Do not show ancient inactive accounts in this strip.
          return !diff.isNegative && diff.inDays < 7;
        }).toList();

        recentDocs.sort((a, b) {
          final aSeen = _chatLastSeenFromUserData(a.data());
          final bSeen = _chatLastSeenFromUserData(b.data());

          if (aSeen == null && bSeen == null) return 0;
          if (aSeen == null) return 1;
          if (bSeen == null) return -1;

          return bSeen.compareTo(aSeen);
        });

        const minPeopleToShow = 10;
        const maxPeopleToShow = 24;

        final docs = <firestore.QueryDocumentSnapshot<Map<String, dynamic>>>[
          ...onlineDocs.take(maxPeopleToShow),
        ];

        if (docs.length < minPeopleToShow) {
          final remainingSlots = maxPeopleToShow - docs.length;

          docs.addAll(
            recentDocs.take(remainingSlots),
          );
        }

          return ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: docs.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _OnlineNewChatItem(
                  onTap: _openingUid == null ? widget.onNewChat : () {},
                );
              }

              final doc = docs[index - 1];
              final data = doc.data();

              final name = _nameFrom(data);
              final photo = _photoFrom(data);
              final isOpening = _openingUid == doc.id;

              final online = _isOnline(data);
              final lastSeen = _chatLastSeenFromUserData(data);
              final lastActiveLabel = online ? '' : _chatLastActiveShortLabel(lastSeen);

              return _OnlinePersonItem(
                name: _firstName(name),
                photoUrl: photo,
                online: online,
                lastActiveLabel: lastActiveLabel,
                loading: isOpening,
                disabled: _openingUid != null,
                onTap: () => _openChat(context, doc.id),
              );
            },
          );
        },
      ),
    );
  }
}

class _OnlineNewChatItem extends StatelessWidget {
  const _OnlineNewChatItem({
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 66,
      child: Column(
        children: [
          Material(
            color: Colors.black,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 58,
                height: 58,
                child: Icon(
                  PhosphorIcons.plus(PhosphorIconsStyle.light),
                  color: Colors.white,
                  size: 27,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'New',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12.8,
              fontWeight: FontWeight.w500,
              color: Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnlinePersonItem extends StatelessWidget {
  const _OnlinePersonItem({
    required this.name,
    required this.photoUrl,
    required this.online,
    required this.lastActiveLabel,
    required this.loading,
    required this.disabled,
    required this.onTap,
  });

  final String name;
  final String photoUrl;
  final bool online;
  final bool loading;
  final bool disabled;
  final VoidCallback onTap;
  final String lastActiveLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 66,
      child: Opacity(
        opacity: disabled && !loading ? .55 : 1,
        child: Column(
          children: [
            GestureDetector(
              onTap: disabled ? null : onTap,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  CircleAvatar(
                    radius: 29,
                    backgroundColor: AppColors.brandGreen.withOpacity(.10),
                    backgroundImage:
                        photoUrl.isEmpty ? null : NetworkImage(photoUrl),
                    child: photoUrl.isEmpty
                        ? Icon(
                            PhosphorIcons.user(PhosphorIconsStyle.light),
                            color: AppColors.brandGreen,
                            size: 24,
                          )
                        : null,
                  ),

                  if (loading)
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.72),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 19,
                          height: 19,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor: AlwaysStoppedAnimation(
                              AppColors.brandGreen,
                            ),
                          ),
                        ),
                      ),
                    ),

                  if (online && !loading)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: AppColors.brandGreen,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: 2.2,
                          ),
                        ),
                      ),
                    ),

                  if (!online && !loading && lastActiveLabel.trim().isNotEmpty)
                    Positioned(
                      right: -5,
                      bottom: -2,
                      child: Container(
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 17,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          lastActiveLabel,
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: Colors.black.withOpacity(.54),
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12.8,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.76),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatFilterTabs extends StatelessWidget {
  const _ChatFilterTabs({
    required this.activeFilter,
    required this.activeSection,
    required this.onFilterChanged,
    required this.onSectionChanged,
  });

  final _ChatFilter activeFilter;
  final _ChatSection activeSection;
  final ValueChanged<_ChatFilter> onFilterChanged;
  final ValueChanged<_ChatSection> onSectionChanged;

  String get _filterLabel {
    switch (activeFilter) {
      case _ChatFilter.all:
        return 'All';
      case _ChatFilter.unread:
        return 'Unread';
      case _ChatFilter.verified:
        return 'Verified';
      case _ChatFilter.pings:
        return 'Pings';
    }
  }

  IconData get _filterIcon {
    switch (activeFilter) {
      case _ChatFilter.all:
        return PhosphorIcons.chatsCircle(PhosphorIconsStyle.light);
      case _ChatFilter.unread:
        return PhosphorIcons.envelopeSimpleOpen(PhosphorIconsStyle.light);
      case _ChatFilter.verified:
        return PhosphorIcons.sealCheck(PhosphorIconsStyle.fill);
      case _ChatFilter.pings:
        return PhosphorIcons.mapPinArea(PhosphorIconsStyle.fill);
    }
  }

  Color get _filterColor {
    switch (activeFilter) {
      case _ChatFilter.all:
        return const Color(0xFF3B82F6);
      case _ChatFilter.unread:
        return const Color(0xFFF97316);
      case _ChatFilter.verified:
        return const Color(0xFF1D9BF0);
      case _ChatFilter.pings:
        return const Color(0xFF111827);
    }
  }

  void _openFilterMenu(BuildContext context) async {
    final selected = await showModalBottomSheet<_ChatFilter>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 14),

                _ChatFilterMenuItem(
                  label: 'All chats',
                  subtitle: 'Show every active conversation',
                  icon: PhosphorIcons.chatsCircle(PhosphorIconsStyle.light),
                  iconColor: const Color(0xFF3B82F6),
                  active: activeFilter == _ChatFilter.all,
                  onTap: () => Navigator.of(context).pop(_ChatFilter.all),
                ),

                const SizedBox(height: 8),

                _ChatFilterMenuItem(
                  label: 'Unread',
                  subtitle: 'Only chats waiting for you',
                  icon: PhosphorIcons.envelopeSimpleOpen(
                    PhosphorIconsStyle.light,
                  ),
                  iconColor: const Color(0xFFF97316),
                  active: activeFilter == _ChatFilter.unread,
                  onTap: () => Navigator.of(context).pop(_ChatFilter.unread),
                ),

                const SizedBox(height: 8),

                _ChatFilterMenuItem(
                  label: 'Verified',
                  subtitle: 'Chats with verified people',
                  icon: PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                  iconColor: const Color(0xFF1D9BF0),
                  active: activeFilter == _ChatFilter.verified,
                  onTap: () => Navigator.of(context).pop(_ChatFilter.verified),
                ),

                const SizedBox(height: 8),

                _ChatFilterMenuItem(
                  label: 'Pings',
                  subtitle: 'Only group chats from joined pings',
                  icon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                  iconColor: const Color(0xFF111827),
                  active: activeFilter == _ChatFilter.pings,
                  onTap: () => Navigator.of(context).pop(_ChatFilter.pings),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null) {
      onFilterChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filterIsDefault = activeFilter == _ChatFilter.all;

    return SizedBox(
      height: 42,
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () => _openFilterMenu(context),
              borderRadius: BorderRadius.circular(999),
              splashColor: Colors.black.withOpacity(.035),
              highlightColor: Colors.black.withOpacity(.02),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 42,
                padding: const EdgeInsets.only(left: 6, right: 11),
                decoration: BoxDecoration(
                  color: filterIsDefault
                      ? const Color(0xFFF4F6FA)
                      : _filterColor.withOpacity(.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.92),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _filterIcon,
                        size: 16,
                        color: filterIsDefault
                            ? Colors.black.withOpacity(.58)
                            : _filterColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _filterLabel,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: filterIsDefault
                            ? Colors.black.withOpacity(.62)
                            : const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
                      size: 12,
                      color: Colors.black.withOpacity(.34),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(width: 8),

          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6FA),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  _ChatSectionChip(
                    label: 'Inbox',
                    active: activeSection == _ChatSection.inbox,
                    onTap: () => onSectionChanged(_ChatSection.inbox),
                  ),
                  StreamBuilder<int>(
                    stream: _pendingMessageRequestCountStream(),
                    initialData: 0,
                    builder: (context, snap) {
                      final count = snap.data ?? 0;

                      return _ChatSectionChip(
                        label: 'Requests',
                        badgeCount: count,
                        active: activeSection == _ChatSection.requests,
                        onTap: () => onSectionChanged(_ChatSection.requests),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatSectionChip extends StatelessWidget {
  const _ChatSectionChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.badgeCount = 0,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final showBadge = badgeCount > 0;
    final badgeText = badgeCount > 99 ? '99+' : badgeCount.toString();

    return Expanded(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          splashColor: Colors.black.withOpacity(.035),
          highlightColor: Colors.black.withOpacity(.02),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            height: double.infinity,
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              boxShadow: active
                  ? [
                      BoxShadow(
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                        color: Colors.black.withOpacity(.055),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? const Color(0xFF111827)
                          : Colors.black.withOpacity(.42),
                    ),
                  ),
                ),

                if (showBadge) ...[
                  const SizedBox(width: 6),
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 19,
                      minHeight: 19,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      badgeText,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatFilterMenuItem extends StatelessWidget {
  const _ChatFilterMenuItem({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? const Color(0xFFEFF2F7) : const Color(0xFFF5F7FA),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.90),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: Colors.black.withOpacity(.64),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.46),
                      ),
                    ),
                  ],
                ),
              ),
              if (active)
                Icon(
                  PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
                  size: 20,
                  color: Colors.black.withOpacity(.64),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatFilterCreateChip extends StatelessWidget {
  const _ChatFilterCreateChip({
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const iconColor = AppColors.brandGreen;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(
            left: 7,
            right: 14,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F6FA),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.black.withOpacity(.035),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  PhosphorIcons.plus(PhosphorIconsStyle.bold),
                  size: 14,
                  color: Colors.black.withOpacity(.64),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'New list',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(.58),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatFilterChip extends StatelessWidget {
  const _ChatFilterChip({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = active
        ? iconColor.withOpacity(.11)
        : const Color(0xFFF4F6FA);

    final borderColor = active
        ? iconColor.withOpacity(.30)
        : Colors.black.withOpacity(.035);

    final textColor = active
        ? const Color(0xFF111827)
        : Colors.black.withOpacity(.58);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 40,
          padding: const EdgeInsets.only(
            left: 7,
            right: 14,
          ),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.88),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 16,
                  color: Colors.black.withOpacity(.64),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateChatCategorySheet extends StatefulWidget {
  const _CreateChatCategorySheet();

  @override
  State<_CreateChatCategorySheet> createState() =>
      _CreateChatCategorySheetState();
}

class _CreateChatCategorySheetState extends State<_CreateChatCategorySheet> {
  final TextEditingController _nameController = TextEditingController();

  String _category = 'Friends';

  final List<String> _categories = const [
    'Friends',
    'Community',
    'Event',
    'Ping',
    'Work',
    'School',
    'Gaming',
    'Custom',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _create() {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Name the channel first.'),
        ),
      );
      return;
    }

    // Later:
    // Save this to Firestore under users/{uid}/chatCategories
    // or create a Stream community channel from a Cloud Function.
    Navigator.of(context).pop();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Created "$name" under $_category.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              blurRadius: 30,
              offset: const Offset(0, 18),
              color: Colors.black.withOpacity(.14),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 18),

              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen.withOpacity(.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      PhosphorIcons.hash(PhosphorIconsStyle.light),
                      color: AppColors.brandGreen,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Create chat category',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              TextField(
                controller: _nameController,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: 'Name it, e.g. Design crew',
                  filled: true,
                  fillColor: const Color(0xFFF3F6FB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              ),

              const SizedBox(height: 14),

              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Category',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.58),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories.map((item) {
                  final active = item == _category;

                  return Material(
                    color: active
                        ? AppColors.brandGreen
                        : const Color(0xFFF3F6FB),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _category = item;
                        });
                      },
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 9,
                        ),
                        child: Text(
                          item,
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: active
                                ? Colors.white
                                : Colors.black.withOpacity(.58),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 18),

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _create,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(19),
                    ),
                  ),
                  child: const Text(
                    'Create',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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

class _ConnectedChannelListGate extends StatefulWidget {
  const _ConnectedChannelListGate({
    required this.channelListKey,
    required this.client,
    required this.query,
    required this.filter,
    required this.compactBottomSpacing,
    required this.section,
    required this.onRetry,
    required this.onNavVisibilityChanged,
  });

  final StreamChatClient client;
  final String query;
  final _ChatFilter filter;
  final bool compactBottomSpacing;
  final Future<void> Function() onRetry;
  final ValueChanged<bool>? onNavVisibilityChanged;
  final _ChatSection section;
  final GlobalKey<_ChannelListBodyState> channelListKey;

  @override
  State<_ConnectedChannelListGate> createState() =>
      _ConnectedChannelListGateState();
}

class _ConnectedChannelListGateState extends State<_ConnectedChannelListGate> {
  bool _openingConnection = false;
  Object? _lastError;

  bool _isConnected(ConnectionStatus status) {
    return status == ConnectionStatus.connected;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureConnection();
    });
  }

  @override
  void didUpdateWidget(covariant _ConnectedChannelListGate oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.client != widget.client) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureConnection();
      });
    }
  }

  Future<void> _ensureConnection() async {
    if (_openingConnection) return;
    if (_isConnected(widget.client.wsConnectionStatus)) return;

    setState(() {
      _openingConnection = true;
      _lastError = null;
    });

    try {
      await widget.client.openConnection();
    } catch (error) {
      _lastError = error;
    } finally {
      if (mounted) {
        setState(() => _openingConnection = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionStatus>(
      stream: widget.client.wsConnectionStatusStream,
      initialData: widget.client.wsConnectionStatus,
      builder: (context, snap) {
        final status = snap.data ?? widget.client.wsConnectionStatus;

        if (_isConnected(status)) {
          return _ChannelListBody(
            key: widget.channelListKey,
            query: widget.query,
            filter: widget.filter,
            section: widget.section,
            compactBottomSpacing: widget.compactBottomSpacing,
            onNavVisibilityChanged: widget.onNavVisibilityChanged,
          );
        }

        if (_openingConnection) {
          return const _ChatContentListLoadingOnly();
        }

        if (_lastError != null) {
          debugPrint('❌ Chat reconnect failed: $_lastError');
        }

        return _ChatReconnectState(
          message: _friendlyInboxErrorMessage(
            _lastError,
            fallback: 'Chat is having trouble reconnecting. Check your internet and try again.',
          ),
          onRetry: () async {
            await _ensureConnection();

            if (_isConnected(widget.client.wsConnectionStatus)) return;

            await widget.onRetry();
          },
        );
      },
    );
  }
}

class _ChatContentListLoadingOnly extends StatefulWidget {
  const _ChatContentListLoadingOnly();

  @override
  State<_ChatContentListLoadingOnly> createState() =>
      _ChatContentListLoadingOnlyState();
}

class _ChatContentListLoadingOnlyState
    extends State<_ChatContentListLoadingOnly>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _fade = Tween<double>(
    begin: .38,
    end: .82,
  ).animate(
    CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _bone({
    required double height,
    double? width,
    double radius = 999,
  }) {
    return FadeTransition(
      opacity: _fade,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }

  Widget _loadingRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.54),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withOpacity(.45),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            _bone(height: 48, width: 48, radius: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bone(height: 13, width: 130),
                  const SizedBox(height: 9),
                  _bone(height: 11, width: double.infinity),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _bone(height: 20, width: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _loadingRow(),
        _loadingRow(),
        _loadingRow(),
        _loadingRow(),
        _loadingRow(),
        _loadingRow(),
      ],
    );
  }
}

class _ChannelListBody extends StatefulWidget {
  const _ChannelListBody({
    super.key,
    required this.query,
    required this.filter,
    required this.section,
    required this.compactBottomSpacing,
    required this.onNavVisibilityChanged,
  });

  final String query;
  final _ChatFilter filter;
  final bool compactBottomSpacing;
  final ValueChanged<bool>? onNavVisibilityChanged;
  final _ChatSection section;

  @override
  State<_ChannelListBody> createState() => _ChannelListBodyState();
}

class _ChannelListBodyState extends State<_ChannelListBody> {
  StreamChannelListController? _controller;
  bool _navHidden = false;
  double _lastScrollOffset = 0;
  DateTime _lastNavSignalAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, DateTime> _localMutedSeenAtByCid = {};
  final Map<String, String> _localMutedSeenMessageIdByCid = {};
  final Map<String, bool> _localMuteOverrideByCid = {};

  void _clearMutedLocalState(Channel channel) {
    final key = _channelSeenKey(channel);
    if (key.isEmpty) return;

    _localMutedSeenAtByCid.remove(key);
    _localMutedSeenMessageIdByCid.remove(key);
  }

  String _channelSeenKey(Channel channel) {
    return (channel.cid ?? channel.id ?? '').toString().trim();
  }

  bool? _localMuteOverrideFor(Channel channel) {
    final key = _channelSeenKey(channel);
    if (key.isEmpty) return null;

    return _localMuteOverrideByCid[key];
  }

  Future<void> refreshChats() async {
    final controller = _controller;

    if (controller == null) return;

    await controller.refresh();
  }

  void _setLocalMuteOverride({
    required Channel channel,
    required bool muted,
  }) {
    final key = _channelSeenKey(channel);
    if (key.isEmpty) return;

    _localMuteOverrideByCid[key] = muted;

    if (!muted) {
      _localMutedSeenAtByCid.remove(key);
      _localMutedSeenMessageIdByCid.remove(key);
    }
  }

  void _rememberMutedChatSeenLocally({
    required Channel channel,
    required Message? lastMessage,
  }) {
    final key = _channelSeenKey(channel);
    if (key.isEmpty) return;

    _localMutedSeenAtByCid[key] = DateTime.now();

    final messageId = (lastMessage?.id ?? '').trim();
    if (messageId.isNotEmpty) {
      _localMutedSeenMessageIdByCid[key] = messageId;
    }
  }

  bool _mutedUnseenWithLocalOverride({
    required Channel channel,
    required bool muted,
    required Message? lastMessage,
    required String? currentUid,
    required Map<String, dynamic>? prefsData,
  }) {
    if (!muted) return false;
    if (lastMessage == null) return false;

    final key = _channelSeenKey(channel);

    final localSeenMessageId = _localMutedSeenMessageIdByCid[key];
    final lastMessageId = (lastMessage.id).trim();

    if (localSeenMessageId != null &&
        localSeenMessageId.isNotEmpty &&
        lastMessageId.isNotEmpty &&
        localSeenMessageId == lastMessageId) {
      return false;
    }

    final localSeenAt = _localMutedSeenAtByCid[key];
    final messageTime = lastMessage.createdAt;

    if (localSeenAt != null) {
      if (!messageTime.isAfter(localSeenAt)) {
        return false;
      }
    }

    return _mutedChatHasUnseenMessage(
      muted: muted,
      lastMessage: lastMessage,
      currentUid: currentUid,
      prefsData: prefsData,
    );
  }

  void _setNavHidden(bool hidden) {
    if (_navHidden == hidden) return;

    _navHidden = hidden;
    widget.onNavVisibilityChanged?.call(hidden);
  }

  bool _handleChatScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    final now = DateTime.now();

    // Throttle so we don't spam setState in the shell.
    if (now.difference(_lastNavSignalAt).inMilliseconds < 80) {
      return false;
    }

    final current = notification.metrics.pixels;
    final delta = current - _lastScrollOffset;
    _lastScrollOffset = current;

    if (delta.abs() < 4) return false;

    _lastNavSignalAt = now;

    // Scrolling down the page / content moves up => hide nav.
    if (delta > 0 && current > 20) {
      _setNavHidden(true);
    }

    // Scrolling back up / content moves down => show nav.
    if (delta < 0) {
      _setNavHidden(false);
    }

    return false;
  }

  bool _matchesFilter({
    required Channel channel,
    required PingmeeChatPerson person,
    required Set<String> verifiedUserIds,
  }) {
    switch (widget.filter) {
      case _ChatFilter.all:
        return true;

      case _ChatFilter.unread:
        return (channel.state?.unreadCount ?? 0) > 0;

      case _ChatFilter.verified:
        return verifiedUserIds.contains(person.id);

      case _ChatFilter.pings:
        return pingmeeIsPingChannel(channel);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_controller != null) return;

    final stream = StreamChat.of(context);
    final currentUser = stream.currentUser;

    if (currentUser == null) return;

    _controller = StreamChannelListController(
      client: stream.client,
      filter: Filter.and([
        Filter.equal('type', 'messaging'),
        Filter.in_(
          'members',
          [currentUser.id],
        ),
      ]),
      channelStateSort: const [
        SortOption('last_message_at'),
      ],
    );
  }

  @override
  void dispose() {
    widget.onNavVisibilityChanged?.call(false);
    _controller?.dispose();
    super.dispose();
  }

  bool _matchesQuery({
    required PingmeeChatPerson person,
    required Message? lastMessage,
  }) {
    final query = widget.query.trim().toLowerCase();
    if (query.isEmpty) return true;

    final name = person.name.toLowerCase();
    final message = (lastMessage?.text ?? '').toLowerCase();

    return name.contains(query) || message.contains(query);
  }

  Widget _buildVerifiedAwareList({
    required StreamChannelListController controller,
  }) {
    if (widget.filter != _ChatFilter.verified) {
      return _buildChannelList(
        controller: controller,
        verifiedUserIds: const <String>{},
      );
    }

    return StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .where('verification.status', isEqualTo: 'verified')
          .snapshots(),
      builder: (context, snap) {
        final verifiedUserIds = (snap.data?.docs ?? [])
            .map((doc) => doc.id)
            .where((id) => id.trim().isNotEmpty)
            .toSet();

        return _buildChannelList(
          controller: controller,
          verifiedUserIds: verifiedUserIds,
        );
      },
    );
  }

  Widget _buildChannelList({
    required StreamChannelListController controller,
    required Set<String> verifiedUserIds,
  }) {
    final bottomPadding = widget.compactBottomSpacing ? 0.0 : 12.0;

    return StreamBuilder<Set<String>>(
      stream: _incomingRequestBlockedUserIdsStream(),

      // Important: no initialData false.
      // We wait for the request gate before showing the inbox,
      // so pending requests do not flash in the inbox.
      builder: (context, requestGateSnap) {
        if (!requestGateSnap.hasData) {
          return const _ChatContentListLoadingOnly();
        }

        final blockedIncomingRequestUserIds =
            requestGateSnap.data ?? <String>{};

        return Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleChatScroll,
            child: StreamChannelListView(
              controller: controller,
              separatorBuilder: (context, channels, index) {
                return const SizedBox.shrink();
              },
              emptyBuilder: (_) => const _EmptyInboxState(),
              errorBuilder: (context, error) {
                debugPrint('❌ Chat list failed: $error');

                return _ChatErrorState(
                  message: _friendlyInboxErrorMessage(
                    error,
                    fallback: 'We could not load your conversations. Pull down or tap retry.',
                  ),
                  onRetry: controller.refresh,
                );
              },
              itemBuilder: (context, channels, index, defaultTile) {
                final hasVisibleConversation = channels.any((item) {
                  final isPingChannel = pingmeeIsPingChannel(item);
                  final lastMessage = item.state?.lastMessage;

                  if (isPingChannel) {
                    // Ping channels should show even before the first message.
                    if (widget.filter == _ChatFilter.verified) {
                      return false;
                    }

                    if (widget.filter == _ChatFilter.unread) {
                      final unread = item.state?.unreadCount ?? 0;
                      if (unread <= 0) return false;
                    }

                    // Pings filter accepts only ping channels.
                    // All filter also accepts ping channels.
                    if (widget.filter != _ChatFilter.all &&
                        widget.filter != _ChatFilter.unread &&
                        widget.filter != _ChatFilter.pings) {
                      return false;
                    }

                    return pingmeeMatchesPingChannelQuery(
                      channel: item,
                      lastMessage: lastMessage,
                      query: widget.query,
                    );
                  }

                  if (lastMessage == null) return false;

                  if (widget.filter == _ChatFilter.pings) {
                    return false;
                  }

                  final person = pingmeeOtherDmPerson(
                    context: context,
                    channel: item,
                  );

                  final otherUid = person.id.trim();

                  if (blockedIncomingRequestUserIds.contains(otherUid)) {
                    return false;
                  }

                  if (!_matchesFilter(
                    channel: item,
                    person: person,
                    verifiedUserIds: verifiedUserIds,
                  )) {
                    return false;
                  }

                  return _matchesQuery(
                    person: person,
                    lastMessage: lastMessage,
                  );
                });

                if (!hasVisibleConversation) {
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.fromLTRB(28, 54, 28, 140),
                      child: _EmptyInboxCard(),
                    );
                  }

                  return const SizedBox.shrink();
                }

                final channel = channels[index];

                final isPingChannel = pingmeeIsPingChannel(channel);

                if (widget.filter == _ChatFilter.pings && !isPingChannel) {
                  return const SizedBox.shrink();
                }

                if (widget.filter == _ChatFilter.verified && isPingChannel) {
                  return const SizedBox.shrink();
                }

                if (widget.filter == _ChatFilter.unread) {
                  final unread = channel.state?.unreadCount ?? 0;
                  if (unread <= 0) return const SizedBox.shrink();
                }

                if (isPingChannel) {
                  return StreamBuilder<Message?>(
                    stream: channel.state?.lastMessageStream,
                    initialData: channel.state?.lastMessage,
                    builder: (context, messageSnap) {
                      final lastMessageObject = messageSnap.data;
                      final prefsRef = _chatPrefsRefFor(channel);

                      Widget buildTile({
                        required bool muted,
                        required bool manualUnread,
                      }) {
                        return _PingChannelInboxTile(
                          channel: channel,
                          lastMessageObject: lastMessageObject,
                          muted: muted,
                          manualUnread: manualUnread,
                          archivedMode: false,
                          onRefresh: controller.refresh,
                          onTap: () async {
                            await Navigator.of(context).push(
                              pingmeeChatRoute(channel),
                            );

                            if (!mounted) return;

                            await _clearChatManualUnread(channel);
                            await controller.refresh();
                          },
                        );
                      }

                      if (prefsRef == null) {
                        return buildTile(
                          muted: false,
                          manualUnread: false,
                        );
                      }

                      return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
                        stream: prefsRef.snapshots(),
                        builder: (context, prefsSnap) {
                          final prefsData = prefsSnap.data?.data();
                          final archived = _chatPrefsArchived(prefsData);

                          // Normal inbox should HIDE archived chats.
                          if (archived) {
                            return const SizedBox.shrink();
                          }

                          if (_chatPrefsMuteExpired(prefsData)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              unawaited(_clearChatMuted(channel));
                            });
                          }

                          return buildTile(
                            muted: _chatPrefsMuted(prefsData),
                            manualUnread: _chatPrefsManualUnread(prefsData),
                          );
                        },
                      );
                    },
                  );
                }

                final person = pingmeeOtherDmPerson(
                  context: context,
                  channel: channel,
                );

                final otherUid = person.id.trim();

                // Receiver side only:
                // Hide pending/declined incoming requests from Inbox.
                // Sender side still sees their outgoing request chat.
                if (blockedIncomingRequestUserIds.contains(otherUid)) {
                  return const SizedBox.shrink();
                }

                if (!_matchesFilter(
                  channel: channel,
                  person: person,
                  verifiedUserIds: verifiedUserIds,
                )) {
                  return const SizedBox.shrink();
                }

                if (person.id.isNotEmpty) {
                  PingmeeStreamChatService.instance.cacheDirectChannel(
                    otherUid: person.id,
                    channel: channel,
                  );
                }

                return StreamBuilder<Message?>(
                  stream: channel.state?.lastMessageStream,
                  initialData: channel.state?.lastMessage,
                  builder: (context, messageSnap) {
                    final lastMessageObject = messageSnap.data;

                    if (lastMessageObject == null) {
                      return const SizedBox.shrink();
                    }

                    if (!_matchesQuery(
                      person: person,
                      lastMessage: lastMessageObject,
                    )) {
                      return const SizedBox.shrink();
                    }

                    final prefsRef = _chatPrefsRefFor(channel);

                    if (prefsRef == null) {
                      return _ChatInboxTile(
                        channel: channel,
                        person: person,
                        lastMessageObject: lastMessageObject,
                        muted: false,
                        mutedUnseen: false,
                        manualUnread: false,
                        onClearMutedLocalState: () {},
                        onRefresh: controller.refresh,
                        onTap: () async {
                          await Navigator.of(context).push(
                            pingmeeChatRoute(channel),
                          );

                          await controller.refresh();
                        },
                      );
                    }

                    return StreamBuilder<
                        firestore.DocumentSnapshot<Map<String, dynamic>>>(
                      stream: prefsRef.snapshots(),
                      builder: (context, prefsSnap) {
                        final prefsData = prefsSnap.data?.data();
                        final archived = _chatPrefsArchived(prefsData);
                        final manualUnread = _chatPrefsManualUnread(prefsData);

                        if (_chatPrefsMuteExpired(prefsData)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            unawaited(_clearChatMuted(channel));
                          });
                        }

                        final serverMuted = _chatPrefsMuted(prefsData);
                        final localMuteOverride = _localMuteOverrideFor(channel);
                        final muted = localMuteOverride ?? serverMuted;

                        final currentUid =
                            StreamChat.of(context).currentUser?.id ??
                                fb.FirebaseAuth.instance.currentUser?.uid;

                        final mutedUnseen = _mutedUnseenWithLocalOverride(
                          channel: channel,
                          muted: muted,
                          lastMessage: lastMessageObject,
                          currentUid: currentUid,
                          prefsData: prefsData,
                        );

                        if (archived) {
                          return const SizedBox.shrink();
                        }

                        return _ChatInboxTile(
                          channel: channel,
                          person: person,
                          lastMessageObject: lastMessageObject,
                          muted: muted,
                          mutedUnseen: mutedUnseen,
                          manualUnread: manualUnread,
                          onClearMutedLocalState: () {
                            setState(() {
                              _setLocalMuteOverride(
                                channel: channel,
                                muted: false,
                              );
                            });
                          },
                          onSetMutedLocalState: () {
                            setState(() {
                              _setLocalMuteOverride(
                                channel: channel,
                                muted: true,
                              );
                            });
                          },
                          onRefresh: controller.refresh,
                          onTap: () async {
                            final navigator = Navigator.of(context);

                            if (muted) {
                              final latestBeforeOpen = _newerMessage(
                                lastMessageObject,
                                channel.state?.lastMessage,
                              );

                              setState(() {
                                _rememberMutedChatSeenLocally(
                                  channel: channel,
                                  lastMessage: latestBeforeOpen,
                                );
                              });

                              unawaited(
                                _markMutedChatSeen(
                                  channel: channel,
                                  fallbackLastMessage: latestBeforeOpen,
                                ).catchError((_) {}),
                              );
                            }

                            await navigator.push(
                              pingmeeChatRoute(channel),
                            );

                            if (!mounted) return;

                            await _clearChatManualUnread(channel);

                            if (muted) {
                              final latestAfterClose = _newerMessage(
                                lastMessageObject,
                                channel.state?.lastMessage,
                              );

                              setState(() {
                                _rememberMutedChatSeenLocally(
                                  channel: channel,
                                  lastMessage: latestAfterClose,
                                );
                              });

                              unawaited(
                                _markMutedChatSeen(
                                  channel: channel,
                                  fallbackLastMessage: latestAfterClose,
                                ).catchError((_) {}),
                              );
                            }

                            await controller.refresh();
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller == null) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
        ),
      );
    }

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomPadding = keyboardOpen ? 12.0 : 104.0;

    if (widget.section == _ChatSection.requests) {
      return const _ChatRequestsState();
    }

    return _buildVerifiedAwareList(
      controller: controller,
    );
  }
}

class _PingChannelInboxTile extends StatelessWidget {
  const _PingChannelInboxTile({
    required this.channel,
    required this.lastMessageObject,
    required this.onTap,
    required this.onRefresh,
    this.archivedMode = false,
    this.muted = false,
    this.manualUnread = false,
  });

  final Channel channel;
  final Message? lastMessageObject;
  final VoidCallback onTap;
  final Future<void> Function() onRefresh;
  final bool archivedMode;
  final bool muted;
  final bool manualUnread;

  String _lastMessageText() {
    final message = lastMessageObject;

    if (message == null) {
      return 'No messages yet';
    }

    final text = (message.text ?? '').trim();
    final senderName = (message.user?.name ?? '').trim();

    if (text.isNotEmpty) {
      if (senderName.isNotEmpty) return '$senderName: $text';
      return text;
    }

    if (message.attachments.isNotEmpty) {
      if (senderName.isNotEmpty) return '$senderName: Sent an attachment';
      return 'Sent an attachment';
    }

    return 'New activity';
  }

  Future<void> _archiveChat(BuildContext context) async {
    final ref = _chatPrefsRefFor(channel);

    if (ref == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not archive this chat.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await ref.set({
        'archived': true,
        'archivedAt': firestore.FieldValue.serverTimestamp(),
        'updatedAt': firestore.FieldValue.serverTimestamp(),
      }, firestore.SetOptions(merge: true));

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat archived.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not archive chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _unarchiveChat(BuildContext context) async {
    final ref = _chatPrefsRefFor(channel);

    if (ref == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unarchive this chat.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await ref.set({
        'archived': false,
        'unarchivedAt': firestore.FieldValue.serverTimestamp(),
        'updatedAt': firestore.FieldValue.serverTimestamp(),
      }, firestore.SetOptions(merge: true));

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat moved back to inbox.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not unarchive chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<_MuteDurationChoice?> _showMuteDurationSheet(BuildContext context) {
    return showModalBottomSheet<_MuteDurationChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        void pick(_MuteDurationChoice choice) {
          Navigator.of(sheetContext).pop(choice);
        }

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),

                const SizedBox(height: 16),

                const Text(
                  'Mute notifications',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  'Choose how long you want this chat muted.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.55),
                    height: 1.3,
                  ),
                ),

                const SizedBox(height: 16),

                _MuteDurationRow(
                  icon: PhosphorIcons.clock(PhosphorIconsStyle.light),
                  title: 'For 1 hour',
                  onTap: () => pick(_MuteDurationChoice.oneHour),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.clockCountdown(
                    PhosphorIconsStyle.light,
                  ),
                  title: 'For 8 hours',
                  onTap: () => pick(_MuteDurationChoice.eightHours),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.calendarBlank(
                    PhosphorIconsStyle.light,
                  ),
                  title: 'For 24 hours',
                  onTap: () => pick(_MuteDurationChoice.twentyFourHours),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.bellSlash(
                    PhosphorIconsStyle.light,
                  ),
                  title: 'Until I change it',
                  onTap: () => pick(_MuteDurationChoice.forever),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _muteChat(BuildContext context) async {
    final choice = await _showMuteDurationSheet(context);
    if (choice == null) return;

    final now = DateTime.now();
    DateTime? mutedUntil;

    switch (choice) {
      case _MuteDurationChoice.oneHour:
        mutedUntil = now.add(const Duration(hours: 1));
        break;
      case _MuteDurationChoice.eightHours:
        mutedUntil = now.add(const Duration(hours: 8));
        break;
      case _MuteDurationChoice.twentyFourHours:
        mutedUntil = now.add(const Duration(hours: 24));
        break;
      case _MuteDurationChoice.forever:
        mutedUntil = null;
        break;
    }

    try {
      await _setChatMuted(
        channel: channel,
        mutedUntil: mutedUntil,
      );

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mutedUntil == null
                ? 'Chat muted until you change it.'
                : 'Chat muted.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not mute chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _unmuteChat(BuildContext context) async {
    try {
      await _clearChatMuted(channel);
      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat unmuted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not unmute chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteChat(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            'Delete chat?',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w600,
            ),
          ),
          content: const Text(
            'This removes the chat from your inbox. It will not delete it for the other people in this ping.',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w400,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Color(0xFFE53935)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await channel.hide(clearHistory: true);
      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat deleted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not delete chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showMore(BuildContext context) {
    final streamUnreadCount = channel.state?.unreadCount ?? 0;
    final isUnread = streamUnreadCount > 0 || manualUnread;

    Future<void> markAsRead() async {
      try {
        await channel.markRead();
      } catch (_) {}

      await _clearChatManualUnread(channel);
      await onRefresh();
    }

    Future<void> markAsUnread() async {
      final message = lastMessageObject;
      final messageId = (message?.id ?? '').trim();

      if (message == null || messageId.isEmpty) return;

      try {
        await channel.markUnread(messageId);
      } catch (_) {
        // Firestore fallback still makes the UI behave correctly.
      }

      await _setChatManualUnread(
        channel: channel,
        message: message,
      );

      await onRefresh();
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MoreAction(
                  icon: isUnread
                      ? PhosphorIcons.checkCircle(PhosphorIconsStyle.light)
                      : PhosphorIcons.envelopeSimple(
                          PhosphorIconsStyle.light,
                        ),
                  title: isUnread ? 'Mark as read' : 'Mark as unread',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();

                    if (isUnread) {
                      await markAsRead();
                    } else {
                      await markAsUnread();
                    }
                  },
                ),

                const SizedBox(height: 8),

                _MoreAction(
                  icon: PhosphorIcons.mapPinArea(PhosphorIconsStyle.light),
                  title: 'Open ping chat',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onTap();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showChatActionSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),

                const SizedBox(height: 14),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _ChatHoldAction(
                      icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
                      label: archivedMode ? 'Unarchive' : 'Archive',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();

                        if (archivedMode) {
                          await _unarchiveChat(context);
                        } else {
                          await _archiveChat(context);
                        }
                      },
                    ),

                    _ChatHoldAction(
                      icon: muted
                          ? PhosphorIcons.bell(PhosphorIconsStyle.light)
                          : PhosphorIcons.bellSlash(
                              PhosphorIconsStyle.light,
                            ),
                      label: muted ? 'Unmute' : 'Mute',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();

                        if (muted) {
                          await _unmuteChat(context);
                        } else {
                          await _muteChat(context);
                        }
                      },
                    ),

                    _ChatHoldAction(
                      icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                      label: 'More',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _showMore(context);
                      },
                    ),

                    _ChatHoldAction(
                      icon: PhosphorIcons.trash(PhosphorIconsStyle.light),
                      label: 'Delete',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _deleteChat(context);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = pingmeeChannelTitle(channel);
    final subtitle = pingmeePingChannelSubtitle(channel);
    final sentAt = pingmeeChatTimeLabel(lastMessageObject?.createdAt);
    final preview = _lastMessageText();

    return Slidable(
      key: ValueKey(channel.cid ?? channel.id),
      groupTag: 'chat-inbox-row',
      closeOnScroll: true,
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.78,
        children: [
          SlidableAction(
            onPressed: archivedMode ? _unarchiveChat : _archiveChat,
            backgroundColor: archivedMode
                ? AppColors.brandGreen.withOpacity(.12)
                : const Color(0xFFEEF2FF),
            foregroundColor: archivedMode
                ? AppColors.brandGreen
                : const Color(0xFF4F46E5),
            icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
            label: archivedMode ? 'Unarchive' : 'Archive',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: muted ? _unmuteChat : _muteChat,
            backgroundColor: muted
                ? AppColors.brandGreen.withOpacity(.12)
                : const Color(0xFFFFF7ED),
            foregroundColor: muted
                ? AppColors.brandGreen
                : const Color(0xFFF97316),
            icon: muted
                ? PhosphorIcons.bell(PhosphorIconsStyle.light)
                : PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
            label: muted ? 'Unmute' : 'Mute',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: _showMore,
            backgroundColor: const Color(0xFFF3F4F6),
            foregroundColor: const Color(0xFF374151),
            icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
            label: 'More',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: _deleteChat,
            backgroundColor: const Color(0xFFFEE2E2),
            foregroundColor: const Color(0xFFE53935),
            icon: PhosphorIcons.trash(PhosphorIconsStyle.light),
            label: 'Delete',
            borderRadius: BorderRadius.circular(16),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showChatActionSheet(context),
          splashColor: AppColors.brandGreen.withOpacity(.035),
          highlightColor: Colors.black.withOpacity(.015),
          child: Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(
              children: [
                PingmeePingChannelAvatar(
                  channel: channel,
                  size: 50,
                  radius: 18,
                  iconSize: 24,
                ),

                const SizedBox(width: 13),

                Expanded(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(0, 17, 20, 17),
                    child: StreamBuilder<int>(
                      stream: channel.state?.unreadCountStream,
                      initialData: channel.state?.unreadCount ?? 0,
                      builder: (context, unreadSnap) {
                        final unreadCount = unreadSnap.data ?? 0;
                        final hasUnread = unreadCount > 0 || manualUnread;
                        final visibleUnreadCount =
                            unreadCount > 0 ? unreadCount : 1;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 15.4,
                                      fontWeight: hasUnread
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: const Color(0xFF111827),
                                    ),
                                  ),
                                ),

                                const SizedBox(width: 8),

                                if (sentAt.isNotEmpty)
                                  Text(
                                    sentAt,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 12.5,
                                      fontWeight: hasUnread
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: hasUnread
                                          ? AppColors.brandGreen
                                          : Colors.black.withOpacity(.40),
                                    ),
                                  ),
                              ],
                            ),

                            const SizedBox(height: 3),

                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 12.8,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.42),
                              ),
                            ),

                            const SizedBox(height: 4),

                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 14.2,
                                      height: 1.15,
                                      fontWeight: hasUnread
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                      color: hasUnread
                                          ? Colors.black.withOpacity(.74)
                                          : Colors.black.withOpacity(.46),
                                    ),
                                  ),
                                ),

                                if (muted) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    PhosphorIcons.bellSlash(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    size: 14,
                                    color: hasUnread
                                        ? AppColors.brandGreen
                                        : Colors.black.withOpacity(.34),
                                  ),
                                ],

                                const SizedBox(width: 8),

                                if (hasUnread)
                                  Container(
                                    constraints: const BoxConstraints(
                                      minWidth: 19,
                                      minHeight: 19,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreen,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      visibleUnreadCount > 99
                                          ? '99+'
                                          : visibleUnreadCount.toString(),
                                      style: const TextStyle(
                                        fontFamily: 'Nunito',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
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

class _ChatInboxTile extends StatelessWidget {
  const _ChatInboxTile({
    required this.channel,
    required this.person,
    required this.lastMessageObject,
    required this.onTap,
    required this.onRefresh,
    required this.onClearMutedLocalState,
    this.onSetMutedLocalState,
    this.archivedMode = false,
    this.muted = false,
    this.mutedUnseen = false,
    this.manualUnread = false,
  });

  final Channel channel;
  final PingmeeChatPerson person;
  final Message? lastMessageObject;
  final VoidCallback onTap;
  final Future<void> Function() onRefresh;
  final bool archivedMode;
  final bool muted;
  final bool mutedUnseen;
  final bool manualUnread;
  final VoidCallback onClearMutedLocalState;
  final VoidCallback? onSetMutedLocalState;

  Future<void> _archiveChat(BuildContext context) async {
    final ref = _chatPrefsRefFor(channel);

    if (ref == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not archive this chat.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await ref.set({
        'archived': true,
        'archivedAt': firestore.FieldValue.serverTimestamp(),
        'updatedAt': firestore.FieldValue.serverTimestamp(),
      }, firestore.SetOptions(merge: true));

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat archived.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not archive chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showChatActionSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),

                const SizedBox(height: 14),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _ChatHoldAction(
                      icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
                      label: archivedMode ? 'Unarchive' : 'Archive',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();

                        if (archivedMode) {
                          await _unarchiveChat(context);
                        } else {
                          await _archiveChat(context);
                        }
                      },
                    ),

                    _ChatHoldAction(
                      icon: muted
                          ? PhosphorIcons.bell(PhosphorIconsStyle.light)
                          : PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
                      label: muted ? 'Unmute' : 'Mute',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();

                        if (muted) {
                          await _unmuteChat(context);
                        } else {
                          await _muteChat(context);
                        }
                      },
                    ),

                    _ChatHoldAction(
                      icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                      label: 'More',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _showMore(context);
                      },
                    ),

                    _ChatHoldAction(
                      icon: PhosphorIcons.trash(PhosphorIconsStyle.light),
                      label: 'Delete',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _deleteChat(context);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _unarchiveChat(BuildContext context) async {
    final ref = _chatPrefsRefFor(channel);

    if (ref == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unarchive this chat.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await ref.set({
        'archived': false,
        'unarchivedAt': firestore.FieldValue.serverTimestamp(),
        'updatedAt': firestore.FieldValue.serverTimestamp(),
      }, firestore.SetOptions(merge: true));

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat moved back to inbox.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not unarchive chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<_MuteDurationChoice?> _showMuteDurationSheet(BuildContext context) {
    return showModalBottomSheet<_MuteDurationChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        void pick(_MuteDurationChoice choice) {
          Navigator.of(sheetContext).pop(choice);
        }

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 28,
                  offset: const Offset(0, 16),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),

                const SizedBox(height: 16),

                const Text(
                  'Mute notifications',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  'Choose how long you want this chat muted.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.55),
                    height: 1.3,
                  ),
                ),

                const SizedBox(height: 16),

                _MuteDurationRow(
                  icon: PhosphorIcons.clock(PhosphorIconsStyle.light),
                  title: 'For 1 hour',
                  onTap: () => pick(_MuteDurationChoice.oneHour),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.clockCountdown(PhosphorIconsStyle.light),
                  title: 'For 8 hours',
                  onTap: () => pick(_MuteDurationChoice.eightHours),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.calendarBlank(PhosphorIconsStyle.light),
                  title: 'For 24 hours',
                  onTap: () => pick(_MuteDurationChoice.twentyFourHours),
                ),

                const SizedBox(height: 8),

                _MuteDurationRow(
                  icon: PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
                  title: 'Until I change it',
                  onTap: () => pick(_MuteDurationChoice.forever),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _muteChat(BuildContext context) async {
    final choice = await _showMuteDurationSheet(context);
    if (choice == null) return;

    final now = DateTime.now();

    DateTime? mutedUntil;

    switch (choice) {
      case _MuteDurationChoice.oneHour:
        mutedUntil = now.add(const Duration(hours: 1));
        break;

      case _MuteDurationChoice.eightHours:
        mutedUntil = now.add(const Duration(hours: 8));
        break;

      case _MuteDurationChoice.twentyFourHours:
        mutedUntil = now.add(const Duration(hours: 24));
        break;

      case _MuteDurationChoice.forever:
        mutedUntil = null;
        break;
    }

    try {
      await _setChatMuted(
        channel: channel,
        mutedUntil: mutedUntil,
      );

      onSetMutedLocalState?.call();

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            mutedUntil == null
                ? 'Chat muted until you change it.'
                : 'Chat muted.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not mute chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _unmuteChat(BuildContext context) async {
    try {
      onClearMutedLocalState();

      await _clearChatMuted(channel);

      await onRefresh();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat unmuted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not unmute chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteChat(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            'Delete chat?',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w600,
            ),
          ),
          content: const Text(
            'This removes the chat from your inbox. It will not delete it for the other person.',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w400,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Color(0xFFE53935)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await channel.hide(clearHistory: true);
      await onRefresh();

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat deleted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not delete chat: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showMore(BuildContext context) {
    final streamUnreadCount = channel.state?.unreadCount ?? 0;
    final isUnread = streamUnreadCount > 0 || mutedUnseen || manualUnread;

    Future<void> markAsRead() async {
      try {
        await channel.markRead();
      } catch (_) {}

      await _clearChatManualUnread(channel);

      if (muted) {
        await _markMutedChatSeen(
          channel: channel,
          fallbackLastMessage: lastMessageObject,
        );
      }

      await onRefresh();
    }

    Future<void> markAsUnread() async {
      final message = lastMessageObject;
      final messageId = (message?.id ?? '').trim();

      if (message == null || messageId.isEmpty) return;

      try {
        // If your Stream version rejects this, tell me the exact error.
        await channel.markUnread(messageId);
      } catch (_) {
        // Firestore fallback still makes the UI behave correctly.
      }

      await _setChatManualUnread(
        channel: channel,
        message: message,
      );

      await onRefresh();
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MoreAction(
                  icon: isUnread
                      ? PhosphorIcons.checkCircle(PhosphorIconsStyle.light)
                      : PhosphorIcons.envelopeSimple(PhosphorIconsStyle.light),
                  title: isUnread ? 'Mark as read' : 'Mark as unread',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();

                    if (isUnread) {
                      await markAsRead();
                    } else {
                      await markAsUnread();
                    }
                  },
                ),

                const SizedBox(height: 8),

                _MoreAction(
                  icon: PhosphorIcons.userCircle(PhosphorIconsStyle.light),
                  title: 'View profile',
                  onTap: () {
                    Navigator.of(sheetContext).pop();

                    final profileUid = person.id.trim();

                    if (profileUid.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not open this profile.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      return;
                    }

                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProfileTab(profileUid: profileUid),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sentAt = pingmeeChatTimeLabel(lastMessageObject?.createdAt);

    final rawText = (lastMessageObject?.text ?? '').trim();

    final preview = rawText.isNotEmpty ? rawText : 'Sent an attachment';

    final currentUid =
        StreamChat.of(context).currentUser?.id ??
        fb.FirebaseAuth.instance.currentUser?.uid;

    final senderUid = lastMessageObject?.user?.id ?? '';

    final isMine = currentUid != null &&
        currentUid.isNotEmpty &&
        senderUid.isNotEmpty &&
        senderUid == currentUid;

    return Slidable(
      key: ValueKey(channel.cid),
      groupTag: 'chat-inbox-row',
      closeOnScroll: true,
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.78,
        children: [
          SlidableAction(
            onPressed: archivedMode ? _unarchiveChat : _archiveChat,
            backgroundColor: archivedMode
                ? AppColors.brandGreen.withOpacity(.12)
                : const Color(0xFFEEF2FF),
            foregroundColor: archivedMode
                ? AppColors.brandGreen
                : const Color(0xFF4F46E5),
            icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
            label: archivedMode ? 'Unarchive' : 'Archive',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: (actionContext) async {
              if (muted) {
                await _unmuteChat(context);
              } else {
                await _muteChat(context);
              }
            },
            backgroundColor: const Color(0xFFF3F4F6),
            foregroundColor: Colors.black.withOpacity(.78),
            icon: muted
                ? PhosphorIcons.bell(PhosphorIconsStyle.light)
                : PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
            label: muted ? 'Unmute' : 'Mute',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: _showMore,
            backgroundColor: const Color(0xFFF3F4F6),
            foregroundColor: const Color(0xFF374151),
            icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
            label: 'More',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: _deleteChat,
            backgroundColor: const Color(0xFFFEE2E2),
            foregroundColor: const Color(0xFFE53935),
            icon: PhosphorIcons.trash(PhosphorIconsStyle.light),
            label: 'Delete',
            borderRadius: BorderRadius.circular(16),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showChatActionSheet(context),
          splashColor: AppColors.brandGreen.withOpacity(.035),
          highlightColor: Colors.black.withOpacity(.015),
          child: Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(
              children: [
                _ChatAvatarWithLiveStatus(
                  userId: person.id,
                  imageUrl: person.image,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(0, 17, 20, 17),
                    child: StreamBuilder<int>(
                      stream: channel.state?.unreadCountStream,
                      initialData: channel.state?.unreadCount ?? 0,
                      builder: (context, unreadSnap) {
                        final unreadCount = unreadSnap.data ?? 0;

                        // Normal Stream unread OR muted-chat visual unread.
                        final hasUnread = unreadCount > 0 || mutedUnseen || manualUnread;

                        // If Stream gives no unread count for muted chats,
                        // still show a green "1" badge so the row does not look dead.
                        final visibleUnreadCount = unreadCount > 0 ? unreadCount : 1;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _LiveFullNameText(
                                    userId: person.id,
                                    fallbackName: person.name,
                                    hasUnread: hasUnread,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (sentAt.isNotEmpty)
                                  Text(
                                    sentAt,
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 12.5,
                                      fontWeight: hasUnread
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: hasUnread
                                          ? AppColors.brandGreen
                                          : Colors.black.withOpacity(.40),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: RichText(
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    text: TextSpan(
                                      children: [
                                        if (isMine)
                                          TextSpan(
                                            text: 'You: ',
                                            style: TextStyle(
                                              fontFamily: 'Nunito',
                                              fontSize: 14.8,
                                              height: 1.15,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black.withOpacity(.52),
                                            ),
                                          ),
                                        TextSpan(
                                          text: preview,
                                          style: TextStyle(
                                            fontFamily: 'Nunito',
                                            fontSize: 14.8,
                                            height: 1.15,
                                            fontWeight: hasUnread
                                                ? FontWeight.w500
                                                : FontWeight.w400,
                                            color: hasUnread
                                                ? Colors.black.withOpacity(.74)
                                                : Colors.black.withOpacity(.46),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (muted) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    PhosphorIcons.bellSlash(PhosphorIconsStyle.bold),
                                    size: 14,
                                    color: hasUnread
                                        ? AppColors.brandGreen
                                        : Colors.black.withOpacity(.34),
                                  ),
                                ],

                                const SizedBox(width: 8),

                                if (hasUnread)
                                  Container(
                                    constraints: const BoxConstraints(
                                      minWidth: 19,
                                      minHeight: 19,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreen,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      visibleUnreadCount > 99
                                          ? '99+'
                                          : visibleUnreadCount.toString(),
                                      style: const TextStyle(
                                        fontFamily: 'Nunito',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
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

class _LiveFullNameText extends StatelessWidget {
  const _LiveFullNameText({
    required this.userId,
    required this.fallbackName,
    required this.hasUnread,
  });

  final String userId;
  final String fallbackName;
  final bool hasUnread;

  bool _isVerified(Map<String, dynamic>? data) {
    final verification = Map<String, dynamic>.from(
      data?['verification'] ?? {},
    );

    return verification['status'] == 'verified';
  }

  @override
  Widget build(BuildContext context) {
    if (userId.trim().isEmpty) {
      return _NameText(
        name: fallbackName,
        hasUnread: hasUnread,
        verified: false,
      );
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final name = snap.hasData
            ? pingmeeFullNameFromUserData(data)
            : fallbackName;

        final verified = _isVerified(data);

        return _NameText(
          name: name,
          hasUnread: hasUnread,
          verified: verified,
        );
      },
    );
  }
}

class _NameText extends StatelessWidget {
  const _NameText({
    required this.name,
    required this.hasUnread,
    required this.verified,
  });

  final String name;
  final bool hasUnread;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 17.5,
              fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
              color: const Color(0xFF111827),
            ),
          ),
        ),

        if (verified) ...[
          const SizedBox(width: 5),
          Icon(
            PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
            size: 16,
            color: const Color(0xFF1D9BF0),
          ),
        ],
      ],
    );
  }
}

class _ChatAvatarWithLiveStatus extends StatelessWidget {
  const _ChatAvatarWithLiveStatus({
    required this.userId,
    required this.imageUrl,
  });

  final String userId;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (userId.trim().isEmpty) {
      return _ChatAvatarWithStatus(
        imageUrl: imageUrl,
        online: false,
        lastActiveLabel: '',
      );
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final online = _chatIsReallyOnlineFromUserData(data);
        final lastSeen = _chatLastSeenFromUserData(data);
        final lastActiveLabel = online
            ? ''
            : _chatLastActiveShortLabel(lastSeen);

        return _ChatAvatarWithStatus(
          imageUrl: imageUrl,
          online: online,
          lastActiveLabel: lastActiveLabel,
        );
      },
    );
  }
}

class _ChatAvatarWithStatus extends StatelessWidget {
  const _ChatAvatarWithStatus({
    required this.imageUrl,
    required this.online,
    required this.lastActiveLabel,
  });

  final String imageUrl;
  final bool online;
  final String lastActiveLabel;

  @override
  Widget build(BuildContext context) {
    final showLastActive = !online && lastActiveLabel.trim().isNotEmpty;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 29,
          backgroundColor: AppColors.brandGreen.withOpacity(.10),
          backgroundImage: imageUrl.isEmpty ? null : NetworkImage(imageUrl),
          child: imageUrl.isEmpty
              ? Icon(
                  PhosphorIcons.user(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                  size: 24,
                )
              : null,
        ),

        if (online)
          Positioned(
            right: 1,
            bottom: 1,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: AppColors.brandGreen,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
              ),
            ),
          ),

        if (showLastActive)
          Positioned(
            right: -6,
            bottom: -2,
            child: Container(
              constraints: const BoxConstraints(
                minWidth: 24,
                minHeight: 17,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                lastActiveLabel,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.black.withOpacity(.54),
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChatHoldAction extends StatelessWidget {
  const _ChatHoldAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          child: SizedBox(
            width: 68,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    icon,
                    size: 22,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
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

class _MoreAction extends StatelessWidget {
  const _MoreAction({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF3F6FB),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Colors.black.withOpacity(.68),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF111827),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MuteDurationRow extends StatelessWidget {
  const _MuteDurationRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF5F7FA),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Colors.black.withOpacity(.72),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
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

class _ChatRequestsState extends StatelessWidget {
  const _ChatRequestsState();

  @override
  Widget build(BuildContext context) {
    final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

    if (myUid == null || myUid.isEmpty) {
      return const _ChatRequestsEmptyState();
    }

    return StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(myUid)
          .collection('message_requests_in')
          .where('status', isEqualTo: 'pending')
          .orderBy('updatedAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(Color(0xFF111827)),
            ),
          );
        }

        if (snap.hasError) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(28, 54, 28, 140),
            physics: const BouncingScrollPhysics(),
            children: [
              _ChatRequestsInfoCard(
                icon: PhosphorIcons.warningCircle(PhosphorIconsStyle.bold),
                title: 'Couldn’t load requests',
                subtitle: 'Something went wrong. Pull back later or check your connection.',
              ),
            ],
          );
        }

        final docs = snap.data?.docs ?? const [];

        if (docs.isEmpty) {
          return const _ChatRequestsEmptyState();
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 140),
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final requestDoc = docs[index];
            final data = requestDoc.data();

            final fromUid = (data['fromUid'] ?? requestDoc.id).toString().trim();

            if (fromUid.isEmpty) {
              return const SizedBox.shrink();
            }

            return _MessageRequestTile(
              myUid: myUid,
              fromUid: fromUid,
              requestData: data,
            );
          },
        );
      },
    );
  }
}

class _ChatRequestsEmptyState extends StatelessWidget {
  const _ChatRequestsEmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 54, 28, 140),
      physics: const BouncingScrollPhysics(),
      children: [
        _ChatRequestsInfoCard(
          icon: PhosphorIcons.userPlus(PhosphorIconsStyle.bold),
          title: 'No requests yet',
          subtitle: 'New message requests will appear here before they enter your inbox.',
        ),
      ],
    );
  }
}

class _ChatRequestsInfoCard extends StatelessWidget {
  const _ChatRequestsInfoCard({
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
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.52),
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageRequestTile extends StatelessWidget {
  const _MessageRequestTile({
    required this.myUid,
    required this.fromUid,
    required this.requestData,
  });

  final String myUid;
  final String fromUid;
  final Map<String, dynamic> requestData;

  String _displayName(Map<String, dynamic>? data) {
    final d = data ?? <String, dynamic>{};

    final fullName = (d['fullName'] ?? '').toString().trim();
    if (fullName.isNotEmpty) return fullName;

    final displayName = (d['displayName'] ?? '').toString().trim();
    if (displayName.isNotEmpty) return displayName;

    final username = (d['username'] ?? '').toString().trim();
    if (username.isNotEmpty) return username;

    return 'Pingmee user';
  }

  String _photoUrl(Map<String, dynamic>? data) {
    final d = data ?? <String, dynamic>{};

    final photoUrl = (d['photoUrl'] ?? '').toString().trim();
    if (photoUrl.isNotEmpty) return photoUrl;

    final profilePhotoUrl = (d['profilePhotoUrl'] ?? '').toString().trim();
    if (profilePhotoUrl.isNotEmpty) return profilePhotoUrl;

    final avatarUrl = (d['avatarUrl'] ?? '').toString().trim();
    if (avatarUrl.isNotEmpty) return avatarUrl;

    return '';
  }

  String _subtitle() {
    final count = (requestData['messageCount'] is num)
        ? (requestData['messageCount'] as num).toInt()
        : 0;

    final max = (requestData['maxMessages'] is num)
        ? (requestData['maxMessages'] as num).toInt()
        : 3;

    if (count <= 0) {
      return 'Wants to send you a message.';
    }

    return '$count of $max request messages sent.';
  }

  Future<void> _openRequestChat(BuildContext context) async {
    try {
      final client = StreamChat.of(context).client;
      final rawCid = (requestData['channelCid'] ?? '').toString().trim();

      Channel channel;

      if (rawCid.contains(':')) {
        final parts = rawCid.split(':');
        final type = parts.first.trim();
        final id = parts.sublist(1).join(':').trim();

        channel = client.channel(type, id: id);
        await channel.watch();
      } else {
        channel = await PingmeeStreamChatService.instance
            .openCachedOrCreateDirectChat(fromUid);
      }

      if (!context.mounted) return;

      await Navigator.of(context).push(
        pingmeeChatRoute(channel),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open request: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _acceptRequest(BuildContext context) async {
    final db = firestore.FirebaseFirestore.instance;
    final now = firestore.FieldValue.serverTimestamp();

    final incomingRef = db
        .collection('users')
        .doc(myUid)
        .collection('message_requests_in')
        .doc(fromUid);

    final outgoingRef = db
        .collection('users')
        .doc(fromUid)
        .collection('message_requests_out')
        .doc(myUid);

    try {
      await db.runTransaction((tx) async {
        tx.set(
          incomingRef,
          {
            'status': 'accepted',
            'acceptedAt': now,
            'updatedAt': now,
          },
          firestore.SetOptions(merge: true),
        );

        tx.set(
          outgoingRef,
          {
            'status': 'accepted',
            'acceptedAt': now,
            'updatedAt': now,
          },
          firestore.SetOptions(merge: true),
        );
      });

      if (!context.mounted) return;

      HapticFeedback.mediumImpact();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request accepted.'),
          behavior: SnackBarBehavior.floating,
        ),
      );

      await _openRequestChat(context);
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not accept request: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _declineRequest(BuildContext context) async {
    final db = firestore.FirebaseFirestore.instance;
    final now = firestore.FieldValue.serverTimestamp();

    final incomingRef = db
        .collection('users')
        .doc(myUid)
        .collection('message_requests_in')
        .doc(fromUid);

    final outgoingRef = db
        .collection('users')
        .doc(fromUid)
        .collection('message_requests_out')
        .doc(myUid);

    try {
      await db.runTransaction((tx) async {
        tx.set(
          incomingRef,
          {
            'status': 'declined',
            'declinedAt': now,
            'updatedAt': now,
          },
          firestore.SetOptions(merge: true),
        );

        tx.set(
          outgoingRef,
          {
            'status': 'declined',
            'declinedAt': now,
            'updatedAt': now,
          },
          firestore.SetOptions(merge: true),
        );
      });

      if (!context.mounted) return;

      HapticFeedback.selectionClick();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request declined.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not decline request: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(fromUid)
          .snapshots(),
      builder: (context, snap) {
        final userData = snap.data?.data();

        final name = _displayName(userData);
        final imageUrl = _photoUrl(userData);
        final verified = _chatUserIsVerified(userData);

        return Material(
          color: const Color(0xFFF5F7FA),
          borderRadius: BorderRadius.circular(26),
          child: InkWell(
            onTap: () => _openRequestChat(context),
            borderRadius: BorderRadius.circular(26),
            splashColor: Colors.black.withOpacity(.035),
            highlightColor: Colors.black.withOpacity(.02),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 25,
                        backgroundColor: Colors.black.withOpacity(.06),
                        backgroundImage:
                            imageUrl.isEmpty ? null : NetworkImage(imageUrl),
                        child: imageUrl.isEmpty
                            ? Icon(
                                PhosphorIcons.user(PhosphorIconsStyle.light),
                                color: Colors.black.withOpacity(.55),
                                size: 24,
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
                                    name,
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

                                if (verified) ...[
                                  const SizedBox(width: 5),
                                  Icon(
                                    PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                                    size: 15.5,
                                    color: const Color(0xFF1D9BF0),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _subtitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 12.8,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.50),
                              ),
                            ),
                          ],
                        ),
                      ),

                      Icon(
                        PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                        size: 16,
                        color: Colors.black.withOpacity(.32),
                      ),
                    ],
                  ),

                  const SizedBox(height: 13),

                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: () => _acceptRequest(context),
                            borderRadius: BorderRadius.circular(999),
                            child: const SizedBox(
                              height: 42,
                              child: Center(
                                child: Text(
                                  'Accept',
                                  style: TextStyle(
                                    fontFamily: 'Nunito',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 10),

                      Expanded(
                        child: Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: () => _declineRequest(context),
                            borderRadius: BorderRadius.circular(999),
                            child: SizedBox(
                              height: 42,
                              child: Center(
                                child: Text(
                                  'Decline',
                                  style: TextStyle(
                                    fontFamily: 'Nunito',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black.withOpacity(.70),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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

class _EmptyInboxState extends StatelessWidget {
  const _EmptyInboxState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(28, 54, 28, 140),
      physics: BouncingScrollPhysics(),
      children: [
        _EmptyInboxCard(),
      ],
    );
  }
}

class _EmptyInboxCard extends StatelessWidget {
  const _EmptyInboxCard();

  void _openNewChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NewChatScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          Material(
            color: Colors.black,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              onTap: () => _openNewChat(context),
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                width: 58,
                height: 58,
                child: Icon(
                  PhosphorIcons.chatCircleDots(
                    PhosphorIconsStyle.bold,
                  ),
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          const Text(
            'No chats yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),

          const SizedBox(height: 6),

          Text(
            'Start a new chat and your conversations will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.52),
              height: 1.3,
            ),
          ),

          const SizedBox(height: 16),

          Material(
            color: Colors.black,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () => _openNewChat(context),
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
                child: Text(
                  'Start new chat',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

class _ChatLoadingState extends StatelessWidget {
  const _ChatLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFEFF2F7),
      body: SafeArea(
        bottom: false,
        child: _ChatContentLoadingState(),
      ),
    );
  }
}


class _ChatContentLoadingState extends StatefulWidget {
  const _ChatContentLoadingState();

  @override
  State<_ChatContentLoadingState> createState() =>
      _ChatContentLoadingStateState();
}

class _ChatContentLoadingStateState extends State<_ChatContentLoadingState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _fade = Tween<double>(
    begin: .38,
    end: .82,
  ).animate(
    CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _bone({
    required double height,
    double? width,
    double radius = 999,
  }) {
    return FadeTransition(
      opacity: _fade,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }

  Widget _loadingRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.54),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withOpacity(.45),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            _bone(height: 48, width: 48, radius: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bone(height: 13, width: 130),
                  const SizedBox(height: 9),
                  _bone(height: 11, width: double.infinity),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _bone(height: 20, width: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          child: Column(
            children: [
              Row(
                children: [
                  _bone(height: 24, width: 72, radius: 10),
                  const Spacer(),
                  _bone(height: 42, width: 42, radius: 16),
                ],
              ),
              const SizedBox(height: 12),
              _bone(height: 48, width: double.infinity, radius: 22),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _bone(height: 42)),
                  const SizedBox(width: 8),
                  Expanded(child: _bone(height: 42)),
                  const SizedBox(width: 8),
                  Expanded(child: _bone(height: 42)),
                  const SizedBox(width: 8),
                  _bone(height: 42, width: 42),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _loadingRow(),
              _loadingRow(),
              _loadingRow(),
              _loadingRow(),
              _loadingRow(),
              _loadingRow(),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatReconnectState extends StatelessWidget {
  const _ChatReconnectState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 70, 24, 140),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                blurRadius: 24,
                offset: const Offset(0, 14),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen.withOpacity(.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  PhosphorIcons.chatCircleDots(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                  size: 26,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Reconnecting chat',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.55),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => onRetry(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Try again',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}


class _ArchivedUnreadBadge extends StatefulWidget {
  final VoidCallback onTap;

  const _ArchivedUnreadBadge({super.key, required this.onTap});

  @override
  State<_ArchivedUnreadBadge> createState() => _ArchivedUnreadBadgeState();
}

class _ArchivedUnreadBadgeState extends State<_ArchivedUnreadBadge> {
  late Future<StreamChatClient?> _clientFuture;
  final Set<String> _archivedCids = {};
  StreamSubscription? _archivedPrefsSub;

  int _computeArchivedUnread(Map<String, Channel> channels) {
    final currentUserId = _client?.state.currentUser?.id;
    int total = 0;
    for (final channel in channels.values) {
      final state = channel.state;
      if (state == null) continue;
      if (state.unreadCount <= 0) continue;

      final cid = channel.cid ?? '';
      if (!cid.startsWith('messaging:')) continue;
      if (!_archivedCids.contains(cid)) continue;

      if (currentUserId != null &&
          state.members.isNotEmpty &&
          !state.members.any((m) => m.userId == currentUserId)) {
        continue;
      }

      total += state.unreadCount;
    }
    return total;
  }

  void _listenToArchivedChanges() {
    final uid = fb.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _archivedPrefsSub?.cancel();
    _archivedPrefsSub = firestore.FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('chatPrefs')
        .where('archived', isEqualTo: true)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final archived = <String>{};
      for (final doc in snap.docs) {
        archived.add(Uri.decodeComponent(doc.id));
      }
      setState(() {
        _archivedCids.clear();
        _archivedCids.addAll(archived);
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _clientFuture = _loadClient();
  }

  Future<StreamChatClient?> _loadClient() async {
    try {
      final client = await PingmeeStreamChatService.instance.connectCurrentUser();
      if (mounted && client != null) {
        _client = client;
        _listenToArchivedChanges();
      }
      return client;
    } catch (_) {
      return null;
    }
  }

  StreamChatClient? _client;

  @override
  void dispose() {
    _archivedPrefsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StreamChatClient?>(
      future: _clientFuture,
      builder: (context, snap) {
        final client = snap.data;
        final count = client != null ? _computeArchivedUnread(client.state.channels) : 0;
        final showBadge = count > 0;
        final badgeText = count > 99 ? '99+' : count.toString();

        return GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF4F6FA),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Icon(
                        PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                        size: 22,
                        color: Colors.black.withOpacity(.58),
                      ),
                    ),
                  ),
                ),
                if (showBadge)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badgeText,
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1,
                        ),
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


class _ArchivedChatsScreen extends StatefulWidget {
  const _ArchivedChatsScreen();

  @override
  State<_ArchivedChatsScreen> createState() => _ArchivedChatsScreenState();
}

class _ArchivedChatsScreenState extends State<_ArchivedChatsScreen> {
  late Future<StreamChatClient> _connectFuture;

  @override
  void initState() {
    super.initState();
    _connectFuture = PingmeeStreamChatService.instance.connectCurrentUser();
  }

  Future<void> _retry() async {
    setState(() {
      _connectFuture = PingmeeStreamChatService.instance.connectCurrentUser();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StreamChatClient>(
      future: _connectFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _ChatLoadingState();
        }

        if (snap.hasError || !snap.hasData) {
          return _ChatErrorState(
            message: snap.error?.toString() ?? 'Could not load archived chats.',
            onRetry: _retry,
          );
        }

        return StreamChat(
          client: snap.data!,
          child: Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _ArchivedChatsHeader(),
                  const Expanded(
                    child: _ArchivedChannelListBody(),
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

class _ArchivedChatsHeader extends StatelessWidget {
  const _ArchivedChatsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 20, 10),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  PhosphorIcons.arrowLeft(PhosphorIconsStyle.light),
                  size: 22,
                  color: Colors.black.withOpacity(.74),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Archived chats',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArchivedChannelListBody extends StatefulWidget {
  const _ArchivedChannelListBody();

  @override
  State<_ArchivedChannelListBody> createState() =>
      _ArchivedChannelListBodyState();
}

class _ArchivedChannelListBodyState extends State<_ArchivedChannelListBody> {
  StreamChannelListController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_controller != null) return;

    final stream = StreamChat.of(context);
    final currentUser = stream.currentUser;

    if (currentUser == null) return;

    _controller = StreamChannelListController(
      client: stream.client,
      filter: Filter.and([
        Filter.equal('type', 'messaging'),
        Filter.in_(
          'members',
          [currentUser.id],
        ),
      ]),
      channelStateSort: const [
        SortOption('last_message_at'),
      ],
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller == null) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.brandGreen,
      onRefresh: controller.refresh,
      child: StreamChannelListView(
        controller: controller,

        // No borders / dividers between chat previews.
        separatorBuilder: (context, channels, index) {
          return const SizedBox.shrink();
        },

        emptyBuilder: (_) => const _EmptyArchivedChatsState(),
        errorBuilder: (context, error) {
          return _ChatErrorState(
            message: error.toString(),
            onRetry: controller.refresh,
          );
        },
        itemBuilder: (context, channels, index, defaultTile) {
          final channel = channels[index];

          if (pingmeeIsPingChannel(channel)) {
            return StreamBuilder<Message?>(
              stream: channel.state?.lastMessageStream,
              initialData: channel.state?.lastMessage,
              builder: (context, messageSnap) {
                final lastMessageObject = messageSnap.data;

                if (!pingmeeMatchesPingChannelQuery(
                  channel: channel,
                  lastMessage: lastMessageObject,
                  query: '',
                )) {
                  return const SizedBox.shrink();
                }

                final prefsRef = _chatPrefsRefFor(channel);

                Widget buildPingTile({
                  required bool muted,
                  required bool manualUnread,
                }) {
                  return _PingChannelInboxTile(
                    channel: channel,
                    lastMessageObject: lastMessageObject,
                    muted: muted,
                    manualUnread: manualUnread,
                    archivedMode: true,
                    onRefresh: controller.refresh,
                    onTap: () async {
                      await Navigator.of(context).push(
                        pingmeeChatRoute(channel),
                      );

                      if (!mounted) return;

                      await _clearChatManualUnread(channel);
                      await controller.refresh();
                    },
                  );
                }

                if (prefsRef == null) {
                  return buildPingTile(
                    muted: false,
                    manualUnread: false,
                  );
                }

                return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
                  stream: prefsRef.snapshots(),
                  builder: (context, prefsSnap) {
                    final prefsData = prefsSnap.data?.data();

                    if (!_chatPrefsArchived(prefsData)) {
                      return const SizedBox.shrink();
                    }

                    if (_chatPrefsMuteExpired(prefsData)) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        unawaited(_clearChatMuted(channel));
                      });
                    }

                    return buildPingTile(
                      muted: _chatPrefsMuted(prefsData),
                      manualUnread: _chatPrefsManualUnread(prefsData),
                    );
                  },
                );
              },
            );
          }

          final person = pingmeeOtherDmPerson(
            context: context,
            channel: channel,
          );

          if (person.id.isNotEmpty) {
            PingmeeStreamChatService.instance.cacheDirectChannel(
              otherUid: person.id,
              channel: channel,
            );
          }

          return StreamBuilder<Message?>(
            stream: channel.state?.lastMessageStream,
            initialData: channel.state?.lastMessage,
            builder: (context, messageSnap) {
              final lastMessageObject = messageSnap.data;

              if (lastMessageObject == null) {
                return const SizedBox.shrink();
              }

              final prefsRef = _chatPrefsRefFor(channel);

              if (prefsRef == null) {
                return const SizedBox.shrink();
              }

              return StreamBuilder<
                  firestore.DocumentSnapshot<Map<String, dynamic>>>(
                stream: prefsRef.snapshots(),
                builder: (context, prefsSnap) {
                  final archived = _chatPrefsArchived(
                    prefsSnap.data?.data(),
                  );

                  if (!archived) {
                    return const SizedBox.shrink();
                  }

                  return _ChatInboxTile(
                    channel: channel,
                    person: person,
                    lastMessageObject: lastMessageObject,
                    archivedMode: true,
                    muted: _chatPrefsMuted(prefsSnap.data?.data()),
                    mutedUnseen: false,
                    manualUnread: false,
                    onClearMutedLocalState: () {},
                    onRefresh: controller.refresh,
                    onTap: () async {
                      await Navigator.of(context).push(
                        pingmeeChatRoute(channel),
                      );

                      await controller.refresh();
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyArchivedChatsState extends StatelessWidget {
  const _EmptyArchivedChatsState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 54, 28, 140),
      physics: const BouncingScrollPhysics(),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F7FA),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  PhosphorIcons.archive(PhosphorIconsStyle.bold),
                  color: Colors.white,
                  size: 28,
                ),
              ),

              const SizedBox(height: 16),

              const Text(
                'No archived chats',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),

              const SizedBox(height: 6),

              Text(
                'Chats you archive will appear here when you move them out of your inbox.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.52),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatErrorState extends StatelessWidget {
  const _ChatErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Chat failed to load',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => onRetry(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Try again',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}