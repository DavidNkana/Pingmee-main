import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/material.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

import 'package:ping_files/features/chat/stream_chat_service.dart';

class PingmeeStreamChatScope extends StatelessWidget {
  const PingmeeStreamChatScope({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<fb.User?>(
      stream: fb.FirebaseAuth.instance.authStateChanges(),
      initialData: fb.FirebaseAuth.instance.currentUser,
      builder: (context, authSnap) {
        final firebaseUser = authSnap.data;

        if (firebaseUser == null) {
          return child;
        }

        return FutureBuilder<StreamChatClient>(
          future: PingmeeStreamChatService.instance.connectCurrentUser(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return child;
            }

            if (snap.hasError || !snap.hasData) {
              return child;
            }

            return StreamChat(
              client: snap.data!,
              child: child,
            );
          },
        );
      },
    );
  }
}