// SafeStride - maps.dart  (added in build-out step 2)
//
// One reusable real map for every screen: OpenStreetMap tiles through flutter_map.
//
//   LiveMap(...)  shows: a person marker (initials), a route line, safe-zone circles drawn
//                 at their TRUE size in metres, extra pins (events/alerts), and an editable
//                 zone circle with tap-to-place.
//
// Demo mode (no Firebase) keeps using the stylised MiniMap through `fallback`.
//
// Requires: flutter pub add flutter_map latlong2
//
// Note on tiles: tile.openstreetmap.org is fine for development and small apps, but its usage
// policy forbids heavy production traffic. Before a public release, swap the URL in
// `_tileUrl` for a provider you have an account with (MapTiler, Stadia, Thunderforest...).

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart';
import 'services.dart';

const String _tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _userAgent = 'com.example.safestride';

LatLng ll(LocationPoint p) => LatLng(p.lat, p.lng);

/// Keeps at most [max] points (always the first and the last) so long routes stay fast.
List<LatLng> decimate(List<LatLng> pts, {int max = 400}) {
  if (pts.length <= max) {
    return pts;
  }
  final step = pts.length / max;
  final out = <LatLng>[];
  for (var i = 0; i < max; i++) {
    out.add(pts[(i * step).floor()]);
  }
  out.add(pts.last);
  return out;
}

/// How much the user can touch the map.
///  fixed      -> display only (for cards inside a list)
///  scrollSafe -> two-finger pan/zoom, so one finger still scrolls the page
///  full       -> one-finger pan too (for the zone editor)
enum MapMode { fixed, scrollSafe, full }

class MapPin {
  final LatLng at;
  final IconData icon;
  final Color bg;
  final Color fg;
  const MapPin(this.at, this.icon, {this.bg = SS.teal, this.fg = Colors.white});
}

class LiveMap extends StatefulWidget {
  final double height;
  final LatLng? center; // the person marker
  final String initials;
  final bool markerFaded; // offline: draw the marker in grey
  final List<LatLng> route;
  final List<SafeZone> zones;
  final List<MapPin> pins;
  final LatLng? editCenter; // zone being edited
  final double? editRadius; // metres
  final ValueChanged<LatLng>? onTap;
  final MapMode mode;
  final bool refitOnChange; // follow new data until the user moves the map
  final MapController? controller;
  final Widget? fallback; // shown in demo mode
  final String emptyText;

  const LiveMap({
    super.key,
    this.height = 190,
    this.center,
    this.initials = '·',
    this.markerFaded = false,
    this.route = const [],
    this.zones = const [],
    this.pins = const [],
    this.editCenter,
    this.editRadius,
    this.onTap,
    this.mode = MapMode.scrollSafe,
    this.refitOnChange = true,
    this.controller,
    this.fallback,
    this.emptyText = 'Waiting for the first location…',
  });

  @override
  State<LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<LiveMap> {
  late final MapController _ctl = widget.controller ?? MapController();
  bool _ready = false;
  bool _userMoved = false;

  @override
  void dispose() {
    if (widget.controller == null) {
      _ctl.dispose(); // only dispose a controller we created ourselves
    }
    super.dispose();
  }

  List<LatLng> _circleExtent(LatLng c, double r) {
    const d = Distance();
    return [
      d.offset(c, r, 0),
      d.offset(c, r, 90),
      d.offset(c, r, 180),
      d.offset(c, r, 270),
    ];
  }

  /// Every coordinate the camera should try to keep in view.
  List<LatLng> _frame() {
    final pts = <LatLng>[];
    if (widget.center != null) {
      pts.add(widget.center!);
    }
    pts.addAll(widget.route);
    for (final p in widget.pins) {
      pts.add(p.at);
    }
    if (widget.editCenter != null) {
      pts.addAll(_circleExtent(widget.editCenter!, widget.editRadius ?? 150));
    }
    // Only include zones when nothing else is being framed, or when they are close
    // to the person (so a far-away zone does not zoom the map out to the continent).
    if (pts.isEmpty) {
      for (final z in widget.zones) {
        if (z.lat != 0 || z.lng != 0) {
          pts.addAll(_circleExtent(LatLng(z.lat, z.lng), z.radius));
        }
      }
    } else {
      final anchor = pts.first;
      for (final z in widget.zones) {
        final c = LatLng(z.lat, z.lng);
        if (const Distance().as(LengthUnit.Meter, anchor, c) < 3000) {
          pts.addAll(_circleExtent(c, z.radius));
        }
      }
    }
    return pts;
  }

  CameraFit _fit(List<LatLng> pts) => CameraFit.coordinates(
    coordinates: pts,
    padding: const EdgeInsets.all(34),
    maxZoom: 17,
  );

  String _signature() {
    String r(LatLng? p) => p == null
        ? '-'
        : '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';
    return '${r(widget.center)}|${r(widget.editCenter)}|${widget.editRadius?.round()}|${widget.route.length}|${widget.pins.length}|${widget.zones.length}';
  }

  void _refit() {
    if (!_ready) {
      return;
    }
    final pts = _frame();
    if (pts.isEmpty) {
      return;
    }
    try {
      _ctl.fitCamera(_fit(pts));
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant LiveMap old) {
    super.didUpdateWidget(old);
    if (widget.refitOnChange && !_userMoved) {
      final oldSig = _SigHolder.of(old);
      if (oldSig != _signature()) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refit());
      }
    }
  }

  int get _flags => switch (widget.mode) {
    MapMode.fixed => InteractiveFlag.none,
    MapMode.scrollSafe => InteractiveFlag.pinchZoom | InteractiveFlag.pinchMove,
    MapMode.full =>
      InteractiveFlag.drag |
          InteractiveFlag.pinchZoom |
          InteractiveFlag.pinchMove |
          InteractiveFlag.doubleTapZoom,
  };

  Widget _personMarker() => Container(
    width: 36,
    height: 36,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: widget.markerFaded ? Colors.white : SS.teal,
      shape: BoxShape.circle,
      border: Border.all(
        color: widget.markerFaded ? SS.muted : Colors.white,
        width: 2.5,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: Text(
      widget.initials,
      style: ssBody(
        bold: true,
        size: 12,
        color: widget.markerFaded ? SS.muted : Colors.white,
      ),
    ),
  );

  Widget _pin(MapPin p) => Container(
    decoration: BoxDecoration(
      color: p.bg,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 3,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: Icon(p.icon, size: 15, color: p.fg),
  );

  @override
  Widget build(BuildContext context) {
    // Demo mode: stylised placeholder.
    if (!backendReady) {
      return widget.fallback ??
          MiniMap(height: widget.height, initials: widget.initials);
    }

    final frame = _frame();
    _SigHolder.store(widget, _signature());

    if (frame.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: widget.height,
          width: double.infinity,
          color: SS.mapBase,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_searching, color: SS.muted, size: 26),
              const SizedBox(height: 8),
              Text(
                widget.emptyText,
                style: ssBody(size: 12.5, color: SS.muted),
              ),
            ],
          ),
        ),
      );
    }

    final zoneCircles = <CircleMarker>[
      for (final z in widget.zones)
        if (z.lat != 0 || z.lng != 0)
          CircleMarker(
            point: LatLng(z.lat, z.lng),
            radius: z.radius,
            useRadiusInMeter: true,
            color: SS.teal.withAlpha(30),
            borderColor: SS.teal,
            borderStrokeWidth: 1.5,
          ),
      if (widget.editCenter != null)
        CircleMarker(
          point: widget.editCenter!,
          radius: widget.editRadius ?? 150,
          useRadiusInMeter: true,
          color: SS.teal.withAlpha(45),
          borderColor: SS.teal,
          borderStrokeWidth: 2.2,
        ),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _ctl,
              options: MapOptions(
                initialCameraFit: _fit(frame),
                interactionOptions: InteractionOptions(flags: _flags),
                onMapReady: () => _ready = true,
                onTap: widget.onTap == null
                    ? null
                    : (_, point) => widget.onTap!(point),
                onPositionChanged: (camera, hasGesture) {
                  if (hasGesture) {
                    _userMoved = true;
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: _tileUrl,
                  userAgentPackageName: _userAgent,
                ),
                if (zoneCircles.isNotEmpty) CircleLayer(circles: zoneCircles),
                if (widget.route.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: widget.route,
                        strokeWidth: 4.5,
                        color: SS.teal,
                        borderStrokeWidth: 1.5,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final z in widget.zones)
                      if (z.lat != 0 || z.lng != 0)
                        Marker(
                          point: LatLng(z.lat, z.lng),
                          width: 90,
                          height: 22,
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(225),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              z.name,
                              overflow: TextOverflow.ellipsis,
                              style: ssBody(
                                bold: true,
                                size: 10.5,
                                color: SS.teal,
                              ),
                            ),
                          ),
                        ),
                    if (widget.editCenter != null)
                      Marker(
                        point: widget.editCenter!,
                        width: 40,
                        height: 40,
                        child: const Icon(
                          Icons.place,
                          size: 38,
                          color: SS.teal,
                        ),
                      ),
                    for (final p in widget.pins)
                      Marker(
                        point: p.at,
                        width: 28,
                        height: 28,
                        child: _pin(p),
                      ),
                    if (widget.center != null)
                      Marker(
                        point: widget.center!,
                        width: 36,
                        height: 36,
                        child: _personMarker(),
                      ),
                  ],
                ),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  showFlutterMapAttribution: false,
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
            // Recenter
            Positioned(
              right: 8,
              top: 8,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(),
                elevation: 1.5,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    _userMoved = false;
                    _refit();
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(Icons.my_location, size: 18, color: SS.teal),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Remembers the previous widget's signature (didUpdateWidget only receives the old widget).
class _SigHolder {
  static final Expando<String> _sigs = Expando<String>();
  static void store(LiveMap w, String sig) => _sigs[w] = sig;
  static String? of(LiveMap w) => _sigs[w];
}

/// Small helper used by the zone editor and others.
double metersBetween(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b);

/// Rough zoom for a radius, used when moving a controller by hand.
double zoomForRadius(double meters) =>
    max(12, min(18, 17 - log(meters / 60) / ln2));
