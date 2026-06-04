import 'dart:ui';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/ProfileCreation/identity_basic_screen.dart';
import 'package:ping_files/app_start_router.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/main_app/tabs/profile/profile_engagement_screen.dart';
import 'package:ping_files/AuthScreens/Signup/signup_screen.dart';
import 'package:ping_files/ProfileCreation/ActivationLevelZeroScreen.dart';
import 'package:ping_files/main_app/main_app_shell.dart';
import 'package:ping_files/services/local_account_vault.dart';
import 'package:ping_files/main_app/communities/create/community_basic_screen.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
import 'package:ping_files/main_app/communities/community_page_screen.dart';
import 'package:ping_files/features/pings/ping_history_screen.dart';

class ProfileOwnerMainMenuScreen extends StatefulWidget {
  final String uid;

  const ProfileOwnerMainMenuScreen({
    super.key,
    required this.uid,
  });

  @override
  State<ProfileOwnerMainMenuScreen> createState() =>
      _ProfileOwnerMainMenuScreenState();
}

class _ProfileOwnerMainMenuScreenState
    extends State<ProfileOwnerMainMenuScreen> {
  final TextEditingController _friendSearchCtrl = TextEditingController();
  final TextEditingController _findFriendsCtrl = TextEditingController();
  final CreateCommunityDraft _createCommunityDraft = CreateCommunityDraft();

  bool _savingPrivacy = false;
  bool _savingNotifications = false;
  String _friendSearch = "";
  String _findFriendsSearch = "";
  bool _switchingAccount = false;

  @override
  void initState() {
    super.initState();

    _friendSearchCtrl.addListener(() {
      if (!mounted) return;
      setState(() => _friendSearch = _friendSearchCtrl.text.trim().toLowerCase());
    });

    _findFriendsCtrl.addListener(() {
      if (!mounted) return;
      setState(
          () => _findFriendsSearch = _findFriendsCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _friendSearchCtrl.dispose();
    _findFriendsCtrl.dispose();
    super.dispose();
  }

  DocumentReference<Map<String, dynamic>> get _userRef =>
      FirebaseFirestore.instance.collection("users").doc(widget.uid);

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppStartRouter()),
      (route) => false,
    );
  }

  Future<void> _openPingHistory() async {
    HapticFeedback.selectionClick();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PingHistoryScreen(),
      ),
    );
  }

  bool _isVerifiedAccount(Map<String, dynamic>? data) {
    final verification = Map<String, dynamic>.from(
      data?['verification'] ?? {},
    );

    return verification['status'] == 'verified';
  }

  Future<void> _goToSignupScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
  }

  Future<void> _goToLoginScreen() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppStartRouter()),
      (route) => false,
    );
  }

  Future<void> _openCreateCommunity() async {
    HapticFeedback.selectionClick();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunityBasicScreen(
          draft: _createCommunityDraft,
        ),
      ),
    );
  }

  Future<void> _switchToSavedAccount(SavedAccount account) async {
    if (_switchingAccount) return;

    setState(() => _switchingAccount = true);

    try {
      final savedSecret = await LocalAccountVault.readSecret(account);

      if (savedSecret == null || savedSecret.isEmpty) {
        await LocalAccountVault.removeAccount(account);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("That saved account is no longer available on this device."),
          ),
        );
        return;
      }

      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: account.identifier,
        password: savedSecret,
      );

      await credential.user?.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser == null) {
        throw FirebaseAuthException(
          code: 'user-null',
          message: 'Login failed.',
        );
      }

      if (!refreshedUser.emailVerified) {
        await FirebaseAuth.instance.signOut();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Verify this account’s email first, then log in manually."),
          ),
        );
        await _goToLoginScreen();
        return;
      }

      final uid = refreshedUser.uid;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final data = doc.data() ?? {};

      await LocalAccountVault.saveAccount(
        uid: uid,
        type: 'email',
        identifier: account.identifier,
        fullName: (data['fullName'] ?? data['name'])?.toString(),
        username: data['username']?.toString(),
        photoUrl: (data['photoUrl'] ??
                data['profilePhotoUrl'] ??
                data['avatarUrl'])
            ?.toString(),
        secret: savedSecret,
        saveSecret: true,
      );

      final onboardingComplete = (data['onboardingComplete'] == true);
      final profileLevel = (data['profileLevel'] is num)
          ? (data['profileLevel'] as num).toInt()
          : 0;

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => (onboardingComplete || profileLevel >= 10)
              ? const MainAppShell()
              : const ActivationLevelZeroScreen(),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.message?.trim().isNotEmpty == true
                ? e.message!.trim()
                : "Could not switch account.",
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Something went wrong while switching account."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _switchingAccount = false);
      }
    }
  }

Future<void> _showSwitchAccountSheet() async {
  final loaded = await LocalAccountVault.loadAccounts();

  final accounts = loaded
      .where((a) => a.type == 'email' && a.hasSavedSecret && a.uid != widget.uid)
      .toList();

  if (!mounted) return;

  if (accounts.isEmpty) {
    await _goToLoginScreen();
    return;
  }

  final result = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(.35),
    builder: (sheetContext) {
      final screenHeight = MediaQuery.of(sheetContext).size.height;

      return Container(
        height: screenHeight * 0.68,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Log into Pingmee',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Poppins',
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Choose an account on this device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mediumGray,
                    fontFamily: 'Poppins',
                  ),
                ),
              ),
              const SizedBox(height: 18),

              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  itemCount: accounts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, index) {
                    final account = accounts[index];

                    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(account.uid)
                          .snapshots(),
                      builder: (context, userSnap) {
                        final data = userSnap.data?.data();

                        final verified = _isVerifiedAccount(data);

                        final firestoreName = (
                          data?['fullName'] ??
                          data?['displayName'] ??
                          data?['name'] ??
                          ''
                        ).toString().trim();

                        final firestoreUsername = (
                          data?['username'] ??
                          ''
                        ).toString().trim();

                        final firestorePhotoUrl = (
                          data?['photoUrl'] ??
                          data?['profilePhotoUrl'] ??
                          data?['avatarUrl'] ??
                          ''
                        ).toString().trim();

                        final displayName = firestoreName.isNotEmpty
                            ? firestoreName
                            : (account.fullName?.trim().isNotEmpty == true)
                                ? account.fullName!.trim()
                                : account.identifier;

                        final handle = firestoreUsername.isNotEmpty
                            ? '@$firestoreUsername'
                            : (account.username?.trim().isNotEmpty == true)
                                ? '@${account.username!.trim()}'
                                : '';

                        final photoUrl = firestorePhotoUrl.isNotEmpty
                            ? firestorePhotoUrl
                            : (account.photoUrl ?? '').trim();

                        return InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: _switchingAccount
                              ? null
                              : () => Navigator.of(sheetContext).pop(account),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF7F8FA),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 28,
                                  backgroundImage: photoUrl.isNotEmpty
                                      ? NetworkImage(photoUrl)
                                      : null,
                                  child: photoUrl.isEmpty
                                      ? Text(
                                          displayName.isNotEmpty
                                              ? displayName[0].toUpperCase()
                                              : '?',
                                        )
                                      : null,
                                ),

                                const SizedBox(width: 14),

                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                fontFamily: 'Nunito',
                                                color: Color(0xFF111827),
                                              ),
                                            ),
                                          ),

                                          if (verified) ...[
                                            const SizedBox(width: 5),
                                            Icon(
                                              PhosphorIcons.sealCheck(
                                                PhosphorIconsStyle.fill,
                                              ),
                                              size: 16,
                                              color: const Color(0xFF1D9BF0),
                                            ),
                                          ],
                                        ],
                                      ),

                                      if (handle.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          handle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: AppColors.mediumGray,
                                            fontFamily: 'Nunito',
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),

                                const SizedBox(width: 8),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop('__use_another__'),
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFFF3F4F6),
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      'Use another account',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
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

  if (!mounted) return;

  if (result == '__use_another__') {
    await _goToLoginScreen();
    return;
  }

  if (result is SavedAccount) {
      await _switchToSavedAccount(result);
    }
  }

  Future<void> _openCommunityPage(String communityId) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunityPageScreen(
          communityId: communityId,
        ),
      ),
    );
  }

  Future<void> _showSwitchCommunitiesSheet() async {
    final snap = await FirebaseFirestore.instance
        .collection('communities')
        .where('ownerUid', isEqualTo: widget.uid)
        .get();

    if (!mounted) return;

    final communities = snap.docs.map((doc) {
      final data = doc.data();

      return _OwnedCommunityMenuItem(
        id: doc.id,
        name: ((data['name'] ?? data['communityName'] ?? 'Untitled community')
                .toString())
            .trim(),
        headline: ((data['headline'] ?? '').toString()).trim(),
        photoUrl: ((data['photoUrl'] ?? data['profilePhotoUrl'] ?? '').toString())
            .trim(),
        subscribersCount: (data['subscribersCount'] is num)
            ? (data['subscribersCount'] as num).toInt()
            : 0,
        eventsCount: (data['eventsCount'] is num)
            ? (data['eventsCount'] as num).toInt()
            : 0,
        createdAt: data['createdAt'] is Timestamp ? data['createdAt'] as Timestamp : null,
      );
    }).toList();

    communities.sort((a, b) {
      final aTime = a.createdAt?.millisecondsSinceEpoch ?? 0;
      final bTime = b.createdAt?.millisecondsSinceEpoch ?? 0;
      return bTime.compareTo(aTime);
    });

    if (communities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You haven’t created any communities yet."),
        ),
      );
      return;
    }

    final result = await showModalBottomSheet<_OwnedCommunityMenuItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(.35),
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(sheetContext).size.height;

        return Container(
          height: screenHeight * 0.68,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Switch communities',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Nunito',
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Choose one of your communities',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.mediumGray,
                      fontFamily: 'Nunito',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    itemCount: communities.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, index) {
                      final community = communities[index];

                      return InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => Navigator.of(sheetContext).pop(community),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF7F8FA),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 28,
                                backgroundImage: community.photoUrl.isNotEmpty
                                    ? NetworkImage(community.photoUrl)
                                    : null,
                                child: community.photoUrl.isEmpty
                                    ? Text(
                                        community.name.isNotEmpty
                                            ? community.name[0].toUpperCase()
                                            : '?',
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      community.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'Nunito',
                                      ),
                                    ),
                                    if (community.headline.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        community.headline,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.mediumGray,
                                          fontFamily: 'Nunito',
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      '${community.subscribersCount} subscribers • ${community.eventsCount} events',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: Colors.black54,
                                        fontFamily: 'Nunito',
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop('__create__'),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F4F6),
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        'Create new community',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontWeight: FontWeight.w600,
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

    if (!mounted) return;

    if (result == '__create__') {
      await _openCreateCommunity();
      return;
    }

    if (result is _OwnedCommunityMenuItem) {
      await _openCommunityPage(result.id);
    }
  }

  Future<void> _setPrivateAccount(bool value) async {
    setState(() => _savingPrivacy = true);
    try {
      await _userRef.set({
        "privacySettings": {
          "isPrivateAccount": value,
        },
      }, SetOptions(merge: true));
    } finally {
      if (mounted) setState(() => _savingPrivacy = false);
    }
  }

  Future<void> _setVisibility(String value) async {
    await _userRef.set({
      "privacySettings": {
        "defaultPingVisibility": value,
      },
    }, SetOptions(merge: true));
  }

  Future<void> _setNotificationSetting(String key, bool value) async {
    setState(() => _savingNotifications = true);
    try {
      await _userRef.set({
        "notificationSettings": {
          key: value,
        },
      }, SetOptions(merge: true));
    } finally {
      if (mounted) setState(() => _savingNotifications = false);
    }
  }

  Future<void> _setPreference(String key, dynamic value) async {
    await _userRef.set({
      "preferences": {
        key: value,
      },
    }, SetOptions(merge: true));
  }

  Future<void> _toggleCloseFriend({
    required String friendUid,
    required bool makeCloseFriend,
  }) async {
    final ref = _userRef.collection("friends").doc(friendUid);
    await ref.set({
      "isCloseFriend": makeCloseFriend,
      "updatedAt": FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _removeBlockedUser(String blockedUid) async {
    final db = FirebaseFirestore.instance;

    final myBlockedRef = _userRef.collection("blocked").doc(blockedUid);
    final theirBlockedByRef = db
        .collection("users")
        .doc(blockedUid)
        .collection("blocked_by")
        .doc(widget.uid);

    final batch = db.batch();
    batch.delete(myBlockedRef);
    batch.delete(theirBlockedByRef);
    await batch.commit();
  }

  Future<void> _requestVerification({
  required Map<String, dynamic> userData,
  required String typeRequested,
  required String reason,
}) async {
  final requests = FirebaseFirestore.instance.collection("verification_requests");

  final existing = await requests
      .where("uid", isEqualTo: widget.uid)
      .where("status", isEqualTo: "pending")
      .limit(1)
      .get();

  if (existing.docs.isNotEmpty) {
    throw Exception("You already have a pending verification request.");
  }

  final reqRef = requests.doc();

  await reqRef.set({
    "uid": widget.uid,
    "createdAt": FieldValue.serverTimestamp(),
    "status": "pending",
    "typeRequested": typeRequested,
    "reason": reason.trim(),
    "snapshot": {
      "fullName": (userData["fullName"] ?? "").toString(),
      "username": (userData["username"] ?? "").toString(),
      "email": (userData["email"] ?? "").toString(),
      "phone": (userData["phone"] ?? "").toString(),
      "photoUrl": (userData["photoUrl"] ?? "").toString(),
      "coverUrl": (userData["coverUrl"] ?? "").toString(),
      "socials": Map<String, dynamic>.from(userData["socials"] ?? {}),
      "intro": (userData["intro"] ?? "").toString(),
    },
  });
}

void _openVerificationInfo({
    required Map<String, dynamic> userData,
    required bool verified,
    required bool hasPendingVerification,
    required String verificationType,
  }) {
    _showVerificationInfoSheet(
      context: context,
      verified: verified,
      hasPendingVerification: hasPendingVerification,
      verificationType: verificationType,
      onRequestTap: () async {
        Navigator.pop(context);

        if (verified) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This account is already verified.")),
          );
          return;
        }

        if (hasPendingVerification) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Your verification request is pending.")),
          );
          return;
        }

        await _showVerificationRequestSheet(
          context: context,
          userData: userData,
          onSubmit: ({
            required String typeRequested,
            required String reason,
          }) async {
            await _requestVerification(
              userData: userData,
              typeRequested: typeRequested,
              reason: reason,
            );
          },
        );
      },
    );
  }

  void _comingSoon(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Stack(
          children: [
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _userRef.snapshots(),
              builder: (context, snap) {
                final userData = snap.data?.data() ?? {};

                final privacySettings =
                    Map<String, dynamic>.from(userData["privacySettings"] ?? {});
                final notificationSettings =
                    Map<String, dynamic>.from(userData["notificationSettings"] ?? {});
                final preferences =
                    Map<String, dynamic>.from(userData["preferences"] ?? {});
                final verification =
                    Map<String, dynamic>.from(userData["verification"] ?? {});

                final verified = verification["status"] == "verified";
                final hasPendingVerification = verification["status"] == "pending";
                final verificationType =
                    (verification["type"] ?? "identity").toString();

                final isPrivateAccount =
                    privacySettings["isPrivateAccount"] == true;
                final defaultPingVisibility =
                    (privacySettings["defaultPingVisibility"] ?? "public")
                        .toString();

                final notifActivity =
                    notificationSettings["activity"] != false;
                final notifGeneral =
                    notificationSettings["general"] != false;
                final notifRequests =
                    notificationSettings["requests"] != false;

              final selectedTheme =
                  (preferences["theme"] ?? "system").toString();
                final selectedLanguage =
                    (preferences["language"] ?? "English").toString();

                return CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Row(
                          children: [
                            _TopIconButton(
                              icon: PhosphorIcons.arrowLeft(
                                PhosphorIconsStyle.bold,
                              ),
                              onTap: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),
                    ),

                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                        child: _OwnerMenuHeroCard(
                          title: "Main menu",
                          subtitle: "You're in control of everything.",
                        ),
                      ),
                    ),

                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _SectionHeader(
                            title: "Communities",
                            icon: PhosphorIcons.buildings(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: PhosphorIcons.usersThree(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Switch communities",
                            subtitle: "Open and move between the communities you own",
                            onTap: _showSwitchCommunitiesSheet,
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.plusCircle(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Create community",
                            subtitle: "Start a community page for events, tasks, and posts",
                            onTap: _openCreateCommunity,
                          ),

                          const SizedBox(height: 24),
                          _SectionHeader(
                            title: "How to use Pingmee",
                            icon: PhosphorIcons.lightbulb(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _MenuTile(
                            icon: PhosphorIcons.chartBar(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Your activity",
                            subtitle: "See how you’ve been using Pingmee",
                            onTap: () =>
                                _comingSoon("Your activity screen coming next."),
                          ),
                          const SizedBox(height: 10),
                          _MenuTile(
                            icon: PhosphorIcons.chartLineUp(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Engagement",
                            subtitle:
                                "Profile views, trends, and audience insights",
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProfileEngagementScreen(uid: widget.uid),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.clockCounterClockwise(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Ping History",
                            subtitle: "See pings you created and joined",
                            onTap: _openPingHistory,
                          ),
                          const SizedBox(height: 10),
                          _MenuTile(
                            icon: PhosphorIcons.bell(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Notifications",
                            subtitle: "Manage app and activity alerts",
                            onTap: () {
                              _showNotificationsSheet(
                                context: context,
                                activity: notifActivity,
                                general: notifGeneral,
                                requests: notifRequests,
                                saving: _savingNotifications,
                                onChanged: (key, value) async {
                                  await _setNotificationSetting(key, value);
                                },
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          _SectionHeader(
                            title: "Who can see your Pings",
                            icon: PhosphorIcons.eye(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: PhosphorIcons.lockSimple(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Account privacy",
                            subtitle: isPrivateAccount
                                ? "Your account is private"
                                : "Your account is public",
                            trailing: _savingPrivacy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.black,
                                      ),
                                    ),
                                  )
                                : Switch(
                                    value: isPrivateAccount,
                                    activeThumbColor: AppColors.brandGreen,
                                    onChanged: (v) => _setPrivateAccount(v),
                                  ),
                            onTap: () => _setPrivateAccount(!isPrivateAccount),
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.usersThree(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Close connections",
                            subtitle:
                                "Choose the people you trust most",
                            onTap: () {
                              _showCloseFriendsSheet(
                                context: context,
                                ownerUid: widget.uid,
                                searchController: _friendSearchCtrl,
                                searchText: _friendSearch,
                                onToggle: ({
                                  required String friendUid,
                                  required bool makeCloseFriend,
                                }) async {
                                  await _toggleCloseFriend(
                                    friendUid: friendUid,
                                    makeCloseFriend: makeCloseFriend,
                                  );
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.prohibitInset(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Blocked",
                            subtitle: "See who you’ve blocked",
                            onTap: () {
                              _showBlockedUsersSheet(
                                context: context,
                                ownerUid: widget.uid,
                                onUnblock: (blockedUid) async {
                                  await _removeBlockedUser(blockedUid);
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.broadcast(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Visibility",
                            subtitle:
                                "Default visibility: ${_prettyVisibility(defaultPingVisibility)}",
                            onTap: () {
                              _showVisibilitySheet(
                                context: context,
                                currentValue: defaultPingVisibility,
                                onSelected: (value) async {
                                  await _setVisibility(value);
                                },
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          _SectionHeader(
                            title: "Interaction",
                            icon: PhosphorIcons.handshake(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: PhosphorIcons.magnifyingGlass(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Find people and communities",
                            subtitle: "Discover people and community pages",
                            onTap: () {
                              _showFindFriendsSheet(
                                context: context,
                                ownerUid: widget.uid,
                                searchController: _findFriendsCtrl,
                                searchText: _findFriendsSearch,
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          _SectionHeader(
                            title: "Personalization",
                            icon: PhosphorIcons.palette(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: PhosphorIcons.paintBucket(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Theme",
                            subtitle: "Current: ${_prettyTheme(selectedTheme)}",
                            onTap: () {
                              _showThemeSheet(
                                context: context,
                                selected: selectedTheme,
                                onSelected: (value) async {
                                  await _setPreference("theme", value);
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.translate(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Language",
                            subtitle: "Current: $selectedLanguage",
                            onTap: () {
                              _showLanguageSheet(
                                context: context,
                                selected: selectedLanguage,
                                onSelected: (value) async {
                                  await _setPreference("language", value);
                                },
                              );
                            },
                          ),

                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.userCircleGear(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Edit full profile",
                            subtitle:
                                "Go back through your full identity setup",
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const IdentityBasicScreen(),
                                ),
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          _SectionHeader(
                            title: "Safety and info",
                            icon: PhosphorIcons.shieldCheck(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: verified
                                ? PhosphorIcons.sealCheck(
                                    PhosphorIconsStyle.fill,
                                  )
                                : hasPendingVerification
                                    ? PhosphorIcons.hourglassMedium(
                                        PhosphorIconsStyle.light,
                                      )
                                    : PhosphorIcons.sealCheck(
                                        PhosphorIconsStyle.light,
                                      ),
                            title: verified
                                ? "Verified"
                                : hasPendingVerification
                                    ? "Verification requested"
                                    : "Request verification",
                            subtitle: verified
                                ? "Your account is verified"
                                : hasPendingVerification
                                    ? "Your verification request is under review"
                                    : "Apply for a verified badge",
                            onTap: () {
                              _openVerificationInfo(
                                userData: userData,
                                verified: verified,
                                hasPendingVerification:
                                    hasPendingVerification,
                                verificationType: verificationType,
                              );
                            },
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.info(
                              PhosphorIconsStyle.light,
                            ),
                            title: "About",
                            subtitle: "What Pingmee is and how it works",
                            onTap: () => _showSimpleInfoSheet(
                              context: context,
                              title: "About Pingmee",
                              body:
                                  "Pingmee helps people connect through shared interests, location, and real-world social moments. To learn more visit www.pingmee.com",
                            ),
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.shieldWarning(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Safety guidance",
                            subtitle: "Tips for safer interactions",
                            onTap: () => _showSimpleInfoSheet(
                              context: context,
                              title: "Safety guidance",
                              body:
                                  "Meet in public places, trust your instincts, avoid sharing sensitive personal details too early, and use block/report when needed.",
                            ),
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.warningCircle(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Report situation",
                            subtitle:
                                "Escalate issues or suspicious behavior",
                            danger: true,
                            onTap: () => _comingSoon(
                              "Report situation flow coming next.",
                            ),
                          ),

                          const SizedBox(height: 24),

                          _SectionHeader(
                            title: "Login",
                            icon: PhosphorIcons.signIn(
                              PhosphorIconsStyle.fill,
                            ),
                          ),
                          const SizedBox(height: 12),

                          _MenuTile(
                            icon: PhosphorIcons.userPlus(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Add account",
                            subtitle: "Add another account to this device",
                            onTap: _goToSignupScreen,
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.repeat(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Switch account",
                            subtitle: "Move between saved accounts",
                            onTap: _showSwitchAccountSheet,
                          ),
                          const SizedBox(height: 10),

                          _MenuTile(
                            icon: PhosphorIcons.signOut(
                              PhosphorIconsStyle.light,
                            ),
                            title: "Log out",
                            subtitle: "Sign out of your current account",
                            danger: true,
                            onTap: () async {
                              final yes = await _showConfirmDialog(
                                context: context,
                                title: "Log out?",
                                body: "You’ll be signed out of this account.",
                                confirmText: "Log out",
                                danger: true,
                              );
                              if (yes == true) {
                                await _logout();
                              }
                            },
                          ),

                          const SizedBox(height: 22),
                        ]),
                      ),
                    ),
                  ],
                );
              },
            ),

            if (_switchingAccount)
              Positioned.fill(
                child: AbsorbPointer(
                  absorbing: true,
                  child: Container(
                    color: Colors.black.withOpacity(.18),
                    child: Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            width: 220,
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.88),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.black.withOpacity(.12),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 24,
                                  offset: const Offset(0, 12),
                                  color: Colors.black.withOpacity(.10),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.6,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.brandGreen,
                                    ),
                                  ),
                                ),
                                SizedBox(height: 14),
                                Text(
                                  "Switching account...",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: Colors.black87,
                                  ),
                                ),
                                SizedBox(height: 6),
                                Text(
                                  "Please wait a moment",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12.5,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
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

  String _prettyVisibility(String value) {
    switch (value) {
      case "friends":
        return "Connections";
      case "verified":
        return "Verified";
      default:
        return "Public";
    }
  }

  String _prettyTheme(String value) {
    switch (value) {
      case "light":
        return "Light";
      case "dark":
        return "Dark";
      default:
        return "System";
    }
  }
  }

Future<bool?> _showConfirmDialog({
    required BuildContext context,
    required String title,
    required String body,
    required String confirmText,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.black.withOpacity(.10)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                            danger ? Colors.red.shade600 : Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: Text(
                          confirmText,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
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

  void _showVerificationInfoSheet({
    required BuildContext context,
    required bool verified,
    required bool hasPendingVerification,
    required String verificationType,
    required VoidCallback onRequestTap,
  }) {
    String prettyType(String raw) {
      switch (raw.trim().toLowerCase()) {
        case "business":
          return "Business";
        case "trusted":
          return "Trusted";
        case "identity":
        default:
          return "Identity";
      }
    }

    final statusTitle = verified
        ? "Your account is verified"
        : hasPendingVerification
            ? "Verification requested"
            : "Get verified on Pingmee";

    final statusText = verified
        ? "This account has already been verified. The blue badge helps people trust that your profile is authentic."
        : hasPendingVerification
            ? "Your request is currently under review. Once approved, your profile will receive a blue verification badge."
            : "Verification helps people trust that your profile is real and notable on Pingmee. It adds extra confidence when people view your account.";

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        final h = MediaQuery.of(context).size.height;

        return _GlassBottomSheet(
          child: SizedBox(
            height: h * 0.78,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 14),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "Verification",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFEAF5FF),
                                Color(0xFFF6FBFF),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: const Color(0xFF1D9BF0).withOpacity(.12),
                            ),
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 68,
                                height: 68,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1D9BF0).withOpacity(.10),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.verified_rounded,
                                  color: Color(0xFF1D9BF0),
                                  size: 36,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                statusTitle,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                statusText,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w400,
                                  fontSize: 12.8,
                                  height: 1.35,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 14),

                        _VerificationInfoTile(
                          icon: PhosphorIcons.shieldCheck(
                            PhosphorIconsStyle.light,
                          ),
                          title: "What verification means",
                          body:
                              "A verified badge tells people this profile has been reviewed and recognized as authentic.",
                        ),
                        const SizedBox(height: 10),

                        _VerificationInfoTile(
                          icon: PhosphorIcons.usersThree(
                            PhosphorIconsStyle.light,
                          ),
                          title: "Why it matters",
                          body:
                              "It can improve trust, reduce impersonation concerns, and make your profile feel more credible.",
                        ),
                        const SizedBox(height: 10),

                        _VerificationInfoTile(
                          icon: PhosphorIcons.identificationBadge(
                            PhosphorIconsStyle.light,
                          ),
                          title: "Current status",
                          body: verified
                              ? "Verified • ${prettyType(verificationType)}"
                              : hasPendingVerification
                                  ? "Pending review"
                                  : "Not verified yet",
                        ),
                      ],
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: (verified || hasPendingVerification)
                          ? () => Navigator.pop(context)
                          : onRequestTap,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (verified || hasPendingVerification)
                            ? Colors.black.withOpacity(.08)
                            : AppColors.brandGreen,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        verified
                            ? "Already verified"
                            : hasPendingVerification
                                ? "Request pending"
                                : "Request verification",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          color: (verified || hasPendingVerification)
                              ? Colors.black87
                              : Colors.white,
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

  Future<void> _showVerificationRequestSheet({
    required BuildContext context,
    required Map<String, dynamic> userData,
    required Future<void> Function({
      required String typeRequested,
      required String reason,
    }) onSubmit,
  }) async {
    String selectedType = "identity";
    final reasonCtrl = TextEditingController();
    bool loading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                ),
                child: _GlassBottomSheet(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(height: 14),

                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                "Request verification",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: loading
                                  ? null
                                  : () => Navigator.pop(sheetContext),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),

                        const SizedBox(height: 6),

                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1D9BF0).withOpacity(.06),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: const Color(0xFF1D9BF0).withOpacity(.10),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.verified_rounded,
                                color: Color(0xFF1D9BF0),
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  "Choose the verification type that fits your profile best, then explain why this account should be verified.",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w400,
                                    fontSize: 12.6,
                                    height: 1.35,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 14),

                        DropdownButtonFormField<String>(
                          initialValue: selectedType,
                          decoration: InputDecoration(
                            labelText: "Verification type",
                            labelStyle: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                              color: Colors.black54,
                            ),
                            filled: true,
                            fillColor: Colors.white.withOpacity(.90),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: Colors.black.withOpacity(.08),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: Colors.black.withOpacity(.08),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: AppColors.brandGreen.withOpacity(.55),
                              ),
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: "identity",
                              child: Text(
                                "Identity",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            DropdownMenuItem(
                              value: "trusted",
                              child: Text(
                                "Trusted",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            DropdownMenuItem(
                              value: "business",
                              child: Text(
                                "Business",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                          onChanged: loading
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setModalState(() => selectedType = value);
                                },
                        ),

                        const SizedBox(height: 12),

                        TextField(
                          controller: reasonCtrl,
                          maxLines: 5,
                          maxLength: 240,
                          enabled: !loading,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: InputDecoration(
                            labelText: "Why should this account be verified?",
                            hintText: "Add context about authenticity, recognition, brand presence, or trust.",
                            alignLabelWithHint: true,
                            labelStyle: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w500,
                              color: Colors.black54,
                            ),
                            hintStyle: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w400,
                              color: Colors.black.withOpacity(.40),
                            ),
                            filled: true,
                            fillColor: Colors.white.withOpacity(.90),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: Colors.black.withOpacity(.08),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: Colors.black.withOpacity(.08),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide(
                                color: AppColors.brandGreen.withOpacity(.55),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 14),

                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: loading
                                ? null
                                : () async {
                                    final reason = reasonCtrl.text.trim();
                                    if (reason.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text("Please add a reason first."),
                                        ),
                                      );
                                      return;
                                    }

                                    setModalState(() => loading = true);

                                    try {
                                      await onSubmit(
                                        typeRequested: selectedType,
                                        reason: reason,
                                      );

                                      if (!context.mounted) return;
                                      Navigator.pop(sheetContext);

                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text("Verification request sent."),
                                        ),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            e.toString().replaceFirst("Exception: ", ""),
                                          ),
                                        ),
                                      );
                                    } finally {
                                      if (context.mounted) {
                                        setModalState(() => loading = false);
                                      }
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.brandGreen,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: loading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : const Text(
                                    "Submit request",
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
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
          },
        );
      },
    );
  }

class _OwnedCommunityMenuItem {
  final String id;
  final String name;
  final String headline;
  final String photoUrl;
  final int subscribersCount;
  final int eventsCount;
  final Timestamp? createdAt;

  const _OwnedCommunityMenuItem({
    required this.id,
    required this.name,
    required this.headline,
    required this.photoUrl,
    required this.subscribersCount,
    required this.eventsCount,
    required this.createdAt,
  });
}

class _VerificationInfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _VerificationInfoTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.86),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF1D9BF0).withOpacity(.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 18,
              color: const Color(0xFF1D9BF0),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    fontSize: 12.5,
                    height: 1.30,
                    color: Colors.black54,
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

void _showSimpleInfoSheet({
  required BuildContext context,
  required String title,
  required String body,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) {
      return _GlassBottomSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w400,
                  color: Colors.black54,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    "Close",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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

void _showVisibilitySheet({
  required BuildContext context,
  required String currentValue,
  required Future<void> Function(String value) onSelected,
}) {
  const values = ["public", "friends", "verified"];

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) {
      return _GlassBottomSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Default visibility",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ...values.map((value) {
                final selected = value == currentValue;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MenuTile(
                    icon: value == "public"
                        ? PhosphorIcons.globe(PhosphorIconsStyle.light)
                        : value == "friends"
                            ? PhosphorIcons.usersThree(
                                PhosphorIconsStyle.light,
                              )
                            : PhosphorIcons.sealCheck(
                                PhosphorIconsStyle.light,
                              ),
                    title: value == "public"
                        ? "Public"
                        : value == "friends"
                            ? "Connections"
                            : "Verified",
                    subtitle: selected ? "Currently selected" : "Tap to use this",
                    trailing: selected
                        ? Icon(
                            PhosphorIcons.checkCircle(
                              PhosphorIconsStyle.fill,
                            ),
                            color: Colors.black,
                          )
                        : null,
                    onTap: () async {
                      Navigator.pop(context);
                      await onSelected(value);
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      );
    },
  );
}

void _showThemeSheet({
  required BuildContext context,
  required String selected,
  required Future<void> Function(String value) onSelected,
}) {
  const values = ["system", "light", "dark"];

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) {
      return _GlassBottomSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Choose theme",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ...values.map((value) {
                final active = value == selected;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MenuTile(
                    icon: value == "light"
                        ? PhosphorIcons.sun(PhosphorIconsStyle.light)
                        : value == "dark"
                            ? PhosphorIcons.moon(PhosphorIconsStyle.light)
                            : PhosphorIcons.desktop(
                                PhosphorIconsStyle.light,
                              ),
                    title: value == "light"
                        ? "Light"
                        : value == "dark"
                            ? "Dark"
                            : "System",
                    subtitle: active ? "Currently selected" : "Tap to select",
                    trailing: active
                        ? Icon(
                            PhosphorIcons.checkCircle(
                              PhosphorIconsStyle.fill,
                            ),
                            color: AppColors.brandGreen,
                          )
                        : null,
                    onTap: () async {
                      Navigator.pop(context);
                      await onSelected(value);
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      );
    },
  );
}

void _showLanguageSheet({
  required BuildContext context,
  required String selected,
  required Future<void> Function(String value) onSelected,
}) {
  const values = ["English", "French", "Bemba", "Nyanja"];

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) {
      return _GlassBottomSheet(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    "Choose language",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...values.map((value) {
                    final active = value == selected;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _MenuTile(
                        icon: PhosphorIcons.translate(PhosphorIconsStyle.light),
                        title: value,
                        subtitle: active ? "Currently selected" : "Tap to select",
                        trailing: active
                            ? Icon(
                                PhosphorIcons.checkCircle(
                                  PhosphorIconsStyle.fill,
                                ),
                                color: AppColors.brandGreen,
                              )
                            : null,
                        onTap: () async {
                          Navigator.pop(context);
                          await onSelected(value);
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _showNotificationsSheet({
  required BuildContext context,
  required bool activity,
  required bool general,
  required bool requests,
  required bool saving,
  required Future<void> Function(String key, bool value) onChanged,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) {
      return _GlassBottomSheet(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Notifications",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (saving)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.black,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _SwitchTile(
                icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
                title: "General",
                subtitle: "Product and general updates",
                value: general,
                onChanged: (v) => onChanged("general", v),
              ),
              const SizedBox(height: 10),
              _SwitchTile(
                icon: PhosphorIcons.chartLineUp(
                  PhosphorIconsStyle.light,
                ),
                title: "Activity",
                subtitle: "Likes, interactions, updates, activity",
                value: activity,
                onChanged: (v) => onChanged("activity", v),
              ),
              const SizedBox(height: 10),
              _SwitchTile(
                icon: PhosphorIcons.userPlus(
                  PhosphorIconsStyle.light,
                ),
                title: "Requests",
                subtitle: "Connection requests and response alerts",
                value: requests,
                onChanged: (v) => onChanged("requests", v),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void _showCloseFriendsSheet({
  required BuildContext context,
  required String ownerUid,
  required TextEditingController searchController,
  required String searchText,
  required Future<void> Function({
    required String friendUid,
    required bool makeCloseFriend,
  }) onToggle,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CloseFriendsSheet(
      ownerUid: ownerUid,
      searchController: searchController,
      onToggle: onToggle,
    ),
  );
}

void _showBlockedUsersSheet({
  required BuildContext context,
  required String ownerUid,
  required Future<void> Function(String blockedUid) onUnblock,
}) {
  final blockRef = FirebaseFirestore.instance
      .collection("users")
      .doc(ownerUid)
      .collection("blocked");

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) {
      final h = MediaQuery.of(context).size.height;
      return _GlassBottomSheet(
        child: SizedBox(
          height: h * 0.85,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        "Blocked",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: blockRef.snapshots(),
                  builder: (context, snap) {
                    final docs = snap.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const _CenteredEmptyState(
                        title: "No blocked users",
                        subtitle: "Anyone you block will appear here.",
                      );
                    }

                    return ListView.separated(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final blockedUid = docs[i].id;

                        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection("users")
                              .doc(blockedUid)
                              .snapshots(),
                          builder: (context, blockedSnap) {
                            final user = blockedSnap.data?.data() ?? {};
                            final name =
                                (user["fullName"] ?? "Blocked user").toString();
                            final username =
                                (user["username"] ?? "").toString();
                            final photoUrl =
                                (user["photoUrl"] ?? "").toString();

                            final verification = Map<String, dynamic>.from(user["verification"] ?? {});
                            final isVerified = verification["status"] == "verified";

                            return _PersonActionTile(
                              photoUrl: photoUrl,
                              title: name,
                              subtitle: username.isEmpty ? "" : "@$username",
                              verified: isVerified,
                              trailing: OutlinedButton(
                                onPressed: () async {
                                  await onUnblock(blockedUid);
                                },
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: Colors.black.withOpacity(.10),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: Text(
                                  "Unblock",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void _showFindFriendsSheet({
  required BuildContext context,
  required String ownerUid,
  required TextEditingController searchController,
  required String searchText,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _FindFriendsSheet(
      ownerUid: ownerUid,
      searchController: searchController,
    ),
  );
}

class _FindItem {
  final String id;
  final String title;
  final String subtitle;
  final String photoUrl;
  final bool verified;
  final bool isCommunity;

  const _FindItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.photoUrl,
    required this.verified,
    required this.isCommunity,
  });
}

class _FindFriendsSheet extends StatefulWidget {
  final String ownerUid;
  final TextEditingController searchController;

  const _FindFriendsSheet({
    required this.ownerUid,
    required this.searchController,
  });

  @override
  State<_FindFriendsSheet> createState() => _FindFriendsSheetState();
}

class _FindFriendsSheetState extends State<_FindFriendsSheet> {
  static const int _pageSize = 30;

  final ScrollController _scrollController = ScrollController();

  Timer? _debounce;

  bool _loading = true;
  bool _searching = false;
  bool _loadingMore = false;

  String _query = "";
  int _searchLimit = _pageSize;

  final Set<String> _friendIds = <String>{};
  final Set<String> _blockedIds = <String>{};

  List<_FindItem> _suggestions = const [];
  List<_FindItem> _searchResults = const [];

  DocumentSnapshot<Map<String, dynamic>>? _verifiedCursor;
  bool _hasMoreVerified = true;

  @override
  void initState() {
    super.initState();
    _query = widget.searchController.text.trim().toLowerCase();
    widget.searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onSearchChanged);
    _scrollController.removeListener(_onScroll);
    _debounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final next = widget.searchController.text.trim().toLowerCase();

    if (_query == next) return;

    setState(() {
      _query = next;
      _searchLimit = _pageSize;
    });

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      if (!mounted) return;

      if (_query.isEmpty) {
        setState(() {
          _searchResults = const [];
        });
        return;
      }

      await _runRemoteSearch();
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 220) return;

    if (_query.isNotEmpty) {
      if (_loadingMore) return;
      _loadMoreSearch();
    } else {
      if (_loadingMore || !_hasMoreVerified) return;
      _loadMoreSuggestions();
    }
  }

  Future<void> _bootstrap() async {
    setState(() => _loading = true);

    try {
      await _loadExclusionSets();
      await _loadInitialSuggestions();

      if (_query.isNotEmpty) {
        await _runRemoteSearch();
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadExclusionSets() async {
    final db = FirebaseFirestore.instance;
    final ownerRef = db.collection("users").doc(widget.ownerUid);

    final ownerSnap = await ownerRef.get();
    final ownerData = ownerSnap.data() ?? {};

    _friendIds.addAll(List<String>.from(ownerData["friendIds"] ?? []));
    _friendIds.remove(widget.ownerUid);

    final friendsSnap = await ownerRef.collection("friends").get();
    for (final doc in friendsSnap.docs) {
      final friendId = (doc.data()["friendId"] ?? "").toString().trim();
      if (friendId.isNotEmpty) _friendIds.add(friendId);
    }

    final blockedSnap = await ownerRef.collection("blocked").get();
    for (final doc in blockedSnap.docs) {
      _blockedIds.add(doc.id);
    }
  }

  bool _shouldExcludeForSuggestions(String id) {
    if (id == widget.ownerUid) return true;
    if (_friendIds.contains(id)) return true;
    if (_blockedIds.contains(id)) return true;
    return false;
  }

  bool _shouldExcludeForSearch(String id) {
    if (id == widget.ownerUid) return true;
    if (_blockedIds.contains(id)) return true;
    return false;
  }

  Future<void> _loadInitialSuggestions() async {
    final db = FirebaseFirestore.instance;
    final items = <_FindItem>[];
    final seen = <String>{};

    Query<Map<String, dynamic>> q = db
        .collection("users")
        .where("verification.status", isEqualTo: "verified")
        .orderBy("fullName")
        .limit(_pageSize);

    final snap = await q.get();

    if (snap.docs.isNotEmpty) {
      _verifiedCursor = snap.docs.last;
    }
    if (snap.docs.length < _pageSize) {
      _hasMoreVerified = false;
    }

    for (final doc in snap.docs) {
      if (_shouldExcludeForSuggestions(doc.id)) continue;

      final d = doc.data();
      final name = (d["fullName"] ?? "User").toString().trim();
      final username = (d["username"] ?? "").toString().trim();
      final photoUrl = (d["photoUrl"] ?? "").toString().trim();

      if (!seen.add(doc.id)) continue;

      items.add(
        _FindItem(
          id: doc.id,
          title: name.isEmpty ? "User" : name,
          subtitle: username.isEmpty ? "Verified account" : "@$username",
          photoUrl: photoUrl,
          verified: true,
          isCommunity: false,
        ),
      );
    }

    items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    if (!mounted) return;
    setState(() {
      _suggestions = items;
    });
  }

  Future<void> _loadMoreSuggestions() async {
    if (_verifiedCursor == null || !_hasMoreVerified) return;

    setState(() => _loadingMore = true);

    try {
      final db = FirebaseFirestore.instance;

      final snap = await db
          .collection("users")
          .where("verification.status", isEqualTo: "verified")
          .orderBy("fullName")
          .startAfterDocument(_verifiedCursor!)
          .limit(_pageSize)
          .get();

      if (snap.docs.isNotEmpty) {
        _verifiedCursor = snap.docs.last;
      }
      if (snap.docs.length < _pageSize) {
        _hasMoreVerified = false;
      }

      final next = List<_FindItem>.from(_suggestions);
      final seen = next.map((e) => e.id).toSet();

      for (final doc in snap.docs) {
        if (_shouldExcludeForSuggestions(doc.id)) continue;
        if (!seen.add(doc.id)) continue;

        final d = doc.data();
        final name = (d["fullName"] ?? "User").toString().trim();
        final username = (d["username"] ?? "").toString().trim();
        final photoUrl = (d["photoUrl"] ?? "").toString().trim();

        next.add(
          _FindItem(
            id: doc.id,
            title: name.isEmpty ? "User" : name,
            subtitle: username.isEmpty ? "Verified account" : "@$username",
            photoUrl: photoUrl,
            verified: true,
            isCommunity: false,
          ),
        );
      }

      next.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _suggestions = next;
      });
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _loadMoreSearch() async {
    if (_loadingMore) return;

    setState(() {
      _loadingMore = true;
      _searchLimit += _pageSize;
    });

    try {
      await _runRemoteSearch();
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _runRemoteSearch() async {
    final q = _query.trim();
    if (q.isEmpty) return;

    setState(() => _searching = true);

    try {
      final db = FirebaseFirestore.instance;
      final end = "$q\uf8ff";

      final futures = <Future>[
        db
            .collection("users")
            .orderBy("fullName_lc")
            .startAt([q])
            .endAt([end])
            .limit(_searchLimit)
            .get(),
        db
            .collection("users")
            .orderBy("username_lc")
            .startAt([q])
            .endAt([end])
            .limit(_searchLimit)
            .get(),
      ];

      // OPTIONAL:
      // If your communities/pages collection uses a different name or field,
      // change "communities" and "name_lc" below.
      futures.add(
        db
            .collection("communities")
            .orderBy("name_lc")
            .startAt([q])
            .endAt([end])
            .limit(_searchLimit)
            .get(),
      );

      final results = await Future.wait(futures);

      final byId = <String, _FindItem>{};

      final usersByName = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final usersByUsername = results[1] as QuerySnapshot<Map<String, dynamic>>;

      for (final doc in [...usersByName.docs, ...usersByUsername.docs]) {
        if (_shouldExcludeForSearch(doc.id)) continue;

        final d = doc.data();
        final name = (d["fullName"] ?? "User").toString().trim();
        final username = (d["username"] ?? "").toString().trim();
        final photoUrl = (d["photoUrl"] ?? "").toString().trim();
        final verification = Map<String, dynamic>.from(d["verification"] ?? {});
        final isVerified = verification["status"] == "verified";

        byId["user_${doc.id}"] = _FindItem(
          id: doc.id,
          title: name.isEmpty ? "User" : name,
          subtitle: username.isEmpty ? "User" : "@$username",
          photoUrl: photoUrl,
          verified: isVerified,
          isCommunity: false,
        );
      }

      // Communities/pages are optional. If collection/index/field doesn't exist,
      // just ignore the failure instead of crashing the sheet.
      if (results.length > 2) {
        try {
          final communitySnap = results[2] as QuerySnapshot<Map<String, dynamic>>;

          for (final doc in communitySnap.docs) {
            final d = doc.data();
            final title = (d["name"] ?? d["title"] ?? "Page").toString().trim();
            final handle = (d["username"] ?? d["slug"] ?? "").toString().trim();
            final image = (d["photoUrl"] ??
                    d["imageUrl"] ??
                    d["coverUrl"] ??
                    "")
                .toString()
                .trim();

            byId["community_${doc.id}"] = _FindItem(
              id: doc.id,
              title: title.isEmpty ? "Page" : title,
              subtitle: handle.isEmpty ? "Page" : "@$handle",
              photoUrl: image,
              verified: false,
              isCommunity: true,
            );
          }
        } catch (_) {}
      }

      final merged = byId.values.toList()
        ..sort((a, b) {
          if (a.isCommunity != b.isCommunity) {
            return a.isCommunity ? 1 : -1;
          }
          if (a.verified != b.verified) {
            return a.verified ? -1 : 1;
          }
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });

      if (!mounted) return;
      setState(() {
        _searchResults = merged;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchResults = const [];
      });
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final showingSearch = _query.isNotEmpty;
    final items = showingSearch ? _searchResults : _suggestions;

    return _GlassBottomSheet(
      child: SizedBox(
        height: h * 0.90,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Find people and Communities",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SearchField(
                controller: widget.searchController,
                hintText: "Search people or communities",
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  showingSearch
                      ? "Searching across all matching users and communities"
                      : "Suggestions",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                    color: Colors.black54,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_searching && showingSearch && items.isEmpty)
                      ? const Center(child: CircularProgressIndicator())
                      : items.isEmpty
                          ? const _CenteredEmptyState(
                              title: "No results",
                              subtitle: "Try a different name, username or community title.",
                            )
                          : ListView.separated(
                              controller: _scrollController,
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                              itemCount: items.length + (_loadingMore ? 1 : 0),
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (_, i) {
                                if (i >= items.length) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 10),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }

                                final item = items[i];

                                return _PersonActionTile(
                                  photoUrl: item.photoUrl,
                                  title: item.title,
                                  subtitle: item.subtitle,
                                  verified: item.verified,
                                  trailing: OutlinedButton(
                                    onPressed: () {
                                      Navigator.pop(context);

                                      if (item.isCommunity) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Wire your page/community route here next.",
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ProfileTab(
                                            profileUid: item.id,
                                          ),
                                        ),
                                      );
                                    },
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(
                                        color: Colors.black.withOpacity(.10),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: Text(
                                      item.isCommunity ? "Open" : "View",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
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

class _SheetPersonRecord {
  final String uid;
  final String name;
  final String username;
  final String photoUrl;
  final bool verified;
  final bool isCloseFriend;
  final bool isFriendOfFriend;

  const _SheetPersonRecord({
    required this.uid,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.verified,
    required this.isCloseFriend,
    required this.isFriendOfFriend,
  });

  String get searchHaystack =>
      "${name.toLowerCase().trim()} ${username.toLowerCase().trim()}";

  _SheetPersonRecord copyWith({
    String? uid,
    String? name,
    String? username,
    String? photoUrl,
    bool? verified,
    bool? isCloseFriend,
    bool? isFriendOfFriend,
  }) {
    return _SheetPersonRecord(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      username: username ?? this.username,
      photoUrl: photoUrl ?? this.photoUrl,
      verified: verified ?? this.verified,
      isCloseFriend: isCloseFriend ?? this.isCloseFriend,
      isFriendOfFriend: isFriendOfFriend ?? this.isFriendOfFriend,
    );
  }
}

class _CloseFriendsSheet extends StatefulWidget {
  final String ownerUid;
  final TextEditingController searchController;
  final Future<void> Function({
    required String friendUid,
    required bool makeCloseFriend,
  }) onToggle;

  const _CloseFriendsSheet({
    required this.ownerUid,
    required this.searchController,
    required this.onToggle,
  });

  @override
  State<_CloseFriendsSheet> createState() => _CloseFriendsSheetState();
}

class _CloseFriendsSheetState extends State<_CloseFriendsSheet> {
  bool _loading = true;
  bool _saving = false;
  String _query = "";
  List<_SheetPersonRecord> _friends = const [];

  @override
  void initState() {
    super.initState();
    _query = widget.searchController.text.trim().toLowerCase();
    widget.searchController.addListener(_onSearchChanged);
    _loadFriends();
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onSearchChanged);
    super.dispose();
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {
      _query = widget.searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _loadFriends() async {
    setState(() => _loading = true);

    try {
      final db = FirebaseFirestore.instance;
      final friendsSnap = await db
          .collection("users")
          .doc(widget.ownerUid)
          .collection("friends")
          .get();

      final futures = friendsSnap.docs.map((friendDoc) async {
        final friendUid = (friendDoc.data()["friendId"] ?? "").toString().trim();
        if (friendUid.isEmpty) return null;

        final userSnap = await db.collection("users").doc(friendUid).get();
        final user = userSnap.data() ?? {};
        final verification =
            Map<String, dynamic>.from(user["verification"] ?? {});

        final fullName = (user["fullName"] ?? "Friend").toString().trim();
        final username = (user["username"] ?? "").toString().trim();
        final photoUrl = (user["photoUrl"] ?? "").toString().trim();

        return _SheetPersonRecord(
          uid: friendUid,
          name: fullName.isEmpty ? "Friend" : fullName,
          username: username,
          photoUrl: photoUrl,
          verified: verification["status"] == "verified",
          isCloseFriend: friendDoc.data()["isCloseFriend"] == true,
          isFriendOfFriend: false,
        );
      }).toList();

      final records = (await Future.wait(futures))
          .whereType<_SheetPersonRecord>()
          .toList();

      records.sort((a, b) {
        if (a.isCloseFriend != b.isCloseFriend) {
          return a.isCloseFriend ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _friends = records;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggleCloseFriend(_SheetPersonRecord person) async {
    if (_saving) return;

    setState(() => _saving = true);
    final nextValue = !person.isCloseFriend;

    try {
      await widget.onToggle(
        friendUid: person.uid,
        makeCloseFriend: nextValue,
      );

      if (!mounted) return;

      setState(() {
        _friends = _friends.map((item) {
          if (item.uid != person.uid) return item;
          return item.copyWith(isCloseFriend: nextValue);
        }).toList();
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;

    final filtered = _friends.where((person) {
      if (_query.isEmpty) return true;
      return person.searchHaystack.contains(_query);
    }).toList();

    return _GlassBottomSheet(
      child: SizedBox(
        height: h * 0.90,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Close connections",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _SearchField(
                controller: widget.searchController,
                hintText: "Search your connections...",
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _friends.isEmpty
                      ? const _CenteredEmptyState(
                          title: "No connections yet",
                          subtitle:
                              "Make connections first, then add close connections here.",
                        )
                      : filtered.isEmpty
                          ? const _CenteredEmptyState(
                              title: "No results",
                              subtitle: "Try a different name or username.",
                            )
                          : ListView.separated(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, i) {
                                final person = filtered[i];

                                return _PersonActionTile(
                                  photoUrl: person.photoUrl,
                                  title: person.name,
                                  subtitle: person.username.isEmpty
                                      ? ""
                                      : "@${person.username}",
                                  verified: person.verified,
                                  trailing: ElevatedButton(
                                    onPressed: _saving
                                        ? null
                                        : () => _toggleCloseFriend(person),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: person.isCloseFriend
                                          ? Colors.black.withOpacity(.08)
                                          : AppColors.brandGreen,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: Text(
                                      person.isCloseFriend ? "Added" : "Add",
                                      style: TextStyle(
                                        fontFamily: "Nunito",
                                        fontWeight: FontWeight.w600,
                                        color: person.isCloseFriend
                                            ? Colors.black87
                                            : Colors.white,
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





class _InlineVerifiedBadge extends StatelessWidget {
  const _InlineVerifiedBadge();

  @override
  Widget build(BuildContext context) {
    return Icon(
      PhosphorIcons.sealCheck(PhosphorIconsStyle.fill),
      size: 16,
      color: const Color(0xFF3B82F6),
    );
  }
}

class _OwnerMenuHeroCard extends StatelessWidget {
  final String title;
  final String subtitle;

  const _OwnerMenuHeroCard({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return _PlayfulGreenSurface(
      borderRadius: BorderRadius.circular(28),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            Positioned(
              top: -4,
              right: 0,
              child: Transform.rotate(
                angle: 0.04,
                child: _StickyNoteMini(
                  text: "Pingmee!!!",
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 110),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      fontSize: 20,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(.88),
                      height: 1.28,
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

class _StickyNoteMini extends StatelessWidget {
  final String text;

  const _StickyNoteMini({required this.text});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 92,
          height: 92,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF3E46F),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 10),
                color: Colors.black.withOpacity(.15),
              ),
            ],
          ),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: Colors.black87,
              ),
            ),
          ),
        ),
        Positioned(
          top: -8,
          left: 20,
          child: Transform.rotate(
            angle: -0.18,
            child: Container(
              width: 36,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.55),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.85),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withOpacity(.06)),
          boxShadow: [
            BoxShadow(
              blurRadius: 14,
              offset: const Offset(0, 8),
              color: Colors.black.withOpacity(.05),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: Colors.black.withOpacity(.80),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({
    required this.title,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.brandGreen, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w500,
            fontSize: 15,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}

class _MainMenuGlassIconPill extends StatelessWidget {
  final IconData icon;
  final bool danger;

  const _MainMenuGlassIconPill({
    required this.icon,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = danger
        ? const Color(0xFFB42318)
        : const Color(0xFF111827);

    final bgStart = danger
        ? const Color(0xFFB42318).withOpacity(.075)
        : Colors.black.withOpacity(.07);

    final bgEnd = danger
        ? const Color(0xFFB42318).withOpacity(.035)
        : Colors.black.withOpacity(.035);

    final borderColor = danger
        ? const Color(0xFFB42318).withOpacity(.10)
        : Colors.black.withOpacity(.065);

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            bgStart,
            bgEnd,
          ],
        ),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, 5),
            color: Colors.black.withOpacity(.035),
          ),
        ],
      ),
      child: Center(
        child: PhosphorIcon(
          icon,
          size: 21,
          color: iconColor,
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool danger;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger
        ? Colors.red.shade700
        : Colors.black87;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.82),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.black.withOpacity(.06)),
            boxShadow: [
              BoxShadow(
                blurRadius: 14,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.04),
              ),
            ],
          ),
          child: Row(
            children: [
              _MainMenuGlassIconPill(
                icon: icon,
                danger: danger,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w500,
                        color: fg,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        color: Colors.black54,
                        height: 1.22,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              trailing ??
                  Icon(
                    PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                    size: 18,
                    color: Colors.black.withOpacity(.35),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.82),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
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
              size: 20,
              color: AppColors.brandGreen,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w400,
                    color: Colors.black54,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            value: value,
            activeThumbColor: AppColors.brandGreen,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;

  const _SearchField({
    required this.controller,
    required this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.black.withOpacity(.45)),
        prefixIcon: Icon(
          PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
          color: Colors.black.withOpacity(.45),
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(.82),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: Colors.black.withOpacity(.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: AppColors.brandGreen.withOpacity(.50)),
        ),
      ),
    );
  }
}

class _PersonActionTile extends StatelessWidget {
  final String photoUrl;
  final String title;
  final String subtitle;
  final bool verified;
  final Widget trailing;

  const _PersonActionTile({
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.verified,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final has = photoUrl.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.82),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF2F4F8),
              image: has
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: !has
                ? Icon(
                    PhosphorIcons.user(PhosphorIconsStyle.light),
                    color: Colors.black.withOpacity(.35),
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
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    if (verified) ...[
                      const SizedBox(width: 6),
                      const _InlineVerifiedBadge(),
                    ],
                  ],
                ),
                if (subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}

class _CenteredEmptyState extends StatelessWidget {
  final String title;
  final String subtitle;

  const _CenteredEmptyState({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withOpacity(.10),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                PhosphorIcons.sparkle(PhosphorIconsStyle.light),
                color: AppColors.brandGreen,
                size: 28,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                color: Colors.black54,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassBottomSheet extends StatelessWidget {
  final Widget child;

  const _GlassBottomSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(.65)),
            boxShadow: [
              BoxShadow(
                blurRadius: 24,
                offset: const Offset(0, -8),
                color: Colors.black.withOpacity(.10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PlayfulGreenSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _PlayfulGreenSurface({
    required this.borderRadius,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFF16C784),
              Color(0xFF16C784),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 10),
              color: Colors.black.withOpacity(.08),
            ),
          ],
        ),
        child: Stack(
          children: [
            const Positioned.fill(
              child: IgnorePointer(
                child: _PlayfulGreenDoodles(),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _PlayfulGreenDoodles extends StatelessWidget {
  const _PlayfulGreenDoodles();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 10,
          left: 12,
          child: Icon(
            Icons.auto_awesome,
            color: Colors.white.withOpacity(.85),
            size: 20,
          ),
        ),
        Positioned(
          top: 12,
          right: 16,
          child: Icon(
            Icons.favorite_border_rounded,
            color: const Color(0xFFD8FF88),
            size: 18,
          ),
        ),
        Positioned(
          bottom: 10,
          left: 20,
          child: Icon(
            Icons.auto_awesome,
            color: const Color(0xFFB7F44A),
            size: 24,
          ),
        ),
        Positioned(
          bottom: 8,
          right: 14,
          child: Icon(
            Icons.auto_awesome,
            color: Colors.white.withOpacity(.70),
            size: 18,
          ),
        ),
      ],
    );
  }
}

