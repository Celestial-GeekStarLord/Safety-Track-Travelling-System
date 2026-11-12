// SafeStride - services.dart  (STEP 2 of 4)
//
// Everything that is not UI:
//   1. Models                (LocationPoint, SafeZone, JourneyEvent, TravelerAlert, ...)
//   2. OfflineStore          (Hive outbox: points, events, zones, meta)
//   3. Geo helpers + GeofenceEngine (familiar-zone suppression, boundary + unexpected-stop alerts)
//   4. Repo                  (Firestore: pairing, live data, zones, alerts, history streams)
//   5. TrackingService       (Traveler: GPS stream, battery, Wi-Fi BSSID, steps, offline buffer, batch sync)
//
// pubspec.yaml additions for this step:
//   cloud_firestore, firebase_messaging, hive, hive_flutter, geolocator,
//   battery_plus, connectivity_plus, network_info_plus, pedometer, geocoding
//
// Design rule: OUTBOX PATTERN. Every GPS fix is written to Hive first, then uploaded in
// batches whenever the phone is online. Online and offline use the exact same code path,
// so nothing is lost and nothing needs special-casing.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:pedometer/pedometer.dart';

/// Region of your Cloud Functions. Must equal REGION in functions/index.js.
const String kFunctionsRegion = 'asia-south1';

/// A pairing problem with a message that is safe to show the user.
class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => message;
}

/// True when Firebase.initializeApp() succeeded (otherwise the app runs in demo mode).
bool get backendReady => Firebase.apps.isNotEmpty;

// ─────────────────────────────────────────────────────────────────────────────
// 1. MODELS
// ─────────────────────────────────────────────────────────────────────────────

/// One GPS fix plus the extra sensor context we keep while offline.
class LocationPoint {
  final String id;
  final double lat, lng, accuracy, speed;
  final int ts; // epoch millis
  final String?
  bssid; // Wi-Fi breadcrumb (which router the phone is attached to)
  final int stepsDelta; // IMU step counter since previous point
  final int battery;

  LocationPoint({
    required this.id,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.ts,
    this.bssid,
    this.stepsDelta = 0,
    this.battery = -1,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'lat': lat,
    'lng': lng,
    'accuracy': accuracy,
    'speed': speed,
    'ts': ts,
    'bssid': bssid,
    'stepsDelta': stepsDelta,
    'battery': battery,
  };

  factory LocationPoint.fromMap(Map<String, dynamic> m) => LocationPoint(
    id: m['id'] as String,
    lat: (m['lat'] as num).toDouble(),
    lng: (m['lng'] as num).toDouble(),
    accuracy: (m['accuracy'] as num?)?.toDouble() ?? 0,
    speed: (m['speed'] as num?)?.toDouble() ?? 0,
    ts: m['ts'] as int,
    bssid: m['bssid'] as String?,
    stepsDelta: (m['stepsDelta'] as int?) ?? 0,
    battery: (m['battery'] as int?) ?? -1,
  );
}

enum ZoneType { home, school, work, other }

class SafeZone {
  final String id;
  String name;
  ZoneType type;
  String address;
  double lat, lng, radius; // metres
  bool quietStays; // arrivals & stays: log to history, no push
  bool notifyLeaving; // alert after crossing the boundary
  String guardianUid;
  List<String> travelerUids;

  SafeZone({
    required this.id,
    required this.name,
    this.type = ZoneType.other,
    this.address = '',
    required this.lat,
    required this.lng,
    this.radius = 150,
    this.quietStays = true,
    this.notifyLeaving = true,
    required this.guardianUid,
    required this.travelerUids,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'type': type.name,
    'address': address,
    'lat': lat,
    'lng': lng,
    'radius': radius,
    'quietStays': quietStays,
    'notifyLeaving': notifyLeaving,
    'guardianUid': guardianUid,
    'travelerUids': travelerUids,
  };

  factory SafeZone.fromMap(Map<String, dynamic> m) => SafeZone(
    id: m['id'] as String,
    name: m['name'] as String,
    type: ZoneType.values.firstWhere(
      (t) => t.name == m['type'],
      orElse: () => ZoneType.other,
    ),
    address: (m['address'] as String?) ?? '',
    lat: (m['lat'] as num).toDouble(),
    lng: (m['lng'] as num).toDouble(),
    radius: (m['radius'] as num?)?.toDouble() ?? 150,
    quietStays: (m['quietStays'] as bool?) ?? true,
    notifyLeaving: (m['notifyLeaving'] as bool?) ?? true,
    guardianUid: (m['guardianUid'] as String?) ?? '',
    travelerUids: List<String>.from((m['travelerUids'] as List?) ?? []),
  );
}

enum EventKind { arrived, left, unexpectedStop, distanceThreshold }

/// A meaningful thing that happened. `alert == false` means "save to history, send no push".
class JourneyEvent {
  final String id;
  final EventKind kind;
  final String travelerUid, travelerName;
  final String? zoneId, zoneName;
  final double lat, lng;
  final int ts;
  final int
  dwellMinutes; // minutes spent in the zone (for `left`) or stopped (for `unexpectedStop`)
  final bool alert;
  final String title;
  String body;

  JourneyEvent({
    required this.id,
    required this.kind,
    required this.travelerUid,
    required this.travelerName,
    this.zoneId,
    this.zoneName,
    required this.lat,
    required this.lng,
    required this.ts,
    this.dwellMinutes = 0,
    required this.alert,
    required this.title,
    required this.body,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind.name,
    'travelerUid': travelerUid,
    'travelerName': travelerName,
    'zoneId': zoneId,
    'zoneName': zoneName,
    'lat': lat,
    'lng': lng,
    'ts': ts,
    'dwellMinutes': dwellMinutes,
    'alert': alert,
    'title': title,
    'body': body,
  };

  factory JourneyEvent.fromMap(Map<String, dynamic> m) => JourneyEvent(
    id: m['id'] as String,
    kind: EventKind.values.firstWhere((k) => k.name == m['kind']),
    travelerUid: m['travelerUid'] as String,
    travelerName: (m['travelerName'] as String?) ?? '',
    zoneId: m['zoneId'] as String?,
    zoneName: m['zoneName'] as String?,
    lat: (m['lat'] as num).toDouble(),
    lng: (m['lng'] as num).toDouble(),
    ts: m['ts'] as int,
    dwellMinutes: (m['dwellMinutes'] as int?) ?? 0,
    alert: (m['alert'] as bool?) ?? false,
    title: (m['title'] as String?) ?? '',
    body: (m['body'] as String?) ?? '',
  );
}

/// Alert shown in the Guardian inbox (one per Guardian per alert-worthy event).
class TravelerAlert {
  final String id, guardianUid, travelerUid, travelerName, title, body;
  final EventKind kind;
  final int ts;
  final bool reviewed;
  final double? lat, lng; // where it happened
  TravelerAlert({
    required this.id,
    required this.guardianUid,
    required this.travelerUid,
    required this.travelerName,
    required this.title,
    required this.body,
    required this.kind,
    required this.ts,
    this.reviewed = false,
    this.lat,
    this.lng,
  });

  factory TravelerAlert.fromMap(Map<String, dynamic> m) => TravelerAlert(
    id: m['id'] as String,
    guardianUid: m['guardianUid'] as String,
    travelerUid: m['travelerUid'] as String,
    travelerName: (m['travelerName'] as String?) ?? '',
    title: (m['title'] as String?) ?? '',
    body: (m['body'] as String?) ?? '',
    kind: EventKind.values.firstWhere(
      (k) => k.name == m['kind'],
      orElse: () => EventKind.unexpectedStop,
    ),
    ts: m['ts'] as int,
    reviewed: (m['reviewed'] as bool?) ?? false,
    lat: (m['lat'] as num?)?.toDouble(),
    lng: (m['lng'] as num?)?.toDouble(),
  );
}

/// Diagnostics snapshot (Device quick check screen + Guardian "location & device").
class DeviceStatus {
  final int battery;
  final bool online;
  final double gpsAccuracy;
  final bool adaptive;
  final int? lastSyncTs;
  final int pending;
  final double? lastLat, lastLng;
  final int? lastFixTs;
  DeviceStatus({
    this.battery = -1,
    this.online = true,
    this.gpsAccuracy = -1,
    this.adaptive = false,
    this.lastSyncTs,
    this.pending = 0,
    this.lastLat,
    this.lastLng,
    this.lastFixTs,
  });

  Map<String, dynamic> toMap() => {
    'battery': battery,
    'online': online,
    'gpsAccuracy': gpsAccuracy,
    'adaptive': adaptive,
    'lastSyncTs': lastSyncTs,
    'pending': pending,
    'lastLat': lastLat,
    'lastLng': lastLng,
    'lastFixTs': lastFixTs,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  };

  factory DeviceStatus.fromMap(Map<String, dynamic> m) => DeviceStatus(
    battery: (m['battery'] as int?) ?? -1,
    online: (m['online'] as bool?) ?? true,
    gpsAccuracy: (m['gpsAccuracy'] as num?)?.toDouble() ?? -1,
    adaptive: (m['adaptive'] as bool?) ?? false,
    lastSyncTs: m['lastSyncTs'] as int?,
    pending: (m['pending'] as int?) ?? 0,
    lastLat: (m['lastLat'] as num?)?.toDouble(),
    lastLng: (m['lastLng'] as num?)?.toDouble(),
    lastFixTs: m['lastFixTs'] as int?,
  );
}

/// A Guardian <-> Traveler link.
class PairInfo {
  final String id,
      guardianUid,
      guardianName,
      travelerUid,
      travelerName,
      relation;
  final bool sharingPaused;
  final String travelerPhone; // shared with the Guardian so they can call
  PairInfo({
    required this.id,
    required this.guardianUid,
    required this.guardianName,
    required this.travelerUid,
    required this.travelerName,
    this.relation = '',
    this.sharingPaused = false,
    this.travelerPhone = '',
  });
  factory PairInfo.fromMap(String id, Map<String, dynamic> m) => PairInfo(
    id: id,
    guardianUid: m['guardianUid'] as String,
    guardianName: (m['guardianName'] as String?) ?? 'Guardian',
    travelerUid: m['travelerUid'] as String,
    travelerName: (m['travelerName'] as String?) ?? 'Traveler',
    relation: (m['relation'] as String?) ?? '',
    sharingPaused: (m['sharingPaused'] as bool?) ?? false,
    travelerPhone: (m['travelerPhone'] as String?) ?? '',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. OFFLINE STORE (Hive outbox, values are JSON strings so no adapters needed)
// ─────────────────────────────────────────────────────────────────────────────

class OfflineStore {
  static late Box<String> _points, _events, _meta;

  /// Call once in main() before runApp.
  static Future<void> init() async {
    await Hive.initFlutter();
    _points = await Hive.openBox<String>('points');
    _events = await Hive.openBox<String>('events');
    _meta = await Hive.openBox<String>('meta');
  }

  // points
  static Future<void> addPoint(LocationPoint p) =>
      _points.put(p.id, jsonEncode(p.toMap()));
  static List<LocationPoint> pendingPoints() =>
      _points.values
          .map(
            (s) => LocationPoint.fromMap(jsonDecode(s) as Map<String, dynamic>),
          )
          .toList()
        ..sort((a, b) => a.ts.compareTo(b.ts));
  static Future<void> removePoints(Iterable<String> ids) =>
      _points.deleteAll(ids);

  // events
  static Future<void> addEvent(JourneyEvent e) =>
      _events.put(e.id, jsonEncode(e.toMap()));
  static List<JourneyEvent> pendingEvents() =>
      _events.values
          .map(
            (s) => JourneyEvent.fromMap(jsonDecode(s) as Map<String, dynamic>),
          )
          .toList()
        ..sort((a, b) => a.ts.compareTo(b.ts));
  static Future<void> removeEvents(Iterable<String> ids) =>
      _events.deleteAll(ids);

  // cached zones + pairs, so geofencing keeps working with no connection
  static Future<void> saveZones(List<SafeZone> z) =>
      _meta.put('zones', jsonEncode(z.map((e) => e.toMap()).toList()));
  static List<SafeZone> zones() {
    final s = _meta.get('zones');
    if (s == null) {
      return [];
    }
    return (jsonDecode(s) as List)
        .map((e) => SafeZone.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<void> saveGuardians(List<String> uids) =>
      _meta.put('guardians', jsonEncode(uids));
  static List<String> guardians() {
    final s = _meta.get('guardians');
    return s == null ? [] : List<String>.from(jsonDecode(s) as List);
  }

  // simple on/off preferences that must survive restarts (e.g. the Traveler's sharing choice)
  static bool flag(String key, {bool def = true}) {
    try {
      final v = _meta.get('flag_$key');
      return v == null ? def : v == '1';
    } catch (_) {
      return def;
    }
  }

  static Future<void> setFlag(String key, bool v) async {
    try {
      await _meta.put('flag_$key', v ? '1' : '0');
    } catch (_) {}
  }

  static String str(String key) {
    try {
      return _meta.get('str_$key') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> setStr(String key, String v) async {
    try {
      await _meta.put('str_$key', v);
    } catch (_) {}
  }

  /// Wipe everything stored on this phone (used at sign-out so data never leaks between accounts).
  static Future<void> clearAll() async {
    try {
      await _points.clear();
      await _events.clear();
      await _meta.clear();
    } catch (_) {}
  }

  static Future<void> setLastSync(int ts) => _meta.put('lastSync', '$ts');
  static int? lastSync() => int.tryParse(_meta.get('lastSync') ?? '');

  /// Numbers for the "24 records waiting to sync" card.
  static PendingSummary summary() {
    final pts = pendingPoints();
    return PendingSummary(
      locationPoints: pts.length,
      wifiBreadcrumbs: pts.where((p) => p.bssid != null).length,
      stepSummaries: pts.where((p) => p.stepsDelta > 0).length,
      steps: pts.fold(0, (a, p) => a + p.stepsDelta),
      events: _events.length,
      oldestTs: pts.isEmpty ? null : pts.first.ts,
    );
  }
}

class PendingSummary {
  final int locationPoints, wifiBreadcrumbs, stepSummaries, steps, events;
  final int? oldestTs;
  const PendingSummary({
    this.locationPoints = 0,
    this.wifiBreadcrumbs = 0,
    this.stepSummaries = 0,
    this.steps = 0,
    this.events = 0,
    this.oldestTs,
  });
  int get total => locationPoints + events;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. GEO HELPERS + GEOFENCE ENGINE
// ─────────────────────────────────────────────────────────────────────────────

double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a =
      pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2);
  return 2 * r * asin(sqrt(a));
}

double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * pi / 180;
  final y = sin(rad(lng2 - lng1)) * cos(rad(lat2));
  final x =
      cos(rad(lat1)) * sin(rad(lat2)) -
      sin(rad(lat1)) * cos(rad(lat2)) * cos(rad(lng2 - lng1));
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

String compass(double deg) {
  const d = [
    'north',
    'north-east',
    'east',
    'south-east',
    'south',
    'south-west',
    'west',
    'north-west',
  ];
  return d[((deg + 22.5) % 360 ~/ 45)];
}

String fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

String fmtDuration(int minutes) {
  if (minutes < 60) {
    return '$minutes min';
  }
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

final geo.Geocoding _geocoder = geo.Geocoding();

/// Street / place name for a coordinate, or null if offline or unavailable.
/// The ONLY place the `geocoding` package is used. If it ever gives you trouble,
/// make this function `return null;` and the app keeps working (just without "Near <street>").
Future<String?> reverseGeocode(double lat, double lng) async {
  try {
    // geocoding 5.x: instance-based API (4.x and older used a top-level function)
    final list = await _geocoder.placemarkFromCoordinates(lat, lng);
    if (list.isEmpty) {
      return null;
    }
    final m = list.first;
    final name = (m.name != null && m.name!.isNotEmpty) ? m.name : m.street;
    return (name == null || name.isEmpty) ? null : name;
  } catch (_) {
    return null;
  }
}

/// Address or place name -> (latitude, longitude), or null when nothing is found (needs internet).
Future<(double, double)?> forwardGeocode(String query) async {
  try {
    final list = await _geocoder.locationFromAddress(query);
    if (list.isEmpty) {
      return null;
    }
    return (list.first.latitude, list.first.longitude);
  } catch (_) {
    return null;
  }
}

class _ZoneState {
  bool inside = false;
  int? enteredAt;
}

/// Pure Dart (no Firebase, no UI) so it works offline and is easy to unit test.
///
/// Rules:
///  * Arriving / staying in a familiar zone -> event with alert=false (history only, no push)
///  * Leaving a zone                         -> alert only if that zone has notifyLeaving
///  * Stopped >= [stopMinutes] outside every zone -> "unexpected stop" alert
///  * Farther than [distanceThresholdM] from every zone -> "distance threshold" alert
class GeofenceEngine {
  final String travelerUid, travelerName;
  final int stopMinutes;
  final double stopRadiusM;
  final double distanceThresholdM;

  GeofenceEngine({
    required this.travelerUid,
    required this.travelerName,
    this.stopMinutes = 10,
    this.stopRadiusM = 30,
    this.distanceThresholdM = 1000,
  });

  final Map<String, _ZoneState> _zones = {};
  LocationPoint? _anchor; // where the current "stop" began
  bool _stopAlerted = false;
  bool _distanceAlerted = false;
  String? _lastZoneName; // most recent zone left, for context
  int _n = 0;

  String _id() => '${DateTime.now().microsecondsSinceEpoch}_${_n++}';
  String get _first => travelerName.split(' ').first;

  List<JourneyEvent> evaluate(LocationPoint p, List<SafeZone> zones) {
    final out = <JourneyEvent>[];
    final myZones = zones.where((z) => z.travelerUids.contains(travelerUid));
    bool insideAny = false;
    double nearest = double.infinity;

    for (final z in myZones) {
      final st = _zones.putIfAbsent(z.id, () => _ZoneState());
      final d = distanceM(p.lat, p.lng, z.lat, z.lng);
      nearest = min(nearest, d - z.radius);
      // Hysteresis: need to be clearly outside (accuracy margin) before "left".
      final margin = min(p.accuracy, 50).toDouble();
      final nowInside = st.inside ? d <= z.radius + margin : d <= z.radius;

      if (nowInside && !st.inside) {
        st.inside = true;
        st.enteredAt = p.ts;
        out.add(
          JourneyEvent(
            id: _id(),
            kind: EventKind.arrived,
            travelerUid: travelerUid,
            travelerName: travelerName,
            zoneId: z.id,
            zoneName: z.name,
            lat: p.lat,
            lng: p.lng,
            ts: p.ts,
            alert:
                !z.quietStays, // quiet by default = familiar stay suppression
            title: 'Arrived at ${z.name}',
            body: '$_first arrived at ${z.name} at ${fmtTime(p.ts)}.',
          ),
        );
      } else if (!nowInside && st.inside) {
        final mins = ((p.ts - (st.enteredAt ?? p.ts)) / 60000).round();
        st.inside = false;
        st.enteredAt = null;
        _lastZoneName = z.name;
        _distanceAlerted = false;
        final dir = compass(bearingDeg(z.lat, z.lng, p.lat, p.lng));
        out.add(
          JourneyEvent(
            id: _id(),
            kind: EventKind.left,
            travelerUid: travelerUid,
            travelerName: travelerName,
            zoneId: z.id,
            zoneName: z.name,
            lat: p.lat,
            lng: p.lng,
            ts: p.ts,
            dwellMinutes: mins,
            alert: z.notifyLeaving,
            title: '$_first left ${z.name}',
            body:
                'Crossed the ${z.radius.round()} m ${z.name} boundary at ${fmtTime(p.ts)}, heading $dir. Stayed ${fmtDuration(mins)}.',
          ),
        );
      }
      insideAny = insideAny || st.inside;
    }

    // ── Unexpected stop (outside every familiar zone)
    if (insideAny) {
      _anchor = null;
      _stopAlerted = false;
    } else {
      final a = _anchor;
      if (a == null || distanceM(a.lat, a.lng, p.lat, p.lng) > stopRadiusM) {
        _anchor = p; // moved: restart the stop timer
        _stopAlerted = false;
      } else if (!_stopAlerted && p.ts - a.ts >= stopMinutes * 60000) {
        _stopAlerted = true;
        final mins = ((p.ts - a.ts) / 60000).round();
        out.add(
          JourneyEvent(
            id: _id(),
            kind: EventKind.unexpectedStop,
            travelerUid: travelerUid,
            travelerName: travelerName,
            lat: p.lat,
            lng: p.lng,
            ts: p.ts,
            dwellMinutes: mins,
            alert: true,
            title: 'An unexpected pause',
            body:
                '$_first has stayed in one place for $mins min, outside familiar zones${_lastZoneName != null ? ' since leaving $_lastZoneName' : ''}.',
          ),
        );
      }
    }

    // ── Distance threshold from every safe zone
    if (!insideAny && nearest.isFinite) {
      if (nearest > distanceThresholdM && !_distanceAlerted) {
        _distanceAlerted = true;
        out.add(
          JourneyEvent(
            id: _id(),
            kind: EventKind.distanceThreshold,
            travelerUid: travelerUid,
            travelerName: travelerName,
            lat: p.lat,
            lng: p.lng,
            ts: p.ts,
            alert: true,
            title: 'Distance threshold reached',
            body:
                'More than ${(distanceThresholdM / 1000).toStringAsFixed(1)} km from the nearest familiar zone at ${fmtTime(p.ts)}.',
          ),
        );
      } else if (nearest < distanceThresholdM * .8) {
        _distanceAlerted = false;
      }
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. REPO (Firestore)
// ─────────────────────────────────────────────────────────────────────────────
//
// Collections
//   users/{uid}                       {name, email, role, fcmToken}
//   pairingCodes/{code}               {guardianUid, guardianName, expiresAt, used}
//   pairs/{pairId}                    {guardianUid, travelerUid, names..., sharingPaused}
//   zones/{zoneId}                    SafeZone.toMap()
//   alerts/{alertId}                  {guardianUid, travelerUid, title, body, kind, ts, reviewed}
//   travelers/{uid}/live/current      latest LocationPoint
//   travelers/{uid}/status/current    DeviceStatus
//   travelers/{uid}/points/{id}       history points (route + Wi-Fi + steps)
//   travelers/{uid}/events/{id}       JourneyEvent (timeline + dwell time)

class Repo {
  Repo._();
  static final instance = Repo._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  // ── users + push
  /// [overwriteRole] false keeps an existing role (used when an existing user signs in, so
  /// "Already connected? Sign in" can never flip a Guardian into a Traveler).
  Future<void> saveProfile({
    required String name,
    required String role,
    bool overwriteRole = true,
  }) async {
    final u = uid;
    if (u == null) {
      return;
    }
    final ref = _db.collection('users').doc(u);
    final data = <String, dynamic>{
      'name': name,
      'email': FirebaseAuth.instance.currentUser?.email,
    };
    if (overwriteRole) {
      data['role'] = role;
    } else {
      final snap = await ref.get();
      if (snap.data()?['role'] == null) {
        data['role'] = role;
      }
    }
    await ref.set(data, SetOptions(merge: true));
  }

  /// Stores the FCM token so a Cloud Function can push alerts to this Guardian.
  StreamSubscription<String>? _tokenSub;

  Future<void> registerPushToken() async {
    final u = uid;
    if (u == null) {
      return;
    }
    final fm = FirebaseMessaging.instance;
    await fm.requestPermission();
    final token = await fm.getToken();
    if (token != null) {
      await _db.collection('users').doc(u).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    }
    await _tokenSub?.cancel();
    _tokenSub = fm.onTokenRefresh.listen(
      (t) => _db.collection('users').doc(u).set({
        'fcmToken': t,
      }, SetOptions(merge: true)),
    );
  }

  /// Sign-out: stop this phone receiving the account's alerts.
  Future<void> clearPushToken() async {
    final u = uid;
    await _tokenSub?.cancel();
    _tokenSub = null;
    try {
      if (u != null) {
        await _db.collection('users').doc(u).update({
          'fcmToken': FieldValue.delete(),
        });
      }
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  // ── alert preferences + single alert lookup
  Future<Map<String, dynamic>?> getPrefs() async {
    final u = uid;
    if (u == null) {
      return null;
    }
    final snap = await _db.collection('users').doc(u).get();
    final p = snap.data()?['prefs'];
    return p == null ? null : Map<String, dynamic>.from(p as Map);
  }

  Future<void> savePrefs(Map<String, dynamic> prefs) async {
    final u = uid;
    if (u == null) {
      return;
    }
    await _db.collection('users').doc(u).set({
      'prefs': prefs,
    }, SetOptions(merge: true));
  }

  Future<TravelerAlert?> getAlert(String id) async {
    final d = await _db.collection('alerts').doc(id).get();
    final m = d.data();
    return m == null ? null : TravelerAlert.fromMap(m);
  }

  // ── pairing
  Future<void> createPairingCode(
    String code,
    String guardianName,
    DateTime expires,
  ) => _db.collection('pairingCodes').doc(code).set({
    'guardianUid': uid,
    'guardianName': guardianName,
    'expiresAt': expires.millisecondsSinceEpoch,
    'used': false,
  });

  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: kFunctionsRegion);

  /// Returns the Guardian's name if the code is valid, else null.
  /// Goes through the `lookupCode` Cloud Function, which limits how fast codes can be guessed.
  /// If the function is not deployed yet, falls back to a direct read (works with the
  /// development rules only; the hardened rules block it on purpose).
  Future<String?> lookupCode(String code) async {
    try {
      final res = await _fn.httpsCallable('lookupCode').call({'code': code});
      final data = Map<String, dynamic>.from(res.data as Map);
      return data['guardianName'] as String?;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') {
        return _lookupDirect(code);
      }
      throw PairingException(e.message ?? 'Could not check that code.');
    }
  }

  Future<String?> _lookupDirect(String code) async {
    final snap = await _db.collection('pairingCodes').doc(code).get();
    final d = snap.data();
    if (d == null || d['used'] == true) {
      return null;
    }
    if ((d['expiresAt'] as int) < DateTime.now().millisecondsSinceEpoch) {
      return null;
    }
    return d['guardianName'] as String?;
  }

  /// Traveler confirms: the `confirmPairing` Cloud Function burns the code and creates the pair.
  Future<void> confirmPairing(
    String code, {
    required String travelerName,
    String travelerPhone = '',
  }) async {
    try {
      await _fn.httpsCallable('confirmPairing').call({
        'code': code,
        'travelerName': travelerName,
        'travelerPhone': travelerPhone,
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') {
        return _confirmDirect(
          code,
          travelerName: travelerName,
          travelerPhone: travelerPhone,
        );
      }
      throw PairingException(e.message ?? 'Could not complete pairing.');
    }
  }

  /// Development fallback (no Cloud Function). The pair id is "<guardianUid>_<travelerUid>",
  /// the same id the function uses, so security rules can check a pair exists.
  Future<void> _confirmDirect(
    String code, {
    required String travelerName,
    String travelerPhone = '',
  }) async {
    final ref = _db.collection('pairingCodes').doc(code);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final d = snap.data();
      if (d == null || d['used'] == true) {
        throw PairingException(
          'That code is invalid or has already been used.',
        );
      }
      if ((d['expiresAt'] as int) < DateTime.now().millisecondsSinceEpoch) {
        throw PairingException('That code has expired. Ask for a new one.');
      }
      if (d['guardianUid'] == uid) {
        throw PairingException('You cannot pair with yourself.');
      }
      final pairRef = _db.collection('pairs').doc('${d['guardianUid']}_$uid');
      tx.set(pairRef, {
        'guardianUid': d['guardianUid'],
        'guardianName': d['guardianName'],
        'travelerUid': uid,
        'travelerName': travelerName,
        'travelerPhone': travelerPhone,
        'members': [d['guardianUid'], uid],
        'sharingPaused': false,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
      tx.set(_db.collection('users').doc(uid), {
        'guardians': FieldValue.arrayUnion([d['guardianUid']]),
      }, SetOptions(merge: true));
      tx.update(ref, {'used': true});
    });
  }

  /// Traveler updates the number their Guardians can call.
  Future<void> updateTravelerPhone(String phone) async {
    final u = uid;
    if (u == null) {
      return;
    }
    final snap = await _db
        .collection('pairs')
        .where('travelerUid', isEqualTo: u)
        .get();
    for (final d in snap.docs) {
      await d.reference.update({'travelerPhone': phone});
    }
  }

  Future<void> setSharingPaused(String pairId, bool paused) =>
      _db.collection('pairs').doc(pairId).update({'sharingPaused': paused});

  Future<void> endPairing(String pairId) =>
      _db.collection('pairs').doc(pairId).delete();

  Stream<List<PairInfo>> watchPairsAsGuardian() => _db
      .collection('pairs')
      .where('guardianUid', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => PairInfo.fromMap(d.id, d.data())).toList());

  Stream<List<PairInfo>> watchPairsAsTraveler() => _db
      .collection('pairs')
      .where('travelerUid', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => PairInfo.fromMap(d.id, d.data())).toList());

  /// Traveler device: keep guardians + zones cached for offline geofencing.
  StreamSubscription<dynamic>? _zonesSub;

  StreamSubscription<dynamic> syncCachesForTraveler() {
    _zonesSub?.cancel();
    _zonesSub = _db
        .collection('zones')
        .where('travelerUids', arrayContains: uid)
        .snapshots()
        .listen((s) {
          OfflineStore.saveZones(
            s.docs.map((d) => SafeZone.fromMap(d.data())).toList(),
          );
        }, onError: (_) {});
    return watchPairsAsTraveler().listen((pairs) {
      OfflineStore.saveGuardians(pairs.map((p) => p.guardianUid).toList());
    }, onError: (_) {});
  }

  void stopCaches() {
    _zonesSub?.cancel();
    _zonesSub = null;
  }

  // ── live + history streams (Guardian screens, step 4)
  Stream<LocationPoint?> watchLive(String travelerUid) => _db
      .collection('travelers')
      .doc(travelerUid)
      .collection('live')
      .doc('current')
      .snapshots()
      .map((d) => d.data() == null ? null : LocationPoint.fromMap(d.data()!));

  Stream<DeviceStatus?> watchStatus(String travelerUid) => _db
      .collection('travelers')
      .doc(travelerUid)
      .collection('status')
      .doc('current')
      .snapshots()
      .map((d) => d.data() == null ? null : DeviceStatus.fromMap(d.data()!));

  /// Points in a time window. Capped at the newest 2,500 to keep reads and drawing cheap.
  Stream<List<LocationPoint>> watchPoints(
    String travelerUid,
    DateTime from,
    DateTime to,
  ) => _db
      .collection('travelers')
      .doc(travelerUid)
      .collection('points')
      .where('ts', isGreaterThanOrEqualTo: from.millisecondsSinceEpoch)
      .where('ts', isLessThan: to.millisecondsSinceEpoch)
      .orderBy('ts', descending: true)
      .limit(2500)
      .snapshots()
      .map(
        (s) => s.docs
            .map((d) => LocationPoint.fromMap(d.data()))
            .toList()
            .reversed
            .toList(),
      );

  /// The latest [limit] points (oldest first) for the live route on a Traveler's detail page.
  Stream<List<LocationPoint>> watchRecentPoints(
    String travelerUid, {
    int limit = 120,
  }) => _db
      .collection('travelers')
      .doc(travelerUid)
      .collection('points')
      .orderBy('ts', descending: true)
      .limit(limit)
      .snapshots()
      .map(
        (s) => s.docs
            .map((d) => LocationPoint.fromMap(d.data()))
            .toList()
            .reversed
            .toList(),
      );

  Stream<List<JourneyEvent>> watchEvents(
    String travelerUid,
    DateTime from,
    DateTime to,
  ) => _db
      .collection('travelers')
      .doc(travelerUid)
      .collection('events')
      .where('ts', isGreaterThanOrEqualTo: from.millisecondsSinceEpoch)
      .where('ts', isLessThan: to.millisecondsSinceEpoch)
      .orderBy('ts', descending: true)
      .snapshots()
      .map((s) => s.docs.map((d) => JourneyEvent.fromMap(d.data())).toList());

  // ── zones
  Stream<List<SafeZone>> watchZones() => _db
      .collection('zones')
      .where('guardianUid', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map((d) => SafeZone.fromMap(d.data())).toList());

  Future<void> saveZone(SafeZone z) =>
      _db.collection('zones').doc(z.id).set(z.toMap());
  Future<void> deleteZone(String id) =>
      _db.collection('zones').doc(id).delete();
  String newId() => _db.collection('zones').doc().id;

  // ── alerts
  /// Needs a composite index (guardianUid ASC, ts DESC). Firebase prints the link on first run.
  Stream<List<TravelerAlert>> watchAlerts() => _db
      .collection('alerts')
      .where('guardianUid', isEqualTo: uid)
      .orderBy('ts', descending: true)
      .limit(60)
      .snapshots()
      .map((s) => s.docs.map((d) => TravelerAlert.fromMap(d.data())).toList());

  Future<void> markAlertReviewed(String id) =>
      _db.collection('alerts').doc(id).update({'reviewed': true});
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. TRACKING SERVICE (runs on the Traveler's phone)
// ─────────────────────────────────────────────────────────────────────────────

enum TrackMode { moving, still, lowPower }

class TrackingService extends ChangeNotifier {
  TrackingService._();
  static final instance = TrackingService._();

  // public state the Traveler UI listens to
  bool running = false;
  String? problem; // why tracking could not start (shown on Traveler Home)
  bool online = true;
  String connection = 'Wi-Fi';
  int battery = -1;
  double gpsAccuracy = -1;
  LocationPoint? lastPoint;
  final List<LocationPoint> trail =
      []; // recent fixes, drawn on the Traveler's own map
  int? lastSyncTs = OfflineStoreSafe.lastSync();
  PendingSummary pending = const PendingSummary();
  TrackMode mode = TrackMode.moving;
  bool get adaptive => mode != TrackMode.moving;

  // internals
  late String _uid, _name;
  late GeofenceEngine _engine;
  StreamSubscription<Position>? _pos;
  StreamSubscription<List<ConnectivityResult>>? _conn;
  StreamSubscription<StepCount>? _stepSub;
  StreamSubscription<dynamic>? _cacheSub;
  Timer? _heartbeat;
  final _battery = Battery();
  int _stepBase = -1, _stepLastSent = 0, _stepNow = 0;
  int _lastUpload = 0, _lastMovingAt = 0, _n = 0;
  bool _flushing = false;

  /// Upload cadence adapts to motion and battery (the "battery-saving mode" in the UI).
  Duration get _uploadEvery => switch (mode) {
    TrackMode.moving => const Duration(seconds: 30),
    TrackMode.still => const Duration(minutes: 5),
    TrackMode.lowPower => const Duration(minutes: 10),
  };

  Future<bool> start({
    required String travelerUid,
    required String travelerName,
  }) async {
    if (running) {
      return true;
    }
    _uid = travelerUid;
    _name = travelerName;
    _engine = GeofenceEngine(travelerUid: _uid, travelerName: _name);

    problem = null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      problem = 'Location is turned off on this phone.';
      notifyListeners();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      problem =
          'Location permission is blocked. Open phone settings to allow it.';
      notifyListeners();
      return false;
    }
    if (perm == LocationPermission.denied) {
      problem = 'SafeStride needs location permission to share your journey.';
      notifyListeners();
      return false;
    }
    // NOTE: for "Always" on Android 10+/iOS, ask via permission_handler's Permission.locationAlways
    // AFTER the user has granted "While using" (screen 3 explains this to the user).

    running = true;
    _lastMovingAt = DateTime.now().millisecondsSinceEpoch;
    if (backendReady) {
      _cacheSub = Repo.instance.syncCachesForTraveler();
    }

    _subscribePosition();

    final first = await Connectivity().checkConnectivity();
    online = _isOnline(first);
    connection = _label(first);
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      final was = online;
      online = _isOnline(r);
      connection = _label(r);
      notifyListeners();
      if (online && !was) flush(force: true); // reconnected -> batch sync
    });

    try {
      _stepSub = Pedometer.stepCountStream.listen((s) {
        if (_stepBase < 0) {
          _stepBase = s.steps;
        }
        _stepNow = s.steps - _stepBase;
      }, onError: (_) {});
    } catch (_) {}

    _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) async {
      await _refreshBattery();
      _refreshPending();
      if (online) {
        await flush(force: true);
      }
      notifyListeners();
    });

    await _refreshBattery();
    _refreshPending();
    notifyListeners();
    return true;
  }

  Future<void> stop() async {
    await _pos?.cancel();
    await _conn?.cancel();
    await _stepSub?.cancel();
    await _cacheSub?.cancel();
    if (backendReady) {
      Repo.instance.stopCaches();
    }
    _heartbeat?.cancel();
    running = false;
    notifyListeners();
  }

  /// Manual "Check connection again" button on the Device screen.
  Future<void> recheck() async {
    final c = await Connectivity().checkConnectivity();
    online = _isOnline(c);
    connection = _label(c);
    await _refreshBattery();
    if (online) {
      await flush(force: true);
    }
    _refreshPending();
    notifyListeners();
  }

  String _label(List<ConnectivityResult> r) {
    if (r.contains(ConnectivityResult.wifi)) {
      return 'Wi-Fi';
    }
    if (r.contains(ConnectivityResult.mobile)) {
      return 'Mobile data';
    }
    if (r.isEmpty || r.contains(ConnectivityResult.none)) {
      return 'Offline';
    }
    return 'Connected';
  }

  bool _isOnline(List<ConnectivityResult> r) =>
      r.isNotEmpty && !r.contains(ConnectivityResult.none);

  // ── GPS stream
  void _subscribePosition() {
    _pos?.cancel();
    _pos = Geolocator.getPositionStream(
      locationSettings: _settings(),
    ).listen(_onPosition);
  }

  LocationSettings _settings() {
    final acc = mode == TrackMode.lowPower
        ? LocationAccuracy.medium
        : LocationAccuracy.high;
    final filter = mode == TrackMode.moving ? 15 : 40;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: acc,
        distanceFilter: filter,
        intervalDuration: _uploadEvery ~/ 2,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'SafeStride is sharing',
          notificationText: 'Your Guardian can see your shared location.',
          enableWakeLock: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: acc,
        distanceFilter: filter,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(accuracy: acc, distanceFilter: filter);
  }

  Future<void> _onPosition(Position pos) async {
    final now = pos.timestamp.millisecondsSinceEpoch;
    if (pos.speed > 0.7) {
      _lastMovingAt = now;
    }

    // adaptive mode
    final newMode = (battery >= 0 && battery <= 20)
        ? TrackMode.lowPower
        : (now - _lastMovingAt > 3 * 60000
              ? TrackMode.still
              : TrackMode.moving);
    final changed = newMode != mode;
    mode = newMode;

    String? bssid;
    try {
      bssid = await NetworkInfo().getWifiBSSID();
    } catch (_) {}
    await _refreshBattery();

    final stepsDelta = max(0, _stepNow - _stepLastSent);
    _stepLastSent = _stepNow;

    final p = LocationPoint(
      id: '${now}_${_n++}',
      lat: pos.latitude,
      lng: pos.longitude,
      accuracy: pos.accuracy,
      speed: pos.speed,
      ts: now,
      bssid: bssid,
      stepsDelta: stepsDelta,
      battery: battery,
    );
    lastPoint = p;
    trail.add(p);
    if (trail.length > 150) {
      trail.removeAt(0);
    }
    gpsAccuracy = pos.accuracy;

    // 1) always buffer first (outbox)
    await OfflineStore.addPoint(p);

    // 2) geofence evaluation works offline using cached zones
    final events = _engine.evaluate(p, OfflineStore.zones());
    for (final e in events) {
      await _addContext(e);
      await OfflineStore.addEvent(e);
    }

    _refreshPending();
    notifyListeners();

    // 3) upload when online, on schedule or when something noteworthy happened
    final due =
        now - _lastUpload >= _uploadEvery.inMilliseconds || events.isNotEmpty;
    if (online && due) {
      await flush();
    }

    if (changed)
      _subscribePosition(); // re-subscribe with new accuracy / filter
  }

  /// Adds "near <street>" to the event text when we can look it up (needs internet).
  Future<void> _addContext(JourneyEvent e) async {
    if (!online) {
      return;
    }
    final street = await reverseGeocode(e.lat, e.lng);
    if (street != null) e.body = '${e.body} Near $street.';
  }

  // ── batch sync
  Future<void> flush({bool force = false}) async {
    if (!backendReady || _flushing || !online) {
      return;
    }
    _flushing = true;
    try {
      final db = FirebaseFirestore.instance;
      final pts = OfflineStore.pendingPoints();
      final evs = OfflineStore.pendingEvents();
      final guardians = OfflineStore.guardians();

      // Firestore batches hold up to 500 writes; stay well below that.
      Future<void> commit(void Function(WriteBatch b) fill) async {
        final b = db.batch();
        fill(b);
        await b.commit();
      }

      final traveler = db.collection('travelers').doc(_uid);

      for (var i = 0; i < pts.length; i += 400) {
        final chunk = pts.sublist(i, min(i + 400, pts.length));
        await commit((b) {
          for (final p in chunk) {
            b.set(traveler.collection('points').doc(p.id), p.toMap());
          }
        });
        await OfflineStore.removePoints(chunk.map((p) => p.id));
      }

      for (var i = 0; i < evs.length; i += 150) {
        final chunk = evs.sublist(i, min(i + 150, evs.length));
        await commit((b) {
          for (final e in chunk) {
            b.set(traveler.collection('events').doc(e.id), e.toMap());
            if (e.alert) {
              // One alert per Guardian. A Cloud Function on alerts/{id} onCreate sends the FCM push.
              for (final g in guardians) {
                b.set(db.collection('alerts').doc('${e.id}_$g'), {
                  'id': '${e.id}_$g',
                  'guardianUid': g,
                  'travelerUid': e.travelerUid,
                  'travelerName': e.travelerName,
                  'kind': e.kind.name,
                  'title': e.title,
                  'body': e.body,
                  'ts': e.ts,
                  'reviewed': false,
                  'lat': e.lat,
                  'lng': e.lng,
                });
              }
            }
          }
        });
        await OfflineStore.removeEvents(chunk.map((e) => e.id));
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      _lastUpload = now;
      lastSyncTs = now;
      await OfflineStore.setLastSync(now);

      // live pointer + diagnostics (last-known location stays here if the phone later goes dark)
      final last = pts.isNotEmpty ? pts.last : lastPoint;
      if (last != null) {
        await traveler.collection('live').doc('current').set(last.toMap());
      }
      await traveler
          .collection('status')
          .doc('current')
          .set(
            DeviceStatus(
              battery: battery,
              online: true,
              gpsAccuracy: gpsAccuracy,
              adaptive: adaptive,
              lastSyncTs: now,
              pending: 0,
              lastLat: last?.lat,
              lastLng: last?.lng,
              lastFixTs: last?.ts,
            ).toMap(),
          );
    } catch (e) {
      debugPrint('Sync failed, will retry (data stays in outbox): $e');
    } finally {
      _flushing = false;
      _refreshPending();
      notifyListeners();
    }
  }

  Future<void> _refreshBattery() async {
    try {
      battery = await _battery.batteryLevel;
    } catch (_) {}
  }

  void _refreshPending() => pending = OfflineStore.summary();
}

/// Lets the singleton read lastSync before Hive is necessarily opened (demo mode safe).
class OfflineStoreSafe {
  static int? lastSync() {
    try {
      return OfflineStore.lastSync();
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIRESTORE SECURITY RULES (paste into firestore.rules)
// ─────────────────────────────────────────────────────────────────────────────
//
// rules_version = '2';
// service cloud.firestore {
//   match /databases/{database}/documents {
//     function signedIn() { return request.auth != null; }
//     function isGuardianOf(t) {
//       return request.auth.uid in get(/databases/$(database)/documents/users/$(t)).data.get('guardians', []);
//     }
//     match /users/{u} { allow read, write: if signedIn() && request.auth.uid == u; }
//     match /pairingCodes/{c} {
//       allow get, create, update: if signedIn();
//       allow list: if false;
//     }
//     match /pairs/{p} {
//       allow read, update, delete: if signedIn() &&
//         (request.auth.uid == resource.data.guardianUid || request.auth.uid == resource.data.travelerUid);
//       allow create: if signedIn() && request.auth.uid in request.resource.data.members;
//     }
//     match /zones/{z} {
//       allow read: if signedIn() && (request.auth.uid == resource.data.guardianUid ||
//                                     request.auth.uid in resource.data.travelerUids);
//       allow create, update: if signedIn() && request.auth.uid == request.resource.data.guardianUid;
//       allow delete: if signedIn() && request.auth.uid == resource.data.guardianUid;
//     }
//     match /alerts/{a} {
//       allow read, update: if signedIn() && request.auth.uid == resource.data.guardianUid;
//       allow create: if signedIn() && request.auth.uid == request.resource.data.travelerUid;
//     }
//     match /travelers/{t}/{doc=**} {
//       allow write: if signedIn() && request.auth.uid == t;
//       allow read: if signedIn() && (request.auth.uid == t || isGuardianOf(t));
//     }
//   }
// }
//
// Tighten before production: move code confirmation + alert creation into Cloud Functions
// (6-digit codes are brute-forceable without rate limiting).
//
// ─────────────────────────────────────────────────────────────────────────────
// CLOUD FUNCTION (functions/index.js) - push alerts to the Guardian
// ─────────────────────────────────────────────────────────────────────────────
//
// const { onDocumentCreated } = require('firebase-functions/v2/firestore');
// const admin = require('firebase-admin'); admin.initializeApp();
// exports.pushAlert = onDocumentCreated('alerts/{id}', async (e) => {
//   const a = e.data.data();
//   const u = await admin.firestore().doc(`users/${a.guardianUid}`).get();
//   const token = u.data()?.fcmToken;
//   if (token) await admin.messaging().send({ token,
//     notification: { title: a.title, body: a.body },
//     data: { kind: a.kind, travelerUid: a.travelerUid } });
// });
