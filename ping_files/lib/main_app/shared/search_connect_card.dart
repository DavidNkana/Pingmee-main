// ============================================================================
// SearchConnectCard
// ============================================================================
//
// Vertical "follow / connect" card used in two places:
//
//   1. The search screen's "People you may want to ping" carousel.
//   2. The feed tab's inline people suggestion (mid-stream, after
//      the 10th moment).
//
// Same widget, same wire flow, no drift. Cloning once and reusing
// from a shared file is the only way to keep both surfaces in sync
// as the design evolves.
//
// Visual: no border, no rounded box — just a soft white tile
// (pure white in light mode, 0xFF161B22 in dark) with 14-px
// corners. Big circular avatar (84x84) centred horizontally with
// a verified badge anchored to the bottom-left (Stack + Clip.none).
// Tiny x dismiss button in the top-right. Full name (13.8pt w600)
// + username (11.6pt w400 grey) below. Solid black pill connect
// button (no border, no icon, 10-px radius) with white text.
//
// Connect flow uses the SAME FriendStateManager that the profile
// screen uses — no new wire format. FriendStateManager.sendFriendRequest
// does the canonical transaction (friend_requests_in / out docs +
// type:connection_request notification) and the optimistic UI
// override. Already-friends users see "Connected" with no tap
// action; users who have sent us a request see "Respond" which
// opens their profile.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/main_app/tabs/profile/profile_tab.dart'
    show FriendStateManager, FriendButtonState;
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/features/search/search_service.dart'
    show SearchResult;

class SearchConnectCard extends StatelessWidget {
  final SearchResult result;
  final void Function(String uid) onOpenProfile;
  final VoidCallback onDismiss;
  final bool isFriend;
  final FriendStateManager manager;
  /// Optional callback fired after a successful connect request.
  /// Lets the parent (search sheet, feed) call setState() so the
  /// button label updates immediately without each card needing a
  /// reference to the parent's State. Required because the widget
  /// lives in a shared file and cannot reach private State classes
  /// of the screens that embed it.
  final VoidCallback? onConnectSent;

  const SearchConnectCard({
    required this.result,
    required this.onOpenProfile,
    required this.onDismiss,
    required this.isFriend,
    required this.manager,
    this.onConnectSent,
  });

  @override
  Widget build(BuildContext context) {
    final d = result.data;
    final fullName =
        (d["fullName"] ?? "Pingmee user").toString().trim();
    final username = (d["username"] ?? "").toString().trim();
    final photoUrl = (d["photoUrl"] ?? "").toString().trim();
    final verification =
        Map<String, dynamic>.from(d["verification"] ?? const {});
    final isVerified = verification["status"] == "verified";

    // Connect button state. The FriendStateManager owns the
    // optimistic override; we also pre-hide the button if the
    // viewer is already friends with this person.
    final btnState =
        isFriend ? FriendButtonState.friends : manager.currentState;
    final showAsSent = btnState == FriendButtonState.outgoing ||
        btnState == FriendButtonState.incoming;

    // Match the chip's "surface" color so the card reads as part of
    // the same surface family as the skills/interests pills above
    // it: pure white in light mode, 0xFF161B22 in dark mode. The
    // parent screen's bg is 0xFFF4F6F8 in light, so a pure-white
    // card pops out cleanly. Subtle 14-px corner radius so the card
    // feels like a soft tile, not a chip.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? const Color(0xFF161B22)
        : Colors.white;

    return SizedBox(
      width: 168,
      child: Padding(
        // 0 px on the bottom — the connect button hugs the
        // card's bottom edge. The card's "much padding"
        // (per the v47 design pass) lives BETWEEN the
        // username and the button (18-px SizedBox below),
        // not below the button. This way the carousel
        // SizedBox can be sized to the card's exact content
        // height and the button sits flush with the
        // carousel's bottom edge.
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
          ),
          // 0 px on the bottom — the connect button hugs the
          // card's bottom edge. The card's real padding is
          // the 18-px SizedBox between the username and the
          // button (below).
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
            // Top row: x dismiss (top-right). 18 px
            // (was 22) — the dismiss icon is only 14 px
            // tall with 2-px padding (so 18 total), so
            // the SizedBox was just extra whitespace.
            SizedBox(
              height: 18,
              child: Align(
                alignment: Alignment.centerRight,
                child: InkResponse(
                  onTap: onDismiss,
                  radius: 14,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Avatar with verified badge anchored to the bottom-left
            // of the circle. Stack(clipBehavior: Clip.none) lets
            // the badge sit half outside the circle without being
            // clipped.
            GestureDetector(
              onTap: () => onOpenProfile(result.id),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFE5E7EB),
                    ),
                    child: ClipOval(
                      child: photoUrl.isEmpty
                          ? Center(
                              child: Text(
                                fullName.isNotEmpty
                                    ? fullName[0].toUpperCase()
                                    : "?",
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF374151),
                                ),
                              ),
                            )
                          : Image.network(
                              photoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Center(
                                child: Text(
                                  fullName.isNotEmpty
                                      ? fullName[0].toUpperCase()
                                      : "?",
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 30,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                  if (isVerified)
                    Positioned(
                      left: -2,
                      bottom: -2,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.verified_rounded,
                          size: 18,
                          color: Color(0xFF1D9BF0),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // 8 px (was 10) to keep the card compact.
            const SizedBox(height: 8),
            // Name — bold, single-line ellipsis. Lighter weight so it
            // doesn't compete with the avatar for visual focus; the
            // avatar is the primary element on the card.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                fullName.isNotEmpty ? fullName : "Pingmee user",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 13.8,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
              ),
            ),
            // No SizedBox between name and username; the
            // line-height difference gives a natural
            // visual gap. Saves 2 px in the column.
            // Username — even lighter (regular), still smaller grey.
            if (username.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  "@$username",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 11.6,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            // 12 px between the username and the connect
            // button — the card's breathing room. The
            // bottom of the card has 0 padding so the
            // button hugs the card edge; the breath
            // lives here. 12 px (was 18 in v47) keeps the
            // card under 209 px tall so the carousel's
            // SizedBox (231 px in feed/search) never
            // overflows the Column.
            const SizedBox(height: 12),
            // Connect / Request sent / Already-friends button. The
            // button is disabled while the manager is busy with a
            // network call (optimistic override is in flight).
            SizedBox(
              height: 36,
              width: double.infinity,
              child: btnState == FriendButtonState.friends
                  ? _connectButtonShell(
                      label: "Connected",
                      icon: Icons.check_rounded,
                      filled: false,
                      isBusy: false,
                      onTap: null,
                    )
                  : btnState == FriendButtonState.incoming
                      ? _connectButtonShell(
                          label: "Respond",
                          icon: Icons.person_add_alt_1_rounded,
                          filled: false,
                          isBusy: false,
                          onTap: () => onOpenProfile(result.id),
                        )
                      : showAsSent
                          ? _connectButtonShell(
                              label: manager.isBusy
                                  ? "Sending…"
                                  : "Request sent",
                              icon: Icons.check_rounded,
                              filled: false,
                              isBusy: manager.isBusy,
                              onTap: null,
                            )
                          : _connectButtonShell(
                              label: "Connect",
                              icon: Icons.person_add_alt_rounded,
                              filled: true,
                              isBusy: manager.isBusy,
                              onTap: manager.isBusy
                                  ? null
                                  : () async {
                                      // Resolve the viewer's
                                      // display name + username
                                      // so the notification body
                                      // matches what the profile
                                      // screen sends.
                                      final me =
                                          FirebaseAuth.instance.currentUser;
                                      if (me == null) return;
                                      final meSnap =
                                          await FirebaseFirestore.instance
                                              .collection("users")
                                              .doc(me.uid)
                                              .get();
                                      final meData = meSnap.data() ??
                                          const <String, dynamic>{};
                                      final meName = (meData["fullName"] ??
                                              me.displayName ??
                                              me.email ??
                                              "Someone")
                                          .toString()
                                          .trim();
                                      final meUsername =
                                          (meData["username"] ?? "")
                                              .toString()
                                              .trim();
                                      final ok =
                                          await manager.sendFriendRequest(
                                        meName,
                                        meUsername,
                                      );
                                      if (ok) {
                                        // Mirror the optimistic
                                        // success: the manager has
                                        // already flipped the state,
                                        // but we notify the parent
                                        // so the button label updates
                                        // without waiting for the
                                        // next rebuild. Each
                                        // embedder (search sheet,
                                        // feed) passes its own
                                        // setState here.
                                        onConnectSent?.call();
                                      }
                                    },
                            ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  // Helper: a small solid black pill with white text, no border,
  // no leading icon. Same look for every state (Connect, Sending…,
  // Request sent, Respond, Connected) — only the label and the tap
  // handler change, so the eye reads the action as one button
  // family, not five. Radius 10 px (down from a pill) so it sits
  // more like a label button than a tag. Vertical padding 6/6
  // (was 0/0 inside a 30-px SizedBox) for a slightly taller, more
  // tappable pill.
  Widget _connectButtonShell({
    required String label,
    required IconData icon, // kept for API parity; not rendered.
    required bool filled,  // kept for API parity; not used (all black).
    required bool isBusy,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isBusy) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.2,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
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
