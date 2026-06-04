import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ping_files/ProfileCreation/identity_profile_photo_screen.dart';
import 'package:ping_files/ProfileCreation/onboarding_style.dart';
import 'package:ping_files/components/profile_progress_bar.dart';

class IdentityPermissionsScreen extends StatefulWidget {
  const IdentityPermissionsScreen({super.key});

  @override
  State<IdentityPermissionsScreen> createState() =>
      _IdentityPermissionsScreenState();
}

class _IdentityPermissionsScreenState extends State<IdentityPermissionsScreen> {
  bool locationEnabled = false;
  bool notificationsEnabled = false;

  bool saving = false;
  bool loading = true;

  // for press animation
  String? pressedKey;

  @override
  void initState() {
    super.initState();
    _loadSavedPermissions();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<void> _loadSavedPermissions() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection("users").doc(uid).get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        locationEnabled = data['permissions']?['location'] ?? false;
        notificationsEnabled = data['permissions']?['notifications'] ?? false;
      }

      // sync real OS state
      final locStatus = await Permission.locationWhenInUse.status;
      if (locStatus.isGranted) locationEnabled = true;

      final notifStatus = await Permission.notification.status;
      if (notifStatus.isGranted) notificationsEnabled = true;
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------- WHY POPUPS ----------

  Future<bool> _showWhySheet({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Map<String, String>> bullets,
    required String ctaText,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  blurRadius: 26,
                  offset: const Offset(0, 14),
                  color: Colors.black.withOpacity(.10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 14),

                // header row
                Row(
                  children: [
                    // accent bar
                    Container(
                      width: 6,
                      height: 46,
                      decoration: BoxDecoration(
                        color: OnboardingStyle.accentLine,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // icon tile
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: OnboardingStyle.action,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, color: OnboardingStyle.onAction),
                    ),

                    const SizedBox(width: 12),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              fontFamily: "Nunito",
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.grey,
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 14),
                Divider(color: Colors.grey.shade200, height: 1),
                const SizedBox(height: 14),

                // bullet list
                ...bullets.map(
                  (b) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: OnboardingStyle.action,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.3,
                                color: Colors.black87,
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w500,
                              ),
                              children: [
                                TextSpan(
                                  text: "${b["title"]}  ",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                TextSpan(text: b["desc"] ?? ""),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 6),

                // buttons
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text(
                          "Not now",
                          style: TextStyle(
                            color: Colors.grey,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: OnboardingStyle.action,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(40),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          ctaText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
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
      ),
    );

    return result ?? false;
  }

  // ---------- REAL PERMISSION HANDLERS ----------

  Future<void> _saveCurrentLocationToFirestore() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Make sure we have permission
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return;
    }

    // Get position (use low power first; you can upgrade accuracy later)
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
    );

    await FirebaseFirestore.instance.collection("users").doc(uid).set({
      "lastLocation": {
        "geopoint": GeoPoint(pos.latitude, pos.longitude),
        "geohash": "" // keep empty for now (we can add GeoFlutterFire2 later)
      },
      "lastLocationUpdatedAt": FieldValue.serverTimestamp(),
      "updatedAt": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }


  Future<void> _handleLocationToggle(bool value) async {
    if (saving) return;

    if (!value) {
      setState(() => locationEnabled = false);
      return;
    }

    // ✅ WHY sheet first
    final proceed = await _showWhySheet(
      icon: Icons.location_on_rounded,
      title: "Location access",
      subtitle: "Pingmee needs this to work nearby.",
      bullets: const [
        {
          "title": "Find people near you",
          "desc": "Discover and be discovered in your area.",
        },
        {
          "title": "Accurate distance",
          "desc": "So your distance slider actually matches reality.",
        },
        {
          "title": "Safety and trust",
          "desc": "Helps reduce spam and fake locations.",
        },
      ],
      ctaText: "Enable",
    );

    if (!proceed) return;

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}

    final status = await Permission.locationWhenInUse.request();

    if (!mounted) return;

    if (status.isGranted) {
      // GPS/Location services ON check (cannot force-enable)
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => locationEnabled = true); // permission granted

        _showSnack("Turn on Location Services (GPS) to discover nearby pings.");
        await Geolocator.openLocationSettings();
        return;
      }

      setState(() => locationEnabled = true);
      _showSnack("Location enabled ✅");

      // ✅ save location to Firestore for the main app
      try {
        await _saveCurrentLocationToFirestore();
      } catch (_) {
        // ignore for now; don't block onboarding
      }

    } else {
      setState(() => locationEnabled = false);

      if (status.isPermanentlyDenied) {
        _showSnack("Location is blocked. Please enable it in Settings.");
        await openAppSettings();
      } else {
        _showSnack("Location permission is required for nearby pings.");
      }
    }
  }

  Future<void> _handleNotificationsToggle(bool value) async {
    if (saving) return;

    if (!value) {
      setState(() => notificationsEnabled = false);
      return;
    }

    // ✅ WHY sheet first
    final proceed = await _showWhySheet(
      icon: Icons.notifications_active_rounded,
      title: "Notifications",
      subtitle: "So you don’t miss the important stuff.",
      bullets: const [
        {
          "title": "Instant pings",
          "desc": "Get alerted when someone pings you.",
        },
        {
          "title": "Event updates",
          "desc": "Know when something you joined is happening.",
        },
        {
          "title": "Safety alerts",
          "desc": "Important notices if someone needs help nearby.",
        },
      ],
      ctaText: "Allow",
    );

    if (!proceed) return;

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}

    final status = await Permission.notification.request();

    if (!mounted) return;

    if (status.isGranted) {
      setState(() => notificationsEnabled = true);
      _showSnack("Notifications enabled ✅");
    } else {
      setState(() => notificationsEnabled = false);

      if (status.isPermanentlyDenied) {
        _showSnack("Notifications are blocked. Please enable in Settings.");
        await openAppSettings();
      } else {
        _showSnack("Allow notifications so Pingmee can alert you.");
      }
    }
  }

  Future<void> _saveAndContinue() async {
    setState(() => saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      await FirebaseFirestore.instance.collection("users").doc(uid).set({
        "permissions": {
          "location": locationEnabled,
          "notifications": notificationsEnabled,
        },
        "profileLevel": 8,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;

      if (locationEnabled) {
        try { await _saveCurrentLocationToFirestore(); } catch (_) {}
      }


      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const IdentityProfilePhotoScreen(),
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  // ---------- UI HELPERS ----------

  String _vibeTitle() {
    if (locationEnabled && notificationsEnabled) return "All set";
    if (locationEnabled) return "Location ready";
    if (notificationsEnabled) return "Alerts ready";
    return "Set your permissions";
  }

  String _vibeSubtitle() {
    if (locationEnabled && notificationsEnabled) {
      return "You’ll get nearby pings + important alerts.";
    }
    if (locationEnabled) {
      return "Now turn on notifications so you don’t miss pings.";
    }
    if (notificationsEnabled) {
      return "Now turn on location to discover people nearby.";
    }
    return "Tap an option to preview why it matters.";
  }

  IconData _vibeIcon() {
    if (locationEnabled && notificationsEnabled) return Icons.verified_rounded;
    if (locationEnabled) return Icons.location_on_rounded;
    if (notificationsEnabled) return Icons.notifications_active_rounded;
    return Icons.tune_rounded;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(OnboardingStyle.progress),
          ),
        ),
      );
    }

    final vibeTitle = _vibeTitle();
    final vibeSubtitle = _vibeSubtitle();
    final vibeIcon = _vibeIcon();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            const ProfileProgressBar(step: 8, totalSteps: 10),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // Pingoo
                    // Top onboarding image
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_eight.png",
                        height: 190,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 16),

                    const Text(
                      "Quick setup",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Turn on what Pingmee needs to work best.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                      ),
                    ),

                    const SizedBox(height: 22),

                    // Preview banner
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                            color: Colors.black.withOpacity(.06),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 44,
                            decoration: BoxDecoration(
                              color: OnboardingStyle.accentLine,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: OnboardingStyle.action,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(vibeIcon, color: OnboardingStyle.onAction),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  vibeTitle,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: "Nunito",
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  vibeSubtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey,
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (locationEnabled || notificationsEnabled)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: OnboardingStyle.action,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                "Live",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: "Nunito",
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    Row(
                      children: [
                        Expanded(
                          child: Container(
                              height: 1, color: Colors.grey.shade200),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "Enable",
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                              height: 1, color: Colors.grey.shade200),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    _permissionCard(
                      keyName: "location",
                      icon: Icons.location_on_outlined,
                      title: "Location access",
                      subtitle: "Discover and be discovered nearby.",
                      value: locationEnabled,
                      onChanged: _handleLocationToggle,
                    ),

                    const SizedBox(height: 14),

                    _permissionCard(
                      keyName: "notifications",
                      icon: Icons.notifications_none_rounded,
                      title: "Notifications",
                      subtitle: "Get alerts when someone pings you.",
                      value: notificationsEnabled,
                      onChanged: _handleNotificationsToggle,
                    ),

                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),

            // Bottom buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: saving ? null : () => Navigator.pop(context),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                            color: Colors.black.withOpacity(.06),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.black87,
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: saving ? null : _saveAndContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(40),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        saving ? "Saving..." : "Next",
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w800,
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

  Widget _permissionCard({
    required String keyName,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    final bool isPressed = pressedKey == keyName;
    final bool isSelected = value;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: saving ? null : (_) => setState(() => pressedKey = keyName),
      onTapCancel: () => setState(() => pressedKey = null),
      onTapUp: (_) => setState(() => pressedKey = null),
      onTap: saving ? null : () => onChanged(!value),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        scale: isPressed ? 0.985 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 6,
                height: 46,
                decoration: BoxDecoration(
                  color: isSelected ? OnboardingStyle.accentLine : Colors.transparent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 12),

              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: OnboardingStyle.optionIconBackground(isSelected),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  color: OnboardingStyle.optionIconForeground(isSelected),
                ),
              ),
              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        fontFamily: "Nunito",
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              Switch(
                value: value,
                activeThumbColor: OnboardingStyle.action,
                onChanged: saving ? null : (v) => onChanged(v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
