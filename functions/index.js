// SafeStride - Cloud Functions
//
// pushAlert    -> sends an FCM push to the Guardian whenever an
//                 alert document is created
// lookupCode   -> checks an invite code for the Traveler (guess-limited)
// confirmPairing -> creates the Guardian<->Traveler pair
//                   (guess-limited, atomic)
// cleanupCodes -> deletes expired invite codes once a day
//
// Why pairing runs here: a 6-digit code has only a million possibilities.
// If the app could read the codes directly, a script could try them all
// during the 10 minutes a code is valid. Here every wrong guess is counted
// per account, and after MAX_FAILS the account is blocked for an hour.
// Security rules (firestore.rules) forbid the app from touching codes or
// creating pairs directly, so this is the only way in.
//
// Deploy: firebase deploy --only functions (needs the Blaze plan)

const {onDocumentCreated} = require(
    "firebase-functions/v2/firestore",
);
const {onCall, HttpsError} = require(
    "firebase-functions/v2/https",
);
const {onSchedule} = require(
    "firebase-functions/v2/scheduler",
);
const {initializeApp} = require(
    "firebase-admin/app",
);
const {getFirestore, FieldValue} = require(
    "firebase-admin/firestore",
);
const {getMessaging} = require(
    "firebase-admin/messaging",
);

initializeApp();
const db = getFirestore();

// IMPORTANT: must match your Firestore location
// (Firebase console -> Firestore Database -> Data)
// AND `kFunctionsRegion` in lib/services.dart.
// Examples: 'asia-south1', 'europe-west1'.
// If your Firestore location is multi-region "nam5", use 'us-central1'.
const REGION = "asia-south1";

const MAX_FAILS = 8; // wrong codes allowed per account...
const WINDOW_MS = 60 * 60 * 1000; // ...per hour

// ───────────────────────── guess limiter ─────────────────────────
/**
 * Checks whether a user has exceeded the pairing attempt limit.
 * @param {string} uid Authenticated user's ID.
 * @return {Promise<object>} Throttle reference and current data.
 */
async function checkThrottle(uid) {
  const ref = db.doc(`pairingAttempts/${uid}`);
  const snap = await ref.get();
  const now = Date.now();
  let d = snap.data() || {fails: 0, windowStart: now};
  if (now - d.windowStart > WINDOW_MS) {
    d = {fails: 0, windowStart: now};
  }
  if (d.fails >= MAX_FAILS) {
    throw new HttpsError(
        "resource-exhausted",
        "Too many wrong codes. Please try again in an hour.",
    );
  }
  return {ref, d};
}

/**
 * Records an unsuccessful pairing attempt.
 * @param {object} attemptThrottle reference and attempt data.
 * @return {Promise<void>} Resolves when the attempt is saved.
 */
async function recordFail({ref, d}) {
  await ref.set({
    fails: d.fails + 1,
    windowStart: d.windowStart,
  });
}

/**
 * Validates and returns a six-digit pairing code.
 * @param {object} data Callable function request data.
 * @return {string} Validated pairing code.
 */
function readCode(data) {
  const code = String((data && data.code) || "");
  if (!/^\d{6}$/.test(code)) {
    throw new HttpsError(
        "invalid-argument",
        "Enter the 6-digit code.",
    );
  }
  return code;
}

// ───────────────────────── pairing ─────────────────────────

exports.lookupCode = onCall({region: REGION}, async (req) => {
  if (!req.auth) {
    throw new HttpsError(
        "unauthenticated",
        "Please sign in first.",
    );
  }
  const code = readCode(req.data);
  const t = await checkThrottle(req.auth.uid);

  const snap = await db.doc(`pairingCodes/${code}`).get();
  const c = snap.data();
  if (!c || c.used || c.expiresAt < Date.now()) {
    await recordFail(t);
    return {guardianName: null};
  }
  return {guardianName: c.guardianName};
});

exports.confirmPairing = onCall({region: REGION}, async (req) => {
  if (!req.auth) {
    throw new HttpsError(
        "unauthenticated",
        "Please sign in first.",
    );
  }
  const travelerUid = req.auth.uid;
  const code = readCode(req.data);
  const name = String(
      (req.data && req.data.travelerName) || "Traveler",
  ).slice(0, 80);
  const phone = String(
      (req.data && req.data.travelerPhone) || "",
  ).slice(0, 30);
  const t = await checkThrottle(travelerUid);

  const codeRef = db.doc(`pairingCodes/${code}`);
  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(codeRef);
      const c = snap.data();
      if (!c || c.used || c.expiresAt < Date.now()) {
        throw new HttpsError(
            "failed-precondition",
            "That code is invalid or has expired. Ask for a new one.",
        );
      }
      if (c.guardianUid === travelerUid) {
        throw new HttpsError(
            "failed-precondition",
            "You cannot pair with yourself.",
        );
      }
      // Deterministic id: security rules use it to check that a pair
      // exists, and pairing the same two people twice simply
      // refreshes the same record.
      const pairRef = db.doc(`pairs/${c.guardianUid}_${travelerUid}`);
      tx.set(pairRef, {
        guardianUid: c.guardianUid,
        guardianName: c.guardianName,
        travelerUid,
        travelerName: name,
        travelerPhone: phone,
        members: [c.guardianUid, travelerUid],
        sharingPaused: false,
        createdAt: Date.now(),
      });
      tx.update(codeRef, {used: true, usedBy: travelerUid});
      return {pairId: pairRef.id, guardianName: c.guardianName};
    });
  } catch (e) {
    if (
      e instanceof HttpsError &&
      e.code === "failed-precondition"
    ) {
      await recordFail(t);
    }
    throw e;
  }
});

exports.cleanupCodes = onSchedule(
    {schedule: "every 24 hours", region: REGION},
    async () => {
      const old = await db
          .collection("pairingCodes")
          .where("expiresAt", "<", Date.now() - 60 * 60 * 1000)
          .limit(400)
          .get();
      const batch = db.batch();
      old.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
    },
);

// ───────────────────────── push alerts ─────────────────────────
/**
 * Determines whether notifications are currently in quiet hours.
 * @param {object} p Notification preferences.
 * @param {Date} now Current date and time.
 * @return {boolean} Whether quiet hours are active.
 */
function inQuietHours(p, now) {
  if (!p.quietOn) return false;
  const utcMin = now.getUTCHours() * 60 + now.getUTCMinutes();
  const m = (((utcMin + (p.tzOffset || 0)) % 1440) + 1440) % 1440;
  const start = p.quietStart ?? 22 * 60;
  const end = p.quietEnd ?? 7 * 60;
  return start <= end ? m >= start && m < end : m >= start || m < end;
}

exports.pushAlert = onDocumentCreated(
    {document: "alerts/{alertId}", region: REGION},
    async (event) => {
      const snap = event.data;
      if (!snap) return;
      const a = snap.data();

      const userRef = db.doc(`users/${a.guardianUid}`);
      const user = await userRef.get();
      const token = user.get("fcmToken");
      if (!token) return; // Guardian signed out or never allowed

      const p = user.get("prefs") || {};
      if (p.push === false) return;
      const typeAllowed = {
        unexpectedStop: p.unexpected !== false,
        left: p.boundary !== false,
        distanceThreshold: p.distance !== false,
        arrived: true,
      }[a.kind];
      if (typeAllowed === false) return;
      if (inQuietHours(p, new Date())) return;

      try {
        await getMessaging().send({
          token,
          notification: {title: a.title, body: a.body},
          data: {
            alertId: event.params.alertId,
            kind: String(a.kind),
            travelerUid: String(a.travelerUid),
          },
          android: {
            priority: "high",
            // 'alerts' is the high-importance channel in MainActivity.kt.
            // Same tag per alert = the same alert never shows twice.
            notification: {
              channelId: "alerts",
              tag: event.params.alertId,
            },
          },
        });
      } catch (err) {
        if (
          err.code === "messaging/registration-token-not-registered" ||
          err.code === "messaging/invalid-registration-token"
        ) {
          await userRef.update({fcmToken: FieldValue.delete()});
        } else {
          console.error("Push failed", err);
        }
      }
    },
);
