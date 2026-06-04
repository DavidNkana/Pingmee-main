import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ping_files/main_app/main_app_shell.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';

class PingInviteResolverScreen extends StatefulWidget {
  final String inviteCode;

  const PingInviteResolverScreen({
    super.key,
    required this.inviteCode,
  });

  @override
  State<PingInviteResolverScreen> createState() =>
      _PingInviteResolverScreenState();
}

class _PingInviteResolverScreenState extends State<PingInviteResolverScreen> {
  bool _loading = true;
  bool _openedSheet = false;
  String? _error;
  String? _pingId;

  @override
  void initState() {
    super.initState();
    _resolveInvite();
  }

  Future<void> _resolveInvite() async {
    try {
      final inviteCode = widget.inviteCode.trim();

      if (inviteCode.isEmpty) {
        setState(() {
          _loading = false;
          _error = "This invite is invalid.";
        });
        return;
      }

      final snap = await FirebaseFirestore.instance
          .collection("pings")
          .where("invite.code", isEqualTo: inviteCode)
          .where("invite.enabled", isEqualTo: true)
          .limit(1)
          .get();

      if (snap.docs.isEmpty) {
        setState(() {
          _loading = false;
          _error = "This invite is invalid or expired.";
        });
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("pending_invite_code");

      if (!mounted) return;

      setState(() {
        _pingId = snap.docs.first.id;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = "Could not open this ping right now.";
      });
    }
  }

  void _openPingIfNeeded() {
    if (_openedSheet || _pingId == null) return;

    _openedSheet = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await openPingDetailsSheet(
        context: context,
        pingId: _pingId!,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFEFF2F7),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              SizedBox(height: 12),
              Text(
                "Opening ping...",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFFEFF2F7),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.link_off_rounded,
                  size: 42,
                  color: Colors.black54,
                ),
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove("pending_invite_code");

                    if (!mounted) return;

                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const MainAppShell(),
                      ),
                    );
                  },
                  child: const Text("Continue"),
                ),
              ],
            ),
          ),
        ),
      );
    }

    _openPingIfNeeded();
    return const MainAppShell();
  }
}