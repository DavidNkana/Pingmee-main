import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;
import 'dart:math' show Point;
import 'dart:math' as math;


import 'package:chewie/chewie.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, PointerDownEvent, PointerMoveEvent, PointerUpEvent, rootBundle;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:ping_files/features/events/event_details_screen.dart';
import 'package:ping_files/features/pings/create_ping_draft.dart';
import 'package:ping_files/features/pings/create_ping_sheet.dart';
import 'package:ping_files/features/pings/ping_details_sheet.dart';
import 'package:ping_files/features/pings/ping_visibility.dart';
import 'package:ping_files/features/search/search_service.dart';
import 'package:ping_files/main_app/tabs/profile/profile_tab.dart';
import 'package:ping_files/theme/colors2.dart';
import 'package:video_player/video_player.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class _ViewerDiscoverProfile {
  final List<String> interests;
  final List<String> skills;

  const _ViewerDiscoverProfile({
    required this.interests,
    required this.skills,
  });
}

class MapTab extends StatefulWidget {
  const MapTab({super.key});

  @override
  State<MapTab> createState() => MapTabState();
}

enum _MapMarkerFilter {
  all,
  pings,
  events,
}

class MapTabState extends State<MapTab> {
  static const String _styleJson = '''
  {
    "version": 8,
    "sources": {
      "osm": {
        "type": "raster",
        "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
        "tileSize": 256,
        "attribution": "© OpenStreetMap contributors"
      }
    },
    "layers": [{ "id": "osm", "type": "raster", "source": "osm" }]
  }
  ''';

  MaplibreMapController? _map;
  bool _mapReady = false;
  bool _tapListenerAttached = false;

  final Map<String, Symbol> _symbolsByPingId = {};
  final Map<String, String> _symbolImageKeyByPingId = {};
  final Set<String> _loadedMarkerImages = {};
  final Map<String, _MapEventPreview> _eventById = {};
  final Map<String, Symbol> _symbolsByEventClusterId = {};
  final Map<String, String> _symbolImageKeyByEventClusterId = {};
  final Map<String, _RenderedEventCluster> _eventClusterById = {};
  final Map<String, Uint8List> _eventCoverBytesCache = {};
  final Map<String, ui.Image> _eventCoverImageCache = {};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventPublicSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _eventMineSub;
  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _eventConnectionSubs = [];

  bool _drawingEventMarkers = false;
  bool _styleLoaded = false;

  _MapMarkerFilter _markerFilter = _MapMarkerFilter.all;

  bool get _showPings =>
      _markerFilter == _MapMarkerFilter.all ||
      _markerFilter == _MapMarkerFilter.pings;

  bool get _showEvents =>
      _markerFilter == _MapMarkerFilter.all ||
      _markerFilter == _MapMarkerFilter.events;
  Future<void>? _routeLayerInitFuture;

  String? _selectedDiscoverCategory;
  final Set<String> _selectedDiscoverTags = <String>{};

  Symbol? _userSymbol;

  bool _markersReady = false;
  bool _isRefreshingMyLocation = false;

  static const _knownCategories = [
    "study",
    "gym",
    "gaming",
    "network",
    "help",
    "support",
    "event",
    "hangout",
    "instant",
    "food",
    "music",
    "sport",
    "default",
  ];

  LatLng? _me;
  bool _locationOk = true;
  StreamSubscription<Position>? _posSub;
  DateTime? _lastAcceptedLocationAt;
  LatLng? _lastAcceptedLocation;  
  Symbol? _radiusTagSymbol;
  String? _radiusTagImageKey;

  final List<_PingPreview> _nearby = [];
  bool _loading = true;
  bool _nearbyCollapsed = false;
  bool _waitingForFirstUsableFix = true;
  Timer? _firstFixTimeout;  
  bool _didAnimateToFirstFix = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _publicSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _verifiedSub;
  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> _friendSubs = [];

  static const String _radiusSourceId = "discovery_radius_source";
  static const String _radiusFillLayerId = "discovery_radius_fill";
  static const String _radiusOutlineLayerId = "discovery_radius_outline";

  double? _discoveryRadiusMiles;
  bool _radiusLayerReady = false;
  Future<void>? _radiusLayerInitFuture;

  double _mapZoom = 11.9;

  static const double _stackBreakZoom = 14.35;
  static const int _maxVisibleStackDepth = 4;
  static const double _firstFixMaxAccuracyMeters = 3500.0;
  static const double _steadyFixMaxAccuracyMeters = 250.0;

  double _markerBaseIconSize() {
    final shortest = MediaQuery.of(context).size.shortestSide;

    // Smaller phones get a touch more scale, larger phones get less.
    final deviceFactor = (390.0 / shortest).clamp(0.90, 1.12);

    // Keep markers a bit tighter at low zoom so they do not swallow the map.
    final zoomFactor = _mapZoom <= 12.0
        ? 0.92
        : _mapZoom >= 15.0
            ? 1.0
            : 0.92 + ((_mapZoom - 12.0) / 3.0) * 0.08;

    return (0.58 * deviceFactor * zoomFactor).clamp(0.48, 0.66);
  }

  double _stackJoinRadiusMetersForZoom() {
    if (_mapZoom >= 15.2) return 0.0;
    if (_mapZoom >= 14.4) return 16.0;
    if (_mapZoom >= 13.5) return 28.0;
    return 48.0;
  }

  double _stackOffsetMetersForZoom() {
    if (_mapZoom >= _stackBreakZoom) return 0.0;
    if (_mapZoom >= 13.6) return 7.0;
    if (_mapZoom >= 12.8) return 11.0;
    return 15.0;
  }

  static const LatLng _neutralMapStart = LatLng(6.0, 12.0);

  bool get _showInitialMapLoading =>
      _loading || (_locationOk && _waitingForFirstUsableFix);
  bool get _showLocationSearchingPill =>
      _locationOk && !_showInitialMapLoading && _me == null; 

  Widget _buildLocationSearchingPill() {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(.78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                  backgroundColor: Colors.white.withOpacity(.12),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                "Still finding your location...",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }  

  Widget _buildInitialMapLoadingOverlay() {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(.78),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                  backgroundColor: Colors.white.withOpacity(.12),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                "Searching your location...",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  LatLng _stackOffsetPoint(LatLng anchor, int fromFront) {
    if (_mapZoom >= 15.2 || fromFront <= 0) return anchor;

    final level = fromFront.clamp(0, 3);

    // Tight fan like layered cards, not a spread-out circle.
    const bearings = <double>[
      0.0,   // front card stays on anchor
      318.0, // back card 1: up-left
      318.0, // back card 2: more up-left
      318.0, // back card 3: even more up-left
    ];

    final distances = _mapZoom >= 14.4
        ? <double>[0.0, 5.0, 9.0, 13.0]
        : <double>[0.0, 8.0, 14.0, 20.0];

    return _offsetLatLng(
      anchor,
      distances[level],
      bearings[level] * math.pi / 180.0,
    );
  }

  double _stackOpacity(int fromFront) {
    if (fromFront <= 0) return 1.0;
    if (fromFront == 1) return 0.96;
    if (fromFront == 2) return 0.92;
    return 0.88;
  }

  double? get _discoveryRadiusMeters {
    final miles = _discoveryRadiusMiles;
    if (miles == null || miles <= 0) return null;
    return miles * 1609.344;
  }

  final Map<String, _PingPreview> _pingById = {};

  late final Timer _expiryTimer;

  static const String _routeSourceId = "joined_ping_route_source";
  static const String _routeLayerId = "joined_ping_route_layer";

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _activePingSub;
  String? _activePingStatus;

  bool _routeLayerReady = false;
  Timer? _routeRefreshDebounce;
  Timer? _activePingClearDebounce;

  String? _activeJoinedPingId;
  _RouteUi? _routeUi;

  LatLng? _lastRouteFrom;
  LatLng? _lastRouteTo;
  int _routeTicket = 0;

  bool _statusBlocksRoute(String? status) {
    final s = (status ?? "").trim().toLowerCase();
    return s == "pending" ||
        s == "denied" ||
        s == "declined" ||
        s == "removed" ||
        s == "left" ||
        s == "cancelled";
  }

  bool _statusAllowsRoute(String? status) {
    final s = (status ?? "").trim().toLowerCase();
    return s == "approved" ||
        s == "joined" ||
        s == "member" ||
        s == "inside" ||
        s == "active";
  }

  Future<bool> _canDrawRouteToPing(String pingId) async {
    if (_statusAllowsRoute(_activePingStatus)) return true;
    if (_statusBlocksRoute(_activePingStatus)) return false;

    final uid = _myUid;
    if (uid == null || uid.isEmpty) return false;

    try {
      final partSnap = await FirebaseFirestore.instance
          .collection("pings")
          .doc(pingId)
          .collection("participants")
          .doc(uid)
          .get();

      if (!partSnap.exists) return false;

      final data = partSnap.data() ?? <String, dynamic>{};
      final status = (data["status"] ?? "").toString().trim().toLowerCase();

      return status == "approved" ||
          status == "joined" ||
          status == "member" ||
          status == "inside" ||
          status == "active";
    } catch (e) {
      debugPrint("❌ route participant check failed: $e");
      return false;
    }
  }

  Future<void> _clearPingSymbols() async {
    if (_map == null) return;

    for (final symbol in _symbolsByPingId.values) {
      try {
        await _map!.removeSymbol(symbol);
      } catch (_) {}
    }

    _symbolsByPingId.clear();
    _symbolImageKeyByPingId.clear();
  }

  Future<void> _clearEventSymbols() async {
    if (_map == null) return;

    for (final symbol in _symbolsByEventClusterId.values) {
      try {
        await _map!.removeSymbol(symbol);
      } catch (_) {}
    }

    _symbolsByEventClusterId.clear();
    _symbolImageKeyByEventClusterId.clear();
    _eventClusterById.clear();
  }

  Future<_PingPreview?> _loadRouteTargetPing(String pingId) async {
    final cached = _pingById[pingId];
    if (cached != null) return cached;

    try {
      final doc = await FirebaseFirestore.instance
          .collection("pings")
          .doc(pingId)
          .get();

      final data = doc.data();
      if (!doc.exists || data == null) return null;

      final loc = data["location"] as Map<String, dynamic>?;
      final gp = loc?["geopoint"] as GeoPoint?;
      if (gp == null) return null;

      final mapGp = loc?["mapGeopoint"] as GeoPoint?;
      final status = (data["status"] ?? "active").toString().trim().toLowerCase();
      final endsAt = (data["endsAt"] is Timestamp)
          ? (data["endsAt"] as Timestamp).toDate()
          : null;

      if (status != "active") return null;
      if (endsAt != null && endsAt.isBefore(DateTime.now())) return null;

      final preview = _PingPreview(
        id: doc.id,
        title: (data["title"] ?? "Ping").toString(),
        creatorId: (data["creatorId"] ?? "").toString(),
        exactAt: LatLng(gp.latitude, gp.longitude),
        mapAt: mapGp == null ? null : LatLng(mapGp.latitude, mapGp.longitude),
        accuracyRadiusMeters: (loc?["accuracyRadiusMeters"] is num)
            ? (loc!["accuracyRadiusMeters"] as num).toInt()
            : 250,
        category: (data["category"] ?? "").toString(),
        privacy: (data["privacy"] ?? "public").toString().trim().toLowerCase(),
        tags: (data["tags"] is List)
            ? (data["tags"] as List).map((e) => e.toString()).toList()
            : [],
        description: (data["description"] ?? "").toString(),
        participantCount: (data["participantCount"] is num)
            ? (data["participantCount"] as num).toInt()
            : 0,
        accuracyMode: (loc?["accuracyMode"] is num)
            ? (loc!["accuracyMode"] as num).toInt()
            : 1,
        placeName: (loc?["placeName"] ?? "Nearby").toString(),
        meetingPoint: (loc?["meetingPoint"] ?? "").toString(),
        status: status,
        createdAt: (data["createdAtLocal"] is Timestamp)
            ? (data["createdAtLocal"] as Timestamp).toDate()
            : null,
        startAt: (data["startAt"] is Timestamp)
            ? (data["startAt"] as Timestamp).toDate()
            : null,
        scheduledStartAt: (data["scheduledStartAt"] is Timestamp)
            ? (data["scheduledStartAt"] as Timestamp).toDate()
            : null,
        scheduledEndAt: (data["scheduledEndAt"] is Timestamp)
            ? (data["scheduledEndAt"] as Timestamp).toDate()
            : null,
        endsAt: endsAt,
        media: parsePingMedia(data["media"]),
        targetInterests: (data["targetInterests"] is List)
            ? (data["targetInterests"] as List).map((e) => e.toString()).toList()
            : const [],
        targetSkills: (data["targetSkills"] is List)
            ? (data["targetSkills"] as List).map((e) => e.toString()).toList()
            : const [],
        targetTerms: (data["targetTerms"] is List)
            ? (data["targetTerms"] as List).map((e) => e.toString()).toList()
            : const [],
        keywords: (data["keywords"] is List)
            ? (data["keywords"] as List).map((e) => e.toString()).toList()
            : const [],
      );

      _pingById[pingId] = preview;
      return preview;
    } catch (e) {
      debugPrint("❌ failed to load route target ping: $e");
      return null;
    }
  }

  PingVisibilityContext? _visibilityContext;
  bool _visibilityReady = false;

  bool _discoverVisible = true;
  bool _mapUiHidden = false;

  void _toggleMapUiHidden() {
    setState(() {
      _mapUiHidden = !_mapUiHidden;
    });
  }

  late final ScrollController _categoryParallaxController;
  late final ScrollController _tagParallaxController;

  bool _syncingParallax = false;

  final CreatePingDraft _createPingDraft = CreatePingDraft();

  Timer? _longPressTimer;
  Offset? _longPressStartOffset;
  LatLng? _longPressLatLng;
  static const double _longPressMoveThreshold = 20.0;

  double _hintOpacity = 1.0;
  Timer? _hintFadeTimer;

  String? _myUid;
  List<_PingPreview> _overlappingOwnPings = [];

  List<_RenderedPingMarker> _buildRenderedPingMarkers(
    List<_PingPreview> source,
  ) {
    final visible = <_PingPreview>[];

    for (final p in source) {
      final markerPoint = _markerPointFor(p);
      if (markerPoint == null) continue;
      visible.add(p);
    }

    if (visible.isEmpty) return const <_RenderedPingMarker>[];

    final joinRadius = _stackJoinRadiusMetersForZoom();

    if (joinRadius <= 0) {
      return visible.map((p) {
        final point = _markerPointFor(p)!;
        return _RenderedPingMarker(
          ping: p,
          position: point,
          opacity: 1.0,
        );
      }).toList();
    }

    final groups = <_MarkerStackGroup>[];

    for (final ping in visible) {
      final point = _markerPointFor(ping)!;

      _MarkerStackGroup? found;

      for (final g in groups) {
        final dist = Geolocator.distanceBetween(
          g.anchor.latitude,
          g.anchor.longitude,
          point.latitude,
          point.longitude,
        );

        if (dist <= joinRadius) {
          found = g;
          break;
        }
      }

      if (found == null) {
        groups.add(
          _MarkerStackGroup(anchor: point, items: [ping]),
        );
      } else {
        found.items.add(ping);
      }
    }

    final out = <_RenderedPingMarker>[];

    for (final group in groups) {
      if (group.items.length == 1) {
        out.add(
          _RenderedPingMarker(
            ping: group.items.first,
            position: group.anchor,
            opacity: 1.0,
          ),
        );
        continue;
      }

      final ordered = [...group.items]
        ..sort((a, b) {
          final ad = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return ad.compareTo(bd); // oldest first, newest ends up on top
        });

      for (int i = 0; i < ordered.length; i++) {
        final ping = ordered[i];
        final fromFront = (ordered.length - 1) - i;

        out.add(
          _RenderedPingMarker(
            ping: ping,
            position: _stackOffsetPoint(group.anchor, fromFront),
            opacity: _stackOpacity(fromFront),
          ),
        );
      }
    }

    return out;
  }

  bool _drawingMarkers = false;

  String _normalizeDiscoverCategory(String raw) {
    final c = raw.trim().toLowerCase();

    if (c.isEmpty) return "";

    if (c.contains("study")) return "study";
    if (c.contains("gym") || c.contains("fitness") || c.contains("workout")) {
      return "gym";
    }
    if (c.contains("gaming") || c.contains("game")) return "gaming";
    if (c.contains("network")) return "network";
    if (c.contains("help")) return "help";
    if (c.contains("support")) return "support";
    if (c.contains("event")) return "event";
    if (c.contains("hangout") || c.contains("hang out") || c.contains("chill")) {
      return "hangout";
    }
    if (c.contains("instant")) return "instant";
    if (c.contains("food") || c.contains("eat")) return "food";
    if (c.contains("music")) return "music";
    if (c.contains("sport")) return "sport";

    return c;
  }

  @override
  void initState() {
    super.initState();

    _categoryParallaxController = ScrollController();
    _tagParallaxController = ScrollController();

    _categoryParallaxController.addListener(_syncCategoryParallax);
    _tagParallaxController.addListener(_syncTagParallax);

    _expiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _sweepExpired(),
    );

    _boot();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _publicSub?.cancel();
    _verifiedSub?.cancel();
    _activePingSub?.cancel();

    for (final s in _friendSubs) {
      s.cancel();
    }

    _eventMineSub?.cancel();

    for (final s in _eventConnectionSubs) {
      s.cancel();
    }
    _eventConnectionSubs.clear();

    _expiryTimer.cancel();
    _longPressTimer?.cancel();
    _hintFadeTimer?.cancel();
    _routeRefreshDebounce?.cancel();
    _activePingClearDebounce?.cancel();
    _eventPublicSub?.cancel();
    _firstFixTimeout?.cancel();

    _categoryParallaxController
      ..removeListener(_syncCategoryParallax)
      ..dispose();

    _tagParallaxController
      ..removeListener(_syncTagParallax)
      ..dispose();

    _createPingDraft.dispose();
    super.dispose();
  }

  String _formatDiscoveryRadiusMiles(double miles) {
    if (miles <= 0) return "Off";

    if (miles >= 10 || miles == miles.roundToDouble()) {
      return "${miles.toStringAsFixed(0)} mi";
    }

    return "${miles.toStringAsFixed(1)} mi";
  }

  bool _isEventWithinDiscoveryRadius(_MapEventPreview e) {
    final me = _me;
    final radiusMeters = _discoveryRadiusMeters;

    if (me == null || radiusMeters == null) return true;

    final meters = Geolocator.distanceBetween(
      me.latitude,
      me.longitude,
      e.at.latitude,
      e.at.longitude,
    );

    return meters <= radiusMeters;
  }

  List<_RenderedEventCluster> _buildRenderedEventClusters(
    List<_MapEventPreview> source,
  ) {
    if (source.isEmpty) return const <_RenderedEventCluster>[];

    final joinRadius = _eventStackJoinRadiusMetersForZoom();
    final groups = <_EventMarkerStackGroup>[];

    for (final event in source) {
      final point = event.at;
      _EventMarkerStackGroup? found;

      for (final g in groups) {
        final dist = Geolocator.distanceBetween(
          g.anchor.latitude,
          g.anchor.longitude,
          point.latitude,
          point.longitude,
        );

        if (dist <= joinRadius) {
          found = g;
          break;
        }
      }

      if (found == null) {
        groups.add(
          _EventMarkerStackGroup(anchor: point, items: [event]),
        );
      } else {
        found.items.add(event);
      }
    }

    final out = <_RenderedEventCluster>[];

    for (final group in groups) {
      final ordered = [...group.items]
        ..sort((a, b) {
          final ad =
              a.createdAt ?? a.startsAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd =
              b.createdAt ?? b.startsAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bd.compareTo(ad); // newest first
        });

      final lead = ordered.first;
      final visibleCardCount = ordered.length >= 3 ? 3 : ordered.length;

      out.add(
        _RenderedEventCluster(
          id: _eventClusterIdFor(ordered),
          anchor: group.anchor,
          events: ordered,
          leadEvent: lead,
          visibleCardCount: visibleCardCount,
        ),
      );
    }

    return out;
  }

  Color _eventThemeColor(String themeId) {
    switch (themeId) {
      case "pink_nova":
        return const Color(0xFFE85ED5);
      case "violet_dusk":
        return const Color(0xFF8B5CF6);
      case "ocean_night":
        return const Color(0xFF3298FF);
      case "emerald_night":
        return const Color(0xFF16C784);
      case "sunset_blaze":
        return const Color(0xFFFF6B57);
      case "amber_smoke":
        return const Color(0xFFF0A827);
      case "berry_wave":
        return const Color(0xFFE95FAF);
      case "teal_ink":
        return const Color(0xFF21C7C9);
      default:
        return const Color(0xFFF39C12);
    }
  }

  final Map<String, String> _eventHostNameCache = {};

  Future<String> _loadEventHostName(String creatorId) async {
    final uid = creatorId.trim();
    if (uid.isEmpty) return "Pingmee user";

    final cached = _eventHostNameCache[uid];
    if (cached != null) return cached;

    try {
      final snap = await FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .get();

      final d = snap.data() ?? <String, dynamic>{};
      final fullName = (d["fullName"] ?? d["displayName"] ?? "Pingmee user")
          .toString()
          .trim();

      final value = fullName.isEmpty ? "Pingmee user" : fullName;
      _eventHostNameCache[uid] = value;
      return value;
    } catch (_) {
      return "Pingmee user";
    }
  }

  String _firstName(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r"\s+"))
        .where((e) => e.isNotEmpty)
        .toList();

    return parts.isEmpty ? "Host" : parts.first;
  }

  Future<void> _paintEventCoverIntoRRect({
    required Canvas canvas,
    required Rect rect,
    required RRect rrect,
    required _MapEventPreview event,
  }) async {
    final coverImage = await _loadEventCoverImage(event);

    if (coverImage != null) {
      canvas.save();
      canvas.clipRRect(rrect);
      paintImage(
        canvas: canvas,
        rect: rect,
        image: coverImage,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
      canvas.restore();
      return;
    }

    if (event.coverType == "gradient" && event.coverGradientColors.length >= 2) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.topLeft,
            rect.bottomRight,
            event.coverGradientColors,
          ),
      );
      return;
    }

    canvas.drawRRect(
      rrect,
      Paint()..color = event.coverColor,
    );
  }

  void _paintCenteredMarkerText({
    required Canvas canvas,
    required String text,
    required double top,
    required double maxWidth,
    required double canvasWidth,
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    int maxLines = 2,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: 1.05,
          shadows: const [
            Shadow(
              color: Color(0x66000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: "…",
    )..layout(maxWidth: maxWidth);

    painter.paint(
      canvas,
      Offset((canvasWidth - painter.width) / 2, top),
    );
  }

  Future<ui.Image?> _loadEventCoverImage(_MapEventPreview event) async {
    final cacheKey = event.coverImageUrl ??
        event.coverPresetAssetPath ??
        "none_${event.id}";

    final cached = _eventCoverImageCache[cacheKey];
    if (cached != null) return cached;

    Uint8List? bytes;

    try {
      if (event.coverType == "uploaded" &&
          event.coverImageUrl != null &&
          event.coverImageUrl!.isNotEmpty) {
        final cachedBytes = _eventCoverBytesCache[event.coverImageUrl!];
        if (cachedBytes != null) {
          bytes = cachedBytes;
        } else {
          final res = await http.get(Uri.parse(event.coverImageUrl!));
          if (res.statusCode == 200) {
            bytes = res.bodyBytes;
            _eventCoverBytesCache[event.coverImageUrl!] = bytes;
          }
        }
      } else if (event.coverType == "preset" &&
          event.coverPresetAssetPath != null &&
          event.coverPresetAssetPath!.isNotEmpty) {
        final data = await rootBundle.load(event.coverPresetAssetPath!);
        bytes = data.buffer.asUint8List();
      }

      if (bytes == null || bytes.isEmpty) return null;

      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 220,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      _eventCoverImageCache[cacheKey] = image;
      return image;
    } catch (e) {
      debugPrint("❌ event cover load failed: $e");
      return null;
    }
  }

  double _eventStackJoinRadiusMetersForZoom() {
    if (_mapZoom >= 15.2) return 0.0;
    if (_mapZoom >= 14.4) return 8.0;
    if (_mapZoom >= 13.5) return 12.0;
    return 16.0;
  }

  double _crossTypeCollisionRadiusMetersForZoom() {
    if (_mapZoom >= 15.2) return 12.0;
    if (_mapZoom >= 14.4) return 18.0;
    if (_mapZoom >= 13.5) return 26.0;
    return 36.0;
  }

  double _crossTypeEventNudgeMetersForZoom() {
    if (_mapZoom >= 15.2) return 16.0;
    if (_mapZoom >= 14.4) return 24.0;
    if (_mapZoom >= 13.5) return 34.0;
    return 46.0;
  }

  bool _isNearLatLng(
    LatLng a,
    LatLng b,
    double radiusMeters,
  ) {
    final meters = Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    return meters <= radiusMeters;
  }

  List<LatLng> _currentRenderedPingPositions() {
    final now = DateTime.now();

    final mapPings = _pingById.values
        .where(_isWithinDiscoveryRadius)
        .where((p) => p.endsAt == null || !p.endsAt!.isBefore(now))
        .toList();

    final rendered = _buildRenderedPingMarkers(mapPings);
    return rendered.map((e) => e.position).toList();
  }

  Map<String, LatLng> _resolveEventClusterAnchorsAgainstPings(
    List<_RenderedEventCluster> clusters,
  ) {
    final out = <String, LatLng>{};

    if (_markerFilter != _MapMarkerFilter.all || !_showPings || !_showEvents) {
      for (final cluster in clusters) {
        out[cluster.id] = cluster.anchor;
      }
      return out;
    }

    final pingPositions = _currentRenderedPingPositions();
    if (pingPositions.isEmpty) {
      for (final cluster in clusters) {
        out[cluster.id] = cluster.anchor;
      }
      return out;
    }

    final collisionRadius = _crossTypeCollisionRadiusMetersForZoom();
    final nudgeMeters = _crossTypeEventNudgeMetersForZoom();

    const slotBearingsDeg = <double>[
      36.0,   // up-right
      0.0,    // right
      72.0,   // stronger up-right
      324.0,  // down-right
      108.0,  // up-left fallback
    ];

    final occupied = <LatLng>[
      ...pingPositions,
    ];

    for (final cluster in clusters) {
      LatLng chosen = cluster.anchor;

      final collidesWithPing = pingPositions.any(
        (p) => _isNearLatLng(cluster.anchor, p, collisionRadius),
      );

      if (!collidesWithPing) {
        out[cluster.id] = chosen;
        occupied.add(chosen);
        continue;
      }

      bool placed = false;

      for (int i = 0; i < slotBearingsDeg.length; i++) {
        final candidate = _offsetLatLng(
          cluster.anchor,
          nudgeMeters + (i >= 2 ? 8.0 : 0.0),
          slotBearingsDeg[i] * math.pi / 180.0,
        );

        final clashes = occupied.any(
          (other) => _isNearLatLng(candidate, other, collisionRadius * 0.92),
        );

        if (!clashes) {
          chosen = candidate;
          placed = true;
          break;
        }
      }

      if (!placed) {
        chosen = _offsetLatLng(
          cluster.anchor,
          nudgeMeters,
          36.0 * math.pi / 180.0,
        );
      }

      out[cluster.id] = chosen;
      occupied.add(chosen);
    }

    return out;
  }

  LatLng _eventStackOffsetPoint(LatLng anchor, int fromFront) {
    if (_mapZoom >= 15.2 || fromFront <= 0) return anchor;

    final level = fromFront.clamp(0, 3);

    final distances = _mapZoom >= 14.4
        ? <double>[0.0, 9.0, 16.0, 23.0]
        : <double>[0.0, 13.0, 22.0, 31.0];

    const bearings = <double>[
      0.0,   // front stays in place
      318.0, // back card 1
      318.0, // back card 2
      318.0, // back card 3
    ];

    return _offsetLatLng(
      anchor,
      distances[level],
      bearings[level] * math.pi / 180.0,
    );
  }

  String _eventClusterIdFor(List<_MapEventPreview> events) {
    final ids = events.map((e) => e.id).toList()..sort();
    return "event_cluster_${ids.join('_').hashCode.abs()}";
  }

  String _getEventMarkerImageName(
    _MapEventPreview event,
    double opacity, {
    required bool compactBackCard,
  }) {
    final opacityInt = (opacity * 100).round();

    final coverSig = [
      event.coverType,
      event.coverImageUrl ?? "",
      event.coverPresetAssetPath ?? "",
      event.coverGradientColors.map((c) => c.value).join("_"),
      event.coverColor.value,
      event.title,
      compactBackCard ? "back" : "front",
    ].join("|").hashCode.abs();

    return "event_card_${event.id}_${coverSig}_o${opacityInt}_v2";
  }

  Future<Uint8List> _renderEventCardMarker(
    _MapEventPreview event, {
    required double opacity,
    required bool compactBackCard,
  }) async {
    if (compactBackCard) {
      const double canvasW = 132;
      const double canvasH = 132;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, canvasW, canvasH),
      );

      final rect = const Rect.fromLTWH(7, 7, 118, 118);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(20));

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(const Offset(0, 5)),
          const Radius.circular(20),
        ),
        Paint()
          ..color = Colors.black.withOpacity(.16 * opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );

      await _paintEventCoverIntoRRect(
        canvas: canvas,
        rect: rect,
        rrect: rrect,
        event: event,
      );

      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.white.withOpacity(opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7,
      );

      final picture = recorder.endRecording();
      final image = await picture.toImage(canvasW.toInt(), canvasH.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    }

    const double canvasW = 220;
    const double canvasH = 220;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, canvasW, canvasH),
    );

    const Rect coverRect = Rect.fromLTWH(41, 6, 138, 138);
    final coverRRect = RRect.fromRectAndRadius(
      coverRect,
      const Radius.circular(22),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        coverRect.shift(const Offset(0, 6)),
        const Radius.circular(22),
      ),
      Paint()
        ..color = Colors.black.withOpacity(.18 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    await _paintEventCoverIntoRRect(
      canvas: canvas,
      rect: coverRect,
      rrect: coverRRect,
      event: event,
    );

    canvas.drawRRect(
      coverRRect,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );

    _paintCenteredMarkerText(
      canvas: canvas,
      text: event.title,
      top: 152,
      maxWidth: 204,
      canvasWidth: canvasW,
      fontSize: 25,
      fontWeight: FontWeight.w900,
      color: Colors.white.withOpacity(opacity),
      maxLines: 2,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW.toInt(), canvasH.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  String _getEventClusterMarkerImageName(_RenderedEventCluster cluster) {
    final visible = cluster.events.take(math.min(cluster.visibleCardCount, 3)).toList();

    final sig = visible.map((e) {
      return [
        e.id,
        e.creatorId,
        e.coverType,
        e.coverImageUrl ?? "",
        e.coverPresetAssetPath ?? "",
        e.coverGradientColors.map((c) => c.value).join("_"),
        e.coverColor.value,
        e.title,
      ].join("|");
    }).join("||").hashCode.abs();

    return "event_cluster_${cluster.id}_${sig}_v2";
  }

  Future<Uint8List> _renderEventClusterMarker(
    _RenderedEventCluster cluster,
  ) async {
    const double canvasW = 252;
    const double canvasH = 224;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, canvasW, canvasH),
    );

    final visible = cluster.events.take(math.min(cluster.visibleCardCount, 3)).toList();

    final rects = <Rect>[
      const Rect.fromLTWH(18, 38, 94, 94),
      const Rect.fromLTWH(56, 18, 108, 108),
      const Rect.fromLTWH(108, 4, 122, 122),
    ];

    final start = rects.length - visible.length;

    for (int i = 0; i < visible.length; i++) {
      final event = visible[i];
      final rect = rects[start + i];
      final rrect = RRect.fromRectAndRadius(
        rect,
        Radius.circular(i == visible.length - 1 ? 22 : 19),
      );

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.shift(const Offset(0, 6)),
          Radius.circular(i == visible.length - 1 ? 22 : 19),
        ),
        Paint()
          ..color = Colors.black.withOpacity(.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );

      await _paintEventCoverIntoRRect(
        canvas: canvas,
        rect: rect,
        rrect: rrect,
        event: event,
      );

      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7,
      );
    }

    final leadHostFull = await _loadEventHostName(cluster.leadEvent.creatorId);
    final leadHost = _firstName(leadHostFull);

    final text = cluster.events.length <= 1
        ? cluster.leadEvent.title
        : "$leadHost +${cluster.events.length - 1} others";

    _paintCenteredMarkerText(
      canvas: canvas,
      text: text,
      top: 148,
      maxWidth: 228,
      canvasWidth: canvasW,
      fontSize: cluster.events.length <= 1 ? 25 : 23,
      fontWeight: FontWeight.w900,
      color: Colors.white,
      maxLines: 2,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW.toInt(), canvasH.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<String> _ensureEventClusterMarkerImageExists(
    _RenderedEventCluster cluster,
  ) async {
    if (_map == null) return "marker_default";

    if (!cluster.isMulti) {
      return _ensureEventMarkerImageExists(
        event: cluster.leadEvent,
        opacity: 1.0,
        compactBackCard: false,
      );
    }

    final imageName = _getEventClusterMarkerImageName(cluster);

    if (_loadedMarkerImages.contains(imageName)) {
      return imageName;
    }

    try {
      final rendered = await _renderEventClusterMarker(cluster);
      await _map!.addImage(imageName, rendered);
      _loadedMarkerImages.add(imageName);
      return imageName;
    } catch (e) {
      debugPrint("❌ Failed to render event cluster marker: $e");
      return "marker_default";
    }
  }

  Future<void> _forceRefreshMyLocation() async {
    if (!mounted || _isRefreshingMyLocation) return;

    setState(() => _isRefreshingMyLocation = true);

    try {
      Position? pos;

      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 12));
      } on TimeoutException {
        debugPrint("⚠️ force refresh timed out, trying last known");
      }

      pos ??= await Geolocator.getLastKnownPosition();
      if (pos == null) return;

      if (pos.accuracy.isFinite && pos.accuracy > 3500.0) {
        debugPrint("🛑 force refresh rejected: poor accuracy ${pos.accuracy}m");
        return;
      }

      final fresh = LatLng(pos.latitude, pos.longitude);

      _lastAcceptedLocation = fresh;
      _lastAcceptedLocationAt = pos.timestamp.toLocal();

      if (mounted) {
        setState(() {
          _me = fresh;
          _waitingForFirstUsableFix = false;
          _loading = false;
        });
      }

      await _moveToMe();
      await _refreshUserMarker();
      await _refreshDiscoveryRadiusCircle();
      await _refreshDiscoveryRadiusTag();
      await _drawAllMapMarkers();
      _rebuildNearby();
      await _refreshJoinedPingRoute(force: true);
    } catch (e) {
      debugPrint("❌ force refresh location failed: $e");
    } finally {
      if (mounted) {
        setState(() => _isRefreshingMyLocation = false);
      }
    }
  }

  Widget _buildRefreshLocationButton() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 10, right: 14),
        child: Align(
          alignment: Alignment.topRight,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isRefreshingMyLocation ? null : _forceRefreshMyLocation,
              borderRadius: BorderRadius.circular(16),
              child: Ink(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.84),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(.08)),
                ),
                child: Center(
                  child: _isRefreshingMyLocation
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(Colors.white),
                            backgroundColor: Colors.white.withOpacity(.14),
                          ),
                        )
                      : Icon(
                          PhosphorIcons.arrowClockwise(
                            PhosphorIconsStyle.bold,
                          ),
                          color: Colors.white,
                          size: 20,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<_MapEventPreview?> _loadEventById(String eventId) async {
    final cached = _eventById[eventId];
    if (cached != null) return cached;

    try {
      final doc = await FirebaseFirestore.instance
          .collection("events")
          .doc(eventId)
          .get();

      if (!doc.exists) return null;

      final preview = _eventPreviewFromDoc(doc);
      if (preview == null) return null;

      _eventById[eventId] = preview;

      if (_mapReady && _markersReady) {
        await _drawEventMarkers();
      }

      return preview;
    } catch (e) {
      debugPrint("❌ failed to load event by id: $e");
      return null;
    }
  }

  Future<void> focusEventAndOpen(String eventId) async {
    if (_map == null) return;

    await Future.delayed(const Duration(milliseconds: 120));

    var event = await _loadEventById(eventId);

    if (event == null) {
      await refreshEventMarkersOnly();
      await Future.delayed(const Duration(milliseconds: 180));
      event = await _loadEventById(eventId);
    }

    if (event == null) {
      debugPrint("❌ focusEventAndOpen: event not found $eventId");
      return;
    }

    try {
      final targetZoom = _mapZoom < 14.8 ? 14.8 : _mapZoom;
      await _map!.animateCamera(
        CameraUpdate.newLatLngZoom(event.at, targetZoom),
      );
    } catch (e) {
      debugPrint("❌ animate to event failed: $e");
    }

    await Future.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;

    if (_discoverVisible) {
      _showMapOnly();
      await Future.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
    }

    _openEventPreview(event);
  }

  Future<String> _ensureEventMarkerImageExists({
    required _MapEventPreview event,
    required double opacity,
    required bool compactBackCard,
  }) async {
    if (_map == null) return "marker_default";

    final imageName = _getEventMarkerImageName(
      event,
      opacity,
      compactBackCard: compactBackCard,
    );

    if (_loadedMarkerImages.contains(imageName)) {
      return imageName;
    }

    try {
      final rendered = await _renderEventCardMarker(
        event,
        opacity: opacity,
        compactBackCard: compactBackCard,
      );
      await _map!.addImage(imageName, rendered);
      _loadedMarkerImages.add(imageName);
      return imageName;
    } catch (e) {
      debugPrint("❌ Failed to render event card marker: $e");
      return "marker_default";
    }
  }

  Future<void> _drawEventMarkers() async {
    if (_map == null) return;
    if (_drawingEventMarkers) return;

    _drawingEventMarkers = true;

    try {
      final now = DateTime.now();

      final mapEvents = _eventById.values
          .where(_isEventWithinDiscoveryRadius)
          .where((e) => e.endsAt == null || !e.endsAt!.isBefore(now))
          .toList();

      final rendered = _buildRenderedEventClusters(mapEvents);
      final resolvedAnchors = _resolveEventClusterAnchorsAgainstPings(rendered);
      final currentIds = rendered.map((e) => e.id).toSet();

      final toRemove = _symbolsByEventClusterId.keys
          .where((id) => !currentIds.contains(id))
          .toList();

      for (final id in toRemove) {
        try {
          await _map!.removeSymbol(_symbolsByEventClusterId[id]!);
        } catch (_) {}
        _symbolsByEventClusterId.remove(id);
        _symbolImageKeyByEventClusterId.remove(id);
        _eventClusterById.remove(id);
      }

      final baseIconSize = (_markerBaseIconSize() + 0.02).clamp(0.52, 0.64);

      for (final cluster in rendered) {
        final markerImage = await _ensureEventClusterMarkerImageExists(cluster);
        final existing = _symbolsByEventClusterId[cluster.id];
        _eventClusterById[cluster.id] = cluster;

        if (existing == null) {
          final symbol = await _map!.addSymbol(
            SymbolOptions(
              geometry: resolvedAnchors[cluster.id] ?? cluster.anchor,
              iconImage: markerImage,
              iconSize: baseIconSize,
              iconAnchor: "bottom",
            ),
          );
          _symbolsByEventClusterId[cluster.id] = symbol;
          _symbolImageKeyByEventClusterId[cluster.id] = markerImage;
        } else {
          final lastImage = _symbolImageKeyByEventClusterId[cluster.id];
          await _map!.updateSymbol(
            existing,
            SymbolOptions(
              geometry: resolvedAnchors[cluster.id] ?? cluster.anchor,
              iconImage: lastImage == markerImage ? null : markerImage,
              iconSize: baseIconSize,
              iconAnchor: "bottom",
            ),
          );
          _symbolImageKeyByEventClusterId[cluster.id] = markerImage;
        }
      }
    } finally {
      _drawingEventMarkers = false;
    }
  }

  void _applyDiscoveryRadiusFromUserData(
    Map<String, dynamic> data, {
    bool forceRefresh = false,
  }) {
    final raw = data["distanceMiles"];
    final next = (raw is num && raw > 0) ? raw.toDouble() : null;

    final changed = _discoveryRadiusMiles != next;
    _discoveryRadiusMiles = next;

    if (!changed && !forceRefresh) return;

    if (mounted) {
      _rebuildNearby();
    }

    unawaited(_syncDiscoveryRadiusOverlay());
  }

  Future<void> _drawAllMapMarkers() async {
    if (_showPings) {
      await _drawPingMarkers();
    } else {
      await _clearPingSymbols();
    }

    if (_showEvents) {
      await _drawEventMarkers();
    } else {
      await _clearEventSymbols();
    }
  }

  Future<void> _setMarkerFilter(_MapMarkerFilter value) async {
    if (_markerFilter == value) return;

    setState(() {
      _markerFilter = value;
    });

    if (_mapReady && _markersReady) {
      await _drawAllMapMarkers();
    }
  }

  bool _isWithinDiscoveryRadius(_PingPreview p) {
    if (p.id == _activeJoinedPingId) return true;

    final me = _me;
    final radiusMeters = _discoveryRadiusMeters;

    if (me == null || radiusMeters == null) return true;

    final meters = Geolocator.distanceBetween(
      me.latitude,
      me.longitude,
      p.at.latitude,
      p.at.longitude,
    );

    return meters <= radiusMeters;
  }

  String _radiusTagText() {
    final miles = _discoveryRadiusMiles;
    if (miles == null) return "Your set discovery radius";
    return "Your set discovery radius • ${_formatDiscoveryRadiusMiles(miles)}les";
  }

  LatLng _radiusTagAnchor({
    required LatLng center,
    required double radiusM,
  }) {
    // Top-right edge of the circle.
    const bearingDeg = 332.0;

    // Small outward push so it sits just above the border.
    final extraMeters = math.max(24.0, math.min(80.0, radiusM * 0.015));

    return _offsetLatLng(
      center,
      radiusM + extraMeters,
      bearingDeg * math.pi / 180.0,
    );
  }

  void _syncCategoryParallax() {
    if (_syncingParallax) return;
    if (!_categoryParallaxController.hasClients) return;
    if (!_tagParallaxController.hasClients) return;

    final target = (_categoryParallaxController.offset * 0.62).clamp(
      0.0,
      _tagParallaxController.position.maxScrollExtent,
    );

    if ((_tagParallaxController.offset - target).abs() < 1.0) return;

    _syncingParallax = true;
    _tagParallaxController.jumpTo(target);
    _syncingParallax = false;
  }

  Future<void> _onCameraIdle() async {
    if (_map == null) return;

    try {
      final pos = _map!.cameraPosition ?? await _map!.queryCameraPosition();
      final nextZoom = pos?.zoom;
      if (nextZoom == null) return;

      if ((nextZoom - _mapZoom).abs() < 0.04) return;

      _mapZoom = nextZoom;

      if (_mapReady && _markersReady) {
        await _drawAllMapMarkers();
      }
    } catch (e) {
      debugPrint("❌ _onCameraIdle: $e");
    }
  }

  void _syncTagParallax() {
    if (_syncingParallax) return;
    if (!_categoryParallaxController.hasClients) return;
    if (!_tagParallaxController.hasClients) return;

    final target = (_tagParallaxController.offset / 0.62).clamp(
      0.0,
      _categoryParallaxController.position.maxScrollExtent,
    );

    if ((_categoryParallaxController.offset - target).abs() < 1.0) return;

    _syncingParallax = true;
    _categoryParallaxController.jumpTo(target);
    _syncingParallax = false;
  }

  void _toggleDiscoverCategory(String value) {
    final normalized = _normalizeDiscoverCategory(value);
    if (normalized.isEmpty) return;

    setState(() {
      if (_selectedDiscoverCategory == normalized) {
        _selectedDiscoverCategory = null;
      } else {
        _selectedDiscoverCategory = normalized;
      }
    });
  }

  void _toggleDiscoverTag(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return;

    final normalized = cleaned.startsWith('#')
        ? cleaned.toLowerCase()
        : '#${cleaned.toLowerCase()}';

    setState(() {
      if (_selectedDiscoverTags.contains(normalized)) {
        _selectedDiscoverTags.remove(normalized);
      } else {
        _selectedDiscoverTags.add(normalized);
      }
    });
  }
  
  List<_PingPreview> _discoverUniversePings() {
    final list = _pingById.values
        .where(_isWithinDiscoveryRadius)
        .where((p) => p.status == "active")
        .toList();

    if (_me != null) {
      list.sort((a, b) {
        final da = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          a.at.latitude,
          a.at.longitude,
        );
        final db = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          b.at.latitude,
          b.at.longitude,
        );
        return da.compareTo(db);
      });
    }

    return list;
  }

  Future<_ViewerDiscoverProfile> _loadViewerDiscoverProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const _ViewerDiscoverProfile(interests: [], skills: []);
    }

    try {
      final snap = await FirebaseFirestore.instance
          .collection("users")
          .doc(uid)
          .get();

      final data = snap.data() ?? <String, dynamic>{};

      return _ViewerDiscoverProfile(
        interests: List<String>.from(data["interests"] ?? const []),
        skills: List<String>.from(data["skills"] ?? const []),
      );
    } catch (_) {
      return const _ViewerDiscoverProfile(interests: [], skills: []);
    }
  }

  bool _matchesDiscoverFilters(_PingPreview p) {
    final selectedCategory = _selectedDiscoverCategory;
    if (selectedCategory != null) {
      final pingCategory = _normalizeDiscoverCategory(p.category);
      if (pingCategory != selectedCategory) {
        return false;
      }
    }

    if (_selectedDiscoverTags.isNotEmpty) {
      final pingTags = p.tags
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .map((e) => e.startsWith('#') ? e : '#$e')
          .toSet();

      for (final tag in _selectedDiscoverTags) {
        if (!pingTags.contains(tag)) return false;
      }
    }

    return true;
  }

  void _clearDiscoverFilters() {
    setState(() {
      _selectedDiscoverCategory = null;
      _selectedDiscoverTags.clear();
    });
  }

  List<_PingPreview> _computeOverlappingOwnPings() {
    final me = _me;
    final myUid = _myUid;

    if (me == null || myUid == null || myUid.isEmpty) {
      return const <_PingPreview>[];
    }

    final now = DateTime.now();

    final items = _pingById.values.where((p) {
      if (p.creatorId != myUid) return false;
      if (p.status != "active") return false;
      if (p.endsAt != null && p.endsAt!.isBefore(now)) return false;

      final markerPoint = _markerPointFor(p);
      if (markerPoint == null) return false;

      final meters = Geolocator.distanceBetween(
        me.latitude,
        me.longitude,
        markerPoint.latitude,
        markerPoint.longitude,
      );

      return meters <= 65;
    }).toList();

    items.sort((a, b) {
      final pa = _markerPointFor(a) ?? a.exactAt;
      final pb = _markerPointFor(b) ?? b.exactAt;

      final da = Geolocator.distanceBetween(
        me.latitude,
        me.longitude,
        pa.latitude,
        pa.longitude,
      );
      final db = Geolocator.distanceBetween(
        me.latitude,
        me.longitude,
        pb.latitude,
        pb.longitude,
      );
      return da.compareTo(db);
    });

    return items;
  }

  Future<Uint8List> _renderRadiusTagMarker(String label) async {
    final recorder = ui.PictureRecorder();
    const double padH = 14;
    const double padV = 10;
    const double radius = 16;
    const double dotSize = 9;
    const double tailW = 12;
    const double tailH = 8;

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontFamily: "Nunito",
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bubbleW = padH * 2 + dotSize + 10 + textPainter.width;
    final bubbleH = padV * 2 + math.max(dotSize, textPainter.height);
    final canvasW = bubbleW + 12;
    final canvasH = bubbleH + tailH + 8;

    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, canvasW, canvasH),
    );

    final left = (canvasW - bubbleW) / 2;
    const top = 0.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top + 3, bubbleW, bubbleH),
        const Radius.circular(radius),
      ),
      Paint()
        ..color = Colors.black.withOpacity(.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, bubbleW, bubbleH),
        const Radius.circular(radius),
      ),
      Paint()..color = const Color(0xFF1A1A2E),
    );

    final dotCx = left + padH + dotSize / 2;
    final dotCy = top + bubbleH / 2;
    canvas.drawCircle(
      Offset(dotCx, dotCy),
      dotSize / 2,
      Paint()..color = AppColors.brandGreen,
    );

    textPainter.paint(
      canvas,
      Offset(
        left + padH + dotSize + 10,
        top + (bubbleH - textPainter.height) / 2,
      ),
    );

    final centerX = canvasW / 2;
    final tailPath = Path()
      ..moveTo(centerX - tailW / 2, bubbleH)
      ..lineTo(centerX + tailW / 2, bubbleH)
      ..lineTo(centerX, bubbleH + tailH)
      ..close();

    canvas.drawPath(
      tailPath,
      Paint()..color = const Color(0xFF1A1A2E),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW.toInt(), canvasH.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<void> _clearDiscoveryRadiusTag() async {
    if (_map != null && _radiusTagSymbol != null) {
      try {
        await _map!.removeSymbol(_radiusTagSymbol!);
      } catch (_) {}
    }
    _radiusTagSymbol = null;
    _radiusTagImageKey = null;
  }

  Future<void> _refreshDiscoveryRadiusTag() async {
    if (_map == null || !_styleLoaded) return;

    final center = _me;
    final radiusM = _discoveryRadiusMeters;

    debugPrint("🟢 radius refresh => me=$center radiusM=$radiusM styleLoaded=$_styleLoaded layerReady=$_radiusLayerReady");

    if (center == null || radiusM == null || radiusM <= 0) {
      await _clearDiscoveryRadiusTag();
      return;
    }

    final label = _radiusTagText();
    final key = "radius_tag_${label.hashCode.abs()}";

    if (!_loadedMarkerImages.contains(key)) {
      final bytes = await _renderRadiusTagMarker(label);
      await _map!.addImage(key, bytes);
      _loadedMarkerImages.add(key);
    }

    final anchor = _radiusTagAnchor(center: center, radiusM: radiusM);

    if (_radiusTagSymbol == null) {
      _radiusTagSymbol = await _map!.addSymbol(
        SymbolOptions(
          geometry: anchor,
          iconImage: key,
          iconSize: 0.82,
          iconAnchor: "bottom",
        ),
      );
    } else {
      await _map!.updateSymbol(
        _radiusTagSymbol!,
        SymbolOptions(
          geometry: anchor,
          iconImage: _radiusTagImageKey == key ? null : key,
          iconSize: 0.82,
          iconAnchor: "bottom",
        ),
      );
    }

    _radiusTagImageKey = key;
  }

  Widget _topMapActionButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(.88),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.22),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              icon,
              size: 21,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _ensureDiscoveryRadiusLayer() async {
    if (_map == null || !_styleLoaded || _radiusLayerReady) return;

    if (_radiusLayerInitFuture != null) {
      await _radiusLayerInitFuture;
      return;
    }

    _radiusLayerInitFuture = () async {
      try {
        await _map!.addGeoJsonSource(_radiusSourceId, _emptyRadiusGeoJson());

        await _map!.addFillLayer(
          _radiusSourceId,
          _radiusFillLayerId,
          FillLayerProperties(
            fillColor: "#22C55E",
            fillOpacity: 0.10,
          ),
          enableInteraction: false,
        );

        await _map!.addLineLayer(
          _radiusSourceId,
          _radiusOutlineLayerId,
          LineLayerProperties(
            lineColor: "#22C55E",
            lineWidth: 2.0,
            lineOpacity: 0.85,
          ),
          enableInteraction: false,
        );

        _radiusLayerReady = true;
      } finally {
        _radiusLayerInitFuture = null;
      }
    }();

    await _radiusLayerInitFuture;
  }

  Map<String, dynamic> _emptyRadiusGeoJson() {
    return {
      "type": "FeatureCollection",
      "features": <dynamic>[],
    };
  }

  Future<void> _refreshDiscoveryRadiusCircle() async {
    if (_map == null || !_styleLoaded) return;

    await _ensureDiscoveryRadiusLayer();

    final center = _me;
    final radiusM = _discoveryRadiusMeters;

    if (center == null || radiusM == null || radiusM <= 0) {
      if (_radiusLayerReady) {
        try {
          await _map!.setGeoJsonSource(_radiusSourceId, _emptyRadiusGeoJson());
        } catch (_) {}
      }
      return;
    }

    try {
      await _map!.setGeoJsonSource(
        _radiusSourceId,
        _radiusGeoJson(center: center, radiusM: radiusM),
      );
    } catch (e) {
      debugPrint("❌ failed to refresh discovery radius: $e");
    }
  }

  Map<String, dynamic> _radiusGeoJson({
    required LatLng center,
    required double radiusM,
    int steps = 72,
  }) {
    final ring = <List<double>>[];

    for (int i = 0; i <= steps; i++) {
      final bearing = (2 * math.pi * i) / steps;
      final point = _offsetLatLng(center, radiusM, bearing);
      ring.add([point.longitude, point.latitude]);
    }

    return {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "properties": {},
          "geometry": {
            "type": "Polygon",
            "coordinates": [ring],
          },
        }
      ],
    };
  }

  Widget _buildMarkerFilterBar() {
    Widget chip({
      required String label,
      required _MapMarkerFilter value,
    }) {
      final selected = _markerFilter == value;

      return GestureDetector(
        onTap: () => _setMarkerFilter(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : const Color(0xFF101418).withOpacity(.82),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? Colors.white
                  : Colors.white.withOpacity(.10),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(.16),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.black : Colors.white,
            ),
          ),
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              chip(label: "All", value: _MapMarkerFilter.all),
              const SizedBox(width: 8),
              chip(label: "Pings", value: _MapMarkerFilter.pings),
              const SizedBox(width: 8),
              chip(label: "Events", value: _MapMarkerFilter.events),
            ],
          ),
        ),
      ),
    );
  }

  LatLng _offsetLatLng(LatLng start, double meters, double bearingRad) {
    const earthRadius = 6371000.0;

    final angularDistance = meters / earthRadius;
    final lat1 = start.latitude * math.pi / 180.0;
    final lon1 = start.longitude * math.pi / 180.0;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) *
              math.sin(angularDistance) *
              math.cos(bearingRad),
    );

    final lon2 = lon1 +
        math.atan2(
          math.sin(bearingRad) *
              math.sin(angularDistance) *
              math.cos(lat1),
          math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
        );

    return LatLng(
      lat2 * 180.0 / math.pi,
      lon2 * 180.0 / math.pi,
    );
  }

  int _stableSeedFromString(String input) {
    var hash = 0x811C9DC5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash & 0x7fffffff;
  }

  double _seedUnit(int seed, int salt) {
    final mixed = (seed ^ (salt * 0x9E3779B9)) & 0x7fffffff;
    return mixed / 0x7fffffff;
  }

  LatLng _buildDeterministicApproxPoint({
    required String pingId,
    required LatLng exactAt,
    required int radiusMeters,
  }) {
    final safeRadius = math.max(120, radiusMeters);
    final seed = _stableSeedFromString(pingId);

    final bearing = _seedUnit(seed, 11) * 2 * math.pi;
    final distanceMeters =
        math.max(70.0, safeRadius * (0.38 + (_seedUnit(seed, 23) * 0.47)));

    return _offsetLatLng(exactAt, distanceMeters, bearing);
  }

  LatLng? _markerPointFor(_PingPreview p) {
    if (p.accuracyMode == 0) {
      // Hidden from everyone except creator.
      return p.creatorId == _myUid ? p.exactAt : null;
    }

    if (p.mapAt != null) return p.mapAt;

    if (p.accuracyMode == 1) {
      return _buildDeterministicApproxPoint(
        pingId: p.id,
        exactAt: p.exactAt,
        radiusMeters: p.accuracyRadiusMeters,
      );
    }

    return p.exactAt;
  }

  void _startActivePingWatch() {
    final uid = _myUid;
    if (uid == null) return;

    _activePingSub?.cancel();
    _activePingSub = FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .snapshots()
        .listen((snap) {
      final data = snap.data() ?? <String, dynamic>{};

      final nextPingId = (data["activePingId"] ?? "").toString().trim();
      final nextStatus = (data["activePingStatus"] ?? "").toString().trim();

      _applyDiscoveryRadiusFromUserData(data);

      if (nextPingId.isEmpty) {
        _activePingClearDebounce?.cancel();
        _activePingClearDebounce = Timer(const Duration(milliseconds: 1200), () {
          _activeJoinedPingId = null;
          _activePingStatus = null;
          _scheduleJoinedPingRouteRefresh(force: true);
        });
        return;
      }

      _activePingClearDebounce?.cancel();
      _activeJoinedPingId = nextPingId;
      _activePingStatus = nextStatus.isEmpty ? null : nextStatus;

      _scheduleJoinedPingRouteRefresh(force: true);
    });
  }
  
  void _scheduleJoinedPingRouteRefresh({bool force = false}) {
    if (!_mapReady || !_styleLoaded) return;

    _routeRefreshDebounce?.cancel();

    if (force) {
      _refreshJoinedPingRoute(force: true);
      return;
    }

    _routeRefreshDebounce = Timer(const Duration(milliseconds: 650), () {
      _refreshJoinedPingRoute();
    });
  }

  Future<void> _ensureRouteLayer() async {
    if (_map == null || !_styleLoaded || _routeLayerReady) return;

    if (_routeLayerInitFuture != null) {
      await _routeLayerInitFuture;
      return;
    }

    _routeLayerInitFuture = () async {
      try {
        await _map!.addGeoJsonSource(_routeSourceId, _emptyRouteGeoJson());
        await _map!.addLineLayer(
          _routeSourceId,
          _routeLayerId,
          LineLayerProperties(
            lineColor: "#22C55E",
            lineWidth: 5.5,
            lineOpacity: 0.92,
            lineCap: "round",
            lineJoin: "round",
          ),
        );
        _routeLayerReady = true;
      } finally {
        _routeLayerInitFuture = null;
      }
    }();

    await _routeLayerInitFuture;
  }

    Future<void> _clearJoinedPingRoute() async {
    _routeUi = null;
    _lastRouteFrom = null;
    _lastRouteTo = null;

    if (_map != null && _routeLayerReady) {
      try {
        await _map!.setGeoJsonSource(_routeSourceId, _emptyRouteGeoJson());
      } catch (_) {}
    }

    if (mounted) {
      setState(() {});
    }
  }

  double _bearingRadians(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180.0;
    final lon1 = from.longitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final lon2 = to.longitude * math.pi / 180.0;

    final dLon = lon2 - lon1;

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return math.atan2(y, x);
  }

  LatLng _routeTargetForPing(_PingPreview ping, LatLng from) {
    final exact = ping.exactAt;
    final visible = _markerPointFor(ping) ?? exact;

    final exactMeters = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      exact.latitude,
      exact.longitude,
    );

    if (exactMeters >= 10) {
      return exact;
    }

    final visibleMeters = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      visible.latitude,
      visible.longitude,
    );

    if (visibleMeters >= 10) {
      return visible;
    }

    final base = visibleMeters >= 1 ? visible : _offsetLatLng(from, 20, math.pi / 4);
    final bearing = _bearingRadians(from, base);

    return _offsetLatLng(from, 22, bearing);
  }
  
  Future<void> refreshEventMarkersOnly() async {
    _eventMineSub?.cancel();
    _eventPublicSub?.cancel();

    for (final s in _eventConnectionSubs) {
      s.cancel();
    }
    _eventConnectionSubs.clear();

    if (_map != null) {
      for (final s in _symbolsByEventClusterId.values) {
        try {
          await _map!.removeSymbol(s);
        } catch (_) {}
      }
    }

    _eventById.clear();
    _symbolsByEventClusterId.clear();
    _symbolImageKeyByEventClusterId.clear();
    _eventClusterById.clear();

    _startEventStreams();

    await Future.delayed(const Duration(milliseconds: 120));

    if (_mapReady && _markersReady) {
      await _drawEventMarkers();
    }
  }

  Future<void> _refreshJoinedPingRoute({bool force = false}) async {
    if (_map == null || !_styleLoaded || _me == null) {
      debugPrint("🛑 route skip: map/style/location not ready");
      await _clearJoinedPingRoute();
      return;
    }

    final targetId = _activeJoinedPingId;
    if (targetId == null || targetId.isEmpty) {
      debugPrint("🛑 route skip: no activeJoinedPingId");
      await _clearJoinedPingRoute();
      return;
    }

    final canDraw = await _canDrawRouteToPing(targetId);
    if (!canDraw) {
      debugPrint("🛑 route skip: join status does not allow route. activePingStatus=$_activePingStatus");
      await _clearJoinedPingRoute();
      return;
    }

    await _ensureRouteLayer();

    final ping = await _loadRouteTargetPing(targetId);
    if (ping == null) {
      debugPrint("🛑 route skip: target ping not loadable for $targetId");
      await _clearJoinedPingRoute();
      return;
    }

    if (ping.creatorId == _myUid) {
      debugPrint("🛑 route skip: creator is current user");
      await _clearJoinedPingRoute();
      return;
    }

    final from = _me!;
    final to = _routeTargetForPing(ping, from);

    final movedEnough = _lastRouteFrom == null ||
        Geolocator.distanceBetween(
              _lastRouteFrom!.latitude,
              _lastRouteFrom!.longitude,
              from.latitude,
              from.longitude,
            ) >=
            12;

    final targetChanged = _lastRouteTo == null ||
        Geolocator.distanceBetween(
              _lastRouteTo!.latitude,
              _lastRouteTo!.longitude,
              to.latitude,
              to.longitude,
            ) >=
            6;

    if (!force && !movedEnough && !targetChanged) {
      debugPrint("🛑 route skip: no meaningful route update needed");
      return;
    }

    _lastRouteFrom = from;
    _lastRouteTo = to;

    final straightLineMeters = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );

    // Do NOT hit the network for ultra-short routes.
    if (straightLineMeters < 8) {
      try {
        await _map!.setGeoJsonSource(
          _routeSourceId,
          _routeGeoJsonFromLatLngs([from, to]),
        );
      } catch (e) {
        debugPrint("❌ failed to set short fallback route: $e");
        await _clearJoinedPingRoute();
        return;
      }

      if (!mounted) return;

      setState(() {
        _routeUi = _RouteUi(
          mode: _TravelMode.walk,
          durationSec: 0,
          distanceM: straightLineMeters,
          pingTitle: ping.title,
        );
      });

      return;
    }

    debugPrint("🧭 route fetch start => ping=$targetId status=$_activePingStatus distance=$straightLineMeters");

    final ticket = ++_routeTicket;
    final route = await _fetchBestRoute(
      from: from,
      to: to,
      straightLineMeters: straightLineMeters,
    );

    if (!mounted || ticket != _routeTicket) return;

    // If route fetch fails, keep the old UI instead of nuking everything.
    if (route == null) {
      debugPrint("🛑 route fetch returned null; keeping previous route UI");
      return;
    }

    try {
      await _map!.setGeoJsonSource(
        _routeSourceId,
        _routeGeoJsonFromLatLngs(route.geometry),
      );
      debugPrint("✅ route rendered with ${route.geometry.length} points");
    } catch (e) {
      debugPrint("❌ failed to set route source: $e");
      return;
    }

    if (!mounted) return;

    setState(() {
      _routeUi = _RouteUi(
        mode: route.mode,
        durationSec: route.durationSec,
        distanceM: route.distanceM,
        pingTitle: ping.title,
      );
    });
  }

  _TravelMode _preferredTravelMode(double meters) {
    if (meters <= 1800) return _TravelMode.walk;
    if (meters <= 7000) return _TravelMode.bike;
    return _TravelMode.drive;
  }

  Future<_RouteResult?> _fetchBestRoute({
    required LatLng from,
    required LatLng to,
    required double straightLineMeters,
  }) async {
    // For close trips, walking should dominate the UI.
    if (straightLineMeters <= 1200) {
      final walk = await _fetchRoute(from: from, to: to, mode: _TravelMode.walk);
      if (walk != null) return walk;

      final bike = await _fetchRoute(from: from, to: to, mode: _TravelMode.bike);
      if (bike != null) {
        return _RouteResult(
          mode: _TravelMode.walk,
          durationSec: bike.durationSec,
          distanceM: bike.distanceM,
          geometry: bike.geometry,
        );
      }

      final drive = await _fetchRoute(from: from, to: to, mode: _TravelMode.drive);
      if (drive != null) {
        return _RouteResult(
          mode: _TravelMode.walk,
          durationSec: drive.durationSec,
          distanceM: drive.distanceM,
          geometry: drive.geometry,
        );
      }

      return null;
    }

    final preferred = _preferredTravelMode(straightLineMeters);

    final queue = <_TravelMode>[
      preferred,
      _TravelMode.walk,
      _TravelMode.bike,
      _TravelMode.drive,
    ];

    final tried = <_TravelMode>{};

    for (final mode in queue) {
      if (!tried.add(mode)) continue;
      final result = await _fetchRoute(from: from, to: to, mode: mode);
      if (result != null) return result;
    }

    return null;
  }

  Future<_RouteResult?> _fetchRoute({
    required LatLng from,
    required LatLng to,
    required _TravelMode mode,
  }) async {
    final profile = switch (mode) {
      _TravelMode.walk => "walking",
      _TravelMode.bike => "cycling",
      _TravelMode.drive => "driving",
    };

    final uri = Uri.parse(
      "https://router.project-osrm.org/route/v1/"
      "$profile/"
      "${from.longitude},${from.latitude};${to.longitude},${to.latitude}"
      "?overview=full&geometries=geojson&steps=false",
    );

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json["code"] != "Ok") return null;

      final routes = json["routes"];
      if (routes is! List || routes.isEmpty) return null;

      final route = routes.first as Map<String, dynamic>;
      final distanceM = (route["distance"] as num?)?.toDouble() ?? 0.0;
      final durationSec =
          ((route["duration"] as num?)?.toDouble() ?? 0).round();

      final geometryMap = route["geometry"];
      if (geometryMap is! Map) return null;

      final coords = geometryMap["coordinates"];
      if (coords is! List) return null;

      final points = <LatLng>[];
      for (final item in coords) {
        if (item is List && item.length >= 2) {
          points.add(
            LatLng(
              (item[1] as num).toDouble(),
              (item[0] as num).toDouble(),
            ),
          );
        }
      }

      if (points.length < 2) return null;

      return _RouteResult(
        mode: mode,
        durationSec: durationSec,
        distanceM: distanceM,
        geometry: points,
      );
    } catch (e) {
      debugPrint("❌ route request failed ($profile): $e");
      return null;
    }
  }

  Map<String, dynamic> _emptyRouteGeoJson() {
    return {
      "type": "FeatureCollection",
      "features": <dynamic>[],
    };
  }

  Map<String, dynamic> _routeGeoJsonFromLatLngs(List<LatLng> points) {
    return {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "properties": {},
          "geometry": {
            "type": "LineString",
            "coordinates": points
                .map((p) => [p.longitude, p.latitude])
                .toList(),
          },
        }
      ],
    };
  }

  Future<void> _boot() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      _myUid = uid;

      if (uid != null) {
        _visibilityContext = await _buildViewerVisibilityContext(viewerUid: uid);
        _visibilityReady = true;

        final doc = await FirebaseFirestore.instance
            .collection("users")
            .doc(uid)
            .get();

        final userData = doc.data() ?? <String, dynamic>{};
        _applyDiscoveryRadiusFromUserData(userData);
      }

      // Start data immediately. Do NOT block this behind emulator GPS.
      _startPingStreams();
      _startEventStreams();
      _startActivePingWatch();

      // Start live location in background.
      _startLocationWatch();

      if (_mapReady && _styleLoaded) {
        await _moveToMe();
        await _ensureMarkersLoaded();
        await _refreshUserMarker();
        await _syncDiscoveryRadiusOverlay();
        await _drawAllMapMarkers();
        await _refreshJoinedPingRoute(force: true);
      }
    } catch (e) {
      debugPrint("❌ _boot: $e");
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _startLocationWatch() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() => _locationOk = false);
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _locationOk = false);
        }
        return;
      }

      if (mounted) {
        setState(() {
          _locationOk = true;
          _loading = true;
          _waitingForFirstUsableFix = true;
        });
      }

      _firstFixTimeout?.cancel();
      _firstFixTimeout = Timer(const Duration(seconds: 15), () async {
        if (!mounted) return;

        if (_me == null) {
          final lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            final fallback = LatLng(lastKnown.latitude, lastKnown.longitude);
            _lastAcceptedLocation = fallback;
            _lastAcceptedLocationAt = lastKnown.timestamp.toLocal();

            setState(() {
              _me = fallback;
              _waitingForFirstUsableFix = false;
              _loading = false;
            });

            await _refreshUserMarker();
            await _refreshDiscoveryRadiusCircle();
            await _refreshDiscoveryRadiusTag();
            await _drawAllMapMarkers();
            _rebuildNearby();
          } else {
            setState(() {
              _waitingForFirstUsableFix = false;
              _loading = false;
            });
          }
        }
      });

      try {
        Position? pos;

        try {
          pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          ).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          debugPrint("⚠️ getCurrentPosition timed out on this device/emulator");
        }

        pos ??= await Geolocator.getLastKnownPosition();

        if (pos != null && _shouldAcceptPosition(pos, allowVeryPoorFirstFix: true)) {
          final fresh = LatLng(pos.latitude, pos.longitude);

          if (mounted) {
            setState(() {
              _me = fresh;
              _waitingForFirstUsableFix = false;
              _loading = false;
            });
            _lastAcceptedLocation = fresh;
            _lastAcceptedLocationAt = pos.timestamp.toLocal();
          }

          if (_mapReady && _styleLoaded) {
            await _animateToFirstFixIfNeeded();
            await _refreshUserMarker();
            await _refreshDiscoveryRadiusCircle();
            await _refreshDiscoveryRadiusTag();
            await _drawAllMapMarkers();
            _rebuildNearby();
            _scheduleJoinedPingRouteRefresh();
          }
        } else {
          debugPrint("⚠️ initial location ignored or unavailable");
        }
      } catch (e) {
        debugPrint("❌ initial location fetch failed: $e");
      }

      _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
        ),
      ).listen((p) async {
        if (!mounted) return;
        if (!_shouldAcceptPosition(p)) return;

        final newLatLng = LatLng(p.latitude, p.longitude);

        _lastAcceptedLocation = newLatLng;
        _lastAcceptedLocationAt = p.timestamp.toLocal();

        setState(() {
          _me = newLatLng;
          _waitingForFirstUsableFix = false;
          _loading = false;
        });

        await _animateToFirstFixIfNeeded();
        await _refreshUserMarker();
        await _refreshDiscoveryRadiusCircle();
        await _refreshDiscoveryRadiusTag();
        await _drawAllMapMarkers();
        _rebuildNearby();
        await _refreshJoinedPingRoute(force: true);
      });
    } catch (e) {
      debugPrint("❌ _startLocationWatch: $e");
      if (mounted) {
        setState(() {
          _locationOk = false;
          _loading = false;
          _waitingForFirstUsableFix = false;
        });
      }
    }
  }

  bool _shouldAcceptPosition(
    Position p, {
    bool allowVeryPoorFirstFix = false,
  }) {
    final next = LatLng(p.latitude, p.longitude);
    final prev = _lastAcceptedLocation ?? _me;

    if (prev == null) {
      if (!p.accuracy.isFinite) return true;

      final startupLimit =
          allowVeryPoorFirstFix ? 3500.0 : _firstFixMaxAccuracyMeters;

      if (p.accuracy > startupLimit) {
        debugPrint("🛑 startup location rejected: poor accuracy ${p.accuracy}m");
        return false;
      }
      return true;
    }

    if (p.accuracy.isFinite && p.accuracy > _steadyFixMaxAccuracyMeters) {
      debugPrint("🛑 location rejected: poor accuracy ${p.accuracy}m");
      return false;
    }

    final movedMeters = Geolocator.distanceBetween(
      prev.latitude,
      prev.longitude,
      next.latitude,
      next.longitude,
    );

    final now = p.timestamp.toLocal();
    final prevTime = _lastAcceptedLocationAt;
    final dtSec = prevTime == null
        ? 0.0
        : now.difference(prevTime).inMilliseconds / 1000.0;

    if (movedMeters < 6.0) return false;

    if (dtSec > 0) {
      final speedMps = movedMeters / dtSec;
      if (movedMeters > 500 && speedMps > 45) {
        debugPrint(
          "🛑 location rejected: teleport jump ${movedMeters.toStringAsFixed(1)}m in ${dtSec.toStringAsFixed(2)}s",
        );
        return false;
      }
    }

    return true;
  }

  Future<LatLng?> _getDeviceLocationSafe() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> recheckLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      await Geolocator.openLocationSettings();
      return;
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return;
    }

    final ok = perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;

    if (!mounted) return;

    setState(() => _locationOk = ok);

    if (ok) {
      final loc = await _getDeviceLocationSafe();
      if (loc != null && mounted) {
        setState(() => _me = loc);
        _lastAcceptedLocation = loc;
        _lastAcceptedLocationAt = DateTime.now();
        if (_mapReady) {
          await _moveToMe();
        }
        await _refreshDiscoveryRadiusCircle();
        await _refreshDiscoveryRadiusTag();
        _rebuildNearby();
        await _refreshUserMarker();
        await _refreshJoinedPingRoute(force: true);
      }
    }
  }

  void _startPingStreams() {
    final visCtx = _visibilityContext;
    if (visCtx == null) return;

    _publicSub?.cancel();
    _publicSub = FirebaseFirestore.instance
        .collection("pings")
        .where("privacy", isEqualTo: "public")
        .where("status", isEqualTo: "active")
        .orderBy("createdAtLocal", descending: true)
        .limit(30)
        .snapshots()
        .listen(
          _onPingSnapshot,
          onError: (e) => debugPrint("❌ public stream: $e"),
        );

    if (visCtx.viewerVerified) {
      _verifiedSub?.cancel();
      _verifiedSub = FirebaseFirestore.instance
          .collection("pings")
          .where("privacy", isEqualTo: "verified")
          .where("status", isEqualTo: "active")
          .orderBy("createdAtLocal", descending: true)
          .limit(20)
          .snapshots()
          .listen(
            _onPingSnapshot,
            onError: (e) => debugPrint("❌ verified stream: $e"),
          );
    }

    for (final s in _friendSubs) {
      s.cancel();
    }
    _friendSubs.clear();

    for (final friendUid in visCtx.viewerFriendIds.take(15)) {
      final sub = FirebaseFirestore.instance
          .collection("pings")
          .where("privacy", isEqualTo: "friends")
          .where("creatorId", isEqualTo: friendUid)
          .where("status", isEqualTo: "active")
          .orderBy("createdAtLocal", descending: true)
          .limit(10)
          .snapshots()
          .listen(
            _onPingSnapshot,
            onError: (e) => debugPrint("❌ friends stream: $e"),
          );
      _friendSubs.add(sub);
    }
  }

  void _startEventStreams() {
    final uid = _myUid;
    final visCtx = _visibilityContext;

    _eventMineSub?.cancel();
    _eventPublicSub?.cancel();

    for (final s in _eventConnectionSubs) {
      s.cancel();
    }
    _eventConnectionSubs.clear();

    if (uid == null || uid.isEmpty) return;

    _eventMineSub = FirebaseFirestore.instance
        .collection("events")
        .where("creatorId", isEqualTo: uid)
        .where("venueType", isEqualTo: "inPerson")
        .where("status", isEqualTo: "published")
        .orderBy("startsAt")
        .limit(30)
        .snapshots()
        .listen(
          _onEventSnapshot,
          onError: (e) => debugPrint("❌ my events stream: $e"),
        );

    _eventPublicSub = FirebaseFirestore.instance
        .collection("events")
        .where("venueType", isEqualTo: "inPerson")
        .where("status", isEqualTo: "published")
        .where("privacy", isEqualTo: "public")
        .orderBy("startsAt")
        .limit(60)
        .snapshots()
        .listen(
          _onEventSnapshot,
          onError: (e) => debugPrint("❌ public events stream: $e"),
        );

    if (visCtx == null) return;

    for (final friendUid in visCtx.viewerFriendIds.take(15)) {
      final sub = FirebaseFirestore.instance
          .collection("events")
          .where("privacy", isEqualTo: "connections")
          .where("hostType", isEqualTo: "user")
          .where("hostId", isEqualTo: friendUid)
          .where("venueType", isEqualTo: "inPerson")
          .where("status", isEqualTo: "published")
          .orderBy("startsAt")
          .limit(12)
          .snapshots()
          .listen(
            _onEventSnapshot,
            onError: (e) => debugPrint("❌ connections events stream: $e"),
          );

      _eventConnectionSubs.add(sub);
    }
  }

  bool _canViewerSeeEventData(Map<String, dynamic> data) {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) return false;

    final creatorId = (data["creatorId"] ?? "").toString().trim();
    if (creatorId == uid) return true;

    final privacy = (data["privacy"] ?? "").toString().trim().toLowerCase();
    if (privacy == "public") return true;

    if (privacy == "connections") {
      final hostType = (data["hostType"] ?? "").toString().trim().toLowerCase();
      final hostId = (data["hostId"] ?? "").toString().trim();
      final visCtx = _visibilityContext;

      return hostType == "user" &&
          visCtx != null &&
          visCtx.viewerFriendIds.contains(hostId);
    }

    return false;
  }

  _MapEventPreview? _eventPreviewFromData(
    String id,
    Map<String, dynamic> data,
  ) {
    final now = DateTime.now();

    final venue = data["venue"] as Map<String, dynamic>?;
    final gp = venue?["geoPoint"] as GeoPoint?;
    if (gp == null) return null;

    final status = (data["status"] ?? "").toString().trim().toLowerCase();
    final venueType = (data["venueType"] ?? "").toString().trim().toLowerCase();

    if (status != "published" || venueType != "inperson") {
      return null;
    }

    if (!_canViewerSeeEventData(data)) {
      return null;
    }

    final startsAt = (data["startsAt"] is Timestamp)
        ? (data["startsAt"] as Timestamp).toDate()
        : null;

    final endsAt = (data["endsAt"] is Timestamp)
        ? (data["endsAt"] as Timestamp).toDate()
        : null;

    if (endsAt != null && endsAt.isBefore(now)) {
      return null;
    }

    final cover = data["cover"] as Map<String, dynamic>? ?? {};
    final gradientRaw = (cover["gradientColors"] as List<dynamic>? ?? const []);

    return _MapEventPreview(
      id: id,
      title: (data["title"] ?? "Event").toString(),
      creatorId: (data["creatorId"] ?? "").toString(),
      at: LatLng(gp.latitude, gp.longitude),
      category: (data["category"] ?? "").toString(),
      theme: (data["theme"] ?? "emerald_night").toString(),
      privacy: (data["privacy"] ?? "").toString(),
      status: status,
      locationText: (data["locationText"] ?? "").toString(),
      meetupInstructions: (data["meetupInstructions"] ?? "").toString(),
      attendeeCount: (data["attendeeCount"] is num)
          ? (data["attendeeCount"] as num).toInt()
          : 0,
      registrationCount: (data["registrationCount"] is num)
          ? (data["registrationCount"] as num).toInt()
          : 0,
      createdAt: (data["createdAt"] is Timestamp)
          ? (data["createdAt"] as Timestamp).toDate()
          : null,
      startsAt: startsAt,
      endsAt: endsAt,
      coverType: (cover["type"] ?? "solid").toString(),
      coverImageUrl: cover["imageUrl"]?.toString(),
      coverPresetAssetPath: cover["presetAssetPath"]?.toString(),
      coverGradientColors: gradientRaw
          .whereType<num>()
          .map((e) => Color(e.toInt()))
          .toList(),
      coverColor: Color(
        ((cover["colorValue"] as num?)?.toInt() ?? 0xFF14B8A6),
      ),
    );
  }

  _MapEventPreview? _eventPreviewFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) return null;
    return _eventPreviewFromData(doc.id, data);
  }

  void _onEventSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    for (final change in snap.docChanges) {
      final doc = change.doc;

      if (change.type == DocumentChangeType.removed) {
        _eventById.remove(doc.id);
        continue;
      }
      

      final preview = _eventPreviewFromDoc(doc);

      if (preview == null) {
        _eventById.remove(doc.id);
        continue;
      }

      _eventById[doc.id] = preview;
    }

    if (_mapReady && _markersReady) {
      _drawAllMapMarkers();
    }
  }

  Future<void> _openEventPreview(_MapEventPreview event) async {
    HapticFeedback.lightImpact();

    try {
      final doc = await FirebaseFirestore.instance
          .collection('events')
          .doc(event.id)
          .get();

      if (!mounted || !doc.exists || doc.data() == null) return;

      final data = EventDetailsData.fromMap(doc.id, doc.data()!);

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EventDetailsScreen(
            data: data,
            onAttend: () {
              // TODO: wire attend / register
            },
            onSave: () {
              // TODO: wire save
            },
            onShare: () {
              // TODO: wire share
            },
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ open event details failed: $e');
    }
  }

  String _formatEventWhen(_MapEventPreview event) {
    final start = event.startsAt;
    final end = event.endsAt;

    if (start == null) return "Time not set";

    String two(int n) => n.toString().padLeft(2, "0");
    String hm(DateTime dt) {
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final ampm = dt.hour >= 12 ? "PM" : "AM";
      return "$h:${two(dt.minute)} $ampm";
    }

    final date = "${start.day}/${start.month}/${start.year}";

    if (end == null) {
      return "$date • ${hm(start)}";
    }

    return "$date • ${hm(start)} - ${hm(end)}";
  }

  void _onPingSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final visCtx = _visibilityContext;
    if (visCtx == null) return;

    final now = DateTime.now();

    for (final change in snap.docChanges) {
      final doc = change.doc;

      if (change.type == DocumentChangeType.removed) {
        _pingById.remove(doc.id);
        continue;
      }

      final data = doc.data();
      if (data == null) {
        _pingById.remove(doc.id);
        continue;
      }

      final loc = data["location"] as Map<String, dynamic>?;
      final gp = loc?["geopoint"] as GeoPoint?;
      if (gp == null) {
        _pingById.remove(doc.id);
        continue;
      }

      final mapGp = loc?["mapGeopoint"] as GeoPoint?;

      final accuracyMode = (loc?["accuracyMode"] is num)
          ? (loc!["accuracyMode"] as num).toInt()
          : 1;

      final accuracyRadiusMeters = (loc?["accuracyRadiusMeters"] is num)
          ? (loc!["accuracyRadiusMeters"] as num).toInt()
          : 250;

      final privacy = (data["privacy"] ?? "public")
          .toString()
          .trim()
          .toLowerCase();

      final status = (data["status"] ?? "active")
          .toString()
          .trim()
          .toLowerCase();

      final endsAt = (data["endsAt"] is Timestamp)
          ? (data["endsAt"] as Timestamp).toDate()
          : null;

      if (endsAt != null && endsAt.isBefore(now)) {
        _pingById.remove(doc.id);
        continue;
      }

      final participantCount = (data["participantCount"] is num)
          ? (data["participantCount"] as num).toInt()
          : 0;

      final preview = _PingPreview(
        id: doc.id,
        title: (data["title"] ?? "Ping").toString(),
        creatorId: (data["creatorId"] ?? "").toString(),
        exactAt: LatLng(gp.latitude, gp.longitude),
        mapAt: mapGp == null ? null : LatLng(mapGp.latitude, mapGp.longitude),
        accuracyRadiusMeters: accuracyRadiusMeters,
        category: (data["category"] ?? "").toString(),
        privacy: privacy,
        tags: (data["tags"] is List)
            ? (data["tags"] as List).map((e) => e.toString()).toList()
            : [],
        description: (data["description"] ?? "").toString(),
        participantCount: participantCount,
        accuracyMode: accuracyMode,
        placeName: (loc?["placeName"] ?? "Nearby").toString(),
        meetingPoint: (loc?["meetingPoint"] ?? "").toString(),
        status: status,
        createdAt: (data["createdAtLocal"] is Timestamp)
            ? (data["createdAtLocal"] as Timestamp).toDate()
            : null,
        startAt: (data["startAt"] is Timestamp)
            ? (data["startAt"] as Timestamp).toDate()
            : null,
        scheduledStartAt: (data["scheduledStartAt"] is Timestamp)
            ? (data["scheduledStartAt"] as Timestamp).toDate()
            : null,
        scheduledEndAt: (data["scheduledEndAt"] is Timestamp)
            ? (data["scheduledEndAt"] as Timestamp).toDate()
            : null,
        endsAt: (data["endsAt"] is Timestamp)
            ? (data["endsAt"] as Timestamp).toDate()
            : null,
        media: parsePingMedia(data["media"]),
        targetInterests: (data["targetInterests"] is List)
            ? (data["targetInterests"] as List).map((e) => e.toString()).toList()
            : const [],
        targetSkills: (data["targetSkills"] is List)
            ? (data["targetSkills"] as List).map((e) => e.toString()).toList()
            : const [],
        targetTerms: (data["targetTerms"] is List)
            ? (data["targetTerms"] as List).map((e) => e.toString()).toList()
            : const [],
        keywords: (data["keywords"] is List)
            ? (data["keywords"] as List).map((e) => e.toString()).toList()
            : const [],
      );

      final canSee = PingVisibility.canViewerSeeActivePing(
        ping: {
          "creatorId": preview.creatorId,
          "privacy": preview.privacy,
          "endsAt": preview.endsAt,
          "status": preview.status,
        },
        context: visCtx,
        now: now,
      );

      if (canSee && preview.status == "active") {
        _pingById[doc.id] = preview;
      } else {
        _pingById.remove(doc.id);
      }
    }

    _rebuildNearby();
  }

  void _rebuildNearby() {
    final list = _pingById.values
        .where(_isWithinDiscoveryRadius)
        .toList();

    if (_me != null) {
      list.sort((a, b) {
        final da = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          a.at.latitude,
          a.at.longitude,
        );
        final db = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          b.at.latitude,
          b.at.longitude,
        );
        return da.compareTo(db);
      });
    }

    if (!mounted) return;

    setState(() {
      _nearby
        ..clear()
        ..addAll(list.take(9));
    });

    if (_mapReady && _markersReady) {
      _drawAllMapMarkers();
    }

    _scheduleJoinedPingRouteRefresh();
  }

  void _sweepExpired() {
    final now = DateTime.now();
    final before = _pingById.length;
    _pingById.removeWhere(
      (_, p) => p.endsAt != null && p.endsAt!.isBefore(now),
    );
    if (_pingById.length != before) {
      _rebuildNearby();
    }
  }

  Future<PingVisibilityContext> _buildViewerVisibilityContext({
    required String viewerUid,
  }) async {
    final db = FirebaseFirestore.instance;
    final doc = await db.collection("users").doc(viewerUid).get();
    final data = doc.data() ?? {};

    final verification = Map<String, dynamic>.from(
      data["verification"] ?? {},
    );

    final viewerVerified = verification["status"] == "verified";

    final friendIds = <String>{};
    friendIds.addAll(List<String>.from(data["friendIds"] ?? []));

    final friendsSnap = await db
        .collection("users")
        .doc(viewerUid)
        .collection("friends")
        .get();

    for (final d in friendsSnap.docs) {
      final fid = (d.data()["friendId"] ?? "").toString();
      if (fid.isNotEmpty) {
        friendIds.add(fid);
      }
    }

    return PingVisibilityContext(
      viewerUid: viewerUid,
      viewerVerified: viewerVerified,
      viewerFriendIds: friendIds,
    );
  }

  bool _canOpenPingPreview(_PingPreview p) {
    final visCtx = _visibilityContext;
    if (visCtx == null) return false;

    return PingVisibility.canViewerSeeActivePing(
          ping: {
            "creatorId": p.creatorId,
            "privacy": p.privacy,
            "endsAt": p.endsAt,
            "status": p.status,
          },
          context: visCtx,
          now: DateTime.now(),
        ) &&
        p.status == "active";
  }

  void _onMapCreated(MaplibreMapController controller) {
    _map = controller;
    _mapReady = true;
    _styleLoaded = false;
  }

  Future<void> _syncDiscoveryRadiusOverlay() async {
    await _refreshDiscoveryRadiusCircle();
    await _refreshDiscoveryRadiusTag();
  }

  Future<void> _onMapStyleLoaded() async {
    _styleLoaded = true;

    // Reset everything tied to the old style.
    _radiusLayerReady = false;
    _radiusLayerInitFuture = null;
    _routeLayerReady = false;
    _routeLayerInitFuture = null;

    _radiusTagSymbol = null;
    _radiusTagImageKey = null;
    _userSymbol = null;

    // Critical: the new style does NOT keep old images/symbols.
    _markersReady = false;
    _loadedMarkerImages.clear();
    _symbolsByPingId.clear();
    _symbolImageKeyByPingId.clear();
    _symbolsByEventClusterId.clear();
    _symbolImageKeyByEventClusterId.clear();
    _eventClusterById.clear();
    _tapListenerAttached = false;

    await _ensureMarkersLoaded();
    await _ensureDiscoveryRadiusLayer();
    await _ensureRouteLayer();

    await _syncDiscoveryRadiusOverlay();

    if (mounted) {
      await _refreshUserMarker();
    }

    await _animateToFirstFixIfNeeded();

    if (_visibilityReady) {
      await _drawAllMapMarkers();
      await _refreshJoinedPingRoute(force: true);
    }

    _hintFadeTimer?.cancel();
    _hintFadeTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      setState(() => _hintOpacity = 0.0);
    });
  }

  Future<void> _moveToMe() async {
    if (_map == null || _me == null) return;

    await _map!.moveCamera(
      CameraUpdate.newLatLngZoom(_me!, 12.9),
    );
  }

  Future<void> _animateToFirstFixIfNeeded() async {
    if (_map == null || _me == null || _didAnimateToFirstFix) return;
    if (!_mapReady || !_styleLoaded) return;

    _didAnimateToFirstFix = true;

    try {
      await _map!.animateCamera(
        CameraUpdate.newLatLngZoom(_me!, 13.2),
      );
    } catch (e) {
      debugPrint("❌ first-fix animate failed: $e");
    }
  }

  Future<void> _locateMe() async {
    if (_map == null || _me == null) return;
    HapticFeedback.lightImpact();
    await _map!.animateCamera(
      CameraUpdate.newLatLngZoom(_me!, 13.9),
    );
  }

  Future<Uint8List> _renderUserMarker() async {
    final assetData = await rootBundle.load('assets/images/pingooo.png');
    final codec = await ui.instantiateImageCodec(
      assetData.buffer.asUint8List(),
      targetWidth: 68,
    );
    final frame = await codec.getNextFrame();
    final pingoooImg = frame.image;

    const double canvasW = 92.0;
    const double canvasH = 92.0;
    const double imgW = 68.0;
    const double imgH = 68.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, canvasW, canvasH),
    );

    final center = Offset(canvasW / 2, canvasH / 2);

    canvas.drawCircle(
      Offset(center.dx, center.dy + 4),
      28,
      Paint()
        ..color = Colors.black.withOpacity(.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    canvas.drawCircle(
      center,
      30,
      Paint()..color = AppColors.brandGreen.withOpacity(.12),
    );

    final imgLeft = (canvasW - imgW) / 2;
    final imgTop = (canvasH - imgH) / 2 - 2;

    canvas.drawImageRect(
      pingoooImg,
      Rect.fromLTWH(
        0,
        0,
        pingoooImg.width.toDouble(),
        pingoooImg.height.toDouble(),
      ),
      Rect.fromLTWH(imgLeft, imgTop, imgW, imgH),
      Paint(),
    );

    final picture = recorder.endRecording();
    final finalImg = await picture.toImage(canvasW.toInt(), canvasH.toInt());
    final bytes = await finalImg.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<void> _refreshUserMarker() async {
    if (_map == null || _me == null) return;

    try {
      const key = "pingooo_user_you";

      if (!_loadedMarkerImages.contains(key)) {
        final rendered = await _renderUserMarker();
        await _map!.addImage(key, rendered);
        _loadedMarkerImages.add(key);
      }

      final iconSize = (_markerBaseIconSize() + 0.06).clamp(0.58, 0.78);

      if (_userSymbol == null) {
        _userSymbol = await _map!.addSymbol(
          SymbolOptions(
            iconImage: key,
            geometry: _me!,
            iconSize: iconSize,
            iconAnchor: "center",
          ),
        );
        return;
      }

      await _map!.updateSymbol(
        _userSymbol!,
        SymbolOptions(
          geometry: _me!,
          iconImage: key,
          iconSize: iconSize,
          iconAnchor: "center",
        ),
      );
    } catch (e) {
      debugPrint("❌ _refreshUserMarker: $e");
    }
  }

  ({IconData icon, Color color}) _categoryStyle(String category) {
    final c = category.toLowerCase();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
        color: const Color(0xFF6C5CE7),
      );
    }
    if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
        color: const Color(0xFFE74C3C),
      );
    }
    if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        color: const Color(0xFF9B59B6),
      );
    }
    if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
        color: const Color(0xFF3498DB),
      );
    }
    if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
        color: const Color(0xFFE67E22),
      );
    }
    if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
        color: const Color(0xFF1ABC9C),
      );
    }
    if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
        color: const Color(0xFFF39C12),
      );
    }
    if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        color: const Color(0xFFE91E63),
      );
    }
    if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.fill),
        color: const Color(0xFFFFB800),
      );
    }
    if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF6B6B),
      );
    }
    if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF1744),
      );
    }
    if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
        color: const Color(0xFF2196F3),
      );
    }

    final hash = category.hashCode;
    final customColors = [
      const Color(0xFF00BCD4),
      const Color(0xFF009688),
      const Color(0xFF8BC34A),
      const Color(0xFFFF5722),
      const Color(0xFFE91E63),
    ];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
      color: customColors[hash.abs() % customColors.length],
    );
  }

  Future<Uint8List> _renderCategoryMarker({
    required IconData icon,
    required Color color,
    int participantCount = 0,
    double opacity = 1.0,
  }) async {
    final safeCount = participantCount < 1 ? 1 : participantCount;
    final countStr = safeCount > 99 ? "99+" : "$safeCount";
    final colorWithAlpha = color.withOpacity(opacity);

    const double canvasW = 136.0;
    const double canvasH = 148.0;

    const double circleSize = 74.0;
    const double circleRadius = circleSize / 2;
    const double circleTop = 4.0;

    const double badgeH = 34.0;
    const double badgeRadius = 13.0;
    const double badgeGap = 7.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, canvasW, canvasH),
    );

    final circleCenter = Offset(canvasW / 2, circleTop + circleRadius);

    // Main shadow
    canvas.drawCircle(
      Offset(circleCenter.dx, circleCenter.dy + 6),
      circleRadius,
      Paint()
        ..color = Colors.black.withOpacity(.22 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // Main circle
    canvas.drawCircle(
      circleCenter,
      circleRadius,
      Paint()..color = colorWithAlpha,
    );

    // Soft ring
    // Thick white outer border
    canvas.drawCircle(
      circleCenter,
      circleRadius,
      Paint()
        ..color = Colors.white.withOpacity(.98 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.8,
    );

    // Soft inner ring for polish
    canvas.drawCircle(
      circleCenter,
      circleRadius - 3.2,
      Paint()
        ..color = Colors.white.withOpacity(.20 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    // Category icon in main circle
    final mainIconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 32,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    mainIconPainter.paint(
      canvas,
      Offset(
        circleCenter.dx - mainIconPainter.width / 2,
        circleCenter.dy - mainIconPainter.height / 2,
      ),
    );

    // Badge icon
    final peopleIcon = PhosphorIcons.user(PhosphorIconsStyle.regular);

    final peoplePainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(peopleIcon.codePoint),
        style: TextStyle(
          fontSize: 15,
          fontFamily: peopleIcon.fontFamily,
          package: peopleIcon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final countPainter = TextPainter(
      text: TextSpan(
        text: countStr,
        style: TextStyle(
          fontSize: countStr.length > 2 ? 11.5 : 13.0,
          fontWeight: FontWeight.w800,
          fontFamily: "Nunito",
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeW = math.max(
      78.0,
      16 + peoplePainter.width + 8 + countPainter.width + 16,
    );

    final badgeLeft = (canvasW - badgeW) / 2;
    final badgeTop = circleTop + circleSize + badgeGap;

    // Badge shadow
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(badgeLeft, badgeTop + 3, badgeW, badgeH),
        const Radius.circular(badgeRadius),
      ),
      Paint()
        ..color = Colors.black.withOpacity(.22 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // Badge
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(badgeLeft, badgeTop, badgeW, badgeH),
        const Radius.circular(badgeRadius),
      ),
      Paint()..color = const Color(0xFF111111).withOpacity(.98 * opacity),
    );

    final iconY = badgeTop + (badgeH - peoplePainter.height) / 2;
    final countY = badgeTop + (badgeH - countPainter.height) / 2;

    peoplePainter.paint(
      canvas,
      Offset(badgeLeft + 14, iconY),
    );

    countPainter.paint(
      canvas,
      Offset(
        badgeLeft + badgeW - 14 - countPainter.width,
        countY,
      ),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW.toInt(), canvasH.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<void> _ensureMarkersLoaded() async {
    if (_map == null || _markersReady) return;

    try {
      if (!_loadedMarkerImages.contains("pingooo_user_you")) {
        final userBytes = await _renderUserMarker();
        await _map!.addImage("pingooo_user_you", userBytes);
        _loadedMarkerImages.add("pingooo_user_you");
      }

      for (final cat in _knownCategories) {
        final style = _categoryStyle(cat);
        final name = "marker_$cat";
        if (_loadedMarkerImages.contains(name)) continue;

        final rendered = await _renderCategoryMarker(
          icon: style.icon,
          color: style.color,
        );
        await _map!.addImage(name, rendered);
        _loadedMarkerImages.add(name);
      }

      _markersReady = true;
    } catch (e) {
      debugPrint("❌ Failed to load markers: $e");
    }
  }

  String _getMarkerImageName(
    String category,
    int participantCount,
    double opacity,
  ) {
    final safeCategory = category.trim().isEmpty ? "default" : category.trim().toLowerCase();
    final opacityInt = (opacity * 100).toInt();
    return "marker_${safeCategory}_p${participantCount}_o$opacityInt";
  }

  Future<String> _ensureMarkerImageExists({
    required String category,
    required int participantCount,
    required double opacity,
  }) async {
    if (_map == null) return "marker_default";

    final imageName = _getMarkerImageName(
      category,
      participantCount,
      opacity,
    );

    if (_loadedMarkerImages.contains(imageName)) {
      return imageName;
    }

    try {
      final style = _categoryStyle(category);
      final rendered = await _renderCategoryMarker(
        icon: style.icon,
        color: style.color,
        participantCount: participantCount,
        opacity: opacity,
      );
      await _map!.addImage(imageName, rendered);
      _loadedMarkerImages.add(imageName);
      return imageName;
    } catch (e) {
      debugPrint("❌ Failed to render marker: $e");
      return "marker_default";
    }
  }

  Future<void> _drawPingMarkers() async {
    if (_map == null) return;
    if (_drawingMarkers) return;

    _drawingMarkers = true;

    try {
      final now = DateTime.now();

      final mapPings = _pingById.values
          .where(_isWithinDiscoveryRadius)
          .where((p) => p.endsAt == null || !p.endsAt!.isBefore(now))
          .toList();

      final rendered = _buildRenderedPingMarkers(mapPings);
      final currentIds = rendered.map((e) => e.ping.id).toSet();

      final toRemove = _symbolsByPingId.keys
          .where((id) => !currentIds.contains(id))
          .toList();

      for (final id in toRemove) {
        try {
          await _map!.removeSymbol(_symbolsByPingId[id]!);
        } catch (_) {}
        _symbolsByPingId.remove(id);
        _symbolImageKeyByPingId.remove(id);
      }

      final baseIconSize = (_markerBaseIconSize() + 0.02).clamp(0.52, 0.70);

      for (final entry in rendered) {
        final p = entry.ping;

        final isNew = p.createdAt != null &&
            now.difference(p.createdAt!).inMinutes < 15;

        final markerImage = await _ensureMarkerImageExists(
          category: p.category,
          participantCount: p.participantCount,
          opacity: entry.opacity,
        );

        final iconSize = isNew
            ? (baseIconSize + 0.02).clamp(0.54, 0.72)
            : baseIconSize;

        final existing = _symbolsByPingId[p.id];

        if (existing == null) {
          final symbol = await _map!.addSymbol(
            SymbolOptions(
              geometry: entry.position,
              iconImage: markerImage,
              iconSize: iconSize,
              iconAnchor: "bottom",
            ),
          );
          _symbolsByPingId[p.id] = symbol;
          _symbolImageKeyByPingId[p.id] = markerImage;
        } else {
          final lastImage = _symbolImageKeyByPingId[p.id];
          await _map!.updateSymbol(
            existing,
            SymbolOptions(
              geometry: entry.position,
              iconImage: lastImage == markerImage ? null : markerImage,
              iconSize: iconSize,
              iconAnchor: "bottom",
            ),
          );
          _symbolImageKeyByPingId[p.id] = markerImage;
        }
      }

      if (!_tapListenerAttached) {
        _tapListenerAttached = true;

        _map!.onSymbolTapped.add((symbol) {
          if (_radiusTagSymbol != null && symbol.id == _radiusTagSymbol!.id) {
            return;
          }

          if (_userSymbol != null && symbol.id == _userSymbol!.id) {
            final overlappingNow = _computeOverlappingOwnPings();

            if (overlappingNow.isNotEmpty) {
              _overlappingOwnPings = overlappingNow;
              _openClusterPopup(overlappingNow);
            } else {
              _openYouPopup();
            }
            return;
          }

        String? pingId;
          for (final e in _symbolsByPingId.entries) {
            if (e.value.id == symbol.id) {
              pingId = e.key;
              break;
            }
          }

          if (pingId != null) {
            final ping = _pingById[pingId];
            if (ping != null) {
              _openPing(ping);
              return;
            }
          }

          String? clusterId;
          for (final e in _symbolsByEventClusterId.entries) {
            if (e.value.id == symbol.id) {
              clusterId = e.key;
              break;
            }
          }

          if (clusterId == null) return;

          final cluster = _eventClusterById[clusterId];
          if (cluster == null) return;

          if (cluster.events.length == 1) {
            _openEventPreview(cluster.events.first);
            return;
          }

          _openEventClusterPopup(cluster.events);
        });
      }
    } finally {
      _drawingMarkers = false;
    }
  }

  Future<void> refreshPings() async {
    await _clearPingSymbols();
    await _clearEventSymbols();

    _styleLoaded = true;
    _radiusLayerReady = false;
    _radiusLayerInitFuture = null;
    _routeLayerReady = false;
    _routeLayerInitFuture = null;
    _radiusTagSymbol = null;
    _radiusTagImageKey = null;
    _userSymbol = null;

    _loadedMarkerImages.clear();
    _pingById.clear();
    _eventById.clear();

    _startPingStreams();
    _startEventStreams();

    await Future.delayed(const Duration(milliseconds: 120));

    if (_mapReady && _markersReady) {
      await _drawAllMapMarkers();
    }
  }

  void _openYouPopup() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _YouMarkerSheet(),
    );
  }

  void _openClusterPopup(List<_PingPreview> pings) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PingClusterSheet(
        pings: pings,
        onTapPing: (p) {
          Navigator.of(context).pop();
          Future.delayed(const Duration(milliseconds: 120), () {
            if (mounted) {
              _openPing(p);
            }
          });
        },
        onTapYou: () {
          Navigator.of(context).pop();
          Future.delayed(const Duration(milliseconds: 120), () {
            if (mounted) {
              _openYouPopup();
            }
          });
        },
      ),
    );
  }

  void _openEventClusterPopup(List<_MapEventPreview> events) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _EventClusterSheet(
        events: events,
        onTapEvent: (event) {
          Navigator.of(context).pop();
          Future.delayed(const Duration(milliseconds: 120), () {
            if (mounted) {
              _openEventPreview(event);
            }
          });
        },
      ),
    );
  }

  Future<void> _recordPingView(String pingId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final pingRef = FirebaseFirestore.instance.collection("pings").doc(pingId);
    final pingSnap = await pingRef.get();
    if (!pingSnap.exists) return;

    final pingData = pingSnap.data() ?? {};
    final creatorId = (pingData["creatorId"] ?? "").toString().trim();

    if (creatorId == uid) return;

    final userSnap = await FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .get();

    final userData = userSnap.data() ?? {};

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final freshPingSnap = await tx.get(pingRef);
      if (!freshPingSnap.exists) return;

      final viewRef = pingRef.collection("views").doc(uid);
      final existingView = await tx.get(viewRef);

      if (existingView.exists) {
        tx.set(viewRef, {
          "lastViewedAt": FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return;
      }

      tx.set(viewRef, {
        "uid": uid,
        "fullName": (userData["fullName"] ?? "").toString(),
        "username": (userData["username"] ?? "").toString(),
        "photoUrl": (userData["photoUrl"] ?? "").toString(),
        "viewedAt": FieldValue.serverTimestamp(),
        "lastViewedAt": FieldValue.serverTimestamp(),
      });

      tx.set(pingRef, {
        "viewCount": FieldValue.increment(1),
      }, SetOptions(merge: true));
    });
  }

  Future<void> _openPingById(
    String pingId, {
    bool showHiddenToast = false,
  }) async {
    if (!mounted) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.maybeOf(context);

    var overlayOpen = false;

    try {
      showDialog(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (_) => const _PingLoadingOverlay(),
      );
      overlayOpen = true;

      // IMPORTANT:
      // View tracking should NEVER block opening the ping.
      try {
        await _recordPingView(pingId);
      } catch (e, st) {
        debugPrint("❌ view tracking failed for $pingId: $e");
        debugPrintStack(stackTrace: st);
      }

      if (!mounted) return;

      if (overlayOpen) {
        try {
          navigator.pop();
        } catch (_) {}
        overlayOpen = false;
      }

      await openPingDetailsSheet(context: context, pingId: pingId);
    } catch (e, st) {
      debugPrint("❌ failed to open ping details for $pingId: $e");
      debugPrintStack(stackTrace: st);

      if (overlayOpen) {
        try {
          navigator.pop();
        } catch (_) {}
        overlayOpen = false;
      }

      if (mounted) {
        _showToast(
          "Failed to open ping details.",
          messenger: messenger,
        );
      }
    } finally {
      if (mounted && showHiddenToast) {
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) {
            _showToast(
              "This user has hidden their location.",
              messenger: messenger,
            );
          }
        });
      }
    }
  }

  Future<void> _openPing(_PingPreview p) async {
    if (!_canOpenPingPreview(p)) {
      _showToast("You can't view this ping.");
      return;
    }

    await _openPingById(
      p.id,
      showHiddenToast: p.accuracyMode == 0,
    );
  }

  Future<void> _focusAndOpenPing(_PingPreview p) async {
    if (p.accuracyMode != 0 && _map != null) {
      await _map!.animateCamera(CameraUpdate.newLatLngZoom(p.at, 14.6));
      await Future.delayed(const Duration(milliseconds: 260));
    }
    await _openPing(p);
  }

  void _showDiscover() {
    if (!mounted) return;
    setState(() => _discoverVisible = true);
  }

  void _showMapOnly() {
    if (!mounted) return;
    setState(() => _discoverVisible = false);
  }

  List<_PingPreview> _sortedDiscoverPings({int? limit}) {
    final list = _pingById.values
        .where(_isWithinDiscoveryRadius)
        .where((p) => p.status == "active")
        .where(_matchesDiscoverFilters)
        .toList();

    if (_me != null) {
      list.sort((a, b) {
        final da = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          a.at.latitude,
          a.at.longitude,
        );
        final db = Geolocator.distanceBetween(
          _me!.latitude,
          _me!.longitude,
          b.at.latitude,
          b.at.longitude,
        );
        return da.compareTo(db);
      });
    }

    if (limit == null) return list;
    return list.take(limit).toList();
  }

  List<String> _discoverTags() {
    final counts = <String, int>{};

    final source = _pingById.values
        .where(_isWithinDiscoveryRadius)
        .where((p) => p.status == "active")
        .where((p) {
          final selectedCategory = _selectedDiscoverCategory;
          if (selectedCategory == null) return true;
          return _normalizeDiscoverCategory(p.category) == selectedCategory;
        });

    for (final ping in source) {
      for (final raw in ping.tags) {
        final cleaned = raw.trim();
        if (cleaned.isEmpty) continue;

        final tag = cleaned.startsWith('#')
            ? cleaned.toLowerCase()
            : '#${cleaned.toLowerCase()}';

        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }

    final tags = counts.keys.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));

    if (tags.isNotEmpty) return tags.take(20).toList();

    return const [
      '#startup',
      '#football',
      '#music',
      '#study',
      '#hangout',
      '#gym',
      '#gaming',
      '#networking',
      '#food',
      '#chill',
    ];
  }

  Future<void> _openAllNearbyPings() async {
    final items = _discoverUniversePings();
    final profile = await _loadViewerDiscoverProfile();

    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => _DiscoverAllPingsScreen(
          items: items,
          me: _me,
          categories: _knownCategories
              .where((e) => e.trim().isNotEmpty && e != "default")
              .toList(),
          initialCategory: _selectedDiscoverCategory,
          initialTags: _selectedDiscoverTags,
          viewerInterests: profile.interests,
          viewerSkills: profile.skills,
          onTapPing: (ping) async {
            Navigator.of(routeContext).pop();
            _showMapOnly();
            await Future.delayed(const Duration(milliseconds: 120));
            if (!mounted) return;
            await _focusAndOpenPing(ping);
          },
        ),
      ),
    );
  }

  Future<void> _openCreatePingAtLocation(LatLng? latLng) async {
    HapticFeedback.mediumImpact();

    final result = await Navigator.push<CreatePingResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePingSheet(
          initialGeoPoint: latLng != null
              ? GeoPoint(latLng.latitude, latLng.longitude)
              : null,
          draft: _createPingDraft,
        ),
      ),
    );

    if (!mounted || result == null) return;

    // Do not hard-refresh the map here.
    // Let Firestore listeners update the map naturally.

    await Future.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return _PingCreatedSheet(
          result: result,
          onDone: () => Navigator.of(sheetContext).pop(),
          onViewPing: () async {
            Navigator.of(sheetContext).pop();
            await Future.delayed(const Duration(milliseconds: 120));
            if (!mounted) return;
            await _openPingById(result.pingId);
          },
        );
      },
    );
  }

  

  void _openSearch({String initialQuery = ""}) {
    final visCtx = _visibilityContext;
    if (visCtx == null) {
      _showToast("Search is still loading.");
      return;
    }

    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => _SearchSheet(
          parentContext: context,
          visibilityContext: visCtx,
          initialQuery: initialQuery,
          candidatePings: _discoverUniversePings(),
          me: _me,
          onOpenPingId: (id) async {
            if (!mounted) return;
            await _openPingById(id);
          },
        ),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            ),
            child: child,
          );
        },
      ),
    );
  }

  void _toggleNearby() {
    setState(() => _nearbyCollapsed = !_nearbyCollapsed);
  }

  void _onMapPointerDown(PointerDownEvent event) {
    _longPressStartOffset = event.position;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(seconds: 5), () {
      if (_longPressLatLng != null && mounted) {
        _openCreatePingAtLocation(_longPressLatLng);
      }
    });
  }

  void _onMapPointerMove(PointerMoveEvent event) {
    if (_longPressStartOffset != null) {
      final distance = (_longPressStartOffset! - event.position).distance;
      if (distance > _longPressMoveThreshold) {
        _longPressTimer?.cancel();
        _longPressTimer = null;
      }
    }
  }

  void _onMapPointerUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressStartOffset = null;
    _longPressLatLng = null;
  }

  Future<void> _onMapLongClick(Point point, LatLng latLng) async {
    _longPressLatLng = latLng;
  }

  void _showToast(
    String msg, {
    ScaffoldMessengerState? messenger,
  }) {
    if (!mounted) return;

    final targetMessenger = messenger ?? ScaffoldMessenger.maybeOf(context);
    if (targetMessenger == null) return;

    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final bottomMargin = bottomSafe + 120;

    targetMessenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: const TextStyle(fontFamily: "Nunito"),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.black.withOpacity(.82),
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final start = _me ?? _neutralMapStart;

    final screenH = MediaQuery.of(context).size.height;
    final compactPhone = screenH < 760;

    final double bottomDock = compactPhone ? 124.0 : 102.0;
    final screenW = MediaQuery.of(context).size.width;
    final etaCardWidth = (screenW * 0.58).clamp(210.0, 280.0);
    final etaBottomOffset = bottomDock + 88.0;
    final locateBottomOffset = bottomDock + 128.0;
    final hideUiBottomOffset = locateBottomOffset + 50.0;
    final bool discoverLoading = _loading || !_mapReady || !_styleLoaded;

    final nearbyItems = _sortedDiscoverPings(limit: 9);
    final allNearbyItems = _sortedDiscoverPings();

    return Scaffold(
      backgroundColor: const Color(0xFFEFF2F7),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _onMapPointerDown,
                onPointerMove: _onMapPointerMove,
                onPointerUp: _onMapPointerUp,
                child: MaplibreMap(
                  styleString: _styleJson,
                  onMapCreated: _onMapCreated,
                  onStyleLoadedCallback: _onMapStyleLoaded,
                  onMapLongClick: _onMapLongClick,
                  onCameraIdle: _onCameraIdle,
                  trackCameraPosition: true,
                  initialCameraPosition: CameraPosition(
                    target: start,
                    zoom: _me == null ? 1.1 : 11.9,
                  ),
                  rotateGesturesEnabled: true,
                  scrollGesturesEnabled: true,
                  zoomGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  compassEnabled: false,
                ),
              ),
            ),

            if (!_mapUiHidden)
              const Positioned.fill(child: _MapVibeGlass()),

            if (_showInitialMapLoading && !_mapUiHidden)
              Positioned.fill(
                child: _buildInitialMapLoadingOverlay(),
              ),

            if (_showLocationSearchingPill && !_mapUiHidden)
              Positioned.fill(
                child: _buildLocationSearchingPill(),
              ),

            if (!_discoverVisible && !_mapUiHidden)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMarkerFilterBar(),
              ),

            if (!_discoverVisible && !_mapUiHidden)
              Positioned(
                top: 0,
                right: 0,
                child: _buildRefreshLocationButton(),
              ),  

            if (!_discoverVisible && !_locationOk && !_loading)
              Positioned(
                top: compactPhone ? 18 : 20,
                left: 16,
                right: 16,
                child: _LocationOffBanner(onTap: recheckLocation),
              ),

            if (!_discoverVisible && !_loading)
              Positioned(
                bottom: bottomDock + 94,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _hintOpacity,
                    duration: const Duration(seconds: 5),
                    curve: Curves.easeOut,
                    child: const _LongPressHint(),
                  ),
                ),
              ),

            if (!_discoverVisible)
              Positioned(
                right: 14,
                bottom: hideUiBottomOffset,
                child: _MapUiToggleButton(
                  hidden: _mapUiHidden,
                  onTap: _toggleMapUiHidden,
                ),
              ),  

            if (!_discoverVisible && !_mapUiHidden)
              Positioned(
                right: 14,
                bottom: locateBottomOffset,
                child: _LocateMeButton(onTap: _locateMe),
              ),

            if (_discoverVisible)
              Positioned.fill(
                child: _DiscoverOverlay(
                  loading: discoverLoading,
                  locationOk: _locationOk,
                  nearbyItems: nearbyItems,
                  allNearbyCount: allNearbyItems.length,
                  me: _me,
                  categories: _knownCategories
                      .where((e) => e.trim().isNotEmpty && e != "default")
                      .toList(),
                  tags: _discoverTags(),
                  categoryController: _categoryParallaxController,
                  tagController: _tagParallaxController,
                  onTapSearch: () => _openSearch(),
                  onTapMap: _showMapOnly,
                  onTapEnableLocation: recheckLocation,
                  onTapViewAll: _openAllNearbyPings,
                  selectedCategory: _selectedDiscoverCategory,
                  selectedTags: _selectedDiscoverTags,
                  onTapCategory: _toggleDiscoverCategory,
                  onTapTag: _toggleDiscoverTag,
                  onClearFilters: _clearDiscoverFilters,
                  onTapPing: (ping) async {
                    _showMapOnly();
                    await Future.delayed(const Duration(milliseconds: 120));
                    if (!mounted) return;
                    await _focusAndOpenPing(ping);
                  },
                ),
              ),

            if (!_discoverVisible && _routeUi != null && !_loading)
              Positioned(
                left: 14,
                width: etaCardWidth,
                bottom: etaBottomOffset,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 4),
                  child: _MapEtaCard(route: _routeUi!),
                ),
              ),

            if (!_discoverVisible && !_mapUiHidden)
              Positioned(
                left: 14,
                right: 14,
                bottom: bottomDock,
                child: _DiscoverLauncherBar(
                  count: allNearbyItems.length,
                  onTap: _showDiscover,
                ),
              ),
          ],
        ),
      ),
    );
  }
  
}

class _PingCreatedSheet extends StatelessWidget {
  final CreatePingResult result;
  final VoidCallback onDone;
  final VoidCallback onViewPing;

  const _PingCreatedSheet({
    required this.result,
    required this.onDone,
    required this.onViewPing,
  });

  String get _subtitle {
    if (!result.hasMedia) {
      return "Your ping is now live on the map.";
    }

    if (!result.hasMediaIssues) {
      return "Your ping is live and all ${result.mediaUploaded} media item(s) uploaded successfully.";
    }

    if (result.mediaUploaded == 0) {
      return "Your ping is live, but media upload failed.";
    }

    return "Your ping is live. ${result.mediaUploaded} media uploaded, ${result.mediaFailed} failed.";
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF4F6F8),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(.70)),
              boxShadow: [
                BoxShadow(
                  blurRadius: 40,
                  offset: const Offset(0, 20),
                  color: Colors.black.withOpacity(.12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandGreen.withOpacity(.12),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                        color: AppColors.brandGreen.withOpacity(.18),
                      ),
                    ],
                  ),
                  child: Icon(
                    PhosphorIcons.checkCircle(PhosphorIconsStyle.fill),
                    size: 42,
                    color: AppColors.brandGreen,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Ping created",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    _subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.55),
                      height: 1.4,
                    ),
                  ),
                ),
                if (result.hasMedia) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen.withOpacity(.06),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: AppColors.brandGreen.withOpacity(.14),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            PhosphorIcons.paperclip(PhosphorIconsStyle.fill),
                            size: 18,
                            color: AppColors.brandGreen,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "${result.mediaUploaded}/${result.mediaTotal} media uploaded",
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          if (result.mediaFailed > 0)
                            Text(
                              "${result.mediaFailed} failed",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: Colors.red.shade700,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onViewPing,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: const Text(
                        "View ping",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: onDone,
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: Colors.black.withOpacity(.08),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(
                        "Done",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.brandGreen,
                        ),
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
  }
}

class _MapUiToggleButton extends StatelessWidget {
  final bool hidden;
  final VoidCallback onTap;

  const _MapUiToggleButton({
    required this.hidden,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              blurRadius: 10,
              offset: const Offset(0, 4),
              color: Colors.black.withOpacity(.18),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            hidden
                ? PhosphorIcons.eye(PhosphorIconsStyle.fill)
                : PhosphorIcons.eyeSlash(PhosphorIconsStyle.fill),
            color: Colors.black,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _LocateMeButton extends StatelessWidget {
  final VoidCallback onTap;

  const _LocateMeButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              blurRadius: 10,
              offset: const Offset(0, 4),
              color: Colors.black.withOpacity(.18),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            PhosphorIcons.navigationArrow(PhosphorIconsStyle.fill),
            color: Colors.black,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _PingClusterSheet extends StatelessWidget {
  final List<_PingPreview> pings;
  final void Function(_PingPreview) onTapPing;
  final VoidCallback onTapYou;

  const _PingClusterSheet({
    required this.pings,
    required this.onTapPing,
    required this.onTapYou,
  });

  ({IconData icon, Color color}) _styleFor(String category) {
    final c = category.toLowerCase();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
        color: const Color(0xFF6C5CE7),
      );
    }
    if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
        color: const Color(0xFFE74C3C),
      );
    }
    if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        color: const Color(0xFF9B59B6),
      );
    }
    if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
        color: const Color(0xFF3498DB),
      );
    }
    if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
        color: const Color(0xFFE67E22),
      );
    }
    if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
        color: const Color(0xFF1ABC9C),
      );
    }
    if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
        color: const Color(0xFFF39C12),
      );
    }
    if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        color: const Color(0xFFE91E63),
      );
    }
    if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.fill),
        color: const Color(0xFFFFB800),
      );
    }
    if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF6B6B),
      );
    }
    if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF1744),
      );
    }
    if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
        color: const Color(0xFF2196F3),
      );
    }

    final hash = category.hashCode;
    const palette = [
      Color(0xFF00BCD4),
      Color(0xFF009688),
      Color(0xFF8BC34A),
      Color(0xFFFF5722),
      Color(0xFF673AB7),
    ];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
      color: palette[hash.abs() % palette.length],
    );
  }

  String _expiresText(DateTime? endsAt) {
    if (endsAt == null) return "";
    final diff = endsAt.difference(DateTime.now());
    if (diff.isNegative) return "Ended";
    if (diff.inMinutes < 60) return "Ends in ${diff.inMinutes}m";
    if (diff.inHours < 24) return "Ends in ${diff.inHours}h";
    return "Ends in ${diff.inDays}d";
  }

  @override
  Widget build(BuildContext context) {
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.82;

    return Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxSheetHeight,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6F8),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withOpacity(.70)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                    color: Colors.black.withOpacity(.12),
                  ),
                ],
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 68,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ...List.generate(pings.length.clamp(0, 3), (i) {
                          final s = _styleFor(pings[i].category);
                          return Positioned(
                            left: 90.0 + i * 28.0,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: s.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 8,
                                    offset: const Offset(0, 4),
                                    color: s.color.withOpacity(.35),
                                  ),
                                ],
                              ),
                              child: Icon(
                                s.icon,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          );
                        }),
                        Positioned(
                          left: 52,
                          child: Container(
                            width: 62,
                            height: 62,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFF2F6F2),
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 14,
                                  offset: const Offset(0, 6),
                                  color: AppColors.brandGreen.withOpacity(.20),
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/images/pingooo.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    pings.length == 1
                        ? "Your ping is here"
                        : "${pings.length} of your pings are here",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Text(
                      "You created ${pings.length == 1 ? "a ping" : "pings"} at your current location. Tap one to open it.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.52),
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  Flexible(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: pings.map((p) {
                          final s = _styleFor(p.category);
                          final exp = _expiresText(p.endsAt);
                          final isExp = p.endsAt != null &&
                              !p.endsAt!.isBefore(DateTime.now()) &&
                              p.endsAt!.difference(DateTime.now()).inMinutes < 15;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => onTapPing(p),
                                borderRadius: BorderRadius.circular(18),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 13,
                                  ),
                                  decoration: BoxDecoration(
                                    color: s.color.withOpacity(.06),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: s.color.withOpacity(.16),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: s.color.withOpacity(.14),
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: Icon(
                                          s.icon,
                                          color: s.color,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: "Nunito",
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            if (exp.isNotEmpty) ...[
                                              const SizedBox(height: 3),
                                              Text(
                                                exp,
                                                style: TextStyle(
                                                  fontFamily: "Nunito",
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: isExp
                                                      ? Colors.red.shade600
                                                      : Colors.black.withOpacity(.45),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        PhosphorIcons.caretRight(
                                          PhosphorIconsStyle.bold,
                                        ),
                                        size: 16,
                                        color: s.color.withOpacity(.60),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Divider(
                      height: 1,
                      color: Colors.black.withOpacity(.06),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: InkWell(
                      onTap: onTapYou,
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              PhosphorIcons.shieldCheck(PhosphorIconsStyle.fill),
                              size: 14,
                              color: AppColors.brandGreen.withOpacity(.75),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              "About your location privacy",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: AppColors.brandGreen.withOpacity(.85),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              PhosphorIcons.caretRight(
                                PhosphorIconsStyle.bold,
                              ),
                              size: 12,
                              color: AppColors.brandGreen.withOpacity(.65),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          "Close",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Colors.white,
                          ),
                        ),
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

class _YouMarkerSheet extends StatelessWidget {
  const _YouMarkerSheet();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxSheetHeight = media.size.height * 0.78;

    return Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        bottom: media.viewInsets.bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxSheetHeight,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6F8),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withOpacity(.70)),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                    color: Colors.black.withOpacity(.12),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Flexible(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFFF2F6F2),
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    blurRadius: 18,
                                    offset: const Offset(0, 8),
                                    color: AppColors.brandGreen.withOpacity(.20),
                                  ),
                                ],
                              ),
                              child: ClipOval(
                                child: Image.asset(
                                  'assets/images/pingooo.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              "This is you",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "Your location is only visible to you. No one on Pingmee can see where you are unless you create a public ping.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 13.5,
                                fontWeight: FontWeight.w400,
                                color: Colors.black.withOpacity(.56),
                                height: 1.42,
                              ),
                            ),
                            const SizedBox(height: 18),

                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF7FAF7),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.black.withOpacity(.05),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 34,
                                        height: 34,
                                        decoration: BoxDecoration(
                                          color: AppColors.brandGreen.withOpacity(.12),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Icon(
                                          PhosphorIcons.eyeSlash(
                                            PhosphorIconsStyle.bold,
                                          ),
                                          size: 16,
                                          color: AppColors.brandGreen,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      const Expanded(
                                        child: Text(
                                          "What others can see",
                                          style: TextStyle(
                                            fontFamily: "Nunito",
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  _PrivacyBullet(
                                    text: "They do not see your live location.",
                                  ),
                                  const SizedBox(height: 8),
                                  _PrivacyBullet(
                                    text: "They only see a ping location if you choose to create one.",
                                  ),
                                  const SizedBox(height: 8),
                                  _PrivacyBullet(
                                    text: "Your own marker is for your view only.",
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          child: const Text(
                            "Close",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrivacyBullet extends StatelessWidget {
  final String text;

  const _PrivacyBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black.withOpacity(.62),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _PrivacyInfoRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _PrivacyInfoRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: color.withOpacity(.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(.14)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withOpacity(.50),
                    height: 1.35,
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

class _LocationOffBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _LocationOffBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3CD),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xFFFFD966).withOpacity(.6),
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 14,
              offset: const Offset(0, 6),
              color: Colors.black.withOpacity(.08),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(
              Icons.location_off_rounded,
              color: Color(0xFFB8860B),
              size: 20,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Enable location to see pings near you",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Color(0xFF7A5C00),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFB8860B),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                "Enable",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LongPressHint extends StatelessWidget {
  const _LongPressHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIcons.handPointing(PhosphorIconsStyle.light),
            color: Colors.white.withOpacity(.85),
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(
            "Long press map to drop a ping",
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Colors.white.withOpacity(.85),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _MapVibeGlass extends StatelessWidget {
  const _MapVibeGlass();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: Container(
        color: AppColors.brandGreen.withOpacity(.06),
      ),
    );
  }
}

class _TopSearchLauncher extends StatelessWidget {
  final VoidCallback onTap;

  const _TopSearchLauncher({
    required this.onTap,
  });

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
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.82),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(.65)),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
                    size: 18,
                    color: Colors.black.withOpacity(.55),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Search people, pings and events",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 13.5,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(.55),
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
            colors: [Color(0xFF3F9B53), Color(0xFF67BE6E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              blurRadius: 26,
              offset: const Offset(0, 18),
              color: Colors.black.withOpacity(.12),
            ),
          ],
        ),
        child: child,
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
        const Positioned(
          bottom: 10,
          left: 20,
          child: Icon(
            Icons.auto_awesome,
            color: Color(0xFFB7F44A),
            size: 24,
          ),
        ),
      ],
    );
  }
}

class _NearbyPingsPreview extends StatefulWidget {
  final bool loading;
  final bool collapsed;
  final VoidCallback onToggle;
  final List<_PingPreview> items;
  final void Function(_PingPreview) onTapPing;
  final LatLng? me;

  const _NearbyPingsPreview({
    required this.loading,
    required this.collapsed,
    required this.onToggle,
    required this.items,
    required this.onTapPing,
    required this.me,
  });

  @override
  State<_NearbyPingsPreview> createState() => _NearbyPingsPreviewState();
}

class _DiscoverOverlay extends StatelessWidget {
  final bool loading;
  final bool locationOk;
  final List<_PingPreview> nearbyItems;
  final int allNearbyCount;
  final LatLng? me;
  final List<String> categories;
  final List<String> tags;
  final ScrollController categoryController;
  final ScrollController tagController;
  final VoidCallback onTapSearch;
  final VoidCallback onTapMap;
  final VoidCallback onTapEnableLocation;
  final VoidCallback onTapViewAll;
  final VoidCallback onClearFilters;
  final String? selectedCategory;
  final Set<String> selectedTags;
  final void Function(String) onTapCategory;
  final void Function(String) onTapTag;
  final void Function(_PingPreview) onTapPing;

  const _DiscoverOverlay({
    required this.loading,
    required this.locationOk,
    required this.nearbyItems,
    required this.allNearbyCount,
    required this.me,
    required this.categories,
    required this.tags,
    required this.categoryController,
    required this.tagController,
    required this.onTapSearch,
    required this.onTapMap,
    required this.onTapEnableLocation,
    required this.onTapViewAll,
    required this.onClearFilters,
    required this.selectedCategory,
    required this.selectedTags,
    required this.onTapCategory,
    required this.onTapTag,
    required this.onTapPing,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final hasFilters =
        selectedCategory != null || selectedTags.isNotEmpty;
    const double _shellNavBarClearance = 78;
    const double _tasksBreathingRoom = 18;    

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Material(
        color: Colors.transparent,
        child: SizedBox.expand(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        "Discover",
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    _DiscoverHeaderIconButton(
                      icon: PhosphorIcons.mapTrifold(
                        PhosphorIconsStyle.bold,
                      ),
                      onTap: onTapMap,
                    ),
                    const SizedBox(width: 10),
                    _DiscoverHeaderIconButton(
                      icon: PhosphorIcons.magnifyingGlass(
                        PhosphorIconsStyle.bold,
                      ),
                      onTap: onTapSearch,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(30),
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F8),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(30),
                        ),
                        border: Border.all(
                          color: const Color(0xFFDDE3E8),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!locationOk) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                              child: _DiscoverLocationBanner(
                                onTap: onTapEnableLocation,
                              ),
                            ),
                            const SizedBox(height: 18),
                          ] else
                            const SizedBox(height: 18),

                          Expanded(
                            child: ListView(
                              physics: const ClampingScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(
                                16,
                                20,
                                16,
                                bottomInset + _shellNavBarClearance + _tasksBreathingRoom,
                              ),
                              children: [
                                const _SectionHeader(
                                  eyebrow: "Browse",
                                  title: "Discover by Category",
                                  darkText: true,
                                ),
                                const SizedBox(height: 12),

                                _ParallaxChipRows(
                                  categoryController: categoryController,
                                  tagController: tagController,
                                  categories: categories,
                                  tags: tags,
                                  selectedCategory: selectedCategory,
                                  selectedTags: selectedTags,
                                  onTapCategory: onTapCategory,
                                  onTapTag: onTapTag,
                                ),

                                if (hasFilters) ...[
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: onClearFilters,
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 0,
                                          vertical: 0,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text(
                                        "Clear filters",
                                        style: TextStyle(
                                          fontFamily: "Nunito",
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 24),

                                _SectionHeader(
                                  eyebrow: "Near You",
                                  title: "Your Pings",
                                  darkText: true,
                                  trailingText:
                                      allNearbyCount > 0 ? "View All" : null,
                                  onTapTrailing:
                                      allNearbyCount > 0 ? onTapViewAll : null,
                                ),
                                const SizedBox(height: 12),

                                if (loading)
                                  const _DiscoverContentSkeleton.light()
                                else
                                  _DiscoverPingShelf(
                                    items: nearbyItems,
                                    me: me,
                                    onTapPing: onTapPing,
                                  ),

                                const SizedBox(height: 16),
                                const _DiscoverGrowBanner(),
                                const SizedBox(height: 22),

                                const _SectionHeader(
                                  eyebrow: "Popular Events",
                                  title: "Coming Soon",
                                  darkText: true,
                                ),
                                const SizedBox(height: 12),

                                const _DiscoverComingSoonShelf(
                                  title: "Events are coming soon",
                                  subtitle:
                                      "This section is reserved for nearby events.",
                                  iconData: PhosphorIcons.calendarDots,
                                ),

                                const SizedBox(height: 22),

                                const _SectionHeader(
                                  eyebrow: "Community",
                                  title: "Tasks",
                                  darkText: true,
                                ),
                                const SizedBox(height: 12),

                                const _DiscoverTasksPlaceholder(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _DiscoverGrowBanner extends StatelessWidget {
  const _DiscoverGrowBanner();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        width: double.infinity,
        height: 112, // slim, not bulky
        child: Image.asset(
          'assets/images/grow.png',
          fit: BoxFit.cover, // no squashing
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) {
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7F9),
                borderRadius: BorderRadius.circular(22),
              ),
              alignment: Alignment.center,
              child: Text(
                "grow.png missing",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(.45),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DiscoverHeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _DiscoverHeaderIconButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: const Color(0xFF111827).withOpacity(.92),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(.14),
              width: 1,
            ),
            boxShadow: const [],
          ),
          child: Center(
            child: Icon(
              icon,
              size: 21,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoverLauncherBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _DiscoverLauncherBar({
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAF8).withOpacity(.95),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: Colors.white.withOpacity(.76),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 22,
                    offset: const Offset(0, 12),
                    color: Colors.black.withOpacity(.10),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppColors.brandGreen.withOpacity(.24),
                              AppColors.brandGreen.withOpacity(.12),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.brandGreen.withOpacity(.20),
                          ),
                        ),
                        child: Icon(
                          PhosphorIcons.compassRose(
                            PhosphorIconsStyle.fill,
                          ),
                          size: 28,
                          color: AppColors.brandGreen,
                        ),
                      ),

                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                                color: Colors.black.withOpacity(.08),
                              ),
                            ],
                          ),
                          child: Icon(
                            PhosphorIcons.sparkle(
                              PhosphorIconsStyle.fill,
                            ),
                            size: 11,
                            color: AppColors.brandGreen,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(width: 14),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                "Discover",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF111111),
                                  height: 1.0,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ),

                        const SizedBox(height: 7),

                        Text(
                          "Pings • Events • Tasks",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.2,
                            fontWeight: FontWeight.w600,
                            color: AppColors.brandGreen,
                            height: 1.0,
                          ),
                        ),

                        const SizedBox(height: 6),

                        Text(
                          "See what is happening around you right now",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 11.8,
                            fontWeight: FontWeight.w500,
                            color: Colors.black.withOpacity(.48),
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 10),

                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      PhosphorIcons.caretUp(PhosphorIconsStyle.bold),
                      size: 17,
                      color: Colors.white,
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

class _SectionHeader extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String? trailingText;
  final VoidCallback? onTapTrailing;
  final bool darkText;

  const _SectionHeader({
    required this.eyebrow,
    required this.title,
    this.trailingText,
    this.onTapTrailing,
    this.darkText = false,
  });

  @override
  Widget build(BuildContext context) {
    final eyebrowColor =
        darkText ? const Color(0xFF6B7280) : Colors.white.withOpacity(.58);

    final titleColor =
        darkText ? const Color(0xFF111111) : Colors.white;

    final trailingColor =
        darkText ? const Color(0xFF111111) : Colors.white.withOpacity(.82);

    final trailingBg =
        darkText ? const Color(0xFFF5F7F9) : Colors.white.withOpacity(.14);    

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: eyebrowColor,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                title,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: titleColor,
                ),
              ),
            ],
          ),
        ),
        if (trailingText != null && onTapTrailing != null)
          TextButton(
            onPressed: onTapTrailing,
            child: Text(
              trailingText!,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: trailingColor,
              ),
            ),
          ),
      ],
    );
  }
}

class _DiscoverLocationBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _DiscoverLocationBanner({
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE7EAEE)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF2F4),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.location_off_rounded,
              color: Color(0xFF111111),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              "Turn on location to discover nearby pings properly.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111111),
              ),
            ),
          ),
          TextButton(
            onPressed: onTap,
            child: const Text(
              "Enable",
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w600,
                color: AppColors.brandGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParallaxChipRows extends StatelessWidget {
  final ScrollController categoryController;
  final ScrollController tagController;
  final List<String> categories;
  final List<String> tags;
  final String? selectedCategory;
  final Set<String> selectedTags;
  final void Function(String) onTapCategory;
  final void Function(String) onTapTag;

  const _ParallaxChipRows({
    required this.categoryController,
    required this.tagController,
    required this.categories,
    required this.tags,
    required this.selectedCategory,
    required this.selectedTags,
    required this.onTapCategory,
    required this.onTapTag,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 46,
          child: ListView.separated(
            controller: categoryController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final raw = categories[index];
              final value = raw.trim().toLowerCase();
              final selected = selectedCategory == value;
              final style = _discoverChipCategoryStyle(raw);

              return _DiscoverFilterChip(
                label: _prettyCategory(raw),
                selected: selected,
                icon: style.icon,
                iconColor: style.color,
                fontSize: 12.2,
                selectedFontWeight: FontWeight.w600,
                unselectedFontWeight: FontWeight.w500,
                onTap: () => onTapCategory(raw),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          child: ListView.separated(
            controller: tagController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: tags.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final raw = tags[index].trim();
              final normalized = raw.startsWith('#')
                  ? raw.toLowerCase()
                  : '#${raw.toLowerCase()}';

              final selected = selectedTags.contains(normalized);

              return _DiscoverFilterChip(
                label: raw.startsWith('#') ? raw : '#$raw',
                selected: selected,
                dense: true,
                fontSize: 11.8,
                selectedFontWeight: FontWeight.w600,
                unselectedFontWeight: FontWeight.w500,
                onTap: () => onTapTag(raw),
              );
            },
          ),
        ),
      ],
    );
  }

  String _prettyCategory(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return raw;
    return cleaned[0].toUpperCase() + cleaned.substring(1).toLowerCase();
  }
}

({IconData icon, Color color}) _discoverChipCategoryStyle(String category) {
  final c = category.trim().toLowerCase();

  if (c.contains("study")) {
    return (
      icon: PhosphorIcons.books(PhosphorIconsStyle.regular),
      color: const Color(0xFF6C5CE7),
    );
  }
  if (c.contains("gym")) {
    return (
      icon: PhosphorIcons.barbell(PhosphorIconsStyle.regular),
      color: const Color(0xFFE74C3C),
    );
  }
  if (c.contains("gaming")) {
    return (
      icon: PhosphorIcons.gameController(PhosphorIconsStyle.regular),
      color: const Color(0xFF9B59B6),
    );
  }
  if (c.contains("network")) {
    return (
      icon: PhosphorIcons.handshake(PhosphorIconsStyle.regular),
      color: const Color(0xFF3498DB),
    );
  }
  if (c.contains("help")) {
    return (
      icon: PhosphorIcons.firstAidKit(PhosphorIconsStyle.regular),
      color: const Color(0xFFE67E22),
    );
  }
  if (c.contains("support")) {
    return (
      icon: PhosphorIcons.handHeart(PhosphorIconsStyle.regular),
      color: const Color(0xFF1ABC9C),
    );
  }
  if (c.contains("event")) {
    return (
      icon: PhosphorIcons.calendar(PhosphorIconsStyle.regular),
      color: const Color(0xFFF39C12),
    );
  }
  if (c.contains("hangout")) {
    return (
      icon: PhosphorIcons.smiley(PhosphorIconsStyle.regular),
      color: const Color(0xFFE91E63),
    );
  }
  if (c.contains("instant")) {
    return (
      icon: PhosphorIcons.lightning(PhosphorIconsStyle.regular),
      color: const Color(0xFFFFB800),
    );
  }
  if (c.contains("food")) {
    return (
      icon: PhosphorIcons.pizza(PhosphorIconsStyle.regular),
      color: const Color(0xFFFF6B6B),
    );
  }
  if (c.contains("music")) {
    return (
      icon: PhosphorIcons.musicNotes(PhosphorIconsStyle.regular),
      color: const Color(0xFFFF1744),
    );
  }
  if (c.contains("sport")) {
    return (
      icon: PhosphorIcons.basketball(PhosphorIconsStyle.regular),
      color: const Color(0xFF2196F3),
    );
  }

  final customColors = [
    const Color(0xFF00BCD4),
    const Color(0xFF009688),
    const Color(0xFF8BC34A),
    const Color(0xFFFF5722),
    const Color(0xFFE91E63),
  ];

  return (
    icon: PhosphorIcons.sparkle(PhosphorIconsStyle.regular),
    color: customColors[category.hashCode.abs() % customColors.length],
  );
}

class _DiscoverFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dense;
  final IconData? icon;
  final Color? iconColor;
  final double fontSize;
  final FontWeight selectedFontWeight;
  final FontWeight unselectedFontWeight;
  final VoidCallback onTap;

  const _DiscoverFilterChip({
    required this.label,
    required this.selected,
    this.dense = false,
    this.icon,
    this.iconColor,
    this.fontSize = 12,
    this.selectedFontWeight = FontWeight.w600,
    this.unselectedFontWeight = FontWeight.w500,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppColors.brandGreen.withOpacity(.10)
        : Colors.white;

    final textColor = selected
        ? const Color(0xFF111111)
        : const Color(0xFF4B5563);

    final resolvedIconColor = selected
        ? (iconColor ?? AppColors.brandGreen)
        : (iconColor ?? const Color(0xFF6B7280));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: dense ? 42 : 46,
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 13,
            vertical: 0,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: resolvedIconColor,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: fontSize,
                  fontWeight:
                      selected ? selectedFontWeight : unselectedFontWeight,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoverChip extends StatelessWidget {
  final String label;
  final bool outlined;
  final VoidCallback onTap;

  const _DiscoverChip({
    required this.label,
    required this.outlined,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: outlined ? Colors.transparent : Colors.white.withOpacity(.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              color: Colors.white.withOpacity(.92),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoverPingShelf extends StatelessWidget {
  final List<_PingPreview> items;
  final LatLng? me;
  final void Function(_PingPreview) onTapPing;

  const _DiscoverPingShelf({
    required this.items,
    required this.me,
    required this.onTapPing,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _DiscoverComingSoonShelf(
        title: "No nearby pings found",
        subtitle: "When people create pings around you, they will show here.",
        iconData: PhosphorIcons.mapPin,
      );
    }

    // Single-result state: do NOT keep the 3-row shelf behavior.
    if (items.length == 1) {
      final ping = items.first;
      return _DiscoverFeaturedPingCard(
        ping: ping,
        me: me,
        onTap: () => onTapPing(ping),
      );
    }

    final groups = <List<_PingPreview>>[];
    for (int i = 0; i < items.length; i += 3) {
      groups.add(items.skip(i).take(3).toList());
    }

    return SizedBox(
      height: 402,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(right: 28),
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) {
          final group = groups[index];

          return SizedBox(
            width: math.min(
              MediaQuery.of(context).size.width * .72,
              300,
            ),
            child: Column(
              children: List.generate(group.length, (i) {
                final ping = group[i];
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: i == group.length - 1 ? 0 : 10,
                    ),
                    child: _DiscoverPingCard(
                      ping: ping,
                      me: me,
                      onTap: () => onTapPing(ping),
                    ),
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }
}

bool _isPingNew(DateTime? createdAt) {
  if (createdAt == null) return false;
  return DateTime.now().difference(createdAt).inMinutes < 15;
}

class _NewPingBadge extends StatelessWidget {
  const _NewPingBadge();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: const BoxDecoration(
          color: AppColors.brandGreen,
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(14),
          ),
        ),
        child: const Text(
          "NEW",
          style: TextStyle(
            fontFamily: "Nunito",
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _DiscoverPingCard extends StatelessWidget {
  final _PingPreview ping;
  final LatLng? me;
  final VoidCallback onTap;

  const _DiscoverPingCard({
    required this.ping,
    required this.me,
    required this.onTap,
  });

  String _distanceText() {
    if (me == null) return "Nearby";

    final meters = Geolocator.distanceBetween(
      me!.latitude,
      me!.longitude,
      ping.at.latitude,
      ping.at.longitude,
    );

    if (meters < 1000) return "${meters.round()} m";
    return "${(meters / 1000).toStringAsFixed(1)} km";
  }

  String _timeLine() {
    final dt =
        ping.scheduledStartAt ??
        ping.startAt ??
        ping.createdAt ??
        ping.endsAt;
    if (dt == null) return "Now";

    int hour = dt.hour % 12;
    if (hour == 0) hour = 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final meridiem = dt.hour >= 12 ? "pm" : "am";

    return "$hour:$minute $meridiem";
  }

  Widget _thumbnail() {
    final style = _discoverCategoryStyle(ping.category);
    final thumb = ping.media.isNotEmpty ? ping.media.first.thumbUrl.trim() : "";

    return Stack(
      children: [
        if (thumb.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.network(
              thumb,
              width: 62,
              height: 62,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallbackThumb(style.icon, style.color),
            ),
          )
        else
          _fallbackThumb(style.icon, style.color),

        Positioned(
          left: 6,
          top: 6,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.96),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                  color: Colors.black.withOpacity(.08),
                ),
              ],
            ),
            child: Icon(
              _discoverChipCategoryStyle(ping.category).icon,
              size: 12.5,
              color: _discoverChipCategoryStyle(ping.category).color,
            ),
          ),
        ),

        if (ping.participantCount > 1)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.72),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                "${ping.participantCount}",
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _fallbackThumb(IconData icon, Color color) {
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        icon,
        size: 24,
        color: color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distanceText = _distanceText();
    final timeLine = _timeLine();
    final isNew = _isPingNew(ping.createdAt);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                    color: Colors.black.withOpacity(.045),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                child: Row(
                  children: [
                    _thumbnail(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(right: isNew ? 58 : 0),
                            child: Row(
                              children: [
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.brandGreen.withOpacity(.10),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    distanceText,
                                    style: const TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 10.8,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.brandGreen,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ping.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              height: 1.12,
                              color: Color(0xFF111111),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Expanded(
                                child: _DiscoverMiniHostRow(
                                  creatorId: ping.creatorId,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  timeLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black.withOpacity(.56),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (isNew)
          const Positioned(
            top: 0,
            right: 0,
            child: _NewPingBadge(),
          ),
      ],
    );
  }
}

class _DiscoverMiniHostRow extends StatefulWidget {
  final String creatorId;

  const _DiscoverMiniHostRow({
    required this.creatorId,
  });

  @override
  State<_DiscoverMiniHostRow> createState() => _DiscoverMiniHostRowState();
}

class _DiscoverMiniHostRowState extends State<_DiscoverMiniHostRow> {
  static final Map<String, _DiscoverHostMeta> _cache = {};
  late Future<_DiscoverHostMeta> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _DiscoverMiniHostRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.creatorId != widget.creatorId) {
      _future = _load();
    }
  }

  Future<_DiscoverHostMeta> _load() async {
    final uid = widget.creatorId.trim();
    if (uid.isEmpty) {
      return const _DiscoverHostMeta(
        fullName: "Pingmee user",
        username: "",
        photoUrl: "",
        isVerified: false,
      );
    }

    final cached = _cache[uid];
    if (cached != null) return cached;

    final snap = await FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .get();

    final d = snap.data() ?? <String, dynamic>{};
    final verification = Map<String, dynamic>.from(d["verification"] ?? {});

    final host = _DiscoverHostMeta(
      fullName: ((d["fullName"] ?? d["displayName"] ?? "Pingmee user") as String)
          .trim()
          .isEmpty
          ? "Pingmee user"
          : ((d["fullName"] ?? d["displayName"] ?? "Pingmee user") as String).trim(),
      username: (d["username"] ?? "").toString().trim(),
      photoUrl: (d["photoUrl"] ?? "").toString().trim(),
      isVerified: verification["status"] == "verified",
    );

    _cache[uid] = host;
    return host;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DiscoverHostMeta>(
      future: _future,
      builder: (context, snapshot) {
        final host = snapshot.data;

        if (host == null) {
          return Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color(0xFFEFF3F6),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                "Loading...",
                style: TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withOpacity(.45),
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            _DiscoverMiniHostAvatar(photoUrl: host.photoUrl),
            const SizedBox(width: 6),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      host.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 11.8,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ),
                  if (host.isVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.verified_rounded,
                      size: 13.5,
                      color: Color(0xFF1D9BF0),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DiscoverMiniHostAvatar extends StatelessWidget {
  final String photoUrl;

  const _DiscoverMiniHostAvatar({
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    if (photoUrl.trim().isNotEmpty) {
      return ClipOval(
        child: Image.network(
          photoUrl,
          width: 20,
          height: 20,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }

    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 20,
      height: 20,
      decoration: const BoxDecoration(
        color: Color(0xFFEFF3F6),
        shape: BoxShape.circle,
      ),
      child: Icon(
        PhosphorIcons.user(PhosphorIconsStyle.regular),
        size: 11,
        color: const Color(0xFF6B7280),
      ),
    );
  }
}

class _DiscoverFeaturedPingCard extends StatelessWidget {
  final _PingPreview ping;
  final LatLng? me;
  final VoidCallback onTap;

  const _DiscoverFeaturedPingCard({
    required this.ping,
    required this.me,
    required this.onTap,
  });

  String _distanceText() {
    if (me == null) return "Nearby";

    final meters = Geolocator.distanceBetween(
      me!.latitude,
      me!.longitude,
      ping.at.latitude,
      ping.at.longitude,
    );

    if (meters < 1000) return "${meters.round()} m away";
    return "${(meters / 1000).toStringAsFixed(1)} km away";
  }

  String _dateLine() {
    final dt =
        ping.scheduledStartAt ??
        ping.startAt ??
        ping.createdAt ??
        ping.endsAt;
    if (dt == null) return "Happening nearby";

    const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ];

    final weekday = weekdays[dt.weekday - 1];
    final month = months[dt.month - 1];
    int hour = dt.hour % 12;
    if (hour == 0) hour = 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final meridiem = dt.hour >= 12 ? "pm" : "am";

    return "$weekday ${dt.day} $month • $hour:$minute $meridiem";
  }

  Widget _mediaThumb() {
    final style = _discoverCategoryStyle(ping.category);
    final thumb = ping.media.isNotEmpty ? ping.media.first.thumbUrl.trim() : "";

    if (thumb.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.network(
          thumb,
          width: 84,
          height: 84,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: style.color.withOpacity(.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              style.icon,
              size: 30,
              color: style.color,
            ),
          ),
        ),
      );
    }

    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: style.color.withOpacity(.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Icon(
        style.icon,
        size: 30,
        color: style.color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = _discoverCategoryStyle(ping.category);
    final title = ping.title.trim().isEmpty ? "Ping" : ping.title.trim();
    final categoryText =
        ping.category.trim().isEmpty ? "Ping" : ping.category.trim();
    final placeText = ping.meetingPoint.trim().isNotEmpty
        ? ping.meetingPoint.trim()
        : ping.placeName.trim();
    final description = ping.description.trim().isNotEmpty
        ? ping.description.trim()
        : "Open this ping to see more details.";
    final isNew = _isPingNew(ping.createdAt);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                    color: Colors.black.withOpacity(.04),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _mediaThumb(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: isNew ? 58 : 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      style.icon,
                                      size: 15,
                                      color: style.color,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        categoryText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: "Nunito",
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: style.color,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    height: 1.12,
                                    color: Color(0xFF111111),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _dateLine(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black.withOpacity(.56),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _DiscoverHostRow(creatorId: ping.creatorId),
                    const SizedBox(height: 12),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.8,
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                        color: Colors.black.withOpacity(.66),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MiniMetaPill(
                          icon: PhosphorIcons.mapPin(
                            PhosphorIconsStyle.regular,
                          ),
                          label: placeText.isEmpty ? _distanceText() : placeText,
                          maxWidth: math.min(
                            MediaQuery.of(context).size.width * .58,
                            240,
                          ),
                        ),
                        _MiniMetaPill(
                          icon: PhosphorIcons.users(
                            PhosphorIconsStyle.regular,
                          ),
                          label: "${ping.participantCount} joined",
                        ),
                        _MiniMetaPill(
                          icon: PhosphorIcons.arrowRight(
                            PhosphorIconsStyle.regular,
                          ),
                          label: _distanceText(),
                        ),
                      ],
                    ),
                    if (ping.tags.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ping.tags.take(3).map((tag) {
                          final normalized = tag.startsWith('#') ? tag : '#$tag';
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F7F9),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              normalized,
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF4B5563),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (isNew)
          const Positioned(
            top: 0,
            right: 0,
            child: _NewPingBadge(),
          ),
      ],
    );
  }
}

class _DiscoverHostRow extends StatefulWidget {
  final String creatorId;

  const _DiscoverHostRow({
    required this.creatorId,
  });

  @override
  State<_DiscoverHostRow> createState() => _DiscoverHostRowState();
}

class _DiscoverHostRowState extends State<_DiscoverHostRow> {
  late Future<_DiscoverHostMeta> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _DiscoverHostRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.creatorId != widget.creatorId) {
      _future = _load();
    }
  }

  Future<_DiscoverHostMeta> _load() async {
    final uid = widget.creatorId.trim();
    if (uid.isEmpty) {
      return const _DiscoverHostMeta(
        fullName: "Pingmee user",
        username: "",
        photoUrl: "",
        isVerified: false,
      );
    }

    final snap = await FirebaseFirestore.instance
        .collection("users")
        .doc(uid)
        .get();

    final d = snap.data() ?? <String, dynamic>{};
    final verification = Map<String, dynamic>.from(d["verification"] ?? {});

    final fullName = (d["fullName"] ?? d["displayName"] ?? "Pingmee user")
        .toString()
        .trim();

    return _DiscoverHostMeta(
      fullName: fullName.isEmpty ? "Pingmee user" : fullName,
      username: (d["username"] ?? "").toString().trim(),
      photoUrl: (d["photoUrl"] ?? "").toString().trim(),
      isVerified: verification["status"] == "verified",
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DiscoverHostMeta>(
      future: _future,
      builder: (context, snapshot) {
        final host = snapshot.data;

        if (host == null) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F9FB),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF3F6),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Loading host...",
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: 12.5,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F9FB),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              _DiscoverHostAvatar(photoUrl: host.photoUrl),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Host",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(.50),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF111111),
                            ),
                          ),
                        ),
                        if (host.isVerified) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.verified_rounded,
                            size: 16,
                            color: Color(0xFF1D9BF0),
                          ),
                        ],
                      ],
                    ),
                    if (host.username.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        "@${host.username}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Colors.black.withOpacity(.55),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DiscoverHostAvatar extends StatelessWidget {
  final String photoUrl;

  const _DiscoverHostAvatar({
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    if (photoUrl.trim().isNotEmpty) {
      return ClipOval(
        child: Image.network(
          photoUrl,
          width: 38,
          height: 38,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        ),
      );
    }

    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 38,
      height: 38,
      decoration: const BoxDecoration(
        color: Color(0xFFEFF3F6),
        shape: BoxShape.circle,
      ),
      child: Icon(
        PhosphorIcons.user(PhosphorIconsStyle.regular),
        size: 18,
        color: const Color(0xFF6B7280),
      ),
    );
  }
}

class _DiscoverHostMeta {
  final String fullName;
  final String username;
  final String photoUrl;
  final bool isVerified;

  const _DiscoverHostMeta({
    required this.fullName,
    required this.username,
    required this.photoUrl,
    required this.isVerified,
  });
}

class _MiniMetaPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final double? maxWidth;

  const _MiniMetaPill({
    required this.icon,
    required this.label,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth ?? 220,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F7F9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: const Color(0xFF6B7280),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: "Nunito",
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverComingSoonShelf extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData Function(PhosphorIconsStyle) iconData;

  const _DiscoverComingSoonShelf({
    required this.title,
    required this.subtitle,
    required this.iconData,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, __) {
          return Container(
            width: math.min(MediaQuery.of(context).size.width * .78, 320),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE4E8EC)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withOpacity(.10),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    iconData(PhosphorIconsStyle.fill),
                    color: const Color(0xFF8B5CF6),
                    size: 24,
                  ),
                ),
                const Spacer(),
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DiscoverTasksPlaceholder extends StatelessWidget {
  const _DiscoverTasksPlaceholder();

  @override
  Widget build(BuildContext context) {
    final items = const [
      (
        title: "Community tasks",
        subtitle: "Simple paid jobs and volunteer work will appear here."
      ),
      (
        title: "Local help requests",
        subtitle: "Communities will soon be able to post quick help opportunities."
      ),
      (
        title: "Task matching",
        subtitle: "This will later match people to nearby community tasks."
      ),
    ];

    return Column(
      children: List.generate(items.length, (i) {
        final item = items[i];
        return Padding(
          padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE4E8EC)),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen.withOpacity(.14),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    PhosphorIcons.briefcase(PhosphorIconsStyle.fill),
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
                        item.title,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111111),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        item.subtitle,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _DiscoverContentSkeleton extends StatelessWidget {
  final bool light;

  const _DiscoverContentSkeleton({
    this.light = false,
  });

  const _DiscoverContentSkeleton.light() : light = true;

  Color _baseFill(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDark) {
      return const Color(0xFF232A31);
    }

    return light
        ? const Color(0xFFE1E7ED)
        : const Color(0xFFDEE5EC);
  }

  Color _cardFill(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isDark) {
      return const Color(0xFF1C232A);
    }

    return light
        ? const Color(0xFFE8EDF2)
        : const Color(0xFFE3E9EF);
  }

  Widget _box(
    BuildContext context, {
    double? width,
    double height = 16,
    BorderRadius? radius,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _baseFill(context),
        borderRadius: radius ?? BorderRadius.circular(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _box(context, width: 96, height: 12),
        const SizedBox(height: 8),
        _box(context, width: 180, height: 28),
        const SizedBox(height: 16),
        ...List.generate(
          3,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              height: 94,
              decoration: BoxDecoration(
                color: _cardFill(context),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _box(context, width: 130, height: 12),
        const SizedBox(height: 8),
        _box(context, width: 210, height: 24),
        const SizedBox(height: 16),
        SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 5,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, __) => _box(
              context,
              width: 96,
              height: 46,
              radius: BorderRadius.circular(999),
            ),
          ),
        ),
      ],
    );
  }
}

enum _DiscoverAllMode {
  forYou,
  nearMe,
  newest,
}

class _DiscoverAllPingsScreen extends StatefulWidget {
  final List<_PingPreview> items;
  final LatLng? me;
  final List<String> categories;
  final String? initialCategory;
  final Set<String> initialTags;
  final List<String> viewerInterests;
  final List<String> viewerSkills;
  final void Function(_PingPreview) onTapPing;

  const _DiscoverAllPingsScreen({
    required this.items,
    required this.me,
    required this.categories,
    required this.initialCategory,
    required this.initialTags,
    required this.viewerInterests,
    required this.viewerSkills,
    required this.onTapPing,
  });

  @override
  State<_DiscoverAllPingsScreen> createState() => _DiscoverAllPingsScreenState();
}

class _DiscoverAllPingsScreenState extends State<_DiscoverAllPingsScreen> {
  _DiscoverAllMode _mode = _DiscoverAllMode.forYou;
  late String? _selectedCategory;
  late Set<String> _selectedTags;
  final Set<String> _selectedProfileTerms = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _selectedTags = {...widget.initialTags};
  }

  List<String> get _profileInterestTerms => _dedupePretty(widget.viewerInterests);
  List<String> get _profileSkillTerms => _dedupePretty(widget.viewerSkills);

  List<String> get _profileTermsCombined =>
      _dedupePretty([...widget.viewerInterests, ...widget.viewerSkills]);

  List<_PingPreview> get _visibleItems {
    final list = widget.items.where(_matchesAllFilters).toList();

    switch (_mode) {
      case _DiscoverAllMode.nearMe:
        list.sort(_distanceCompare);
        break;
      case _DiscoverAllMode.newest:
        list.sort((a, b) {
          final ad = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final cmp = bd.compareTo(ad);
          if (cmp != 0) return cmp;
          return _distanceCompare(a, b);
        });
        break;
      case _DiscoverAllMode.forYou:
        list.sort((a, b) {
          final scoreCmp = _scorePing(b).compareTo(_scorePing(a));
          if (scoreCmp != 0) return scoreCmp;
          return _distanceCompare(a, b);
        });
        break;
    }

    return list;
  }

  List<String> get _availableTags {
    final counts = <String, int>{};

    final source = widget.items.where((p) {
      if (_selectedCategory != null &&
          _normalizeCategory(p.category) != _selectedCategory) {
        return false;
      }
      if (_selectedProfileTerms.isNotEmpty &&
          !_selectedProfileTerms.any((term) => _matchesProfileTerm(p, term))) {
        return false;
      }
      return true;
    });

    for (final ping in source) {
      for (final raw in ping.tags) {
        final cleaned = raw.trim();
        if (cleaned.isEmpty) continue;

        final tag = cleaned.startsWith('#')
            ? cleaned.toLowerCase()
            : '#${cleaned.toLowerCase()}';

        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }

    final tags = counts.keys.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));

    return tags.take(20).toList();
  }

  int _distanceCompare(_PingPreview a, _PingPreview b) {
    if (widget.me == null) return 0;

    final da = Geolocator.distanceBetween(
      widget.me!.latitude,
      widget.me!.longitude,
      a.at.latitude,
      a.at.longitude,
    );

    final db = Geolocator.distanceBetween(
      widget.me!.latitude,
      widget.me!.longitude,
      b.at.latitude,
      b.at.longitude,
    );

    return da.compareTo(db);
  }

  bool _matchesAllFilters(_PingPreview ping) {
    if (_selectedCategory != null &&
        _normalizeCategory(ping.category) != _selectedCategory) {
      return false;
    }

    final pingTags = ping.tags
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('#') ? e : '#$e')
        .toSet();

    for (final tag in _selectedTags) {
      if (!pingTags.contains(tag)) return false;
    }

    if (_selectedProfileTerms.isNotEmpty &&
        !_selectedProfileTerms.any((term) => _matchesProfileTerm(ping, term))) {
      return false;
    }

    return true;
  }

  int _scorePing(_PingPreview ping) {
    var score = 0;

    if (widget.me != null) {
      final meters = Geolocator.distanceBetween(
        widget.me!.latitude,
        widget.me!.longitude,
        ping.at.latitude,
        ping.at.longitude,
      );

      if (meters <= 200) {
        score += 40;
      } else if (meters <= 700) {
        score += 32;
      } else if (meters <= 1500) {
        score += 24;
      } else if (meters <= 3000) {
        score += 16;
      } else {
        score += 8;
      }
    }

    final profileInterestMatches = _profileInterestTerms
        .where((term) => _matchesProfileTerm(ping, term))
        .length;

    final profileSkillMatches = _profileSkillTerms
        .where((term) => _matchesProfileTerm(ping, term))
        .length;

    score += profileInterestMatches * 12;
    score += profileSkillMatches * 8;

    if (_selectedProfileTerms.isNotEmpty) {
      final explicitMatches = _selectedProfileTerms
          .where((term) => _matchesProfileTerm(ping, term))
          .length;
      score += explicitMatches * 18;
    }

    score += _selectedTags
        .where((tag) => ping.tags.map((e) => e.toLowerCase()).contains(tag.replaceFirst('#', '')) ||
            ping.tags.map((e) => e.toLowerCase()).contains(tag))
        .length *
        8;

    final age = DateTime.now().difference(
      ping.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );

    if (age.inMinutes <= 30) {
      score += 8;
    } else if (age.inHours <= 4) {
      score += 5;
    } else if (age.inHours <= 24) {
      score += 2;
    }

    if (ping.participantCount >= 4) {
      score += 4;
    }

    return score;
  }

  Map<String, Set<String>> get _semanticAliases => {
    "photography": {
      "camera",
      "photo",
      "photos",
      "photographer",
      "videography",
      "filming",
      "film",
      "cinematography",
      "content creation",
      "nature",
    },
    "nature": {
      "outdoors",
      "wildlife",
      "hiking",
      "trees",
      "travel",
      "photography",
      "filming",
    },
    "movies": {
      "film",
      "cinema",
      "filming",
      "videography",
    },
    "music": {
      "singing",
      "guitar",
      "piano",
      "music production",
      "beats",
    },
    "fitness": {
      "gym",
      "workout",
      "training",
      "personal training",
      "fitness coaching",
    },
    "sports": {
      "football",
      "soccer",
      "basketball",
      "running",
    },
    "technology": {
      "tech",
      "ai",
      "ml",
      "flutter",
      "web development",
      "game development",
      "cybersecurity",
      "data analysis",
    },
    "business": {
      "startup",
      "startups",
      "startup founder",
      "business strategy",
      "founder",
      "marketing",
      "networking",
    },
    "art": {
      "graphic design",
      "ui ux design",
      "ui ux",
      "3d design",
      "painting",
      "drawing",
      "creative",
    },
    "travel": {
      "nature",
      "outdoors",
      "adventure",
      "hiking",
    },
  };

  Set<String> _termVariants(String raw) {
    final n = _normalizeLoose(raw);
    if (n.isEmpty) return const {};

    final variants = <String>{n};

    for (final entry in _semanticAliases.entries) {
      final key = _normalizeLoose(entry.key);
      final values = entry.value.map(_normalizeLoose).toSet();

      if (n == key || values.contains(n)) {
        variants.add(key);
        variants.addAll(values);
      }
    }

    return variants;
  }

  int _scorePingAgainstTerm(_PingPreview ping, String term) {
    final variants = _termVariants(term);
    if (variants.isEmpty) return 0;

    final category = _normalizeLoose(ping.category);

    final tags = ping.tags
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetInterests = ping.targetInterests
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetSkills = ping.targetSkills
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetTerms = ping.targetTerms
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final keywords = ping.keywords
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final haystack = [
      ping.title,
      ping.description,
      ping.placeName,
      ping.meetingPoint,
      ping.category,
      ...ping.tags,
      ...ping.targetInterests,
      ...ping.targetSkills,
      ...ping.targetTerms,
      ...ping.keywords,
    ].map(_normalizeLoose).join(" ");

    int score = 0;

    for (final v in variants) {
      if (v.isEmpty) continue;

      if (category == v) score += 7;
      if (tags.contains(v)) score += 6;
      if (targetInterests.contains(v)) score += 8;
      if (targetSkills.contains(v)) score += 8;
      if (targetTerms.contains(v)) score += 7;
      if (keywords.contains(v)) score += 5;
      if (haystack.contains(v)) score += 2;
    }

    return score;
  }

  bool _matchesProfileTerm(_PingPreview ping, String term) {
    return _scorePingAgainstTerm(ping, term) > 0;
  }

  String _normalizeCategory(String raw) {
    final c = raw.trim().toLowerCase();

    if (c.contains("study")) return "study";
    if (c.contains("gym") || c.contains("fitness") || c.contains("workout")) {
      return "gym";
    }
    if (c.contains("gaming") || c.contains("game")) return "gaming";
    if (c.contains("network")) return "network";
    if (c.contains("help")) return "help";
    if (c.contains("support")) return "support";
    if (c.contains("event")) return "event";
    if (c.contains("hangout") || c.contains("hang out") || c.contains("chill")) {
      return "hangout";
    }
    if (c.contains("instant")) return "instant";
    if (c.contains("food") || c.contains("eat")) return "food";
    if (c.contains("music")) return "music";
    if (c.contains("sport")) return "sport";

    return c;
  }

  String _normalizeLoose(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll('#', '')
        .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _dedupePretty(List<String> input) {
    final seen = <String>{};
    final out = <String>[];

    for (final raw in input) {
      final cleaned = raw.trim();
      if (cleaned.isEmpty) continue;

      final key = _normalizeLoose(cleaned);
      if (key.isEmpty || seen.contains(key)) continue;

      seen.add(key);
      out.add(cleaned);
    }

    return out;
  }

  void _toggleTag(String raw) {
    final tag = raw.startsWith('#') ? raw.toLowerCase() : '#${raw.toLowerCase()}';

    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
    });
  }

  void _toggleProfileTerm(String term) {
    final normalized = _normalizeLoose(term);
    if (normalized.isEmpty) return;

    setState(() {
      if (_selectedProfileTerms.contains(normalized)) {
        _selectedProfileTerms.remove(normalized);
      } else {
        _selectedProfileTerms.add(normalized);
      }
    });
  }

  String? _reasonFor(_PingPreview ping) {
    final interestMatch = _profileInterestTerms.any((t) => _matchesProfileTerm(ping, t));
    final skillMatch = _profileSkillTerms.any((t) => _matchesProfileTerm(ping, t));

    if (_selectedProfileTerms.isNotEmpty &&
        _selectedProfileTerms.any((t) => _matchesProfileTerm(ping, t))) {
      return "Fits what you picked";
    }

    if (interestMatch) return "Matches your interests";
    if (skillMatch) return "Fits your skills";

    if (widget.me != null) {
      final meters = Geolocator.distanceBetween(
        widget.me!.latitude,
        widget.me!.longitude,
        ping.at.latitude,
        ping.at.longitude,
      );
      if (meters <= 250) return "Very close to you";
    }

    if (ping.participantCount >= 4) return "Getting attention nearby";
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final items = _visibleItems;
    final bg = const Color(0xFFEFF2F7);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => Navigator.pop(context),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.arrow_back_rounded, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "All nearby pings",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111111),
                          ),
                        ),
                        Text(
                          "Sorted for you using distance, interests, skills, category, and tags",
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 12.2,
                            fontWeight: FontWeight.w400,
                            color: Colors.black.withOpacity(.58),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      "${items.length}",
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildModeRow(),
                          const SizedBox(height: 16),
                          _buildCategoryRow(),
                          const SizedBox(height: 12),
                          if (_availableTags.isNotEmpty) _buildTagRow(),
                          if (_availableTags.isNotEmpty) const SizedBox(height: 14),
                          if (_profileTermsCombined.isNotEmpty) ...[
                            const Text(
                              "Because of your profile",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                            const SizedBox(height: 10),
                            _buildProfileTermRow(),
                            const SizedBox(height: 18),
                          ],
                          if (_selectedCategory != null ||
                              _selectedTags.isNotEmpty ||
                              _selectedProfileTerms.isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () {
                                  setState(() {
                                    _selectedCategory = null;
                                    _selectedTags.clear();
                                    _selectedProfileTerms.clear();
                                  });
                                },
                                child: const Text(
                                  "Clear filters",
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.brandGreen,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (items.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                blurRadius: 16,
                                offset: const Offset(0, 8),
                                color: Colors.black.withOpacity(.04),
                              ),
                            ],
                          ),
                          child: Text(
                            "No pings match these filters yet. Try removing a few and explore wider.",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              height: 1.35,
                              color: Colors.black.withOpacity(.62),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList.separated(
                      itemCount: items.length,
                      itemBuilder: (_, index) {
                        final ping = items[index];
                        return Padding(
                          padding: EdgeInsets.fromLTRB(
                            14,
                            index == 0 ? 0 : 0,
                            14,
                            12,
                          ),
                          child: _DiscoverAllPingCard(
                            ping: ping,
                            me: widget.me,
                            reason: _reasonFor(ping),
                            onTap: () => widget.onTapPing(ping),
                          ),
                        );
                      },
                      separatorBuilder: (_, __) => const SizedBox.shrink(),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 28)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeRow() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _DiscoverFilterChip(
            label: "For You",
            selected: _mode == _DiscoverAllMode.forYou,
            fontSize: 12.2,
            selectedFontWeight: FontWeight.w600,
            unselectedFontWeight: FontWeight.w500,
            icon: PhosphorIcons.sparkle(PhosphorIconsStyle.regular),
            iconColor: const Color(0xFF7C3AED),
            onTap: () => setState(() => _mode = _DiscoverAllMode.forYou),
          ),
          const SizedBox(width: 10),
          _DiscoverFilterChip(
            label: "Near Me",
            selected: _mode == _DiscoverAllMode.nearMe,
            fontSize: 12.2,
            selectedFontWeight: FontWeight.w600,
            unselectedFontWeight: FontWeight.w500,
            icon: PhosphorIcons.mapPin(PhosphorIconsStyle.regular),
            iconColor: AppColors.brandGreen,
            onTap: () => setState(() => _mode = _DiscoverAllMode.nearMe),
          ),
          const SizedBox(width: 10),
          _DiscoverFilterChip(
            label: "Newest",
            selected: _mode == _DiscoverAllMode.newest,
            fontSize: 12.2,
            selectedFontWeight: FontWeight.w600,
            unselectedFontWeight: FontWeight.w500,
            icon: PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.regular),
            iconColor: const Color(0xFF0EA5E9),
            onTap: () => setState(() => _mode = _DiscoverAllMode.newest),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryRow() {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, index) {
          final raw = widget.categories[index];
          final normalized = _normalizeCategory(raw);
          final selected = _selectedCategory == normalized;
          final style = _discoverChipCategoryStyle(raw);

          return _DiscoverFilterChip(
            label: raw[0].toUpperCase() + raw.substring(1).toLowerCase(),
            selected: selected,
            icon: style.icon,
            iconColor: style.color,
            fontSize: 12.2,
            selectedFontWeight: FontWeight.w600,
            unselectedFontWeight: FontWeight.w500,
            onTap: () {
              setState(() {
                if (_selectedCategory == normalized) {
                  _selectedCategory = null;
                } else {
                  _selectedCategory = normalized;
                }
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildTagRow() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _availableTags.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, index) {
          final tag = _availableTags[index];
          return _DiscoverFilterChip(
            label: tag,
            selected: _selectedTags.contains(tag),
            dense: true,
            fontSize: 11.8,
            selectedFontWeight: FontWeight.w600,
            unselectedFontWeight: FontWeight.w500,
            onTap: () => _toggleTag(tag),
          );
        },
      ),
    );
  }

  Widget _buildProfileTermRow() {
    final chips = <Widget>[];

    for (final term in _profileInterestTerms) {
      chips.add(
        _DiscoverFilterChip(
          label: term,
          selected: _selectedProfileTerms.contains(_normalizeLoose(term)),
          icon: PhosphorIcons.heart(PhosphorIconsStyle.regular),
          iconColor: const Color(0xFFE11D48),
          fontSize: 11.8,
          selectedFontWeight: FontWeight.w600,
          unselectedFontWeight: FontWeight.w500,
          onTap: () => _toggleProfileTerm(term),
        ),
      );
    }

    for (final term in _profileSkillTerms) {
      chips.add(
        _DiscoverFilterChip(
          label: term,
          selected: _selectedProfileTerms.contains(_normalizeLoose(term)),
          icon: PhosphorIcons.hash(PhosphorIconsStyle.regular),
          iconColor: const Color(0xFF0EA5E9),
          fontSize: 11.8,
          selectedFontWeight: FontWeight.w600,
          unselectedFontWeight: FontWeight.w500,
          onTap: () => _toggleProfileTerm(term),
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: chips,
    );
  }
}

class _DiscoverAllPingCard extends StatelessWidget {
  final _PingPreview ping;
  final LatLng? me;
  final String? reason;
  final VoidCallback onTap;

  const _DiscoverAllPingCard({
    required this.ping,
    required this.me,
    required this.reason,
    required this.onTap,
  });

  String _distanceText() {
    if (me == null) return "Nearby";

    final meters = Geolocator.distanceBetween(
      me!.latitude,
      me!.longitude,
      ping.at.latitude,
      ping.at.longitude,
    );

    if (meters < 1000) return "${meters.round()} m";
    return "${(meters / 1000).toStringAsFixed(1)} km";
  }

  String _timeLine() {
    final dt =
        ping.scheduledStartAt ??
        ping.startAt ??
        ping.createdAt ??
        ping.endsAt;
    if (dt == null) return "Now";

    int hour = dt.hour % 12;
    if (hour == 0) hour = 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final meridiem = dt.hour >= 12 ? "pm" : "am";

    return "$hour:$minute $meridiem";
  }

  Widget _thumb() {
    final style = _discoverChipCategoryStyle(ping.category);
    final thumb = ping.media.isNotEmpty ? ping.media.first.thumbUrl.trim() : "";

    if (thumb.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.network(
          thumb,
          width: 84,
          height: 84,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(style),
        ),
      );
    }

    return _fallback(style);
  }

  Widget _fallback(({IconData icon, Color color}) style) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: style.color.withOpacity(.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Icon(
        style.icon,
        size: 28,
        color: style.color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distanceText = _distanceText();
    final timeLine = _timeLine();
    final isNew = _isPingNew(ping.createdAt);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                    color: Colors.black.withOpacity(.04),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _thumb(),
                    const SizedBox(width: 12),

                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: isNew ? 58 : 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.brandGreen.withOpacity(.10),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    distanceText,
                                    style: const TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 10.8,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.brandGreen,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 5),

                            Text(
                              ping.title.trim().isEmpty ? "Ping" : ping.title.trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: "Nunito",
                                fontSize: 14.8,
                                fontWeight: FontWeight.w600,
                                height: 1.12,
                                color: Color(0xFF111111),
                              ),
                            ),

                            if (reason != null && reason!.trim().isNotEmpty) ...[
                              const SizedBox(height: 7),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF5F7F9),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  reason!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 11.2,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                              ),
                            ],

                            const SizedBox(height: 8),

                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    ping.meetingPoint.trim().isNotEmpty
                                        ? ping.meetingPoint.trim()
                                        : ping.placeName.trim().isNotEmpty
                                            ? ping.placeName.trim()
                                            : "Nearby",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 11.8,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.black.withOpacity(.58),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    timeLine,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.black.withOpacity(.56),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 8),

                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    "${ping.participantCount} joined",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 11.6,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black.withOpacity(.68),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        if (isNew)
          const Positioned(
            top: 0,
            right: 0,
            child: _NewPingBadge(),
          ),
      ],
    );
  }
}

class _AllPingMetaPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _AllPingMetaPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: const Color(0xFF6B7280),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }
}

({IconData icon, Color color}) _discoverCategoryStyle(String category) {
  final c = category.toLowerCase();

  if (c.contains("study")) {
    return (
      icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
      color: const Color(0xFF8B7CFF),
    );
  }
  if (c.contains("gym")) {
    return (
      icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF7A6B),
    );
  }
  if (c.contains("gaming")) {
    return (
      icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
      color: const Color(0xFFC17BFF),
    );
  }
  if (c.contains("network")) {
    return (
      icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
      color: const Color(0xFF61C8FF),
    );
  }
  if (c.contains("event")) {
    return (
      icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
      color: const Color(0xFFFFC857),
    );
  }
  if (c.contains("food")) {
    return (
      icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF8A65),
    );
  }
  if (c.contains("music")) {
    return (
      icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF5FA2),
    );
  }
  if (c.contains("sport")) {
    return (
      icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
      color: const Color(0xFF58A6FF),
    );
  }

  return (
    icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
    color: const Color(0xFF86EFAC),
  );
}


class _NearbyPingsPreviewState extends State<_NearbyPingsPreview> {
  int _tabIndex = 0; // 0 = pings, 1 = events


  @override
  Widget build(BuildContext context) {
    final count = widget.items.length;

    String subtitle;
    if (widget.loading) {
      subtitle = "Loading nearby…";
    } else {
      subtitle = "$count live ping${count == 1 ? '' : 's'} · events soon";
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: AppColors.brandGreen.withOpacity(.14),
              width: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 16,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: widget.onToggle,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen.withOpacity(.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.brandGreen.withOpacity(.18),
                        ),
                      ),
                      child: Icon(
                        PhosphorIcons.broadcast(PhosphorIconsStyle.light),
                        size: 28,
                        color: AppColors.brandGreen,
                      ),
                    ),

                    const SizedBox(width: 14),

                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  "Nearby pings and events",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                  style: TextStyle(
                                    fontFamily: "Nunito",
                                    fontSize: 13.8,
                                    fontWeight: FontWeight.w700,
                                    height: 1.0,
                                    color: Color(0xFF111111),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                widget.collapsed
                                    ? PhosphorIcons.caretDown(
                                        PhosphorIconsStyle.light,
                                      )
                                    : PhosphorIcons.caretUp(
                                        PhosphorIconsStyle.light,
                                      ),
                                size: 17,
                                color: const Color(0xFF111111),
                              ),
                            ],
                          ),

                          const SizedBox(height: 10),

                          Container(
                            height: 1,
                            width: double.infinity,
                            color: const Color(0xFFE8E8E8),
                          ),

                          const SizedBox(height: 10),

                          Text(
                            widget.collapsed ? subtitle : "Tap to collapse",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 11.8,
                              fontWeight: FontWeight.w500,
                              height: 1.0,
                              color: Colors.black.withOpacity(.58),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        if (!widget.collapsed) ...[
          const SizedBox(height: 10),
          // keep your expanded sheet below exactly as it already is
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                height: 360,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F6F8),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withOpacity(.65)),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                      color: Colors.black.withOpacity(.06),
                    ),
                  ],
                ),
                child: widget.loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.brandGreen,
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Nearby",
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _NearbySheetTab(
                                  label: "Pings",
                                  value: "$count",
                                  icon: PhosphorIcons.mapPin(
                                    PhosphorIconsStyle.fill,
                                  ),
                                  selected: _tabIndex == 0,
                                  onTap: () {
                                    setState(() => _tabIndex = 0);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _NearbySheetTab(
                                  label: "Events",
                                  value: "Soon",
                                  icon: PhosphorIcons.calendarBlank(
                                    PhosphorIconsStyle.regular,
                                  ),
                                  selected: _tabIndex == 1,
                                  onTap: () {
                                    setState(() => _tabIndex = 1);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: _tabIndex == 0
                                  ? (widget.items.isEmpty
                                      ? const _NearbyPingsEmptyState()
                                      : ListView.separated(
                                          key: const ValueKey('pings_tab'),
                                          itemCount: widget.items.length,
                                          physics:
                                              const BouncingScrollPhysics(),
                                          separatorBuilder: (_, __) =>
                                              const SizedBox(height: 10),
                                          itemBuilder: (_, i) => _NearbyPingRow(
                                            ping: widget.items[i],
                                            me: widget.me,
                                            onTap: () => widget.onTapPing(
                                              widget.items[i],
                                            ),
                                          ),
                                        ))
                                  : const _NearbyEventsEmptyState(
                                      key: ValueKey('events_tab'),
                                    ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}



class _NearbyPreviewChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool active;
  final bool showDot;

  const _NearbyPreviewChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.active,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? AppColors.brandGreen
        : const Color(0xFFF7F8FA);

    final border = active
        ? AppColors.brandGreen
        : Colors.black.withOpacity(.06);

    final textColor = active
        ? Colors.white
        : Colors.black.withOpacity(.82);

    final subColor = active
        ? Colors.white.withOpacity(.92)
        : Colors.black.withOpacity(.55);

    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
        boxShadow: active
            ? [
                BoxShadow(
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                  color: AppColors.brandGreen.withOpacity(.18),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: textColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "$label • $value",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: subColor,
              ),
            ),
          ),
          if (showDot)
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFF4DA3FF),
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

class _NearbySectionTitle extends StatelessWidget {
  final String title;

  const _NearbySectionTitle({
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: "Nunito",
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Colors.black87,
      ),
    );
  }
}

class _NearbySheetTab extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _NearbySheetTab({
    required this.label,
    required this.value,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppColors.brandGreen.withOpacity(.12)
        : const Color(0xFFF6F8FA);
    final textColor = selected
        ? Colors.white
        : Colors.black.withOpacity(.82);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: textColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "$label • $value",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textColor,
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

class _NearbyPingsEmptyState extends StatelessWidget {
  const _NearbyPingsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAF8),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.brandGreen.withOpacity(.10),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              PhosphorIcons.mapPin(PhosphorIconsStyle.fill),
              size: 18,
              color: AppColors.brandGreen,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "No pings near you yet. Create one and start the action.",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: Colors.black.withOpacity(.58),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbyEventsEmptyState extends StatelessWidget {
  const _NearbyEventsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withOpacity(.14),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              PhosphorIcons.calendarDots(PhosphorIconsStyle.fill),
              size: 18,
              color: const Color(0xFF8B5CF6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "No events yet",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Create one when event creation goes live.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.55),
                    height: 1.35,
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

class _EventsComingSoonRow extends StatelessWidget {
  const _EventsComingSoonRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withOpacity(.14),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              PhosphorIcons.calendarDots(PhosphorIconsStyle.fill),
              size: 18,
              color: const Color(0xFF8B5CF6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Events coming soon",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Create and discover nearby events here very soon.",
                  style: TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    color: Colors.black.withOpacity(.55),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              "Soon",
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8B5CF6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbyPingRow extends StatelessWidget {
  final _PingPreview ping;
  final LatLng? me;
  final VoidCallback onTap;

  const _NearbyPingRow({
    required this.ping,
    required this.me,
    required this.onTap,
  });

  String _timeAwayText() {
    if (me == null) return "—";

    final meters = Geolocator.distanceBetween(
      me!.latitude,
      me!.longitude,
      ping.at.latitude,
      ping.at.longitude,
    );

    final mins = (meters / 78.0).round().clamp(1, 999);

    if (meters < 1000) {
      return "${meters.round()}m · $mins min walk";
    }

    return "${(meters / 1000).toStringAsFixed(1)}km · $mins min walk";
  }

  String _expiresText() {
    final ends = ping.endsAt;
    if (ends == null) return "";

    final diff = ends.difference(DateTime.now());
    if (diff.isNegative) return "Ended";
    if (diff.inMinutes < 60) return "Ends in ${diff.inMinutes}m";
    if (diff.inHours < 24) return "Ends in ${diff.inHours}h";
    return "Ends in ${diff.inDays}d";
  }

  bool get _isNew =>
      ping.createdAt != null &&
      DateTime.now().difference(ping.createdAt!).inMinutes < 5;

  bool get _isExpiringSoon =>
      ping.endsAt != null &&
      !ping.endsAt!.isBefore(DateTime.now()) &&
      ping.endsAt!.difference(DateTime.now()).inMinutes < 15;

  ({IconData icon, Color color}) _rowStyle() {
    final c = ping.category.toLowerCase();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
        color: const Color(0xFF6C5CE7),
      );
    }
    if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
        color: const Color(0xFFE74C3C),
      );
    }
    if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        color: const Color(0xFF9B59B6),
      );
    }
    if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
        color: const Color(0xFF3498DB),
      );
    }
    if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
        color: const Color(0xFFE67E22),
      );
    }
    if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
        color: const Color(0xFF1ABC9C),
      );
    }
    if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
        color: const Color(0xFFF39C12),
      );
    }
    if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        color: const Color(0xFFE91E63),
      );
    }
    if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.fill),
        color: const Color(0xFFFFB800),
      );
    }
    if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF6B6B),
      );
    }
    if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF1744),
      );
    }
    if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
        color: const Color(0xFF2196F3),
      );
    }

    final hash = ping.category.hashCode;
    final customColors = [
      const Color(0xFF00BCD4),
      const Color(0xFF009688),
      const Color(0xFF8BC34A),
      const Color(0xFFFF5722),
      const Color(0xFF673AB7),
      const Color(0xFFE91E63),
    ];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
      color: customColors[hash.abs() % customColors.length],
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = _rowStyle();
    final timeAway = _timeAwayText();
    final expires = _expiresText();
    final joined = "${ping.participantCount} joined";

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: _isNew
                ? AppColors.brandGreen.withOpacity(.06)
                : Colors.white.withOpacity(.92),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _isNew
                  ? AppColors.brandGreen.withOpacity(.22)
                  : Colors.black.withOpacity(.06),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: style.color.withOpacity(.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  style.icon,
                  size: 18,
                  color: style.color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ping.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: "Nunito",
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        if (_isNew) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.brandGreen,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              "New",
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w600,
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [timeAway, joined]
                                .where((x) => x.isNotEmpty)
                                .join(" · "),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: "Nunito",
                              fontSize: 12.5,
                              color: Colors.black.withOpacity(.55),
                            ),
                          ),
                        ),
                        if (expires.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _isExpiringSoon
                                  ? Colors.red.withOpacity(.10)
                                  : Colors.black.withOpacity(.06),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              expires,
                              style: TextStyle(
                                fontFamily: "Nunito",
                                fontWeight: FontWeight.w700,
                                fontSize: 10.5,
                                color: _isExpiringSoon
                                    ? Colors.red.shade700
                                    : Colors.black.withOpacity(.55),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                size: 18,
                color: Colors.black.withOpacity(.38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchSheet extends StatefulWidget {
  final BuildContext parentContext;
  final PingVisibilityContext visibilityContext;
  final Future<void> Function(String) onOpenPingId;
  final String initialQuery;
  final List<_PingPreview> candidatePings;
  final LatLng? me;

  const _SearchSheet({
    super.key,
    required this.parentContext,
    required this.visibilityContext,
    required this.onOpenPingId,
    required this.candidatePings,
    required this.me,
    this.initialQuery = "",
  });

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  final _ctrl = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  List<SearchResult> _results = [];
  late final SearchService _service;
  final FocusNode _focusNode = FocusNode();

  late final PageController _forYouPager = PageController(viewportFraction: 0.82);
  final ValueNotifier<double> _forYouPage = ValueNotifier<double>(0);

  final Set<String> _myFriendIds = <String>{};
  bool _friendIdsLoading = true;

  List<SearchResult> _suggestedPeople = [];
  bool _peopleSuggestionsLoading = false;

  List<String> _profileInterests = [];
  List<String> _profileSkills = [];
  bool _profileLoading = true;
  final Set<String> _selectedProfileTerms = <String>{};

  Future<void> _loadMyFriendIds() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _myFriendIds.clear();
        _friendIdsLoading = false;
      });
      return;
    }

    try {
      final userRef = FirebaseFirestore.instance.collection("users").doc(uid);

      final userSnap = await userRef.get();
      final userData = userSnap.data() ?? <String, dynamic>{};

      final storedFriendIds = List<String>.from(userData["friendIds"] ?? const []);

      final friendsSnap = await userRef.collection("friends").limit(200).get();
      final subFriendIds = friendsSnap.docs
          .map((d) => (d.data()["friendId"] ?? "").toString().trim())
          .where((id) => id.isNotEmpty)
          .toList();

      if (!mounted) return;

      setState(() {
        _myFriendIds
          ..clear()
          ..addAll(storedFriendIds)
          ..addAll(subFriendIds);
        _myFriendIds.remove(uid);
        _friendIdsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _myFriendIds.clear();
        _friendIdsLoading = false;
      });
    }
  }

  Future<void> _loadProfileTerms() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) {
        setState(() => _profileLoading = false);
      }
      return;
    }

    try {
      final snap = await FirebaseFirestore.instance.collection("users").doc(uid).get();
      final data = snap.data() ?? <String, dynamic>{};

      if (!mounted) return;

      setState(() {
        _profileInterests = _dedupePretty(
          List<String>.from(data["interests"] ?? const []),
        );
        _profileSkills = _dedupePretty(
          List<String>.from(data["skills"] ?? const []),
        );
        _profileLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _profileLoading = false);
    }
  }

  String _normalizeLoose(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll('#', '')
        .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _dedupePretty(List<String> input) {
    final seen = <String>{};
    final out = <String>[];

    for (final raw in input) {
      final cleaned = raw.trim();
      if (cleaned.isEmpty) continue;

      final key = _normalizeLoose(cleaned);
      if (key.isEmpty || seen.contains(key)) continue;

      seen.add(key);
      out.add(cleaned);
    }

    return out;
  }

  Map<String, Set<String>> get _semanticAliases => {
    "photography": {
      "camera",
      "photo",
      "photos",
      "photographer",
      "videography",
      "filming",
      "film",
      "cinematography",
      "content creation",
      "nature",
    },
    "nature": {
      "outdoors",
      "wildlife",
      "hiking",
      "trees",
      "travel",
      "photography",
      "filming",
    },
    "movies": {
      "film",
      "cinema",
      "filming",
      "videography",
    },
    "music": {
      "singing",
      "guitar",
      "piano",
      "music production",
      "beats",
    },
    "fitness": {
      "gym",
      "workout",
      "training",
      "personal training",
      "fitness coaching",
    },
    "sports": {
      "football",
      "soccer",
      "basketball",
      "running",
    },
    "technology": {
      "tech",
      "ai",
      "ml",
      "flutter",
      "web development",
      "game development",
      "cybersecurity",
      "data analysis",
    },
    "business": {
      "startup",
      "startups",
      "startup founder",
      "business strategy",
      "founder",
      "marketing",
      "networking",
    },
    "art": {
      "graphic design",
      "ui ux design",
      "ui ux",
      "3d design",
      "painting",
      "drawing",
      "creative",
    },
    "travel": {
      "nature",
      "outdoors",
      "adventure",
      "hiking",
    },
  };

  Set<String> _termVariants(String raw) {
    final n = _normalizeLoose(raw);
    if (n.isEmpty) return const {};

    final variants = <String>{n};

    for (final entry in _semanticAliases.entries) {
      final key = _normalizeLoose(entry.key);
      final values = entry.value.map(_normalizeLoose).toSet();

      if (n == key || values.contains(n)) {
        variants.add(key);
        variants.addAll(values);
      }
    }

    return variants;
  }

  int _scorePingAgainstTerm(_PingPreview ping, String term) {
    final variants = _termVariants(term);
    if (variants.isEmpty) return 0;

    final category = _normalizeLoose(ping.category);

    final tags = ping.tags
        .map((e) => _normalizeLoose(e))
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetInterests = ping.targetInterests
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetSkills = ping.targetSkills
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final targetTerms = ping.targetTerms
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final keywords = ping.keywords
        .map(_normalizeLoose)
        .where((e) => e.isNotEmpty)
        .toSet();

    final haystack = [
      ping.title,
      ping.description,
      ping.placeName,
      ping.meetingPoint,
      ping.category,
      ...ping.tags,
      ...ping.targetInterests,
      ...ping.targetSkills,
      ...ping.targetTerms,
      ...ping.keywords,
    ].map(_normalizeLoose).join(" ");

    int score = 0;

    for (final v in variants) {
      if (v.isEmpty) continue;

      if (category == v) score += 7;
      if (tags.contains(v)) score += 6;
      if (targetInterests.contains(v)) score += 8;
      if (targetSkills.contains(v)) score += 8;
      if (targetTerms.contains(v)) score += 7;
      if (keywords.contains(v)) score += 5;
      if (haystack.contains(v)) score += 2;
    }

    return score;
  }

  bool _matchesProfileTerm(_PingPreview ping, String term) {
    return _scorePingAgainstTerm(ping, term) > 0;
  }

  String? _reasonFor(_PingPreview ping) {
    final selectedTerms = _selectedProfileTerms.toList();

    if (selectedTerms.isNotEmpty &&
        selectedTerms.any((t) => _matchesProfileTerm(ping, t))) {
      return "Fits what you picked";
    }

    final interestMatch = _profileInterests.any((t) => _matchesProfileTerm(ping, t));
    final skillMatch = _profileSkills.any((t) => _matchesProfileTerm(ping, t));

    if (interestMatch) return "Matches your interests";
    if (skillMatch) return "Fits your skills";

    if (widget.me != null) {
      final meters = Geolocator.distanceBetween(
        widget.me!.latitude,
        widget.me!.longitude,
        ping.at.latitude,
        ping.at.longitude,
      );
      if (meters <= 250) return "Very close to you";
    }

    if (ping.participantCount >= 4) return "Getting attention nearby";
    return null;
  }

  List<_PingPreview> get _matchedProfilePings {
    final allTerms = [
      ..._profileInterests.map(_normalizeLoose),
      ..._profileSkills.map(_normalizeLoose),
    ].where((e) => e.isNotEmpty).toSet();

    final activeTerms =
        _selectedProfileTerms.isNotEmpty ? _selectedProfileTerms : allTerms;

    if (activeTerms.isEmpty) return const <_PingPreview>[];

    final scored = <({ _PingPreview ping, int score })>[];

    for (final ping in widget.candidatePings) {
      int total = 0;

      for (final term in activeTerms) {
        total += _scorePingAgainstTerm(ping, term);
      }

      if (total > 0) {
        scored.add((ping: ping, score: total));
      }
    }

    scored.sort((a, b) {
      final scoreCmp = b.score.compareTo(a.score);
      if (scoreCmp != 0) return scoreCmp;

      final ad = a.ping.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.ping.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });

    return scored.map((e) => e.ping).take(16).toList();
  }

  void _toggleProfileTerm(String term) {
    final normalized = _normalizeLoose(term);
    if (normalized.isEmpty) return;

    setState(() {
      if (_selectedProfileTerms.contains(normalized)) {
        _selectedProfileTerms.remove(normalized);
      } else {
        _selectedProfileTerms.add(normalized);
      }
    });

    _loadPeopleSuggestions();
  }

  String _distanceText(_PingPreview ping) {
    if (widget.me == null) return "Nearby";

    final meters = Geolocator.distanceBetween(
      widget.me!.latitude,
      widget.me!.longitude,
      ping.at.latitude,
      ping.at.longitude,
    );

    if (meters < 1000) return "${meters.round()} m away";
    return "${(meters / 1000).toStringAsFixed(1)} km away";
  }

  IconData _tabIcon(int index) {
    switch (index) {
      case 0:
        return PhosphorIcons.sparkle(PhosphorIconsStyle.light);
      case 1:
        return PhosphorIcons.mapPin(PhosphorIconsStyle.light);
      case 2:
        return PhosphorIcons.usersThree(PhosphorIconsStyle.light);
      case 3:
        return PhosphorIcons.calendarDots(PhosphorIconsStyle.light);
      default:
        return PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light);
    }
  }

  String _tabLabel(int index) {
    switch (index) {
      case 0:
        return "All";
      case 1:
        return "Pings";
      case 2:
        return "People";
      case 3:
        return "Events";
      default:
        return "";
    }
  }

  void _selectTab(int index) {
    _tabs.animateTo(index);
    _runSearch(immediate: true);
  }

  Color _mutedGrey(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? Colors.white.withOpacity(.56) : const Color(0xFF6B7280);
  }

  ({IconData icon, Color color}) _pingCategoryStyle(String category) {
    final c = category.toLowerCase();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
        color: const Color(0xFF6C5CE7),
      );
    }
    if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
        color: const Color(0xFFE74C3C),
      );
    }
    if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        color: const Color(0xFF9B59B6),
      );
    }
    if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
        color: const Color(0xFF3498DB),
      );
    }
    if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
        color: const Color(0xFFE67E22),
      );
    }
    if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
        color: const Color(0xFF1ABC9C),
      );
    }
    if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
        color: const Color(0xFFF39C12),
      );
    }
    if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        color: const Color(0xFFE91E63),
      );
    }
    if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.fill),
        color: const Color(0xFFFFB800),
      );
    }
    if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF6B6B),
      );
    }
    if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF1744),
      );
    }
    if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
        color: const Color(0xFF2196F3),
      );
    }

    final customColors = [
      const Color(0xFF00BCD4),
      const Color(0xFF009688),
      const Color(0xFF8BC34A),
      const Color(0xFFFF5722),
      const Color(0xFF673AB7),
      const Color(0xFFE91E63),
    ];

    final color = customColors[category.hashCode.abs() % customColors.length];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
      color: color,
    );
  }


  @override
  void initState() {
    super.initState();

    _service = SearchService(
      FirebaseFirestore.instance,
      visibilityContext: widget.visibilityContext,
    );

    if (widget.initialQuery.trim().isNotEmpty) {
      _ctrl.text = widget.initialQuery.trim();
    }

    _forYouPager.addListener(() {
      if (!_forYouPager.hasClients) return;
      _forYouPage.value = _forYouPager.page ?? 0.0;
    });

    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      _runSearch(immediate: true);
      setState(() {});
    });

    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });

    _loadProfileTerms().then((_) async {
      if (!mounted) return;
      await _loadMyFriendIds();
      if (!mounted) return;
      await _loadPeopleSuggestions();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();

      if (_ctrl.text.trim().isNotEmpty) {
        _runSearch(immediate: true);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _tabs.dispose();
    _focusNode.dispose();
    _forYouPager.dispose();
    _forYouPage.dispose();
    super.dispose();
  }

  void _runSearch({bool immediate = false}) {
    _debounce?.cancel();

    final q = _ctrl.text.trim();

    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _results = [];
          _loading = false;
        });
      }
      return;
    }

    Future<void> fire() async {
      if (mounted) {
        setState(() => _loading = true);
      }

      try {
        List<SearchResult> out;

        switch (_tabs.index) {
          case 1:
            out = await _service.searchPingsOnly(q);
            break;
          case 2:
            out = await _service.searchPeopleOnly(q);
            break;
          case 3:
            out = const [];
            break;
          default:
            out = await _service.searchAll(q);
        }

        if (mounted) {
          setState(() => _results = out);
        }
      } finally {
        if (mounted) {
          setState(() => _loading = false);
        }
      }
    }

    // Tiny queries should feel instant.
    if (immediate || q.length <= 2) {
      fire();
      return;
    }

    // Keep only a very light debounce for longer queries.
    _debounce = Timer(const Duration(milliseconds: 80), fire);
  }

  Future<void> _loadPeopleSuggestions() async {
    final terms = (_selectedProfileTerms.isNotEmpty
            ? _selectedProfileTerms.toList()
            : [
                ..._profileInterests.map(_normalizeLoose),
                ..._profileSkills.map(_normalizeLoose),
              ])
        .where((e) => e.trim().isNotEmpty)
        .toList();

    if (terms.isEmpty) {
      if (!mounted) return;
      setState(() {
        _suggestedPeople = [];
        _peopleSuggestionsLoading = false;
      });
      return;
    }

    if (mounted) {
      setState(() => _peopleSuggestionsLoading = true);
    }

    try {
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      final query = terms.take(4).join(' ');
      final out = await _service.searchPeopleOnly(query);

      final filtered = out.where((r) {
        if (r.kind != SearchKind.user) return false;

        final uid = r.id.trim();
        if (uid.isEmpty) return false;
        if (uid == myUid) return false;
        if (_myFriendIds.contains(uid)) return false;

        return true;
      }).take(5).toList();

      if (!mounted) return;

      setState(() {
        _suggestedPeople = filtered;
      });
    } finally {
      if (mounted) {
        setState(() => _peopleSuggestionsLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0D1117) : const Color(0xFFF4F6F8);
    final surface = isDark ? const Color(0xFF161B22) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final muted = _mutedGrey(context);

    final hasQuery = _ctrl.text.trim().isNotEmpty;
    final showSuggestionsHome = !hasQuery;

    final profilePings = _matchedProfilePings;
    final showPingSuggestions = showSuggestionsHome && profilePings.isNotEmpty;
    final showPeopleSuggestions =
        showSuggestionsHome && _suggestedPeople.isNotEmpty;
    final showEventSuggestions = showSuggestionsHome;

    return Scaffold(
      backgroundColor: bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 16,
                          color: textColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                            color: Colors.black.withOpacity(isDark ? .18 : .05),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focusNode,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) {
                          setState(() {});
                          _runSearch();
                        },
                        onSubmitted: (_) => _runSearch(immediate: true),
                        style: TextStyle(
                          fontFamily: "Nunito",
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: textColor,
                        ),
                        cursorColor: AppColors.brandGreen,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          hintText: "Search people, pings and events",
                          hintStyle: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            color: muted,
                          ),
                          prefixIcon: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.light),
                              size: 19,
                              color: muted,
                            ),
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          suffixIcon: _ctrl.text.trim().isEmpty
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: IconButton(
                                    onPressed: () {
                                      _ctrl.clear();
                                      setState(() {});
                                      _runSearch(immediate: true);
                                    },
                                    iconSize: 13,
                                    splashRadius: 16,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 22,
                                      height: 22,
                                    ),
                                    icon: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? Colors.white.withOpacity(.10)
                                            : const Color(0xFFE5E7EB),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 13,
                                        color: isDark
                                            ? Colors.white.withOpacity(.72)
                                            : const Color(0xFF6B7280),
                                      ),
                                    ),
                                  ),
                                ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          filled: true,
                          fillColor: Colors.transparent,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide(
                              color: AppColors.brandGreen.withOpacity(.22),
                              width: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  const SizedBox(height: 2),

                  Row(
                    children: List.generate(4, (index) {
                      final selected = _tabs.index == index;

                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: index == 3 ? 0 : 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _selectTab(index),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              decoration: BoxDecoration(
                                color: selected
                                    ? (isDark
                                        ? Colors.white.withOpacity(.08)
                                        : const Color(0xFFEDEFF2))
                                    : surface,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _tabIcon(index),
                                    size: 17,
                                    color: muted,
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    _tabLabel(index),
                                    style: TextStyle(
                                      fontFamily: "Nunito",
                                      fontSize: 11.8,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),

                  if (!_profileLoading &&
                      (_profileInterests.isNotEmpty ||
                          _profileSkills.isNotEmpty)) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Icon(
                          PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
                          size: 15,
                          color: Colors.black.withOpacity(.72),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Find your people",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.8,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      "Tap your interests and skills to find people and pings that match your vibe.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.6,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_profileInterests.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 40,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                children: [
                                  ..._profileInterests.map(
                                    (term) => Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: _SearchProfileChip(
                                        label: term,
                                        icon: PhosphorIcons.heart(
                                          PhosphorIconsStyle.light,
                                        ),
                                        selected: _selectedProfileTerms.contains(
                                          _normalizeLoose(term),
                                        ),
                                        kind: _SearchChipKind.interest,
                                        onTap: () => _toggleProfileTerm(term),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (_profileInterests.isNotEmpty && _profileSkills.isNotEmpty)
                            const SizedBox(height: 12),
                          if (_profileSkills.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 40,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                children: [
                                  ..._profileSkills.map(
                                    (term) => Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: _SearchProfileChip(
                                        label: term,
                                        icon: PhosphorIcons.hash(
                                          PhosphorIconsStyle.light,
                                        ),
                                        selected: _selectedProfileTerms.contains(
                                          _normalizeLoose(term),
                                        ),
                                        kind: _SearchChipKind.skill,
                                        onTap: () => _toggleProfileTerm(term),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],

                  if (showPingSuggestions) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Icon(
                          PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
                          size: 16,
                          color: Colors.black.withOpacity(.72),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Because of your profile",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Pings that line up with your interests and skills.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 214,
                      child: ValueListenableBuilder<double>(
                        valueListenable: _forYouPage,
                        builder: (context, page, _) {
                          return PageView.builder(
                            controller: _forYouPager,
                            padEnds: false,
                            physics: const BouncingScrollPhysics(),
                            itemCount: profilePings.length,
                            itemBuilder: (context, index) {
                              final ping = profilePings[index];
                              final delta = index - page;

                              return Padding(
                                padding: EdgeInsets.only(
                                  left: index == 0 ? 0 : 4,
                                  right: index == profilePings.length - 1 ? 0 : 12,
                                ),
                                child: RepaintBoundary(
                                  child: _SearchForYouCard(
                                    ping: ping,
                                    reason: _reasonFor(ping) ?? "Picked for you",
                                    distanceText: _distanceText(ping),
                                    onTap: () async {
                                      Navigator.pop(context);
                                      await widget.onOpenPingId(ping.id);
                                    },
                                    parallax: delta,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],

                  if (showPeopleSuggestions) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Icon(
                          PhosphorIcons.usersThree(PhosphorIconsStyle.fill),
                          size: 16,
                          color: Colors.black.withOpacity(.72),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "People you may want to ping",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "People who match your interests and skills.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ..._suggestedPeople.take(5).map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SearchRow(
                          r: r,
                          onTapPing: (pingId) async {
                            Navigator.pop(context);
                            await widget.onOpenPingId(pingId);
                          },
                          onTapUser: (uid) {
                            Navigator.pop(context);
                            Navigator.of(widget.parentContext).push(
                              MaterialPageRoute(
                                builder: (_) => ProfileTab(profileUid: uid),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],

                  if (showEventSuggestions) ...[
                    Row(
                      children: [
                        Icon(
                          PhosphorIcons.calendarDots(PhosphorIconsStyle.fill),
                          size: 16,
                          color: const Color(0xFF8B5CF6),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Events for you",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "This section will light up when event discovery is ready.",
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _NearbyEventsEmptyState(),
                    const SizedBox(height: 18),
                  ],

                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppColors.brandGreen,
                          strokeWidth: 2.6,
                        ),
                      ),
                    )
                  else if (showSuggestionsHome &&
                      !showPingSuggestions &&
                      !showPeopleSuggestions &&
                      !_peopleSuggestionsLoading)
                    _SearchEmptyState(
                      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.light),
                      title: "Suggestions will show up here",
                      subtitle: "Add interests or skills to get better ping and people suggestions.",
                    )
                  else if (_results.isEmpty)
                    _SearchEmptyState(
                      icon: PhosphorIcons.magnifyingGlass(
                        PhosphorIconsStyle.light,
                      ),
                      title: _tabs.index == 3
                          ? "Events are coming soon"
                          : "No results found",
                      subtitle: _tabs.index == 3
                          ? "This tab is ready for the future event system."
                          : "Try one of your interest or skill chips, or search broader.",
                    )
                  else ...[
                    Row(
                      children: [
                        Text(
                          "Results",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          "${_results.length}",
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ..._results.map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SearchRow(
                          r: r,
                          onTapPing: (pingId) async {
                            Navigator.pop(context);
                            await widget.onOpenPingId(pingId);
                          },
                          onTapUser: (uid) {
                            Navigator.pop(context);
                            Navigator.of(widget.parentContext).push(
                              MaterialPageRoute(
                                builder: (_) => ProfileTab(profileUid: uid),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchRow extends StatelessWidget {
  final SearchResult r;
  final Future<void> Function(String) onTapPing;
  final void Function(String) onTapUser;

  const _SearchRow({
    super.key,
    required this.r,
    required this.onTapPing,
    required this.onTapUser,
  });

  static ({IconData icon, Color color}) _pingCategoryStyle(String category) {
    final c = category.toLowerCase();

    if (c.contains("study")) {
      return (
        icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
        color: const Color(0xFF6C5CE7),
      );
    }
    if (c.contains("gym")) {
      return (
        icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
        color: const Color(0xFFE74C3C),
      );
    }
    if (c.contains("gaming")) {
      return (
        icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        color: const Color(0xFF9B59B6),
      );
    }
    if (c.contains("network")) {
      return (
        icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
        color: const Color(0xFF3498DB),
      );
    }
    if (c.contains("help")) {
      return (
        icon: PhosphorIcons.firstAid(PhosphorIconsStyle.fill),
        color: const Color(0xFFE67E22),
      );
    }
    if (c.contains("support")) {
      return (
        icon: PhosphorIcons.hand(PhosphorIconsStyle.fill),
        color: const Color(0xFF1ABC9C),
      );
    }
    if (c.contains("event")) {
      return (
        icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
        color: const Color(0xFFF39C12),
      );
    }
    if (c.contains("hangout")) {
      return (
        icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        color: const Color(0xFFE91E63),
      );
    }
    if (c.contains("instant")) {
      return (
        icon: PhosphorIcons.lightning(PhosphorIconsStyle.fill),
        color: const Color(0xFFFFB800),
      );
    }
    if (c.contains("food")) {
      return (
        icon: PhosphorIcons.pizza(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF6B6B),
      );
    }
    if (c.contains("music")) {
      return (
        icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
        color: const Color(0xFFFF1744),
      );
    }
    if (c.contains("sport")) {
      return (
        icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
        color: const Color(0xFF2196F3),
      );
    }

    final hash = category.hashCode;
    const palette = [
      Color(0xFF00BCD4),
      Color(0xFF009688),
      Color(0xFF8BC34A),
      Color(0xFFFF5722),
      Color(0xFF673AB7),
      Color(0xFFE91E63),
    ];

    return (
      icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
      color: palette[hash.abs() % palette.length],
    );
  }

  static String _formatDateTime(dynamic raw) {
    DateTime? dt;

    if (raw is Timestamp) {
      dt = raw.toDate();
    } else if (raw is DateTime) {
      dt = raw;
    }

    if (dt == null) return "";

    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];

    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
    final ampm = hour24 >= 12 ? "PM" : "AM";

    return "${dt.day} ${months[dt.month - 1]} · $hour12:$minute $ampm";
  }

  static String _hostLabel(Map<String, dynamic> d) {
    final host = (d["creatorName"] ??
            d["hostName"] ??
            d["fullName"] ??
            d["creatorUsername"] ??
            d["username"] ??
            "")
        .toString()
        .trim();

    if (host.isEmpty) return "";
    return "Host: $host";
  }

  static String _meetingPointLabel(Map<String, dynamic> d) {
    if (d["location"] is! Map) return "";
    final location = Map<String, dynamic>.from(d["location"] as Map);
    final meetingPoint = (location["meetingPoint"] ?? "").toString().trim();
    if (meetingPoint.isEmpty) return "";
    return "Meet: $meetingPoint";
  }

  static String _placeLabel(Map<String, dynamic> d) {
    if (d["location"] is! Map) return "";
    final location = Map<String, dynamic>.from(d["location"] as Map);
    return (location["placeName"] ?? "").toString().trim();
  }

  static Widget _metaPill({
    required IconData icon,
    required String text,
    required Color textColor,
    required Color fill,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: textColor),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: "Nunito",
                fontWeight: FontWeight.w700,
                fontSize: 10.8,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = r.data;

    if (r.kind == SearchKind.ping) {
      final title = (d["title"] ?? "Ping").toString();
      final place = _placeLabel(d);
      final meetingPoint = _meetingPointLabel(d);
      final host = _hostLabel(d);

      final when = _formatDateTime(
        d["scheduledStartAt"] ?? d["startAt"] ?? d["createdAtLocal"],
      );

      final category = (d["category"] ?? "").toString();
      final style = _pingCategoryStyle(category);

      final chips = <Widget>[
        if (host.isNotEmpty)
          _metaPill(
            icon: PhosphorIcons.user(PhosphorIconsStyle.light),
            text: host,
            textColor: const Color(0xFF374151),
            fill: const Color(0xFFF3F4F6),
          ),
        if (when.isNotEmpty)
          _metaPill(
            icon: PhosphorIcons.calendarBlank(PhosphorIconsStyle.light),
            text: when,
            textColor: const Color(0xFF374151),
            fill: const Color(0xFFF3F4F6),
          ),
        if (meetingPoint.isNotEmpty)
          _metaPill(
            icon: PhosphorIcons.mapPin(PhosphorIconsStyle.light),
            text: meetingPoint,
            textColor: const Color(0xFF374151),
            fill: const Color(0xFFF3F4F6),
          ),
      ];

      return _GlassCard(
        child: InkWell(
          onTap: () => onTapPing(r.id),
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: style.color.withOpacity(.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    style.icon,
                    color: style.color,
                    size: 19,
                  ),
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
                          fontWeight: FontWeight.w700,
                          fontSize: 13.8,
                          color: Color(0xFF111111),
                        ),
                      ),
                      if (place.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: Colors.black.withOpacity(.58),
                          ),
                        ),
                      ],
                      if (chips.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: chips,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  PhosphorIcons.caretRight(PhosphorIconsStyle.light),
                  color: Colors.black.withOpacity(.35),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final name = (d["fullName"] ?? "Pingmee user").toString();
    final username = (d["username"] ?? "").toString();
    final photoUrl = (d["photoUrl"] ?? "").toString();

    final verification = Map<String, dynamic>.from(d["verification"] ?? {});
    final isVerified = verification["status"] == "verified";

    return _GlassCard(
      child: InkWell(
        onTap: () => onTapUser(r.id),
        borderRadius: BorderRadius.circular(22),
        child: Row(
          children: [
            _MiniAvatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: "Nunito",
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            color: Color(0xFF111111),
                          ),
                        ),
                      ),
                      if (isVerified) ...[
                        const SizedBox(width: 4),
                        const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.verified_rounded,
                            size: 16,
                            color: Color(0xFF1D9BF0),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    username.isEmpty ? "" : "@$username",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: Colors.black.withOpacity(.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              PhosphorIcons.caretRight(PhosphorIconsStyle.light),
              color: Colors.black.withOpacity(.35),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SearchChipKind { interest, skill }

class _SearchProfileChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final _SearchChipKind kind;
  final VoidCallback onTap;

  const _SearchProfileChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.kind,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color accent = switch (kind) {
      _SearchChipKind.interest => const Color(0xFFE85D75),
      _SearchChipKind.skill => const Color(0xFF4F8CFF),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? accent.withOpacity(isDark ? .18 : .12)
              : (isDark ? const Color(0xFF161B22) : Colors.white),
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? [
                  BoxShadow(
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                    color: accent.withOpacity(isDark ? .10 : .08),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected
                  ? accent
                  : accent.withOpacity(isDark ? .92 : .82),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 12.2,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                color: selected
                    ? accent
                    : (isDark ? Colors.white70 : const Color(0xFF374151)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchForYouCard extends StatelessWidget {
  final _PingPreview ping;
  final String reason;
  final String distanceText;
  final VoidCallback onTap;
  final double parallax;

  const _SearchForYouCard({
    required this.ping,
    required this.reason,
    required this.distanceText,
    required this.onTap,
    required this.parallax,
  });

  @override
  Widget build(BuildContext context) {
    final style = _searchCategoryVisual(ping.category);

    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(parallax * 2, 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        style.color.withOpacity(.94),
                        style.color.withOpacity(.72),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(parallax * 1, 0),
                child: Stack(
                  children: [
                    Positioned(
                      right: -18,
                      top: -12,
                      child: Icon(
                        style.icon,
                        size: 92,
                        color: Colors.white.withOpacity(.10),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      bottom: 20,
                      child: Icon(
                        Icons.auto_awesome,
                        color: Colors.white.withOpacity(.80),
                        size: 18,
                      ),
                    ),
                    Positioned(
                      right: 22,
                      bottom: 26,
                      child: Icon(
                        Icons.auto_awesome,
                        color: Colors.white.withOpacity(.32),
                        size: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        reason,
                        style: const TextStyle(
                          fontFamily: "Nunito",
                          fontSize: 11.2,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.16),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(
                            style.icon,
                            color: Colors.white,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ping.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "${ping.placeName} • $distanceText",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white.withOpacity(.86),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark ? Colors.white.withOpacity(.48) : const Color(0xFF6B7280);
    final tileColor = isDark ? const Color(0xFF161B22) : Colors.white;

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
        child: Column(
          children: [
            Container(
              width: 82,
              height: 82,
              decoration: BoxDecoration(
                color: tileColor,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withOpacity(.08)
                      : Colors.black.withOpacity(.06),
                ),
              ),
              child: Icon(
                icon,
                size: 31,
                color: iconColor,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: "Nunito",
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.35,
                color: iconColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

({IconData icon, Color color}) _searchCategoryVisual(String category) {
  final c = category.toLowerCase();

  if (c.contains("study")) {
    return (
      icon: PhosphorIcons.books(PhosphorIconsStyle.fill),
      color: const Color(0xFF6C5CE7),
    );
  }
  if (c.contains("gym")) {
    return (
      icon: PhosphorIcons.fire(PhosphorIconsStyle.fill),
      color: const Color(0xFFE74C3C),
    );
  }
  if (c.contains("gaming")) {
    return (
      icon: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
      color: const Color(0xFF9B59B6),
    );
  }
  if (c.contains("network")) {
    return (
      icon: PhosphorIcons.handshake(PhosphorIconsStyle.fill),
      color: const Color(0xFF3498DB),
    );
  }
  if (c.contains("event")) {
    return (
      icon: PhosphorIcons.calendar(PhosphorIconsStyle.fill),
      color: const Color(0xFFF39C12),
    );
  }
  if (c.contains("hangout")) {
    return (
      icon: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
      color: const Color(0xFFE91E63),
    );
  }
  if (c.contains("music")) {
    return (
      icon: PhosphorIcons.headphones(PhosphorIconsStyle.fill),
      color: const Color(0xFFFF1744),
    );
  }
  if (c.contains("sport")) {
    return (
      icon: PhosphorIcons.basketball(PhosphorIconsStyle.fill),
      color: const Color(0xFF2196F3),
    );
  }

  return (
    icon: PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
    color: AppColors.brandGreen,
  );
}

class _GlassTabs extends StatelessWidget {
  final TabController controller;
  final List<String> tabs;
  final bool dense;

  const _GlassTabs({
    required this.controller,
    required this.tabs,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: EdgeInsets.all(dense ? 4 : 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.72),
            border: Border.all(color: Colors.white.withOpacity(.55)),
            borderRadius: BorderRadius.circular(22),
          ),
          child: TabBar(
            controller: controller,
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            indicator: BoxDecoration(
              color: AppColors.brandGreen.withOpacity(.14),
              borderRadius: BorderRadius.circular(18),
            ),
            labelColor: AppColors.brandGreen,
            unselectedLabelColor: Colors.black.withOpacity(.55),
            labelStyle: TextStyle(
              fontFamily: "Nunito",
              fontWeight: FontWeight.w600,
              fontSize: dense ? 12.5 : 13.5,
            ),
            tabs: tabs.map((t) => Tab(text: t)).toList(),
          ),
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;

  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.78),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(.55)),
            boxShadow: [
              BoxShadow(
                blurRadius: 22,
                offset: const Offset(0, 14),
                color: Colors.black.withOpacity(.06),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String photoUrl;

  const _MiniAvatar({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final has = photoUrl.trim().isNotEmpty;

    return Container(
      width: 44,
      height: 44,
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
              size: 18,
              color: Colors.black.withOpacity(.55),
            )
          : null,
    );
  }
}

class _PingLoadingOverlay extends StatelessWidget {
  const _PingLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                valueColor: AlwaysStoppedAnimation<Color>(
                  AppColors.brandGreen,
                ),
              ),
            ),
            SizedBox(width: 12),
            Text(
              "Opening ping…",
              style: TextStyle(
                fontFamily: "Nunito",
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingMediaViewer extends StatefulWidget {
  final List<PingMediaItem> media;
  final int initialIndex;

  const _PingMediaViewer({
    required this.media,
    required this.initialIndex,
  });

  @override
  State<_PingMediaViewer> createState() => _PingMediaViewerState();
}

class _PingMediaViewerState extends State<_PingMediaViewer> {
  late final PageController _page;
  int _index = 0;
  final Map<int, VideoPlayerController> _vp = {};
  final Map<int, ChewieController> _chewie = {};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    _ensureVideo(_index);
  }

  @override
  void dispose() {
    for (final c in _chewie.values) {
      c.dispose();
    }
    for (final v in _vp.values) {
      v.dispose();
    }
    _page.dispose();
    super.dispose();
  }

  Future<void> _ensureVideo(int i) async {
    if (i < 0 || i >= widget.media.length) return;

    final m = widget.media[i];
    if (!m.isVideo || _vp.containsKey(i)) return;

    final vp = VideoPlayerController.networkUrl(Uri.parse(m.url));
    await vp.initialize();

    final ch = ChewieController(
      videoPlayerController: vp,
      autoPlay: true,
      looping: false,
      allowFullScreen: false,
      showControls: true,
    );

    _vp[i] = vp;
    _chewie[i] = ch;

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height,
      color: Colors.black.withOpacity(.96),
      child: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _page,
              itemCount: widget.media.length,
              onPageChanged: (i) async {
                setState(() => _index = i);
                await _ensureVideo(i);
              },
              itemBuilder: (_, i) {
                final m = widget.media[i];

                if (!m.isVideo) {
                  return PhotoView(
                    imageProvider: NetworkImage(m.url),
                    backgroundDecoration: const BoxDecoration(
                      color: Colors.transparent,
                    ),
                    loadingBuilder: (_, __) =>
                        const Center(child: CircularProgressIndicator()),
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: Colors.white70,
                        size: 36,
                      ),
                    ),
                  );
                }

                final ch = _chewie[i];
                if (ch == null) {
                  return const Center(child: CircularProgressIndicator());
                }

                return Center(
                  child: AspectRatio(
                    aspectRatio: _vp[i]?.value.aspectRatio ?? (16 / 9),
                    child: Chewie(controller: ch),
                  ),
                );
              },
            ),
            Positioned(
              left: 12,
              right: 12,
              top: 8,
              child: Row(
                children: [
                  _viewerIcon(
                    icon: Icons.close_rounded,
                    onTap: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  Text(
                    "${_index + 1}/${widget.media.length}",
                    style: const TextStyle(
                      fontFamily: "Nunito",
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
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

  Widget _viewerIcon({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(.14)),
        ),
        child: Icon(icon, color: Colors.white70),
      ),
    );
  }
}

class _PingPreview {
  final String id;
  final String title;
  final String creatorId;
  final LatLng exactAt;
  final LatLng? mapAt;
  final int accuracyRadiusMeters;
  final List<PingMediaItem> media;
  final String category;
  final String privacy;
  final List<String> tags;
  final String description;
  final int participantCount;
  final int accuracyMode;
  final String placeName;
  final String meetingPoint;
  final String status;
  final DateTime? createdAt;
  final DateTime? startAt;
  final DateTime? scheduledStartAt;
  final DateTime? scheduledEndAt;
  final DateTime? endsAt;
  final List<String> targetInterests;
  final List<String> targetSkills;
  final List<String> targetTerms;
  final List<String> keywords;

  _PingPreview({
    required this.id,
    required this.title,
    required this.creatorId,
    required this.exactAt,
    required this.mapAt,
    required this.accuracyRadiusMeters,
    required this.category,
    required this.privacy,
    required this.tags,
    required this.description,
    required this.participantCount,
    required this.accuracyMode,
    required this.placeName,
    required this.meetingPoint,
    required this.status,
    required this.createdAt,
    required this.startAt,
    required this.scheduledStartAt,
    required this.scheduledEndAt,
    required this.endsAt,
    required this.media,
    required this.targetInterests,
    required this.targetSkills,
    required this.targetTerms,
    required this.keywords,
  });

  LatLng get at => mapAt ?? exactAt;
}

class _MapEventPreview {
  final String id;
  final String title;
  final String creatorId;
  final LatLng at;
  final String category;
  final String theme;
  final String privacy;
  final String status;
  final String locationText;
  final String meetupInstructions;
  final int attendeeCount;
  final int registrationCount;
  final DateTime? createdAt;
  final DateTime? startsAt;
  final DateTime? endsAt;

  final String coverType;
  final String? coverImageUrl;
  final String? coverPresetAssetPath;
  final List<Color> coverGradientColors;
  final Color coverColor;

  _MapEventPreview({
    required this.id,
    required this.title,
    required this.creatorId,
    required this.at,
    required this.category,
    required this.theme,
    required this.privacy,
    required this.status,
    required this.locationText,
    required this.meetupInstructions,
    required this.attendeeCount,
    required this.registrationCount,
    required this.createdAt,
    required this.startsAt,
    required this.endsAt,
    required this.coverType,
    required this.coverImageUrl,
    required this.coverPresetAssetPath,
    required this.coverGradientColors,
    required this.coverColor,
  });
}

class _RenderedEventCluster {
  final String id;
  final LatLng anchor;
  final List<_MapEventPreview> events;
  final _MapEventPreview leadEvent;
  final int visibleCardCount;

  const _RenderedEventCluster({
    required this.id,
    required this.anchor,
    required this.events,
    required this.leadEvent,
    required this.visibleCardCount,
  });

  bool get isMulti => events.length > 1;
  int get extraCount => events.length > 1 ? events.length - 1 : 0;
}

class _EventMarkerStackGroup {
  final LatLng anchor;
  final List<_MapEventPreview> items;

  _EventMarkerStackGroup({
    required this.anchor,
    required this.items,
  });
}

enum _TravelMode { walk, bike, drive }

class _RouteResult {
  final _TravelMode mode;
  final int durationSec;
  final double distanceM;
  final List<LatLng> geometry;

  const _RouteResult({
    required this.mode,
    required this.durationSec,
    required this.distanceM,
    required this.geometry,
  });
}

class _RouteUi {
  final _TravelMode mode;
  final int durationSec;
  final double distanceM;
  final String pingTitle;

  const _RouteUi({
    required this.mode,
    required this.durationSec,
    required this.distanceM,
    required this.pingTitle,
  });

  int get minutes => ((durationSec / 60).round()).clamp(1, 999);

  String get primaryLabel {
    switch (mode) {
      case _TravelMode.walk:
        return "$minutes min walk";
      case _TravelMode.bike:
        return "$minutes min ride";
      case _TravelMode.drive:
        return "$minutes min drive";
    }
  }

  String get distanceLabel {
    if (distanceM < 1000) return "${distanceM.round()} m";
    return "${(distanceM / 1000).toStringAsFixed(1)} km";
  }
}

class _RouteEtaPill extends StatelessWidget {
  final _RouteUi route;

  const _RouteEtaPill({
    required this.route,
  });

  IconData _icon() {
    switch (route.mode) {
      case _TravelMode.walk:
        return PhosphorIcons.personSimpleWalk(PhosphorIconsStyle.fill);
      case _TravelMode.bike:
        return PhosphorIcons.bicycle(PhosphorIconsStyle.fill);
      case _TravelMode.drive:
        return PhosphorIcons.car(PhosphorIconsStyle.fill);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.94),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.brandGreen.withOpacity(.18),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(.08),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.brandGreen.withOpacity(.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _icon(),
                  size: 18,
                  color: AppColors.brandGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.primaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "To ${route.pingTitle} · ${route.distanceLabel}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: "Nunito",
                        fontWeight: FontWeight.w400,
                        fontSize: 12,
                        color: Colors.black.withOpacity(.56),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PingMediaItem {
  final String type;
  final String url;
  final String thumbUrl;

  const PingMediaItem({
    required this.type,
    required this.url,
    required this.thumbUrl,
  });

  bool get isVideo => type == "video";
}

List<PingMediaItem> parsePingMedia(dynamic raw) {
  if (raw is! List) return const [];

  return raw
      .map((e) {
        if (e is! Map) return null;

        final type = (e["type"] ?? "image").toString();
        final url = (e["url"] ?? "").toString();
        final thumbUrl = (e["thumbUrl"] ?? url).toString();

        if (url.trim().isEmpty) return null;

        return PingMediaItem(
          type: type,
          url: url,
          thumbUrl: thumbUrl,
        );
      })
      .whereType<PingMediaItem>()
      .toList();
}

class _DiscoveryRadiusTag extends StatelessWidget {
  final String label;

  const _DiscoveryRadiusTag({
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              blurRadius: 14,
              offset: const Offset(0, 6),
              color: Colors.black.withOpacity(.18),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: AppColors.brandGreen,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontFamily: "Nunito",
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkerStackGroup {
  final LatLng anchor;
  final List<_PingPreview> items;

  _MarkerStackGroup({
    required this.anchor,
    required this.items,
  });
}

class _RenderedPingMarker {
  final _PingPreview ping;
  final LatLng position;
  final double opacity;

  const _RenderedPingMarker({
    required this.ping,
    required this.position,
    required this.opacity,
  });
}

class _MapEtaCard extends StatelessWidget {
  final _RouteUi route;
  const _MapEtaCard({required this.route});

  String _modeLabel() {
    switch (route.mode) {
      case _TravelMode.walk:
        return "Walking";
      case _TravelMode.bike:
        return "Bike";
      case _TravelMode.drive:
        return "Driving";
    }
  }

  IconData _modeIcon() {
    switch (route.mode) {
      case _TravelMode.walk:
        return PhosphorIcons.personSimpleWalk(PhosphorIconsStyle.fill);
      case _TravelMode.bike:
        return PhosphorIcons.bicycle(PhosphorIconsStyle.fill);
      case _TravelMode.drive:
        return PhosphorIcons.car(PhosphorIconsStyle.fill);
    }
  }

  String _durationText() {
    final mins = (route.durationSec / 60).round();
    if (mins < 1) return "Less than 1 min";
    if (mins < 60) return "$mins min";
    final h = mins ~/ 60;
    final m = mins % 60;
    if (m == 0) return "$h hr";
    return "$h hr $m min";
  }

  String _distanceText() {
    final km = route.distanceM / 1000;
    if (km < 1) return "${route.distanceM.round()} m";
    return "${km.toStringAsFixed(km >= 10 ? 0 : 1)} km";
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width < 360;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14,
          vertical: compact ? 10 : 12,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.96),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.black.withOpacity(.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.10),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: compact ? 38 : 42,
              height: compact ? 38 : 42,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withOpacity(.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                _modeIcon(),
                color: AppColors.brandGreen,
                size: compact ? 20 : 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _durationText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: compact ? 14 : 15.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withOpacity(.96),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "${_modeLabel()} • ${_distanceText()}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: "Nunito",
                      fontSize: compact ? 11.5 : 12.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withOpacity(.62),
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

class _EventMarkerSheet extends StatelessWidget {
  final _MapEventPreview event;
  final String whenText;

  const _EventMarkerSheet({
    required this.event,
    required this.whenText,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (event.theme) {
      "pink_nova" => const Color(0xFFE85ED5),
      "violet_dusk" => const Color(0xFF8B5CF6),
      "ocean_night" => const Color(0xFF3298FF),
      "emerald_night" => const Color(0xFF16C784),
      "sunset_blaze" => const Color(0xFFFF6B57),
      "amber_smoke" => const Color(0xFFF0A827),
      "berry_wave" => const Color(0xFFE95FAF),
      "teal_ink" => const Color(0xFF21C7C9),
      _ => const Color(0xFFF39C12),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: accent.withOpacity(.16),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: accent.withOpacity(.28)),
                ),
                child: Icon(
                  PhosphorIcons.calendar(PhosphorIconsStyle.fill),
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  event.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: "Nunito",
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _eventInfoRow(
            icon: PhosphorIcons.clock(PhosphorIconsStyle.bold),
            text: whenText,
          ),
          const SizedBox(height: 10),
          _eventInfoRow(
            icon: PhosphorIcons.mapPin(PhosphorIconsStyle.bold),
            text: event.locationText.isEmpty ? "Location not set" : event.locationText,
          ),
          if (event.meetupInstructions.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _eventInfoRow(
              icon: PhosphorIcons.mapTrifold(PhosphorIconsStyle.bold),
              text: event.meetupInstructions,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _eventPill(label: event.category.isEmpty ? "event" : event.category),
              _eventPill(label: "${event.attendeeCount} going"),
              _eventPill(label: "${event.registrationCount} registered"),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                disabledBackgroundColor: accent.withOpacity(.50),
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text(
                "Event details coming next",
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontFamily: "Nunito",
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _eventInfoRow({
    required IconData icon,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Colors.white.withOpacity(.82)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: "Nunito",
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(.90),
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _eventPill({required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: "Nunito",
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Colors.white.withOpacity(.92),
        ),
      ),
    );
  }
}

class _EventClusterSheet extends StatelessWidget {
  final List<_MapEventPreview> events;
  final ValueChanged<_MapEventPreview> onTapEvent;

  const _EventClusterSheet({
    required this.events,
    required this.onTapEvent,
  });

  String _whenText(_MapEventPreview event) {
    final dt = event.startsAt ?? event.createdAt;
    if (dt == null) return "Time TBD";

    final now = DateTime.now();
    final sameYear = dt.year == now.year;
    final monthNames = const [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ];

    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? "PM" : "AM";

    final datePart = sameYear
        ? "${monthNames[dt.month - 1]} ${dt.day}"
        : "${monthNames[dt.month - 1]} ${dt.day}, ${dt.year}";

    return "$datePart • $hour:$minute $ampm";
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...events]
      ..sort((a, b) {
        final ad = a.startsAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.startsAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ad.compareTo(bd);
      });

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            "${sorted.length} events here",
            style: const TextStyle(
              fontFamily: "Nunito",
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: sorted.length,
              separatorBuilder: (_, __) => Divider(
                height: 18,
                color: Colors.white.withOpacity(.08),
              ),
              itemBuilder: (_, index) {
                final event = sorted[index];
                final accent = switch (event.theme) {
                  "pink_nova" => const Color(0xFFE85ED5),
                  "violet_dusk" => const Color(0xFF8B5CF6),
                  "ocean_night" => const Color(0xFF3298FF),
                  "emerald_night" => const Color(0xFF16C784),
                  "sunset_blaze" => const Color(0xFFFF6B57),
                  "amber_smoke" => const Color(0xFFF0A827),
                  "berry_wave" => const Color(0xFFE95FAF),
                  "teal_ink" => const Color(0xFF21C7C9),
                  _ => const Color(0xFFF39C12),
                };

                return InkWell(
                  onTap: () => onTapEvent(event),
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: accent.withOpacity(.16),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: accent.withOpacity(.28)),
                          ),
                          child: Icon(
                            PhosphorIcons.calendar(PhosphorIconsStyle.fill),
                            color: Colors.white,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _whenText(event),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withOpacity(.72),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                event.locationText.isEmpty
                                    ? "Location selected"
                                    : event.locationText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: "Nunito",
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withOpacity(.56),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          PhosphorIcons.caretRight(PhosphorIconsStyle.bold),
                          color: Colors.white.withOpacity(.6),
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}