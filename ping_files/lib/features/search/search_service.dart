import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ping_files/features/pings/ping_visibility.dart';

enum SearchKind { ping, user }

class SearchResult {
  final SearchKind kind;
  final String id;
  final Map<String, dynamic> data;

  SearchResult({
    required this.kind,
    required this.id,
    required this.data,
  });
}

class SearchService {
  final FirebaseFirestore _db;
  final PingVisibilityContext visibilityContext;

  SearchService(
    this._db, {
    required this.visibilityContext,
  });

  static const Map<String, List<String>> _synonyms = {
    "chill": ["hangout", "hang", "out", "vibes", "relax", "linkup", "lowkey"],
    "hangout": ["chill", "hang", "out", "linkup", "vibes"],
    "hang": ["hangout", "chill"],
    "out": ["hangout"],
    "linkup": ["hangout", "chill"],
    "link": ["linkup"],
    "up": ["linkup"],
    "football": ["soccer"],
    "gym": ["fitness", "workout"],
    "workout": ["gym", "fitness"],
    "music": ["party", "vibes"],
  };

  List<String> _tokenize(String input) {
    final q = input.trim().toLowerCase();
    if (q.isEmpty) return [];

    final raw = q
        .replaceAll(RegExp(r"[^\w#\s]"), " ")
        .split(RegExp(r"\s+"))
        .where((t) => t.isNotEmpty)
        .toList();

    final out = <String>{};

    for (final t in raw) {
      out.add(t);
      final syn = _synonyms[t];
      if (syn != null) out.addAll(syn);
    }

    for (int i = 0; i < raw.length - 1; i++) {
      final joined = "${raw[i]}${raw[i + 1]}";
      out.add(joined);

      final syn = _synonyms[joined];
      if (syn != null) out.addAll(syn);
    }

    return out.toList();
  }

  Future<List<QuerySnapshot<Map<String, dynamic>>>> _safeWait(
    List<Future<QuerySnapshot<Map<String, dynamic>>>> futures,
  ) async {
    final out = <QuerySnapshot<Map<String, dynamic>>>[];

    for (final future in futures) {
      try {
        final snap = await future;
        out.add(snap);
      } catch (e) {
      }
    }

    return out;
  }

  bool _isVisibleActivePing(Map<String, dynamic> data) {
    final status = (data["status"] ?? "active").toString();
    if (status != "active") return false;

    return PingVisibility.canViewerSeeActivePing(
      ping: data,
      context: visibilityContext,
      now: DateTime.now(),
    );
  }

  Future<List<SearchResult>> searchAll(String query) async {
    final tokens = _tokenize(query);
    if (tokens.isEmpty) return [];

    final pingFuture = _searchPings(tokens, query);
    final userFuture = _searchUsers(tokens, query);

    final results = await Future.wait([pingFuture, userFuture]);
    final merged = [...results[0], ...results[1]];

    merged.sort(
      (a, b) => _score(b, tokens, query).compareTo(_score(a, tokens, query)),
    );

    return merged;
  }

  Future<List<SearchResult>> searchPingsOnly(String query) async {
    final tokens = _tokenize(query);
    if (tokens.isEmpty) return [];

    final list = await _searchPings(tokens, query);
    list.sort(
      (a, b) => _score(b, tokens, query).compareTo(_score(a, tokens, query)),
    );
    return list;
  }

  Future<List<SearchResult>> searchPeopleOnly(String query) async {
    final tokens = _tokenize(query);
    if (tokens.isEmpty) return [];

    final list = await _searchUsers(tokens, query);
    list.sort(
      (a, b) => _score(b, tokens, query).compareTo(_score(a, tokens, query)),
    );
    return list;
  }

  Future<List<SearchResult>> _fallbackRecentPingScan(String rawQuery) async {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return [];

    try {
      final snap = await _db
          .collection("pings")
          .orderBy("createdAtLocal", descending: true)
          .limit(200)
          .get();

      final out = <SearchResult>[];

      for (final d in snap.docs) {
        final data = d.data();
        if (!_isVisibleActivePing(data)) continue;

        final title = (data["title"] ?? "").toString().toLowerCase();
        final desc = (data["description"] ?? "").toString().toLowerCase();
        final loc = (data["location"] is Map)
            ? Map<String, dynamic>.from(data["location"])
            : <String, dynamic>{};
        final place = (loc["placeName"] ?? "").toString().toLowerCase();

        if (title.contains(q) || desc.contains(q) || place.contains(q)) {
          out.add(
            SearchResult(
              kind: SearchKind.ping,
              id: d.id,
              data: data,
            ),
          );
        }
      }

      return out;
    } catch (e) {
      return [];
    }
  }

  Future<List<SearchResult>> _fallbackRecentUserScan(String rawQuery) async {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return [];

    try {
      final snap = await _db.collection("users").limit(200).get();

      final out = <SearchResult>[];

      for (final d in snap.docs) {
        final data = d.data();

        final username = (data["username"] ?? "").toString().toLowerCase();
        final fullName = (data["fullName"] ?? "").toString().toLowerCase();

        final interests = (data["interests"] is List)
            ? (data["interests"] as List)
                .map((e) => e.toString().toLowerCase())
                .toList()
            : <String>[];

        final skills = (data["skills"] is List)
            ? (data["skills"] as List)
                .map((e) => e.toString().toLowerCase())
                .toList()
            : <String>[];

        if (username.contains(q) ||
            fullName.contains(q) ||
            interests.any((x) => x.contains(q)) ||
            skills.any((x) => x.contains(q))) {
          out.add(
            SearchResult(
              kind: SearchKind.user,
              id: d.id,
              data: data,
            ),
          );
        }
      }

      return out;
    } catch (e) {
      return [];
    }
  }

  Future<List<SearchResult>> _searchPings(
    List<String> tokens,
    String rawQuery,
  ) async {
    final normalizedTags = tokens
        .map((t) => t.startsWith("#") ? t.substring(1) : t)
        .where((t) => t.isNotEmpty)
        .toList();

    final tokenSlice = normalizedTags.take(10).toList();
    final q = rawQuery.trim().toLowerCase();

    final futures = <Future<QuerySnapshot<Map<String, dynamic>>>>[];

    void addKeywordQueriesForPrivacy(String privacy) {
      if (tokenSlice.isNotEmpty) {
        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: privacy)
              .where("keywords", arrayContainsAny: tokenSlice)
              .limit(20)
              .get(),
        );

        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: privacy)
              .where("tags", arrayContainsAny: tokenSlice)
              .limit(20)
              .get(),
        );
      }

      if (q.isNotEmpty) {
        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: privacy)
              .orderBy("title_lc")
              .startAt([q])
              .endAt(["$q\uf8ff"])
              .limit(20)
              .get(),
        );
      }
    }

    // public
    addKeywordQueriesForPrivacy("public");

    // verified
    if (visibilityContext.viewerVerified) {
      addKeywordQueriesForPrivacy("verified");
    }

    // friends
    for (final friendUid in visibilityContext.viewerFriendIds.take(15)) {
      if (tokenSlice.isNotEmpty) {
        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: "friends")
              .where("creatorId", isEqualTo: friendUid)
              .where("keywords", arrayContainsAny: tokenSlice)
              .limit(10)
              .get(),
        );

        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: "friends")
              .where("creatorId", isEqualTo: friendUid)
              .where("tags", arrayContainsAny: tokenSlice)
              .limit(10)
              .get(),
        );
      }

      if (q.isNotEmpty) {
        futures.add(
          _db
              .collection("pings")
              .where("privacy", isEqualTo: "friends")
              .where("creatorId", isEqualTo: friendUid)
              .orderBy("title_lc")
              .startAt([q])
              .endAt(["$q\uf8ff"])
              .limit(10)
              .get(),
        );
      }
    }

    final snaps = await _safeWait(futures);
    final map = <String, SearchResult>{};

    for (final s in snaps) {
      for (final d in s.docs) {
        final data = d.data();
        if (!_isVisibleActivePing(data)) continue;

        map[d.id] = SearchResult(
          kind: SearchKind.ping,
          id: d.id,
          data: data,
        );
      }
    }

    final results = map.values.toList();

    if (results.isEmpty && q.isNotEmpty) {
      return _fallbackRecentPingScan(q);
    }

    return results;
  }

  Future<List<SearchResult>> _searchUsers(
    List<String> tokens,
    String rawQuery,
  ) async {
    final q = rawQuery.trim().toLowerCase();
    final futures = <Future<QuerySnapshot<Map<String, dynamic>>>>[];

    if (q.isNotEmpty) {
      futures.add(
        _db
            .collection("users")
            .orderBy("username_lc")
            .startAt([q])
            .endAt(["$q\uf8ff"])
            .limit(20)
            .get(),
      );

      futures.add(
        _db
            .collection("users")
            .orderBy("fullName_lc")
            .startAt([q])
            .endAt(["$q\uf8ff"])
            .limit(20)
            .get(),
      );
    }

    final labelish = tokens
        .map((t) => _titleCaseToken(t))
        .where((t) => t.isNotEmpty)
        .toList();

    final slice = labelish.take(10).toList();

    if (slice.isNotEmpty) {
      futures.add(
        _db
            .collection("users")
            .where("interests", arrayContainsAny: slice)
            .limit(20)
            .get(),
      );

      futures.add(
        _db
            .collection("users")
            .where("skills", arrayContainsAny: slice)
            .limit(20)
            .get(),
      );
    }

    final snaps = await _safeWait(futures);
    final map = <String, SearchResult>{};

    for (final s in snaps) {
      for (final d in s.docs) {
        map[d.id] = SearchResult(
          kind: SearchKind.user,
          id: d.id,
          data: d.data(),
        );
      }
    }

    final results = map.values.toList();

    if (results.isEmpty && q.isNotEmpty) {
      return _fallbackRecentUserScan(q);
    }

    return results;
  }

  int _score(SearchResult r, List<String> tokens, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    final data = r.data;

    if (r.kind == SearchKind.ping) {
      final title = (data["title"] ?? "").toString().toLowerCase();
      final tags = (data["tags"] is List)
          ? (data["tags"] as List)
              .map((e) => e.toString().toLowerCase())
              .toList()
          : <String>[];

      int s = 0;
      if (title.contains(q) && q.isNotEmpty) s += 50;

      for (final t in tokens) {
        final tt = t.startsWith("#") ? t.substring(1) : t;
        if (tags.contains(tt)) s += 30;
        if (title.contains(tt)) s += 10;
      }
      return s;
    } else {
      final username = (data["username"] ?? "").toString().toLowerCase();
      final name = (data["fullName"] ?? "").toString().toLowerCase();

      int s = 0;
      if (username.startsWith(q) && q.isNotEmpty) s += 60;
      if (name.startsWith(q) && q.isNotEmpty) s += 40;
      return s;
    }
  }

  String _titleCaseToken(String t) {
    final x = t.replaceAll("#", "").trim();
    if (x.isEmpty) return "";
    if (x.length == 1) return x.toUpperCase();
    return x[0].toUpperCase() + x.substring(1).toLowerCase();
  }
}