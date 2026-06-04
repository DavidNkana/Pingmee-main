import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/components/profile_progress_bar.dart';
import 'package:ping_files/main_app/communities/create/community_final_review_screen.dart';
import 'package:ping_files/main_app/communities/create/create_community_draft.dart';
import 'package:ping_files/theme/colors2.dart';


class CommunitySettingsScreen extends StatefulWidget {
  const CommunitySettingsScreen({
    super.key,
    required this.draft,
    this.nextScreenBuilder,
  });

  final CreateCommunityDraft draft;
  final Widget Function(CreateCommunityDraft draft)? nextScreenBuilder;

  @override
  State<CommunitySettingsScreen> createState() =>
      _CommunitySettingsScreenState();
}

class _CommunitySettingsScreenState extends State<CommunitySettingsScreen> {
  bool saving = false;
  String? pressedCategory;

  late double _radiusKm;
  late String _selectedCategory;
  late String _hoursMode;
  late Map<String, List<_HourRange>> _hoursByDay;

  late ScaffoldMessengerState _messenger;

  final TextEditingController _friendSearchCtrl = TextEditingController();
  String _friendSearch = "";

  final Set<String> _busyInviteIds = <String>{};
  final Set<String> _sentInviteIds = <String>{};

  static const int minKm = 1;
  static const int maxKm = 500;

  static const List<String> _days = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
  ];

  static const Map<String, String> _dayLabel = {
    "monday": "Monday",
    "tuesday": "Tuesday",
    "wednesday": "Wednesday",
    "thursday": "Thursday",
    "friday": "Friday",
    "saturday": "Saturday",
    "sunday": "Sunday",
  };

  final List<Map<String, dynamic>> categories = [
    {
      "label": "Club",
      "icon": PhosphorIconsRegular.usersThree,
    },
    {
      "label": "Business",
      "icon": PhosphorIconsRegular.storefront,
    },
    {
      "label": "Campus",
      "icon": PhosphorIconsRegular.graduationCap,
    },
    {
      "label": "Creator Hub",
      "icon": PhosphorIconsRegular.microphoneStage,
    },
    {
      "label": "Cause",
      "icon": PhosphorIconsRegular.heart,
    },
    {
      "label": "Local Group",
      "icon": PhosphorIconsRegular.mapPinArea,
    },
  ];
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void initState() {
    super.initState();

    _radiusKm = widget.draft.discoveryRadiusKm.clamp(
      minKm.toDouble(),
      maxKm.toDouble(),
    );

    _selectedCategory = widget.draft.communityCategory.trim();
    _hoursMode = widget.draft.hoursMode.trim().isEmpty
        ? "none"
        : widget.draft.hoursMode.trim();

    _hoursByDay = {
      for (final day in _days)
        day: _deserializeRanges(widget.draft.selectedHours[day] ?? const []),
    };

    _sentInviteIds.addAll(widget.draft.invitedFriendIds);

    _friendSearchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _friendSearch = _friendSearchCtrl.text.trim().toLowerCase();
      });
    });

    _pageScrollCtrl.addListener(_onPageScroll);

    if (FirebaseAuth.instance.currentUser != null) {
      _loadInitialFriends();
    }
  }

  @override
  void dispose() {
    _friendSearchCtrl.dispose();
    _pageScrollCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    _messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

    static const int _friendsPageSize = 30;

    final ScrollController _pageScrollCtrl = ScrollController();
    final List<_FriendInviteItem> _friendItems = <_FriendInviteItem>[];

    DocumentSnapshot<Map<String, dynamic>>? _lastFriendDoc;

    bool _friendsInitialLoading = false;
    bool _friendsMoreLoading = false;
    bool _friendsHasMore = true;
    bool _friendsLoadedOnce = false;
    String? _friendsLoadError;

  String _radiusVibe(int km) {
    if (km <= 3) return "Ultra local";
    if (km <= 10) return "Nearby";
    if (km <= 25) return "City-wide";
    if (km <= 80) return "Regional";
    if (km <= 180) return "Wide reach";
    return "Explorer";
  }

  String _categoryKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _normalizeCategory(String input) {
    final collapsed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return '';

    final words = collapsed.split(' ');
    return words.map((word) {
      if (word.isEmpty) return word;
      final lower = word.toLowerCase();
      if (word.length == 1) return lower.toUpperCase();
      return lower[0].toUpperCase() + lower.substring(1);
    }).join(' ');
  }

  String? _validateCustomCategory(String raw) {
    final value = _normalizeCategory(raw);

    if (value.isEmpty) {
      return "Enter a category first.";
    }
    if (value.length < 2) {
      return "That’s too short to be a real category.";
    }
    if (value.length > 24) {
      return "Keep it short. 24 characters max.";
    }
    if (value.split(' ').where((e) => e.trim().isNotEmpty).length > 3) {
      return "Use a short category, not a sentence.";
    }
    if (!RegExp(r"^[A-Za-z0-9][A-Za-z0-9\s&+\-'/]*$").hasMatch(value)) {
      return "Use real words only. No weird symbols.";
    }

    return null;
  }

  void _onPageScroll() {
    if (!_pageScrollCtrl.hasClients) return;

    final position = _pageScrollCtrl.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      _loadMoreFriends();
    }
  }

  Future<void> _loadInitialFriends() async {
    _lastFriendDoc = null;
    _friendsHasMore = true;
    _friendsLoadedOnce = false;
    _friendsLoadError = null;
    _friendItems.clear();

    await _loadMoreFriends(reset: true);
  }

  Future<void> _loadMoreFriends({bool reset = false}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    if (_friendsInitialLoading || _friendsMoreLoading) return;
    if (!reset && !_friendsHasMore) return;

    if (mounted) {
      setState(() {
        if (reset) {
          _friendsInitialLoading = true;
          _friendsLoadError = null;
        } else {
          _friendsMoreLoading = true;
        }
      });
    }

    try {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .collection("friends")
          .orderBy(FieldPath.documentId)
          .limit(_friendsPageSize);

      if (!reset && _lastFriendDoc != null) {
        query = query.startAfterDocument(_lastFriendDoc!);
      }

      final snap = await query.get();
      final friendDocs = snap.docs;

      final friendIds = friendDocs
          .map((doc) {
            final data = doc.data();
            final raw = (data["friendId"] ?? "").toString().trim();
            return raw.isNotEmpty ? raw : doc.id;
          })
          .where((id) => id.isNotEmpty)
          .toList();

      final usersById = await _fetchUsersByIds(friendIds);
      if (!mounted) return;

      final existingIds = reset
          ? <String>{}
          : _friendItems.map((e) => e.uid).toSet();

      final newItems = <_FriendInviteItem>[];

      for (final friendId in friendIds) {
        if (existingIds.contains(friendId)) continue;

        final user = usersById[friendId];
        if (user == null) continue;

        newItems.add(
          _FriendInviteItem(
            uid: friendId,
            name: (user["fullName"] ?? "Friend").toString(),
            username: (user["username"] ?? "").toString(),
            photoUrl: (user["photoUrl"] ?? "").toString(),
          ),
        );
      }

      setState(() {
        if (reset) {
          _friendItems
            ..clear()
            ..addAll(newItems);
        } else {
          _friendItems.addAll(newItems);
        }

        _lastFriendDoc = friendDocs.isNotEmpty ? friendDocs.last : _lastFriendDoc;
        _friendsHasMore = friendDocs.length == _friendsPageSize;
        _friendsLoadedOnce = true;
        _friendsLoadError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _friendsLoadError = "Couldn’t load friends right now.";
        _friendsLoadedOnce = true;
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _friendsInitialLoading = false;
        _friendsMoreLoading = false;
      });
    }
  }

  Future<Map<String, Map<String, dynamic>>> _fetchUsersByIds(
    List<String> ids,
  ) async {
    final result = <String, Map<String, dynamic>>{};
    if (ids.isEmpty) return result;

    const int batchSize = 10;

    for (int i = 0; i < ids.length; i += batchSize) {
      final end = (i + batchSize > ids.length) ? ids.length : i + batchSize;
      final batch = ids.sublist(i, end);

      final snap = await FirebaseFirestore.instance
          .collection("users")
          .where(FieldPath.documentId, whereIn: batch)
          .get();

      for (final doc in snap.docs) {
        result[doc.id] = doc.data();
      }
    }

    return result;
  }

  List<_FriendInviteItem> get _visibleFriendItems {
    if (_friendSearch.isEmpty) return _friendItems;

    return _friendItems.where((friend) {
      final haystack =
          "${friend.name} ${friend.username}".toLowerCase().trim();
      return haystack.contains(_friendSearch);
    }).toList();
  }

  Future<void> _openCustomCategorySheet() async {
    final controller = TextEditingController();
    String? errorText;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  16,
                  24,
                  MediaQuery.of(context).viewInsets.bottom + 20,
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
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.brandGreen.withOpacity(.12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            PhosphorIconsBold.plus,
                            color: AppColors.brandGreen,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            "Add custom category",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              fontFamily: "Nunito",
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(PhosphorIconsBold.x),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(24),
                      ],
                      decoration: InputDecoration(
                        hintText: "e.g. Nonprofit, Church, Dance Crew",
                        errorText: errorText,
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(
                            color: AppColors.brandGreen,
                            width: 1.2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                      ),
                      onChanged: (_) {
                        if (errorText != null) {
                          setModalState(() => errorText = null);
                        }
                      },
                      onSubmitted: (_) {
                        final validationError =
                            _validateCustomCategory(controller.text);

                        if (validationError != null) {
                          setModalState(() => errorText = validationError);
                          return;
                        }

                        setState(() {
                          _selectedCategory =
                              _normalizeCategory(controller.text);
                        });

                        try {
                          HapticFeedback.selectionClick();
                        } catch (_) {}

                        Navigator.pop(context);
                      },
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Keep it short and real. This becomes the public category for the community.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.grey.shade600,
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          final validationError =
                              _validateCustomCategory(controller.text);

                          if (validationError != null) {
                            setModalState(() => errorText = validationError);
                            return;
                          }

                          setState(() {
                            _selectedCategory =
                                _normalizeCategory(controller.text);
                          });

                          try {
                            HapticFeedback.selectionClick();
                          } catch (_) {}

                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          "Add category",
                          style: TextStyle(
                            fontSize: 15,
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
            );
          },
        );
      },
    );
  }

  List<_HourRange> _deserializeRanges(List<Map<String, String>> raw) {
    return raw.map((item) {
      return _HourRange(
        open: _timeFromStorage(item["open"]),
        close: _timeFromStorage(item["close"]),
      );
    }).toList();
  }

  Map<String, List<Map<String, String>>> _serializeHours() {
    final result = <String, List<Map<String, String>>>{};

    for (final day in _days) {
      final rows = _hoursByDay[day] ?? <_HourRange>[];
      final complete = rows
          .where((row) => row.open != null && row.close != null)
          .map((row) => {
                "open": _timeToStorage(row.open!),
                "close": _timeToStorage(row.close!),
              })
          .toList();

      if (complete.isNotEmpty) {
        result[day] = complete;
      }
    }

    return result;
  }

  bool get _hasAnyCompleteSelectedHours {
    for (final rows in _hoursByDay.values) {
      for (final row in rows) {
        if (row.open != null && row.close != null) {
          return true;
        }
      }
    }
    return false;
  }

  String _hoursSummaryText() {
    switch (_hoursMode) {
      case "always_open":
        return "Open 24 hours every day";
      case "selected":
        if (!_hasAnyCompleteSelectedHours) return "No hours selected yet";
        final activeDays = _serializeHours().length;
        if (activeDays == 1) return "Hours set for 1 day";
        return "Hours set for $activeDays days";
      case "none":
      default:
        return "No hours shown";
    }
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay? initial) {
    return showTimePicker(
      context: context,
      initialTime: initial ?? const TimeOfDay(hour: 9, minute: 0),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.brandGreen,
                ),
          ),
          child: child!,
        );
      },
    );
  }

  Future<void> _openHoursSheet() async {
    final working = <String, List<_HourRange>>{
      for (final day in _days)
        day: (_hoursByDay[day] ?? <_HourRange>[])
            .map((e) => e.copy())
            .toList(),
    };

    for (final day in _days) {
      if (working[day]!.isEmpty) {
        working[day]!.add(_HourRange());
      }
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * .88,
              decoration: const BoxDecoration(
                color: Color(0xFFF8FAF8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
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
                      padding: const EdgeInsets.fromLTRB(16, 0, 10, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Selected hours",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                                color: Colors.black87,
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
                    Divider(
                      height: 1,
                      color: Colors.grey.shade200,
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                        itemCount: _days.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 16),
                        itemBuilder: (context, dayIndex) {
                          final day = _days[dayIndex];
                          final rows = working[day]!;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _dayLabel[day]!,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 10),
                              ...List.generate(rows.length, (rowIndex) {
                                final row = rows[rowIndex];

                                return Padding(
                                  padding: EdgeInsets.only(
                                    bottom: rowIndex == rows.length - 1 ? 0 : 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _HourFieldButton(
                                          label: row.open == null
                                              ? "Opening"
                                              : _timeForDisplay(context, row.open!),
                                          onTap: () async {
                                            final picked =
                                                await _pickTime(row.open);
                                            if (picked == null) return;
                                            setModalState(() {
                                              row.open = picked;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _HourFieldButton(
                                          label: row.close == null
                                              ? "Closing"
                                              : _timeForDisplay(context, row.close!),
                                          onTap: () async {
                                            final picked =
                                                await _pickTime(row.close);
                                            if (picked == null) return;
                                            setModalState(() {
                                              row.close = picked;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      if (rowIndex == rows.length - 1)
                                        _SquareActionButton(
                                          icon: Icons.add_rounded,
                                          onTap: () {
                                            setModalState(() {
                                              rows.add(_HourRange());
                                            });
                                          },
                                        )
                                      else
                                        _SquareActionButton(
                                          icon: Icons.remove_rounded,
                                          danger: true,
                                          onTap: () {
                                            setModalState(() {
                                              rows.removeAt(rowIndex);
                                              if (rows.isEmpty) {
                                                rows.add(_HourRange());
                                              }
                                            });
                                          },
                                        ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: Colors.grey.shade200,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(context),
                              style: TextButton.styleFrom(
                                backgroundColor: Colors.grey.shade100,
                                foregroundColor: Colors.black87,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              child: const Text(
                                "Cancel",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _hoursByDay = {
                                    for (final day in _days)
                                      day: working[day]!
                                          .where((row) =>
                                              row.open != null ||
                                              row.close != null)
                                          .map((row) => row.copy())
                                          .toList(),
                                  };
                                  _hoursMode = "selected";
                                });
                                Navigator.pop(context);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              child: const Text(
                                "Save",
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
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
          },
        );
      },
    );
  }

  Future<void> _inviteFriend({
    required String friendUid,
    required String friendName,
    required String friendPhotoUrl,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      _showSnack("You need to be signed in.");
      return;
    }

    if (_busyInviteIds.contains(friendUid) ||
        _sentInviteIds.contains(friendUid) ||
        widget.draft.invitedFriendIds.contains(friendUid)) {
      return;
    }

    setState(() {
      _busyInviteIds.add(friendUid);
    });

    try {
      final senderDoc = await FirebaseFirestore.instance
          .collection("users")
          .doc(currentUser.uid)
          .get();

      final senderData = senderDoc.data() ?? {};
      final senderName = (senderData["fullName"] ?? "Someone").toString();
      final senderPhotoUrl = (senderData["photoUrl"] ?? "").toString();

      final communityName = widget.draft.communityName.trim().isEmpty
          ? "New community"
          : widget.draft.communityName.trim();

      final communityHeadline = widget.draft.headline.trim();
      final communityPhotoUrl = widget.draft.profilePhotoUrl?.trim() ?? "";

      await FirebaseFirestore.instance
          .collection("users")
          .doc(friendUid)
          .collection("notifications")
          .add({
        "type": "community_invite",
        "senderUid": currentUser.uid,
        "senderName": senderName,
        "senderPhotoUrl": senderPhotoUrl,
        "title": "Community invite",
        "body": "$senderName invited you to check out $communityName.",
        "read": false,
        "createdAt": FieldValue.serverTimestamp(),
        "buttonLabel": "Visit community",
        "communitySnapshot": {
          "name": communityName,
          "headline": communityHeadline,
          "category": _selectedCategory,
          "photoUrl": communityPhotoUrl,
          "radiusKm": _radiusKm.round(),
          "hoursMode": _hoursMode,
          "hours": _serializeHours(),
        },
      });

      if (!mounted) return;

      setState(() {
        _sentInviteIds.add(friendUid);
        widget.draft.invitedFriendIds.add(friendUid);
      });

      _showSnack("Invite sent to $friendName.");
    } catch (e, st) {
      debugPrint("community invite failed: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      _showSnack("Couldn’t send invite.");
    } finally {
      if (mounted) {
        setState(() {
          _busyInviteIds.remove(friendUid);
        });
      }
    }
  }

  Future<void> _saveAndContinue() async {
    if (_selectedCategory.trim().isEmpty) {
      _showSnack("Choose one community category to continue.");
      return;
    }

    if (_hoursMode == "selected" && !_hasAnyCompleteSelectedHours) {
      _showSnack("Add at least one valid opening and closing time.");
      return;
    }

    setState(() => saving = true);

    try {
      widget.draft.discoveryRadiusKm = _radiusKm.roundToDouble();
      widget.draft.communityCategory = _selectedCategory.trim();
      widget.draft.hoursMode = _hoursMode;
      widget.draft.selectedHours = _serializeHours();

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CommunityFinalReviewScreen(
            draft: widget.draft,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint("community settings next failed: $e");
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      _showSnack("Something went wrong. Please try again.");
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _buildInfoCard() {
    final km = _radiusKm.round();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              PhosphorIconsFill.slidersHorizontal,
              color: AppColors.brandGreen,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedCategory.trim().isEmpty
                      ? "$km km radius • Pick a type"
                      : "$km km radius • $_selectedCategory",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFamily: "Nunito",
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _hoursSummaryText(),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _selectedCategory.trim().isEmpty ? "Set" : "Ready",
              style: const TextStyle(
                color: Colors.white,
                fontFamily: "Nunito",
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: "Nunito",
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 13.5,
            height: 1.4,
            fontWeight: FontWeight.w500,
            color: Colors.black.withOpacity(.56),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryCard(Map<String, dynamic> item) {
    final String label = (item["label"] ?? "").toString();
    final IconData icon = item["icon"] as IconData;
    final bool selected = _selectedCategory == label;
    final bool pressed = pressedCategory == label;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: saving ? null : (_) => setState(() => pressedCategory = label),
      onTapCancel: () => setState(() => pressedCategory = null),
      onTapUp: (_) => setState(() => pressedCategory = null),
      onTap: saving
          ? null
          : () {
              try {
                HapticFeedback.selectionClick();
              } catch (_) {}
              setState(() => _selectedCategory = label);
            },
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        scale: pressed ? 0.97 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: selected ? Colors.grey.shade100 : AppColors.brandGreen,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PhosphorIcon(
                      icon,
                      size: 26,
                      color: selected ? AppColors.brandGreen : Colors.white,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.black87 : Colors.white,
                          fontFamily: "Nunito",
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Positioned(
                  top: -6,
                  right: -6,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                          color: Colors.black.withOpacity(.18),
                        ),
                      ],
                    ),
                    child: const Icon(
                      PhosphorIconsBold.check,
                      size: 14,
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

  Widget _buildCustomCategoryButton() {
    final bool selected = _selectedCategory.trim().isNotEmpty &&
        !categories.any(
          (item) =>
              _categoryKey((item["label"] ?? "").toString()) ==
              _categoryKey(_selectedCategory),
        );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: saving ? null : _openCustomCategorySheet,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? Colors.grey.shade100 : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.brandGreen.withOpacity(.22)
                : Colors.grey.shade200,
            width: 1.3,
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 8),
              color: Colors.black.withOpacity(.05),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.brandGreen.withOpacity(.12)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                PhosphorIconsRegular.plusCircle,
                color: AppColors.brandGreen,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Custom category",
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      fontFamily: "Nunito",
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selected
                        ? _selectedCategory
                        : "Add your own category if the recommended ones don’t fit.",
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.8,
                      fontWeight: FontWeight.w500,
                      fontFamily: "Nunito",
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: const Icon(
                  PhosphorIconsBold.check,
                  size: 14,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoursModeTile({
    required String value,
    required String title,
    required String subtitle,
    required bool withEditButton,
  }) {
    final bool selected = _hoursMode == value;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: saving
          ? null
          : () async {
              setState(() => _hoursMode = value);
              if (value == "selected") {
                await _openHoursSheet();
              }
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? Colors.grey.shade100 : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.brandGreen.withOpacity(.22)
                : Colors.grey.shade200,
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 8),
              color: Colors.black.withOpacity(.05),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withOpacity(.10),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                value == "none"
                    ? PhosphorIconsRegular.prohibitInset
                    : value == "always_open"
                        ? PhosphorIconsRegular.clockAfternoon
                        : PhosphorIconsRegular.clockCountdown,
                color: AppColors.brandGreen,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      fontFamily: "Nunito",
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12.8,
                      fontWeight: FontWeight.w500,
                      fontFamily: "Nunito",
                      color: Colors.grey.shade600,
                    ),
                  ),
                  if (selected && value == "selected") ...[
                    const SizedBox(height: 6),
                    Text(
                      _hoursSummaryText(),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: AppColors.brandGreen,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (withEditButton && selected)
              TextButton(
                onPressed: saving ? null : _openHoursSheet,
                child: const Text(
                  "Edit",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w800,
                    color: AppColors.brandGreen,
                  ),
                ),
              )
            else if (selected)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: const Icon(
                  PhosphorIconsBold.check,
                  size: 14,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: TextField(
        controller: _friendSearchCtrl,
        cursorColor: AppColors.brandGreen,
        decoration: InputDecoration(
          hintText: "Search friends",
          hintStyle: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFamily: "Nunito",
          ),
          prefixIcon: Icon(
            PhosphorIconsRegular.magnifyingGlass,
            size: 20,
            color: Colors.grey.shade700,
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
              color: Colors.grey.shade300,
              width: 1.1,
            ),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(
              color: AppColors.brandGreen,
              width: 1.6,
            ),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
              color: Colors.grey.shade300,
              width: 1.1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInviteFriendsSection() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: const Text(
          "You need to be signed in to invite friends.",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    if (_friendsInitialLoading && _friendItems.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
          ),
        ),
      );
    }

    if (_friendsLoadError != null && _friendItems.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _friendsLoadError!,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _loadInitialFriends,
              child: const Text(
                "Retry",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w800,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_friendItems.isEmpty && _friendsLoadedOnce) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Text(
          "No friends to invite yet.",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(.62),
          ),
        ),
      );
    }

    final visibleItems = _visibleFriendItems;

    if (visibleItems.isEmpty && _friendSearch.isNotEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Text(
          _friendsHasMore
              ? "No matches in the loaded friends yet. Scroll more to load more friends."
              : "No friends matched your search.",
          style: TextStyle(
            fontFamily: "Nunito",
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(.62),
          ),
        ),
      );
    }

    return Column(
      children: [
        ...visibleItems.map((friend) {
          final busy = _busyInviteIds.contains(friend.uid);
          final sent = _sentInviteIds.contains(friend.uid);

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PersonActionTile(
              photoUrl: friend.photoUrl,
              title: friend.name,
              subtitle: friend.username.isEmpty ? "" : "@${friend.username}",
              trailing: ElevatedButton(
                onPressed: busy || sent
                    ? null
                    : () => _inviteFriend(
                          friendUid: friend.uid,
                          friendName: friend.name,
                          friendPhotoUrl: friend.photoUrl,
                        ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: sent
                      ? Colors.black.withOpacity(.08)
                      : AppColors.brandGreen,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text(
                        sent ? "Sent" : "Invite",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          color: sent
                              ? Colors.black.withOpacity(.70)
                              : Colors.white,
                        ),
                      ),
              ),
            ),
          );
        }),

        if (_friendsMoreLoading)
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 12),
            child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
            ),
          ),

        if (!_friendsMoreLoading && _friendsHasMore && _friendSearch.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 10),
            child: Text(
              "Scroll to load more friends",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: Colors.grey.shade600,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final int kmInt = _radiusKm.round();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAF8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: saving ? null : () => Navigator.pop(context),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.grey.shade200,
                        ),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "Create community",
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: ProfileProgressBar(step: 4, totalSteps: 5),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                controller: _pageScrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        "assets/images/onboarding_five.png",
                        height: 230,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      "Set the basics that shape discovery",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        fontFamily: "Nunito",
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Keep this tight. Radius decides reach, category tells people what this community is, hours make it feel real, and invites help it start with actual people.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        fontFamily: "Nunito",
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _buildInfoCard(),
                    const SizedBox(height: 24),

                    _buildSectionTitle(
                      "Discovery radius",
                      "Choose how far this community should be discoverable.",
                    ),
                    const SizedBox(height: 16),

                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: AppColors.brandGreen.withOpacity(.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.radar_rounded,
                              color: AppColors.brandGreen,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "$kmInt km",
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    fontFamily: "Nunito",
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _radiusVibe(kmInt),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey,
                                    fontFamily: "Nunito",
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    _BubbleSlider(
                      value: _radiusKm,
                      min: minKm.toDouble(),
                      max: maxKm.toDouble(),
                      label: "$kmInt km",
                      onChanged: saving
                          ? null
                          : (v) {
                              setState(() => _radiusKm = v);
                            },
                    ),

                    const SizedBox(height: 12),

                    Text(
                      "Max range: $maxKm km",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontFamily: "Nunito",
                      ),
                    ),

                    const SizedBox(height: 28),

                    _buildSectionTitle(
                      "Category / type",
                      "Pick one recommended category, or add your own custom one.",
                    ),
                    const SizedBox(height: 18),

                    Text(
                      "Recommended",
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w800,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),

                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.92,
                      ),
                      itemCount: categories.length,
                      itemBuilder: (context, index) {
                        return _buildCategoryCard(categories[index]);
                      },
                    ),

                    const SizedBox(height: 16),
                    _buildCustomCategoryButton(),

                    const SizedBox(height: 28),

                    _buildSectionTitle(
                      "Hours open",
                      "Show no hours, mark the community as always open, or enter selected hours.",
                    ),
                    const SizedBox(height: 14),

                    _buildHoursModeTile(
                      value: "none",
                      title: "No hours available",
                      subtitle: "Don’t show any hours.",
                      withEditButton: false,
                    ),
                    _buildHoursModeTile(
                      value: "always_open",
                      title: "Always open",
                      subtitle: "You’re open 24 hours every day.",
                      withEditButton: false,
                    ),
                    _buildHoursModeTile(
                      value: "selected",
                      title: "Open at selected hours",
                      subtitle: "Enter your specific hours.",
                      withEditButton: true,
                    ),

                    const SizedBox(height: 28),

                    _buildSectionTitle(
                      "Invite friends to subscribe",
                      "Start strong. Invite people who already know you.",
                    ),
                    const SizedBox(height: 14),
                    _buildSearchField(),
                    const SizedBox(height: 14),
                    _buildInviteFriendsSection(),

                    const SizedBox(height: 120),
                  ],
                ),
              ),
            ),
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
                        backgroundColor: AppColors.brandGreen,
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
}

class _BubbleSlider extends StatelessWidget {
  const _BubbleSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final double t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    final double screenW = MediaQuery.of(context).size.width;
    final double sliderW = screenW - 48;
    const double bubbleW = 72;

    final double left = (t * sliderW) - (bubbleW / 2);
    final double clampedLeft = left.clamp(0.0, sliderW - bubbleW);

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: clampedLeft,
                top: 0,
                child: Container(
                  width: bubbleW,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                        color: Colors.black.withOpacity(.10),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontFamily: "Nunito",
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 10,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 14),
            activeTrackColor: AppColors.brandGreen,
            inactiveTrackColor: Colors.grey.shade200,
            thumbColor: AppColors.brandGreen,
            overlayColor: AppColors.brandGreen.withOpacity(.12),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).toInt(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _HourFieldButton extends StatelessWidget {
  const _HourFieldButton({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              Icon(
                PhosphorIconsRegular.clock,
                size: 18,
                color: Colors.grey.shade700,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: label == "Opening" || label == "Closing"
                        ? Colors.grey.shade600
                        : Colors.black87,
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

class _SquareActionButton extends StatelessWidget {
  const _SquareActionButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 52,
          height: 56,
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xFFB42318).withOpacity(.10)
                : AppColors.brandGreen.withOpacity(.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            icon,
            color: danger ? const Color(0xFFB42318) : AppColors.brandGreen,
          ),
        ),
      ),
    );
  }
}

class _PersonActionTile extends StatelessWidget {
  const _PersonActionTile({
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String photoUrl;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(.05),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.brandGreen.withOpacity(.10),
            backgroundImage: hasPhoto ? NetworkImage(photoUrl) : null,
            child: !hasPhoto
                ? const Icon(
                    PhosphorIconsRegular.user,
                    color: AppColors.brandGreen,
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                if (subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.8,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _HourRange {
  _HourRange({
    this.open,
    this.close,
  });

  TimeOfDay? open;
  TimeOfDay? close;

  _HourRange copy() => _HourRange(
        open: open == null
            ? null
            : TimeOfDay(hour: open!.hour, minute: open!.minute),
        close: close == null
            ? null
            : TimeOfDay(hour: close!.hour, minute: close!.minute),
      );
}

TimeOfDay? _timeFromStorage(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parts = raw.split(':');
  if (parts.length != 2) return null;

  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);

  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

  return TimeOfDay(hour: hour, minute: minute);
}

String _timeToStorage(TimeOfDay value) {
  final hh = value.hour.toString().padLeft(2, '0');
  final mm = value.minute.toString().padLeft(2, '0');
  return "$hh:$mm";
}

String _timeForDisplay(BuildContext context, TimeOfDay value) {
  final localizations = MaterialLocalizations.of(context);
  return localizations.formatTimeOfDay(value);
}

class _FriendInviteItem {
  const _FriendInviteItem({
    required this.uid,
    required this.name,
    required this.username,
    required this.photoUrl,
  });

  final String uid;
  final String name;
  final String username;
  final String photoUrl;
}