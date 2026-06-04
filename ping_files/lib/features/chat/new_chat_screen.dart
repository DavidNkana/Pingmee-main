import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'package:ping_files/features/chat/pingmee_chat_routes.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:ping_files/features/chat/message_request_router.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _opening = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _nameFrom(Map<String, dynamic> data) {
    final fullName = (data['fullName'] ?? '').toString().trim();
    final displayName = (data['displayName'] ?? '').toString().trim();
    final name = (data['name'] ?? '').toString().trim();

    final firstName = (data['firstName'] ?? '').toString().trim();
    final lastName = (data['lastName'] ?? '').toString().trim();
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

  String _subtitleFrom(Map<String, dynamic> data) {
    final headline = (data['headline'] ?? '').toString().trim();
    final bio = (data['bio'] ?? '').toString().trim();

    if (headline.isNotEmpty) return headline;
    if (bio.isNotEmpty) return bio;
    return 'Tap to start chat';
  }

  bool _matchesQuery(Map<String, dynamic> data) {
    if (_query.isEmpty) return true;

    final name = _nameFrom(data).toLowerCase();
    final username = (data['username'] ?? '').toString().toLowerCase();
    final headline = (data['headline'] ?? '').toString().toLowerCase();
    final bio = (data['bio'] ?? '').toString().toLowerCase();

    return name.contains(_query) ||
        username.contains(_query) ||
        headline.contains(_query) ||
        bio.contains(_query);
  }

  Future<void> _openChat(String otherUid) async {
    if (_opening) return;

    setState(() => _opening = true);

    try {
      final channel = await PingmeeMessageRequestRouter.openDirectChat(
        otherUid: otherUid,
      );

      if (!mounted) return;

      Navigator.of(context).pop();
      Navigator.of(context).push(
        pingmeeChatRoute(channel),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not start chat: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = fb.FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
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
                          size: 21,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'New chat',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: TextField(
                controller: _search,
                onChanged: (value) {
                  setState(() {
                    _query = value.trim().toLowerCase();
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Search people',
                  prefixIcon: Icon(
                    PhosphorIcons.magnifyingGlass(
                      PhosphorIconsStyle.light,
                    ),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                ),
              ),
            ),

            if (_opening)
              const LinearProgressIndicator(
                minHeight: 2,
                valueColor: AlwaysStoppedAnimation(AppColors.brandGreen),
              ),

            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .limit(50)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor:
                            AlwaysStoppedAnimation(AppColors.brandGreen),
                      ),
                    );
                  }

                  final docs = snap.data?.docs ?? [];

                  final people = docs.where((doc) {
                    if (doc.id == myUid) return false;
                    return _matchesQuery(doc.data());
                  }).toList();

                  if (people.isEmpty) {
                    return const Center(
                      child: Text(
                        'No people found',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 26),
                    itemCount: people.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final doc = people[index];
                      final data = doc.data();

                      final name = _nameFrom(data);
                      final subtitle = _subtitleFrom(data);
                      final photoUrl =
                          (data['photoUrl'] ?? data['photoURL'] ?? '')
                              .toString()
                              .trim();

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          onTap: () => _openChat(doc.id),
                          borderRadius: BorderRadius.circular(22),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      AppColors.brandGreen.withOpacity(.12),
                                  backgroundImage: photoUrl.isEmpty
                                      ? null
                                      : NetworkImage(photoUrl),
                                  child: photoUrl.isEmpty
                                      ? Icon(
                                          PhosphorIcons.user(
                                            PhosphorIconsStyle.light,
                                          ),
                                          color: AppColors.brandGreen,
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
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Nunito',
                                          fontSize: 15.5,
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
                                          fontSize: 13,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.black.withOpacity(.50),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  PhosphorIcons.chatCircle(
                                    PhosphorIconsStyle.light,
                                  ),
                                  color: Colors.black.withOpacity(.35),
                                ),
                              ],
                            ),
                          ),
                        ),
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
  }
}