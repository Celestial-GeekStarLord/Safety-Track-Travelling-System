// SafeStride - session.dart  (added in build-out step 1)
//
//   SessionGate     -> runs once at launch. Signed in? Sends the user straight to the
//                      right place (Guardian dashboard / Traveler home / pairing) and
//                      restarts tracking for a paired Traveler.
//   PermissionFlow  -> asks for location (while in use, then "always"), notifications and
//                      activity recognition, with a plain-language explanation first.
//
// Requires: flutter pub add permission_handler

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'guardian_screens.dart';
import 'main.dart';
import 'services.dart';
import 'traveller_screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SESSION GATE
// ─────────────────────────────────────────────────────────────────────────────

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late final Future<Widget> _future = _resolve(context.read<AppState>());

  Future<Widget> _resolve(AppState app) async {
    // Demo mode (no Firebase): always start at Welcome.
    if (!backendReady) {
      return const WelcomeScreen();
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const WelcomeScreen();
    }
    try {
      app.email = user.email ?? '';
      app.name = user.displayName ?? '';
      app.signedIn = true;

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final role = doc.data()?['role'] as String?;

      if (role == 'guardian') {
        app.role = UserRole.guardian;
        Repo.instance.registerPushToken(); // keeps the FCM token fresh
        return const GuardianShell();
      }

      if (role == 'traveler') {
        app.role = UserRole.traveler;
        final pairs = await Repo.instance.watchPairsAsTraveler().first;
        if (pairs.isEmpty) {
          return const TravelerConsentScreen(); // signed up but never paired
        }
        await app.restoreTraveler(pairs.first);
        return const TravelerShell();
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
    }
    return const WelcomeScreen();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasData) {
          return snap.data!;
        }
        return const _Splash();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 44, color: SS.teal),
            const SizedBox(height: 10),
            Text('SafeStride', style: ssHeadline().copyWith(fontSize: 24)),
            const SizedBox(height: 18),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: SS.teal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PERMISSIONS
// ─────────────────────────────────────────────────────────────────────────────

class PermissionFlow {
  PermissionFlow._();

  /// Returns true when at least foreground location is granted (enough to start tracking).
  /// "Always" is requested too, because it keeps tracking reliable when the app is closed.
  static Future<bool> requestAll(BuildContext context) async {
    // 1) Location while using the app
    final fg = await Permission.locationWhenInUse.request();
    if (!fg.isGranted) {
      return false;
    }

    // 2) Non-blocking extras: the sharing notification and step counting
    await Permission.notification.request();
    await Permission.activityRecognition.request();

    // 3) Location "all the time" (Android 11+ sends the user to a settings page)
    if (!await Permission.locationAlways.isGranted) {
      if (!context.mounted) {
        return true;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: SS.bg,
          title: Text(
            'Keep sharing when the app is closed',
            style: ssBody(bold: true, size: 18),
          ),
          content: Text(
            'On the next screen, choose "Allow all the time". This lets SafeStride keep your journey up to date even when it is closed. You can turn sharing off at any time.',
            style: ssSub(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: Text(
                'Not now',
                style: ssBody(bold: true, color: SS.muted),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(
                'Continue',
                style: ssBody(bold: true, color: SS.teal),
              ),
            ),
          ],
        ),
      );
      if (go == true) {
        await Permission.locationAlways.request();
      }
    }
    return true;
  }
}
