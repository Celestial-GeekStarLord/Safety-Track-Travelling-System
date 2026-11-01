// SafeStride - guardian_screens.dart  (STEP 4 of 4)
//
// Guardian side:
//   GuardianShell  -> bottom nav: People | Zones | Alerts | History
//   People         -> "Your circle, at a glance"  (+ live Traveler detail)
//   Zones          -> safe zones list + "Make Home familiar" editor
//   Alerts         -> contextual inbox (+ "A pause worth checking" detail)
//   History        -> "The shape of today" (+ timeline & time at places)
//
// DEMO MODE (Firebase not configured): every screen runs on sample data
// (Jamie and Alex, School, Home...) and zone edits / "mark as reviewed" work in memory.
// With Firebase configured the same screens read live data through Repo (services.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import 'main.dart';
import 'services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA LAYER: one place that switches between demo data and Firestore
// ─────────────────────────────────────────────────────────────────────────────

class GD {
  static bool get demo => !backendReady;

  static String get guardianUid =>
      demo ? 'demo-guardian' : (Repo.instance.uid ?? '');

  // ── pairs
  static final List<PairInfo> demoPairs = [
    PairInfo(
      id: 'p1',
      guardianUid: 'demo-guardian',
      guardianName: 'Maya Lee',
      travelerUid: 'jamie',
      travelerName: 'Jamie Lee',
      relation: 'Your child',
    ),
    PairInfo(
      id: 'p2',
      guardianUid: 'demo-guardian',
      guardianName: 'Maya Lee',
      travelerUid: 'alex',
      travelerName: 'Alex Lee',
      relation: 'Your parent',
    ),
  ];
  static List<PairInfo> get pairsInit => demo ? demoPairs : const [];
  static Stream<List<PairInfo>> pairs() =>
      demo ? Stream.value(demoPairs) : Repo.instance.watchPairsAsGuardian();

  // ── zones (editable in demo mode too)
  static final List<SafeZone> _zones = [
    SafeZone(
      id: 'z1',
      name: 'Home',
      type: ZoneType.home,
      address: '18 Maple Avenue',
      lat: 0,
      lng: 0,
      radius: 150,
      guardianUid: 'demo-guardian',
      travelerUids: ['jamie', 'alex'],
    ),
    SafeZone(
      id: 'z2',
      name: 'School',
      type: ZoneType.school,
      address: 'Oak School, 42 Maple Ave',
      lat: 0,
      lng: 0,
      radius: 200,
      guardianUid: 'demo-guardian',
      travelerUids: ['jamie'],
    ),
    SafeZone(
      id: 'z3',
      name: 'Workplace',
      type: ZoneType.work,
      address: 'Cedar Library, 8 Cedar St',
      lat: 0,
      lng: 0,
      radius: 100,
      guardianUid: 'demo-guardian',
      travelerUids: ['jamie'],
    ),
  ];
  static final _zonesCtl = StreamController<List<SafeZone>>.broadcast();
  static List<SafeZone> get zonesInit => demo ? List.of(_zones) : const [];

  static Stream<List<SafeZone>> zones() async* {
    if (!demo) {
      yield* Repo.instance.watchZones();
      return;
    }
    yield List.of(_zones);
    yield* _zonesCtl.stream;
  }

  static Future<void> saveZone(SafeZone z) async {
    if (!demo) return Repo.instance.saveZone(z);
    final i = _zones.indexWhere((e) => e.id == z.id);
    if (i >= 0) {
      _zones[i] = z;
    } else {
      _zones.add(z);
    }
    _zonesCtl.add(List.of(_zones));
  }

  static Future<void> deleteZone(String id) async {
    if (!demo) return Repo.instance.deleteZone(id);
    _zones.removeWhere((z) => z.id == id);
    _zonesCtl.add(List.of(_zones));
  }

  static String newId() => demo
      ? 'z${DateTime.now().millisecondsSinceEpoch}'
      : Repo.instance.newId();

  // ── alerts
  static int _at(int dayOffset, int h, int m) {
    final n = DateTime.now();
    return DateTime(
      n.year,
      n.month,
      n.day + dayOffset,
      h,
      m,
    ).millisecondsSinceEpoch;
  }

  static late List<TravelerAlert> _alerts = [
    TravelerAlert(
      id: 'a1',
      guardianUid: 'demo-guardian',
      travelerUid: 'jamie',
      travelerName: 'Jamie Lee',
      kind: EventKind.unexpectedStop,
      ts: _at(0, 9, 41),
      title: 'Stopped near Willow Park for 12 min',
      body:
          'Outside familiar zones since leaving School. Willow Park Café is 18 m away.',
    ),
    TravelerAlert(
      id: 'a2',
      guardianUid: 'demo-guardian',
      travelerUid: 'jamie',
      travelerName: 'Jamie Lee',
      kind: EventKind.left,
      ts: _at(0, 9, 18),
      title: 'Jamie left School',
      body:
          'Moved beyond the 200 m School boundary. Last direction: toward Cedar Street.',
      reviewed: true,
    ),
    TravelerAlert(
      id: 'a3',
      guardianUid: 'demo-guardian',
      travelerUid: 'jamie',
      travelerName: 'Jamie Lee',
      kind: EventKind.distanceThreshold,
      ts: _at(-1, 16, 22),
      title: 'Distance threshold reached',
      body: 'More than 1 km from Home. Jamie returned at 4:48 PM.',
      reviewed: true,
    ),
  ];
  static final _alertsCtl = StreamController<List<TravelerAlert>>.broadcast();
  static List<TravelerAlert> get alertsInit =>
      demo ? List.of(_alerts) : const [];

  static Stream<List<TravelerAlert>> alerts() async* {
    if (!demo) {
      yield* Repo.instance.watchAlerts();
      return;
    }
    yield List.of(_alerts);
    yield* _alertsCtl.stream;
  }

  static Future<void> markReviewed(TravelerAlert a) async {
    if (!demo) return Repo.instance.markAlertReviewed(a.id);
    final i = _alerts.indexWhere((e) => e.id == a.id);
    if (i < 0) return;
    _alerts[i] = TravelerAlert(
      id: a.id,
      guardianUid: a.guardianUid,
      travelerUid: a.travelerUid,
      travelerName: a.travelerName,
      title: a.title,
      body: a.body,
      kind: a.kind,
      ts: a.ts,
      reviewed: true,
    );
    _alertsCtl.add(List.of(_alerts));
  }

  // ── live data
  static LocationPoint? demoPoint(PairInfo p) => LocationPoint(
    id: 'd',
    lat: 0,
    lng: 0,
    accuracy: 8,
    speed: 0,
    ts:
        DateTime.now().millisecondsSinceEpoch -
        (p.travelerUid == 'alex' ? 60000 : 0),
    battery: p.travelerUid == 'alex' ? 86 : 72,
  );
  static DeviceStatus demoStatus(PairInfo p) => DeviceStatus(
    battery: p.travelerUid == 'alex' ? 86 : 72,
    online: true,
    gpsAccuracy: 8,
  );

  // ── history
  static Stream<List<JourneyEvent>> events(
    PairInfo p,
    DateTime from,
    DateTime to,
  ) => demo
      ? Stream.value(_demoEvents(p))
      : Repo.instance.watchEvents(p.travelerUid, from, to);

  static Stream<List<LocationPoint>> points(
    PairInfo p,
    DateTime from,
    DateTime to,
  ) => demo
      ? Stream.value(const <LocationPoint>[])
      : Repo.instance.watchPoints(p.travelerUid, from, to);

  static JourneyEvent _ev(
    String uid,
    EventKind k,
    int h,
    int m,
    String zoneId,
    String zone, {
    int dwell = 0,
    bool alert = false,
    String title = '',
    String body = '',
  }) => JourneyEvent(
    id: '$uid$h$m',
    kind: k,
    travelerUid: uid,
    travelerName: uid,
    zoneId: zoneId,
    zoneName: zone,
    lat: 0,
    lng: 0,
    ts: _at(0, h, m),
    dwellMinutes: dwell,
    alert: alert,
    title: title,
    body: body,
  );

  static List<JourneyEvent> _demoEvents(PairInfo p) {
    if (p.travelerUid != 'jamie') {
      return [
        _ev(
          'alex',
          EventKind.arrived,
          8,
          30,
          'z1',
          'Home',
          title: 'Arrived at Home',
        ),
      ];
    }
    return [
      _ev(
        'jamie',
        EventKind.arrived,
        8,
        0,
        'z1',
        'Home',
        title: 'Arrived at Home',
      ),
      _ev(
        'jamie',
        EventKind.left,
        8,
        55,
        'z1',
        'Home',
        dwell: 55,
        title: 'Left Home',
      ),
      _ev(
        'jamie',
        EventKind.arrived,
        9,
        5,
        'z2',
        'School',
        title: 'Arrived at School',
      ),
      _ev(
        'jamie',
        EventKind.left,
        9,
        18,
        'z2',
        'School',
        dwell: 13,
        alert: true,
        title: 'Left School',
      ),
      _ev(
        'jamie',
        EventKind.unexpectedStop,
        9,
        29,
        '',
        '',
        dwell: 12,
        alert: true,
        title: 'Unexpected pause',
      ),
    ];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SMALL HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/// Creates its stream once (so rebuilds don't resubscribe) and rebuilds on every event.
class Src<T> extends StatefulWidget {
  final Stream<T> Function() create;
  final T initial;
  final Widget Function(BuildContext, T) builder;
  const Src({
    super.key,
    required this.create,
    required this.initial,
    required this.builder,
  });
  @override
  State<Src<T>> createState() => _SrcState<T>();
}

class _SrcState<T> extends State<Src<T>> {
  late final Stream<T> _s = widget.create();
  @override
  Widget build(BuildContext context) => StreamBuilder<T>(
    stream: _s,
    initialData: widget.initial,
    builder: (c, snap) =>
        widget.builder(c, snap.hasData ? snap.data as T : widget.initial),
  );
}

/// Live point + device status for one Traveler.
class LiveBuilder extends StatefulWidget {
  final PairInfo pair;
  final Widget Function(BuildContext, LocationPoint?, DeviceStatus?) builder;
  const LiveBuilder({super.key, required this.pair, required this.builder});
  @override
  State<LiveBuilder> createState() => _LiveBuilderState();
}

class _LiveBuilderState extends State<LiveBuilder> {
  late final Stream<LocationPoint?>? _live = GD.demo
      ? null
      : Repo.instance.watchLive(widget.pair.travelerUid);
  late final Stream<DeviceStatus?>? _status = GD.demo
      ? null
      : Repo.instance.watchStatus(widget.pair.travelerUid);

  @override
  Widget build(BuildContext context) {
    if (GD.demo) {
      return widget.builder(
        context,
        GD.demoPoint(widget.pair),
        GD.demoStatus(widget.pair),
      );
    }
    return StreamBuilder<LocationPoint?>(
      stream: _live,
      builder: (c, a) => StreamBuilder<DeviceStatus?>(
        stream: _status,
        builder: (c, b) => widget.builder(c, a.data, b.data),
      ),
    );
  }
}

/// Resolves a place name for a point once per ~100 m.
class PlaceName extends StatefulWidget {
  final LocationPoint? point;
  final String demoText;
  final String prefix;
  final TextStyle style;
  final String fallback;
  const PlaceName({
    super.key,
    required this.point,
    required this.style,
    this.demoText = 'Willow Park Café',
    this.prefix = '',
    this.fallback = 'an unfamiliar place',
  });
  @override
  State<PlaceName> createState() => _PlaceNameState();
}

class _PlaceNameState extends State<PlaceName> {
  String? _name;
  String? _key;

  void _resolve() {
    final p = widget.point;
    if (p == null || GD.demo) return;
    final k = '${p.lat.toStringAsFixed(3)},${p.lng.toStringAsFixed(3)}';
    if (k == _key) return;
    _key = k;
    reverseGeocode(p.lat, p.lng).then((n) {
      if (mounted && n != null) setState(() => _name = n);
    });
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant PlaceName old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  @override
  Widget build(BuildContext context) {
    final n = GD.demo ? widget.demoText : (_name ?? widget.fallback);
    return Text('${widget.prefix}$n', style: widget.style);
  }
}

class GSeg extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  const GSeg({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFE9E7DD),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == index ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  labels[i],
                  style: ssBody(
                    bold: i == index,
                    size: 13,
                    color: i == index ? SS.teal : SS.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

Widget _tile(IconData i, {Color bg = SS.mint, Color fg = SS.teal}) => Container(
  width: 38,
  height: 38,
  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
  child: Icon(i, size: 19, color: fg),
);

String _first(String n) => n.split(' ').first;
String _initials(String n) =>
    n.split(' ').where((w) => w.isNotEmpty).map((w) => w[0]).take(2).join();

String _ago(int? ts) {
  if (ts == null) return 'not yet';
  final m = ((DateTime.now().millisecondsSinceEpoch - ts) / 60000).round();
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  return '${m ~/ 60} h ago';
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _dayLabel(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

IconData _zoneIcon(ZoneType t) => switch (t) {
  ZoneType.home => Icons.home_outlined,
  ZoneType.school => Icons.school_outlined,
  ZoneType.work => Icons.work_outline,
  ZoneType.other => Icons.place_outlined,
};

ZoneType _guessType(String name) {
  final n = name.toLowerCase();
  if (n.contains('home') || n.contains('house')) return ZoneType.home;
  if (n.contains('school') || n.contains('college')) return ZoneType.school;
  if (n.contains('work') || n.contains('office') || n.contains('library'))
    return ZoneType.work;
  return ZoneType.other;
}

// ─────────────────────────────────────────────────────────────────────────────
// SHELL with in-shell navigation (keeps the bottom nav visible on detail pages)
// ─────────────────────────────────────────────────────────────────────────────

class GShell extends InheritedWidget {
  final Widget nav;
  final void Function(Widget page, {int? tab}) push;
  final VoidCallback pop;
  final ValueChanged<int> goTab;
  const GShell({
    super.key,
    required this.nav,
    required this.push,
    required this.pop,
    required this.goTab,
    required super.child,
  });

  static GShell of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<GShell>()!;

  @override
  bool updateShouldNotify(GShell old) => true;
}

class _Entry {
  final Widget page;
  final int prevTab;
  _Entry(this.page, this.prevTab);
}

class GuardianShell extends StatefulWidget {
  const GuardianShell({super.key});
  @override
  State<GuardianShell> createState() => _GuardianShellState();
}

class _GuardianShellState extends State<GuardianShell> {
  int _tab = 0;
  final List<_Entry> _stack = [];

  void _goTab(int i) => setState(() {
    _stack.clear();
    _tab = i;
  });

  void _push(Widget page, {int? tab}) => setState(() {
    _stack.add(_Entry(page, _tab));
    if (tab != null) _tab = tab;
  });

  void _pop() {
    if (_stack.isEmpty) return;
    setState(() {
      _tab = _stack.removeLast().prevTab;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = SSBottomNav(
      index: _tab,
      onTap: _goTab,
      items: const [
        (Icons.people_outline, 'People'),
        (Icons.location_on_outlined, 'Zones'),
        (Icons.notifications_none, 'Alerts'),
        (Icons.timeline, 'History'),
      ],
    );
    final Widget body = _stack.isNotEmpty
        ? _stack.last.page
        : switch (_tab) {
            0 => const PeopleScreen(),
            1 => const ZonesScreen(),
            2 => const AlertsScreen(),
            _ => const HistoryScreen(),
          };

    return PopScope(
      canPop: _stack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: GShell(
        nav: nav,
        push: _push,
        pop: _pop,
        goTab: _goTab,
        child: KeyedSubtree(
          key: ValueKey('$_tab-${_stack.length}'),
          child: body,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. PEOPLE OVERVIEW
// ─────────────────────────────────────────────────────────────────────────────

class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    final app = context.watch<AppState>();
    return SSScaffold(
      trailing: 'Guardian',
      showBack: false,
      bottom: shell.nav,
      children: [
        Src<List<PairInfo>>(
          create: GD.pairs,
          initial: GD.pairsInit,
          builder: (c, pairs) => Src<List<SafeZone>>(
            create: GD.zones,
            initial: GD.zonesInit,
            builder: (c, zones) => Src<List<TravelerAlert>>(
              create: GD.alerts,
              initial: GD.alertsInit,
              builder: (c, alerts) {
                final hour = DateTime.now().hour;
                final greet = hour < 12
                    ? 'Good morning'
                    : (hour < 18 ? 'Good afternoon' : 'Good evening');
                final urgent = alerts
                    .where(
                      (a) => !a.reviewed && a.kind == EventKind.unexpectedStop,
                    )
                    .toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SSHeader(
                      eyebrow: '$greet, ${_first(app.displayName)}',
                      title: 'Your circle, at a glance',
                      subtitle: pairs.isEmpty
                          ? 'No Travelers yet. Invite someone to get started.'
                          : '${pairs.length} ${pairs.length == 1 ? 'Traveler' : 'Travelers'}. A little peace of mind.',
                    ),
                    if (urgent.isNotEmpty)
                      SSCard(
                        color: SS.amber,
                        onTap: () => shell.push(
                          AlertDetail(alert: urgent.first),
                          tab: 2,
                        ),
                        child: Row(
                          children: [
                            _tile(
                              Icons.coffee_outlined,
                              bg: Colors.white.withAlpha(150),
                              fg: SS.amberText,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_first(urgent.first.travelerName)} has stopped for a while',
                                    style: ssBody(bold: true, size: 14.5),
                                  ),
                                  Text(
                                    'Outside familiar zones · ${fmtTime(urgent.first.ts)}',
                                    style: ssBody(
                                      size: 12,
                                      color: SS.amberText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              'View ›',
                              style: ssBody(
                                bold: true,
                                size: 13,
                                color: SS.amberText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (final p in pairs) _TravelerCard(pair: p, zones: zones),
                    SSButton(
                      'Pair another Traveler',
                      icon: Icons.person_add_alt_1_outlined,
                      filled: false,
                      onPressed: () => Navigator.pushNamed(context, '/invite'),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(
                        "Locations are shared with each Traveler's consent.",
                        style: ssBody(size: 11.5, color: SS.muted),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

String? _zoneAt(PairInfo pair, LocationPoint? p, List<SafeZone> zones) {
  if (GD.demo) return pair.travelerUid == 'alex' ? 'Home' : null;
  if (p == null) return null;
  for (final z in zones) {
    if (z.travelerUids.contains(pair.travelerUid) &&
        distanceM(p.lat, p.lng, z.lat, z.lng) <= z.radius) {
      return z.name;
    }
  }
  return null;
}

class _TravelerCard extends StatelessWidget {
  final PairInfo pair;
  final List<SafeZone> zones;
  const _TravelerCard({required this.pair, required this.zones});

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    return LiveBuilder(
      pair: pair,
      builder: (c, p, s) {
        final online = s?.online ?? true;
        final atZone = _zoneAt(pair, p, zones);
        final battery = (s?.battery ?? p?.battery ?? -1);
        final batteryTxt = battery < 0 ? '—' : '$battery%';
        return SSCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: SS.mint,
                    child: Text(
                      _initials(pair.travelerName),
                      style: ssBody(bold: true, color: SS.teal, size: 13),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pair.travelerName,
                          style: ssBody(bold: true, size: 16),
                        ),
                        if (pair.relation.isNotEmpty)
                          Text(
                            pair.relation,
                            style: ssBody(size: 12.5, color: SS.muted),
                          ),
                      ],
                    ),
                  ),
                  if (pair.sharingPaused)
                    const SSPill('Paused', bg: SS.amber, fg: SS.amberText)
                  else
                    online
                        ? const SSPill('Live')
                        : const SSPill(
                            'Offline',
                            bg: SS.amber,
                            fg: SS.amberText,
                          ),
                ],
              ),
              const SizedBox(height: 12),
              if (atZone == null) ...[
                MiniMap(
                  height: 130,
                  showRoute: true,
                  initials: _initials(pair.travelerName),
                  markerFaded: !online,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PlaceName(
                            point: p,
                            prefix: 'Near ',
                            style: ssBody(bold: true, size: 14.5),
                          ),
                          Text(
                            online
                                ? '${_ago(p?.ts)} · ${p == null ? '' : fmtTime(p.ts)}'
                                : 'Last known ${_ago(p?.ts)}',
                            style: ssBody(size: 12, color: SS.muted),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      batteryTxt,
                      style: ssBody(bold: true, size: 14, color: SS.teal),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    _tile(_zoneIcon(_guessType(atZone))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'At $atZone',
                            style: ssBody(bold: true, size: 14.5),
                          ),
                          Text(
                            'Updated ${_ago(p?.ts)}${p == null ? '' : ' · ${fmtTime(p.ts)}'}',
                            style: ssBody(size: 12, color: SS.muted),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      batteryTxt,
                      style: ssBody(bold: true, size: 14, color: SS.teal),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Familiar-zone arrival saved to history. No alert sent.',
                  style: ssBody(size: 11.5, color: SS.muted),
                ),
              ],
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: () => shell.push(
                    TravelerDetail(pair: pair, zones: zones),
                    tab: 0,
                  ),
                  child: Text(
                    'View location & device →',
                    style: ssBody(bold: true, size: 13, color: SS.teal),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1b. LIVE TRAVELER DETAIL
// ─────────────────────────────────────────────────────────────────────────────

class TravelerDetail extends StatelessWidget {
  final PairInfo pair;
  final List<SafeZone> zones;
  const TravelerDetail({super.key, required this.pair, required this.zones});

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    final name = _first(pair.travelerName);
    return LiveBuilder(
      pair: pair,
      builder: (c, p, s) {
        final online = s?.online ?? true;
        final battery = s?.battery ?? p?.battery ?? -1;
        final acc = s?.gpsAccuracy ?? p?.accuracy ?? -1;
        final atZone = _zoneAt(pair, p, zones);
        return SSScaffold(
          trailing: 'Guardian',
          onBack: shell.pop,
          bottom: shell.nav,
          children: [
            Text(pair.travelerName.toUpperCase(), style: ssEyebrow()),
            const SizedBox(height: 6),
            atZone != null
                ? Text('At $atZone', style: ssHeadline())
                : PlaceName(point: p, prefix: 'Near ', style: ssHeadline()),
            const SizedBox(height: 10),
            Row(
              children: [
                online
                    ? const SSPill('Live · just now')
                    : const SSPill(
                        'Offline · last known',
                        bg: SS.amber,
                        fg: SS.amberText,
                      ),
                const Spacer(),
                Text(
                  p == null ? '' : fmtTime(p.ts),
                  style: ssBody(size: 12.5, color: SS.muted),
                ),
              ],
            ),
            const SizedBox(height: 14),
            MiniMap(
              height: 190,
              showRoute: atZone == null,
              initials: _initials(pair.travelerName),
              markerFaded: !online,
            ),
            const SizedBox(height: 10),
            SSCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _tile(Icons.navigation_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PlaceName(
                              point: p,
                              demoText: '214 Cedar Street',
                              style: ssBody(bold: true, size: 15),
                              fallback: 'Location updating…',
                            ),
                            Text(
                              acc < 0
                                  ? 'Waiting for GPS'
                                  : 'Accurate to ±${acc.round()} m',
                              style: ssBody(size: 12, color: SS.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22, color: SS.line),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        battery < 0 ? '— battery' : '$battery% battery',
                        style: ssBody(bold: true, size: 13),
                      ),
                      Text(
                        online ? 'Connected' : 'Offline',
                        style: ssBody(
                          bold: true,
                          size: 13,
                          color: online ? SS.teal : SS.amberText,
                        ),
                      ),
                      Text(
                        acc < 0 ? 'No GPS' : 'GPS locked',
                        style: ssBody(bold: true, size: 13),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Src<List<TravelerAlert>>(
              create: GD.alerts,
              initial: GD.alertsInit,
              builder: (c, alerts) {
                final stop = alerts
                    .where(
                      (a) =>
                          a.travelerUid == pair.travelerUid &&
                          a.kind == EventKind.unexpectedStop &&
                          !a.reviewed,
                    )
                    .toList();
                if (stop.isEmpty) return const SizedBox.shrink();
                final mins = GD.demo
                    ? 12
                    : ((DateTime.now().millisecondsSinceEpoch - stop.first.ts) /
                                  60000)
                              .round() +
                          10;
                return SSCard(
                  color: SS.amber,
                  onTap: () =>
                      shell.push(AlertDetail(alert: stop.first), tab: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _tile(
                            Icons.coffee_outlined,
                            bg: Colors.white.withAlpha(150),
                            fg: SS.amberText,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Stopped for $mins minutes',
                                  style: ssBody(bold: true, size: 15),
                                ),
                                Text(
                                  'Since ${fmtTime(stop.first.ts - 10 * 60000)} · Outside familiar zones',
                                  style: ssBody(size: 12, color: SS.amberText),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            'View ›',
                            style: ssBody(
                              bold: true,
                              size: 13,
                              color: SS.amberText,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20, color: Color(0x33000000)),
                      Text(
                        'Check in if this stop was not expected.',
                        style: ssBody(size: 12.5, color: SS.amberText),
                      ),
                    ],
                  ),
                );
              },
            ),
            Row(
              children: [
                Expanded(
                  child: SSButton(
                    'Call $name',
                    icon: Icons.call_outlined,
                    onPressed: () => _soon(context, 'Calling'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SSButton(
                    'Directions',
                    icon: Icons.navigation_outlined,
                    filled: false,
                    onPressed: () => _soon(context, 'Directions'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                "Only $name's shared information is shown. Updates slow down when the device is still to save battery.",
                textAlign: TextAlign.center,
                style: ssBody(size: 11.5, color: SS.muted),
              ),
            ),
          ],
        );
      },
    );
  }
}

void _soon(BuildContext c, String what) => ssToast(
  c,
  '$what needs the url_launcher package and the Traveler\'s phone number. Add them when you are ready.',
);

// ─────────────────────────────────────────────────────────────────────────────
// 2. SAFE ZONES
// ─────────────────────────────────────────────────────────────────────────────

class ZonesScreen extends StatefulWidget {
  const ZonesScreen({super.key});
  @override
  State<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends State<ZonesScreen> {
  int _filter = 0; // 0 = all, 1.. = a Traveler

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    return SSScaffold(
      trailing: 'Guardian',
      showBack: false,
      bottom: shell.nav,
      children: [
        Src<List<PairInfo>>(
          create: GD.pairs,
          initial: GD.pairsInit,
          builder: (c, pairs) => Src<List<SafeZone>>(
            create: GD.zones,
            initial: GD.zonesInit,
            builder: (c, zones) {
              if (_filter > pairs.length) _filter = 0;
              final who = _filter == 0 ? null : pairs[_filter - 1];
              final shown = zones
                  .where(
                    (z) =>
                        who == null || z.travelerUids.contains(who.travelerUid),
                  )
                  .toList();
              String names(SafeZone z) {
                final n = pairs
                    .where((p) => z.travelerUids.contains(p.travelerUid))
                    .map((p) => _first(p.travelerName))
                    .toList();
                return n.isEmpty ? 'No Travelers' : n.join(' & ');
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SSHeader(
                    eyebrow: 'Familiar places',
                    title: 'Safe zones',
                    subtitle:
                        'Give everyday places a little context, so only meaningful changes need your attention.',
                  ),
                  GSeg(
                    labels: [
                      'All Travelers',
                      ...pairs.map((p) => _first(p.travelerName)),
                    ],
                    index: _filter,
                    onChanged: (i) => setState(() => _filter = i),
                  ),
                  const SizedBox(height: 12),
                  if (shown.isEmpty)
                    const SSInfo(
                      icon: Icons.add_location_alt_outlined,
                      title: 'No safe zones yet',
                      body:
                          'Add Home, School or Work so routine arrivals stay quiet and boundary crossings stand out.',
                    ),
                  for (final z in shown)
                    SSCard(
                      onTap: () => shell.push(ZoneEditor(zone: z), tab: 1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _tile(_zoneIcon(z.type)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      z.name,
                                      style: ssBody(bold: true, size: 15.5),
                                    ),
                                    Text(
                                      '${z.address.isEmpty ? 'Custom location' : z.address} · ${z.radius.round()} m radius',
                                      style: ssBody(size: 12, color: SS.muted),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                'Edit ›',
                                style: ssBody(
                                  bold: true,
                                  size: 13,
                                  color: SS.teal,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 20, color: SS.line),
                          Text(
                            '${names(z)} · ${z.quietStays ? 'Familiar zone' : 'Alerts on arrival'}',
                            style: ssBody(size: 12, color: SS.muted),
                          ),
                        ],
                      ),
                    ),
                  const SSInfo(
                    icon: Icons.notifications_off_outlined,
                    title: 'Familiar stays stay quiet',
                    body:
                        'Arrivals and dwell time are saved to history, without routine push notifications.\n\nLeaving a boundary can still alert you, based on each zone\'s settings.',
                  ),
                  SSButton(
                    'Add a safe zone',
                    icon: Icons.add,
                    onPressed: () => shell.push(const ZoneEditor(), tab: 1),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2b. ZONE EDITOR
// ─────────────────────────────────────────────────────────────────────────────

class ZoneEditor extends StatefulWidget {
  final SafeZone? zone;
  const ZoneEditor({super.key, this.zone});
  @override
  State<ZoneEditor> createState() => _ZoneEditorState();
}

class _ZoneEditorState extends State<ZoneEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.zone?.name ?? '',
  );
  late double _radius = widget.zone?.radius ?? 150;
  late bool _quiet = widget.zone?.quietStays ?? true;
  late bool _notify = widget.zone?.notifyLeaving ?? true;
  late final Set<String> _who = {
    ...(widget.zone?.travelerUids ?? const <String>[]),
  };
  late double _lat = widget.zone?.lat ?? 0;
  late double _lng = widget.zone?.lng ?? 0;
  late String _address = widget.zone?.address ?? '';
  bool _locating = false;
  bool _initWho = false;

  bool get _isNew => widget.zone == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) _useHere();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _useHere() async {
    if (GD.demo) return;
    setState(() => _locating = true);
    try {
      final pos = await Geolocator.getCurrentPosition();
      _lat = pos.latitude;
      _lng = pos.longitude;
      final n = await reverseGeocode(_lat, _lng);
      if (n != null) _address = n;
    } catch (_) {
      if (mounted)
        ssToast(
          context,
          "Couldn't read this phone's location. Check location permission.",
        );
    }
    if (mounted) setState(() => _locating = false);
  }

  Future<void> _save() async {
    final shell = GShell.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      ssToast(context, 'Give this place a name.');
      return;
    }
    if (_who.isEmpty) {
      ssToast(context, 'Choose at least one Traveler.');
      return;
    }
    final z = SafeZone(
      id: widget.zone?.id ?? GD.newId(),
      name: name,
      type: widget.zone?.type ?? _guessType(name),
      address: _address,
      lat: _lat,
      lng: _lng,
      radius: _radius,
      quietStays: _quiet,
      notifyLeaving: _notify,
      guardianUid: GD.guardianUid,
      travelerUids: _who.toList(),
    );
    await GD.saveZone(z);
    shell.pop();
  }

  Future<void> _delete() async {
    final shell = GShell.of(context);
    await GD.deleteZone(widget.zone!.id);
    shell.pop();
  }

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    final nm = _name.text.trim();
    return SSScaffold(
      trailing: 'Guardian',
      onBack: shell.pop,
      bottom: shell.nav,
      children: [
        Src<List<PairInfo>>(
          create: GD.pairs,
          initial: GD.pairsInit,
          builder: (c, pairs) {
            if (_isNew && !_initWho && pairs.isNotEmpty) {
              _initWho = true;
              _who.add(pairs.first.travelerUid);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SSHeader(
                  eyebrow:
                      'Safe zone · ${pairs.where((p) => _who.contains(p.travelerUid)).map((p) => _first(p.travelerName)).join(' & ')}',
                  title: nm.isEmpty
                      ? 'Make a place familiar'
                      : 'Make $nm familiar',
                ),
                Text('Zone name', style: ssBody(bold: true, size: 12.5)),
                const SizedBox(height: 6),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() {}),
                  style: ssBody(size: 15),
                  decoration: InputDecoration(
                    hintText: 'Home, School, Grandma\'s house…',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: SS.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: SS.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: SS.teal, width: 1.6),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                MiniMap(
                  height: 170,
                  showZone: true,
                  initials: nm.isEmpty ? '·' : nm[0].toUpperCase(),
                  zoneRadius: 18 + (_radius - 50) / 950 * 62,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _address.isEmpty
                            ? (_locating
                                  ? 'Finding this place…'
                                  : 'Location set from this phone')
                            : _address,
                        style: ssBody(bold: true, size: 13.5),
                      ),
                    ),
                    TextButton(
                      onPressed: _locating
                          ? null
                          : () async {
                              if (GD.demo) {
                                ssToast(
                                  context,
                                  'Demo mode uses a sample location.',
                                );
                              } else {
                                await _useHere();
                              }
                            },
                      child: Text(
                        'Use my location',
                        style: ssBody(bold: true, size: 12.5, color: SS.teal),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text('Zone radius', style: ssBody(bold: true, size: 14)),
                    const Spacer(),
                    Text(
                      '${_radius.round()} m',
                      style: ssBody(bold: true, size: 14, color: SS.teal),
                    ),
                  ],
                ),
                Slider(
                  value: _radius,
                  min: 50,
                  max: 1000,
                  divisions: 19,
                  activeColor: SS.teal,
                  onChanged: (v) => setState(() => _radius = v),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('50 m', style: ssBody(size: 11.5, color: SS.muted)),
                    Text('1,000 m', style: ssBody(size: 11.5, color: SS.muted)),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Applies to', style: ssBody(bold: true, size: 12.5)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in pairs)
                      FilterChip(
                        label: Text(_first(p.travelerName)),
                        selected: _who.contains(p.travelerUid),
                        selectedColor: SS.mint,
                        checkmarkColor: SS.teal,
                        backgroundColor: Colors.white,
                        labelStyle: ssBody(bold: true, size: 13, color: SS.ink),
                        onSelected: (v) => setState(
                          () => v
                              ? _who.add(p.travelerUid)
                              : _who.remove(p.travelerUid),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SSCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      _switchRow(
                        'Quiet arrivals & stays',
                        'Save visits and dwell time to history. No routine push notifications.',
                        _quiet,
                        (v) => setState(() => _quiet = v),
                      ),
                      const Divider(height: 1, color: SS.line),
                      _switchRow(
                        'Notify when leaving',
                        'Alert after crossing the ${_radius.round()} m boundary.',
                        _notify,
                        (v) => setState(() => _notify = v),
                      ),
                    ],
                  ),
                ),
                SSButton(
                  _isNew
                      ? 'Save zone'
                      : 'Save ${nm.isEmpty ? 'zone' : nm} zone',
                  onPressed: _save,
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Radius helps allow for small GPS variations around familiar places.',
                    textAlign: TextAlign.center,
                    style: ssBody(size: 11.5, color: SS.muted),
                  ),
                ),
                if (!_isNew)
                  Center(
                    child: TextButton(
                      onPressed: _delete,
                      child: Text(
                        'Delete this zone',
                        style: ssBody(bold: true, color: SS.amberText),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _switchRow(String t, String sub, bool v, ValueChanged<bool> on) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t, style: ssBody(bold: true, size: 14.5)),
                  Text(sub, style: ssBody(size: 12, color: SS.muted)),
                ],
              ),
            ),
            Switch(value: v, onChanged: on),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. ALERTS INBOX
// ─────────────────────────────────────────────────────────────────────────────

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  int _tab = 0;

  IconData _icon(EventKind k) => switch (k) {
    EventKind.unexpectedStop => Icons.coffee_outlined,
    EventKind.left => Icons.logout,
    EventKind.distanceThreshold => Icons.straighten,
    EventKind.arrived => Icons.login,
  };

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    return SSScaffold(
      trailing: 'Guardian',
      showBack: false,
      bottom: shell.nav,
      children: [
        const SSHeader(eyebrow: 'Meaningful updates only', title: 'Alerts'),
        GSeg(
          labels: const ['Needs attention', 'All updates'],
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 14),
        Src<List<TravelerAlert>>(
          create: GD.alerts,
          initial: GD.alertsInit,
          builder: (c, all) {
            final now = DateTime.now();
            final cutoff = now
                .subtract(const Duration(hours: 48))
                .millisecondsSinceEpoch;
            final list =
                (_tab == 0
                        ? all.where((a) => !a.reviewed || a.ts >= cutoff)
                        : all)
                    .toList()
                  ..sort((a, b) => b.ts.compareTo(a.ts));
            final today = list
                .where(
                  (a) =>
                      _sameDay(DateTime.fromMillisecondsSinceEpoch(a.ts), now),
                )
                .toList();
            final earlier = list
                .where(
                  (a) =>
                      !_sameDay(DateTime.fromMillisecondsSinceEpoch(a.ts), now),
                )
                .toList();
            final fresh = today.where((a) => !a.reviewed).length;

            Widget card(TravelerAlert a) {
              final isNew = !a.reviewed;
              return SSCard(
                color: isNew ? SS.amber : SS.surface,
                onTap: () => shell.push(AlertDetail(alert: a), tab: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _tile(
                          _icon(a.kind),
                          bg: isNew ? Colors.white.withAlpha(150) : SS.mint,
                          fg: isNew ? SS.amberText : SS.teal,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a.kind == EventKind.unexpectedStop
                                    ? 'An unexpected pause'
                                    : a.title,
                                style: ssBody(bold: true, size: 14.5),
                              ),
                              Text(
                                '${a.travelerName} · ${fmtTime(a.ts)}',
                                style: ssBody(size: 12, color: SS.muted),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          isNew ? 'New' : 'Seen',
                          style: ssBody(
                            bold: true,
                            size: 12.5,
                            color: isNew ? SS.amberText : SS.teal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (a.kind == EventKind.unexpectedStop)
                      Text(a.title, style: ssBody(bold: true, size: 15)),
                    Text(
                      a.body,
                      style: ssBody(
                        size: 12.5,
                        color: isNew ? SS.amberText : SS.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isNew ? 'Review & check in →' : 'View details →',
                      style: ssBody(
                        bold: true,
                        size: 13,
                        color: isNew ? SS.amberText : SS.teal,
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (list.isEmpty)
                  const SSInfo(
                    icon: Icons.check_circle_outline,
                    title: 'All quiet',
                    body: 'Nothing needs your attention right now.',
                  ),
                if (today.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Text(
                          'Today · ${_dayLabel(now)}',
                          style: ssBody(
                            bold: true,
                            size: 12.5,
                            color: SS.muted,
                          ),
                        ),
                        const Spacer(),
                        if (fresh > 0)
                          SSPill('$fresh new', bg: SS.amber, fg: SS.amberText),
                      ],
                    ),
                  ),
                for (final a in today) card(a),
                if (earlier.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Text(
                      'Earlier',
                      style: ssBody(bold: true, size: 12.5, color: SS.muted),
                    ),
                  ),
                for (final a in earlier) card(a),
                const SSInfo(
                  icon: Icons.notifications_off_outlined,
                  title: 'Not everything needs an alert',
                  body:
                      'Home arrivals and familiar-zone stays are recorded quietly. Find them in History.',
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3b. ALERT DETAIL ("A pause worth checking")
// ─────────────────────────────────────────────────────────────────────────────

class AlertDetail extends StatelessWidget {
  final TravelerAlert alert;
  const AlertDetail({super.key, required this.alert});

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    final a = alert;
    final name = _first(a.travelerName);
    final d = DateTime.fromMillisecondsSinceEpoch(a.ts);
    final isToday = _sameDay(d, DateTime.now());
    final title = switch (a.kind) {
      EventKind.unexpectedStop => 'A pause worth checking',
      EventKind.left => 'A boundary was crossed',
      EventKind.distanceThreshold => 'Farther than usual',
      EventKind.arrived => 'An arrival',
    };
    final pill = switch (a.kind) {
      EventKind.unexpectedStop => 'Unexpected stop',
      EventKind.left => 'Left a safe zone',
      EventKind.distanceThreshold => 'Distance threshold',
      EventKind.arrived => 'Arrival',
    };
    final pair = GD.pairsInit
        .where((p) => p.travelerUid == a.travelerUid)
        .toList();

    return SSScaffold(
      trailing: 'Guardian',
      onBack: shell.pop,
      bottom: shell.nav,
      children: [
        Text(
          '${a.travelerName.toUpperCase()} · ${isToday ? 'TODAY' : _dayLabel(d).toUpperCase()}, ${fmtTime(a.ts).toUpperCase()}',
          style: ssEyebrow(),
        ),
        const SizedBox(height: 6),
        Text(title, style: ssHeadline()),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            SSPill(
              a.reviewed ? '$pill · Reviewed' : '$pill · Needs review',
              bg: a.reviewed ? SS.mint : SS.amber,
              fg: a.reviewed ? SS.teal : SS.amberText,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Stack(
          children: [
            MiniMap(
              height: 190,
              showRoute: true,
              initials: _initials(a.travelerName),
            ),
            if (a.kind == EventKind.unexpectedStop)
              Positioned(
                left: 14,
                top: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: SS.amber,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Stopped',
                    style: ssBody(bold: true, size: 11, color: SS.amberText),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SSCard(
          color: SS.amber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.kind == EventKind.unexpectedStop
                    ? 'No movement for a while'
                    : a.title,
                style: ssBody(bold: true, size: 16),
              ),
              const SizedBox(height: 4),
              Text(a.body, style: ssBody(size: 13, color: SS.amberText)),
            ],
          ),
        ),
        SSCard(
          child: Column(
            children: [
              Row(
                children: [
                  _tile(Icons.route_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'What led here',
                          style: ssBody(bold: true, size: 14.5),
                        ),
                        Text(
                          '${fmtTime(a.ts)} · ${a.title}',
                          style: ssBody(size: 12, color: SS.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 22, color: SS.line),
              LiveBuilder(
                pair: pair.isNotEmpty
                    ? pair.first
                    : PairInfo(
                        id: 'x',
                        guardianUid: a.guardianUid,
                        guardianName: '',
                        travelerUid: a.travelerUid,
                        travelerName: a.travelerName,
                      ),
                builder: (c, p, s) => Row(
                  children: [
                    _tile(Icons.my_location),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (s?.online ?? true)
                                ? 'Location is live · ${_ago(p?.ts)}'
                                : 'Offline · last known ${_ago(p?.ts)}',
                            style: ssBody(bold: true, size: 14),
                          ),
                          Text(
                            '${p == null ? '' : '${fmtTime(p.ts)} · '}GPS ${(s?.gpsAccuracy ?? -1) < 0 ? 'searching' : '±${s!.gpsAccuracy.round()} m'} · ${(s?.battery ?? -1) < 0 ? '—' : '${s!.battery}%'} battery',
                            style: ssBody(size: 12, color: SS.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: SSButton(
                'Call $name',
                icon: Icons.call_outlined,
                onPressed: () => _soon(context, 'Calling'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SSButton(
                'Directions',
                icon: Icons.navigation_outlined,
                filled: false,
                onPressed: () => _soon(context, 'Directions'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SSButton(
          a.reviewed ? 'Reviewed' : 'Mark as reviewed',
          icon: Icons.check,
          filled: false,
          onPressed: a.reviewed
              ? null
              : () async {
                  await GD.markReviewed(a);
                  shell.pop();
                },
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'A pause can be part of a normal day. This alert is a prompt to check in, not confirmation of an emergency.',
            textAlign: TextAlign.center,
            style: ssBody(size: 11.5, color: SS.muted),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. HISTORY ("The shape of today")
// ─────────────────────────────────────────────────────────────────────────────

class DayStats {
  final double km;
  final int movingMin;
  final int stops;
  final String route;
  const DayStats(this.km, this.movingMin, this.stops, this.route);
}

DayStats computeStats(List<LocationPoint> pts, List<JourneyEvent> evs) {
  double meters = 0;
  double movingSec = 0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final dt = (b.ts - a.ts) / 1000;
    if (dt <= 0 || dt > 600 || b.accuracy > 100)
      continue; // skip gaps and poor fixes
    final d = distanceM(a.lat, a.lng, b.lat, b.lng);
    if (d / dt > 0.5 && d > 8) {
      meters += d;
      movingSec += dt;
    }
  }
  final sorted = [...evs]..sort((a, b) => a.ts.compareTo(b.ts));
  final stops = sorted
      .where(
        (e) =>
            e.kind == EventKind.arrived || e.kind == EventKind.unexpectedStop,
      )
      .length;
  final names = <String>[];
  for (final e in sorted) {
    final n = e.kind == EventKind.unexpectedStop
        ? 'Unplanned stop'
        : (e.kind == EventKind.arrived ? e.zoneName : null);
    if (n != null && n.isNotEmpty && (names.isEmpty || names.last != n))
      names.add(n);
  }
  return DayStats(
    meters / 1000,
    (movingSec / 60).round(),
    stops,
    names.isEmpty ? 'No journeys recorded yet' : names.join(' → '),
  );
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _who = 0;
  int _range = 0; // 0 today/selected day, 1 past week, 2 last month
  DateTime _day = DateTime.now();

  (DateTime, DateTime) _window() {
    final dayStart = DateTime(_day.year, _day.month, _day.day);
    return switch (_range) {
      0 => (dayStart, dayStart.add(const Duration(days: 1))),
      1 => (
        DateTime.now().subtract(const Duration(days: 7)),
        DateTime.now().add(const Duration(minutes: 1)),
      ),
      _ => (
        DateTime.now().subtract(const Duration(days: 30)),
        DateTime.now().add(const Duration(minutes: 1)),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    return SSScaffold(
      trailing: 'Guardian',
      showBack: false,
      bottom: shell.nav,
      children: [
        Src<List<PairInfo>>(
          create: GD.pairs,
          initial: GD.pairsInit,
          builder: (c, pairs) {
            if (pairs.isEmpty) {
              return const Column(
                children: [
                  SSHeader(
                    eyebrow: 'Journey history',
                    title: 'The shape of today',
                  ),
                  SSInfo(
                    icon: Icons.person_add_alt_1_outlined,
                    title: 'No Travelers yet',
                    body:
                        'Pair a Traveler and their journeys will appear here.',
                  ),
                ],
              );
            }
            if (_who >= pairs.length) _who = 0;
            final pair = pairs[_who];
            final (from, to) = _window();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SSHeader(
                  eyebrow: '${pair.travelerName} · Journey history',
                  title: _range == 0
                      ? (_sameDay(_day, DateTime.now())
                            ? 'The shape of today'
                            : 'The shape of the day')
                      : (_range == 1
                            ? 'The shape of the week'
                            : 'The shape of the month'),
                ),
                if (pairs.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (var i = 0; i < pairs.length; i++)
                          ChoiceChip(
                            label: Text(_first(pairs[i].travelerName)),
                            selected: i == _who,
                            selectedColor: SS.mint,
                            backgroundColor: Colors.white,
                            labelStyle: ssBody(
                              bold: true,
                              size: 13,
                              color: SS.ink,
                            ),
                            onSelected: (_) => setState(() => _who = i),
                          ),
                      ],
                    ),
                  ),
                GSeg(
                  labels: const ['Today', 'Past week', 'Last month'],
                  index: _range,
                  onChanged: (i) => setState(() {
                    _range = i;
                    if (i == 0) _day = DateTime.now();
                  }),
                ),
                const SizedBox(height: 12),
                if (_range == 0)
                  Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(
                          () => _day = _day.subtract(const Duration(days: 1)),
                        ),
                        icon: const Icon(Icons.chevron_left, color: SS.teal),
                      ),
                      Text(
                        '${_dayLabel(_day)} ${_day.year}',
                        style: ssBody(bold: true, size: 14),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _day,
                            firstDate: DateTime.now().subtract(
                              const Duration(days: 365),
                            ),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) setState(() => _day = picked);
                        },
                        child: Text(
                          'Calendar',
                          style: ssBody(bold: true, size: 13, color: SS.teal),
                        ),
                      ),
                    ],
                  ),
                Src<List<JourneyEvent>>(
                  key: ValueKey('ev-${pair.id}-$_range-${_day.day}'),
                  create: () => GD.events(pair, from, to),
                  initial: const [],
                  builder: (c, evs) => Src<List<LocationPoint>>(
                    key: ValueKey('pt-${pair.id}-$_range-${_day.day}'),
                    create: () => GD.points(pair, from, to),
                    initial: const [],
                    builder: (c, pts) {
                      final st = GD.demo
                          ? DayStats(
                              _range == 0 ? 1.8 : (_range == 1 ? 11.4 : 42.7),
                              _range == 0 ? 21 : (_range == 1 ? 96 : 340),
                              computeStats(const [], evs).stops,
                              computeStats(const [], evs).route,
                            )
                          : computeStats(pts, evs);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          MiniMap(
                            height: 190,
                            showRoute: true,
                            initials: _initials(pair.travelerName),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Shared route',
                                style: ssBody(size: 11.5, color: SS.teal),
                              ),
                              Text(
                                pts.isEmpty && !GD.demo
                                    ? 'No points recorded'
                                    : 'All points synced',
                                style: ssBody(size: 11.5, color: SS.muted),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SSCard(
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    _stat(
                                      st.km < 10
                                          ? st.km.toStringAsFixed(1)
                                          : st.km.round().toString(),
                                      'km',
                                      'Distance',
                                    ),
                                    _stat(
                                      st.movingMin.toString(),
                                      'min',
                                      'Moving',
                                    ),
                                    _stat(
                                      st.stops.toString(),
                                      'stops',
                                      'Since leaving',
                                    ),
                                  ],
                                ),
                                const Divider(height: 22, color: SS.line),
                                Row(
                                  children: [
                                    _tile(Icons.route_outlined),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        st.route,
                                        style: ssBody(bold: true, size: 14),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          SSButton(
                            'View events & time at places',
                            icon: Icons.format_list_bulleted,
                            filled: false,
                            onPressed: () => shell.push(
                              TimelineScreen(
                                pair: pair,
                                from: from,
                                to: to,
                                label: _range == 0
                                    ? _dayLabel(_day)
                                    : (_range == 1
                                          ? 'Past week'
                                          : 'Last month'),
                              ),
                              tab: 3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Center(
                            child: Text(
                              'Routes connect recorded points and may not follow every turn exactly.',
                              textAlign: TextAlign.center,
                              style: ssBody(size: 11.5, color: SS.muted),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _stat(String v, String unit, String label) => Expanded(
    child: Column(
      children: [
        RichText(
          text: TextSpan(
            children: [
              TextSpan(text: v, style: ssBody(bold: true, size: 22)),
              TextSpan(
                text: ' $unit',
                style: ssBody(size: 12, color: SS.muted),
              ),
            ],
          ),
        ),
        Text(label, style: ssBody(size: 11.5, color: SS.muted)),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 4b. TIMELINE + TIME AT PLACES
// ─────────────────────────────────────────────────────────────────────────────

class _Item {
  final IconData icon;
  final String title, sub;
  final bool alert;
  final String note;
  final int ts;
  _Item(this.icon, this.title, this.sub, this.alert, this.note, this.ts);
}

List<_Item> _buildTimeline(List<JourneyEvent> evs, String guardianName) {
  final sorted = [...evs]..sort((a, b) => a.ts.compareTo(b.ts));
  final out = <_Item>[];
  for (final e in sorted) {
    switch (e.kind) {
      case EventKind.arrived:
        final end = sorted
            .where(
              (x) =>
                  x.kind == EventKind.left &&
                  x.zoneId == e.zoneId &&
                  x.ts >= e.ts,
            )
            .toList();
        final mins = end.isEmpty ? null : end.first.dwellMinutes;
        out.add(
          _Item(
            _zoneIcon(_guessType(e.zoneName ?? '')),
            e.alert ? 'Arrived at ${e.zoneName}' : '${e.zoneName}',
            end.isEmpty
                ? '${fmtTime(e.ts)} · here now'
                : '${fmtTime(e.ts)}–${fmtTime(end.first.ts)} · ${fmtDuration(mins ?? 0)} at ${e.zoneName}',
            e.alert,
            e.alert
                ? 'Arrival alert sent'
                : 'Familiar-zone history only · No push sent',
            e.ts,
          ),
        );
      case EventKind.left:
        if (e.alert) {
          out.add(
            _Item(
              Icons.logout,
              'Left ${e.zoneName} boundary',
              '${fmtTime(e.ts)} · Beyond the zone radius',
              true,
              'Boundary notification sent to ${_first(guardianName)}',
              e.ts,
            ),
          );
        }
      case EventKind.unexpectedStop:
        out.add(
          _Item(
            Icons.coffee_outlined,
            'Stopped away from familiar places',
            '${fmtTime(e.ts - e.dwellMinutes * 60000)}–now · ${e.dwellMinutes} min and counting',
            true,
            'Unexpected pause · Review in Alerts',
            e.ts,
          ),
        );
      case EventKind.distanceThreshold:
        out.add(
          _Item(
            Icons.straighten,
            'Distance threshold reached',
            fmtTime(e.ts),
            true,
            'Alert sent',
            e.ts,
          ),
        );
    }
  }
  return out;
}

class TimelineScreen extends StatefulWidget {
  final PairInfo pair;
  final DateTime from, to;
  final String label;
  const TimelineScreen({
    super.key,
    required this.pair,
    required this.from,
    required this.to,
    required this.label,
  });
  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final shell = GShell.of(context);
    final app = context.watch<AppState>();
    return SSScaffold(
      trailing: 'Guardian',
      onBack: shell.pop,
      bottom: shell.nav,
      children: [
        Text(
          '${widget.pair.travelerName.toUpperCase()} · ${widget.label.toUpperCase()}',
          style: ssEyebrow(),
        ),
        const SizedBox(height: 6),
        Text('Time at familiar places', style: ssHeadline()),
        const SizedBox(height: 14),
        GSeg(
          labels: const ['Timeline', 'Time at places'],
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 12),
        Src<List<JourneyEvent>>(
          create: () => GD.events(widget.pair, widget.from, widget.to),
          initial: const [],
          builder: (c, evs) {
            final dwell = <String, int>{};
            for (final e in evs) {
              if (e.kind == EventKind.left && (e.zoneName ?? '').isNotEmpty) {
                dwell[e.zoneName!] = (dwell[e.zoneName!] ?? 0) + e.dwellMinutes;
              } else if (e.kind == EventKind.unexpectedStop) {
                dwell['Other'] = (dwell['Other'] ?? 0) + e.dwellMinutes;
              }
            }
            final total = dwell.values.fold(0, (a, b) => a + b);
            const colors = [
              SS.teal,
              Color(0xFF7FA89C),
              Color(0xFFD3B77A),
              Color(0xFFB9C7C2),
            ];
            final entries = dwell.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));

            Widget bar() => SSCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DWELL TIME · $total MIN RECORDED',
                    style: ssBody(bold: true, size: 11.5, color: SS.muted),
                  ),
                  const SizedBox(height: 10),
                  if (total == 0)
                    Text(
                      'Nothing recorded for this period yet.',
                      style: ssBody(size: 12.5, color: SS.muted),
                    )
                  else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Row(
                        children: [
                          for (var i = 0; i < entries.length; i++)
                            Expanded(
                              flex: entries[i].value.clamp(1, 100000),
                              child: Container(
                                height: 10,
                                color: colors[i % colors.length],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        for (var i = 0; i < entries.length; i++)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: colors[i % colors.length],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${entries[i].key} ${fmtDuration(entries[i].value)}',
                                style: ssBody(bold: true, size: 12),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            );

            if (_tab == 1) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(),
                  Text('By place', style: ssBody(bold: true, size: 16)),
                  const SizedBox(height: 8),
                  if (entries.isEmpty)
                    Text(
                      'No stays recorded yet.',
                      style: ssBody(size: 12.5, color: SS.muted),
                    ),
                  for (var i = 0; i < entries.length; i++)
                    SSCard(
                      child: Row(
                        children: [
                          _tile(
                            entries[i].key == 'Other'
                                ? Icons.place_outlined
                                : _zoneIcon(_guessType(entries[i].key)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entries[i].key,
                                  style: ssBody(bold: true, size: 14.5),
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: total == 0
                                        ? 0
                                        : entries[i].value / total,
                                    minHeight: 6,
                                    backgroundColor: SS.mint,
                                    color: colors[i % colors.length],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            fmtDuration(entries[i].value),
                            style: ssBody(
                              bold: true,
                              size: 13.5,
                              color: SS.teal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      'Time at places is estimated from shared location points. Ongoing stays update as new points arrive.',
                      textAlign: TextAlign.center,
                      style: ssBody(size: 11.5, color: SS.muted),
                    ),
                  ),
                ],
              );
            }

            final items = _buildTimeline(
              evs,
              widget.pair.guardianName.isEmpty
                  ? app.displayName
                  : widget.pair.guardianName,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(),
                Text("Today's events", style: ssBody(bold: true, size: 16)),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  const SSInfo(
                    icon: Icons.hourglass_empty,
                    title: 'Nothing yet',
                    body:
                        'Arrivals, departures and stops will appear here as they happen.',
                  ),
                for (final it in items)
                  SSCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _tile(
                              it.icon,
                              bg: it.alert ? SS.amber : SS.mint,
                              fg: it.alert ? SS.amberText : SS.teal,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    it.title,
                                    style: ssBody(bold: true, size: 14.5),
                                  ),
                                  Text(
                                    it.sub,
                                    style: ssBody(size: 12, color: SS.muted),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              it.alert ? 'Alert' : 'Quiet',
                              style: ssBody(
                                bold: true,
                                size: 12.5,
                                color: it.alert ? SS.amberText : SS.teal,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          it.note,
                          style: ssBody(
                            size: 11.5,
                            color: it.alert ? SS.amberText : SS.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'Time at places is estimated from shared location points. Ongoing stays update as new points arrive.',
                    textAlign: TextAlign.center,
                    style: ssBody(size: 11.5, color: SS.muted),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
