import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/features/chat/chat_display_helpers.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ping_files/features/chat/stream_video_service.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart' as video_sdk;
import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:giphy_get/giphy_get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';

const String kPingmeeGiphyApiKey = 'g3wdgZSfWXCPsRDJn4fosL6bXjtYgQXJ';

enum _OpenChatMuteDurationChoice {
  oneHour,
  eightHours,
  twentyFourHours,
  forever,
}

void _logChatError(
  String label,
  Object error, [
  StackTrace? stackTrace,
]) {
  debugPrint('❌ $label: $error');

  if (stackTrace != null) {
    debugPrintStack(stackTrace: stackTrace);
  }
}

String _friendlyChatErrorMessage(
  Object error, {
  required String fallback,
}) {
  final raw = error.toString().toLowerCase();

  if (raw.contains('timeout') || raw.contains('timed out')) {
    return 'This is taking too long. Check your connection and try again.';
  }

  if (raw.contains('network') ||
      raw.contains('socket') ||
      raw.contains('connection') ||
      raw.contains('host lookup')) {
    return 'No stable internet connection. Try again in a moment.';
  }

  if (raw.contains('permission') ||
      raw.contains('denied') ||
      raw.contains('unauthorized')) {
    return 'Permission denied. Please check your access and try again.';
  }

  if (raw.contains('too large') ||
      raw.contains('size') ||
      raw.contains('413')) {
    return 'That file is too large to send.';
  }

  if (raw.contains('cancel')) {
    return 'Action cancelled.';
  }

  return fallback;
}

void _showChatSnack(
  BuildContext context,
  String message,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;

  messenger.hideCurrentSnackBar();

  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}

firestore.DocumentReference<Map<String, dynamic>>? _openChatPrefsRefFor(
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

firestore.DocumentReference<Map<String, dynamic>>?
    _outgoingMessageRequestRefForContext(BuildContext context) {
  final myUid = fb.FirebaseAuth.instance.currentUser?.uid;
  if (myUid == null || myUid.isEmpty) return null;

  final channel = StreamChannel.of(context).channel;

  if (pingmeeIsPingChannel(channel)) {
    return null;
  }

  final person = pingmeeOtherDmPerson(
    context: context,
    channel: channel,
  );

  final otherUid = person.id.trim();
  if (otherUid.isEmpty) return null;

  return firestore.FirebaseFirestore.instance
      .collection('users')
      .doc(myUid)
      .collection('message_requests_out')
      .doc(otherUid);
}

bool _isPendingOutgoingRequest(Map<String, dynamic>? data) {
  if (data == null) return false;

  final status = (data['status'] ?? '').toString().trim().toLowerCase();

  return status == 'pending';
}

int _requestMessageCount(Map<String, dynamic>? data) {
  final raw = data?['messageCount'];
  if (raw is num) return raw.toInt();
  return 0;
}

int _requestMaxMessages(Map<String, dynamic>? data) {
  final raw = data?['maxMessages'];
  if (raw is num && raw.toInt() > 0) return raw.toInt();
  return 3;
}

int _requestMessagesRemaining(Map<String, dynamic>? data) {
  final max = _requestMaxMessages(data);
  final count = _requestMessageCount(data);

  return (max - count).clamp(0, max);
}

String _requestRemainingText(int remaining) {
  switch (remaining) {
    case 0:
      return 'You have no messages left.';
    case 1:
      return 'You have one message left.';
    case 2:
      return 'You have two messages left.';
    case 3:
      return 'You have three messages left.';
    default:
      return 'You have $remaining messages left.';
  }
}

Future<void> _logPingChatActivity({
  required String pingId,
  required String type,
  required String title,
  String subtitle = "",
  Map<String, dynamic>? extra,
}) async {
  final actorUid = fb.FirebaseAuth.instance.currentUser?.uid;
  if (actorUid == null || actorUid.trim().isEmpty) return;

  try {
    await firestore.FirebaseFirestore.instance
        .collection("pings")
        .doc(pingId)
        .collection("activity")
        .add({
      "type": type,
      "title": title,
      "subtitle": subtitle,
      "actorUid": actorUid,
      "source": "ping_chat",
      "createdAt": firestore.FieldValue.serverTimestamp(),
      "extra": extra ?? <String, dynamic>{},
    });
  } catch (error) {
    debugPrint("❌ log ping chat activity failed: $error");
  }
}

Future<bool> _tryConsumeOutgoingRequestMessageSlot(
  BuildContext context,
) async {
  final myUid = fb.FirebaseAuth.instance.currentUser?.uid;
  final outRef = _outgoingMessageRequestRefForContext(context);

  if (myUid == null || myUid.isEmpty || outRef == null) {
    return true;
  }

  final db = firestore.FirebaseFirestore.instance;
  var allowed = true;

  await db.runTransaction((tx) async {
    final outSnap = await tx.get(outRef);
    final data = outSnap.data();

    // No pending outgoing request = normal accepted/non-request chat.
    if (!_isPendingOutgoingRequest(data)) {
      allowed = true;
      return;
    }

    final count = _requestMessageCount(data);
    final max = _requestMaxMessages(data);

    if (count >= max) {
      allowed = false;
      return;
    }

    final fromUid = (data?['fromUid'] ?? myUid).toString().trim();
    final toUid = (data?['toUid'] ?? '').toString().trim();

    if (fromUid.isEmpty || toUid.isEmpty) {
      allowed = false;
      return;
    }

    final nextCount = count + 1;
    final now = firestore.FieldValue.serverTimestamp();

    tx.set(
      outRef,
      {
        'messageCount': nextCount,
        'maxMessages': max,
        'updatedAt': now,
      },
      firestore.SetOptions(merge: true),
    );

    final incomingRef = db
        .collection('users')
        .doc(toUid)
        .collection('message_requests_in')
        .doc(fromUid);

    tx.set(
      incomingRef,
      {
        'messageCount': nextCount,
        'maxMessages': max,
        'updatedAt': now,
      },
      firestore.SetOptions(merge: true),
    );
  });

  if (!allowed && context.mounted) {
    _showChatSnack(
      context,
      'You have used all 3 request messages. Wait for them to accept your request.',
    );

    HapticFeedback.mediumImpact();
  }

  return allowed;
}

Future<void> _archiveOpenChat({
  required BuildContext context,
  required Channel channel,
}) async {
  final ref = _openChatPrefsRefFor(channel);

  if (ref == null) {
    _showChatSnack(context, 'Could not archive this chat.');
    return;
  }

  try {
    await ref.set({
      'archived': true,
      'archivedAt': firestore.FieldValue.serverTimestamp(),
      'updatedAt': firestore.FieldValue.serverTimestamp(),
    }, firestore.SetOptions(merge: true));

    if (!context.mounted) return;

    Navigator.of(context).pop();
    _showChatSnack(context, 'Chat archived.');
  } catch (error) {
    if (!context.mounted) return;
    _showChatSnack(context, 'Could not archive chat: $error');
  }
}

Future<void> _deleteOpenChat({
  required BuildContext context,
  required Channel channel,
}) async {
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

    if (!context.mounted) return;

    Navigator.of(context).pop();
    _showChatSnack(context, 'Chat deleted.');
  } catch (error) {
    if (!context.mounted) return;
    _showChatSnack(context, 'Could not delete chat: $error');
  }
}

DateTime? _openChatPrefsMutedUntil(Map<String, dynamic>? data) {
  final value = data?['mutedUntil'];

  if (value is firestore.Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}

bool _openChatPrefsMuted(Map<String, dynamic>? data) {
  if (data?['muted'] != true) return false;

  final until = _openChatPrefsMutedUntil(data);

  // No mutedUntil means muted until changed.
  if (until == null) return true;

  return until.isAfter(DateTime.now());
}

Future<void> _setOpenChatMuted({
  required Channel channel,
  required DateTime? mutedUntil,
}) async {
  final ref = _openChatPrefsRefFor(channel);

  await channel.mute();

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

Future<void> _clearOpenChatMuted(Channel channel) async {
  final ref = _openChatPrefsRefFor(channel);

  await channel.unmute();

  if (ref == null) return;

  await ref.set({
    'muted': false,
    'mutedUntil': firestore.FieldValue.delete(),
    'mutedAt': firestore.FieldValue.delete(),
    'mutedSeenMessageId': firestore.FieldValue.delete(),
    'mutedSeenMessageAt': firestore.FieldValue.delete(),
    'mutedSeenLastMessageAt': firestore.FieldValue.delete(),
    'unmutedAt': firestore.FieldValue.serverTimestamp(),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

Future<_OpenChatMuteDurationChoice?> _showOpenChatMuteDurationSheet(
  BuildContext context,
) {
  return showModalBottomSheet<_OpenChatMuteDurationChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      void pick(_OpenChatMuteDurationChoice choice) {
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

              _OpenChatSheetRow(
                icon: PhosphorIcons.clock(PhosphorIconsStyle.light),
                title: 'For 1 hour',
                onTap: () => pick(_OpenChatMuteDurationChoice.oneHour),
              ),

              const SizedBox(height: 8),

              _OpenChatSheetRow(
                icon: PhosphorIcons.clockCountdown(PhosphorIconsStyle.light),
                title: 'For 8 hours',
                onTap: () => pick(_OpenChatMuteDurationChoice.eightHours),
              ),

              const SizedBox(height: 8),

              _OpenChatSheetRow(
                icon: PhosphorIcons.calendarBlank(PhosphorIconsStyle.light),
                title: 'For 24 hours',
                onTap: () => pick(_OpenChatMuteDurationChoice.twentyFourHours),
              ),

              const SizedBox(height: 8),

              _OpenChatSheetRow(
                icon: PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
                title: 'Until I change it',
                onTap: () => pick(_OpenChatMuteDurationChoice.forever),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _openPingIdFromChannel(Channel channel) {
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

String _openPingPinnedMessageFromData(Map<String, dynamic>? data) {
  final chatConfig = Map<String, dynamic>.from(
    data?['chatConfig'] ?? {},
  );

  return (chatConfig['pinnedMessage'] ?? '').toString().trim();
}

bool _openPingReadOnlyFromData(Map<String, dynamic>? data) {
  final chatConfig = Map<String, dynamic>.from(
    data?['chatConfig'] ?? {},
  );

  return chatConfig['readOnly'] == true;
}

DateTime? _openChatDateFromValue(Object? value) {
  if (value is firestore.Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

DateTime? _openPingEndsAtFromData(Map<String, dynamic>? data) {
  return _openChatDateFromValue(data?['endsAt']);
}

DateTime? _openPingChatReadOnlyAtFromData(Map<String, dynamic>? data) {
  return _openChatDateFromValue(data?['chatReadOnlyAt']);
}

bool _openPingExpiredButStillWritable(Map<String, dynamic>? data) {
  final endsAt = _openPingEndsAtFromData(data);
  final readOnlyAt = _openPingChatReadOnlyAtFromData(data);

  if (endsAt == null || readOnlyAt == null) return false;

  final now = DateTime.now();

  return now.isAfter(endsAt) && now.isBefore(readOnlyAt);
}

int _openPingSlowModeSecondsFromData(Map<String, dynamic>? data) {
  final chatConfig = Map<String, dynamic>.from(
    data?['chatConfig'] ?? {},
  );

  final raw = chatConfig['slowModeSeconds'];

  if (raw is num && raw.toInt() > 0) {
    return raw.toInt();
  }

  return 0;
}

DateTime? _openChatLastPingMessageAtFromPrefs(Map<String, dynamic>? data) {
  final value = data?['lastPingMessageAt'];

  if (value is firestore.Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}

int _openChatSlowModeRemainingSeconds({
  required DateTime? lastSentAt,
  required int slowModeSeconds,
}) {
  if (lastSentAt == null) return 0;
  if (slowModeSeconds <= 0) return 0;

  final unlockAt = lastSentAt.add(Duration(seconds: slowModeSeconds));
  final remaining = unlockAt.difference(DateTime.now()).inSeconds;

  return remaining > 0 ? remaining : 0;
}

Future<void> _markPingSlowModeSent(Channel channel) async {
  final ref = _openChatPrefsRefFor(channel);
  if (ref == null) return;

  await ref.set({
    'lastPingMessageAt': firestore.FieldValue.serverTimestamp(),
    'updatedAt': firestore.FieldValue.serverTimestamp(),
  }, firestore.SetOptions(merge: true));
}

String _openPingCreatorIdFromData(Map<String, dynamic>? data) {
  return (data?['creatorId'] ?? '').toString().trim();
}

class PingmeeChatChannelPage extends StatefulWidget {
  const PingmeeChatChannelPage({super.key});

  @override
  State<PingmeeChatChannelPage> createState() => _PingmeeChatChannelPageState();
}

class _PingmeeChatChannelPageState extends State<PingmeeChatChannelPage> {
  bool _didMarkRead = false;

  late final StreamMessageInputController _messageInputController =
      StreamMessageInputController();

  void _setQuotedMessage(Message message) {
    _messageInputController.quotedMessage = message;
  }

  void _clearQuotedMessage() {
    _messageInputController.clearQuotedMessage();
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markChannelReadOnce();
      _prepareGalleryPermission();
    });
  }

  Future<void> _prepareGalleryPermission() async {
    if (!Platform.isAndroid) return;

    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      if (sdkInt >= 33) {
        final statuses = await [
          Permission.photos,
          Permission.videos,
        ].request();

        final photosDenied = statuses[Permission.photos]?.isDenied == true ||
            statuses[Permission.photos]?.isPermanentlyDenied == true;

        final videosDenied = statuses[Permission.videos]?.isDenied == true ||
            statuses[Permission.videos]?.isPermanentlyDenied == true;

        debugPrint(
          '📸 Gallery permissions Android $sdkInt: '
          'photos=${statuses[Permission.photos]}, '
          'videos=${statuses[Permission.videos]}',
        );

        if (photosDenied && videosDenied) {
          debugPrint('❌ Gallery media permission denied.');
        }

        return;
      }

      final status = await Permission.storage.request();

      debugPrint('📸 Gallery storage permission Android $sdkInt: $status');

      if (status.isDenied || status.isPermanentlyDenied) {
        debugPrint('❌ Storage/gallery permission denied.');
      }
    } catch (error, stack) {
      debugPrint('❌ Gallery permission prep failed: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> _markChannelReadOnce() async {
    if (!mounted || _didMarkRead) return;

    _didMarkRead = true;

    try {
      final channel = StreamChannel.of(context).channel;
      await channel.markRead();
    } catch (_) {
      // Do not crash chat because read-state failed.
    }
  }

  @override
  void dispose() {
    _messageInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Builder(
          builder: (context) {
            final channel = StreamChannel.of(context).channel;
            final isPingChannel = pingmeeIsPingChannel(channel);

            if (!isPingChannel) {
              return Column(
                children: [
                  const _PingmeeDmHeader(),

                  Expanded(
                    child: _PingmeeMessageList(
                      onSwipeReply: _setQuotedMessage,
                      canReply: true,
                    ),
                  ),

                  _PingmeeThemedMessageInput(
                    messageInputController: _messageInputController,
                    onQuotedMessageCleared: _clearQuotedMessage,
                  ),
                ],
              );
            }

            final pingId = _openPingIdFromChannel(channel);

            if (pingId.isEmpty) {
              return Column(
                children: [
                  _PingmeePingHeader(channel: channel),

                  Expanded(
                    child: _PingmeeMessageList(
                      onSwipeReply: _setQuotedMessage,
                      canReply: true,
                    ),
                  ),

                  _PingmeeThemedMessageInput(
                    messageInputController: _messageInputController,
                    onQuotedMessageCleared: _clearQuotedMessage,
                  ),
                ],
              );
            }

            return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
              stream: firestore.FirebaseFirestore.instance
                  .collection('pings')
                  .doc(pingId)
                  .snapshots(),
              builder: (context, snap) {
                final pingData = snap.data?.data();

                final readOnly = _openPingReadOnlyFromData(pingData);
                final expiredButStillWritable =
                    _openPingExpiredButStillWritable(pingData);
                final creatorId = _openPingCreatorIdFromData(pingData);
                final currentUid =
                    fb.FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

                final isHost =
                    creatorId.isNotEmpty && currentUid.isNotEmpty && currentUid == creatorId;

                final canSend = !readOnly || isHost;

                final slowModeSeconds = isHost
                    ? 0
                    : _openPingSlowModeSecondsFromData(pingData);

                if (!canSend) {
                  _messageInputController.clearQuotedMessage();
                }

                return Column(
                  children: [
                    _PingmeePingHeader(channel: channel),

                    _PingChatTopNoticeRotator(
                      channel: channel,
                      showExpiredWarning: expiredButStillWritable,
                    ),

                    Expanded(
                      child: _PingmeeMessageList(
                        onSwipeReply: _setQuotedMessage,
                        canReply: canSend,
                      ),
                    ),

                    if (canSend)
                      _PingSlowModeComposerGate(
                        channel: channel,
                        slowModeSeconds: slowModeSeconds,
                        child: _PingmeeThemedMessageInput(
                          messageInputController: _messageInputController,
                          onQuotedMessageCleared: _clearQuotedMessage,
                          allowPolls: true,
                          preMessageSending: (message) {
                            if (slowModeSeconds > 0) {
                              unawaited(_markPingSlowModeSent(channel));
                            }

                            return message;
                          },
                          onAnyMessageSent: () {
                            if (slowModeSeconds > 0) {
                              unawaited(_markPingSlowModeSent(channel));
                            }
                          },
                        ),
                      )
                    else
                      const _PingReadOnlyComposerLock(),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

bool _isVoiceAttachment(Attachment attachment) {
  final type = (attachment.type ?? '').toString().toLowerCase();
  final extraType =
      (attachment.extraData['type'] ?? '').toString().toLowerCase();
  final mimeType =
      (attachment.extraData['mime_type'] ??
              attachment.extraData['mimeType'] ??
              '')
          .toString()
          .toLowerCase();

  return attachment.isVoiceRecording ||
      type.contains('voice') ||
      type.contains('audio') ||
      extraType.contains('voice') ||
      extraType.contains('audio') ||
      mimeType.startsWith('audio/');
}

Attachment? _voiceAttachmentFromMessage(Message message) {
  for (final attachment in message.attachments) {
    if (_isVoiceAttachment(attachment)) return attachment;
  }
  return null;
}

String _voiceAttachmentUrl(Attachment attachment) {
  final candidates = <Object?>[
    attachment.assetUrl,
    attachment.titleLink,
    attachment.imageUrl,
    attachment.thumbUrl,

    attachment.extraData['asset_url'],
    attachment.extraData['assetUrl'],
    attachment.extraData['audio_url'],
    attachment.extraData['audioUrl'],
    attachment.extraData['url'],
    attachment.extraData['file'],
    attachment.extraData['file_url'],
    attachment.extraData['fileUrl'],
  ];

  for (final item in candidates) {
    final value = (item ?? '').toString().trim();

    if (value.isEmpty) continue;

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
  }

  return '';
}

String _readGiphyText(Object? Function() read) {
  try {
    return (read() ?? '').toString().trim();
  } catch (_) {
    return '';
  }
}

String _tryReadGiphyUrl(Object? Function() read) {
  final value = _readGiphyText(read);

  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }

  return '';
}

String _bestGiphyUrl(GiphyGif gif) {
  final dynamic g = gif;

  final candidates = [
    _tryReadGiphyUrl(() => g.images?.original?.url),
    _tryReadGiphyUrl(() => g.images?.downsized?.url),
    _tryReadGiphyUrl(() => g.images?.fixedHeight?.url),
    _tryReadGiphyUrl(() => g.images?.fixedWidth?.url),
    _tryReadGiphyUrl(() => g.images?.previewGif?.url),
  ];

  for (final url in candidates) {
    if (url.isNotEmpty) return url;
  }

  return '';
}

String _bestGiphyPreviewUrl(GiphyGif gif) {
  final dynamic g = gif;

  final candidates = [
    _tryReadGiphyUrl(() => g.images?.fixedHeightSmallStill?.url),
    _tryReadGiphyUrl(() => g.images?.fixedWidthSmallStill?.url),
    _tryReadGiphyUrl(() => g.images?.downsizedStill?.url),
    _tryReadGiphyUrl(() => g.images?.originalStill?.url),
    _tryReadGiphyUrl(() => g.images?.previewGif?.url),
  ];

  for (final url in candidates) {
    if (url.isNotEmpty) return url;
  }

  return _bestGiphyUrl(gif);
}

Duration _voiceAttachmentDuration(Attachment attachment) {
  int? readInt(Object? value) {
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  final ms =
      readInt(attachment.extraData['duration_ms']) ??
      readInt(attachment.extraData['durationMs']) ??
      readInt(attachment.extraData['duration']);

  if (ms != null && ms > 0) {
    return Duration(milliseconds: ms);
  }

  final seconds =
      readInt(attachment.extraData['duration_seconds']) ??
      readInt(attachment.extraData['durationSeconds']);

  if (seconds != null && seconds > 0) {
    return Duration(seconds: seconds);
  }

  return Duration.zero;
}

class _PingmeeMessageList extends StatelessWidget {
  const _PingmeeMessageList({
    required this.onSwipeReply,
    required this.canReply,
  });

  final ValueChanged<Message> onSwipeReply;
  final bool canReply;

  String _bestMessageUserName(User? user) {
    if (user == null) return 'Pingmee user';

    final fullName = (user.extraData['fullName'] ?? '').toString().trim();
    final displayName = (user.extraData['displayName'] ?? '').toString().trim();
    final name = (user.name).toString().trim();

    final firstName = (user.extraData['firstName'] ?? '').toString().trim();
    final lastName = (user.extraData['lastName'] ?? '').toString().trim();

    final combinedName = [firstName, lastName]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .trim();

    if (fullName.isNotEmpty) return fullName;
    if (displayName.isNotEmpty) return displayName;
    if (name.isNotEmpty && name != user.id) return name;
    if (combinedName.isNotEmpty) return combinedName;

    return 'Pingmee user';
  }

  String _bestMessageUserImage(User? user) {
    if (user == null) return '';

    final image = (user.image ?? '').toString().trim();
    final photoUrl = (user.extraData['photoUrl'] ?? '').toString().trim();
    final photoURL = (user.extraData['photoURL'] ?? '').toString().trim();
    final profilePhotoUrl =
        (user.extraData['profilePhotoUrl'] ?? '').toString().trim();
    final avatarUrl = (user.extraData['avatarUrl'] ?? '').toString().trim();

    if (image.isNotEmpty) return image;
    if (photoUrl.isNotEmpty) return photoUrl;
    if (photoURL.isNotEmpty) return photoURL;
    if (profilePhotoUrl.isNotEmpty) return profilePhotoUrl;
    if (avatarUrl.isNotEmpty) return avatarUrl;

    return '';
  }

  Widget _replyWrap({
    required Message message,
    required bool isMyMessage,
    required Widget child,
  }) {
    if (!canReply) return child;

    return _SwipeReplyWrapper(
      message: message,
      isMyMessage: isMyMessage,
      onReply: onSwipeReply,
      child: child,
    );
  }

  String _bestMessageUserProfileUid(User? user) {
    if (user == null) return '';

    final candidates = <Object?>[
      user.extraData['uid'],
      user.extraData['userId'],
      user.extraData['firebaseUid'],
      user.extraData['profileUid'],
      user.id,
    ];

    for (final item in candidates) {
      final value = (item ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }

    return '';
  }

  void _openMessageUserProfile(
    BuildContext context,
    User? user,
  ) {
    final channel = StreamChannel.of(context).channel;

    // Only do this inside ping group chats.
    if (!pingmeeIsPingChannel(channel)) return;

    final profileUid = _bestMessageUserProfileUid(user);

    if (profileUid.isEmpty) {
      _showChatSnack(context, 'Could not open this profile.');
      return;
    }

    HapticFeedback.selectionClick();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileTab(
          profileUid: profileUid,
        ),
      ),
    );
  }

  Widget _buildMessageAvatar(BuildContext context, User? user) {
    final imageUrl = _bestMessageUserImage(user);
    final name = _bestMessageUserName(user);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

    Widget fallback() {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.brandGreen.withOpacity(.12),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.brandGreen,
          ),
        ),
      );
    }

    Widget avatar;

    if (imageUrl.isEmpty) {
      avatar = fallback();
    } else {
      avatar = SizedBox(
        width: 34,
        height: 34,
        child: ClipOval(
          child: Image.network(
            imageUrl,
            width: 34,
            height: 34,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (_, __, ___) => fallback(),
          ),
        ),
      );
    }

    final channel = StreamChannel.of(context).channel;
    final canOpenProfile = pingmeeIsPingChannel(channel) &&
        _bestMessageUserProfileUid(user).isNotEmpty;

    if (!canOpenProfile) {
      return avatar;
    }

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _openMessageUserProfile(context, user),
        child: avatar,
      ),
    );
  }

  Widget _buildCustomMessageShell({
    required BuildContext context,
    required Message message,
    required bool isMyMessage,
    required Widget child,
  }) {
    final user = message.user;
    final senderName = _bestMessageUserName(user);

    if (isMyMessage) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(56, 4, 12, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(child: child),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 56, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildMessageAvatar(context, user),

          const SizedBox(width: 8),

          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 11.8,
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withOpacity(.45),
                  ),
                ),

                const SizedBox(height: 3),

                child,
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _hasTextMention(Message message) {
    final text = (message.text ?? '').trim();
    return text.contains('@') && message.attachments.isEmpty;
  }

  bool _hasAnyAttachment(Message message) {
    return message.attachments.isNotEmpty;
  }

  Attachment? _giphyStickerAttachmentFromMessage(Message message) {
    for (final attachment in message.attachments) {
      final type = (attachment.type ?? '').toLowerCase();

      if (attachment.extraData['pingmeeSticker'] == true ||
          type == 'sticker') {
        return attachment;
      }
    }

    return null;
  }

  bool _isOldestLoadedMessage({
    required Message message,
    required List<Message> messages,
  }) {
    if (messages.isEmpty) return false;

    Message? oldest;

    for (final item in messages) {
      final itemTime = item.createdAt ?? item.updatedAt;

      if (itemTime == null) continue;

      final oldestTime = oldest?.createdAt ?? oldest?.updatedAt;

      if (oldest == null || oldestTime == null || itemTime.isBefore(oldestTime)) {
        oldest = item;
      }
    }

    return oldest?.id == message.id;
  }

  Future<void> _sendStarterMessage(
    BuildContext context,
    String text,
  ) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    try {
      final channel = StreamChannel.of(context).channel;

      await channel.sendMessage(
        Message(text: cleanText),
      );

      HapticFeedback.selectionClick();
    } catch (error) {
      _showChatSnack(
        context,
        'Could not send message. Try again.',
      );
    }
  }

  Widget _buildEmptyChatState(BuildContext context) {
    final channel = StreamChannel.of(context).channel;

    if (pingmeeIsPingChannel(channel)) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
        physics: const BouncingScrollPhysics(),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen.withOpacity(.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      PhosphorIcons.chatsCircle(PhosphorIconsStyle.fill),
                      size: 25,
                      color: AppColors.brandGreen,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'No messages yet',
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
                  'Start the conversation for this ping.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                    color: Colors.black.withOpacity(.52),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final person = pingmeeOtherDmPerson(
      context: context,
      channel: channel,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
      physics: const BouncingScrollPhysics(),
      children: [
        if (person.id.trim().isNotEmpty)
          _ChatTopProfileCard(
            person: person,
          ),

        _ChatConnectionStarterCard(
          person: person,
          onSendStarter: (text) => _sendStarterMessage(context, text),
        ),
      ],
    );
  }

  Widget _withTopProfileCardIfNeeded({
    required BuildContext context,
    required Message message,
    required List<Message> messages,
    required Widget child,
  }) {
    final shouldShowCard = _isOldestLoadedMessage(
      message: message,
      messages: messages,
    );

    if (!shouldShowCard) return child;

    final channel = StreamChannel.of(context).channel;

    if (pingmeeIsPingChannel(channel)) {
      return child;
    }

    final person = pingmeeOtherDmPerson(
      context: context,
      channel: channel,
    );

    if (person.id.trim().isEmpty) return child;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ChatTopProfileCard(
          person: person,
        ),
        child,
      ],
    );
  }

  bool _isBigEmojiMessage(Message message) {
    return message.extraData['pingmeeBigEmoji'] == true;
  }

  void _openForwardSheet(BuildContext context, Message sourceMessage) {
    final sourceChannel = StreamChannel.of(context).channel;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _ForwardMessageSheet(
          sourceMessage: sourceMessage,
          sourceChannelCid: sourceChannel.cid ?? '',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = StreamChatTheme.of(context);

    final greenColorTheme = baseTheme.colorTheme.copyWith(
      accentPrimary: AppColors.brandGreen,
    );

    final normalTheme = baseTheme.copyWith(
      colorTheme: greenColorTheme,
      ownMessageTheme: StreamMessageThemeData(
        messageBackgroundColor: const Color(0xFFE9EDF2),
        messageTextStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15.6,
          fontWeight: FontWeight.w500,
          color: Color(0xFF111827),
          height: 1.28,
        ),
        messageBorderColor: Colors.transparent,
      ),
      otherMessageTheme: StreamMessageThemeData(
        messageBackgroundColor: Colors.white,
        messageTextStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15.6,
          fontWeight: FontWeight.w500,
          color: Color(0xFF111827),
          height: 1.28,
        ),
        messageBorderColor: const Color(0xFFE2E8F0),
      ),
    );

    final mediaOnlyTheme = baseTheme.copyWith(
      colorTheme: greenColorTheme,
      ownMessageTheme: StreamMessageThemeData(
        messageBackgroundColor: Colors.transparent,
        messageBorderColor: Colors.transparent,
        messageTextStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15.6,
          fontWeight: FontWeight.w500,
          color: Colors.white,
          height: 1.28,
        ),
      ),
      otherMessageTheme: StreamMessageThemeData(
        messageBackgroundColor: Colors.transparent,
        messageBorderColor: Colors.transparent,
        messageTextStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15.6,
          fontWeight: FontWeight.w500,
          color: Color(0xFF111827),
          height: 1.28,
        ),
      ),
    );

    final greenMaterialTheme = Theme.of(context).copyWith(
      colorScheme: Theme.of(context).colorScheme.copyWith(
        primary: AppColors.brandGreen,
        secondary: AppColors.brandGreen,
        tertiary: AppColors.brandGreen,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return AppColors.brandGreen;
          }

          return Colors.transparent;
        }),
        checkColor: MaterialStateProperty.all(Colors.white),
        side: BorderSide(
          color: AppColors.brandGreen.withOpacity(.55),
          width: 1.6,
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return AppColors.brandGreen;
          }

          return Colors.black.withOpacity(.35);
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppColors.brandGreen,
        linearTrackColor: AppColors.brandGreen.withOpacity(.12),
      ),
    );

    return Theme(
      data: greenMaterialTheme,
      child: StreamChatTheme(
        data: normalTheme,
        child: StreamMessageListView(
        emptyBuilder: (context) {
          return _buildEmptyChatState(context);
        },
        threadBuilder: (context, parentMessage) {
          final safeParentMessage = parentMessage;

          if (safeParentMessage == null) {
            return const Scaffold(
              backgroundColor: Colors.white,
              body: Center(
                child: Text(
                  'Could not open thread.',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            );
          }

          return _PingmeeThreadPage(parentMessage: safeParentMessage);
        },
        messageBuilder: (context, details, messages, defaultMessage) {
          final message = details.message;

          if (_hasTextMention(message)) {
            final mentionBubble = _PingmeeMentionTextBubble(
              message: message,
              isMe: details.isMyMessage,
            );

            return _withTopProfileCardIfNeeded(
              context: context,
              message: message,
              messages: messages,
              child: _replyWrap(
                message: message,
                isMyMessage: details.isMyMessage,
                child: mentionBubble,
              ),
            ); 
          }
          if (_isBigEmojiMessage(message)) {
          final bigEmoji = _PingmeeBigEmojiBubble(
            emoji: (message.text ?? '').trim(),
            isMe: details.isMyMessage,
          );

          return _withTopProfileCardIfNeeded(
            context: context,
            message: message,
            messages: messages,
            child: _replyWrap(
              message: message,
              isMyMessage: details.isMyMessage,
              child: bigEmoji,
            ),
          );                                    
        }

        final stickerAttachment = _giphyStickerAttachmentFromMessage(message);

        if (stickerAttachment != null) {
          final stickerBubble = _PingmeeGiphyStickerBubble(
            attachment: stickerAttachment,
            isMe: details.isMyMessage,
          );

          return _withTopProfileCardIfNeeded(
            context: context,
            message: message,
            messages: messages,
            child: _replyWrap(
              message: message,
              isMyMessage: details.isMyMessage,
              child: stickerBubble,
            ),
          );
        }

          final voiceAttachment = _voiceAttachmentFromMessage(message);

          if (voiceAttachment != null) {
            final voiceBubble = _PingmeeVoiceMessageBubble(
              attachment: voiceAttachment,
              isMe: details.isMyMessage,
              url: _voiceAttachmentUrl(voiceAttachment),
              initialDuration: _voiceAttachmentDuration(voiceAttachment),
            );

            final voiceMessageWithSender = _buildCustomMessageShell(
              context: context,
              message: message,
              isMyMessage: details.isMyMessage,
              child: voiceBubble,
            );

            return _withTopProfileCardIfNeeded(
              context: context,
              message: message,
              messages: messages,
              child: _replyWrap(
                message: message,
                isMyMessage: details.isMyMessage,
                child: voiceMessageWithSender,
              ),
            );
          }

          debugPrint(
            '🧪 Pingmee messageBuilder fired '
            'id=${message.id} '
            'text="${message.text}" '
            'attachments=${message.attachments.length} '
            'types=${message.attachments.map((a) => a.type).join(",")} '
            'isMine=${details.isMyMessage}',
          );

          final controlledMessage = defaultMessage.copyWith(
            userAvatarBuilder: _buildMessageAvatar,
            showFlagButton: !details.isMyMessage,
            showEditMessage: details.isMyMessage,
            showCopyMessage: true,
            showDeleteMessage: false,
            showReplyMessage: canReply,
            showThreadReplyMessage: false,
            customActions: [
              StreamMessageAction(
                leading: Icon(
                  PhosphorIcons.chatTeardropText(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                  size: 21,
                ),
                title: const Text(
                  'Reply in thread',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111827),
                  ),
                ),
                onTap: (message) {
                  final safeMessage = message;
                  if (safeMessage == null) return;

                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => StreamChannel(
                        channel: StreamChannel.of(context).channel,
                        child: _PingmeeThreadPage(parentMessage: safeMessage),
                      ),
                    ),
                  );
                },
              ),
              StreamMessageAction(
                leading: Icon(
                  PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.light),
                  color: const Color(0xFF111827),
                  size: 21,
                ),
                title: const Text(
                  'Forward',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: (message) {
                  final safeMessage = message;

                  if (safeMessage == null) return;

                  _openForwardSheet(context, safeMessage);
                },
              ),
            ],
          );

          final swipeWrappedMessage = _replyWrap(
            message: message,
            isMyMessage: details.isMyMessage,
            child: controlledMessage,
          );

          Widget finalMessage = swipeWrappedMessage;

          if (_hasAnyAttachment(message)) {
            finalMessage = StreamChatTheme(
              data: mediaOnlyTheme,
              child: swipeWrappedMessage,
            );
          }

          return _withTopProfileCardIfNeeded(
            context: context,
            message: message,
            messages: messages,
            child: finalMessage,
          );
        },
      ),
      )
    );
  }
}

class _PingmeePingHeader extends StatelessWidget {
  const _PingmeePingHeader({
    required this.channel,
  });

  final Channel channel;

  void _openPingInfo(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return StreamChannel(
            channel: channel,
            child: _PingChatInfoScreen(channel: channel),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = pingmeeChannelTitle(channel);
    final subtitle = pingmeePingChannelSubtitle(channel);

    return Container(
      height: 66,
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(.05),
          ),
        ),
      ),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Icon(
                  PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                  size: 22,
                  color: Colors.black.withOpacity(.82),
                ),
              ),
            ),
          ),

          const SizedBox(width: 4),

          Expanded(
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                onTap: () => _openPingInfo(context),
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      PingmeePingChannelAvatar(
                        channel: channel,
                        size: 42,
                        radius: 16,
                        iconSize: 22,
                      ),

                      const SizedBox(width: 10),

                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: Colors.black.withOpacity(.50),
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
          ),

          const SizedBox(width: 6),

          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => _openPingInfo(context),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  PhosphorIcons.info(PhosphorIconsStyle.bold),
                  size: 20,
                  color: Colors.black.withOpacity(.70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PingExpiredChatWarningBanner extends StatelessWidget {
  const _PingExpiredChatWarningBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7ED),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xFFF97316).withOpacity(.18),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFF97316).withOpacity(.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                PhosphorIcons.clockCountdown(PhosphorIconsStyle.fill),
                size: 16,
                color: const Color(0xFFF97316),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This ping has expired. Chat stays open for 3 days after expiry, then becomes read-only.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13.2,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: Colors.black.withOpacity(.66),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingChatTopNoticeRotator extends StatefulWidget {
  const _PingChatTopNoticeRotator({
    required this.channel,
    required this.showExpiredWarning,
  });

  final Channel channel;
  final bool showExpiredWarning;

  @override
  State<_PingChatTopNoticeRotator> createState() =>
      _PingChatTopNoticeRotatorState();
}

class _PingChatTopNoticeRotatorState extends State<_PingChatTopNoticeRotator> {
  late final PageController _controller;
  Timer? _timer;

  int _page = 1000;
  int _noticeCount = 0;
  bool _pinnedExpanded = false;

  @override
  void initState() {
    super.initState();

    _controller = PageController(
      initialPage: _page,
    );

    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (!mounted || !_controller.hasClients) return;
        if (_noticeCount < 2) return;

        // Let the user read the expanded pinned message.
        if (_pinnedExpanded) return;

        _page += 1;

        _controller.animateToPage(
          _page,
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
        );
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _togglePinnedExpanded() {
    HapticFeedback.selectionClick();

    setState(() {
      _pinnedExpanded = !_pinnedExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pingId = _openPingIdFromChannel(widget.channel);

    if (pingId.isEmpty) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('pings')
          .doc(pingId)
          .snapshots(),
      builder: (context, snap) {
        final pinnedMessage = _openPingPinnedMessageFromData(
          snap.data?.data(),
        );

        final hasPinned = pinnedMessage.isNotEmpty;

        final notices = <Widget>[
          if (hasPinned)
            _PingPinnedTopNoticeCard(
              pinnedMessage: pinnedMessage,
              expanded: _pinnedExpanded,
              onTap: _togglePinnedExpanded,
            ),

          if (widget.showExpiredWarning)
            const _PingExpiredTopNoticeCard(),
        ];

        _noticeCount = notices.length;

        if (notices.isEmpty) {
          return const SizedBox.shrink();
        }

        final visibleIndex = _noticeCount == 0 ? 0 : _page % _noticeCount;
        final showingPinned = hasPinned && visibleIndex == 0;

        final frameHeight =
            showingPinned && _pinnedExpanded ? 126.0 : 66.0;

        if (notices.length == 1) {
          return _PingTopNoticeFrame(
            height: frameHeight,
            child: notices.first,
          );
        }

        return _PingTopNoticeFrame(
          height: frameHeight,
          child: PageView.builder(
            controller: _controller,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (value) {
              setState(() {
                _page = value;
              });
            },
            itemBuilder: (context, index) {
              final safeIndex = index % notices.length;
              return notices[safeIndex];
            },
          ),
        );
      },
    );
  }
}

class _PingTopNoticeFrame extends StatelessWidget {
  const _PingTopNoticeFrame({
    required this.child,
    required this.height,
  });

  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: height,
        child: child,
      ),
    );
  }
}

class _PingTopNoticePager extends StatefulWidget {
  const _PingTopNoticePager({
    required this.notices,
  });

  final List<Widget> notices;

  @override
  State<_PingTopNoticePager> createState() => _PingTopNoticePagerState();
}

class _PingTopNoticePagerState extends State<_PingTopNoticePager> {
  late final PageController _controller;
  Timer? _timer;
  int _page = 1000;

  @override
  void initState() {
    super.initState();

    _controller = PageController(
      initialPage: _page,
    );

    _startTimer();
  }

  @override
  void didUpdateWidget(covariant _PingTopNoticePager oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.notices.length != widget.notices.length) {
      _timer?.cancel();
      _startTimer();
    }
  }

  void _startTimer() {
    if (widget.notices.length < 2) return;

    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (!mounted || !_controller.hasClients) return;

        _page += 1;

        _controller.animateToPage(
          _page,
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
        );
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.notices.isEmpty) {
      return const SizedBox.shrink();
    }

    return PageView.builder(
      controller: _controller,
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (context, index) {
        final safeIndex = index % widget.notices.length;
        return widget.notices[safeIndex];
      },
    );
  }
}

class _PingPinnedTopNoticeCard extends StatelessWidget {
  const _PingPinnedTopNoticeCard({
    required this.pinnedMessage,
    required this.expanded,
    required this.onTap,
  });

  final String pinnedMessage;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F6F8),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.black.withOpacity(.045),
            ),
          ),
          child: Row(
            crossAxisAlignment:
                expanded ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Center(
                  child: Icon(
                    PhosphorIcons.pushPin(PhosphorIconsStyle.fill),
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Column(
                  mainAxisAlignment: expanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pinned by host',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        height: 1,
                      ),
                    ),

                    const SizedBox(height: 5),

                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Text(
                        pinnedMessage,
                        maxLines: expanded ? 5 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13.3,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(.62),
                          height: 1.22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Icon(
                expanded
                    ? PhosphorIcons.caretUp(PhosphorIconsStyle.bold)
                    : PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
                size: 17,
                color: Colors.black.withOpacity(.42),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PingExpiredTopNoticeCard extends StatelessWidget {
  const _PingExpiredTopNoticeCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF97316).withOpacity(.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFF97316).withOpacity(.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              PhosphorIcons.clockCountdown(PhosphorIconsStyle.fill),
              size: 17,
              color: const Color(0xFFF97316),
            ),
          ),

          const SizedBox(width: 10),

          Expanded(
            child: Text(
              'This ping has expired. Chat stays open for 3 days after expiry, then becomes read-only.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13.1,
                fontWeight: FontWeight.w700,
                height: 1.18,
                color: Colors.black.withOpacity(.66),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PingPinnedMessageBanner extends StatefulWidget {
  const _PingPinnedMessageBanner({
    required this.channel,
  });

  final Channel channel;

  @override
  State<_PingPinnedMessageBanner> createState() =>
      _PingPinnedMessageBannerState();
}

class _PingPinnedMessageBannerState extends State<_PingPinnedMessageBanner> {
  bool _expanded = false;

  void _toggleExpanded() {
    HapticFeedback.selectionClick();

    setState(() {
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pingId = _openPingIdFromChannel(widget.channel);

    if (pingId.isEmpty) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('pings')
          .doc(pingId)
          .snapshots(),
      builder: (context, snap) {
        final pinnedMessage = _openPingPinnedMessageFromData(
          snap.data?.data(),
        );

        if (pinnedMessage.isEmpty) {
          return const SizedBox.shrink();
        }

        return Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: _toggleExpanded,
              borderRadius: BorderRadius.circular(18),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.black.withOpacity(.045),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Icon(
                          PhosphorIcons.pushPin(PhosphorIconsStyle.fill),
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),

                    const SizedBox(width: 10),

                    Expanded(
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Pinned by host',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827),
                              ),
                            ),

                            const SizedBox(height: 3),

                            Text(
                              pinnedMessage,
                              maxLines: _expanded ? null : 3,
                              overflow: _expanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 13.4,
                                fontWeight: FontWeight.w500,
                                height: 1.32,
                                color: Colors.black.withOpacity(.66),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PingSlowModeComposerGate extends StatelessWidget {
  const _PingSlowModeComposerGate({
    required this.channel,
    required this.slowModeSeconds,
    required this.child,
  });

  final Channel channel;
  final int slowModeSeconds;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (slowModeSeconds <= 0) {
      return child;
    }

    final prefsRef = _openChatPrefsRefFor(channel);

    if (prefsRef == null) {
      return child;
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: prefsRef.snapshots(),
      builder: (context, prefsSnap) {
        final prefsData = prefsSnap.data?.data();

        return StreamBuilder<int>(
          stream: Stream<int>.periodic(
            const Duration(seconds: 1),
            (tick) => tick,
          ),
          builder: (context, tickSnap) {
            final lastSentAt = _openChatLastPingMessageAtFromPrefs(prefsData);

            final remaining = _openChatSlowModeRemainingSeconds(
              lastSentAt: lastSentAt,
              slowModeSeconds: slowModeSeconds,
            );

            if (remaining <= 0) {
              return child;
            }

            return _PingSlowModeComposerLock(
              remainingSeconds: remaining,
            );
          },
        );
      },
    );
  }
}

class _PingSlowModeComposerLock extends StatelessWidget {
  const _PingSlowModeComposerLock({
    required this.remainingSeconds,
  });

  final int remainingSeconds;

  @override
  Widget build(BuildContext context) {
    final label = remainingSeconds == 1
        ? 'You can send again in 1 second.'
        : 'You can send again in $remainingSeconds seconds.';

    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.black.withOpacity(.045),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Center(
                child: Icon(
                  PhosphorIcons.timer(PhosphorIconsStyle.fill),
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13.4,
                  fontWeight: FontWeight.w600,
                  height: 1.28,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingReadOnlyComposerLock extends StatelessWidget {
  const _PingReadOnlyComposerLock();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.black.withOpacity(.045),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Center(
                child: Icon(
                  PhosphorIcons.lockSimple(PhosphorIconsStyle.fill),
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                'This ping has ended or host made it read only. You can still view the conversation and shared content, but new messages are closed.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13.4,
                  fontWeight: FontWeight.w600,
                  height: 1.28,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingChatInfoScreen extends StatefulWidget {
  const _PingChatInfoScreen({
    required this.channel,
  });

  final Channel channel;

  @override
  State<_PingChatInfoScreen> createState() => _PingChatInfoScreenState();
}

class _PingChatInfoScreenState extends State<_PingChatInfoScreen> {
  bool _descriptionExpanded = false;

  String get _pingId {
    final fromExtra =
        (widget.channel.extraData['pingId'] ?? '').toString().trim();

    if (fromExtra.isNotEmpty) return fromExtra;

    final id = (widget.channel.id ?? '').toString().trim();

    if (id.startsWith('ping_') && id.length > 5) {
      return id.substring(5);
    }

    return '';
  }

  String _titleFromPing(Map<String, dynamic>? data) {
    final title = (data?['title'] ?? '').toString().trim();
    if (title.isNotEmpty) return title;

    return pingmeeChannelTitle(widget.channel);
  }

  String _descriptionFromPing(Map<String, dynamic>? data) {
    return (data?['description'] ?? '').toString().trim();
  }

  void _openSharedContent(String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return _SharedChatContentScreen(
            channel: widget.channel,
            person: PingmeeChatPerson(
              id: _pingId,
              name: title,
              image: '',
              online: false,
            ),
          );
        },
      ),
    );
  }

  Future<void> _mutePingChat() async {
    final choice = await _showOpenChatMuteDurationSheet(context);
    if (choice == null) return;

    final now = DateTime.now();

    DateTime? mutedUntil;

    switch (choice) {
      case _OpenChatMuteDurationChoice.oneHour:
        mutedUntil = now.add(const Duration(hours: 1));
        break;

      case _OpenChatMuteDurationChoice.eightHours:
        mutedUntil = now.add(const Duration(hours: 8));
        break;

      case _OpenChatMuteDurationChoice.twentyFourHours:
        mutedUntil = now.add(const Duration(hours: 24));
        break;

      case _OpenChatMuteDurationChoice.forever:
        mutedUntil = null;
        break;
    }

    try {
      await _setOpenChatMuted(
        channel: widget.channel,
        mutedUntil: mutedUntil,
      );

      if (!mounted) return;

      _showChatSnack(
        context,
        mutedUntil == null
            ? 'Ping chat muted until you change it.'
            : 'Ping chat muted.',
      );
    } catch (error) {
      if (!mounted) return;

      _showChatSnack(
        context,
        'Could not mute ping chat.',
      );
    }
  }

  Future<void> _unmutePingChat() async {
    try {
      await _clearOpenChatMuted(widget.channel);

      if (!mounted) return;

      _showChatSnack(context, 'Ping chat unmuted.');
    } catch (error) {
      if (!mounted) return;

      _showChatSnack(context, 'Could not unmute ping chat.');
    }
  }

  List<String> _huddleMemberIds() {
    final ids = <String>{};

    final currentUid = fb.FirebaseAuth.instance.currentUser?.uid.trim();

    if (currentUid != null && currentUid.isNotEmpty) {
      ids.add(currentUid);
    }

    final members = widget.channel.state?.members ?? const <Member>[];

    for (final member in members) {
      final id = (member.userId ?? member.user?.id ?? '').trim();

      if (id.isNotEmpty) {
        ids.add(id);
      }
    }

    return ids.toList()..sort();
  }

  Future<void> _startHuddle(String title) async {
    final pingId = _pingId.trim();

    if (pingId.isEmpty) {
      _showChatSnack(context, 'Could not start this huddle.');
      return;
    }

    unawaited(
      _logPingChatActivity(
        pingId: pingId,
        type: "ping_huddle_started",
        title: "Huddle started",
        subtitle: "A group video huddle was started from the ping chat.",
        extra: {
          "huddleTitle": title,
        },
      ),
    );

    final memberIds = _huddleMemberIds();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return _PingmeePingHuddleScreen(
            channel: widget.channel,
            pingId: pingId,
            title: title,
            memberIds: memberIds,
          );
        },
      ),
    );
  }

  Future<void> _viewPingDetails() async {
    final pingId = _pingId.trim();

    if (pingId.isEmpty) {
      _showChatSnack(context, 'Could not open this ping.');
      return;
    }

    await openPingDetailsSheet(
      context: context,
      pingId: pingId,
    );
  }                     

  void _showPingInfoMoreSheet() {
    final title = pingmeeChannelTitle(widget.channel);

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
              boxShadow: [
                BoxShadow(
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _OpenChatSheetRow(
                  icon: PhosphorIcons.mapPin(PhosphorIconsStyle.light),
                  title: 'View ping',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _viewPingDetails();
                  },
                ),

                const SizedBox(height: 8),

                _OpenChatSheetRow(
                  icon: PhosphorIcons.imageSquare(
                    PhosphorIconsStyle.light,
                  ),
                  title: 'Shared content',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openSharedContent(title);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }          

  void _showMoreMenu() {
    HapticFeedback.selectionClick();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
          stream: _openChatPrefsRefFor(widget.channel)?.snapshots(),
          builder: (context, prefsSnap) {
            final prefsData = prefsSnap.data?.data();
            final muted = _openChatPrefsMuted(prefsData);

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
                        _PingInfoChatHoldAction(
                          icon: PhosphorIcons.archive(
                            PhosphorIconsStyle.light,
                          ),
                          label: 'Archive',
                          onTap: () async {
                            Navigator.of(sheetContext).pop();

                            await _archiveOpenChat(
                              context: context,
                              channel: widget.channel,
                            );
                          },
                        ),

                        _PingInfoChatHoldAction(
                          icon: muted
                              ? PhosphorIcons.bell(
                                  PhosphorIconsStyle.light,
                                )
                              : PhosphorIcons.bellSlash(
                                  PhosphorIconsStyle.light,
                                ),
                          label: muted ? 'Unmute' : 'Mute',
                          onTap: () async {
                            Navigator.of(sheetContext).pop();

                            if (muted) {
                              await _unmutePingChat();
                            } else {
                              await _mutePingChat();
                            }
                          },
                        ),

                        _PingInfoChatHoldAction(
                          icon: PhosphorIcons.dotsThree(
                            PhosphorIconsStyle.bold,
                          ),
                          label: 'More',
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _showPingInfoMoreSheet();
                          },
                        ),

                        _PingInfoChatHoldAction(
                          icon: PhosphorIcons.trash(
                            PhosphorIconsStyle.light,
                          ),
                          label: 'Delete',
                          onTap: () async {
                            Navigator.of(sheetContext).pop();

                            await _deleteOpenChat(
                              context: context,
                              channel: widget.channel,
                            );
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pingId = _pingId;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              height: 62,
              padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
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
                          PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                          size: 22,
                          color: Colors.black.withOpacity(.80),
                        ),
                      ),
                    ),
                  ),

                  const Expanded(
                    child: Center(
                      child: Text(
                        'Ping info',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                  ),

                  Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      onTap: _showMoreMenu,
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          PhosphorIcons.dotsThree(
                            PhosphorIconsStyle.bold,
                          ),
                          size: 25,
                          color: Colors.black.withOpacity(.78),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: pingId.isEmpty
                  ? const Center(
                      child: Text(
                        'Could not load ping info.',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : StreamBuilder<
                      firestore.DocumentSnapshot<Map<String, dynamic>>>(
                      stream: firestore.FirebaseFirestore.instance
                          .collection('pings')
                          .doc(pingId)
                          .snapshots(),
                      builder: (context, snap) {
                        final data = snap.data?.data();
                        final title = _titleFromPing(data);
                        final description = _descriptionFromPing(data);

                        return ListView(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 120),
                          children: [
                            _PingInfoHeroCard(
                              channel: widget.channel,
                              title: title,
                              description: description,
                              expanded: _descriptionExpanded,
                              onToggleExpanded: () {
                                setState(() {
                                  _descriptionExpanded =
                                      !_descriptionExpanded;
                                });
                              },
                            ),

                            const SizedBox(height: 14),

                            Column(
                              children: [
                                _PingPrimaryActionCard(
                                  icon: PhosphorIcons.videoCamera,
                                  title: 'Start Huddle',
                                  subtitle: 'Hop into a group call with everyone in this ping',
                                  onTap: () => _startHuddle(title),
                                ),

                                const SizedBox(height: 10),

                                Row(
                                  children: [
                                    Expanded(
                                      child: StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
                                        stream: _openChatPrefsRefFor(widget.channel)?.snapshots(),
                                        builder: (context, prefsSnap) {
                                          final prefsData = prefsSnap.data?.data();
                                          final muted = _openChatPrefsMuted(prefsData);

                                          return _PingSecondaryActionCard(
                                            icon: muted ? PhosphorIcons.bell : PhosphorIcons.bellSlash,
                                            title: muted ? 'Unmute' : 'Mute',
                                            subtitle: muted ? 'Turn alerts on' : 'Mute alerts',
                                            onTap: muted ? _unmutePingChat : _mutePingChat,
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _PingSecondaryActionCard(
                                        icon: PhosphorIcons.mapPin,
                                        title: 'View Ping',
                                        subtitle: 'See details',
                                        onTap: _viewPingDetails,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 22),

                            _PingInfoSectionHeader(
                              title: 'Shared content',
                              action: 'View more >',
                              onActionTap: () => _openSharedContent(title),
                            ),

                            const SizedBox(height: 10),

                            _PingInfoSharedMediaPreview(
                              channel: widget.channel,
                              onViewMore: () => _openSharedContent(title),
                            ),

                            const SizedBox(height: 24),

                            const _PingInfoSectionHeader(
                              title: 'Members',
                            ),

                            const SizedBox(height: 10),

                            _PingInfoMembersList(
                              pingId: pingId,
                              creatorId:
                                  (data?['creatorId'] ?? '').toString().trim(),
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
}

class _PingInfoChatHoldAction extends StatelessWidget {
  const _PingInfoChatHoldAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFE53935) : const Color(0xFF111827);
    final bg = danger
        ? const Color(0xFFFEE2E2)
        : const Color(0xFFF4F6FA);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 72,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: bg,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 22,
                  color: color,
                ),
              ),

              const SizedBox(height: 7),

              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12.4,
                  fontWeight: FontWeight.w600,
                  color: danger
                      ? const Color(0xFFE53935)
                      : Colors.black.withOpacity(.68),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PingInfoHeroCard extends StatelessWidget {
  const _PingInfoHeroCard({
    required this.channel,
    required this.title,
    required this.description,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final Channel channel;
  final String title;
  final String description;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final hasDescription = description.trim().isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            blurRadius: 22,
            offset: const Offset(0, 10),
            color: Colors.black.withOpacity(.045),
          ),
        ],
      ),
      child: Column(
        children: [
          PingmeePingChannelAvatar(
            channel: channel,
            size: 96,
            radius: 48,
            iconSize: 42,
          ),

          const SizedBox(height: 16),

          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 23,
              fontWeight: FontWeight.w700,
              height: 1.12,
              color: Color(0xFF111827),
            ),
          ),

          const SizedBox(height: 8),

          Text(
            'Welcome to $title. This is where everyone inside the ping can talk, share updates, and stay aligned.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14.2,
              fontWeight: FontWeight.w400,
              height: 1.35,
              color: Colors.black.withOpacity(.54),
            ),
          ),

          if (hasDescription) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7FA),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description,
                    maxLines: expanded ? null : 3,
                    overflow:
                        expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.38,
                      color: Colors.black.withOpacity(.68),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: onToggleExpanded,
                    child: Text(
                      expanded ? 'See less' : 'See more',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PingPrimaryActionCard extends StatelessWidget {
  const _PingPrimaryActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData Function(PhosphorIconsStyle style) icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1E1E1E),
                const Color(0xFF111111),
                AppColors.brandGreen.withOpacity(.95),
              ],
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 24,
                offset: const Offset(0, 12),
                color: Colors.black.withOpacity(.12),
              ),
            ],
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.14),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(.10),
                    ),
                  ),
                  child: Icon(
                    icon(PhosphorIconsStyle.fill),
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'New',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white70,
                          letterSpacing: .2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13.2,
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withOpacity(.80),
                          height: 1.3,
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
                    color: Colors.white.withOpacity(.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 19,
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

class _PingSecondaryActionCard extends StatelessWidget {
  const _PingSecondaryActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData Function(PhosphorIconsStyle style) icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          height: 114,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.black.withOpacity(.04),
            ),
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
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F5F7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon(PhosphorIconsStyle.bold),
                  color: const Color(0xFF111827),
                  size: 20,
                ),
              ),
              const Spacer(),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14.2,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.48),
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PingInfoSectionHeader extends StatelessWidget {
  const _PingInfoSectionHeader({
    required this.title,
    this.action,
    this.onActionTap,
  });

  final String title;
  final String? action;
  final VoidCallback? onActionTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Color(0xFF111827),
            ),
          ),
        ),
        if (action != null)
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: onActionTap,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Text(
                  action!,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PingInfoMediaPreviewItem {
  const _PingInfoMediaPreviewItem({
    required this.message,
    required this.attachment,
  });

  final Message message;
  final Attachment attachment;
}

class _PingInfoSharedMediaPreview extends StatefulWidget {
  const _PingInfoSharedMediaPreview({
    required this.channel,
    required this.onViewMore,
  });

  final Channel channel;
  final VoidCallback onViewMore;

  @override
  State<_PingInfoSharedMediaPreview> createState() =>
      _PingInfoSharedMediaPreviewState();
}

class _PingInfoSharedMediaPreviewState
    extends State<_PingInfoSharedMediaPreview> {
  late final Future<List<_PingInfoMediaPreviewItem>> _mediaFuture =
      _loadMedia();

  bool _isMediaAttachment(Attachment attachment) {
    final type = (attachment.type ?? '').toLowerCase();
    final mimeType =
        (attachment.extraData['mime_type'] ??
                attachment.extraData['mimeType'] ??
                attachment.extraData['contentType'] ??
                '')
            .toString()
            .toLowerCase();

    return type == 'image' ||
        type == 'video' ||
        mimeType.startsWith('image/') ||
        mimeType.startsWith('video/');
  }

  String _attachmentUrl(Attachment attachment) {
    final candidates = <Object?>[
      attachment.imageUrl,
      attachment.thumbUrl,
      attachment.assetUrl,
      attachment.titleLink,
      attachment.extraData['url'],
      attachment.extraData['asset_url'],
      attachment.extraData['assetUrl'],
      attachment.extraData['file_url'],
      attachment.extraData['fileUrl'],
    ];

    for (final item in candidates) {
      final value = (item ?? '').toString().trim();

      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }

    return '';
  }

  Future<List<_PingInfoMediaPreviewItem>> _loadMedia() async {
    List<Message> messages;

    try {
      final state = await widget.channel.query(
        messagesPagination: const PaginationParams(
          limit: 80,
        ),
      );

      messages = state.messages ?? const <Message>[];
    } catch (_) {
      messages = widget.channel.state?.messages ?? const <Message>[];
    }

    final media = <_PingInfoMediaPreviewItem>[];

    for (final message in messages) {
      for (final attachment in message.attachments) {
        if (!_isMediaAttachment(attachment)) continue;

        media.add(
          _PingInfoMediaPreviewItem(
            message: message,
            attachment: attachment,
          ),
        );

        if (media.length >= 6) {
          return media;
        }
      }
    }

    return media;
  }

  void _openItem(_PingInfoMediaPreviewItem item) {
    final url = _attachmentUrl(item.attachment);
    if (url.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SharedMediaViewerScreen(
          url: url,
          attachment: item.attachment,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_PingInfoMediaPreviewItem>>(
      future: _mediaFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            height: 104,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppColors.brandGreen,
                ),
              ),
            ),
          );
        }

        final media = snap.data ?? const <_PingInfoMediaPreviewItem>[];

        if (media.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    PhosphorIcons.imagesSquare(PhosphorIconsStyle.bold),
                    size: 21,
                    color: Colors.black.withOpacity(.55),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Photos and videos shared here will appear in this section.',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13.8,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(26),
          ),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: media.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (context, index) {
              final item = media[index];
              final attachment = item.attachment;
              final url = _attachmentUrl(attachment);
              final type = (attachment.type ?? '').toLowerCase();

              return Material(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  onTap: () => _openItem(item),
                  borderRadius: BorderRadius.circular(18),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (url.isNotEmpty)
                          Image.network(
                            url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) {
                              return Icon(
                                PhosphorIcons.imageBroken(
                                  PhosphorIconsStyle.light,
                                ),
                                color: Colors.black.withOpacity(.40),
                              );
                            },
                          )
                        else
                          Icon(
                            PhosphorIcons.image(
                              PhosphorIconsStyle.light,
                            ),
                            color: Colors.black.withOpacity(.40),
                          ),

                        if (type == 'video')
                          Center(
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.62),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 24,
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
      },
    );
  }
}

class _PingInfoMemberRecord {
  const _PingInfoMemberRecord({
    required this.uid,
    required this.role,
    required this.status,
  });

  final String uid;
  final String role;
  final String status;

  bool get isApproved {
    final s = status.trim().toLowerCase();

    return s == 'approved' ||
        s == 'active' ||
        s == 'joined' ||
        s == 'member';
  }

  bool isHost(String creatorId) {
    final r = role.trim().toLowerCase();

    return uid == creatorId ||
        r == 'creator' ||
        r == 'host' ||
        r == 'owner';
  }

  factory _PingInfoMemberRecord.fromDoc(
    firestore.QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();

    return _PingInfoMemberRecord(
      uid: (data['uid'] ?? doc.id).toString().trim(),
      role: (data['role'] ?? '').toString().trim(),
      status: (data['status'] ?? '').toString().trim(),
    );
  }
}

class _PingInfoMembersList extends StatelessWidget {
  const _PingInfoMembersList({
    required this.pingId,
    required this.creatorId,
  });

  final String pingId;
  final String creatorId;

  Future<Map<String, Map<String, dynamic>>> _loadUsers(
    List<String> userIds,
  ) async {
    final out = <String, Map<String, dynamic>>{};

    for (int i = 0; i < userIds.length; i += 10) {
      final chunk = userIds.skip(i).take(10).toList();

      if (chunk.isEmpty) continue;

      final snap = await firestore.FirebaseFirestore.instance
          .collection('users')
          .where(
            firestore.FieldPath.documentId,
            whereIn: chunk,
          )
          .get();

      for (final doc in snap.docs) {
        out[doc.id] = doc.data();
      }
    }

    return out;
  }

  bool _isVerified(Map<String, dynamic>? data) {
    final verification = Map<String, dynamic>.from(
      data?['verification'] ?? {},
    );

    return verification['status'] == 'verified';
  }

  @override
  Widget build(BuildContext context) {
    final participantsRef = firestore.FirebaseFirestore.instance
        .collection('pings')
        .doc(pingId)
        .collection('participants');

    return StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
      stream: participantsRef.snapshots(),
      builder: (context, snap) {
        final records = (snap.data?.docs ?? [])
            .map(_PingInfoMemberRecord.fromDoc)
            .where((record) => record.uid.isNotEmpty)
            .where((record) => record.isApproved)
            .toList()
          ..sort((a, b) {
            final ah = a.isHost(creatorId);
            final bh = b.isHost(creatorId);

            if (ah && !bh) return -1;
            if (!ah && bh) return 1;

            return a.uid.compareTo(b.uid);
          });

        if (records.isEmpty) {
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Text(
              'No approved members yet.',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(.54),
              ),
            ),
          );
        }

        final ids = records.map((record) => record.uid).toList();

        return FutureBuilder<Map<String, Map<String, dynamic>>>(
          future: _loadUsers(ids),
          builder: (context, userSnap) {
            final usersById = userSnap.data ?? const <String, Map<String, dynamic>>{};

            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < records.length; i++) ...[
                    _PingInfoMemberTile(
                      record: records[i],
                      userData: usersById[records[i].uid],
                      creatorId: creatorId,
                      verified: _isVerified(usersById[records[i].uid]),
                    ),
                    if (i != records.length - 1)
                      Divider(
                        height: 1,
                        indent: 72,
                        color: Colors.black.withOpacity(.055),
                      ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _PingInfoMemberTile extends StatelessWidget {
  const _PingInfoMemberTile({
    required this.record,
    required this.userData,
    required this.creatorId,
    required this.verified,
  });

  final _PingInfoMemberRecord record;
  final Map<String, dynamic>? userData;
  final String creatorId;
  final bool verified;

  void _openProfile(BuildContext context) {
    final uid = record.uid.trim();
    if (uid.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileTab(profileUid: uid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = pingmeeFullNameFromUserData(userData);
    final image = pingmeePhotoFromUserData(userData);
    final isHost = record.isHost(creatorId);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openProfile(context),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              ClipOval(
                child: Container(
                  width: 44,
                  height: 44,
                  color: AppColors.brandGreen.withOpacity(.10),
                  child: image.isEmpty
                      ? Icon(
                          PhosphorIcons.user(PhosphorIconsStyle.light),
                          size: 21,
                          color: AppColors.brandGreen,
                        )
                      : Image.network(
                          image,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) {
                            return Icon(
                              PhosphorIcons.user(PhosphorIconsStyle.light),
                              size: 21,
                              color: AppColors.brandGreen,
                            );
                          },
                        ),
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),

                    if (verified) ...[
                      const SizedBox(width: 5),
                      Icon(
                        PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                        size: 15,
                        color: const Color(0xFF1D9BF0),
                      ),
                    ],
                  ],
                ),
              ),

              if (isHost) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen.withOpacity(.11),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Host',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 10.6,
                      fontWeight: FontWeight.w500,
                      color: AppColors.brandGreen,
                      height: 1,
                    ),
                  ),
                ),
              ],

              const SizedBox(width: 6),

              Icon(
                PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                size: 15,
                color: Colors.black.withOpacity(.24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatConnectionStarterCard extends StatelessWidget {
  const _ChatConnectionStarterCard({
    required this.person,
    required this.onSendStarter,
  });

  final PingmeeChatPerson person;
  final ValueChanged<String> onSendStarter;

  String _displayNameFrom(Map<String, dynamic>? data) {
    final fullName = pingmeeFullNameFromUserData(data).trim();

    if (fullName.isNotEmpty && fullName != 'Pingmee user') {
      return fullName;
    }

    final fallback = person.name.trim();
    if (fallback.isNotEmpty) return fallback;

    return 'this person';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(person.id)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final displayName = _displayNameFrom(data);

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.78),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: Colors.black.withOpacity(.035),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                    color: Colors.black.withOpacity(.045),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          PhosphorIcons.linkSimpleHorizontal(
                            PhosphorIconsStyle.bold,
                          ),
                          size: 13,
                          color: Colors.white.withOpacity(.92),
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Connected',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: .1,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 15),

                  Text(
                    'You’re now connected with $displayName',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                      height: 1.16,
                      letterSpacing: -.2,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'Break the silence. Start light, share a ping, or send something quick.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(.50),
                      height: 1.35,
                    ),
                  ),

                  const SizedBox(height: 17),

                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ChatStarterChip(
                        label: 'Hey 👋',
                        onTap: () => onSendStarter('Hey 👋'),
                      ),
                      _ChatStarterChip(
                        label: 'What’s up?',
                        onTap: () => onSendStarter('What’s up?'),
                      ),
                      _ChatStarterChip(
                        label: 'You nearby?',
                        onTap: () => onSendStarter('You nearby?'),
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

class _ChatStarterChip extends StatelessWidget {
  const _ChatStarterChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        splashColor: Colors.black.withOpacity(.04),
        highlightColor: Colors.black.withOpacity(.02),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.black.withOpacity(.045),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 13.4,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
        ),
      ),
    );
  }
}

class _PingmeeMentionTextBubble extends StatelessWidget {
  const _PingmeeMentionTextBubble({
    required this.message,
    required this.isMe,
  });

  final Message message;
  final bool isMe;

  List<String> _memberIds(BuildContext context) {
    final channel = StreamChannel.of(context).channel;

    return (channel.state?.members ?? const <Member>[])
        .map((member) => (member.userId ?? member.user?.id ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(10)
        .toList();
  }

  List<TextSpan> _spans({
    required String text,
    required List<String> names,
    required TextStyle normalStyle,
    required TextStyle mentionStyle,
  }) {
    if (text.isEmpty) return [];

    final cleanNames = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty && name != 'Pingmee user')
        .toSet()
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    if (cleanNames.isEmpty) {
      return [TextSpan(text: text, style: normalStyle)];
    }

    final lowerText = text.toLowerCase();
    var cursor = 0;
    final spans = <TextSpan>[];

    while (cursor < text.length) {
      int? nearestIndex;
      String? nearestMatch;

      for (final name in cleanNames) {
        final target = '@${name.toLowerCase()}';
        final found = lowerText.indexOf(target, cursor);

        if (found == -1) continue;

        if (nearestIndex == null || found < nearestIndex) {
          nearestIndex = found;
          nearestMatch = text.substring(found, found + target.length);
        }
      }

      if (nearestIndex == null || nearestMatch == null) {
        spans.add(TextSpan(text: text.substring(cursor), style: normalStyle));
        break;
      }

      if (nearestIndex > cursor) {
        spans.add(
          TextSpan(
            text: text.substring(cursor, nearestIndex),
            style: normalStyle,
          ),
        );
      }

      spans.add(
        TextSpan(
          text: nearestMatch,
          style: mentionStyle,
        ),
      );

      cursor = nearestIndex + nearestMatch.length;
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final text = (message.text ?? '').trim();

    final memberIds = _memberIds(context);

    final bubbleColor = isMe ? const Color(0xFFE9EDF2) : Colors.white;
    final borderColor = isMe ? Colors.transparent : const Color(0xFFE2E8F0);

    const normalStyle = TextStyle(
      fontFamily: 'Nunito',
      fontSize: 15.6,
      fontWeight: FontWeight.w500,
      color: Color(0xFF111827),
      height: 1.28,
    );

    const mentionStyle = TextStyle(
      fontFamily: 'Nunito',
      fontSize: 15.6,
      fontWeight: FontWeight.w700,
      color: Color(0xFF2563EB), // ✅ blue in sent message
      height: 1.28,
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMe ? 72 : 10,
          right: isMe ? 10 : 72,
          top: 3,
          bottom: 3,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 13,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          child: memberIds.isEmpty
              ? Text(text, style: normalStyle)
              : StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
                  stream: firestore.FirebaseFirestore.instance
                      .collection('users')
                      .where(
                        firestore.FieldPath.documentId,
                        whereIn: memberIds,
                      )
                      .snapshots(),
                  builder: (context, snap) {
                    final names = (snap.data?.docs ?? [])
                        .map((doc) {
                          return pingmeeFullNameFromUserData(doc.data());
                        })
                        .where((name) => name.trim().isNotEmpty)
                        .toList();

                    return RichText(
                      text: TextSpan(
                        children: _spans(
                          text: text,
                          names: names,
                          normalStyle: normalStyle,
                          mentionStyle: mentionStyle,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _ChatTopProfileCard extends StatelessWidget {
  const _ChatTopProfileCard({
    required this.person,
  });

  final PingmeeChatPerson person;

  String _headlineFrom(Map<String, dynamic>? data) {
    final d = data ?? <String, dynamic>{};

    final headline = (d['headline'] ?? '').toString().trim();
    final intro = (d['intro'] ?? '').toString().trim();
    final bio = (d['bio'] ?? '').toString().trim();

    if (headline.isNotEmpty) return headline;
    if (intro.isNotEmpty) return intro;
    if (bio.isNotEmpty) return bio;

    return 'No headline yet.';
  }

  bool _isVerified(Map<String, dynamic>? data) {
    final verification = Map<String, dynamic>.from(
      data?['verification'] ?? {},
    );

    return verification['status'] == 'verified';
  }

  void _openProfile(BuildContext context) {
    final uid = person.id.trim();
    if (uid.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileTab(profileUid: uid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(person.id)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final fullName = pingmeeFullNameFromUserData(data);
        final imageUrl = pingmeePhotoFromUserData(data);

        final displayName = fullName.trim().isEmpty ? person.name : fullName;
        final displayImage = imageUrl.trim().isEmpty ? person.image : imageUrl;
        final verified = _isVerified(data);

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: AppColors.brandGreen.withOpacity(.10),
                      backgroundImage: displayImage.isEmpty
                          ? null
                          : NetworkImage(displayImage),
                      child: displayImage.isEmpty
                          ? Icon(
                              PhosphorIcons.user(PhosphorIconsStyle.light),
                              size: 38,
                              color: AppColors.brandGreen,
                            )
                          : null,
                    ),
                    if (person.online)
                      Positioned(
                        right: 2,
                        bottom: 3,
                        child: Container(
                          width: 15,
                          height: 15,
                          decoration: BoxDecoration(
                            color: AppColors.brandGreen,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF111827),
                          height: 1.15,
                        ),
                      ),
                    ),

                    if (verified) ...[
                      const SizedBox(width: 6),
                      Icon(
                        PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                        size: 18,
                        color: const Color(0xFF1D9BF0),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 8),

                Text(
                  _headlineFrom(data),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.8,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.55),
                    height: 1.35,
                  ),
                ),

                const SizedBox(height: 16),

                Material(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    onTap: () => _openProfile(context),
                    borderRadius: BorderRadius.circular(999),
                    child: const SizedBox(
                      height: 44,
                      width: 150,
                      child: Center(
                        child: Text(
                          'View profile',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
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

class _PingmeeVoiceMessageBubble extends StatefulWidget {
  const _PingmeeVoiceMessageBubble({
    required this.attachment,
    required this.isMe,
    required this.url,
    required this.initialDuration,
  });

  final Attachment attachment;
  final bool isMe;
  final String url;
  final Duration initialDuration;

  @override
  State<_PingmeeVoiceMessageBubble> createState() =>
      _PingmeeVoiceMessageBubbleState();
}

class _PingmeeGiphyStickerBubble extends StatelessWidget {
  const _PingmeeGiphyStickerBubble({
    required this.attachment,
    required this.isMe,
  });

  final Attachment attachment;
  final bool isMe;

  String _url() {
    final candidates = <Object?>[
      attachment.imageUrl,
      attachment.assetUrl,
      attachment.thumbUrl,
      attachment.extraData['url'],
      attachment.extraData['previewUrl'],
    ];

    for (final item in candidates) {
      final value = (item ?? '').toString().trim();

      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }

    return '';
  }

  @override
  Widget build(BuildContext context) {
    final url = _url();

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMe ? 96 : 10,
          right: isMe ? 10 : 96,
          top: 5,
          bottom: 5,
        ),
        child: SizedBox(
          width: 150,
          height: 150,
          child: url.isEmpty
              ? Icon(
                  PhosphorIcons.sticker(PhosphorIconsStyle.bold),
                  size: 56,
                  color: Colors.black.withOpacity(.55),
                )
              : Image.network(
                  url,
                  fit: BoxFit.contain,
                ),
        ),
      ),
    );
  }
}

class _PingmeeBigEmojiBubble extends StatelessWidget {
  const _PingmeeBigEmojiBubble({
    required this.emoji,
    required this.isMe,
  });

  final String emoji;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final safeEmoji = emoji.trim().isEmpty ? '💚' : emoji.trim();

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMe ? 70 : 10,
          right: isMe ? 10 : 70,
          top: 4,
          bottom: 4,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(
            safeEmoji,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 54,
              height: 1.05,
            ),
          ),
        ),
      ),
    );
  }
}

class _PingmeeVoiceMessageBubbleState
    extends State<_PingmeeVoiceMessageBubble> {
  late final AudioPlayer _player;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isReady = false;

  static const List<double> _bars = [
    6, 12, 9, 16, 11, 18, 8, 14, 10, 17, 7, 13, 9, 15, 8, 12,
  ];

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _duration = widget.initialDuration;
    _setup();
  }

  Future<void> _setup() async {
    _positionSub = _player.positionStream.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
    });

    _durationSub = _player.durationStream.listen((value) {
      if (!mounted || value == null) return;
      setState(() => _duration = value);
    });

    _playerStateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        _isPlaying = state.playing;
      });

      if (state.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
      }
    });

    if (widget.url.trim().isEmpty) return;

    try {
      final loadedDuration = await _player.setUrl(widget.url.trim());
      if (!mounted) return;

      setState(() {
        _isReady = true;
        if (loadedDuration != null) {
          _duration = loadedDuration;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isReady = false;
      });
    }
  }

  Future<void> _togglePlay() async {
    if (!_isReady) return;

    if (_player.playerState.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }

    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    String two(int n) => n.toString().padLeft(2, '0');
    return '$minutes:${two(seconds)}';
  }

  double get _progress {
    if (_duration.inMilliseconds <= 0) return 0;
    final ratio = _position.inMilliseconds / _duration.inMilliseconds;
    return ratio.clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bubbleColor = widget.isMe
        ? const Color(0xFFF2F4F7)
        : Colors.white;

    final borderColor = widget.isMe
        ? Colors.transparent
        : const Color(0xFFE2E8F0);

    final playBg = AppColors.brandGreen.withOpacity(.14);
    final playIcon = AppColors.brandGreen;
    final inactiveBar = const Color(0xFFB8BDC7);
    final activeBar = AppColors.brandGreen;
    final textColor = const Color(0xFF4B5563);

    final displayedDuration = _position > Duration.zero ? _position : _duration;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 190,
        maxWidth: 255,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _togglePlay,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: playBg,
                  shape: BoxShape.circle,
                ),
                child: _isReady
                    ? Icon(
                        _isPlaying
                            ? PhosphorIcons.pause(
                                PhosphorIconsStyle.fill,
                              )
                            : PhosphorIcons.play(
                                PhosphorIconsStyle.fill,
                              ),
                        size: 18,
                        color: playIcon,
                      )
                    : const SizedBox(
                        width: 16,
                        height: 16,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
              ),
            ),

            const SizedBox(width: 10),

            Expanded(
              child: SizedBox(
                height: 24,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: List.generate(_bars.length, (index) {
                    final barHeight = _bars[index];
                    final threshold = (index + 1) / _bars.length;
                    final barColor = _progress >= threshold
                        ? activeBar
                        : inactiveBar;

                    return Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 3,
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: barColor,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),

            const SizedBox(width: 10),

            Text(
              _formatDuration(displayedDuration),
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),

            const SizedBox(width: 8),

            Icon(
              PhosphorIcons.speakerHigh(PhosphorIconsStyle.bold),
              size: 18,
              color: textColor.withOpacity(.72),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingmeeLocalAttachment {
  const _PingmeeLocalAttachment({
    required this.file,
    required this.fileName,
    required this.contentType,
  });

  final File file;
  final String fileName;
  final String contentType;
}

class _PingmeeThemedMessageInput extends StatefulWidget {
  const _PingmeeThemedMessageInput({
    this.messageInputController,
    this.preMessageSending,
    this.onQuotedMessageCleared,
    this.onAnyMessageSent,
    this.allowPolls = false,
  });

  final StreamMessageInputController? messageInputController;
  final Message Function(Message message)? preMessageSending;
  final VoidCallback? onQuotedMessageCleared;
  final VoidCallback? onAnyMessageSent;
  final bool allowPolls;

  @override
  State<_PingmeeThemedMessageInput> createState() =>
      _PingmeeThemedMessageInputState();
}

class _PingmeeMediaLibrarySheet extends StatelessWidget {
  const _PingmeeMediaLibrarySheet({
    required this.onEmojiSelected,
    required this.onStickerTap,
    required this.onGifTap,
  });

  final ValueChanged<String> onEmojiSelected;
  final VoidCallback onStickerTap;
  final VoidCallback onGifTap;

  @override
  Widget build(BuildContext context) {
    final sheetHeight = MediaQuery.of(context).size.height * .62;

    return SafeArea(
      top: false,
      child: Container(
        height: sheetHeight,
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),

              const SizedBox(height: 14),

              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.06),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      PhosphorIcons.smiley(PhosphorIconsStyle.fill),
                      color: Colors.black,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Pingmee library',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              Container(
                height: 42,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: TabBar(
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.black.withOpacity(.46),
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
                    Tab(text: 'Emoji'),
                    Tab(text: 'Stickers'),
                    Tab(text: 'GIFs'),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              Expanded(
                child: TabBarView(
                  children: [
                    _PingmeeEmojiLibraryTab(
                      onEmojiSelected: onEmojiSelected,
                    ),
                    _PingmeeGiphyOpenTab(
                      title: 'GIPHY stickers',
                      subtitle: 'Browse animated stickers from GIPHY.',
                      icon: PhosphorIcons.sticker(
                        PhosphorIconsStyle.fill,
                      ),
                      buttonText: 'Open stickers',
                      onTap: onStickerTap,
                    ),
                    _PingmeeGiphyOpenTab(
                      title: 'GIPHY GIFs',
                      subtitle: 'Search reactions, memes, and moments.',
                      icon: PhosphorIcons.gif(
                        PhosphorIconsStyle.fill,
                      ),
                      buttonText: 'Open GIFs',
                      onTap: onGifTap,
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

class _PingmeeEmojiLibraryTab extends StatelessWidget {
  const _PingmeeEmojiLibraryTab({
    required this.onEmojiSelected,
  });

  final ValueChanged<String> onEmojiSelected;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: EmojiPicker(
        onEmojiSelected: (category, emoji) {
          onEmojiSelected(emoji.emoji);
        },
        config: Config(
          height: 340,
          checkPlatformCompatibility: true,
          emojiViewConfig: EmojiViewConfig(
            columns: 7,
            emojiSizeMax: 30 *
                (foundation.defaultTargetPlatform == TargetPlatform.iOS
                    ? 1.20
                    : 1.0),
            backgroundColor: Colors.white,
            verticalSpacing: 0,
            horizontalSpacing: 0,
            gridPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 6,
            ),
          ),
          viewOrderConfig: const ViewOrderConfig(
            top: EmojiPickerItem.categoryBar,
            middle: EmojiPickerItem.emojiView,
            bottom: EmojiPickerItem.searchBar,
          ),
          skinToneConfig: const SkinToneConfig(),
          categoryViewConfig: const CategoryViewConfig(
            backgroundColor: Colors.white,
            indicatorColor: Colors.black,
            iconColor: Color(0xFF9CA3AF),
            iconColorSelected: Colors.black,
            dividerColor: Colors.transparent,
          ),
          bottomActionBarConfig: const BottomActionBarConfig(
            backgroundColor: Colors.white,
            buttonIconColor: Colors.black,
          ),
          searchViewConfig: const SearchViewConfig(
            backgroundColor: Color(0xFFF3F4F6),
            buttonIconColor: Colors.black,
            hintText: 'Search emoji',
          ),
        ),
      ),
    );
  }
}

class _PingmeeGiphyOpenTab extends StatelessWidget {
  const _PingmeeGiphyOpenTab({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.buttonText,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String buttonText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: Colors.white,
                size: 28,
              ),
            ),

            const SizedBox(height: 14),

            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),

            const SizedBox(height: 7),

            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(.52),
                height: 1.3,
              ),
            ),

            const SizedBox(height: 18),

            Material(
              color: Colors.black,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 46,
                  width: 170,
                  child: Center(
                    child: Text(
                      buttonText,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
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

class _PingmeePollDraft {
  const _PingmeePollDraft({
    required this.question,
    required this.options,
  });

  final String question;
  final List<String> options;
}

class _PingmeeThemedMessageInputState
    extends State<_PingmeeThemedMessageInput> {
  final AudioRecorder _recorder = AudioRecorder();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isUploadingAttachment = false;
  double _attachmentUploadProgress = 0.0;
  String _attachmentUploadLabel = 'Sending attachment...';

  Timer? _recordingTimer;
  bool _isRecording = false;
  bool _isUploadingVoice = false;
  Duration _recordingDuration = Duration.zero;
  String? _recordingPath;

  Future<void> _openPollSheet() async {
    if (_isUploadingAttachment || _isUploadingVoice || _isRecording) return;

    final channel = StreamChannel.of(context).channel;

    if (!widget.allowPolls || !pingmeeIsPingChannel(channel)) {
      return;
    }

    final draft = await showModalBottomSheet<_PingmeePollDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PingmeeCreatePollSheet(),
    );

    if (draft == null) return;

    await _sendPoll(draft);
  }

  Future<void> _sendPoll(_PingmeePollDraft draft) async {
    final channel = StreamChannel.of(context).channel;

    if (!widget.allowPolls || !pingmeeIsPingChannel(channel)) {
      return;
    }

    final question = draft.question.trim();

    final cleanOptions = draft.options
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();

    if (question.isEmpty || cleanOptions.length < 2) {
      _showChatSnack(
        context,
        'Add a question and at least two options.',
      );
      return;
    }

    try {
      final poll = Poll(
        name: question,
        enforceUniqueVote: true,
        votingVisibility: VotingVisibility.public,
        options: cleanOptions
            .map(
              (text) => PollOption(text: text),
            )
            .toList(),
        extraData: const {
          'pingmeePoll': true,
        },
      );

      await channel.sendPoll(
        poll,
        messageText: question,
      );

      widget.onAnyMessageSent?.call();

      HapticFeedback.selectionClick();

      if (!mounted) return;
      _showChatSnack(context, 'Poll sent.');
    } catch (error, stack) {
      _logChatError('Send poll failed', error, stack);

      if (!mounted) return;

      _showChatSnack(
        context,
        _friendlyChatErrorMessage(
          error,
          fallback: 'Could not send poll. Make sure polls are enabled in Stream.',
        ),
      );
    }
  }

  bool _isVoiceAttachment(Attachment attachment) {
    final type = (attachment.type ?? '').toString().toLowerCase();
    final extraType = (attachment.extraData['type'] ?? '')
        .toString()
        .toLowerCase();

    return attachment.isVoiceRecording ||
        type == 'voicerecording' ||
        type == 'voice_recording' ||
        type == 'voice-recording' ||
        extraType == 'voicerecording' ||
        extraType == 'voice_recording' ||
        extraType == 'voice-recording';
  }

  String _composerHintFromUserData(
    Map<String, dynamic>? data, {
    required String fallbackName,
  }) {
    final fullName = pingmeeFullNameFromUserData(data).trim();

    final cleanName =
        fullName.isNotEmpty && fullName != 'Pingmee user'
            ? fullName
            : fallbackName.trim();

    if (cleanName.isEmpty || cleanName == 'Pingmee user') {
      return 'Message';
    }

    final firstName = cleanName.split(RegExp(r'\s+')).first.trim();

    if (firstName.isEmpty) return 'Message';

    return 'Message $firstName';
  }

  String _sentLabelForAttachments(List<Attachment> attachments) {
    if (attachments.isEmpty) return '';

    final hasSticker = attachments.any((attachment) {
      return attachment.extraData['pingmeeSticker'] == true;
    });

    if (hasSticker) return 'Sent sticker';

    final hasVoice = attachments.any((attachment) {
      final type = (attachment.type ?? '').toLowerCase();
      final extraType =
          (attachment.extraData['type'] ?? '').toString().toLowerCase();

      return type.contains('audio') ||
          type.contains('voice') ||
          extraType.contains('voice') ||
          attachment.extraData['pingmeeVoiceMessage'] == true;
    });

    if (hasVoice) return 'Sent voice note';

    final hasVideo = attachments.any((attachment) {
      final type = (attachment.type ?? '').toLowerCase();
      final mimeType =
          (attachment.extraData['mime_type'] ??
                  attachment.extraData['contentType'] ??
                  '')
              .toString()
              .toLowerCase();

      return type == 'video' || mimeType.startsWith('video/');
    });

    if (hasVideo) return 'Sent video';

    final hasImage = attachments.any((attachment) {
      final type = (attachment.type ?? '').toLowerCase();
      final mimeType =
          (attachment.extraData['mime_type'] ??
                  attachment.extraData['contentType'] ??
                  '')
              .toString()
              .toLowerCase();

      return type == 'image' || mimeType.startsWith('image/');
    });

    if (hasImage) return 'Sent photo';

    return 'Sent attachment';
  }

  Message _removeVoiceFileLabel(Message message) {
    if (message.attachments.isEmpty) return message;

    final cleanedAttachments = message.attachments.map((attachment) {
      if (!_isVoiceAttachment(attachment)) return attachment;

      final extraData = Map<String, Object?>.from(attachment.extraData);

      extraData.remove('name');
      extraData.remove('fileName');
      extraData.remove('file_name');
      extraData.remove('filename');

      return attachment.copyWith(
        title: '',
        text: '',
        fallback: 'Voice message',
        extraData: extraData,
      );
    }).toList();

    return message.copyWith(
      attachments: cleanedAttachments,
    );
  }

  Future<void> _toggleRecording() async {
    if (_isUploadingVoice) return;

    if (_isRecording) {
      await _stopAndSendRecording();
      return;
    }

    await _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      final hasPermission = await _recorder.hasPermission();

      if (!hasPermission) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is needed to record voice.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final uid = fb.FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final fileName =
          'pingmee_voice_${uid}_${DateTime.now().millisecondsSinceEpoch}.m4a';

      final path = '${tempDir.path}/$fileName';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );

      if (!mounted) return;

      setState(() {
        _isRecording = true;
        _recordingPath = path;
        _recordingDuration = Duration.zero;
      });

      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;

        setState(() {
          _recordingDuration += const Duration(seconds: 1);
        });

        if (_recordingDuration.inMinutes >= 2) {
          _stopAndSendRecording();
        }
      });

      HapticFeedback.selectionClick();
    } catch (error, stack) {
      _logChatError('Voice recording start failed', error, stack);

      if (!mounted) return;

      _showChatSnack(
        context,
        _friendlyChatErrorMessage(
          error,
          fallback: 'Could not start recording. Please try again.',
        ),
      );
    }
  }

  Future<void> _cancelRecording() async {
    try {
      _recordingTimer?.cancel();

      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }

      final path = _recordingPath;
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {
      // Ignore cleanup errors.
    } finally {
      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _isUploadingVoice = false;
        _recordingDuration = Duration.zero;
        _recordingPath = null;
      });
    }
  }

  void _openPingmeeLibrarySheet() {
    if (_isUploadingAttachment || _isUploadingVoice || _isRecording) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _PingmeeMediaLibrarySheet(
          onEmojiSelected: (emoji) {
            Navigator.of(sheetContext).pop();
            _sendBigEmoji(emoji);
          },
          onStickerTap: () {
            Navigator.of(sheetContext).pop();
            _openGiphyPicker(isSticker: true);
          },
          onGifTap: () {
            Navigator.of(sheetContext).pop();
            _openGiphyPicker(isSticker: false);
          },
        );
      },
    );
  }

  Future<void> _stopAndSendRecording() async {
    if (!_isRecording || _isUploadingVoice) return;

    final allowed = await _tryConsumeOutgoingRequestMessageSlot(context);
    if (!allowed) {
      await _cancelRecording();
      return;
    }

    _recordingTimer?.cancel();

    setState(() {
      _isUploadingVoice = true;
    });

    File? localFile;

    try {
      debugPrint('🎙️ Voice: stopping recorder...');

      final stoppedPath = await _recorder.stop().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          throw TimeoutException('Recorder stop timed out.');
        },
      );

      final path = stoppedPath ?? _recordingPath;

      debugPrint('🎙️ Voice: stoppedPath=$path');

      if (path == null || path.trim().isEmpty) {
        throw StateError('No recording file was created.');
      }

      localFile = File(path);

      if (!await localFile.exists()) {
        throw StateError('Recording file does not exist.');
      }

      final fileSize = await localFile.length();

      debugPrint('🎙️ Voice: file exists, size=$fileSize bytes');

      if (fileSize <= 0) {
        throw StateError('Recording file is empty.');
      }

      setState(() {
        _attachmentUploadLabel = 'Uploading voice note...';
        _attachmentUploadProgress = 0.0;
      });

      final voiceAttachment = await _uploadLocalAttachmentToStream(
        item: _PingmeeLocalAttachment(
          file: localFile,
          fileName: _fileNameFromPath(localFile.path),
          contentType: 'audio/mp4',
        ),
        index: 0,
        totalItems: 1,
        forceAudio: true,
        audioDuration: _recordingDuration,
      );

      Message message = Message(
        text: 'Sent voice note',
        attachments: [voiceAttachment],
        extraData: {
          'pingmeeVoiceMessage': true,
          'pingmeeGeneratedText': true,
        },
      );

      if (widget.preMessageSending != null) {
        message = widget.preMessageSending!(message);
      }

      setState(() {
        _attachmentUploadLabel = 'Sending voice note...';
        _attachmentUploadProgress = 1.0;
      });

      final channel = StreamChannel.of(context).channel;

      debugPrint('🎙️ Voice: sending Stream message...');
      final sentMessage = await channel.sendMessage(message);
      debugPrint('✅ Voice: Stream confirmed id=${sentMessage.message.id}');

      debugPrint('✅ Voice: Stream voice message sent');
      widget.onAnyMessageSent?.call();

      try {
        if (await localFile.exists()) {
          await localFile.delete();
        }
      } catch (_) {
        // Ignore local cleanup errors.
      }

      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _isUploadingVoice = false;
        _recordingDuration = Duration.zero;
        _recordingPath = null;
      });

      HapticFeedback.lightImpact();

      debugPrint('✅ Voice: composer reset after queueing message');
    } catch (error, stack) {
      _logChatError('Voice recording send failed', error, stack);

      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _isUploadingVoice = false;
        _recordingDuration = Duration.zero;
        _recordingPath = null;
      });

      _showChatSnack(
        context,
        _friendlyChatErrorMessage(
          error,
          fallback: 'Could not send voice note. Please try again.',
        ),
      );
    }
  }

  String _formatRecordingTime(Duration value) {
    final totalSeconds = value.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    String two(int n) => n.toString().padLeft(2, '0');
    return '$minutes:${two(seconds)}';
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  String _safeChannelId(Channel channel) {
    final raw = (channel.cid ?? channel.id ?? 'dm').toString();

    return raw
        .replaceAll(':', '_')
        .replaceAll('/', '_')
        .replaceAll('%', '_');
  }

  String _fileNameFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);

    if (parts.isNotEmpty && parts.last.trim().isNotEmpty) {
      return parts.last.trim();
    }

    return 'pingmee_file_${DateTime.now().millisecondsSinceEpoch}';
  }

  String _extensionFromName(String fileName) {
    final clean = fileName.trim().toLowerCase();
    final dot = clean.lastIndexOf('.');

    if (dot < 0 || dot == clean.length - 1) return '';

    return clean.substring(dot + 1);
  }

  String _contentTypeForFileName(
    String fileName, {
    String? fallback,
  }) {
    final safeFallback = (fallback ?? '').trim();

    if (safeFallback.isNotEmpty &&
        safeFallback != 'application/octet-stream') {
      return safeFallback;
    }

    switch (_extensionFromName(fileName)) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default:
        return 'application/octet-stream';
    }
  }

  String _contentTypeForAsset(
    AssetEntity asset,
    String fileName,
  ) {
    if (asset.type == AssetType.image) {
      return _contentTypeForFileName(
        fileName,
        fallback: 'image/jpeg',
      );
    }

    if (asset.type == AssetType.video) {
      return _contentTypeForFileName(
        fileName,
        fallback: 'video/mp4',
      );
    }

    return _contentTypeForFileName(fileName);
  }

  String _attachmentTypeForContentType(String contentType) {
    final type = contentType.toLowerCase();

    if (type.startsWith('image/')) return 'image';
    if (type.startsWith('video/')) return 'video';
    if (type.startsWith('audio/')) return 'audio';

    return 'file';
  }

  String _fallbackForAttachmentType(String type) {
    switch (type) {
      case 'image':
        return 'Photo';
      case 'video':
        return 'Video';
      case 'audio':
        return 'Audio';
      default:
        return 'File';
    }
  }

  String _safeStorageFileName(String fileName) {
    final cleaned = fileName
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll(':', '_')
        .replaceAll('%', '_')
        .trim();

    if (cleaned.isEmpty) {
      return 'pingmee_file_${DateTime.now().millisecondsSinceEpoch}';
    }

    return cleaned;
  }

  void _openPingmeeAttachmentSheet() {
    if (_isUploadingAttachment || _isUploadingVoice) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _PingmeeAttachmentSheet(
          onCamera: () {
            Navigator.of(context).pop();
            _pickCameraPhoto();
          },
          onGallery: () {
            Navigator.of(context).pop();
            _pickGalleryMedia();
          },
          onVideo: () {
            Navigator.of(context).pop();
            _pickGalleryVideo();
          },
          onFile: () {
            Navigator.of(context).pop();
            _pickFiles();
          },
        );
      },
    );
  }

  Future<void> _pickCameraPhoto() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 1920,
    );

    if (picked == null) return;

    final fileName = picked.name.trim().isEmpty
        ? _fileNameFromPath(picked.path)
        : picked.name.trim();

    await _sendLocalAttachments([
      _PingmeeLocalAttachment(
        file: File(picked.path),
        fileName: fileName,
        contentType: _contentTypeForFileName(fileName),
      ),
    ]);
  }

  Future<void> _pickGalleryMedia() async {
    final assets = await AssetPicker.pickAssets(
      context,
      pickerConfig: const AssetPickerConfig(
        maxAssets: 6,
        requestType: RequestType.common,
      ),
    );

    if (assets == null || assets.isEmpty) return;

    final localAttachments = <_PingmeeLocalAttachment>[];

    for (final asset in assets) {
      final file = await asset.file;
      if (file == null) continue;

      final title = (asset.title ?? '').trim();
      final fileName = title.isEmpty ? _fileNameFromPath(file.path) : title;

      localAttachments.add(
        _PingmeeLocalAttachment(
          file: file,
          fileName: fileName,
          contentType: _contentTypeForAsset(asset, fileName),
        ),
      );
    }

    if (localAttachments.isEmpty) return;

    await _sendLocalAttachments(localAttachments);
  }

  Future<void> _pickGalleryVideo() async {
    final picked = await _imagePicker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );

    if (picked == null) return;

    final fileName = picked.name.trim().isEmpty
        ? _fileNameFromPath(picked.path)
        : picked.name.trim();

    await _sendLocalAttachments([
      _PingmeeLocalAttachment(
        file: File(picked.path),
        fileName: fileName,
        contentType: _contentTypeForFileName(
          fileName,
          fallback: picked.mimeType,
        ),
      ),
    ]);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false,
    );

    if (result == null || result.files.isEmpty) return;

    final localAttachments = <_PingmeeLocalAttachment>[];

    for (final picked in result.files) {
      final path = picked.path;
      if (path == null || path.trim().isEmpty) continue;

      final fileName = picked.name.trim().isEmpty
          ? _fileNameFromPath(path)
          : picked.name.trim();

      localAttachments.add(
        _PingmeeLocalAttachment(
          file: File(path),
          fileName: fileName,
          contentType: _contentTypeForFileName(fileName),
        ),
      );
    }

    if (localAttachments.isEmpty) return;

    await _sendLocalAttachments(localAttachments);
  }

  Future<Attachment> _uploadLocalAttachmentToStream({
    required _PingmeeLocalAttachment item,
    required int index,
    required int totalItems,
    bool forceAudio = false,
    Duration? audioDuration,
    Map<String, Object?> extraData = const {},
  }) async {
    final channel = StreamChannel.of(context).channel;
    final client = StreamChat.of(context).client;

    final channelId = channel.id;
    final channelType = channel.type;

    if (channelId == null || channelId.trim().isEmpty) {
      throw StateError('Missing Stream channel id.');
    }

    final safeFileName = _safeStorageFileName(item.fileName);
    final contentType = item.contentType;
    final attachmentType = forceAudio
        ? 'audio'
        : _attachmentTypeForContentType(contentType);

    final fileSize = await item.file.length();

    final attachmentFile = AttachmentFile(
      path: item.file.path,
      name: safeFileName,
      size: fileSize,
    );

    void updateProgress(int sent, int total) {
      if (!mounted) return;

      final fileProgress = total <= 0 ? 0.0 : sent / total;
      final overallProgress = ((index + fileProgress) / totalItems)
          .clamp(0.0, 1.0);

      setState(() {
        _attachmentUploadProgress = overallProgress;
        _attachmentUploadLabel = totalItems > 1
            ? 'Uploading ${index + 1} of $totalItems...'
            : 'Uploading $safeFileName...';
      });
    }

    dynamic response;

    if (attachmentType == 'image') {
      response = await client.sendImage(
        attachmentFile,
        channelId,
        channelType,
        onSendProgress: updateProgress,
      );
    } else {
      response = await client.sendFile(
        attachmentFile,
        channelId,
        channelType,
        onSendProgress: updateProgress,
      );
    }

    final url = (response.file ?? '').toString();

    if (url.isEmpty) {
      throw StateError('Stream upload returned an empty file URL.');
    }

    return Attachment(
      uploadState: const UploadState.success(), // ✅ critical
      type: attachmentType,
      assetUrl: url,
      imageUrl: attachmentType == 'image' ? url : null,
      title: attachmentType == 'file' ? safeFileName : '',
      text: '',
      fallback:
          forceAudio ? 'Voice message' : _fallbackForAttachmentType(attachmentType),
      extraData: {
        'pingmeeAttachment': true,
        if (forceAudio) 'pingmeeVoiceMessage': true,
        'fileName': safeFileName,
        'mime_type': contentType,
        'contentType': contentType,
        'url': url,
        if (audioDuration != null) 'duration_ms': audioDuration.inMilliseconds,
        if (audioDuration != null) 'durationMs': audioDuration.inMilliseconds,
        ...extraData,
      },
    );
  }

  Future<void> _sendLocalAttachments(
    List<_PingmeeLocalAttachment> localAttachments,
  ) async {
    if (_isUploadingAttachment || _isUploadingVoice) return;
    if (localAttachments.isEmpty) return;

    final allowed = await _tryConsumeOutgoingRequestMessageSlot(context);
    if (!allowed) return;

    setState(() {
      _isUploadingAttachment = true;
      _attachmentUploadProgress = 0.0;
      _attachmentUploadLabel = 'Preparing attachment.';
    });

    try {
      final streamAttachments = <Attachment>[];

      for (var i = 0; i < localAttachments.length; i++) {
        final item = localAttachments[i];

        if (!await item.file.exists()) {
          throw StateError('${item.fileName} does not exist.');
        }

        final size = await item.file.length();

        if (size <= 0) {
          throw StateError('${item.fileName} is empty.');
        }

        streamAttachments.add(
          await _uploadLocalAttachmentToStream(
            item: item,
            index: i,
            totalItems: localAttachments.length,
          ),
        );
      }

      setState(() {
        _attachmentUploadLabel = 'Sending message...';
        _attachmentUploadProgress = 1.0;
      });

      Message message = Message(
        text: _sentLabelForAttachments(streamAttachments),
        attachments: streamAttachments,
        extraData: {
          'pingmeeAttachment': true,
          'pingmeeGeneratedText': true,
        },
      );

      if (widget.preMessageSending != null) {
        message = widget.preMessageSending!(message);
      }

      final channel = StreamChannel.of(context).channel;

      debugPrint('📎 Attachment: sending Stream message...');
      final sentMessage = await channel.sendMessage(message);
      debugPrint('✅ Attachment: Stream confirmed id=${sentMessage.message.id}');

      if (!mounted) return;

      setState(() {
        _isUploadingAttachment = false;
        _attachmentUploadProgress = 0.0;
        _attachmentUploadLabel = 'Sending attachment...';
      });

      HapticFeedback.lightImpact();
    } catch (error, stack) {
      debugPrint('❌ Attachment send failed: $error');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;

      setState(() {
        _isUploadingAttachment = false;
        _attachmentUploadProgress = 0.0;
        _attachmentUploadLabel = 'Sending attachment...';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not send attachment: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _sendBigEmoji(String emoji) async {
    final cleanEmoji = emoji.trim();
    if (cleanEmoji.isEmpty) return;

    if (_isUploadingAttachment || _isUploadingVoice || _isRecording) return;

    final allowed = await _tryConsumeOutgoingRequestMessageSlot(context);
    if (!allowed) return;

    try {
      final channel = StreamChannel.of(context).channel;

      Message message = Message(
        text: cleanEmoji,
        extraData: {
          'pingmeeBigEmoji': true,
        },
      );

      if (widget.preMessageSending != null) {
        message = widget.preMessageSending!(message);
      }

      await channel.sendMessage(message);

      HapticFeedback.selectionClick();
    } catch (error, stack) {
      _logChatError('Big emoji send failed', error, stack);

      if (!mounted) return;

      _showChatSnack(
        context,
        _friendlyChatErrorMessage(
          error,
          fallback: 'Could not send emoji. Please try again.',
        ),
      );
    }
  }

  Future<void> _openGiphyPicker({
    required bool isSticker,
  }) async {
    if (_isUploadingAttachment || _isUploadingVoice || _isRecording) return;

    if (kPingmeeGiphyApiKey.contains('PASTE_')) {
      _showChatSnack(context, 'GIPHY is not set up yet.');
      return;
    }

    try {
      final gif = await GiphyGet.getGif(
        context: context,
        apiKey: kPingmeeGiphyApiKey,
        lang: GiphyLanguage.english,
        tabColor: AppColors.brandGreen,
        debounceTimeInMilliseconds: 350,
        showGIFs: !isSticker,
        showStickers: isSticker,
        showEmojis: false,
      );

      if (gif == null) return;

      await _sendGiphyMedia(
        gif: gif,
        isSticker: isSticker,
      );
    } catch (error, stack) {
      _logChatError(
        isSticker
            ? 'Open GIPHY sticker picker failed'
            : 'Open GIPHY GIF picker failed',
        error,
        stack,
      );

      if (!mounted) return;

      _showChatSnack(
        context,
        isSticker
            ? 'Could not open sticker library. Please try again.'
            : 'Could not open GIF library. Please try again.',
      );
    }
  }

  Future<void> _sendGiphyMedia({
    required GiphyGif gif,
    required bool isSticker,
  }) async {
    if (_isUploadingAttachment || _isUploadingVoice || _isRecording) return;

    final url = _bestGiphyUrl(gif);
    final previewUrl = _bestGiphyPreviewUrl(gif);

    if (url.isEmpty) {
      _showChatSnack(
        context,
        isSticker
            ? 'Could not send sticker. Please try again.'
            : 'Could not send GIF. Please try again.',
      );
      return;
    }

    try {
      final dynamic g = gif;
      final title = _readGiphyText(() => g.title);
      final id = _readGiphyText(() => g.id);

      final channel = StreamChannel.of(context).channel;

      Message message = Message(
        text: isSticker ? 'Sent sticker' : 'Sent GIF',
        attachments: [
          Attachment(
            uploadState: const UploadState.success(),
            type: isSticker ? 'sticker' : 'image',
            assetUrl: url,
            imageUrl: url,
            thumbUrl: previewUrl,
            title: title,
            fallback: isSticker ? 'Sticker' : 'GIF',
            extraData: {
              'pingmeeGiphy': true,
              'pingmeeSticker': isSticker,
              'giphyId': id,
              'giphyTitle': title,
              'url': url,
              'previewUrl': previewUrl,
            },
          ),
        ],
        extraData: {
          'pingmeeAttachment': true,
          'pingmeeGeneratedText': true,
          'pingmeeGiphyMessage': true,
          if (isSticker) 'pingmeeStickerMessage': true,
        },
      );

      if (widget.preMessageSending != null) {
        message = widget.preMessageSending!(message);
      }

      final sentMessage = await channel.sendMessage(message);

      debugPrint(
        isSticker
            ? '✅ GIPHY sticker sent id=${sentMessage.message.id}'
            : '✅ GIPHY GIF sent id=${sentMessage.message.id}',
      );

      HapticFeedback.selectionClick();
    } catch (error, stack) {
      _logChatError(
        isSticker ? 'GIPHY sticker send failed' : 'GIPHY GIF send failed',
        error,
        stack,
      );

      if (!mounted) return;

      _showChatSnack(
        context,
        _friendlyChatErrorMessage(
          error,
          fallback: isSticker
              ? 'Could not send sticker. Please try again.'
              : 'Could not send GIF. Please try again.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = StreamChatTheme.of(context);

    final channel = StreamChannel.of(context).channel;
    final isPingChannel = pingmeeIsPingChannel(channel);

    final person = isPingChannel
        ? const PingmeeChatPerson(
            id: '',
            name: '',
            image: '',
            online: false,
          )
        : pingmeeOtherDmPerson(
            context: context,
            channel: channel,
          );

    final themedInput = baseTheme.copyWith(
      messageInputTheme: baseTheme.messageInputTheme.copyWith(
        sendButtonColor: const Color(0xFF111827),
        sendButtonIdleColor: Colors.black.withOpacity(.30),

        actionButtonColor: const Color(0xFF111827),
        actionButtonIdleColor: const Color(0xFF111827),

        expandButtonColor: const Color(0xFF111827),
        linkHighlightColor: Colors.black.withOpacity(.10),

        inputBackgroundColor: const Color(0xFFF1F2F4),

        activeBorderGradient: const LinearGradient(
          colors: [
            Color(0xFFF1F2F4),
            Color(0xFFF1F2F4),
          ],
        ),

        idleBorderGradient: const LinearGradient(
          colors: [
            Color(0xFFF1F2F4),
            Color(0xFFF1F2F4),
          ],
        ),

        borderRadius: BorderRadius.zero,

        inputTextStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontSize: 15.8,
          fontWeight: FontWeight.w500,
          color: Color(0xFF111827),
          height: 1.25,
        ),

        inputDecoration: InputDecoration(
          // Base fallback. The real hint gets injected below from Firestore.
          hintText: 'Message',
          hintStyle: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 15.8,
            fontWeight: FontWeight.w500,
            color: Colors.black.withOpacity(.34),
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: false,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 7,
          ),
        ),
      ),
    );

    final requestRef = _outgoingMessageRequestRefForContext(context);

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: pingmeeIsPingChannel(channel) || person.id.trim().isEmpty
        ? null
        : firestore.FirebaseFirestore.instance
            .collection('users')
            .doc(person.id.trim())
            .snapshots(),
  builder: (context, snap) {
    final isPingChannel = pingmeeIsPingChannel(channel);

    final composerHint = isPingChannel
        ? 'Message this ping'
        : _composerHintFromUserData(
            snap.data?.data(),
            fallbackName: person.name,
          );

    final inputThemeWithHint = themedInput.copyWith(
      messageInputTheme: themedInput.messageInputTheme.copyWith(
        inputDecoration:
            themedInput.messageInputTheme.inputDecoration?.copyWith(
                  hintText: composerHint,
                ) ??
                InputDecoration(
                  hintText: composerHint,
                ),
      ),
    );

    final requestRef = _outgoingMessageRequestRefForContext(context);
    
    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
        stream: requestRef?.snapshots(),
        builder: (context, requestSnap) {
          final requestData = requestSnap.data?.data();

          final isPendingRequest = requestSnap.data?.exists == true &&
              _isPendingOutgoingRequest(requestData);

          final remaining = _requestMessagesRemaining(requestData);
          final maxMessages = _requestMaxMessages(requestData);
          final requestLocked = isPendingRequest && remaining <= 0;

          void showRequestLimitSnack() {
            _showChatSnack(
              context,
              'You have used all 3 request messages. Wait for them to accept your request.',
            );
            HapticFeedback.mediumImpact();
          }

          return StreamChatTheme(
            data: inputThemeWithHint,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 3, 12, 5),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPendingRequest)
                      _OutgoingMessageRequestLimitBanner(
                        remaining: remaining,
                        maxMessages: maxMessages,
                      ),

                    if (_isRecording || _isUploadingVoice) ...[
                      _PingmeeRecordingBar(
                        elapsed: _recordingDuration,
                        uploading: _isUploadingVoice,
                        onCancel: _isUploadingVoice ? null : _cancelRecording,
                        onSend: _isUploadingVoice ? null : _stopAndSendRecording,
                        formatTime: _formatRecordingTime,
                      ),
                      const SizedBox(height: 8),
                    ],

                    if (_isUploadingAttachment || _isUploadingVoice) ...[
                      _PingmeeAttachmentUploadingBar(
                        label: _attachmentUploadLabel,
                        progress: _attachmentUploadProgress,
                      ),
                      const SizedBox(height: 8),
                    ],

                    _PingmeeQuickEmojiRail(
                      onEmojiTap: requestLocked
                          ? (_) => showRequestLimitSnack()
                          : _sendBigEmoji,
                    ),

                    const SizedBox(height: 8),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _PingmeeComposerRoundButton(
                          icon: PhosphorIcons.camera(PhosphorIconsStyle.fill),
                          onTap: requestLocked
                              ? showRequestLimitSnack
                              : _openPingmeeAttachmentSheet,
                        ),

                        if (widget.allowPolls && isPingChannel) ...[
                          const SizedBox(width: 8),
                          _PingmeeComposerRoundButton(
                            icon: PhosphorIcons.chartPieSlice(
                              PhosphorIconsStyle.fill,
                            ),
                            onTap: requestLocked
                                ? showRequestLimitSnack
                                : _openPollSheet,
                          ),
                        ],

                        const SizedBox(width: 8),

                        Expanded(
                          child: StreamMessageInput(
                            messageInputController: widget.messageInputController,
                            preMessageSending: (message) {
                              if (requestLocked) {
                                showRequestLimitSnack();
                                throw StateError(
                                  'message_request_limit_reached',
                                );
                              }

                              if (isPendingRequest) {
                                unawaited(
                                  _tryConsumeOutgoingRequestMessageSlot(context),
                                );
                              }

                              final cleanedMessage =
                                  _removeVoiceFileLabel(message);

                              if (widget.preMessageSending != null) {
                                return widget.preMessageSending!(cleanedMessage);
                              }

                              return cleanedMessage;
                            },
                            customAutocompleteTriggers: [
                              StreamAutocompleteTrigger(
                                trigger: '@',
                                minimumRequiredCharacters: 0,
                                optionsViewBuilder: (
                                  context,
                                  autocompleteQuery,
                                  messageEditingController,
                                ) {
                                  return _PingmeeMentionAutocompleteOptions(
                                    query: autocompleteQuery.query,
                                  );
                                },
                              ),
                            ],
                            onQuotedMessageCleared:
                                widget.onQuotedMessageCleared,

                            enableVoiceRecording: false,

                            actionsLocation: ActionsLocation.right,
                            sendButtonLocation: SendButtonLocation.inside,
                            spaceBetweenActions: 10,

                            minLines: 1,
                            maxLines: 4,
                            maxHeight: 128,
                            textInputAction: TextInputAction.newline,
                            keyboardType: TextInputType.multiline,
                            textCapitalization: TextCapitalization.sentences,

                            padding: const EdgeInsets.fromLTRB(7, 0, 7, 0),
                            textInputMargin: const EdgeInsets.only(
                              left: 4,
                              right: 6,
                            ),
                            elevation: 0,
                            shadow: const BoxShadow(
                              color: Colors.transparent,
                              blurRadius: 0,
                            ),

                            hintGetter: (context, _) {
                              return composerHint;
                            },

                            quotedMessageBuilder: (context, message) {
                              return _PingmeeQuotedReplyPreview(
                                message: message,
                                onClose: widget.onQuotedMessageCleared,
                              );
                            },

                            attachmentButtonBuilder:
                                (context, attachmentButton) {
                              return const SizedBox.shrink();
                            },

                            commandButtonBuilder: (context, commandButton) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Material(
                                  color: Colors.transparent,
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    onTap: requestLocked
                                        ? showRequestLimitSnack
                                        : _openPingmeeLibrarySheet,
                                    customBorder: const CircleBorder(),
                                    child: _PingmeeInputButtonShell(
                                      child: Icon(
                                        PhosphorIcons.smiley(
                                          PhosphorIconsStyle.fill,
                                        ),
                                        size: 20,
                                        color: const Color(0xFF111827),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },

                            idleSendIcon: Icon(
                              PhosphorIcons.arrowUp(
                                PhosphorIconsStyle.bold,
                              ),
                              color: Colors.black.withOpacity(.30),
                              size: 22,
                            ),

                            activeSendIcon: Container(
                              width: 32,
                              height: 32,
                              decoration: const BoxDecoration(
                                color: Color(0xFF111827),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                PhosphorIcons.arrowUp(
                                  PhosphorIconsStyle.bold,
                                ),
                                color: Colors.white,
                                size: 19,
                              ),
                            ),

                            onError: (error, stackTrace) {
                              debugPrint('❌ Stream input error: $error');
                              debugPrintStack(stackTrace: stackTrace);
                            },
                          ),
                        ),

                        const SizedBox(width: 8),

                        _PingmeeVoiceRecordButton(
                          recording: _isRecording,
                          uploading: _isUploadingVoice,
                          onTap: requestLocked
                              ? showRequestLimitSnack
                              : _toggleRecording,
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
    },
  );
  }

  void _showComposerActionHint(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _PingmeeCreatePollSheet extends StatefulWidget {
  const _PingmeeCreatePollSheet();

  @override
  State<_PingmeeCreatePollSheet> createState() =>
      _PingmeeCreatePollSheetState();
}

class _PingmeeCreatePollSheetState extends State<_PingmeeCreatePollSheet> {
  final TextEditingController _questionCtrl = TextEditingController();
  final List<TextEditingController> _optionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];

  @override
  void dispose() {
    _questionCtrl.dispose();

    for (final ctrl in _optionCtrls) {
      ctrl.dispose();
    }

    super.dispose();
  }

  void _addOption() {
    if (_optionCtrls.length >= 8) return;

    setState(() {
      _optionCtrls.add(TextEditingController());
    });
  }

  void _removeOption(int index) {
    if (_optionCtrls.length <= 2) return;

    final ctrl = _optionCtrls.removeAt(index);
    ctrl.dispose();

    setState(() {});
  }

  void _submit() {
    final question = _questionCtrl.text.trim();
    final options = _optionCtrls
        .map((ctrl) => ctrl.text.trim())
        .where((text) => text.isNotEmpty)
        .toSet()
        .toList();

    if (question.isEmpty) {
      _showChatSnack(context, 'Poll question is required.');
      return;
    }

    if (options.length < 2) {
      _showChatSnack(context, 'Add at least two poll options.');
      return;
    }

    Navigator.of(context).pop(
      _PingmeePollDraft(
        question: question,
        options: options,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(14),
          constraints: BoxConstraints(
            maxHeight: media.size.height * .82,
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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

              const SizedBox(height: 14),

              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.06),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      PhosphorIcons.chartPieSlice(
                        PhosphorIconsStyle.fill,
                      ),
                      size: 21,
                      color: const Color(0xFF111827),
                    ),
                  ),

                  const SizedBox(width: 12),

                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Create poll',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Ask the group and let everyone vote.',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ),

                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      PhosphorIcons.x(PhosphorIconsStyle.bold),
                      size: 20,
                      color: Colors.black.withOpacity(.62),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      _PingmeePollTextField(
                        controller: _questionCtrl,
                        label: 'Question',
                        hint: 'Where should we meet?',
                        maxLines: 2,
                      ),

                      const SizedBox(height: 14),

                      for (int i = 0; i < _optionCtrls.length; i++) ...[
                        _PingmeePollOptionField(
                          controller: _optionCtrls[i],
                          index: i,
                          canRemove: _optionCtrls.length > 2,
                          onRemove: () => _removeOption(i),
                        ),
                        const SizedBox(height: 10),
                      ],

                      if (_optionCtrls.length < 8)
                        Material(
                          color: const Color(0xFFF5F6F8),
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            onTap: _addOption,
                            borderRadius: BorderRadius.circular(18),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 13,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    PhosphorIcons.plusCircle(
                                      PhosphorIconsStyle.fill,
                                    ),
                                    size: 20,
                                    color: const Color(0xFF111827),
                                  ),
                                  const SizedBox(width: 10),
                                  const Text(
                                    'Add option',
                                    style: TextStyle(
                                      fontFamily: 'Nunito',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _submit,
                  icon: Icon(
                    PhosphorIcons.paperPlaneTilt(
                      PhosphorIconsStyle.fill,
                    ),
                    size: 18,
                    color: Colors.white,
                  ),
                  label: const Text(
                    'Send poll',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF111827),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
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

class _PingmeePollTextField extends StatelessWidget {
  const _PingmeePollTextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: label == 'Question' ? 80 : 40,
      textCapitalization: TextCapitalization.sentences,
      style: const TextStyle(
        fontFamily: 'Nunito',
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
        color: Color(0xFF111827),
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: const Color(0xFFF5F6F8),
        labelStyle: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w700,
          color: Colors.black.withOpacity(.55),
        ),
        hintStyle: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w500,
          color: Colors.black.withOpacity(.32),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      ),
    );
  }
}

class _PingmeePollOptionField extends StatelessWidget {
  const _PingmeePollOptionField({
    required this.controller,
    required this.index,
    required this.canRemove,
    required this.onRemove,
  });

  final TextEditingController controller;
  final int index;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _PingmeePollTextField(
            controller: controller,
            label: 'Option ${index + 1}',
            hint: index == 0 ? 'Yes' : 'No',
          ),
        ),

        if (canRemove) ...[
          const SizedBox(width: 8),
          Material(
            color: Colors.black.withOpacity(.055),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  PhosphorIcons.trash(PhosphorIconsStyle.light),
                  size: 20,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PingmeeVoiceRecordButton extends StatelessWidget {
  const _PingmeeVoiceRecordButton({
    required this.recording,
    required this.uploading,
    required this.onTap,
  });

  final bool recording;
  final bool uploading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = recording
        ? const Color(0xFFEF4444)
        : Colors.black;

    final iconColor = Colors.white;

    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: uploading ? null : onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Center(
            child: uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Icon(
                    recording
                        ? PhosphorIcons.paperPlaneTilt(
                            PhosphorIconsStyle.fill,
                          )
                        : PhosphorIcons.microphone(
                            PhosphorIconsStyle.fill,
                          ),
                    size: 21,
                    color: iconColor,
                  ),
          ),
        ),
      ),
    );
  }
}

class _PingmeeRecordingBar extends StatelessWidget {
  const _PingmeeRecordingBar({
    required this.elapsed,
    required this.uploading,
    required this.onCancel,
    required this.onSend,
    required this.formatTime,
  });

  final Duration elapsed;
  final bool uploading;
  final VoidCallback? onCancel;
  final VoidCallback? onSend;
  final String Function(Duration value) formatTime;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: uploading
                  ? AppColors.brandGreen
                  : const Color(0xFFEF4444),
              shape: BoxShape.circle,
            ),
          ),

          const SizedBox(width: 9),

          Expanded(
            child: Text(
              uploading
                  ? 'Sending voice note...'
                  : 'Recording ${formatTime(elapsed)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),
          ),

          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onCancel,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Icon(
                  PhosphorIcons.x(PhosphorIconsStyle.bold),
                  size: 15,
                  color: Colors.black.withOpacity(.55),
                ),
              ),
            ),
          ),

          const SizedBox(width: 8),

          Material(
            color: AppColors.brandGreen,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onSend,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Icon(
                  PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.fill),
                  size: 16,
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

class _PingmeeAttachmentUploadingBar extends StatelessWidget {
  const _PingmeeAttachmentUploadingBar({
    required this.label,
    required this.progress,
  });

  final String label;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final safeProgress = progress.clamp(0.0, 1.0);
    final percentage = (safeProgress * 100).round();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  value: safeProgress <= 0 ? null : safeProgress,
                  strokeWidth: 3,
                  valueColor: const AlwaysStoppedAnimation(Colors.black),
                  backgroundColor: Colors.black.withOpacity(.08),
                ),
              ),
              Text(
                safeProgress <= 0 ? '' : '$percentage',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
              ),
            ],
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: safeProgress <= 0 ? null : safeProgress,
                    backgroundColor: Colors.black.withOpacity(.08),
                    valueColor: const AlwaysStoppedAnimation(Colors.black),
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

class _PingmeeAttachmentSheet extends StatelessWidget {
  const _PingmeeAttachmentSheet({
    required this.onCamera,
    required this.onGallery,
    required this.onVideo,
    required this.onFile,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onVideo;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
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
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Color(0xFF111827),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    PhosphorIcons.paperclip(PhosphorIconsStyle.bold),
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Add to message',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _PingmeeAttachmentAction(
                    icon: PhosphorIcons.camera(PhosphorIconsStyle.bold),
                    label: 'Camera',
                    onTap: onCamera,
                  ),
                  const SizedBox(width: 10),
                  _PingmeeAttachmentAction(
                    icon: PhosphorIcons.images(PhosphorIconsStyle.bold),
                    label: 'Gallery',
                    onTap: onGallery,
                  ),
                  const SizedBox(width: 10),
                  _PingmeeAttachmentAction(
                    icon: PhosphorIcons.videoCamera(PhosphorIconsStyle.bold),
                    label: 'Video',
                    onTap: onVideo,
                  ),
                  const SizedBox(width: 10),
                  _PingmeeAttachmentAction(
                    icon: PhosphorIcons.file(PhosphorIconsStyle.bold),
                    label: 'File',
                    onTap: onFile,
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

class _PingmeeAttachmentAction extends StatelessWidget {
  const _PingmeeAttachmentAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 82,
      child: Material(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.06),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    color: Colors.black,
                    size: 20,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black.withOpacity(.72),
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

class _PingmeeMentionAutocompleteOptions extends StatelessWidget {
  const _PingmeeMentionAutocompleteOptions({
    required this.query,
  });

  final String query;

  List<String> _chatMemberIds(BuildContext context) {
    final channel = StreamChannel.of(context).channel;
    final currentUserId = StreamChat.of(context).currentUser?.id;

    return (channel.state?.members ?? const <Member>[])
        .map((member) => (member.userId ?? member.user?.id ?? '').trim())
        .where((id) => id.isNotEmpty && id != currentUserId)
        .toSet()
        .take(10) // Firestore whereIn limit safety for V1.
        .toList();
  }

  String _photoFrom(Map<String, dynamic> data) {
    return (data['photoUrl'] ??
            data['photoURL'] ??
            data['profilePhotoUrl'] ??
            data['avatarUrl'] ??
            data['image'] ??
            '')
        .toString()
        .trim();
  }

  String _nameFrom(Map<String, dynamic> data) {
    return pingmeeFullNameFromUserData(data);
  }

  bool _matches(Map<String, dynamic> data) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;

    final name = _nameFrom(data).toLowerCase();
    final username = (data['username'] ?? '').toString().toLowerCase();
    final headline =
        (data['headline'] ?? data['intro'] ?? '').toString().toLowerCase();

    return name.contains(q) ||
        username.contains(q) ||
        headline.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final memberIds = _chatMemberIds(context);

    if (memberIds.isEmpty) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 260),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              blurRadius: 24,
              offset: const Offset(0, 12),
              color: Colors.black.withOpacity(.10),
            ),
          ],
        ),
        child: StreamBuilder<firestore.QuerySnapshot<Map<String, dynamic>>>(
          stream: firestore.FirebaseFirestore.instance
              .collection('users')
              .where(firestore.FieldPath.documentId, whereIn: memberIds)
              .snapshots(),
          builder: (context, snap) {
            final docs = (snap.data?.docs ?? []).where((doc) {
              return _matches(doc.data());
            }).toList()
              ..sort((a, b) {
                return _nameFrom(a.data()).compareTo(_nameFrom(b.data()));
              });

            if (docs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Text(
                  'No people in this chat',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.48),
                  ),
                ),
              );
            }

            return ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 2),
              itemBuilder: (context, index) {
                final data = docs[index].data();

                final name = _nameFrom(data);
                final photo = _photoFrom(data);

                return InkWell(
                  onTap: () {
                    // Inserts "@Full Name"
                    StreamAutocomplete.of(context).acceptAutocompleteOption(
                      name,
                      keepTrigger: true,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor:
                              AppColors.brandGreen.withOpacity(.10),
                          backgroundImage:
                              photo.isEmpty ? null : NetworkImage(photo),
                          child: photo.isEmpty
                              ? Icon(
                                  PhosphorIcons.user(
                                    PhosphorIconsStyle.light,
                                  ),
                                  size: 17,
                                  color: AppColors.brandGreen,
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF111827), // ✅ black in search
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PingmeeQuickEmojiRail extends StatelessWidget {
  const _PingmeeQuickEmojiRail({
    required this.onEmojiTap,
  });

  final ValueChanged<String> onEmojiTap;

  static const List<String> _items = [
    '👋',
    '😂',
    '❤️',
    '🔥',
    '👍',
    '🥺',
    '🙌',
    '👀',
    '🎉',
    '😮',
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final emoji = _items[index];

          return Material(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () => onEmojiTap(emoji),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 21),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OutgoingMessageRequestLimitBanner extends StatelessWidget {
  const _OutgoingMessageRequestLimitBanner({
    required this.remaining,
    required this.maxMessages,
  });

  final int remaining;
  final int maxMessages;

  @override
  Widget build(BuildContext context) {
    final locked = remaining <= 0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.black.withOpacity(.045),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: locked ? const Color(0xFF991B1B) : Colors.black,
              shape: BoxShape.circle,
            ),
            child: Icon(
              locked
                  ? PhosphorIcons.lock(PhosphorIconsStyle.bold)
                  : PhosphorIcons.paperPlaneTilt(PhosphorIconsStyle.bold),
              color: Colors.white,
              size: 17,
            ),
          ),

          const SizedBox(width: 11),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _requestRemainingText(remaining),
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.8,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                    height: 1.18,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'You can send up to $maxMessages messages before they accept your message request',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.6,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.52),
                    height: 1.25,
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

class _PingmeeComposerRoundButton extends StatelessWidget {
  const _PingmeeComposerRoundButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF111827),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: Colors.white.withOpacity(.12),
        highlightColor: Colors.white.withOpacity(.06),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _PingmeeInputButtonShell extends StatelessWidget {
  const _PingmeeInputButtonShell({
    required this.child,
    this.isPrimary = false,
  });

  final Widget child;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isPrimary
        ? const Color(0xFF111827)
        : const Color(0xFFF3F4F6);

    final iconColor = isPrimary
        ? Colors.white
        : const Color(0xFF111827);

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: IconTheme(
          data: IconThemeData(
            color: iconColor,
            size: 20,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PingmeeQuotedReplyPreview extends StatelessWidget {
  const _PingmeeQuotedReplyPreview({
    required this.message,
    required this.onClose,
  });

  final Message message;
  final VoidCallback? onClose;

  String _previewText() {
    final text = (message.text ?? '').trim();

    if (text.isNotEmpty) return text;

    if (message.attachments.isNotEmpty) {
      final type = (message.attachments.first.type ?? '').toLowerCase();

      if (type.contains('image')) return 'Photo';
      if (type.contains('video')) return 'Video';
      if (type.contains('voice') || type.contains('audio')) {
        return 'Voice message';
      }
      if (type.contains('giphy') || type.contains('gif')) return 'GIF';

      return 'Attachment';
    }

    return 'Message';
  }

  @override
  Widget build(BuildContext context) {
    final senderName = (message.user?.name ?? 'Reply').trim();

    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 10),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderName.isEmpty ? 'Replying' : senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.brandGreen,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _previewText(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.2,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.56),
                  ),
                ),
              ],
            ),
          ),

          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onClose,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(
                  PhosphorIcons.x(PhosphorIconsStyle.bold),
                  size: 15,
                  color: Colors.black.withOpacity(.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCallButton extends StatelessWidget {
  const _HeaderCallButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            icon,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _PingmeeCallStartSheet extends StatelessWidget {
  const _PingmeeCallStartSheet({
    required this.person,
    required this.video,
  });

  final PingmeeChatPerson person;
  final bool video;

  void _openCallScreen(BuildContext context) {
    Navigator.of(context).pop();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PingmeeLiveCallScreen(
          person: person,
          video: video,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = video ? 'Start video call?' : 'Start voice call?';
    final subtitle = video
        ? 'Open a face-to-face Pingmee call with ${person.name}.'
        : 'Start a clean audio call with ${person.name}.';

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              blurRadius: 30,
              offset: const Offset(0, 18),
              color: Colors.black.withOpacity(.16),
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
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),

            const SizedBox(height: 22),

            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandGreen.withOpacity(.08),
                  ),
                ),
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandGreen.withOpacity(.12),
                  ),
                ),
                CircleAvatar(
                  radius: 36,
                  backgroundColor: AppColors.brandGreen.withOpacity(.14),
                  backgroundImage:
                      person.image.isEmpty ? null : NetworkImage(person.image),
                  child: person.image.isEmpty
                      ? Icon(
                          PhosphorIcons.user(PhosphorIconsStyle.light),
                          color: AppColors.brandGreen,
                          size: 30,
                        )
                      : null,
                ),
                Positioned(
                  right: 4,
                  bottom: 12,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: 3,
                      ),
                    ),
                    child: Icon(
                      video
                          ? PhosphorIcons.videoCamera(PhosphorIconsStyle.bold)
                          : PhosphorIcons.phoneCall(PhosphorIconsStyle.bold),
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),

            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),

            const SizedBox(height: 7),

            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14.5,
                fontWeight: FontWeight.w400,
                color: Colors.black.withOpacity(.52),
                height: 1.35,
              ),
            ),

            const SizedBox(height: 22),

            Row(
              children: [
                Expanded(
                  child: _CallSheetButton(
                    label: 'Cancel',
                    backgroundColor: const Color(0xFFF2F4F7),
                    textColor: const Color(0xFF111827),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _CallSheetButton(
                    label: video ? 'Video call' : 'Voice call',
                    backgroundColor: AppColors.brandGreen,
                    textColor: Colors.white,
                    onTap: () => _openCallScreen(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallSheetButton extends StatelessWidget {
  const _CallSheetButton({
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    required this.onTap,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: 52,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PingmeeCallPreviewScreen extends StatelessWidget {
  const _PingmeeCallPreviewScreen({
    required this.person,
    required this.video,
  });

  final PingmeeChatPerson person;
  final bool video;

  @override
  Widget build(BuildContext context) {
    final isVideo = video;

    return Scaffold(
      backgroundColor: isVideo ? const Color(0xFF05070A) : Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: isVideo
                  ? _VideoCallPreviewBody(person: person)
                  : _VoiceCallPreviewBody(person: person),
            ),

            Positioned(
              left: 18,
              right: 18,
              bottom: 24,
              child: _CallControlDock(
                video: video,
                onEnd: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceCallPreviewBody extends StatelessWidget {
  const _VoiceCallPreviewBody({
    required this.person,
  });

  final PingmeeChatPerson person;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.55),
          radius: 1.1,
          colors: [
            Color(0xFFE8FFF7),
            Color(0xFFFFFFFF),
          ],
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 70),

          Text(
            'Calling',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.42),
            ),
          ),

          const SizedBox(height: 8),

          Text(
            person.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 28,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),

          const SizedBox(height: 50),

          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.brandGreen.withOpacity(.06),
                ),
              ),
              Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.brandGreen.withOpacity(.10),
                ),
              ),
              CircleAvatar(
                radius: 58,
                backgroundColor: AppColors.brandGreen.withOpacity(.14),
                backgroundImage:
                    person.image.isEmpty ? null : NetworkImage(person.image),
                child: person.image.isEmpty
                    ? Icon(
                        PhosphorIcons.user(PhosphorIconsStyle.light),
                        color: AppColors.brandGreen,
                        size: 44,
                      )
                    : null,
              ),
            ],
          ),

          const SizedBox(height: 26),

          Text(
            'Pingmee voice',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoCallPreviewBody extends StatelessWidget {
  const _VideoCallPreviewBody({
    required this.person,
  });

  final PingmeeChatPerson person;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF05070A),
      child: Column(
        children: [
          const SizedBox(height: 70),

          Text(
            person.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 25,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            'Pingmee video',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white.withOpacity(.52),
            ),
          ),

          const Spacer(),

          Container(
            width: 180,
            height: 240,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.08),
              borderRadius: BorderRadius.circular(34),
              border: Border.all(
                color: Colors.white.withOpacity(.10),
                width: 1,
              ),
            ),
            child: Center(
              child: CircleAvatar(
                radius: 50,
                backgroundColor: AppColors.brandGreen.withOpacity(.18),
                backgroundImage:
                    person.image.isEmpty ? null : NetworkImage(person.image),
                child: person.image.isEmpty
                    ? Icon(
                        PhosphorIcons.user(PhosphorIconsStyle.light),
                        color: Colors.white,
                        size: 42,
                      )
                    : null,
              ),
            ),
          ),

          const Spacer(),
          const SizedBox(height: 120),
        ],
      ),
    );
  }
}

class _CallControlDock extends StatelessWidget {
  const _CallControlDock({
    required this.video,
    required this.onEnd,
  });

  final bool video;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: video ? Colors.white.withOpacity(.10) : const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: video ? Colors.white.withOpacity(.10) : Colors.black.withOpacity(.04),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CallControlButton(
            icon: PhosphorIcons.microphone(PhosphorIconsStyle.bold),
            backgroundColor: video
                ? Colors.white.withOpacity(.12)
                : Colors.white,
            iconColor: video ? Colors.white : const Color(0xFF111827),
            onTap: () {},
          ),

          if (video)
            _CallControlButton(
              icon: PhosphorIcons.videoCamera(PhosphorIconsStyle.bold),
              backgroundColor: Colors.white.withOpacity(.12),
              iconColor: Colors.white,
              onTap: () {},
            ),

          _CallControlButton(
            icon: PhosphorIcons.speakerHigh(PhosphorIconsStyle.bold),
            backgroundColor: video
                ? Colors.white.withOpacity(.12)
                : Colors.white,
            iconColor: video ? Colors.white : const Color(0xFF111827),
            onTap: () {},
          ),

          _CallControlButton(
            icon: PhosphorIcons.phoneDisconnect(PhosphorIconsStyle.bold),
            backgroundColor: const Color(0xFFEF4444),
            iconColor: Colors.white,
            onTap: onEnd,
          ),
        ],
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.icon,
    required this.backgroundColor,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final Color backgroundColor;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            icon,
            size: 22,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

class _SharedMediaItem {
  const _SharedMediaItem({
    required this.message,
    required this.attachment,
  });

  final Message message;
  final Attachment attachment;
}

class _SharedChatContentScreen extends StatefulWidget {
  const _SharedChatContentScreen({
    required this.channel,
    required this.person,
  });

  final Channel channel;
  final PingmeeChatPerson person;

  @override
  State<_SharedChatContentScreen> createState() =>
      _SharedChatContentScreenState();
}

class _SharedContentEmptyState extends StatelessWidget {
  const _SharedContentEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData Function(PhosphorIconsStyle style) icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 120),
      physics: const BouncingScrollPhysics(),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
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
                  icon(PhosphorIconsStyle.bold),
                  color: Colors.white,
                  size: 27,
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
                  color: Colors.black,
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
        ),
      ],
    );
  }
}

class _SharedMediaViewerScreen extends StatelessWidget {
  const _SharedMediaViewerScreen({
    required this.url,
    required this.attachment,
  });

  final String url;
  final Attachment attachment;

  bool get _isVideo {
    final type = (attachment.type ?? '').toLowerCase();
    final mimeType =
        (attachment.extraData['mime_type'] ??
                attachment.extraData['mimeType'] ??
                attachment.extraData['contentType'] ??
                '')
            .toString()
            .toLowerCase();

    return type == 'video' || mimeType.startsWith('video/');
  }

  Future<void> _openExternal(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: url),
    );

    if (!context.mounted) return;

    _showChatSnack(context, 'Media link copied.');
  }

  void _showOptions(BuildContext context) {
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
                _OpenChatSheetRow(
                  icon: PhosphorIcons.shareNetwork(PhosphorIconsStyle.light),
                  title: 'Share',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _copyLink(context);
                  },
                ),

                const SizedBox(height: 8),

                _OpenChatSheetRow(
                  icon: PhosphorIcons.downloadSimple(PhosphorIconsStyle.light),
                  title: 'Open / download',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _openExternal(context);
                  },
                ),

                const SizedBox(height: 8),

                _OpenChatSheetRow(
                  icon: PhosphorIcons.link(PhosphorIconsStyle.light),
                  title: 'Copy link',
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _copyLink(context);
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: _isVideo
                    ? Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _openExternal(context),
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            width: 82,
                            height: 82,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.14),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 52,
                            ),
                          ),
                        ),
                      )
                    : InteractiveViewer(
                        minScale: .75,
                        maxScale: 4,
                        child: Image.network(
                          url,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) {
                            return Icon(
                              PhosphorIcons.imageBroken(
                                PhosphorIconsStyle.light,
                              ),
                              color: Colors.white.withOpacity(.72),
                              size: 54,
                            );
                          },
                        ),
                      ),
              ),
            ),

            Positioned(
              left: 8,
              top: 8,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),

            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                onPressed: () => _showOptions(context),
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SharedChatContentScreenState extends State<_SharedChatContentScreen> {
  late Future<List<Message>> _messagesFuture;

  @override
  void initState() {
    super.initState();
    _messagesFuture = _loadMessages();
  }

  Future<List<Message>> _loadMessages() async {
    try {
      final state = await widget.channel.query(
        messagesPagination: const PaginationParams(
          limit: 100,
        ),
      );

      return state.messages ?? const <Message>[];
    } catch (_) {
      return widget.channel.state?.messages ?? const <Message>[];
    }
  }

  bool _isMediaAttachment(Attachment attachment) {
    final type = (attachment.type ?? '').toLowerCase();
    final mimeType =
        (attachment.extraData['mime_type'] ??
                attachment.extraData['mimeType'] ??
                attachment.extraData['contentType'] ??
                '')
            .toString()
            .toLowerCase();

    return type == 'image' ||
        type == 'video' ||
        mimeType.startsWith('image/') ||
        mimeType.startsWith('video/');
  }

  String _attachmentUrl(Attachment attachment) {
    final candidates = <Object?>[
      attachment.imageUrl,
      attachment.assetUrl,
      attachment.thumbUrl,
      attachment.titleLink,
      attachment.extraData['url'],
      attachment.extraData['asset_url'],
      attachment.extraData['assetUrl'],
      attachment.extraData['file_url'],
      attachment.extraData['fileUrl'],
    ];

    for (final item in candidates) {
      final value = (item ?? '').toString().trim();

      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }

    return '';
  }

  void _openSharedMediaItem(_SharedMediaItem item) {
    final url = _attachmentUrl(item.attachment);
    if (url.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SharedMediaViewerScreen(
          url: url,
          attachment: item.attachment,
        ),
      ),
    );
  }

  List<_SharedMediaItem> _mediaFrom(List<Message> messages) {
    final media = <_SharedMediaItem>[];

    for (final message in messages) {
      for (final attachment in message.attachments) {
        if (_isMediaAttachment(attachment)) {
          media.add(
            _SharedMediaItem(
              message: message,
              attachment: attachment,
            ),
          );
        }
      }
    }

    return media;
  }

  List<String> _linksFrom(List<Message> messages) {
    final links = <String>{};

    final regex = RegExp(
      r'(https?:\/\/[^\s]+)',
      caseSensitive: false,
    );

    for (final message in messages) {
      final text = (message.text ?? '').trim();

      for (final match in regex.allMatches(text)) {
        final link = match.group(0)?.trim();

        if (link != null && link.isNotEmpty) {
          links.add(link);
        }
      }

      for (final attachment in message.attachments) {
        final url = _attachmentUrl(attachment);

        if (url.isEmpty) continue;
        if (_isMediaAttachment(attachment)) continue;

        links.add(url);
      }
    }

    return links.toList();
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamChannel(
      channel: widget.channel,
      child: DefaultTabController(
        length: 3,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(
                          PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                          size: 23,
                          color: Colors.black.withOpacity(.78),
                        ),
                      ),

                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Shared content',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              widget.person.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Nunito',
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Colors.black.withOpacity(.46),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                Container(
                  height: 42,
                  margin: const EdgeInsets.symmetric(horizontal: 18),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: TabBar(
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    labelColor: Colors.black,
                    unselectedLabelColor: Colors.black.withOpacity(.46),
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
                      Tab(text: 'Moments'),
                      Tab(text: 'Media'),
                      Tab(text: 'Links'),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                Expanded(
                  child: FutureBuilder<List<Message>>(
                    future: _messagesFuture,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.brandGreen,
                            ),
                          ),
                        );
                      }

                      final messages = snap.data ?? const <Message>[];
                      final media = _mediaFrom(messages);
                      final links = _linksFrom(messages);

                      return TabBarView(
                        children: [
                          const _SharedContentEmptyState(
                            icon: PhosphorIcons.sparkle,
                            title: 'Moments coming soon',
                            subtitle:
                                'Shared moments from this conversation will appear here later.',
                          ),

                          media.isEmpty
                              ? const _SharedContentEmptyState(
                                  icon: PhosphorIcons.imagesSquare,
                                  title: 'No media yet',
                                  subtitle:
                                      'Photos and videos shared in this chat will appear here.',
                                )
                              : GridView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    120,
                                  ),
                                  physics: const BouncingScrollPhysics(),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                    childAspectRatio: 1,
                                  ),
                                  itemCount: media.length,
                                  itemBuilder: (context, index) {
                                    final item = media[index];
                                    final attachment = item.attachment;
                                    final url = _attachmentUrl(attachment);
                                    final type = (attachment.type ?? '').toLowerCase();

                                    return Material(
                                      color: Colors.transparent,
                                      borderRadius: BorderRadius.circular(18),
                                      child: InkWell(
                                        onTap: () => _openSharedMediaItem(item),
                                        borderRadius: BorderRadius.circular(18),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(18),
                                          child: Container(
                                            color: const Color(0xFFF3F4F6),
                                            child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            if (url.isNotEmpty)
                                              Image.network(
                                                url,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) {
                                                  return Icon(
                                                    PhosphorIcons.imageBroken(
                                                      PhosphorIconsStyle.light,
                                                    ),
                                                    color: Colors.black
                                                        .withOpacity(.42),
                                                  );
                                                },
                                              )
                                            else
                                              Icon(
                                                PhosphorIcons.image(
                                                  PhosphorIconsStyle.light,
                                                ),
                                                color: Colors.black
                                                    .withOpacity(.42),
                                              ),

                                            if (type == 'video')
                                              Center(
                                                child: Container(
                                                  width: 34,
                                                  height: 34,
                                                  decoration: BoxDecoration(
                                                    color: Colors.black
                                                        .withOpacity(.62),
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: const Icon(
                                                    Icons.play_arrow_rounded,
                                                    color: Colors.white,
                                                    size: 24,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      )
                                      )
                                    );
                                  },
                                ),

                          links.isEmpty
                              ? const _SharedContentEmptyState(
                                  icon: PhosphorIcons.link,
                                  title: 'No links yet',
                                  subtitle:
                                      'Links shared in this conversation will appear here.',
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    120,
                                  ),
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: links.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (context, index) {
                                    final url = links[index];

                                    return Material(
                                      color: const Color(0xFFF5F7FA),
                                      borderRadius: BorderRadius.circular(20),
                                      child: InkWell(
                                        onTap: () => _openLink(url),
                                        borderRadius: BorderRadius.circular(20),
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            13,
                                            12,
                                            13,
                                            12,
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 40,
                                                height: 40,
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(15),
                                                ),
                                                child: Icon(
                                                  PhosphorIcons.link(
                                                    PhosphorIconsStyle.bold,
                                                  ),
                                                  size: 19,
                                                  color: Colors.black
                                                      .withOpacity(.72),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  url,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontFamily: 'Nunito',
                                                    fontSize: 13.5,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF111827),
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
                        ],
                      );
                    },
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

class _PingmeeDmHeader extends StatelessWidget {
  const _PingmeeDmHeader();

  void _openCallStartSheet(
    BuildContext context, {
    required PingmeeChatPerson person,
    required bool video,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _PingmeeCallStartSheet(
          person: person,
          video: video,
        );
      },
    );
  }

  void _showHeaderActionSheet(BuildContext context) {
    final channel = StreamChannel.of(context).channel;

    final person = pingmeeOtherDmPerson(
      context: context,
      channel: channel,
    );

    Future<void> muteChat() async {
      final choice = await _showOpenChatMuteDurationSheet(context);
      if (choice == null) return;

      final now = DateTime.now();
      DateTime? mutedUntil;

      switch (choice) {
        case _OpenChatMuteDurationChoice.oneHour:
          mutedUntil = now.add(const Duration(hours: 1));
          break;
        case _OpenChatMuteDurationChoice.eightHours:
          mutedUntil = now.add(const Duration(hours: 8));
          break;
        case _OpenChatMuteDurationChoice.twentyFourHours:
          mutedUntil = now.add(const Duration(hours: 24));
          break;
        case _OpenChatMuteDurationChoice.forever:
          mutedUntil = null;
          break;
      }

      try {
        await _setOpenChatMuted(
          channel: channel,
          mutedUntil: mutedUntil,
        );

        if (!context.mounted) return;

        _showChatSnack(
          context,
          mutedUntil == null
              ? 'Chat muted until you change it.'
              : 'Chat muted.',
        );
      } catch (error) {
        if (!context.mounted) return;
        _showChatSnack(context, 'Could not mute chat: $error');
      }
    }

    void openMore() {
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
                  _OpenChatSheetRow(
                    icon: PhosphorIcons.userCircle(PhosphorIconsStyle.light),
                    title: 'View profile',
                    onTap: () {
                      Navigator.of(sheetContext).pop();

                      final uid = person.id.trim();
                      if (uid.isEmpty) return;

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ProfileTab(profileUid: uid),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 8),

                  _OpenChatSheetRow(
                    icon: PhosphorIcons.imagesSquare(PhosphorIconsStyle.light),
                    title: 'Shared content',
                    onTap: () {
                      Navigator.of(sheetContext).pop();

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _SharedChatContentScreen(
                            channel: channel,
                            person: person,
                          ),
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
                    _OpenChatHeaderAction(
                      icon: PhosphorIcons.archive(PhosphorIconsStyle.light),
                      label: 'Archive',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _archiveOpenChat(
                          context: context,
                          channel: channel,
                        );
                      },
                    ),

                    _OpenChatHeaderAction(
                      icon: PhosphorIcons.bellSlash(PhosphorIconsStyle.light),
                      label: 'Mute',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await muteChat();
                      },
                    ),

                    _OpenChatHeaderAction(
                      icon: PhosphorIcons.dotsThree(PhosphorIconsStyle.bold),
                      label: 'More',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        openMore();
                      },
                    ),

                    _OpenChatHeaderAction(
                      icon: PhosphorIcons.trash(PhosphorIconsStyle.light),
                      label: 'Delete',
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _deleteOpenChat(
                          context: context,
                          channel: channel,
                        );
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
    final channel = StreamChannel.of(context).channel;

    final person = pingmeeOtherDmPerson(
      context: context,
      channel: channel,
    );

    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(.06),
            width: 1,
          ),
        ),
      ),
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
                  color: Colors.black.withOpacity(.76),
                ),
              ),
            ),
          ),

          const SizedBox(width: 4),

          Expanded(
            child: _LiveHeaderIdentity(
              userId: person.id,
              fallbackName: person.name,
              fallbackImage: person.image,
            ),
          ),

          _HeaderCallButton(
            icon: PhosphorIcons.phoneCall(PhosphorIconsStyle.fill),
            onTap: () {
              _openCallStartSheet(
                context,
                person: person,
                video: false,
              );
            },
          ),

          const SizedBox(width: 6),

          _HeaderCallButton(
            icon: PhosphorIcons.videoCamera(PhosphorIconsStyle.fill),
            onTap: () {
              _openCallStartSheet(
                context,
                person: person,
                video: true,
              );
            },
          ),

          const SizedBox(width: 4),

          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => _showHeaderActionSheet(context),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  PhosphorIcons.dotsThreeVertical(PhosphorIconsStyle.bold),
                  size: 22,
                  color: Colors.black.withOpacity(.62),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeReplyWrapper extends StatefulWidget {
  const _SwipeReplyWrapper({
    required this.message,
    required this.isMyMessage,
    required this.onReply,
    required this.child,
  });

  final Message message;
  final bool isMyMessage;
  final ValueChanged<Message> onReply;
  final Widget child;

  @override
  State<_SwipeReplyWrapper> createState() => _SwipeReplyWrapperState();
}

class _SwipeReplyWrapperState extends State<_SwipeReplyWrapper> {
  static const double _triggerDistance = 76;

  double _dragDx = 0;
  bool _triggered = false;

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final delta = details.delta.dx;

    // Own messages: swipe left.
    // Other messages: swipe right.
    final validDirection = widget.isMyMessage ? delta < 0 : delta > 0;

    if (!validDirection) return;

    setState(() {
      _dragDx += delta;

      if (widget.isMyMessage) {
        _dragDx = _dragDx.clamp(-_triggerDistance, 0);
      } else {
        _dragDx = _dragDx.clamp(0, _triggerDistance);
      }

      _triggered = _dragDx.abs() >= _triggerDistance * .72;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final shouldReply = _dragDx.abs() >= _triggerDistance * .72;

    if (shouldReply) {
      widget.onReply(widget.message);
      HapticFeedback.selectionClick();
    }

    setState(() {
      _dragDx = 0;
      _triggered = false;
    });
  }

  void _onHorizontalDragCancel() {
    setState(() {
      _dragDx = 0;
      _triggered = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final messageAlignment =
        widget.isMyMessage ? Alignment.centerRight : Alignment.centerLeft;

    final iconAlignment =
        widget.isMyMessage ? Alignment.centerRight : Alignment.centerLeft;

    final iconOffset = widget.isMyMessage
        ? const EdgeInsets.only(right: 18)
        : const EdgeInsets.only(left: 18);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      child: Stack(
        alignment: messageAlignment, // ✅ not center
        children: [
          Positioned.fill(
            child: Align(
              alignment: iconAlignment,
              child: Padding(
                padding: iconOffset,
                child: AnimatedScale(
                  scale: _triggered ? 1.12 : 1,
                  duration: const Duration(milliseconds: 110),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _dragDx.abs() <= 4
                        ? 0
                        : (_dragDx.abs() / _triggerDistance).clamp(0.0, 1.0),
                    duration: const Duration(milliseconds: 80),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen.withOpacity(.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        PhosphorIcons.arrowBendUpLeft(
                          PhosphorIconsStyle.bold,
                        ),
                        size: 18,
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          AnimatedContainer(
            duration: _dragDx == 0
                ? const Duration(milliseconds: 180)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_dragDx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _ForwardMessageSheet extends StatefulWidget {
  const _ForwardMessageSheet({
    required this.sourceMessage,
    required this.sourceChannelCid,
  });

  final Message sourceMessage;
  final String sourceChannelCid;

  @override
  State<_ForwardMessageSheet> createState() => _ForwardMessageSheetState();
}

class _ForwardMessageSheetState extends State<_ForwardMessageSheet> {
  StreamChannelListController? _controller;
  bool _sending = false;

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

  Future<void> _forwardTo(Channel channel) async {
    if (_sending) return;

    final source = widget.sourceMessage;
    final text = (source.text ?? '').trim();
    final attachments = source.attachments;

    if (text.isEmpty && attachments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This message cannot be forwarded.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _sending = true);

    try {
      await channel.sendMessage(
        Message(
          text: text.isEmpty ? 'Forwarded a message' : text,
          attachments: attachments,
          extraData: {
            'pingmeeForwarded': true,
            'sourceMessageId': source.id,
            'sourceUserId': source.user?.id,
          },
        ),
      );

      if (!mounted) return;

      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message forwarded.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not forward message: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  String _lastPreview(Channel channel) {
    final text = (channel.state?.lastMessage?.text ?? '').trim();
    if (text.isNotEmpty) return text;
    return 'Tap to forward here';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        height: MediaQuery.of(context).size.height * .68,
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
        child: Column(
          children: [
            Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),

            const SizedBox(height: 16),

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
                    PhosphorIcons.paperPlaneTilt(
                      PhosphorIconsStyle.light,
                    ),
                    color: AppColors.brandGreen,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Forward message',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            if (_sending)
              const LinearProgressIndicator(
                minHeight: 2,
                valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
              ),

            if (_sending) const SizedBox(height: 10),

            Expanded(
              child: controller == null
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation(
                          AppColors.brandGreen,
                        ),
                      ),
                    )
                  : StreamChannelListView(
                      controller: controller,
                      emptyBuilder: (_) {
                        return const Center(
                          child: Text(
                            'No chats to forward to yet.',
                            style: TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      },
                      errorBuilder: (context, error) {
                        return Center(
                          child: Text(
                            error.toString(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        );
                      },
                      itemBuilder: (context, channels, index, defaultTile) {
                        final channel = channels[index];
                        final isCurrentChannel =
                            (channel.cid ?? '') == widget.sourceChannelCid;

                        final person = pingmeeOtherDmPerson(
                          context: context,
                          channel: channel,
                        );

                        return Opacity(
                          opacity: isCurrentChannel ? .45 : 1,
                          child: Material(
                            color: const Color(0xFFF5F7FA),
                            borderRadius: BorderRadius.circular(22),
                            child: InkWell(
                              onTap: isCurrentChannel || _sending
                                  ? null
                                  : () => _forwardTo(channel),
                              borderRadius: BorderRadius.circular(22),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 24,
                                      backgroundColor:
                                          AppColors.brandGreen.withOpacity(.10),
                                      backgroundImage: person.image.isEmpty
                                          ? null
                                          : NetworkImage(person.image),
                                      child: person.image.isEmpty
                                          ? Icon(
                                              PhosphorIcons.user(
                                                PhosphorIconsStyle.light,
                                              ),
                                              color: AppColors.brandGreen,
                                              size: 21,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            person.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontFamily: 'Nunito',
                                              fontSize: 15.5,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF111827),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            isCurrentChannel
                                                ? 'Current chat'
                                                : _lastPreview(channel),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontFamily: 'Nunito',
                                              fontSize: 13,
                                              fontWeight: FontWeight.w400,
                                              color:
                                                  Colors.black.withOpacity(.50),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Icon(
                                      PhosphorIcons.arrowRight(
                                        PhosphorIconsStyle.light,
                                      ),
                                      size: 20,
                                      color: Colors.black.withOpacity(.42),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingmeeThreadPage extends StatelessWidget {
  const _PingmeeThreadPage({
    required this.parentMessage,
  });

  final Message parentMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  bottom: BorderSide(
                    color: Colors.black.withOpacity(.06),
                    width: 1,
                  ),
                ),
              ),
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
                          PhosphorIcons.arrowLeft(
                            PhosphorIconsStyle.light,
                          ),
                          size: 22,
                          color: Colors.black.withOpacity(.76),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Thread',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: StreamMessageListView(
                parentMessage: parentMessage,
              ),
            ),

            _PingmeeThemedMessageInput(
              preMessageSending: (message) {
                return message.copyWith(
                  parentId: parentMessage.id,
                  showInChannel: false,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveHeaderIdentity extends StatelessWidget {
  const _LiveHeaderIdentity({
    required this.userId,
    required this.fallbackName,
    required this.fallbackImage,
  });

  final String userId;
  final String fallbackName;
  final String fallbackImage;

  DateTime? _dateFrom(dynamic value) {
    if (value is firestore.Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  String _lastSeenLabel(DateTime? value) {
    if (value == null) return 'Offline';

    final now = DateTime.now();
    final local = value.toLocal();
    final diff = now.difference(local);

    if (diff.inSeconds < 30) return 'Last seen just now';
    if (diff.inMinutes < 1) return 'Last seen ${diff.inSeconds}s ago';
    if (diff.inHours < 1) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Last seen ${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Last seen yesterday';
    if (diff.inDays < 7) return 'Last seen ${diff.inDays}d ago';

    return 'Last seen ${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (userId.trim().isEmpty) {
      return _HeaderIdentityContent(
        userId: userId,
        name: fallbackName,
        imageUrl: fallbackImage,
        online: false,
        statusText: 'Offline',
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

        final fullName = pingmeeFullNameFromUserData(data);
        final imageUrl = pingmeePhotoFromUserData(data);
        final online = pingmeeIsOnlineFromUserData(data);
        final lastSeen = _dateFrom(data?['lastSeen']);

        final verification = Map<String, dynamic>.from(
          data?['verification'] ?? {},
        );

        final verified = verification['status'] == 'verified';

        return _HeaderIdentityContent(
          userId: userId,
          name: fullName.trim().isEmpty ? fallbackName : fullName,
          imageUrl: imageUrl.trim().isEmpty ? fallbackImage : imageUrl,
          online: online,
          statusText: online ? 'Online' : _lastSeenLabel(lastSeen),
          verified: verified,
        );
      },
    );
  }
}

class _HeaderIdentityContent extends StatelessWidget {
  const _HeaderIdentityContent({
    required this.userId,
    required this.name,
    required this.imageUrl,
    required this.online,
    required this.statusText,
    required this.verified,
  });

  final String name;
  final String imageUrl;
  final bool online;
  final String statusText;
  final String userId;
  final bool verified;

  void _openProfile(BuildContext context) {
    final uid = userId.trim();
    if (uid.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileTab(profileUid: uid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openProfile(context),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Row(
            children: [
              _HeaderAvatar(
                imageUrl: imageUrl,
                online: online,
              ),

              const SizedBox(width: 11),

              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),

                        if (verified) ...[
                          const SizedBox(width: 5),
                          Icon(
                            PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
                            size: 15,
                            color: const Color(0xFF1D9BF0),
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: 2),

                    Text(
                      statusText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: online
                            ? AppColors.brandGreen
                            : Colors.black.withOpacity(.45),
                      ),
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

class _OpenChatHeaderAction extends StatelessWidget {
  const _OpenChatHeaderAction({
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

class _OpenChatSheetRow extends StatelessWidget {
  const _OpenChatSheetRow({
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

class _LiveHeaderFullName extends StatelessWidget {
  const _LiveHeaderFullName({
    required this.userId,
    required this.fallbackName,
  });

  final String userId;
  final String fallbackName;

  @override
  Widget build(BuildContext context) {
    if (userId.trim().isEmpty) {
      return _HeaderNameText(name: fallbackName);
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final fullName = pingmeeFullNameFromUserData(data);

        return _HeaderNameText(
          name: fullName.trim().isEmpty ? fallbackName : fullName,
        );
      },
    );
  }
}

class _HeaderNameText extends StatelessWidget {
  const _HeaderNameText({
    required this.name,
  });

  final String name;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontFamily: 'Nunito',
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFF111827),
      ),
    );
  }
}

class _LiveHeaderAvatar extends StatelessWidget {
  const _LiveHeaderAvatar({
    required this.userId,
    required this.fallbackImage,
  });

  final String userId;
  final String fallbackImage;

  @override
  Widget build(BuildContext context) {
    if (userId.trim().isEmpty) {
      return _HeaderAvatar(
        imageUrl: fallbackImage,
        online: false,
      );
    }

    return StreamBuilder<firestore.DocumentSnapshot<Map<String, dynamic>>>(
      stream: firestore.FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();

        final imageUrl = pingmeePhotoFromUserData(data);
        final online = pingmeeIsOnlineFromUserData(data);

        return _HeaderAvatar(
          imageUrl: imageUrl.isEmpty ? fallbackImage : imageUrl,
          online: online,
        );
      },
    );
  }
}

class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({
    required this.imageUrl,
    required this.online,
  });

  final String imageUrl;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 21,
          backgroundColor: AppColors.brandGreen.withOpacity(.10),
          backgroundImage: imageUrl.isEmpty ? null : NetworkImage(imageUrl),
          child: imageUrl.isEmpty
              ? Icon(
                  PhosphorIcons.user(PhosphorIconsStyle.light),
                  size: 20,
                  color: AppColors.brandGreen,
                )
              : null,
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 1,
            child: Container(
              width: 11,
              height: 11,
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
      ],
    );
  }
}

class _PingmeePingHuddleScreen extends StatefulWidget {
  const _PingmeePingHuddleScreen({
    required this.channel,
    required this.pingId,
    required this.title,
    required this.memberIds,
  });

  final Channel channel;
  final String pingId;
  final String title;
  final List<String> memberIds;

  @override
  State<_PingmeePingHuddleScreen> createState() =>
      _PingmeePingHuddleScreenState();
}

class _PingmeePingHuddleScreenState extends State<_PingmeePingHuddleScreen> {
  late final Future<video_sdk.Call> _callFuture;

  PingmeeChatPerson get _huddlePerson {
    return PingmeeChatPerson(
      id: widget.pingId,
      name: widget.title.trim().isEmpty ? 'Ping Huddle' : widget.title.trim(),
      image: pingmeeChannelImage(widget.channel),
      online: false,
    );
  }

  @override
  void initState() {
    super.initState();

    _callFuture = PingmeeStreamVideoService.instance.startPingHuddle(
      pingId: widget.pingId,
      title: widget.title,
      memberIds: widget.memberIds,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<video_sdk.Call>(
      future: _callFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _PingmeeConnectingCallScreen(
            person: _huddlePerson,
            video: true,
          );
        }

        if (snap.hasError || !snap.hasData) {
          return _PingmeeCallErrorScreen(
            error: snap.error?.toString() ?? 'Could not start huddle.',
          );
        }

        final call = snap.data!;

        final baseVideoTheme = video_sdk.StreamVideoTheme.of(context);

        final pingmeeVideoTheme = baseVideoTheme.copyWith(
          callControlsTheme: baseVideoTheme.callControlsTheme.copyWith(
            backgroundColor: Colors.black.withOpacity(.64),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(34),
              topRight: Radius.circular(34),
            ),
            padding: const EdgeInsets.all(14),
            spacing: 10,
            optionIconColor: AppColors.brandGreen,
            optionBackgroundColor: Colors.white,
            inactiveOptionIconColor: Colors.white,
            inactiveOptionBackgroundColor: AppColors.brandGreen,
            optionElevation: 0,
            inactiveOptionElevation: 0,
            callReactions: const [
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':like:',
                icon: '👍',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':heart:',
                icon: '💚',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':joy:',
                icon: '😂',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':fireworks:',
                icon: '🎉',
              ),
              video_sdk.CallReactionData(
                type: 'raised-hand',
                emojiCode: ':raise-hand:',
                icon: '✋',
              ),
            ],
          ),
        );

        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Theme(
              data: Theme.of(context).copyWith(
                extensions: [
                  pingmeeVideoTheme,
                ],
                colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.brandGreen,
                  secondary: AppColors.brandGreen,
                ),
              ),
              child: video_sdk.StreamCallContainer(
                call: call,
                onCancelCallTap: () async {
                  await call.leave();

                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                onLeaveCallTap: () async {
                  await call.leave();

                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                callContentWidgetBuilder: (context, call) {
                  return video_sdk.StreamCallContent(
                    call: call,
                    onLeaveCallTap: () async {
                      await call.leave();

                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    callControlsWidgetBuilder: (context, call) {
                      return video_sdk.StreamCallControls(
                        options: [
                          ...video_sdk.defaultCallControlOptions(
                            call: call,
                          ),
                          video_sdk.AddReactionOption(
                            call: call,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PingmeeLiveCallScreen extends StatefulWidget {
  const _PingmeeLiveCallScreen({
    required this.person,
    required this.video,
  });

  final PingmeeChatPerson person;
  final bool video;

  @override
  State<_PingmeeLiveCallScreen> createState() => _PingmeeLiveCallScreenState();
}

class _PingmeeLiveCallScreenState extends State<_PingmeeLiveCallScreen> {
  late final Future<video_sdk.Call> _callFuture;

  @override
  void initState() {
    super.initState();

    _callFuture = PingmeeStreamVideoService.instance.startDirectCall(
      otherUid: widget.person.id,
      video: widget.video,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<video_sdk.Call>(
      future: _callFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _PingmeeConnectingCallScreen(
            person: widget.person,
            video: widget.video,
          );
        }

        if (snap.hasError || !snap.hasData) {
          return _PingmeeCallErrorScreen(
            error: snap.error?.toString() ?? 'Could not start call.',
          );
        }

        final call = snap.data!;

        final baseVideoTheme = video_sdk.StreamVideoTheme.of(context);

        final pingmeeVideoTheme = baseVideoTheme.copyWith(
          callControlsTheme: baseVideoTheme.callControlsTheme.copyWith(
            backgroundColor: widget.video
                ? Colors.black.withOpacity(.64)
                : Colors.white,

            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(34),
              topRight: Radius.circular(34),
            ),

            padding: const EdgeInsets.all(14),
            spacing: 10,

            // Main control icons.
            optionIconColor: AppColors.brandGreen,
            optionBackgroundColor: Colors.white,

            // Active/toggled controls.
            inactiveOptionIconColor: Colors.white,
            inactiveOptionBackgroundColor: AppColors.brandGreen,

            optionElevation: 0,
            inactiveOptionElevation: 0,

            callReactions: const [
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':like:',
                icon: '👍',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':heart:',
                icon: '💚',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':joy:',
                icon: '😂',
              ),
              video_sdk.CallReactionData(
                type: 'reaction',
                emojiCode: ':fireworks:',
                icon: '🎉',
              ),
              video_sdk.CallReactionData(
                type: 'raised-hand',
                emojiCode: ':raise-hand:',
                icon: '✋',
              ),
            ],
          ),
        );

        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Theme(
              data: Theme.of(context).copyWith(
                extensions: [
                  pingmeeVideoTheme,
                ],
                colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.brandGreen,
                  secondary: AppColors.brandGreen,
                ),
              ),
              child: video_sdk.StreamCallContainer(
                call: call,
                onCancelCallTap: () async {
                  await call.leave();

                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                onLeaveCallTap: () async {
                  await call.leave();

                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },

                // ✅ Active call screen override.
                // This is where we add the missing reaction button.
                callContentWidgetBuilder: (context, call) {
                  return video_sdk.StreamCallContent(
                    call: call,
                    onLeaveCallTap: () async {
                      await call.leave();

                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    callControlsWidgetBuilder: (context, call) {
                      return video_sdk.StreamCallControls(
                        options: [
                          ...video_sdk.defaultCallControlOptions(
                            call: call,
                          ),

                          // ✅ This is the missing reaction/emoji button.
                          video_sdk.AddReactionOption(
                            call: call,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PingmeeConnectingCallScreen extends StatelessWidget {
  const _PingmeeConnectingCallScreen({
    required this.person,
    required this.video,
  });

  final PingmeeChatPerson person;
  final bool video;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: video ? const Color(0xFF05070A) : Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: AppColors.brandGreen.withOpacity(.14),
                  backgroundImage:
                      person.image.isEmpty ? null : NetworkImage(person.image),
                  child: person.image.isEmpty
                      ? Icon(
                          PhosphorIcons.user(PhosphorIconsStyle.light),
                          color: AppColors.brandGreen,
                          size: 38,
                        )
                      : null,
                ),
                const SizedBox(height: 22),
                Text(
                  video ? 'Starting video call…' : 'Starting voice call…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: video ? Colors.white : const Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  person.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: video
                        ? Colors.white.withOpacity(.56)
                        : Colors.black.withOpacity(.50),
                  ),
                ),
                const SizedBox(height: 26),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
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

class _PingmeeCallErrorScreen extends StatelessWidget {
  const _PingmeeCallErrorScreen({
    required this.error,
  });

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(18),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withOpacity(.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    PhosphorIcons.warningCircle(PhosphorIconsStyle.bold),
                    color: const Color(0xFFEF4444),
                    size: 26,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Could not start call',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.50),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                Material(
                  color: AppColors.brandGreen,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(20),
                    child: const SizedBox(
                      height: 50,
                      width: double.infinity,
                      child: Center(
                        child: Text(
                          'Back to chat',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
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