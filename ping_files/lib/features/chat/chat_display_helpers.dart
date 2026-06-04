import 'package:flutter/material.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/theme/colors2.dart';

class PingmeeChatPerson {
  const PingmeeChatPerson({
    required this.id,
    required this.name,
    required this.image,
    required this.online,
  });

  final String id;
  final String name;
  final String image;
  final bool online;
}

String _cleanString(Object? value) {
  return (value ?? '').toString().trim();
}

String pingmeeFullNameFromUserData(Map<String, dynamic>? data) {
  final d = data ?? <String, dynamic>{};

  final fullName = _cleanString(d['fullName']);
  final displayName = _cleanString(d['displayName']);
  final name = _cleanString(d['name']);

  final firstName = _cleanString(d['firstName']);
  final lastName = _cleanString(d['lastName']);

  final combinedName = [firstName, lastName]
      .where((part) => part.isNotEmpty)
      .join(' ')
      .trim();

  if (fullName.isNotEmpty) return fullName;
  if (displayName.isNotEmpty) return displayName;
  if (name.isNotEmpty) return name;
  if (combinedName.isNotEmpty) return combinedName;

  return 'Pingmee user';
}

String pingmeePhotoFromUserData(Map<String, dynamic>? data) {
  final d = data ?? <String, dynamic>{};

  final photoUrl = _cleanString(d['photoUrl']);
  final photoURL = _cleanString(d['photoURL']);
  final profilePhotoUrl = _cleanString(d['profilePhotoUrl']);
  final avatarUrl = _cleanString(d['avatarUrl']);
  final image = _cleanString(d['image']);

  if (photoUrl.isNotEmpty) return photoUrl;
  if (photoURL.isNotEmpty) return photoURL;
  if (profilePhotoUrl.isNotEmpty) return profilePhotoUrl;
  if (avatarUrl.isNotEmpty) return avatarUrl;
  if (image.isNotEmpty) return image;

  return '';
}

DateTime? _pingmeeLastSeenFromUserData(Map<String, dynamic>? data) {
  if (data == null) return null;
  final raw = data['lastSeen'] ??
      data['lastSeenAt'] ??
      data['lastActiveAt'] ??
      data['lastOnlineAt'] ??
      data['updatedAt'];
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is firestore.Timestamp) return raw.toDate();
  return DateTime.tryParse(raw.toString());
}

bool pingmeeIsOnlineFromUserData(Map<String, dynamic>? data) {
  if (data == null) return false;

  final rawOnline = data['online'] == true;
  final rawIsOnline = data['isOnline'] == true;
  final presence = _cleanString(data['presence'] ?? '').toLowerCase();

  final saysOnline = rawOnline || rawIsOnline || presence == 'online';
  if (!saysOnline) return false;

  final lastSeen = _pingmeeLastSeenFromUserData(data);

  // If no lastSeen yet, don't trust stale online flags blindly.
  if (lastSeen == null) return false;

  final diff = DateTime.now().difference(lastSeen.toLocal());

  if (diff.isNegative) return true;

  // Online only if seen within the last 2 minutes.
  return diff.inMinutes < 2;
}

String _bestFullNameFromStreamUser(User? user) {
  if (user == null) return 'Pingmee user';

  final fullName = _cleanString(user.extraData['fullName']);
  final displayName = _cleanString(user.extraData['displayName']);
  final name = _cleanString(user.name);

  final firstName = _cleanString(user.extraData['firstName']);
  final lastName = _cleanString(user.extraData['lastName']);

  final combinedName = [firstName, lastName]
      .where((part) => part.isNotEmpty)
      .join(' ')
      .trim();

  if (fullName.isNotEmpty) return fullName;
  if (displayName.isNotEmpty) return displayName;
  if (name.isNotEmpty) return name;
  if (combinedName.isNotEmpty) return combinedName;

  return 'Pingmee user';
}

PingmeeChatPerson pingmeeOtherDmPerson({
  required BuildContext context,
  required Channel channel,
}) {
  final currentUserId = StreamChat.of(context).currentUser?.id;
  final members = channel.state?.members ?? const <Member>[];

  Member? otherMember;

  for (final member in members) {
    final memberUserId = member.userId ?? member.user?.id;

    if (memberUserId != null && memberUserId != currentUserId) {
      otherMember = member;
      break;
    }
  }

  otherMember ??= members.isNotEmpty ? members.first : null;

  final user = otherMember?.user;
  final id = user?.id ?? otherMember?.userId ?? '';

  final image = _cleanString(user?.image).isNotEmpty
      ? _cleanString(user?.image)
      : _cleanString(user?.extraData['photoUrl']).isNotEmpty
          ? _cleanString(user?.extraData['photoUrl'])
          : _cleanString(user?.extraData['photoURL']);

  final presence = _cleanString(user?.extraData['presence']).toLowerCase();

  final online =
      user?.online == true ||
      user?.extraData['online'] == true ||
      user?.extraData['isOnline'] == true ||
      presence == 'online';

  return PingmeeChatPerson(
    id: id,
    name: _bestFullNameFromStreamUser(user),
    image: image,
    online: online,
  );
}

String pingmeeChatTimeLabel(DateTime? dateTime) {
  if (dateTime == null) return '';

  final local = dateTime.toLocal();
  final now = DateTime.now();

  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;

  String two(int value) => value.toString().padLeft(2, '0');

  if (sameDay) {
    return '${two(local.hour)}:${two(local.minute)}';
  }

  final yesterday = now.subtract(const Duration(days: 1));

  final wasYesterday =
      local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;

  if (wasYesterday) return 'Yesterday';

  return '${local.day}/${local.month}/${local.year}';
}

bool pingmeeIsPingChannel(Channel channel) {
  final type = (channel.extraData['pingmeeType'] ?? '')
      .toString()
      .trim()
      .toLowerCase();

  final id = (channel.id ?? '').toString().trim();

  return type == 'ping' || id.startsWith('ping_');
}

String pingmeeChannelTitle(Channel channel) {
  final name = (channel.extraData['name'] ?? '').toString().trim();

  if (name.isNotEmpty) return name;

  return 'Ping chat';
}

String pingmeeChannelImage(Channel channel) {
  return (channel.extraData['image'] ?? '').toString().trim();
}

int pingmeeChannelMemberCount(Channel channel) {
  final raw = channel.extraData['pingmeeMemberCount'];

  if (raw is num) return raw.toInt();

  final members = channel.state?.members ?? const <Member>[];

  if (members.isNotEmpty) return members.length;

  return 1;
}

int pingmeeChannelOnlineCount(Channel channel) {
  final members = channel.state?.members ?? const <Member>[];

  var count = 0;

  for (final member in members) {
    final user = member.user;

    final presence =
        (user?.extraData['presence'] ?? '').toString().trim().toLowerCase();

    final online =
        user?.online == true ||
        user?.extraData['online'] == true ||
        user?.extraData['isOnline'] == true ||
        presence == 'online';

    if (online) count++;
  }

  return count;
}

String pingmeePingChannelSubtitle(Channel channel) {
  final members = pingmeeChannelMemberCount(channel);
  final online = pingmeeChannelOnlineCount(channel);

  final memberText = members == 1 ? '1 member' : '$members members';
  final onlineText = online == 1 ? '1 online' : '$online online';

  return '$onlineText · $memberText';
}

String pingmeePingIdFromChannel(Channel channel) {
  final fromExtra = (channel.extraData['pingId'] ?? '').toString().trim();

  if (fromExtra.isNotEmpty) {
    return fromExtra;
  }

  final id = (channel.id ?? '').toString().trim();

  if (id.startsWith('ping_') && id.length > 5) {
    return id.substring(5);
  }

  return '';
}

String pingmeeFirstPingMediaImageFromData(Map<String, dynamic>? data) {
  final d = data ?? <String, dynamic>{};

  final directCandidates = [
    d['chatImageUrl'],
    d['coverImageUrl'],
    d['coverUrl'],
    d['imageUrl'],
    d['photoUrl'],
  ];

  for (final item in directCandidates) {
    final value = (item ?? '').toString().trim();

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
  }

  final media = d['media'];

  if (media is List) {
    for (final raw in media) {
      if (raw is! Map) continue;

      final item = Map<String, dynamic>.from(raw);
      final type = (item['type'] ?? '').toString().trim().toLowerCase();

      final thumbUrl = (item['thumbUrl'] ?? '').toString().trim();
      final url = (item['url'] ?? '').toString().trim();

      final isVisual = type == 'image' || type == 'video';

      if (!isVisual) continue;

      if (thumbUrl.startsWith('http://') || thumbUrl.startsWith('https://')) {
        return thumbUrl;
      }

      if (url.startsWith('http://') || url.startsWith('https://')) {
        return url;
      }
    }
  }

  return '';
}

({IconData icon, Color color}) pingmeePingCategoryStyleFromData(
  Map<String, dynamic>? data,
) {
  final d = data ?? <String, dynamic>{};

  final category = (d['category'] ?? d['category_lc'] ?? '')
      .toString()
      .trim()
      .toLowerCase();

  if (category.contains('study')) {
    return (
      icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
      color: const Color(0xFF6C5CE7),
    );
  }

  if (category.contains('gym') ||
      category.contains('fitness') ||
      category.contains('workout')) {
    return (
      icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
      color: const Color(0xFFE74C3C),
    );
  }

  if (category.contains('gaming') || category.contains('game')) {
    return (
      icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
      color: const Color(0xFF9B59B6),
    );
  }

  if (category.contains('network')) {
    return (
      icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
      color: const Color(0xFF3498DB),
    );
  }

  if (category.contains('help')) {
    return (
      icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
      color: const Color(0xFFE67E22),
    );
  }

  if (category.contains('support')) {
    return (
      icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
      color: const Color(0xFF1ABC9C),
    );
  }

  if (category.contains('event')) {
    return (
      icon: PhosphorIcons.ticket(PhosphorIconsStyle.fill),
      color: const Color(0xFFF39C12),
    );
  }

  if (category.contains('hangout') ||
      category.contains('hang out') ||
      category.contains('chill')) {
    return (
      icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
      color: const Color(0xFFE91E63),
    );
  }

  if (category.contains('instant')) {
    return (
      icon: PhosphorIcons.siren(PhosphorIconsStyle.fill),
      color: const Color(0xFFFFB800),
    );
  }

  if (category.contains('food') || category.contains('eat')) {
    return (
      icon: PhosphorIcons.hamburger(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF6B6B),
    );
  }

  if (category.contains('music')) {
    return (
      icon: PhosphorIcons.musicNotes(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF1744),
    );
  }

  if (category.contains('sport')) {
    return (
      icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
      color: const Color(0xFF2196F3),
    );
  }

  final palette = [
    const Color(0xFF00BCD4),
    const Color(0xFF009688),
    const Color(0xFF8BC34A),
    const Color(0xFFFF5722),
    const Color(0xFF673AB7),
    const Color(0xFFE91E63),
  ];

  final fallbackColor = category.isEmpty
      ? AppColors.brandGreen
      : palette[category.hashCode.abs() % palette.length];

  return (
    icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
    color: fallbackColor,
  );
}

class PingmeePingChannelAvatar extends StatelessWidget {
  const PingmeePingChannelAvatar({
    super.key,
    required this.channel,
    this.size = 42,
    this.radius = 16,
    this.iconSize = 22,
  });

  final Channel channel;
  final double size;
  final double radius;
  final double iconSize;

  Widget _box({
    required String imageUrl,
    required IconData fallbackIcon,
    required Color fallbackColor,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fallbackColor.withOpacity(.13),
        borderRadius: BorderRadius.circular(radius),
        image: imageUrl.isEmpty
            ? null
            : DecorationImage(
                image: NetworkImage(imageUrl),
                fit: BoxFit.cover,
              ),
      ),
      child: imageUrl.isEmpty
          ? Center(
              child: Icon(
                fallbackIcon,
                color: fallbackColor,
                size: iconSize,
              ),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final streamImage = pingmeeChannelImage(channel);
    final pingId = pingmeePingIdFromChannel(channel);

    if (pingId.isEmpty) {
      return _box(
        imageUrl: streamImage,
        fallbackIcon: PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
        fallbackColor: AppColors.brandGreen,
      );
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('pings')
          .doc(pingId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final firestoreImage = pingmeeFirstPingMediaImageFromData(data);
        final image = firestoreImage.isNotEmpty ? firestoreImage : streamImage;

        final categoryStyle = pingmeePingCategoryStyleFromData(data);

        return _box(
          imageUrl: image,
          fallbackIcon: categoryStyle.icon,
          fallbackColor: categoryStyle.color,
        );
      },
    );
  }
}