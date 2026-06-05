import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PingmeeFeedBootstrapResult {
  final String userFeed;
  final String timelineFeed;
  final String notificationFeed;

  const PingmeeFeedBootstrapResult({
    required this.userFeed,
    required this.timelineFeed,
    required this.notificationFeed,
  });

  factory PingmeeFeedBootstrapResult.fromMap(Map<String, dynamic> map) {
    final feeds = Map<String, dynamic>.from(map["feeds"] ?? {});

    return PingmeeFeedBootstrapResult(
      userFeed: (feeds["user"] ?? "").toString(),
      timelineFeed: (feeds["timeline"] ?? "").toString(),
      notificationFeed: (feeds["notification"] ?? "").toString(),
    );
  }
}

class PingmeeFeedService {
  PingmeeFeedService({
    FirebaseFunctions? functions,
  }) : _functions = functions ??
            FirebaseFunctions.instanceFor(region: "us-central1");

  final FirebaseFunctions _functions;

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = (value ?? "").toString().trim();
      if (text.isNotEmpty) return text;
    }
    return "";
  }

  Future<Map<String, dynamic>> getFeedsToken() async {
    debugPrint("🟢 Calling getStreamFeedsUserToken...");

    try {
      final callable = _functions.httpsCallable("getStreamFeedsUserToken");
      final result = await callable.call();

      final data = Map<String, dynamic>.from(result.data as Map);
      debugPrint("🧪 Timeline backend debugVersion=${data["debugVersion"]}");

      debugPrint("✅ Stream Feeds token ready for user=${data["userId"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 getStreamFeedsUserToken failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 getStreamFeedsUserToken unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<PingmeeFeedBootstrapResult> bootstrapMyFeeds() async {
    debugPrint("🟢 bootstrapMyFeeds service started");
    debugPrint("🟢 Calling bootstrapMyFeeds function...");

    try {
      final callable = _functions.httpsCallable("bootstrapMyFeeds");
      final result = await callable.call();

      final data = Map<String, dynamic>.from(result.data as Map);
      final boot = PingmeeFeedBootstrapResult.fromMap(data);

      debugPrint("✅ Pingmee feeds bootstrapped");
      debugPrint("   user=${boot.userFeed}");
      debugPrint("   timeline=${boot.timelineFeed}");
      debugPrint("   notification=${boot.notificationFeed}");

      return boot;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 bootstrapMyFeeds failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 bootstrapMyFeeds unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createTestMoment() async {
    debugPrint("🟢 Calling createTestMoment function...");

    try {
      final callable = _functions.httpsCallable("createTestMoment");

      final result = await callable.call({
        "text": "Testing my first Pingmee Moment from Flutter.",
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Test Moment created");
      debugPrint("   momentId=${data["momentId"]}");
      debugPrint("   streamActivityId=${data["streamActivityId"]}");
      debugPrint("   feed=${data["feed"]}");
      debugPrint("🧪 Function returned mediaCount=${data["mediaCount"]}");
      debugPrint("🧪 Function returned media=${data["media"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 createTestMoment failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 createTestMoment unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> loadMyTimelineMoments() async {
    final user = FirebaseAuth.instance.currentUser;

    debugPrint("🟢 Calling loadMyTimelineMoments function...");
    debugPrint("🟢 Current Firebase user before timeline call: ${user?.uid}");

    if (user == null) {
      debugPrint("🛑 Cannot load timeline: Firebase user is null.");
      throw FirebaseAuthException(
        code: "not-signed-in",
        message: "No Firebase user is currently signed in.",
      );
    }

    try {
      // Force-refresh the auth token so callable Functions receives request.auth.
      await user.getIdToken(true);
      debugPrint("🟢 Firebase ID token refreshed before timeline call.");

      final callable = _functions.httpsCallable("loadMyTimelineMoments");

      final result = await callable.call({
        "limit": 15,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final raw = data["activities"];

      final activities = raw is List
          ? raw
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList()
          : <Map<String, dynamic>>[];

      debugPrint("✅ Timeline Moments loaded");
      debugPrint("   count=${activities.length}");

      for (final activity in activities) {
        debugPrint(
          "   moment=${activity["id"]} "
          "location=${activity["locationLabel"]} "
          "city=${activity["city"]} "
          "country=${activity["country"]} "
          "time=${activity["time"]} "
          "text=${activity["text"]}",
        );
      }

      return activities;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 loadMyTimelineMoments failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 loadMyTimelineMoments unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createMoment({
    required String text,
    String visibility = "public",
    Map<String, dynamic>? location,
    List<Map<String, dynamic>> media = const [],
  }) async {
    debugPrint("🟢 Calling createMoment function...");

    try {
      final callable = _functions.httpsCallable("createMomentV2");

      final result = await callable.call({
        "text": text,
        "visibility": visibility,
        "location": location ?? {},
        "media": media,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Moment created");
      debugPrint("   momentId=${data["momentId"]}");
      debugPrint("   streamActivityId=${data["streamActivityId"]}");
      debugPrint("   feed=${data["feed"]}");
      debugPrint("🧪 createMoment returned mediaCount=${data["mediaCount"]}");
      debugPrint("🧪 createMoment returned media=${data["media"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 createMoment failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 createMoment unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> toggleMomentLike({
    required String activityId,
    required bool currentlyLiked,
    required String reactionId,
    String? momentId,
  }) async {
    debugPrint("🟢 Calling toggleMomentLike function...");

    try {
      final callable = _functions.httpsCallable("toggleMomentLike");

      final result = await callable.call({
        "activityId": activityId,
        "currentlyLiked": currentlyLiked,
        "reactionId": reactionId,
        "momentId": momentId ?? activityId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Moment like updated");
      debugPrint("   liked=${data["liked"]}");
      debugPrint("   reactionId=${data["reactionId"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 toggleMomentLike failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 toggleMomentLike unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> loadMomentComments({
    required String activityId,
  }) async {
    debugPrint("🟢 Calling loadMomentComments function...");

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }

    try {
      final callable = _functions.httpsCallable("loadMomentComments");

      final result = await callable.call({
        "activityId": activityId,
        "limit": 30,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final raw = data["comments"];

      final comments = raw is List
          ? raw.map((item) => Map<String, dynamic>.from(item as Map)).toList()
          : <Map<String, dynamic>>[];

      debugPrint("✅ Moment comments loaded count=${comments.length}");

      return comments;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 loadMomentComments failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> addMomentComment({
    required String activityId,
    required String text,
  }) async {
    debugPrint("🟢 Calling addMomentComment function...");

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }

    try {
      final callable = _functions.httpsCallable("addMomentComment");

      final result = await callable.call({
        "activityId": activityId,
        "text": text,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Moment comment added");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 addMomentComment failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> toggleMomentBookmark({
    required String activityId,
    required bool currentlySaved,
    required String reactionId,
    String? momentId,
  }) async {
    debugPrint("🟢 Calling toggleMomentBookmark function...");

    try {
      final callable = _functions.httpsCallable("toggleMomentBookmark");

      final result = await callable.call({
        "activityId": activityId,
        "currentlySaved": currentlySaved,
        "reactionId": reactionId,
        "momentId": momentId ?? activityId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Moment save updated");
      debugPrint("   saved=${data["saved"]}");
      debugPrint("   reactionId=${data["reactionId"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 toggleMomentBookmark failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 toggleMomentBookmark unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createMomentRepost({
    required Map<String, dynamic> originalMoment,
    String quoteText = "",
  }) async {
    debugPrint("🟢 Calling createMomentRepost function...");

    try {
      final callable = _functions.httpsCallable("createMomentRepost");

      final originalActivityId = _firstNonEmpty([
        originalMoment["originalActivityId"],
        originalMoment["id"],
        originalMoment["activityId"],
      ]);

      final originalText = _firstNonEmpty([
        originalMoment["originalText"],
        originalMoment["text"],
      ]);

      final originalAuthorUid = _firstNonEmpty([
        originalMoment["originalAuthorUid"],
        originalMoment["authorUid"],
      ]);

      final originalAuthorName = _firstNonEmpty([
        originalMoment["originalAuthorName"],
        originalMoment["authorName"],
      ]);

      final originalAuthorPhotoUrl = _firstNonEmpty([
        originalMoment["originalAuthorPhotoUrl"],
        originalMoment["authorPhotoUrl"],
      ]);

      final originalMedia = originalMoment["originalMedia"] is List
          ? List<Map<String, dynamic>>.from(
              (originalMoment["originalMedia"] as List)
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item)),
            )
          : originalMoment["media"] is List
              ? List<Map<String, dynamic>>.from(
                  (originalMoment["media"] as List)
                      .whereType<Map>()
                      .map((item) => Map<String, dynamic>.from(item)),
                )
              : <Map<String, dynamic>>[];

      debugPrint("🧪 repost originalActivityId=$originalActivityId");
      debugPrint("🧪 repost originalText=$originalText");
      debugPrint("🧪 repost originalMediaCount=${originalMedia.length}");

      final originalForeignId = _firstNonEmpty([
        originalMoment["originalForeignId"],
        originalMoment["foreignId"],
        originalMoment["streamForeignId"],
      ]);

      final result = await callable.call({
        "originalActivityId": originalActivityId,
        "quoteText": quoteText.trim(),
        "originalForeignId": originalForeignId,
        "originalAuthorUid": originalAuthorUid,
        "originalAuthorName": originalAuthorName,
        "originalAuthorPhotoUrl": originalAuthorPhotoUrl,
        "originalText": originalText,
        "originalMedia": originalMedia,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Moment reposted");
      debugPrint("   type=${data["type"]}");
      debugPrint("   streamActivityId=${data["streamActivityId"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 createMomentRepost failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 createMomentRepost unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<void> deleteMoment({
    required String activityId,
    required String foreignId,
  }) async {
    debugPrint("🟢 Calling deleteMoment function...");

    try {
      final callable = _functions.httpsCallable("deleteMoment");

      await callable.call({
        "activityId": activityId,
        "foreignId": foreignId,
      });

      debugPrint("✅ Moment deleted");
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 deleteMoment failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<void> reportMoment({
    required String activityId,
    required String foreignId,
    String reason = "other",
  }) async {
    debugPrint("🟢 Calling reportMoment function...");

    try {
      final callable = _functions.httpsCallable("reportMoment");

      await callable.call({
        "activityId": activityId,
        "foreignId": foreignId,
        "reason": reason,
      });

      debugPrint("✅ Moment reported");
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 reportMoment failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> syncMyFeedFollows() async {
    debugPrint("🟢 Calling syncMyFeedFollows function...");

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }

    try {
      final callable = _functions.httpsCallable("syncMyFeedFollows");
      final result = await callable.call();

      final data = Map<String, dynamic>.from(result.data as Map);

      debugPrint("✅ Feed follows synced");
      debugPrint("   followedCount=${data["followedCount"]}");

      return data;
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint("🔥 syncMyFeedFollows failed");
      debugPrint("   code=${e.code}");
      debugPrint("   message=${e.message}");
      debugPrint("   details=${e.details}");
      debugPrintStack(stackTrace: st);
      rethrow;
    } catch (e, st) {
      debugPrint("🔥 syncMyFeedFollows unknown failure: $e");
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  /// Load all moments the current user has liked.
  /// Tries Firestore subcollection first (users/{uid}/liked_moments),
  /// falls back to timeline + likedByMe filter.
  Future<List<Map<String, dynamic>>> loadMyLikedMoments() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    try {
      final snap = await FirebaseFirestore.instance
          .collection("users")
          .doc(user.uid)
          .collection("liked_moments")
          .orderBy("likedAt", descending: true)
          .limit(50)
          .get();

      if (snap.docs.isNotEmpty) {
        final moments = <Map<String, dynamic>>[];
        for (final doc in snap.docs) {
          final momentId = doc.id;
          try {
            final momentSnap = await FirebaseFirestore.instance
                .collection("moments")
                .doc(momentId)
                .get();
            if (momentSnap.exists) {
              final m = Map<String, dynamic>.from(momentSnap.data()!);
              m["id"] = momentId;
              m["likedByMe"] = true;
              moments.add(m);
            }
          } catch (_) {}
        }
        return moments;
      }
    } catch (_) {}

    final all = await loadMyTimelineMoments();
    return all.where((m) => m["likedByMe"] == true).toList();
  }

  /// Load all moments the current user has saved/bookmarked.
  /// Tries Firestore subcollection first (users/{uid}/saved_moments),
  /// falls back to timeline + savedByMe filter.
  Future<List<Map<String, dynamic>>> loadMySavedMoments() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    try {
      final snap = await FirebaseFirestore.instance
          .collection("users")
          .doc(user.uid)
          .collection("saved_moments")
          .orderBy("savedAt", descending: true)
          .limit(50)
          .get();

      if (snap.docs.isNotEmpty) {
        final moments = <Map<String, dynamic>>[];
        for (final doc in snap.docs) {
          final momentId = doc.id;
          try {
            final momentSnap = await FirebaseFirestore.instance
                .collection("moments")
                .doc(momentId)
                .get();
            if (momentSnap.exists) {
              final m = Map<String, dynamic>.from(momentSnap.data()!);
              m["id"] = momentId;
              m["savedByMe"] = true;
              moments.add(m);
            }
          } catch (_) {}
        }
        return moments;
      }
    } catch (_) {}

    final all = await loadMyTimelineMoments();
    return all.where((m) => m["savedByMe"] == true).toList();
  }
}