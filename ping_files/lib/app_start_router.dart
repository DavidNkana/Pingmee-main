import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ping_files/onboarding_screen.dart';
import 'package:ping_files/AuthScreens/Welcome/welcome_screen.dart';
import 'package:ping_files/main_app/main_app_shell.dart';
import 'package:ping_files/ProfileCreation/ActivationLevelZeroScreen.dart';
import 'package:ping_files/features/pings/ping_invite_resolver_screen.dart';
import 'package:lottie/lottie.dart';

class AppStartRouter extends StatefulWidget {
  const AppStartRouter({super.key});

  @override
  State<AppStartRouter> createState() => _AppStartRouterState();
}

class _AppStartRouterState extends State<AppStartRouter> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _setupDeepLinks();
  }

  Future<void> _setupDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleIncomingUri(initialUri);
      }
    } catch (_) {}

    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) async {
        await _handleIncomingUri(uri);
      },
      onError: (_) {},
    );
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    if (uri.host != "pingmee.io") return;
    if (uri.pathSegments.length != 2) return;
    if (uri.pathSegments.first != "j") return;

    final inviteCode = uri.pathSegments[1].trim();
    if (inviteCode.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("pending_invite_code", inviteCode);

    if (mounted) {
      setState(() {});
    }
  }

  Future<Widget> _decideStart() async {
    final prefs = await SharedPreferences.getInstance();
    final seenOnboarding = prefs.getBool('seen_onboarding') ?? false;
    final pendingInviteCode = prefs.getString("pending_invite_code");

    if (!seenOnboarding) return const OnboardingScreen();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const WelcomeScreen();

    await user.reload();
    final refreshed = FirebaseAuth.instance.currentUser;

    if (refreshed == null) return const WelcomeScreen();

    if (refreshed.email != null && !refreshed.emailVerified) {
      await FirebaseAuth.instance.signOut();
      return const WelcomeScreen();
    }

    final uid = refreshed.uid;
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final data = doc.data();

    final onboardingComplete = (data?['onboardingComplete'] == true);
    final profileLevel =
        (data?['profileLevel'] is num) ? (data!['profileLevel'] as num).toInt() : 0;

    if (onboardingComplete || profileLevel >= 10) {
      if (pendingInviteCode != null && pendingInviteCode.isNotEmpty) {
        return PingInviteResolverScreen(inviteCode: pendingInviteCode);
      }
      return const MainAppShell();
    }

    return const ActivationLevelZeroScreen();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _decideStart(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const _BootLoading();
        }

        return snap.data!;
      },
    );
  }
}

class _BootLoading extends StatelessWidget {
  const _BootLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: Lottie.asset(
            'assets/images/finger-loading.json',
            repeat: true,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
