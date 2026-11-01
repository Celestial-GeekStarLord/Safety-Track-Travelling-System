// SafeStride - main.dart  (STEP 1 of 4)
//
// Files in this project (max 4):
//   lib/main.dart               -> bootstrap, theme, shared widgets, onboarding + pairing flow
//   lib/services.dart           -> (step 2) models, Firebase, Hive offline buffer, tracking, sync, geofence
//   lib/traveler_screens.dart   -> (step 3) traveler home online/offline, device diagnostics
//   lib/guardian_screens.dart   -> (step 4) people, live detail, zones, alerts, history, timeline
//
// pubspec.yaml dependencies needed for this step:
//   firebase_core, firebase_auth, provider, google_fonts, qr_flutter
//
// Run `flutterfire configure` to generate firebase_options.dart if you want real
// Firebase. Until then the app runs in DEMO MODE (no backend) so you can see the UI.

import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'guardian_screens.dart';
import 'services.dart';
import 'traveller_screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BOOTSTRAP
// ─────────────────────────────────────────────────────────────────────────────

bool firebaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // With flutterfire: await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase not configured, running in demo mode: $e');
  }
  await OfflineStore.init(); // Hive outbox for offline tracking (step 2)
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const SafeStrideApp(),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN TOKENS
// ─────────────────────────────────────────────────────────────────────────────

class SS {
  static const bg = Color(0xFFF5F3EC);
  static const surface = Colors.white;
  static const teal = Color(0xFF176B5D);
  static const tealDark = Color(0xFF0F3F37);
  static const ink = Color(0xFF12372F);
  static const muted = Color(0xFF6B7A75);
  static const mint = Color(0xFFE2F0EA);
  static const amber = Color(0xFFF7EBD5);
  static const amberText = Color(0xFF9A5B12);
  static const line = Color(0xFFE4E1D6);
  static const mapBase = Color(0xFFE9E8DE);
  static const mapPark = Color(0xFFD7E4CE);
  static const mapWater = Color(0xFFBFD9DE);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: teal, surface: bg),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      // Explicit styles (ssBody, ssHeadline...) use Nunito via GoogleFonts.nunito().
      // We keep the theme-wide TextTheme free of google_fonts types to stay compatible
      // with any google_fonts / Flutter SDK combination.
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: const AppBarTheme(backgroundColor: bg, elevation: 0),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? teal : const Color(0xFFCFCFC6),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}

TextStyle ssEyebrow() => GoogleFonts.nunito(
  fontSize: 11,
  fontWeight: FontWeight.w800,
  color: SS.teal,
  letterSpacing: .6,
);
TextStyle ssHeadline() => GoogleFonts.nunito(
  fontSize: 30,
  height: 1.12,
  fontWeight: FontWeight.w800,
  color: SS.ink,
);
TextStyle ssSub() =>
    GoogleFonts.nunito(fontSize: 14, height: 1.4, color: SS.muted);
TextStyle ssBody({bool bold = false, Color color = SS.ink, double size = 14}) =>
    GoogleFonts.nunito(
      fontSize: size,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
      color: color,
    );

// ─────────────────────────────────────────────────────────────────────────────
// APP STATE  (step 2 moves auth/pairing to services.dart and wires Firestore)
// ─────────────────────────────────────────────────────────────────────────────

enum UserRole { traveler, guardian }

class AppState extends ChangeNotifier {
  UserRole role = UserRole.traveler;
  String email = '';
  bool signedIn = false;

  // Traveler consent
  bool shareLocation = true;
  bool shareDeviceStatus = true;

  // Pairing (Guardian side generates, Traveler side enters)
  String syncCode = '';
  DateTime? codeExpiry;
  Timer? _ticker;

  // Result of pairing
  String guardianName = 'Maya Lee';
  bool paired = false;

  void setRole(UserRole r) {
    role = r;
    notifyListeners();
  }

  void setShareLocation(bool v) {
    shareLocation = v;
    notifyListeners();
    if (paired && backendReady && !sharingPaused) {
      v ? _startTracking() : TrackingService.instance.stop();
    }
  }

  Future<void> _startTracking() => TrackingService.instance.start(
    travelerUid: Repo.instance.uid!,
    travelerName: displayName,
  );

  // Pause / resume sharing (Traveler > Sharing tab)
  bool sharingPaused = false;
  DateTime? pausedUntil;
  Timer? _resumeTimer;

  Future<void> setPaused(bool paused, {Duration? forDuration}) async {
    sharingPaused = paused;
    _resumeTimer?.cancel();
    pausedUntil = null;
    if (paused && forDuration != null) {
      pausedUntil = DateTime.now().add(forDuration);
      _resumeTimer = Timer(forDuration, () => setPaused(false));
    }
    notifyListeners();
    if (!backendReady) {
      return;
    }
    final pairs = await Repo.instance.watchPairsAsTraveler().first;
    for (final p in pairs) {
      await Repo.instance.setSharingPaused(p.id, paused);
    }
    if (paused) {
      await TrackingService.instance.stop();
    } else if (shareLocation) {
      await _startTracking();
    }
  }

  /// Remove every Guardian connection and stop tracking.
  Future<void> endConnection() async {
    _resumeTimer?.cancel();
    if (backendReady) {
      final pairs = await Repo.instance.watchPairsAsTraveler().first;
      for (final p in pairs) {
        await Repo.instance.endPairing(p.id);
      }
      await TrackingService.instance.stop();
    }
    paired = false;
    sharingPaused = false;
    notifyListeners();
  }

  void setShareDevice(bool v) {
    shareDeviceStatus = v;
    notifyListeners();
  }

  /// Email/password sign in. Falls back to demo mode if Firebase isn't set up.
  Future<String?> signIn(
    String mail,
    String password, {
    bool create = false,
  }) async {
    email = mail.trim();
    if (email.isEmpty || password.length < 6) {
      return 'Enter your email and a password of at least 6 characters.';
    }
    if (firebaseReady) {
      try {
        final auth = FirebaseAuth.instance;
        if (create) {
          await auth.createUserWithEmailAndPassword(
            email: email,
            password: password,
          );
        } else {
          await auth.signInWithEmailAndPassword(
            email: email,
            password: password,
          );
        }
      } on FirebaseAuthException catch (e) {
        return e.message ?? 'Could not sign in. Please try again.';
      }
    }
    if (firebaseReady) {
      await Repo.instance.saveProfile(name: displayName, role: role.name);
      if (role == UserRole.guardian) {
        Repo.instance.registerPushToken();
      }
    }
    signedIn = true;
    notifyListeners();
    return null;
  }

  /// Guardian: create a temporary 6-digit code valid for 10 minutes.
  /// STEP 2: also write `pairingCodes/{code}` to Firestore with guardianUid + expiry.
  void generateCode() {
    syncCode = (100000 + Random.secure().nextInt(900000)).toString();
    codeExpiry = DateTime.now().add(const Duration(minutes: 10));
    if (backendReady) {
      Repo.instance.createPairingCode(syncCode, displayName, codeExpiry!);
    }
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (remaining == Duration.zero) {
        _ticker?.cancel();
      }
      notifyListeners();
    });
    notifyListeners();
  }

  Duration get remaining {
    if (codeExpiry == null) {
      return Duration.zero;
    }
    final d = codeExpiry!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  String get displayName {
    final base = email.split('@').first;
    if (base.isEmpty) {
      return role == UserRole.guardian ? 'Guardian' : 'Traveler';
    }
    return base
        .split(RegExp(r'[._-]'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  String _pendingCode = '';

  /// Traveler: look up a code in Firestore (demo mode: any 6 digits resolves).
  Future<String?> lookupGuardian(String code) async {
    if (code.length != 6) {
      return null;
    }
    _pendingCode = code;
    if (!backendReady) {
      await Future.delayed(const Duration(milliseconds: 400));
      return guardianName;
    }
    final name = await Repo.instance.lookupCode(code);
    if (name != null) {
      guardianName = name;
    }
    return name;
  }

  /// Traveler confirms: create the pair, save profile, start background tracking.
  Future<void> confirmPairing() async {
    if (backendReady) {
      await Repo.instance.saveProfile(name: displayName, role: 'traveler');
      await Repo.instance.confirmPairing(
        _pendingCode,
        travelerName: displayName,
      );
      if (shareLocation) {
        await TrackingService.instance.start(
          travelerUid: Repo.instance.uid!,
          travelerName: displayName,
        );
      }
    }
    paired = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// APP + NAVIGATION
// ─────────────────────────────────────────────────────────────────────────────

class SafeStrideApp extends StatelessWidget {
  const SafeStrideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeStride',
      debugShowCheckedModeBanner: false,
      theme: SS.theme(),
      initialRoute: '/',
      routes: {
        '/': (_) => const WelcomeScreen(),
        '/signin': (_) => const SignInScreen(),
        '/consent': (_) => const TravelerConsentScreen(),
        '/invite': (_) => const GuardianInviteScreen(),
        '/pair': (_) => const TravelerPairScreen(),
        // STEP 3/4 replace these with real shells:
        '/traveler': (_) => const TravelerShell(),
        '/guardian': (_) => const GuardianShell(),
      },
    );
  }
}

class ShellPlaceholder extends StatelessWidget {
  final String label;
  const ShellPlaceholder({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return SSScaffold(
      title: label,
      trailing: 'Next step',
      showBack: false,
      children: [
        const SizedBox(height: 40),
        Text('Onboarding complete', style: ssHeadline()),
        const SizedBox(height: 8),
        Text('$label is built in the next step.', style: ssSub()),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

/// Page frame: top bar (shield + SafeStride + trailing label) and scroll body.
class SSScaffold extends StatelessWidget {
  final String title;
  final String trailing;
  final bool showBack;
  final List<Widget> children;
  final Widget? bottom;

  const SSScaffold({
    super.key,
    this.title = '',
    required this.trailing,
    this.showBack = true,
    required this.children,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 20, 8),
              child: Row(
                children: [
                  if (showBack)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back, color: SS.teal),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.shield_outlined, color: SS.teal),
                    ),
                  Text(
                    'SafeStride',
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    trailing,
                    style: ssBody(bold: true, color: SS.muted, size: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: children,
              ),
            ),
            if (bottom != null) bottom!,
          ],
        ),
      ),
    );
  }
}

class SSHeader extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String? subtitle;
  const SSHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(eyebrow.toUpperCase(), style: ssEyebrow()),
      const SizedBox(height: 6),
      Text(title, style: ssHeadline()),
      if (subtitle != null) ...[
        const SizedBox(height: 8),
        Text(subtitle!, style: ssSub()),
      ],
      const SizedBox(height: 16),
    ],
  );
}

class SSButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;
  const SSButton(
    this.label, {
    super.key,
    this.icon,
    this.onPressed,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : SS.teal;
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: Material(
        color: filled ? SS.teal : SS.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: filled ? BorderSide.none : const BorderSide(color: SS.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SSCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool outlined;
  const SSCard({
    super.key,
    required this.child,
    this.color = SS.surface,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.outlined = true,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: outlined && color == SS.surface
            ? const BorderSide(color: SS.line)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

/// Tinted info panel with a leading icon: used for "A private connection", etc.
class SSInfo extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final Color fg;
  const SSInfo({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.color = SS.mint,
    this.fg = SS.teal,
  });

  @override
  Widget build(BuildContext context) => SSCard(
    color: color,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(150),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: fg),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ssBody(bold: true, size: 14)),
              const SizedBox(height: 3),
              Text(
                body,
                style: ssBody(
                  size: 12.5,
                  color: SS.muted,
                ).copyWith(height: 1.35),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SSPill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const SSPill(this.text, {super.key, this.bg = SS.mint, this.fg = SS.teal});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: ssBody(bold: true, color: fg, size: 11.5)),
  );
}

/// Simple stylised map used across the app (zone circle, route, marker).
/// STEP 3/4: swap or overlay with google_maps_flutter / flutter_map using real points.
class MiniMap extends StatelessWidget {
  final double height;
  final bool showZone;
  final bool showRoute;
  final String initials;
  final bool markerFaded;
  const MiniMap({
    super.key,
    this.height = 190,
    this.showZone = false,
    this.showRoute = false,
    this.initials = 'JL',
    this.markerFaded = false,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _MapPainter(showZone, showRoute),
        child: Align(
          alignment: showRoute ? const Alignment(.35, .55) : Alignment.center,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: markerFaded ? Colors.white : SS.teal,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
            ),
            child: Text(
              initials,
              style: ssBody(
                bold: true,
                size: 12,
                color: markerFaded ? SS.muted : Colors.white,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MapPainter extends CustomPainter {
  final bool zone;
  final bool route;
  _MapPainter(this.zone, this.route);

  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = SS.mapBase);
    // park
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(s.width * .5, 8, s.width * .38, s.height * .42),
        const Radius.circular(10),
      ),
      Paint()..color = SS.mapPark,
    );
    // river
    final river = Path()
      ..moveTo(s.width * .88, 0)
      ..quadraticBezierTo(s.width * .96, s.height * .5, s.width * .8, s.height);
    c.drawPath(
      river,
      Paint()
        ..color = SS.mapWater
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16,
    );
    // roads
    final road = Paint()..color = Colors.white;
    c.drawRect(
      Rect.fromLTWH(0, s.height * .42, s.width, 12),
      road,
    ); // horizontal
    c.drawRect(Rect.fromLTWH(s.width * .3, 0, 12, s.height), road); // vertical
    c.drawRect(Rect.fromLTWH(0, s.height * .84, s.width, 8), road);
    // blocks
    final block = Paint()..color = const Color(0xFFDCDACD);
    for (final r in [
      Rect.fromLTWH(s.width * .08, s.height * .08, 30, 24),
      Rect.fromLTWH(s.width * .45, s.height * .6, 34, 26),
      Rect.fromLTWH(s.width * .12, s.height * .6, 30, 26),
    ]) {
      c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), block);
    }
    final label = TextPainter(
      text: TextSpan(
        text: 'Willow Park',
        style: GoogleFonts.nunito(fontSize: 9, color: SS.muted),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(c, Offset(s.width * .58, 14));

    if (zone) {
      final center = Offset(s.width / 2, s.height / 2);
      c.drawCircle(center, 52, Paint()..color = SS.teal.withAlpha(25));
      final dash = Paint()
        ..color = SS.teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      for (var a = 0.0; a < 2 * pi; a += .22) {
        c.drawArc(
          Rect.fromCircle(center: center, radius: 52),
          a,
          .12,
          false,
          dash,
        );
      }
    }
    if (route) {
      final p = Paint()
        ..color = SS.teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      final path = Path()
        ..moveTo(s.width * .28, s.height * .2)
        ..lineTo(s.width * .28, s.height * .47)
        ..lineTo(s.width * .6, s.height * .47)
        ..lineTo(s.width * .6, s.height * .65);
      c.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.zone != zone || old.route != route;
}

/// Bottom navigation used by both Traveler and Guardian shells.
class SSBottomNav extends StatelessWidget {
  final List<(IconData, String)> items;
  final int index;
  final ValueChanged<int> onTap;
  const SSBottomNav({
    super.key,
    required this.items,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: SS.bg,
      border: Border(top: BorderSide(color: SS.line)),
    ),
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
    child: Row(
      children: [
        for (var i = 0; i < items.length; i++)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onTap(i),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: i == index ? SS.mint : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      items[i].$1,
                      size: 20,
                      color: i == index ? SS.teal : SS.muted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    items[i].$2,
                    style: ssBody(
                      bold: i == index,
                      size: 11,
                      color: i == index ? SS.teal : SS.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

void ssToast(BuildContext c, String msg) =>
    ScaffoldMessenger.of(c).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 1: WELCOME & ROLE SELECTION
// ─────────────────────────────────────────────────────────────────────────────

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return SSScaffold(
      trailing: 'Welcome',
      showBack: false,
      children: [
        const SSHeader(
          eyebrow: 'A little reassurance, together',
          title: 'Room to roam. Someone in your corner.',
          subtitle:
              'Stay connected on everyday journeys, with care that respects your independence.',
        ),
        const MiniMap(height: 170, showZone: true, initials: 'H'),
        const SizedBox(height: 18),
        Text(
          'How will you use SafeStride?',
          style: ssBody(bold: true, size: 16),
        ),
        const SizedBox(height: 10),
        _RoleCard(
          icon: Icons.directions_walk,
          title: "I'm a Traveler",
          subtitle: 'Share my journey with someone I trust.',
          selected: state.role == UserRole.traveler,
          onTap: () => state.setRole(UserRole.traveler),
        ),
        _RoleCard(
          icon: Icons.favorite_border,
          title: "I'm a Guardian",
          subtitle: 'Support a loved one along the way.',
          selected: state.role == UserRole.guardian,
          onTap: () => state.setRole(UserRole.guardian),
        ),
        const SizedBox(height: 4),
        SSButton(
          state.role == UserRole.traveler
              ? 'Continue as Traveler'
              : 'Continue as Guardian',
          onPressed: () => Navigator.pushNamed(context, '/signin'),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 14, color: SS.muted),
            const SizedBox(width: 6),
            Text(
              'Always your choice. Never shared publicly.',
              style: ssBody(size: 12, color: SS.muted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () => Navigator.pushNamed(context, '/signin'),
            child: Text(
              'Already connected? Sign in',
              style: ssBody(bold: true, color: SS.teal),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => SSCard(
    color: selected ? SS.mint : SS.surface,
    onTap: onTap,
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: selected ? Colors.white.withAlpha(160) : SS.mint,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: SS.teal, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ssBody(bold: true, size: 15)),
              Text(subtitle, style: ssBody(size: 12.5, color: SS.muted)),
            ],
          ),
        ),
        Icon(
          selected ? Icons.check : Icons.chevron_right,
          color: selected ? SS.teal : SS.muted,
          size: 20,
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 2: SIGN IN / CREATE ACCOUNT
// ─────────────────────────────────────────────────────────────────────────────

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _create = false;
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = context.read<AppState>();
    final err = await state.signIn(_email.text, _pass.text, create: _create);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err == null) {
      Navigator.pushNamed(
        context,
        state.role == UserRole.traveler ? '/consent' : '/invite',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SSScaffold(
      trailing: 'Your account',
      children: [
        SSHeader(
          eyebrow: 'Your trusted circle',
          title: _create ? 'Create your account' : 'Welcome back',
          subtitle:
              'Sign in to reconnect. Your account works for both Traveler and Guardian roles.',
        ),
        _Segmented(
          left: 'Sign in',
          right: 'Create account',
          rightSelected: _create,
          onChanged: (v) => setState(() => _create = v),
        ),
        const SizedBox(height: 16),
        Text('Email address', style: ssBody(bold: true, size: 12.5)),
        const SizedBox(height: 6),
        _field(
          _email,
          'maya.lee@example.com',
          keyboard: TextInputType.emailAddress,
        ),
        const SizedBox(height: 14),
        Text('Password', style: ssBody(bold: true, size: 12.5)),
        const SizedBox(height: 6),
        _field(
          _pass,
          'Password',
          obscure: _hide,
          suffix: IconButton(
            icon: Icon(
              _hide ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 20,
              color: SS.muted,
            ),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              if (firebaseReady && _email.text.isNotEmpty) {
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: _email.text.trim(),
                );
                if (mounted) {
                  ssToast(context, 'Reset link sent.');
                }
              } else {
                ssToast(context, 'Enter your email first.');
              }
            },
            child: Text(
              'Forgot password?',
              style: ssBody(bold: true, color: SS.teal, size: 12.5),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: ssBody(color: SS.amberText, size: 12.5),
            ),
          ),
        SSButton(
          _busy
              ? 'Please wait…'
              : (_create ? 'Create account' : 'Sign in securely'),
          icon: Icons.arrow_forward,
          onPressed: _busy ? null : _submit,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'or continue with',
            style: ssBody(size: 12, color: SS.muted),
          ),
        ),
        const SizedBox(height: 12),
        SSButton(
          'Continue with Apple',
          icon: Icons.apple,
          filled: false,
          onPressed: () => ssToast(
            context,
            'Apple sign-in: add sign_in_with_apple in step 2.',
          ),
        ),
        const SizedBox(height: 10),
        SSButton(
          'Continue with Google',
          icon: Icons.language,
          filled: false,
          onPressed: () =>
              ssToast(context, 'Google sign-in: add google_sign_in in step 2.'),
        ),
        const SizedBox(height: 14),
        const SSInfo(
          icon: Icons.verified_user_outlined,
          title: 'A private connection',
          body:
              'Only people you pair with can see shared location. You can review access at any time.',
        ),
        Center(
          child: Text(
            'By continuing, you agree to our Terms of use and Privacy notice.',
            textAlign: TextAlign.center,
            style: ssBody(size: 11, color: SS.muted),
          ),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String hint, {
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      style: ssBody(size: 15),
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        suffixIcon: suffix,
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
    );
  }
}

class _Segmented extends StatelessWidget {
  final String left;
  final String right;
  final bool rightSelected;
  final ValueChanged<bool> onChanged;
  const _Segmented({
    required this.left,
    required this.right,
    required this.rightSelected,
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
        _seg(left, !rightSelected, () => onChanged(false)),
        _seg(right, rightSelected, () => onChanged(true)),
      ],
    ),
  );

  Widget _seg(String t, bool sel, VoidCallback tap) => Expanded(
    child: GestureDetector(
      onTap: tap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: sel ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Text(
          t,
          style: ssBody(bold: sel, size: 13.5, color: sel ? SS.teal : SS.muted),
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 3: TRAVELER CONSENT & PERMISSIONS
// ─────────────────────────────────────────────────────────────────────────────

class TravelerConsentScreen extends StatelessWidget {
  const TravelerConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return SSScaffold(
      trailing: 'Traveler setup',
      children: [
        const SSHeader(
          eyebrow: 'Step 1 of 2 · Your choice',
          title: 'Share with confidence',
          subtitle:
              'Choose what your Guardian can see. Nothing is shared until you pair and give permission.',
        ),
        SSCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _toggle(
                'Share my location',
                'Current location and journey history.',
                s.shareLocation,
                s.setShareLocation,
              ),
              const Divider(height: 1, color: SS.line),
              _toggle(
                'Share device status',
                'Battery, connection and GPS readiness.',
                s.shareDeviceStatus,
                s.setShareDevice,
              ),
            ],
          ),
        ),
        const SSInfo(
          icon: Icons.location_on_outlined,
          title: 'Location, even with the app closed',
          body:
              'Choose "Allow While Using", then "Always" in your phone\'s location settings.\n\nBackground access keeps journeys up to date. Adaptive updates use less power when you\'re still.',
        ),
        const SSInfo(
          icon: Icons.wifi_off,
          title: "When you're offline",
          body:
              'Location, Wi-Fi (BSSID) breadcrumbs and motion-sensor steps stay on this phone, then sync securely on reconnect.',
          color: SS.amber,
          fg: SS.amberText,
        ),
        const SSInfo(
          icon: Icons.tune,
          title: 'You stay in control',
          body:
              'Pause sharing or remove a Guardian anytime. Your Guardian will see when sharing is paused.',
          color: Color(0xFFEFEDE3),
          fg: SS.muted,
        ),
        SSButton(
          'Agree & enable location',
          onPressed: () async {
            // STEP 2: request permissions here via permission_handler / geolocator:
            //   await Permission.locationWhenInUse.request();
            //   await Permission.locationAlways.request();
            Navigator.pushNamed(context, '/pair');
          },
        ),
        Center(
          child: TextButton(
            onPressed: () {
              s.setShareLocation(false);
              Navigator.pushNamed(context, '/pair');
            },
            child: Text('Not now', style: ssBody(bold: true, color: SS.teal)),
          ),
        ),
        Center(
          child: Text(
            'You can explore without permission. Location sharing stays off until you enable it.',
            textAlign: TextAlign.center,
            style: ssBody(size: 11.5, color: SS.muted),
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
// SCREEN 4: GUARDIAN PAIRING INVITATION (QR + 6-digit code)
// ─────────────────────────────────────────────────────────────────────────────

class GuardianInviteScreen extends StatefulWidget {
  const GuardianInviteScreen({super.key});
  @override
  State<GuardianInviteScreen> createState() => _GuardianInviteScreenState();
}

class _GuardianInviteScreenState extends State<GuardianInviteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<AppState>().generateCode(),
    );
  }

  String _fmtCode(String c) =>
      c.length == 6 ? '${c.substring(0, 3)} ${c.substring(3)}' : c;

  String _fmtExpiry(DateTime? d) {
    if (d == null) {
      return '';
    }
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final mins = s.remaining.inMinutes;
    final secs = (s.remaining.inSeconds % 60).toString().padLeft(2, '0');
    final expired = s.remaining == Duration.zero && s.syncCode.isNotEmpty;

    return SSScaffold(
      trailing: 'Guardian setup',
      children: [
        const SSHeader(
          eyebrow: 'Connect your circle',
          title: 'Invite your Traveler',
          subtitle:
              'Ask them to scan this code in SafeStride, or enter the six-digit code on their phone.',
        ),
        SSCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              const SSPill('Private invitation'),
              const SizedBox(height: 14),
              Opacity(
                opacity: expired ? .25 : 1,
                child: s.syncCode.isEmpty
                    ? const SizedBox(height: 180)
                    : QrImageView(
                        // STEP 2: encode a signed payload (guardianUid + code) instead of raw code
                        data: 'safestride://pair?code=${s.syncCode}',
                        size: 180,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: SS.tealDark,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: SS.tealDark,
                        ),
                      ),
              ),
              const SizedBox(height: 14),
              Text(
                'TEMPORARY SYNC CODE',
                style: ssBody(size: 11, color: SS.muted),
              ),
              const SizedBox(height: 4),
              Text(
                _fmtCode(s.syncCode),
                style: GoogleFonts.nunito(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                expired
                    ? 'This code has expired. Generate a new one.'
                    : 'Expires at ${_fmtExpiry(s.codeExpiry)} · $mins:$secs remaining',
                style: ssBody(
                  size: 12,
                  color: expired ? SS.amberText : SS.muted,
                ),
              ),
            ],
          ),
        ),
        SSButton(
          'Share invitation',
          icon: Icons.share_outlined,
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(
                text:
                    'Join my SafeStride circle. Enter code ${_fmtCode(s.syncCode)} in the app. It expires in 10 minutes.',
              ),
            );
            if (mounted) {
              ssToast(
                context,
                'Invitation copied. Add share_plus for the share sheet.',
              );
            }
          },
        ),
        const SizedBox(height: 10),
        SSButton(
          'Generate a new code',
          icon: Icons.refresh,
          filled: false,
          onPressed: s.generateCode,
        ),
        const SizedBox(height: 12),
        const SSInfo(
          icon: Icons.person_add_alt_1_outlined,
          title: 'Connection takes two',
          body:
              'Your Traveler reviews your name and chooses to share before you can see a location.',
          color: Color(0xFFEFEDE3),
          fg: SS.muted,
        ),
        Center(
          child: Text(
            'Keep this code private. A new code replaces the previous invitation.',
            textAlign: TextAlign.center,
            style: ssBody(size: 11.5, color: SS.muted),
          ),
        ),
        const SizedBox(height: 10),
        // Demo shortcut until Firestore listens for the Traveler's confirmation (step 2)
        Center(
          child: TextButton(
            onPressed: () => Navigator.pushNamedAndRemoveUntil(
              context,
              '/guardian',
              (r) => false,
            ),
            child: Text(
              'Continue to dashboard',
              style: ssBody(bold: true, color: SS.teal),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 5: TRAVELER PAIRING CONFIRMATION
// ─────────────────────────────────────────────────────────────────────────────

class TravelerPairScreen extends StatefulWidget {
  const TravelerPairScreen({super.key});
  @override
  State<TravelerPairScreen> createState() => _TravelerPairScreenState();
}

class _TravelerPairScreenState extends State<TravelerPairScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String? _guardian; // set when a valid code resolves

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String v) async {
    setState(() => _guardian = null);
    if (v.length == 6) {
      final g = await context.read<AppState>().lookupGuardian(v);
      if (mounted) setState(() => _guardian = g);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _ctrl.text;
    return SSScaffold(
      trailing: 'Traveler setup',
      children: [
        const SSHeader(
          eyebrow: 'Step 2 of 2 · Pair securely',
          title: "Who's in your corner?",
          subtitle:
              "Enter the temporary code from your Guardian. You'll confirm who it belongs to before sharing.",
        ),
        Text('Six-digit sync code', style: ssBody(bold: true, size: 12.5)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Stack(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (i) {
                  final filled = i < code.length;
                  final active = i == code.length && _focus.hasFocus;
                  return Container(
                    width: 48,
                    height: 54,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: filled || active ? SS.teal : SS.line,
                        width: filled || active ? 1.8 : 1,
                      ),
                    ),
                    child: Text(
                      filled ? code[i] : '',
                      style: GoogleFonts.nunito(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  );
                }),
              ),
              // invisible field that captures input
              Positioned.fill(
                child: Opacity(
                  opacity: 0,
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: _onChanged,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SSButton(
          'Scan a QR code instead',
          icon: Icons.qr_code_scanner,
          filled: false,
          onPressed: () =>
              ssToast(context, 'QR scanning: add mobile_scanner in step 2.'),
        ),
        const SizedBox(height: 12),
        if (_guardian != null) ...[
          SSCard(
            color: SS.mint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.done_all, size: 16, color: SS.teal),
                    const SizedBox(width: 6),
                    Text('Code found', style: ssBody(bold: true, size: 13)),
                  ],
                ),
                Text(
                  'Review your Guardian before connecting.',
                  style: ssBody(size: 12, color: SS.muted),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white,
                      child: Text(
                        _guardian!.split(' ').map((w) => w[0]).take(2).join(),
                        style: ssBody(bold: true, size: 12, color: SS.teal),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(_guardian!, style: ssBody(bold: true, size: 16)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${_guardian!.split(' ').first} will see your shared location, journey history and device status. Only connect if this is someone you trust.',
                  style: ssBody(size: 12, color: SS.muted),
                ),
              ],
            ),
          ),
          SSButton(
            'Confirm & share with ${_guardian!.split(' ').first}',
            icon: Icons.shield_outlined,
            onPressed: () async {
              final s = context.read<AppState>();
              await s.confirmPairing();
              if (mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/traveler',
                  (r) => false,
                );
              }
            },
          ),
          Center(
            child: TextButton(
              onPressed: () {
                _ctrl.clear();
                setState(() => _guardian = null);
              },
              child: Text(
                "This isn't my Guardian",
                style: ssBody(bold: true, color: SS.teal),
              ),
            ),
          ),
        ],
        const SSInfo(
          icon: Icons.tune,
          title: 'Your choice, always',
          body:
              'Pause sharing or end this connection from Sharing at any time.',
          color: Color(0xFFEFEDE3),
          fg: SS.muted,
        ),
      ],
    );
  }
}
