// SafeStride - notifications.dart  (added in build-out step 4)
//
// Everything about getting an alert to the Guardian:
//
//   1. Push (app closed / in background)  -> sent by the Cloud Function in functions/index.js
//      through Firebase Cloud Messaging. The phone's system tray shows it.
//   2. In-app banner (app open)           -> appears at the top of the Guardian screens.
//      It works WITHOUT any server: the app listens to Firestore directly, so alerts show
//      up even before you deploy the Cloud Function (no billing needed for this part).
//   3. Tapping a push notification        -> opens that alert's detail page.
//   4. Alert preferences                  -> which alert types to receive + quiet hours.
//      Stored in users/{uid}.prefs and read by BOTH the app and the Cloud Function.
//
// No extra packages: uses firebase_messaging (already installed) and permission_handler.

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'main.dart';
import 'services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PREFERENCES
// ─────────────────────────────────────────────────────────────────────────────

class AlertPrefs {
  bool push;
  bool unexpected; // unexpected stops
  bool boundary; // leaving a safe zone
  bool distance; // too far from every safe zone
  bool quietOn;
  int quietStart; // minutes after midnight, local time
  int quietEnd;

  AlertPrefs({
    this.push = true,
    this.unexpected = true,
    this.boundary = true,
    this.distance = true,
    this.quietOn = false,
    this.quietStart = 22 * 60,
    this.quietEnd = 7 * 60,
  });

  Map<String, dynamic> toMap() => {
    'push': push,
    'unexpected': unexpected,
    'boundary': boundary,
    'distance': distance,
    'quietOn': quietOn,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
    // The Cloud Function runs in UTC, so it needs our offset to apply quiet hours.
    'tzOffset': DateTime.now().timeZoneOffset.inMinutes,
  };

  factory AlertPrefs.fromMap(Map<String, dynamic>? m) {
    if (m == null) {
      return AlertPrefs();
    }
    return AlertPrefs(
      push: (m['push'] as bool?) ?? true,
      unexpected: (m['unexpected'] as bool?) ?? true,
      boundary: (m['boundary'] as bool?) ?? true,
      distance: (m['distance'] as bool?) ?? true,
      quietOn: (m['quietOn'] as bool?) ?? false,
      quietStart: (m['quietStart'] as int?) ?? 22 * 60,
      quietEnd: (m['quietEnd'] as int?) ?? 7 * 60,
    );
  }

  bool inQuietHours(DateTime now) {
    if (!quietOn) {
      return false;
    }
    final m = now.hour * 60 + now.minute;
    return quietStart <= quietEnd
        ? (m >= quietStart && m < quietEnd)
        : (m >= quietStart || m < quietEnd);
  }

  bool allows(EventKind k, DateTime now) {
    if (!push || inQuietHours(now)) {
      return false;
    }
    return switch (k) {
      EventKind.unexpectedStop => unexpected,
      EventKind.left => boundary,
      EventKind.distanceThreshold => distance,
      EventKind.arrived => true,
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BUS (tiny glue between the services and the UI)
// ─────────────────────────────────────────────────────────────────────────────

class NotifyBus {
  NotifyBus._();

  /// An alert to show as a banner right now.
  static final ValueNotifier<TravelerAlert?> banner = ValueNotifier(null);

  /// An alert the user asked to open (banner tapped, or push notification tapped).
  static final ValueNotifier<TravelerAlert?> pendingAlert = ValueNotifier(null);
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT CENTER (runs while the Guardian screens are open)
// ─────────────────────────────────────────────────────────────────────────────

class AlertCenter {
  AlertCenter._();

  static AlertPrefs prefs = AlertPrefs();
  static StreamSubscription<List<TravelerAlert>>? _alerts;
  static StreamSubscription<RemoteMessage>? _onMsg;
  static StreamSubscription<RemoteMessage>? _onOpen;
  static final Set<String> _shown = {};
  static bool _primed = false;

  static Future<void> start() async {
    if (!backendReady) {
      return;
    }
    await stop();
    try {
      prefs = AlertPrefs.fromMap(await Repo.instance.getPrefs());
    } catch (_) {}

    // (a) Free path: watch Firestore directly. The first snapshot only records what already
    // exists, so old alerts never pop up as banners.
    _primed = false;
    _alerts = Repo.instance.watchAlerts().listen((list) {
      if (!_primed) {
        _shown.addAll(list.map((a) => a.id));
        _primed = true;
        return;
      }
      for (final a in list) {
        if (a.reviewed || _shown.contains(a.id)) {
          continue;
        }
        _shown.add(a.id);
        if (prefs.allows(a.kind, DateTime.now())) {
          NotifyBus.banner.value = a;
        }
      }
    }, onError: (_) {});

    // (b) Push while the app is open: the system does not draw it, so we show the banner.
    _onMsg = FirebaseMessaging.onMessage.listen((m) async {
      final id = m.data['alertId'] as String?;
      if (id == null || _shown.contains(id)) {
        return;
      }
      _shown.add(id);
      final a = await Repo.instance.getAlert(id);
      if (a != null && !a.reviewed) {
        NotifyBus.banner.value = a;
      }
    });

    // (c) Push tapped while the app was in the background.
    _onOpen = FirebaseMessaging.onMessageOpenedApp.listen(_openFrom);

    // (d) Push tapped while the app was closed.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      await _openFrom(initial);
    }
  }

  static Future<void> _openFrom(RemoteMessage m) async {
    final id = m.data['alertId'] as String?;
    if (id == null) {
      return;
    }
    final a = await Repo.instance.getAlert(id);
    if (a != null) {
      NotifyBus.pendingAlert.value = a;
    }
  }

  static Future<void> stop() async {
    await _alerts?.cancel();
    await _onMsg?.cancel();
    await _onOpen?.cancel();
    _alerts = null;
    _onMsg = null;
    _onOpen = null;
  }

  static Future<void> setPrefs(AlertPrefs p) async {
    prefs = p;
    if (backendReady) {
      try {
        await Repo.instance.savePrefs(p.toMap());
      } catch (_) {}
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IN-APP BANNER
// ─────────────────────────────────────────────────────────────────────────────

class AlertBannerHost extends StatefulWidget {
  final Widget child;
  const AlertBannerHost({super.key, required this.child});
  @override
  State<AlertBannerHost> createState() => _AlertBannerHostState();
}

class _AlertBannerHostState extends State<AlertBannerHost> {
  TravelerAlert? _alert;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    NotifyBus.banner.addListener(_onBanner);
  }

  @override
  void dispose() {
    NotifyBus.banner.removeListener(_onBanner);
    _timer?.cancel();
    super.dispose();
  }

  void _onBanner() {
    final a = NotifyBus.banner.value;
    if (a == null) {
      return;
    }
    NotifyBus.banner.value = null;
    setState(() => _alert = a);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 9), _dismiss);
  }

  void _dismiss() {
    if (mounted) {
      setState(() => _alert = null);
    }
  }

  void _review() {
    final a = _alert;
    _timer?.cancel();
    setState(() => _alert = null);
    if (a != null) {
      NotifyBus.pendingAlert.value = a;
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _alert;
    return Stack(
      children: [
        widget.child,
        if (a != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Material(
                  color: SS.amber,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _review,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.notifications_active_outlined,
                              color: SS.amberText,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ssBody(bold: true, size: 14.5),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  a.body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: ssBody(
                                    size: 12.5,
                                    color: SS.amberText,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Review & check in →',
                                  style: ssBody(
                                    bold: true,
                                    size: 12.5,
                                    color: SS.amberText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: _dismiss,
                            icon: const Icon(
                              Icons.close,
                              size: 18,
                              color: SS.amberText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ALERT SETTINGS SHEET
// ─────────────────────────────────────────────────────────────────────────────

String _hm(BuildContext c, int minutes) =>
    TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(c);

Future<void> showAlertSettings(BuildContext context) async {
  final p = AlertPrefs.fromMap(AlertCenter.prefs.toMap());

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SS.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (ctx, setS) {
        Widget row(String t, String sub, bool v, ValueChanged<bool> on) =>
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
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

        Future<void> pick(bool start) async {
          final cur = start ? p.quietStart : p.quietEnd;
          final t = await showTimePicker(
            context: ctx,
            initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
          );
          if (t != null) {
            setS(() {
              if (start) {
                p.quietStart = t.hour * 60 + t.minute;
              } else {
                p.quietEnd = t.hour * 60 + t.minute;
              }
            });
          }
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              20 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Alert settings', style: ssBody(bold: true, size: 20)),
                const SizedBox(height: 4),
                Text(
                  'Choose which updates are worth a notification. Everything still appears in your Alerts list.',
                  style: ssSub(),
                ),
                const SizedBox(height: 10),
                if (backendReady)
                  FutureBuilder<NotificationSettings>(
                    future: FirebaseMessaging.instance
                        .getNotificationSettings(),
                    builder: (c, snap) {
                      final st = snap.data?.authorizationStatus;
                      if (st == null ||
                          st == AuthorizationStatus.authorized ||
                          st == AuthorizationStatus.provisional) {
                        return const SizedBox.shrink();
                      }
                      return SSCard(
                        color: SS.amber,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.notifications_off_outlined,
                              color: SS.amberText,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                st == AuthorizationStatus.denied
                                    ? 'Notifications are off for SafeStride in your phone settings.'
                                    : 'SafeStride has not been allowed to send notifications yet.',
                                style: ssBody(size: 12.5, color: SS.amberText),
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                if (st == AuthorizationStatus.denied) {
                                  await openAppSettings();
                                } else {
                                  await FirebaseMessaging.instance
                                      .requestPermission();
                                  setS(() {});
                                }
                              },
                              child: Text(
                                st == AuthorizationStatus.denied
                                    ? 'Open settings'
                                    : 'Allow',
                                style: ssBody(
                                  bold: true,
                                  size: 12.5,
                                  color: SS.amberText,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                row(
                  'Push notifications',
                  'Master switch for alerts sent to this phone.',
                  p.push,
                  (v) => setS(() => p.push = v),
                ),
                const Divider(height: 1, color: SS.line),
                row(
                  'Unexpected stops',
                  'Still for 10+ minutes away from familiar places.',
                  p.unexpected,
                  (v) => setS(() => p.unexpected = v),
                ),
                row(
                  'Leaving a safe zone',
                  'When a Traveler crosses a zone boundary.',
                  p.boundary,
                  (v) => setS(() => p.boundary = v),
                ),
                row(
                  'Far from familiar places',
                  'More than 1 km from every safe zone.',
                  p.distance,
                  (v) => setS(() => p.distance = v),
                ),
                const Divider(height: 1, color: SS.line),
                row(
                  'Quiet hours',
                  'Silence notifications during set hours. Alerts still appear in the list.',
                  p.quietOn,
                  (v) => setS(() => p.quietOn = v),
                ),
                if (p.quietOn)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: SSButton(
                            'From ${_hm(ctx, p.quietStart)}',
                            filled: false,
                            onPressed: () => pick(true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SSButton(
                            'To ${_hm(ctx, p.quietEnd)}',
                            filled: false,
                            onPressed: () => pick(false),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                SSButton(
                  'Send a test alert',
                  icon: Icons.notifications_active_outlined,
                  filled: false,
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    final now = DateTime.now().millisecondsSinceEpoch;
                    NotifyBus.banner.value = TravelerAlert(
                      id: 'test-$now',
                      guardianUid: '',
                      travelerUid: 'test',
                      travelerName: 'Test Traveler',
                      kind: EventKind.unexpectedStop,
                      ts: now,
                      title: 'Test alert',
                      body:
                          'This is how alerts will look when your Traveler needs a check-in.',
                    );
                  },
                ),
                const SizedBox(height: 10),
                SSButton('Done', onPressed: () => Navigator.pop(sheetCtx)),
              ],
            ),
          ),
        );
      },
    ),
  );

  // Saved whenever the sheet closes (Done, swipe down, or test alert).
  await AlertCenter.setPrefs(p);
}
