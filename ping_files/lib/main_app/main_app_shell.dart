// main_app_shell: rebuilt for the author-tap fix on 2026-06-11
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'dart:math' as math;
import 'package:ping_files/main_app/tabs/map/map_tab.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ping_files/features/pings/create_ping_sheet.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ping_files/app_start_router.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/features/pings/create_ping_draft.dart';
import 'package:ping_files/main_app/tabs/feed/feed_tab.dart';
import 'package:ping_files/features/events/create_event_draft.dart';
import 'package:ping_files/features/events/create_event_screen.dart';
import 'package:ping_files/features/events/event_hosts_screen.dart';
import 'package:ping_files/features/chat/pingmee_chat_tab.dart';
import 'package:ping_files/features/chat/stream_chat_service.dart';
import 'package:stream_chat_flutter/stream_chat_flutter.dart';

class MainAppShell extends StatefulWidget {
  const MainAppShell({
    super.key,
    this.initialIndex = 0,
    this.initialProfileUid,
  });

  final int initialIndex;
  final String? initialProfileUid;

  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

class _MainAppShellState extends State<MainAppShell>
  with SingleTickerProviderStateMixin {
  late int index;
  String? _profileUidForTab;
  bool menuOpen = false;
  bool _openingCreateEvent = false;
  bool _navHiddenByScroll = false;

  final GlobalKey<MapTabState> _mapKey = GlobalKey<MapTabState>();
  final GlobalKey<FeedTabState> _feedKey = GlobalKey<FeedTabState>();

  final CreatePingDraft _pingDraft = CreatePingDraft();
  final CreateEventDraft _eventDraft = CreateEventDraft();

  void _hideCreateEventOpeningLoader() {
    if (!mounted || !_openingCreateEvent) return;
    setState(() => _openingCreateEvent = false);
  }

  Future<void> _openCreatePingSheet() async {
    await _closeMenu();
    if (!mounted) return;

    final previousIndex = index;

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _GreenLoaderDialog(),
    );

    await Future.delayed(const Duration(milliseconds: 80));

    GeoPoint? gp;

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        await Geolocator.openLocationSettings();
        throw Exception("Location services off");
      }

      var perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      if (perm == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
        throw Exception("Permission denied forever");
      }

      if (perm != LocationPermission.always &&
          perm != LocationPermission.whileInUse) {
        throw Exception("Permission not granted");
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      ).timeout(const Duration(seconds: 5));

      gp = GeoPoint(pos.latitude, pos.longitude);
    } catch (_) {
      gp = null;
    } finally {
      _closeLoader();
    }

    if (!mounted) return;

    final result = await Navigator.push<CreatePingResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePingSheet(
          initialGeoPoint: gp,
          draft: _pingDraft,
        ),
      ),
    );

    if (!mounted) return;

    if (result == null) {
      if (index != previousIndex) {
        _setIndex(previousIndex);
      }
      return;
    }

    // Success: just switch to Discovery and let the live streams update it.
    _setIndex(0);
    return;

    // Let the map settle first.
    await Future.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;

    final mapState = _mapKey.currentState;
    if (mapState == null) return;

    await mapState.refreshPings();

    // Remove this for now. It is unnecessary and risky here.
    // await mapState.recheckLocation();
  }
  
  void _closeLoader() {
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }


  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 165),
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  late final Animation<double> _menuOpen = CurvedAnimation(
    parent: _ctl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  late final Animation<double> _plusRotate = CurvedAnimation(
    parent: _ctl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );


  void _setIndex(int i) {
    if (menuOpen) _closeMenu();

    setState(() {
      index = i;
      _navHiddenByScroll = false;
    });
  }

  void _setNavHiddenByScroll(bool hidden) {
    if (!mounted) return;
    if (_navHiddenByScroll == hidden) return;

    setState(() {
      _navHiddenByScroll = hidden;
    });
  }

  @override
  void dispose() {
    _pingDraft.dispose();
    _eventDraft.dispose();
    _ctl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    index = widget.initialIndex;
    _profileUidForTab = widget.initialProfileUid;
  }

  void _openOwnProfileTab() {
    if (menuOpen) _closeMenu();
    setState(() {
      _profileUidForTab = null;
      index = 3;
    });
  }

  /// Open the profile tab showing another user's profile (not the
  /// logged-in user). Called from the feed/liked/saved/moment-detail
  /// screens when the user taps an avatar or name on a moment card.
  void _openUserProfileTab(String uid) {
    if (uid.trim().isEmpty) return;
    if (menuOpen) _closeMenu();
    setState(() {
      _profileUidForTab = uid.trim();
      index = 3;
    });
  }

  /// Called from ProfileTab when the user taps the back arrow in the
  /// cover image. Clears the foreign-user uid and switches the tab
  /// back to the feed so the next visit to the profile tab shows the
  /// logged-in user's own profile.
  void _closeUserProfile() {
    if (_profileUidForTab == null) return;
    setState(() {
      _profileUidForTab = null;
      index = 0; // back to the feed
    });
  }

  ({Color solid, Color top, Color bottom}) _eventThemeColors(String themeId) {
    switch (themeId) {
      case "pink_nova":
        return (
          solid: const Color(0xFFE85ED5),
          top: const Color(0xFFA86AA0),
          bottom: const Color(0xFF243B68),
        );
      case "violet_dusk":
        return (
          solid: const Color(0xFF8B5CF6),
          top: const Color(0xFF9A84FF),
          bottom: const Color(0xFF2E206D),
        );
      case "ocean_night":
        return (
          solid: const Color(0xFF3298FF),
          top: const Color(0xFF68B7FF),
          bottom: const Color(0xFF153C78),
        );
      case "emerald_night":
        return (
          solid: const Color(0xFF16C784),
          top: const Color(0xFF73E3BF),
          bottom: const Color(0xFF0B4E4B),
        );
      case "sunset_blaze":
        return (
          solid: const Color(0xFFFF6B57),
          top: const Color(0xFFFF9A7A),
          bottom: const Color(0xFF653049),
        );
      case "amber_smoke":
        return (
          solid: const Color(0xFFF0A827),
          top: const Color(0xFFF6CB75),
          bottom: const Color(0xFF6B4722),
        );
      case "berry_wave":
        return (
          solid: const Color(0xFFE95FAF),
          top: const Color(0xFFF29BCE),
          bottom: const Color(0xFF4A245B),
        );
      case "teal_ink":
        return (
          solid: const Color(0xFF21C7C9),
          top: const Color(0xFF75E0DE),
          bottom: const Color(0xFF184C64),
        );
      default:
        return (
          solid: const Color(0xFF16C784),
          top: const Color(0xFF73E3BF),
          bottom: const Color(0xFF0B4E4B),
        );
    }
  }

  Future<void> _openCreateEventScreen() async {
    await _closeMenu();
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _GreenLoaderDialog(),
    );

    await Future.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final result = await Navigator.push<CreateEventResult>(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, animation, __) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            ),
            child: CreateEventScreen(
              draft: _eventDraft,
              onReady: _closeLoader,
            ),
          );
        },
      ),
    );

    _closeLoader();

    if (result == null || !mounted) return;

    final colors = _eventThemeColors(result.themeId);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventHostsScreen(
          eventId: result.eventId,
          eventTitle: result.title,
          themeSolid: colors.solid,
          themeTop: colors.top,
          themeBottom: colors.bottom,
          showCreatedPopup: result.showCreatedPopup,
        ),
      ),
    );

    if (!mounted) return;

    _setIndex(0);

    await WidgetsBinding.instance.endOfFrame;
    await Future.delayed(const Duration(milliseconds: 160));

    final mapState = _mapKey.currentState;
    if (mapState == null) return;

    await mapState.refreshEventMarkersOnly();
    await mapState.focusEventAndOpen(result.eventId);
  }


  Future<void> _toggleMenu() async {
    if (menuOpen) {
      await _ctl.reverse();
      if (!mounted) {
        _closeLoader();
        return;
      }

      setState(() => menuOpen = false);
    } else {
      setState(() => menuOpen = true);
      await _ctl.forward();
    }
  }

  Future<void> _closeMenu() async {
    if (!menuOpen) return;
    await _ctl.reverse();
    if (!mounted) return;
    setState(() => menuOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    // Hard hide means: do not build the nav at all.
    // This prevents the empty white/frosted navbar shell when the keyboard is open.
    final hardHideBottomNav = !menuOpen && keyboardOpen;

    // Scroll hide means: keep the nav built, but slide it down smoothly.
    final slideBottomNav = !menuOpen && (index == 1 || index == 2) && _navHiddenByScroll;
    return PopScope(
      // While we're not on the Map (Discovery) tab, intercept the
      // Android system back button and route the user to the Map tab.
      // Once the user is already on the Map tab, allow the back press
      // to propagate (canPop = true) so the OS closes the app as
      // expected. This matches the standard "back goes home" pattern.
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (index != 0) {
          _setIndex(0);
        }
      },
      child: Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFEFF2F7),
      body: Stack(
        children: [
          IndexedStack(
            index: index,
            children: [
              MapTab(key: _mapKey),
              FeedTab(
                key: _feedKey,
                onOpenUserProfile: _openUserProfileTab,
                onNavVisibilityChanged: _setNavHiddenByScroll,
              ),
              PingmeeChatTab(
                onNavVisibilityChanged: _setNavHiddenByScroll,
              ),
              ProfileTab(
                key: ValueKey("profile-${_profileUidForTab ?? 'me'}"),
                profileUid: _profileUidForTab,
                onBack: _closeUserProfile,
              ),
            ],
          ),


          // Tap outside to close
          if (menuOpen)
            Positioned.fill(
              child: FadeTransition(
                opacity: _fade,
                child: GestureDetector(
                  onTap: _closeMenu,
                  child: Container(color: Colors.black.withOpacity(.10)),
                ),
              ),
            ),


          // if (_openingCreateEvent)
          //   Positioned.fill(
          //     child: IgnorePointer(
          //       child: Container(
          //         color: Colors.black.withOpacity(.10),
          //         child: const Center(
          //           child: SizedBox(
          //             width: 26,
          //             height: 26,
          //             child: CircularProgressIndicator(
          //               strokeWidth: 3,
          //               valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
          //             ),
          //           ),
          //         ),
          //       ),
          //     ),
          //   ),
          // ✅ ONE CLUSTER: bar + plus + popup+stem all in same widget tree
          if (!hardHideBottomNav)
            AnimatedPositioned(
              left: 0,
              right: 0,
              bottom: slideBottomNav ? -118 : 0,
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeInOutCubic,
              child: IgnorePointer(
                ignoring: slideBottomNav,
                child: _BottomNavCluster(
                  index: index,
                  menuOpen: menuOpen,
                  menuOpenAnim: _menuOpen,
                  plusRotateAnim: _plusRotate,
                  fade: _fade,
                  onMap: () => _setIndex(0),
                  onFeed: () {
                    if (index == 1) {
                      // Already on the Moments tab — scroll to the top
                      // instead of rebuilding the tab.
                      _feedKey.currentState?.scrollToTop();
                    } else {
                      _setIndex(1);
                    }
                  },
                  onInbox: () => _setIndex(2),
                  onProfile: _openOwnProfileTab,
                  onToggleMenu: _toggleMenu,
                  onCreatePing: _openCreatePingSheet,
                  onCreateEvent: _openCreateEventScreen,
                  onPostMoment: () async {
                    await _closeMenu();
                    // TODO: push CreatePost
                  },
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

class _BottomNavCluster extends StatelessWidget {
  final int index;
  final bool menuOpen;

  final Animation<double> menuOpenAnim;
  final Animation<double> plusRotateAnim;
  final Animation<double> fade;

  final VoidCallback onMap;
  final VoidCallback onFeed;
  final VoidCallback onInbox;
  final VoidCallback onProfile;

  final VoidCallback onToggleMenu;
  final VoidCallback onCreatePing;
  final VoidCallback onCreateEvent;
  final VoidCallback onPostMoment;

  const _BottomNavCluster({
    required this.index,
    required this.menuOpen,
    required this.menuOpenAnim,
    required this.plusRotateAnim,
    required this.fade,
    required this.onMap,
    required this.onFeed,
    required this.onInbox,
    required this.onProfile,
    required this.onToggleMenu,
    required this.onCreatePing,
    required this.onCreateEvent,
    required this.onPostMoment,
  });

  @override
  Widget build(BuildContext context) {
    const double plusSize = 52;
    const double barHeight = 70;
    const double overflowRoom = 320;

    final double popupAnchor = barHeight - 2;
    final double plusBottom = popupAnchor - (plusSize / 2);

    return SizedBox(
      height: barHeight + overflowRoom,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: Listenable.merge([menuOpenAnim, plusRotateAnim]),
        builder: (context, _) {
          final t = menuOpenAnim.value.clamp(0.0, 1.0);
          final rotateT = plusRotateAnim.value.clamp(0.0, 1.0);
          final popupOpacity = Curves.easeOut.transform(t);
          final popupScale = lerpDouble(0.90, 1.0, Curves.easeOutBack.transform(t))!;
          final popupDy = lerpDouble(12, 0, Curves.easeOutCubic.transform(t))!;
          final plusTopRadius = lerpDouble(26, 8, t)!;
          final plusElevation = lerpDouble(16, 0, t)!;
          final plusShadowOpacity = lerpDouble(0.22, 0.0, t)!;
          final plusScale = lerpDouble(0.96, 1.0, Curves.easeOutCubic.transform(t))!;

          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _FullWidthFrostedBar(
                  index: index,
                  onMap: onMap,
                  onFeed: onFeed,
                  onInbox: onInbox,
                  onProfile: onProfile,
                ),
              ),

              Positioned(
                bottom: popupAnchor,
                child: IgnorePointer(
                  ignoring: t < 0.02,
                  child: Opacity(
                    opacity: popupOpacity,
                    child: Transform.translate(
                      offset: Offset(0, popupDy),
                      child: Transform.scale(
                        scale: popupScale,
                        alignment: Alignment.bottomCenter,
                        child: _PopupWithStem(
                          plusSize: plusSize,
                          openT: t,
                          onCreatePing: onCreatePing,
                          onCreateEvent: onCreateEvent,
                          onPostMoment: onPostMoment,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              Positioned(
                bottom: plusBottom,
                child: Transform.scale(
                  scale: plusScale,
                  alignment: Alignment.bottomCenter,
                  child: Material(
                    color: Colors.transparent,
                    elevation: plusElevation,
                    shadowColor: Colors.black.withOpacity(plusShadowOpacity),
                    borderRadius: BorderRadius.only(
                      bottomLeft: const Radius.circular(26),
                      bottomRight: const Radius.circular(26),
                      topLeft: Radius.circular(plusTopRadius),
                      topRight: Radius.circular(plusTopRadius),
                    ),
                    child: InkWell(
                      onTap: onToggleMenu,
                      borderRadius: BorderRadius.only(
                        bottomLeft: const Radius.circular(26),
                        bottomRight: const Radius.circular(26),
                        topLeft: Radius.circular(plusTopRadius),
                        topRight: Radius.circular(plusTopRadius),
                      ),
                      child: Ink(
                        width: plusSize,
                        height: plusSize,
                        decoration: BoxDecoration(
                          color: AppColors.brandGreen,
                          borderRadius: BorderRadius.only(
                            bottomLeft: const Radius.circular(26),
                            bottomRight: const Radius.circular(26),
                            topLeft: Radius.circular(plusTopRadius),
                            topRight: Radius.circular(plusTopRadius),
                          ),
                        ),
                        child: Center(
                          child: Transform.rotate(
                            angle: (math.pi / 4) * rotateT,
                            child: const _PlusGlyph(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


/// ✅ Full-width bar, icons centered vertically (NO PLUS BUTTON HERE)
class _FullWidthFrostedBar extends StatelessWidget {
  final int index;
  final VoidCallback onMap;
  final VoidCallback onFeed;
  final VoidCallback onInbox;
  final VoidCallback onProfile;

  const _FullWidthFrostedBar({
    required this.index,
    required this.onMap,
    required this.onFeed,
    required this.onInbox,
    required this.onProfile,
  });

  @override
  Widget build(BuildContext context) {
    Widget navSlot({
      required Widget child,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: 78,
            child: Center(child: child),
          ),
        ),
      );
    }

    Widget iconBtn({
      required bool active,
      required IconData icon,
      required VoidCallback onTap,
    }) {
      final activeColor = Colors.black.withOpacity(.84);
      final inactiveColor = Colors.black.withOpacity(.35);

      return navSlot(
        onTap: onTap,
        child: SizedBox(
          height: 78,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 25,
                color: active ? activeColor : inactiveColor,
              ),
              const SizedBox(height: 6),
              const SizedBox(height: 6),
              _NavActiveDot(active: active),
            ],
          ),
        ),
      );
    }

    Widget chatIconBtn({
      required bool active,
      required VoidCallback onTap,
    }) {
      return navSlot(
        onTap: onTap,
        child: SizedBox(
          height: 78,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ChatNavIconWithUnreadDot(active: active),
              const SizedBox(height: 6),
              const SizedBox(height: 6),
              _NavActiveDot(active: active),
            ],
          ),
        ),
      );
    }

    Widget profileBtn({
      required bool active,
      required VoidCallback onTap,
    }) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final activeColor = Colors.black.withOpacity(.84);
      final inactiveColor = Colors.black.withOpacity(.35);

      return navSlot(
        onTap: onTap,
        child: SizedBox(
          height: 78,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              uid == null
                  ? Icon(
                      PhosphorIcons.user(PhosphorIconsStyle.light),
                      size: 25,
                      color: active ? activeColor : inactiveColor,
                    )
                  : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection("users")
                          .doc(uid)
                          .snapshots(),
                      builder: (context, snap) {
                        final data = snap.data?.data() ?? {};
                        final photoUrl = (data["photoUrl"] ?? "").toString().trim();
                        final hasPhoto = photoUrl.isNotEmpty;

                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFF2F4F8),
                            border: Border.all(
                              color: active
                                  ? Colors.black.withOpacity(.72)
                                  : Colors.black.withOpacity(.10),
                              width: active ? 1.8 : 1.4,
                            ),
                            image: hasPhoto
                                ? DecorationImage(
                                    image: NetworkImage(photoUrl),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: !hasPhoto
                              ? Icon(
                                  PhosphorIcons.user(PhosphorIconsStyle.light),
                                  size: 16,
                                  color: active ? activeColor : inactiveColor,
                                )
                              : null,
                        );
                      },
                    ),
              const SizedBox(height: 6),
              const SizedBox(height: 6),
              _NavActiveDot(active: active),    
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(30),
        topRight: Radius.circular(30),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          height: 78,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC).withOpacity(.92),
            border: const Border(
              top: BorderSide(
                color: Color(0xFFD8E1EA),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 26,
                offset: const Offset(0, -8),
                color: Color(0x14000000),
              ),
              BoxShadow(
                blurRadius: 0,
                offset: const Offset(0, -1),
                color: Color(0x66FFFFFF),
              ),
            ],
          ),
          child: Row(
            children: [
              iconBtn(
                active: index == 0,
                icon: PhosphorIcons.compass(PhosphorIconsStyle.light),
                onTap: onMap,
              ),
              iconBtn(
                active: index == 1,
                icon: PhosphorIcons.newspaper(PhosphorIconsStyle.light),
                onTap: onFeed,
              ),

              // center space for floating plus button
              const Expanded(
                child: SizedBox(
                  height: 78,
                ),
              ),

              chatIconBtn(
                active: index == 2,
                onTap: onInbox,
              ),
              profileBtn(
                active: index == 3,
                onTap: onProfile,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopupWithStem extends StatelessWidget {
  final double plusSize;
  final double openT;
  final VoidCallback onCreatePing;
  final VoidCallback onCreateEvent;
  final VoidCallback onPostMoment;

  const _PopupWithStem({
    required this.plusSize,
    required this.openT,
    required this.onCreatePing,
    required this.onCreateEvent,
    required this.onPostMoment,
  });

  @override
  Widget build(BuildContext context) {
    final green = AppColors.brandGreen;

    final cardWidth = lerpDouble(246, 262, openT)!;
    final topPad = lerpDouble(26, 40, openT)!;
    final bottomPad = lerpDouble(22, 34, openT)!;
    final stemWidth = lerpDouble(plusSize - 8, plusSize + 2, openT)!;
    final stemHeight = lerpDouble(28, 38, openT)!;
    final stemOverlap = lerpDouble(4, 8, openT)!;
    final shadowBlur = lerpDouble(18, 30, openT)!;
    final shadowOffsetY = lerpDouble(8, 18, openT)!;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Container(
          width: cardWidth,
          padding: EdgeInsets.fromLTRB(18, topPad, 18, bottomPad),
          decoration: BoxDecoration(
            color: green,
            borderRadius: BorderRadius.circular(42),
            boxShadow: [
              BoxShadow(
                blurRadius: shadowBlur,
                offset: Offset(0, shadowOffsetY),
                color: Colors.black.withOpacity(.18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StaggeredMenuLine(
                openT: openT,
                index: 0,
                title: "Create Ping",
                icon: PhosphorIcons.mapPin(PhosphorIconsStyle.light),
                onTap: onCreatePing,
              ),
              const SizedBox(height: 12),
              _StaggeredMenuLine(
                openT: openT,
                index: 1,
                title: "Create Event",
                icon: PhosphorIcons.calendarDots(PhosphorIconsStyle.light),
                onTap: onCreateEvent,
              ),
              const SizedBox(height: 12),
              _StaggeredMenuLine(
                openT: openT,
                index: 2,
                title: "Create Task",
                icon: PhosphorIcons.listChecks(PhosphorIconsStyle.light),
                onTap: onPostMoment,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),

        Positioned(
          bottom: -stemOverlap,
          child: Container(
            width: stemWidth,
            height: stemHeight,
            decoration: BoxDecoration(
              color: green,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(26),
                bottomRight: Radius.circular(26),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StaggeredMenuLine extends StatelessWidget {
  final double openT;
  final int index;
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _StaggeredMenuLine({
    required this.openT,
    required this.index,
    required this.title,
    required this.icon,
    required this.onTap,
  });

  static double _itemT(double t, int index) {
    const stagger = 0.065;
    final start = index * stagger;
    if (t <= start) return 0;
    return Curves.easeOutCubic.transform(
      ((t - start) / (1 - start)).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemT = _itemT(openT, index);
    return Opacity(
      opacity: itemT,
      child: Transform.translate(
        offset: Offset(0, lerpDouble(8, 0, itemT)!),
        child: _CleanLine(
          title: title,
          icon: icon,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// ✅ tighter spacing + no fontWeight
class _CleanLine extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _CleanLine({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final green = AppColors.brandGreen;

    // ✅ subtle contrast inside the blob
    final pillBg = Color.lerp(green, Colors.white, 0.10)!;   // slightly lighter
    final iconBg = Color.lerp(green, Colors.black, 0.18)!;   // slightly darker
    final iconColor = Colors.white.withOpacity(.90);
    final textColor = Colors.white.withOpacity(.92);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6), // space between rows
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: Colors.white.withOpacity(.10),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                // ✅ icon capsule
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Center(
                    child: Icon(
                      icon,
                      size: 20,
                      color: iconColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 16.5,
                      color: textColor,
                      fontWeight: FontWeight.w600, // clearer CTA
                    ),
                  ),
                ),

                // ✅ subtle chevron so it feels tappable
                Icon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                  size: 18,
                  color: Colors.white.withOpacity(.55),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _StubPage extends StatelessWidget {
  final String title;
  const _StubPage({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 24,
          fontWeight: FontWeight.w900,
          color: Colors.black87,
        ),
      ),
    );
  }
}

class _PlusGlyph extends StatelessWidget {
  const _PlusGlyph();

  @override
  Widget build(BuildContext context) {
    return Icon(
      PhosphorIcons.plus(PhosphorIconsStyle.bold),
      size: 28,
      color: Colors.white,
    );
  }
}

class _NavActiveDot extends StatelessWidget {
  final bool active;
  const _NavActiveDot({required this.active});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 8,
      height: 8,
      child: Center(
        child: AnimatedScale(
          scale: active ? 1 : 0.65,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatNavIconWithUnreadDot extends StatefulWidget {
  const _ChatNavIconWithUnreadDot({
    required this.active,
  });

  final bool active;

  @override
  State<_ChatNavIconWithUnreadDot> createState() =>
      _ChatNavIconWithUnreadDotState();
}

class _ChatNavIconWithUnreadDotState extends State<_ChatNavIconWithUnreadDot> {
  late Future<StreamChatClient?> _clientFuture;
  StreamController<int>? _unreadController;
  StreamSubscription<Map<String, Channel>>? _channelsStreamSub;
  final Map<String, StreamSubscription<int>> _channelUnreadSubs = {};
  StreamChatClient? _client;
  final Set<String> _archivedCids = {};
  StreamSubscription? _archivedPrefsSub;

  int _computeTotal(Map<String, Channel> channels, {bool excludeArchived = true}) {
    final currentUserId = _client?.state.currentUser?.id;
    int total = 0;
    for (final channel in channels.values) {
      final state = channel.state;
      if (state == null) continue;
      if (state.unreadCount <= 0) continue;

      final cid = channel.cid ?? '';
      if (!cid.startsWith('messaging:')) continue;

      // Skip archived channels
      if (excludeArchived && _archivedCids.contains(cid)) continue;

      if (currentUserId != null &&
          state.members.isNotEmpty &&
          !state.members.any((m) => m.userId == currentUserId)) {
        continue;
      }

      total += state.unreadCount;
    }
    return total;
  }

  void _syncChannelListeners(Map<String, Channel> channels) {
    final currentCids = channels.keys.toSet();

    for (final cid in <String>{..._channelUnreadSubs.keys}) {
      if (!currentCids.contains(cid)) {
        _channelUnreadSubs[cid]?.cancel();
        _channelUnreadSubs.remove(cid);
      }
    }

    for (final cid in currentCids) {
      if (_channelUnreadSubs.containsKey(cid)) continue;
      final channel = channels[cid];
      final unreadStream = channel?.state?.unreadCountStream;
      if (unreadStream == null) continue;
      _channelUnreadSubs[cid] = unreadStream.listen((_) {
        _emitTotal();
      });
    }

    _emitTotal();
  }

  void _emitTotal() {
    if (!mounted || _unreadController == null || _unreadController!.isClosed) {
      return;
    }
    _unreadController!.add(_computeTotal(_client?.state.channels ?? {}));
  }

  @override
  void initState() {
    super.initState();
    _clientFuture = _loadClient();
  }

  Future<StreamChatClient?> _loadClient() async {
    try {
      final client = await PingmeeStreamChatService.instance.connectCurrentUser();
      if (mounted) {
        _client = client;
        _unreadController = StreamController<int>.broadcast();

        _channelsStreamSub = client.state.channelsStream.listen((channels) {
          _syncChannelListeners(channels);
        });

        _syncChannelListeners(client.state.channels);

        // Listen to Firestore to track which channels are archived
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          _archivedPrefsSub = FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('chatPrefs')
              .where('archived', isEqualTo: true)
              .snapshots()
              .listen((snap) {
            if (!mounted) return;
            final archived = <String>{};
            for (final doc in snap.docs) {
              final docId = Uri.decodeComponent(doc.id);
              archived.add(docId);
            }
            setState(() {
              _archivedCids.clear();
              _archivedCids.addAll(archived);
            });
            _emitTotal();
          });
        }
      }
      return client;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _channelsStreamSub?.cancel();
    _unreadController?.close();
    _channelUnreadSubs.values.forEach((s) => s.cancel());
    _channelUnreadSubs.clear();
    _archivedPrefsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = Colors.black.withOpacity(.84);
    final inactiveColor = Colors.black.withOpacity(.35);

    Widget iconWithDot({required bool showDot}) {
      return SizedBox(
        width: 34,
        height: 30,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(
              PhosphorIcons.chatCircle(PhosphorIconsStyle.light),
              size: 25,
              color: widget.active ? activeColor : inactiveColor,
            ),

            if (showDot)
              Positioned(
                top: 0,
                right: 4,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFF8FAFC),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                        color: const Color(0xFFEF4444).withOpacity(.32),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return FutureBuilder<StreamChatClient?>(
      future: _clientFuture,
      builder: (context, snap) {
        final client = snap.data;

        if (client == null) {
          return iconWithDot(showDot: false);
        }

        if (_unreadController == null) {
          return iconWithDot(showDot: false);
        }

        return StreamBuilder<int>(
          stream: _unreadController!.stream,
          initialData: _computeTotal(client.state.channels),
          builder: (context, unreadSnap) {
            final unreadCount = unreadSnap.data ?? 0;

            return iconWithDot(
              showDot: unreadCount > 0,
            );
          },
        );
      },
    );
  }
}

class ProfileTabTemp extends StatelessWidget {
  const ProfileTabTemp({super.key});

  static const double _navBarHeight = 78; // matches your frosted bar height

  Future<void> _logout(BuildContext context) async {
    await PingmeeStreamChatService.instance.disconnect();
    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppStartRouter()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, _navBarHeight + 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                "Profile — temp",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 12),

              const Spacer(),

              ElevatedButton.icon(
                onPressed: () => _logout(context),
                icon: const Icon(Icons.logout_rounded, color: Colors.white),
                label: const Text(
                  "Log out",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _TopSearchPill extends StatelessWidget {
  final VoidCallback onTap;
  const _TopSearchPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.74),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(.55)),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
                    size: 18,
                    color: Colors.black.withOpacity(.55),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Search pings, events, people…",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(.55),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen.withOpacity(.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      "Live",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.brandGreen,
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


class _NearbyPingsPreview extends StatelessWidget {
  final VoidCallback onOpen;
  final void Function(String title) onOpenPing;

  const _NearbyPingsPreview({
    required this.onOpen,
    required this.onOpenPing,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(26),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.78),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: Colors.white.withOpacity(.55)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 26,
                    offset: const Offset(0, 18),
                    color: Colors.black.withOpacity(.10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        "Nearby Pings",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withOpacity(.82),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        PhosphorIcons.caretUp(PhosphorIconsStyle.light),
                        size: 18,
                        color: Colors.black.withOpacity(.45),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _PingCardPreview(
                    title: "FIFA at Top Floor",
                    subtitle: "2 mins away • 6 people vibing",
                    onTap: () => onOpenPing("FIFA at Top Floor"),
                  ),
                  const SizedBox(height: 10),
                  _PingCardPreview(
                    title: "Study Group — Calculus",
                    subtitle: "On campus • 3 people waiting",
                    onTap: () => onOpenPing("Study Group — Calculus"),
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


class _PingCardPreview extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PingCardPreview({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F6FB),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.black.withOpacity(.05)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen.withOpacity(.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  PhosphorIcons.mapPin(PhosphorIconsStyle.light),
                  color: AppColors.brandGreen,
                  size: 18,
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
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        color: Colors.black.withOpacity(.55),
                      ),
                    ),
                  ],
                ),
              ),
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

class _GlassSheet extends StatelessWidget {
  final Widget child;
  const _GlassSheet({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(.55)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final String text;
  const _QuickChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6FB),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withOpacity(.05)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}


class _MapVibeBackground extends StatelessWidget {
  const _MapVibeBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.2, -0.4),
          radius: 1.2,
          colors: [
            Color(0xFFFFFFFF),
            Color(0xFFEFF2F7),
          ],
        ),
      ),
      child: CustomPaint(
        painter: _DotGridPainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(.045);
    const gap = 26.0;
    const r = 1.2;

    for (double y = 0; y < size.height; y += gap) {
      for (double x = 0; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }

    final glow = Paint()
      ..color = AppColors.brandGreen.withOpacity(.10)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);

    canvas.drawCircle(Offset(size.width * .65, size.height * .35), 90, glow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GreenLoaderDialog extends StatelessWidget {
  const _GreenLoaderDialog();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
        ),
      ),
    );
  }
}



