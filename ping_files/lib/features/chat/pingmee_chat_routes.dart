import 'package:flutter/material.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/features/chat/chat_channel_page.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';

Route<void> pingmeeChatRoute(Channel channel) {
  return MaterialPageRoute(
    builder: (_) {
      final client = PingmeeStreamChatService.instance.client;

      return StreamChat(
        client: client,
        child: Builder(
          builder: (streamContext) {
            return StreamChannel(
              channel: channel,
              child: Builder(
                builder: (channelContext) {
                  return const PingmeeChatChannelPage();
                },
              ),
            );
          },
        ),
      );
    },
  );
}