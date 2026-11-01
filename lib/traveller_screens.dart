// SafeStride - traveler_screens.dart  (STEP 3 of 4)
//
// Traveler side after pairing:
//   TravelerShell   -> bottom nav: Home | Sharing | Device
//   Home            -> "Connected, quietly."  (online)  /  "Offline, not forgotten." (offline)
//   Sharing         -> who can see you, what is shared, pause / end connection
//   Device          -> "A quick device check" (GPS, battery, connection, last sync)
//
// All live numbers come from TrackingService (services.dart).
// In DEMO MODE (Firebase not configured) sample values are used so you can see every state,
// and a "Preview offline" switch appears on Home.

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import 'main.dart';
import 'services.dart';

/// Demo only: flips Home / Device between online and offline states.
final ValueNotifier<bool> demoOffline = ValueNotifier(false);

// ─────────────────────────────────────────────────────────────────────────────
// VIEW MODEL: merges real TrackingService data with demo fallbacks
// ─────────────────────────────────────────────────────────────────────────────

class TravelerVm {
  final bool online;
  final int battery;
  final double accuracy;
  final bool adaptive;
  final String connection;
  final PendingSummary pending;
  final int? lastSyncTs;
  final LocationPoint? lastPoint;
  final bool demo;

  TravelerVm({
    required this.online,
    required this.battery,
    required this.accuracy,
    required this.adaptive,
    required this.connection,
    required this.pending,
    required this.lastSyncTs,
    required this.lastPoint,
    required this.demo,
  });

  factory TravelerVm.from(TrackingService t) {
    if (backendReady) {
      return TravelerVm(
        online: t.online,
        battery: t.battery,
        accuracy: t.gpsAccuracy,
        adaptive: t.adaptive,
        connection: t.connection,
        pending: t.pending,
        lastSyncTs: t.lastSyncTs,
        lastPoint: t.lastPoint,
        demo: false,
      );
    }
    final off = demoOffline.value;
    final now = DateTime.now().millisecondsSinceEpoch;
    return TravelerVm(
      online: !off,
      battery: off ? 68 : 72,
      accuracy: 8,
      adaptive: true,
      connection: off ? 'Offline' : 'Wi-Fi',
      pending: off
          ? const PendingSummary(
              locationPoints: 18,
              wifiBreadcrumbs: 4,
              stepSummaries: 2,
              steps: 640,
              events: 0,
            )
          : const PendingSummary(),
      lastSyncTs: now - (off ? 16 : 0) * 60000,
      lastPoint: null,
      demo: true,
    );
  }

  String get batteryText => battery < 0 ? '—' : '$battery%';
  String get accuracyText => accuracy < 0 ? '—' : '${accuracy.round()} m';
}

String _ago(int? ts) {
  if (ts == null) return 'not yet';
  final m = ((DateTime.now().millisecondsSinceEpoch - ts) / 60000).round();
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  return '${m ~/ 60} h ago';
}

String _greeting() {
  final h = DateTime.now().hour;
  return h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
}

String _first(String name) => name.split(' ').first;

// ─────────────────────────────────────────────────────────────────────────────
// SHELL
// ─────────────────────────────────────────────────────────────────────────────

class TravelerShell extends StatefulWidget {
  const TravelerShell({super.key});
  @override
  State<TravelerShell> createState() => _TravelerShellState();
}

class _TravelerShellState extends State<TravelerShell> {
  int _tab = 0;

  void _go(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final nav = SSBottomNav(
      index: _tab,
      onTap: _go,
      items: const [
        (Icons.home_outlined, 'Home'),
        (Icons.shield_outlined, 'Sharing'),
        (Icons.show_chart, 'Device'),
      ],
    );
    // Rebuild whenever tracking state or the demo switch changes.
    return ListenableBuilder(
      listenable: Listenable.merge([TrackingService.instance, demoOffline]),
      builder: (context, _) {
        final vm = TravelerVm.from(TrackingService.instance);
        return switch (_tab) {
          0 => TravelerHome(vm: vm, nav: nav, goTo: _go),
          1 => SharingScreen(nav: nav),
          _ => DeviceScreen(vm: vm, nav: nav),
        };
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOME (online + offline)
// ─────────────────────────────────────────────────────────────────────────────

class TravelerHome extends StatefulWidget {
  final TravelerVm vm;
  final Widget nav;
  final ValueChanged<int> goTo;
  const TravelerHome({
    super.key,
    required this.vm,
    required this.nav,
    required this.goTo,
  });
  @override
  State<TravelerHome> createState() => _TravelerHomeState();
}

class _TravelerHomeState extends State<TravelerHome> {
  String? _place;
  String? _placeKey;

  /// Reverse-geocodes the last fix (only when it moved ~100 m, and only when online).
  void _resolvePlace(LocationPoint? p) {
    if (p == null || !widget.vm.online) return;
    final key = '${p.lat.toStringAsFixed(3)},${p.lng.toStringAsFixed(3)}';
    if (key == _placeKey) return;
    _placeKey = key;
    reverseGeocode(p.lat, p.lng).then((name) {
      if (mounted && name != null) setState(() => _place = name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final app = context.watch<AppState>();
    final name = app.displayName;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _resolvePlace(vm.lastPoint),
    );

    final body = vm.online && !app.sharingPaused
        ? _online(context, vm, app)
        : (vm.online ? _paused(context, vm, app) : _offline(context, vm, app));

    return SSScaffold(
      trailing: 'Traveler',
      showBack: false,
      bottom: widget.nav,
      children: [
        SSHeader(
          eyebrow: vm.online
              ? '${_greeting()}, ${_first(name)}'
              : "${_first(name)}'s phone · ${fmtTime(DateTime.now().millisecondsSinceEpoch)}",
          title: !vm.online
              ? 'Offline, not forgotten.'
              : (app.sharingPaused ? 'Taking a pause.' : 'Connected, quietly.'),
        ),
        ...body,
        if (vm.demo)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Demo: preview offline state',
                style: ssBody(size: 12.5, color: SS.muted),
              ),
              value: demoOffline.value,
              onChanged: (v) => demoOffline.value = v,
            ),
          ),
      ],
    );
  }

  // ── online
  List<Widget> _online(BuildContext c, TravelerVm vm, AppState app) {
    final p = vm.lastPoint;
    return [
      const Wrap(
        spacing: 8,
        children: [SSPill('Sharing is on'), SSPill('Online')],
      ),
      const SizedBox(height: 12),
      const MiniMap(height: 170, showRoute: true),
      const SizedBox(height: 12),
      SSCard(
        child: Column(
          children: [
            _line(
              Icons.place_outlined,
              _place != null
                  ? 'Near $_place'
                  : (vm.demo ? 'Near Willow Park Café' : 'Locating you…'),
              'Location updated ${_ago(p?.ts ?? vm.lastSyncTs)} · ${fmtTime(p?.ts ?? vm.lastSyncTs ?? DateTime.now().millisecondsSinceEpoch)}',
            ),
            const Divider(height: 20, color: SS.line),
            _line(
              Icons.battery_5_bar_outlined,
              '${vm.batteryText} battery · ${vm.connection} connected',
              vm.accuracy < 0
                  ? 'Waiting for GPS'
                  : 'GPS locked · accurate to ${vm.accuracyText.replaceAll(' m', '')} m',
            ),
          ],
        ),
      ),
      SSInfo(
        icon: Icons.favorite_border,
        title: 'Sharing with ${app.guardianName}',
        body:
            '${_first(app.guardianName)} can see your location and device status. No one else has access.',
      ),
      SSInfo(
        icon: Icons.eco_outlined,
        title: vm.adaptive
            ? 'Battery-saving mode is active'
            : 'Full accuracy mode',
        body: vm.adaptive
            ? 'You can close the app. Adaptive location updates continue in the background.'
            : "You're on the move, so updates are frequent. They slow down when you're still.",
      ),
      SSButton(
        'Manage or pause sharing',
        icon: Icons.tune,
        filled: false,
        onPressed: () => widget.goTo(1),
      ),
    ];
  }

  // ── online but paused by the Traveler
  List<Widget> _paused(BuildContext c, TravelerVm vm, AppState app) => [
    const Wrap(
      spacing: 8,
      children: [
        SSPill('Sharing paused', bg: SS.amber, fg: SS.amberText),
        SSPill('Online'),
      ],
    ),
    const SizedBox(height: 12),
    SSInfo(
      icon: Icons.pause_circle_outline,
      title: '${_first(app.guardianName)} can see that sharing is paused',
      body: app.pausedUntil == null
          ? 'Nothing new is sent until you resume.'
          : 'Sharing resumes automatically at ${fmtTime(app.pausedUntil!.millisecondsSinceEpoch)}.',
      color: SS.amber,
      fg: SS.amberText,
    ),
    SSButton(
      'Resume sharing',
      icon: Icons.play_arrow_rounded,
      onPressed: () => app.setPaused(false),
    ),
  ];

  // ── offline
  List<Widget> _offline(BuildContext c, TravelerVm vm, AppState app) {
    final pend = vm.pending;
    final lastTs = vm.lastSyncTs;
    return [
      const Wrap(
        spacing: 8,
        children: [
          SSPill(
            'Offline · saved on this phone',
            bg: SS.amber,
            fg: SS.amberText,
          ),
        ],
      ),
      const SizedBox(height: 12),
      Stack(
        children: [
          const MiniMap(height: 170, markerFaded: true),
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Last known · ${lastTs == null ? '—' : fmtTime(lastTs)}',
                style: ssBody(bold: true, size: 11, color: SS.muted),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      SSInfo(
        icon: Icons.location_off_outlined,
        title: '${_first(app.guardianName)} sees your last-known location',
        body:
            "Your live position isn't being sent. Sharing will resume automatically when you're connected.",
        color: SS.amber,
        fg: SS.amberText,
      ),
      SSCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tile(Icons.storage_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pend.total == 0
                        ? 'Nothing waiting to sync'
                        : '${pend.total} records waiting to sync',
                    style: ssBody(bold: true, size: 15),
                  ),
                  Text(
                    pend.oldestTs == null
                        ? 'Everything is saved.'
                        : 'Saved securely since ${fmtTime(pend.oldestTs!)}',
                    style: ssBody(size: 12.5, color: SS.muted),
                  ),
                  if (pend.total > 0) ...[
                    const Divider(height: 18, color: SS.line),
                    Text(
                      '${pend.locationPoints} location points · ${pend.wifiBreadcrumbs} Wi-Fi breadcrumbs · ${pend.stepSummaries} step summaries · ${pend.steps} steps recorded',
                      style: ssBody(size: 12, color: SS.muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      SSInfo(
        icon: Icons.eco_outlined,
        title: 'Still saving your journey',
        body:
            '${vm.batteryText} battery · Background recording is on. No need to keep this screen open.',
      ),
      SSButton(
        'Check connection & device',
        icon: Icons.show_chart,
        filled: false,
        onPressed: () => widget.goTo(2),
      ),
      const SizedBox(height: 8),
      Center(
        child: Text(
          'Pending records upload together after reconnecting.',
          style: ssBody(size: 11.5, color: SS.muted),
        ),
      ),
    ];
  }

  Widget _line(IconData i, String t, String sub) => Row(
    children: [
      _tile(i),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t, style: ssBody(bold: true, size: 14.5)),
            Text(sub, style: ssBody(size: 12, color: SS.muted)),
          ],
        ),
      ),
    ],
  );
}

Widget _tile(IconData i, {Color bg = SS.mint, Color fg = SS.teal}) => Container(
  width: 36,
  height: 36,
  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
  child: Icon(i, size: 19, color: fg),
);

// ─────────────────────────────────────────────────────────────────────────────
// SHARING TAB
// ─────────────────────────────────────────────────────────────────────────────

class SharingScreen extends StatelessWidget {
  final Widget nav;
  const SharingScreen({super.key, required this.nav});

  Future<void> _pauseSheet(BuildContext context, AppState app) async {
    final picked = await showModalBottomSheet<Duration?>(
      context: context,
      backgroundColor: SS.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pause sharing for…', style: ssBody(bold: true, size: 18)),
              const SizedBox(height: 4),
              Text(
                '${_first(app.guardianName)} will see that sharing is paused.',
                style: ssSub(),
              ),
              const SizedBox(height: 14),
              for (final o in const [
                ('1 hour', Duration(hours: 1)),
                ('4 hours', Duration(hours: 4)),
                ('Until I resume', Duration.zero),
              ])
                SSCard(
                  onTap: () => Navigator.pop(sheetCtx, o.$2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(o.$1, style: ssBody(bold: true, size: 15)),
                      ),
                      const Icon(Icons.chevron_right, color: SS.muted),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await app.setPaused(
      true,
      forDuration: picked == Duration.zero ? null : picked,
    );
  }

  Future<void> _endSheet(BuildContext context, AppState app) async {
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: SS.bg,
        title: Text(
          'End this connection?',
          style: ssBody(bold: true, size: 18),
        ),
        content: Text(
          '${_first(app.guardianName)} will no longer see your location. You can pair again with a new code.',
          style: ssSub(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(
              'Keep sharing',
              style: ssBody(bold: true, color: SS.teal),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(
              'End connection',
              style: ssBody(bold: true, color: SS.amberText),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.endConnection();
    nav.pushNamedAndRemoveUntil('/', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final g = app.guardianName;
    return SSScaffold(
      trailing: 'Traveler',
      showBack: false,
      bottom: nav,
      children: [
        SSHeader(
          eyebrow: 'Your circle',
          title: app.sharingPaused
              ? 'Sharing is paused'
              : 'Sharing, on your terms',
          subtitle: 'You decide what ${_first(g)} can see, and for how long.',
        ),
        SSCard(
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: SS.mint,
                child: Text(
                  g.split(' ').map((w) => w[0]).take(2).join(),
                  style: ssBody(bold: true, color: SS.teal),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g, style: ssBody(bold: true, size: 16)),
                    Text(
                      'Your Guardian',
                      style: ssBody(size: 12.5, color: SS.muted),
                    ),
                  ],
                ),
              ),
              app.sharingPaused
                  ? const SSPill('Paused', bg: SS.amber, fg: SS.amberText)
                  : const SSPill('Sharing'),
            ],
          ),
        ),
        SSCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _toggle(
                'Share my location',
                'Current location and journey history.',
                app.shareLocation,
                app.setShareLocation,
              ),
              const Divider(height: 1, color: SS.line),
              _toggle(
                'Share device status',
                'Battery, connection and GPS readiness.',
                app.shareDeviceStatus,
                app.setShareDevice,
              ),
            ],
          ),
        ),
        if (app.sharingPaused)
          SSButton(
            'Resume sharing',
            icon: Icons.play_arrow_rounded,
            onPressed: () => app.setPaused(false),
          )
        else
          SSButton(
            'Pause sharing',
            icon: Icons.pause_rounded,
            filled: false,
            onPressed: () => _pauseSheet(context, app),
          ),
        const SizedBox(height: 12),
        SSInfo(
          icon: Icons.visibility_outlined,
          title: '${_first(g)} will always know',
          body:
              'If you pause or turn something off, your Guardian sees that sharing is paused. They never see why.',
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: () => _endSheet(context, app),
            child: Text(
              'End connection with ${_first(g)}',
              style: ssBody(bold: true, color: SS.amberText),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toggle(String t, String sub, bool v, ValueChanged<bool> on) =>
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
// DEVICE TAB: quick diagnostics
// ─────────────────────────────────────────────────────────────────────────────

class DeviceScreen extends StatefulWidget {
  final TravelerVm vm;
  final Widget nav;
  const DeviceScreen({super.key, required this.vm, required this.nav});
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  bool _checking = false;

  Future<void> _recheck() async {
    setState(() => _checking = true);
    if (widget.vm.demo) {
      await Future.delayed(const Duration(milliseconds: 700));
      demoOffline.value = false; // demo: pretend we reconnected
    } else {
      await TrackingService.instance.recheck();
    }
    if (!mounted) return;
    setState(() => _checking = false);
    ssToast(
      context,
      widget.vm.online
          ? 'Connected. Syncing saved records.'
          : 'Still offline. Your records are safe on this phone.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final app = context.watch<AppState>();
    final now = fmtTime(DateTime.now().millisecondsSinceEpoch);
    final gpsReady = vm.accuracy >= 0 && vm.accuracy <= 50;
    final lowBattery = vm.battery >= 0 && vm.battery <= 20;

    return SSScaffold(
      trailing: 'Traveler',
      showBack: false,
      bottom: widget.nav,
      children: [
        SSHeader(
          eyebrow: "${_first(app.displayName)}'s phone · $now",
          title: 'A quick device check',
          subtitle: vm.online
              ? 'Everything is recording and syncing as it should.'
              : 'Location is recording on this phone. Connection is the only thing waiting.',
        ),
        Wrap(
          spacing: 8,
          children: [
            vm.online
                ? const SSPill('Online · syncing')
                : const SSPill(
                    'Offline · background recording active',
                    bg: SS.amber,
                    fg: SS.amberText,
                  ),
          ],
        ),
        const SizedBox(height: 12),
        SSCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              _diag(
                Icons.my_location,
                'GPS lock',
                gpsReady
                    ? 'Accurate to ${vm.accuracyText} · Checked $now'
                    : 'Searching for a clear signal',
                gpsReady ? 'Ready' : 'Searching',
                ok: gpsReady,
              ),
              const Divider(height: 1, color: SS.line),
              _diag(
                Icons.battery_5_bar_outlined,
                'Battery',
                vm.adaptive
                    ? 'Adaptive battery-saving mode active'
                    : 'Full accuracy mode',
                vm.batteryText,
                ok: !lowBattery,
                neutral: true,
              ),
              const Divider(height: 1, color: SS.line),
              _diag(
                vm.online ? Icons.wifi : Icons.wifi_off,
                'Connection',
                vm.online
                    ? '${vm.connection} · internet available'
                    : 'No internet. Wi-Fi and mobile data unavailable',
                vm.online ? 'Online' : 'Offline',
                ok: vm.online,
                amberWhenBad: true,
              ),
              const Divider(height: 1, color: SS.line),
              _diag(
                Icons.cloud_done_outlined,
                'Last successful sync',
                vm.lastSyncTs == null
                    ? 'Nothing synced yet'
                    : 'Today, ${fmtTime(vm.lastSyncTs!)} · ${_ago(vm.lastSyncTs)}',
                vm.pending.total == 0 ? 'Saved' : '${vm.pending.total} waiting',
                ok: vm.pending.total == 0,
                neutral: true,
              ),
            ],
          ),
        ),
        SSInfo(
          icon: Icons.sync,
          title: 'Automatic background sync is on',
          body: vm.online
              ? 'Records upload in batches. ${_first(app.guardianName)} sees your live location.'
              : 'Records upload in one batch after reconnecting. ${_first(app.guardianName)} sees the ${vm.lastSyncTs == null ? '' : '${fmtTime(vm.lastSyncTs!)} '}last-known location until then.',
        ),
        SSButton(
          _checking ? 'Checking…' : 'Check connection again',
          icon: Icons.refresh,
          onPressed: _checking ? null : _recheck,
        ),
        const SizedBox(height: 10),
        SSButton(
          'Open phone settings',
          icon: Icons.settings_outlined,
          filled: false,
          onPressed: Geolocator.openAppSettings,
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Your queue stays on this phone until it is securely synced. You can close SafeStride while you wait.',
            textAlign: TextAlign.center,
            style: ssBody(size: 11.5, color: SS.muted),
          ),
        ),
      ],
    );
  }

  Widget _diag(
    IconData icon,
    String title,
    String sub,
    String status, {
    required bool ok,
    bool neutral = false,
    bool amberWhenBad = false,
  }) {
    final color = ok ? SS.teal : (neutral && !ok ? SS.amberText : SS.amberText);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          _tile(
            icon,
            bg: ok || neutral ? SS.mint : SS.amber,
            fg: ok || neutral ? SS.teal : SS.amberText,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ssBody(bold: true, size: 14.5)),
                Text(sub, style: ssBody(size: 12, color: SS.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(status, style: ssBody(bold: true, size: 13, color: color)),
        ],
      ),
    );
  }
}
