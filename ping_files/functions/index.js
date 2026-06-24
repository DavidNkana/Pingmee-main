const {setGlobalOptions} = require("firebase-functions/v2");
const {onRequest, onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const admin = require("firebase-admin");
const {StreamChat} = require("stream-chat");
const stream = require("getstream");

if (!admin.apps.length) {
  admin.initializeApp();
}

const GOOGLE_PLACES_API_KEY = defineSecret("GOOGLE_PLACES_API_KEY");
const STREAM_API_KEY = defineSecret("STREAM_API_KEY");
const STREAM_API_SECRET = defineSecret("STREAM_API_SECRET");

const REGION = "us-central1";

const AUTOCOMPLETE_FIELD_MASK = [
  "suggestions.placePrediction.placeId",
  "suggestions.placePrediction.text.text",
  "suggestions.placePrediction.structuredFormat.mainText.text",
  "suggestions.placePrediction.structuredFormat.secondaryText.text",
].join(",");

const PLACE_DETAILS_FIELD_MASK = [
  "id",
  "displayName",
  "formattedAddress",
  "location",
].join(",");

setGlobalOptions({maxInstances: 10});

/**
 * Safely converts a value to a trimmed string.
 *
 * @param {*} value Any incoming value.
 * @return {string} A trimmed string or an empty string.
 */
function cleanString(value) {
  if (typeof value !== "string") return "";
  return value.trim();
}

/**
 * Creates a Stream server client using Firebase secrets.
 *
 * @return {StreamChat} Stream Chat server client.
 */
function getStreamClient() {
  return StreamChat.getInstance(
      STREAM_API_KEY.value(),
      STREAM_API_SECRET.value(),
  );
}

/**
 * Deletes a Stream reaction and ignores already-deleted reactions.
 *
 * @param {object} client Stream Feeds client.
 * @param {string} reactionId Reaction ID.
 * @return {Promise<void>} Resolves when reaction is gone.
 */
async function safeDeleteReaction(client, reactionId) {
  if (!reactionId) return;

  try {
    await client.reactions.delete(reactionId);
  } catch (error) {
    const message = cleanString(error.message).toLowerCase();

    const alreadyGone =
      error.statusCode === 404 ||
      error.code === 16 ||
      message.includes("reaction does not exist") ||
      message.includes("does not exist") ||
      message.includes("not found");

    if (!alreadyGone) {
      throw error;
    }
  }
}

/**
 * Removes a Stream activity and ignores already-deleted activities.
 *
 * @param {object} feed Stream feed.
 * @param {string} activityId Stream activity ID.
 * @return {Promise<void>} Resolves when activity is gone.
 */
async function safeRemoveActivity(feed, activityId) {
  if (!activityId) return;

  try {
    await feed.removeActivity(activityId);
  } catch (error) {
    const message = cleanString(error.message).toLowerCase();

    const alreadyGone =
      error.statusCode === 404 ||
      error.code === 16 ||
      message.includes("does not exist") ||
      message.includes("not found");

    if (!alreadyGone) {
      throw error;
    }
  }
}

/**
 * Extracts a Firestore moment ID from a Stream foreign_id.
 *
 * @param {string} foreignId Stream foreign ID like moment:abc.
 * @return {string} Firestore moment ID or empty string.
 */
function momentIdFromForeignId(foreignId) {
  const value = cleanString(foreignId);
  if (!value.startsWith("moment:")) return "";
  return value.replace("moment:", "").trim();
}

/**
 * Creates a Stream Activity Feeds client using Firebase secrets.
 *
 * @return {object} Stream Feeds server client.
 */
function getStreamFeedsClient() {
  return stream.connect(
      STREAM_API_KEY.value(),
      STREAM_API_SECRET.value(),
  );
}

/**
 * Extracts hashtags from Moment text.
 *
 * @param {string} text Moment text.
 * @return {string[]} Clean lowercase hashtags without #.
 */
function extractHashtags(text) {
  const matches = text.match(/#[A-Za-z0-9_]{2,40}/g) || [];
  const seen = new Set();
  const out = [];

  for (const raw of matches) {
    const tag = raw
        .replace("#", "")
        .trim()
        .toLowerCase();

    if (tag && !seen.has(tag)) {
      seen.add(tag);
      out.push(tag);
    }
  }

  return out.slice(0, 12);
}

/**
 * Follows a Stream feed and ignores duplicate follow errors.
 *
 * @param {object} sourceFeed Source feed object.
 * @param {string} targetSlug Target feed group.
 * @param {string} targetUserId Target feed user id.
 * @return {Promise<void>} Resolves when follow exists.
 */
async function safeFollowFeed(sourceFeed, targetSlug, targetUserId) {
  try {
    await sourceFeed.follow(targetSlug, targetUserId);
  } catch (error) {
    const message = cleanString(error.message).toLowerCase();

    const alreadyFollowing =
      message.includes("already") ||
      message.includes("duplicate") ||
      message.includes("follow relation already exists") ||
      error.statusCode === 409;

    if (!alreadyFollowing) {
      throw error;
    }
  }
}

/**
 * Converts Firestore timestamp-like values to JS Date.
 *
 * @param {*} value Firestore Timestamp, Date, string, or null.
 * @return {?Date} JS Date or null.
 */
function dateFromValue(value) {
  if (!value) return null;

  if (typeof value.toDate === "function") {
    return value.toDate();
  }

  if (value instanceof Date) {
    return value;
  }

  if (typeof value === "string") {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  return null;
}

/**
 * Encodes Stream CID for the per-user chatPrefs doc id.
 *
 * @param {string} cid Stream channel cid.
 * @return {string} Encoded Firestore document ID.
 */
function chatPrefsDocIdForCid(cid) {
  return encodeURIComponent(cid);
}

/**
 * Adds days to a date.
 *
 * @param {Date} date Base date.
 * @param {number} days Number of days.
 * @return {Date} New date.
 */
function addDays(date, days) {
  return new Date(date.getTime() + days * 24 * 60 * 60 * 1000);
}

/**
 * Reads the public user profile used by Stream Chat.
 *
 * @param {string} uid Firebase Auth user ID.
 * @return {Promise<object>} Public Stream user payload.
 */
async function getPublicUser(uid) {
  const snap = await admin.firestore().collection("users").doc(uid).get();
  const data = snap.exists ? snap.data() : {};

  const firstName = cleanString(data.firstName);
  const lastName = cleanString(data.lastName);
  const combinedName = [firstName, lastName]
      .filter((part) => part)
      .join(" ")
      .trim();

  const name =
    cleanString(data.fullName) ||
    cleanString(data.displayName) ||
    cleanString(data.name) ||
    combinedName ||
    cleanString(data.username) ||
    "Pingmee user";

  const image =
    cleanString(data.photoUrl) ||
    cleanString(data.photoURL) ||
    cleanString(data.profilePhotoUrl) ||
    cleanString(data.avatarUrl) ||
    cleanString(data.image);

  return {
    id: uid,
    name,
    image,
    fullName: name,
    displayName: name,
    photoUrl: image,
    firebaseUid: uid,
  };
}

/**
 * Creates a Stream channel and ignores duplicate channel errors.
 *
 * @param {object} channel Stream channel object.
 * @return {Promise<void>} Resolves when the channel exists.
 */
async function safeCreateChannel(channel) {
  try {
    await channel.create();
  } catch (error) {
    const message = cleanString(error.message).toLowerCase();

    const alreadyExists =
      message.includes("already exists") ||
      message.includes("duplicate") ||
      error.code === 16;

    if (!alreadyExists) {
      throw error;
    }
  }
}

/**
 * Gets the first usable visual from a ping media list.
 *
 * @param {object} ping Firestore ping data.
 * @return {string} First image/video thumbnail URL or empty string.
 */
function firstPingMediaImage(ping) {
  const media = Array.isArray(ping.media) ? ping.media : [];

  for (const item of media) {
    const m = item || {};
    const type = cleanString(m.type).toLowerCase();

    const thumbUrl = cleanString(m.thumbUrl);
    const url = cleanString(m.url);

    if (type === "image") {
      if (thumbUrl) return thumbUrl;
      if (url) return url;
    }

    if (type === "video") {
      if (thumbUrl) return thumbUrl;
      if (url) return url;
    }
  }

  return "";
}

// -----------------------------------------------------------------------------
// GOOGLE PLACES
// -----------------------------------------------------------------------------

exports.placesAutocomplete = onRequest(
    {
      region: REGION,
      secrets: [GOOGLE_PLACES_API_KEY],
    },
    async (req, res) => {
      try {
        if (req.method !== "GET") {
          return res.status(405).json({error: "Method not allowed"});
        }

        const input = String(req.query.input || "").trim();
        const sessionToken = String(req.query.sessionToken || "").trim();
        const lat = Number(req.query.lat);
        const lng = Number(req.query.lng);
        const radiusMeters = Number(req.query.radiusMeters);

        if (input.length < 2) {
          return res.status(200).json({predictions: []});
        }

        const apiKey = GOOGLE_PLACES_API_KEY.value();

        const body = {
          input,
          sessionToken: sessionToken || undefined,
        };

        if (
          Number.isFinite(lat) &&
          Number.isFinite(lng) &&
          Number.isFinite(radiusMeters) &&
          radiusMeters > 0
        ) {
          body.locationBias = {
            circle: {
              center: {
                latitude: lat,
                longitude: lng,
              },
              radius: Math.min(radiusMeters, 50000),
            },
          };
        }

        const googleRes = await fetch(
            "https://places.googleapis.com/v1/places:autocomplete",
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-Goog-Api-Key": apiKey,
                "X-Goog-FieldMask": AUTOCOMPLETE_FIELD_MASK,
              },
              body: JSON.stringify(body),
            },
        );

        const data = await googleRes.json();

        if (!googleRes.ok) {
          return res.status(googleRes.status).json({
            error: "Google Places request failed",
            details: data,
          });
        }

        const predictions = (data.suggestions || [])
            .map((item) => item.placePrediction)
            .filter(Boolean)
            .map((place) => ({
              placeId: place.placeId || "",
              text: (place.text && place.text.text) || "",
              mainText: (
                place.structuredFormat &&
                place.structuredFormat.mainText &&
                place.structuredFormat.mainText.text
              ) || "",
              secondaryText: (
                place.structuredFormat &&
                place.structuredFormat.secondaryText &&
                place.structuredFormat.secondaryText.text
              ) || "",
            }));

        return res.status(200).json({predictions});
      } catch (error) {
        console.error("placesAutocomplete failed:", error);
        return res.status(500).json({error: "Internal server error"});
      }
    },
);

exports.placeDetails = onRequest(
    {
      region: REGION,
      secrets: [GOOGLE_PLACES_API_KEY],
    },
    async (req, res) => {
      try {
        if (req.method !== "GET") {
          return res.status(405).json({error: "Method not allowed"});
        }

        const placeId = String(req.query.placeId || "").trim();

        if (!placeId) {
          return res.status(400).json({error: "Missing placeId"});
        }

        const apiKey = GOOGLE_PLACES_API_KEY.value();

        const googleRes = await fetch(
            `https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`,
            {
              method: "GET",
              headers: {
                "X-Goog-Api-Key": apiKey,
                "X-Goog-FieldMask": PLACE_DETAILS_FIELD_MASK,
              },
            },
        );

        const data = await googleRes.json();

        if (!googleRes.ok) {
          return res.status(googleRes.status).json({
            error: "Google Place Details request failed",
            details: data,
          });
        }

        return res.status(200).json({
          placeId: data.id || "",
          name: (data.displayName && data.displayName.text) || "",
          formattedAddress: data.formattedAddress || "",
          lat: (data.location && data.location.latitude) || null,
          lng: (data.location && data.location.longitude) || null,
        });
      } catch (error) {
        console.error("placeDetails failed:", error);
        return res.status(500).json({error: "Internal server error"});
      }
    },
);

// -----------------------------------------------------------------------------
// STREAM CHAT
// -----------------------------------------------------------------------------

exports.getStreamUserToken = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const client = getStreamClient();
      const streamUser = await getPublicUser(uid);

      await client.upsertUser(streamUser);

      const token = client.createToken(uid);

      return {
        apiKey: STREAM_API_KEY.value(),
        token,
        userId: uid,
        name: streamUser.name,
        image: streamUser.image,
      };
    },
);

// -----------------------------------------------------------------------------
// STREAM FEEDS
// -----------------------------------------------------------------------------

exports.getStreamFeedsUserToken = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const client = getStreamFeedsClient();
      const streamUser = await getPublicUser(uid);

      await client.user(uid).create(
          {
            name: streamUser.name,
            image: streamUser.image,
            fullName: streamUser.name,
            displayName: streamUser.name,
            photoUrl: streamUser.image,
            firebaseUid: uid,
          },
          {
            get_or_create: true,
          },
      );

      const token = client.createUserToken(uid);

      return {
        apiKey: STREAM_API_KEY.value(),
        token,
        userId: uid,
        name: streamUser.name,
        image: streamUser.image,
      };
    },
);

exports.bootstrapMyFeeds = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const client = getStreamFeedsClient();
      const timelineFeed = client.feed("timeline", uid);

      // User should see their own Moments in their own timeline.
      await safeFollowFeed(timelineFeed, "user", uid);

      return {
        ok: true,
        feeds: {
          user: `user:${uid}`,
          timeline: `timeline:${uid}`,
          notification: `notification:${uid}`,
        },
      };
    },
);

exports.syncMyFeedFollows = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const db = admin.firestore();
      const client = getStreamFeedsClient();
      const timelineFeed = client.feed("timeline", uid);

      const followUids = new Set();
      followUids.add(uid);

      const friendsSnap = await db
          .collection("users")
          .doc(uid)
          .collection("friends")
          .limit(500)
          .get();

      friendsSnap.docs.forEach((doc) => {
        const data = doc.data() || {};
        const friendUid =
          cleanString(data.uid) ||
          cleanString(data.friendUid) ||
          cleanString(data.userId) ||
          doc.id;

        const status = cleanString(data.status).toLowerCase();

        if (
          friendUid &&
          friendUid !== uid &&
          (
            !status ||
            status === "accepted" ||
            status === "active" ||
            status === "connected" ||
            status === "friend"
          )
        ) {
          followUids.add(friendUid);
        }
      });

      // Optional compatibility if you later renamed friends to connections.
      const connectionsSnap = await db
          .collection("users")
          .doc(uid)
          .collection("connections")
          .limit(500)
          .get()
          .catch(() => null);

      if (connectionsSnap && !connectionsSnap.empty) {
        connectionsSnap.docs.forEach((doc) => {
          const data = doc.data() || {};
          const connectionUid =
            cleanString(data.uid) ||
            cleanString(data.connectionUid) ||
            cleanString(data.userId) ||
            doc.id;

          const status = cleanString(data.status).toLowerCase();

          if (
            connectionUid &&
            connectionUid !== uid &&
            (
              !status ||
              status === "accepted" ||
              status === "active" ||
              status === "connected" ||
              status === "friend"
            )
          ) {
            followUids.add(connectionUid);
          }
        });
      }

      const followed = [];
      const failed = [];

      for (const targetUid of followUids) {
        try {
          await safeFollowFeed(timelineFeed, "user", targetUid);
          followed.push(targetUid);
        } catch (error) {
          failed.push({
            uid: targetUid,
            message: error && error.message,
          });
        }
      }

      console.log("syncMyFeedFollows complete", {
        uid,
        followedCount: followed.length,
        failedCount: failed.length,
      });

      return {
        ok: true,
        timeline: `timeline:${uid}`,
        followedCount: followed.length,
        followed,
        failed,
      };
    },
);

exports.createTestMoment = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const rawText = cleanString(request.data && request.data.text);
      const text = rawText ||
        "Testing my first Pingmee Moment. If this works, the feed is alive.";

      const db = admin.firestore();
      const client = getStreamFeedsClient();

      const streamUser = await getPublicUser(uid);
      const momentRef = db.collection("moments").doc();
      const momentId = momentRef.id;

      const nowIso = new Date().toISOString();

      const activity = {
        actor: `user:${uid}`,
        verb: "moment",
        object: `moment:${momentId}`,
        foreign_id: `moment:${momentId}`,
        time: nowIso,

        type: "moment",
        text,

        authorUid: uid,
        authorName: streamUser.name,
        authorPhotoUrl: streamUser.image,

        visibility: "public",
        media: [],
        hashtags: ["pingmee", "test"],

        pingId: null,
        eventId: null,

        source: "pingmee_test",
      };

      try {
        const userFeed = client.feed("user", uid);

        // Make sure the user's own timeline follows their user feed too.
        const timelineFeed = client.feed("timeline", uid);
        await safeFollowFeed(timelineFeed, "user", uid);

        const streamActivity = await userFeed.addActivity(activity);

        await momentRef.set({
          streamActivityId: cleanString(streamActivity.id),
          streamForeignId: `moment:${momentId}`,

          creatorId: uid,
          text,

          media: [],
          hashtags: ["pingmee", "test"],

          visibility: "public",

          pingId: null,
          eventId: null,

          status: "active",

          likeCount: 0,
          commentCount: 0,
          shareCount: 0,
          reportCount: 0,

          source: "pingmee_test",

          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        console.log("createTestMoment complete", {
          uid,
          momentId,
          streamActivityId: streamActivity.id,
        });

        return {
          ok: true,
          momentId,
          streamActivityId: streamActivity.id || "",
          feed: `user:${uid}`,
          text,
        };
      } catch (error) {
        console.error("createTestMoment failed", {
          uid,
          momentId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not create test moment.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

// ============================================================================
// v78: _scrapeLinkPreview - shared helper used by both the
// public scrapeLinkPreview cloud function and the
// createMomentV2 hook. Validates URL, fetches with timeout,
// parses Open Graph + fallback meta tags, resolves relative
// og:image URLs, and returns a compact preview object.
// ============================================================================
function _scrapeLinkPreview(rawUrl) {
  return (async () => {
    const url = cleanString(rawUrl);
    if (!url) return null;
    let parsed;
    try {
      parsed = new URL(url);
    } catch (_) {
      return null;
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return null;
    }
    // SSRF guard: refuse private / loopback / link-local hosts.
    // Stream's link preview is meant for public URLs only.
    const host = (parsed.hostname || "").toLowerCase();
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "0.0.0.0" ||
      host.startsWith("10.") ||
      host.startsWith("192.168.") ||
      /^172\.(1[6-9]|2\d|3[0-1])\./.test(host) ||
      host.endsWith(".local")
    ) {
      console.log("v78 _scrapeLinkPreview blocked private host:", host);
      return null;
    }
    // Fetch with 5s timeout, 1MB cap, follow up to 3 redirects.
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 5000);
    let resp;
    try {
      resp = await fetch(url, {
        signal: ac.signal,
        redirect: "follow",
        headers: {
          "User-Agent":
            "Mozilla/5.0 (PingmeeBot/1.0; +https://pingmee.app)",
          "Accept":
            "text/html,application/xhtml+xml",
        },
      });
    } catch (e) {
      console.log("v78 _scrapeLinkPreview fetch failed:", url, e && e.message);
      clearTimeout(timer);
      return null;
    }
    clearTimeout(timer);
    if (!resp || !resp.ok) {
      console.log("v78 _scrapeLinkPreview non-2xx:", resp && resp.status, url);
      return null;
    }
    const ctype = (resp.headers.get("content-type") || "").toLowerCase();
    if (!ctype.includes("text/html") && !ctype.includes("xml")) {
      return null;
    }
    // Cap body size at 1MB.
    const body = await resp.text();
    if (body.length > 1 * 1024 * 1024) {
      return null;
    }
    // Decode a few HTML entities (the ones we actually display).
    const decodeEntities = (s) =>
      cleanString(s)
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'")
        .replace(/&nbsp;/g, " ")
        .replace(/&#(\d+);/g, (_, n) => {
          const code = Number(n);
          return Number.isFinite(code) ? String.fromCharCode(code) : "";
        });
    // Extract the first <meta> tag whose attributes match the
    // given key/value pairs. Returns the content or "".
    const metaContent = (html, attrs) => {
      const entries = Object.entries(attrs);
      for (const [k, v] of entries) {
        // Build a regex that matches `<meta ... k="v" ... content="..."`.
        // We accept the attributes in any order by matching both
        // possible positions in a single regex.
        const re = new RegExp(
          "<meta[^>]*\\b" + k + "=\\s*[\"']" +
            v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") +
            "[\"'][^>]*content=\\s*[\"']([^\"']+)[\"']",
          "i"
        );
        const m = body.match(re);
        if (m && m[1]) return decodeEntities(m[1]);
      }
      return "";
    };
    const title = (() => {
      const og = metaContent(body, { property: "og:title" });
      if (og) return og;
      const t = body.match(/<title[^>]*>([^<]+)<\/title>/i);
      return t && t[1] ? decodeEntities(t[1]) : "";
    })();
    const description = (() => {
      const og = metaContent(body, { property: "og:description" });
      if (og) return og;
      return metaContent(body, { name: "description" });
    })();
    const siteName = metaContent(body, { property: "og:site_name" });
    const rawImage = (() => {
      const og = metaContent(body, { property: "og:image" });
      if (og) return og;
      const tw = metaContent(body, { name: "twitter:image" });
      if (tw) return tw;
      const link = body.match(
        /<link[^>]*rel=["'](?:apple-touch-icon|icon)["'][^>]*href=["']([^"']+)/i
      );
      return link && link[1] ? link[1] : "";
    })();
    // Resolve relative image URL against the page URL.
    let image = "";
    if (rawImage) {
      try {
        image = new URL(rawImage, resp.url || url).toString();
      } catch (_) {
        image = rawImage;
      }
    }
    if (!title && !description && !image) {
      return null;
    }
    // Truncate fields to sane bounds for the client.
    const trim = (s, n) =>
      (s && s.length > n ? s.substring(0, n - 1) + "\u2026" : s);
    return {
      url: resp.url || url,
      title: trim(title, 200),
      description: trim(description, 400),
      image,
      siteName: trim(siteName, 80),
    };
  })().catch((e) => {
    console.log("v78 _scrapeLinkPreview exception:", e && e.message);
    return null;
  });
}

exports.scrapeLinkPreview = onCall(
    {
      region: REGION,
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in required.");
      }
      const url = cleanString(request.data && request.data.url);
      if (!url) {
        throw new HttpsError("invalid-argument", "url is required.");
      }
      const preview = await _scrapeLinkPreview(url);
      return { ok: true, preview: preview || null };
    },
);

exports.createMomentV2 = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const text = cleanString(request.data && request.data.text);
      const visibility = cleanString(
          request.data && request.data.visibility,
      ) || "public";

      const allowedVisibility = [
        "public",
        "connections",
        "verified",
      ];

      const rawMedia = Array.isArray(request.data && request.data.media) ?
        request.data.media :
        [];

      const media = rawMedia
          .slice(0, 4)
          .map((item) => {
            const data = item || {};
            const type = cleanString(data.type).toLowerCase();
            const url = cleanString(data.url);
            const thumbUrl = cleanString(data.thumbUrl);
            const name = cleanString(data.name);
            const contentType = cleanString(data.contentType);

            return {
              type,
              url,
              thumbUrl,
              name,
              contentType,
            };
          })
          .filter((item) => {
            const isImage =
              item.type === "image" &&
              item.contentType.startsWith("image/");

            const isVideo =
              item.type === "video" &&
              item.contentType.startsWith("video/");

            return item.url && (isImage || isVideo);
          });

      if (!text && media.length === 0) {
        throw new HttpsError(
            "invalid-argument",
            "Moment text or media is required.",
        );
      }

      if (text.length > 500) {
        throw new HttpsError(
            "invalid-argument",
            "Moment text is too long.",
        );
      }

      if (!allowedVisibility.includes(visibility)) {
        throw new HttpsError(
            "invalid-argument",
            "Invalid Moment visibility.",
        );
      }

      const pingId = cleanString(request.data && request.data.pingId);
      const eventId = cleanString(request.data && request.data.eventId);

      const locationData =
        request.data && typeof request.data.location === "object" ?
          request.data.location :
          {};

      const locationLabel = cleanString(locationData.locationLabel);
      const city = cleanString(locationData.city);
      const country = cleanString(locationData.country);

      const lat = Number(locationData.lat);
      const lng = Number(locationData.lng);

      const hasValidLocation =
        Number.isFinite(lat) &&
        Number.isFinite(lng) &&
        lat >= -90 &&
        lat <= 90 &&
        lng >= -180 &&
        lng <= 180;

      const db = admin.firestore();
      const client = getStreamFeedsClient();

      const streamUser = await getPublicUser(uid);
      const momentRef = db.collection("moments").doc();
      const momentId = momentRef.id;

      const hashtags = extractHashtags(text);
      const nowIso = new Date().toISOString();

      const activity = {
        actor: `user:${uid}`,
        verb: "moment",
        object: `moment:${momentId}`,
        foreign_id: `moment:${momentId}`,
        time: nowIso,

        type: "moment",
        text,

        authorUid: uid,
        authorName: streamUser.name,
        authorPhotoUrl: streamUser.image,

        visibility,
        media,
        hashtags,

        locationLabel,
        city,
        country,
        lat: hasValidLocation ? lat : null,
        lng: hasValidLocation ? lng : null,

        pingId: pingId || null,
        eventId: eventId || null,

        source: "pingmee_moment",
      };

      // v78: detect the first http(s) URL in the moment text
      // and scrape its Open Graph metadata. Stored on BOTH the
      // Stream activity (so the OG preview travels with the
      // activity payload, like a real Stream chat link preview)
      // AND the Firestore moment doc (so the frontend can
      // render it from the moment card without re-scraping).
      const urlMatch = text.match(
        /https?:\/\/[^\s<>"\u201d]+/i,
      );
      let linkPreview = null;
      if (urlMatch) {
        try {
          linkPreview = await _scrapeLinkPreview(urlMatch[0]);
        } catch (e) {
          console.log("v78 createMomentV2 linkPreview failed:", e && e.message);
        }
        if (linkPreview) {
          activity.linkPreview = linkPreview;
        }
      }

      try {
        const userFeed = client.feed("user", uid);
        const timelineFeed = client.feed("timeline", uid);

        await safeFollowFeed(timelineFeed, "user", uid);

        const streamActivity = await userFeed.addActivity(activity);

        await momentRef.set({
          streamActivityId: cleanString(streamActivity.id),
          streamForeignId: `moment:${momentId}`,

          creatorId: uid,
          text,

          media,
          mediaCount: media.length,
          hashtags,

          visibility,

          locationLabel,
          city,
          country,
          lat: hasValidLocation ? lat : null,
          lng: hasValidLocation ? lng : null,

          pingId: pingId || null,
          eventId: eventId || null,

          // v78: Open Graph link preview, or null. Mirrors the
          // Stream activity's linkPreview so the renderer can
          // stay agnostic about which source it reads.
          linkPreview: linkPreview || null,

          status: "active",

          likeCount: 0,
          commentCount: 0,
          savedCount: 0,
          repostCount: 0,
          shareCount: 0,
          reportCount: 0,

          source: "pingmee_moment",

          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        console.log("createMoment complete", {
          uid,
          momentId,
          streamActivityId: streamActivity.id,
        });

        return {
          ok: true,
          momentId,
          streamActivityId: streamActivity.id || "",
          feed: `user:${uid}`,
          text,
          hashtags,
          mediaCount: media.length,
          media,
          // v83: echo the scraped linkPreview (or client-supplied
          // one) back to the composer so the UI can confirm the
          // preview was generated immediately, without waiting
          // for the feed to reload.
          linkPreview: linkPreview || null,
          debugLocation: {
            locationLabel,
            city,
            country,
            lat: hasValidLocation ? lat : null,
            lng: hasValidLocation ? lng : null,
          },
        };
      } catch (error) {
        console.error("createMoment failed", {
          uid,
          momentId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not create Moment.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.loadMyTimelineMoments = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const rawLimit = Number(request.data && request.data.limit);
      const limit = Number.isFinite(rawLimit) ?
        Math.min(Math.max(rawLimit, 1), 30) :
        15;

      const rawOffset = Number(request.data && request.data.offset);
      const offset = Number.isFinite(rawOffset) && rawOffset >= 0 ?
        Math.floor(rawOffset) :
        0;
      const isPagination = offset > 0;

      try {
        const client = getStreamFeedsClient();
        const timelineFeed = client.feed("timeline", uid);

        // Make sure own posts are visible in own timeline.
        await safeFollowFeed(timelineFeed, "user", uid);

        const getParams = {
          limit,
          offset,
          reactions: {
            own: true,
            counts: true,
            recent: true,
          },
          user_id: uid,
        };

        const response = await timelineFeed.get(getParams);

        const results = Array.isArray(response.results) ?
          response.results :
          [];

        const hasMore = results.length >= limit;
        const nextOffset = offset + results.length;

        // Identify reposts that need originalMedia backfilled from
        // the original activity (for old reposts where originalMedia
        // was not yet embedded in GetStream activity data).
        const repostNeedsMedia = [];
        for (let i = 0; i < results.length; i++) {
          const a = results[i] || {};
          if (
            (a.type === "repost" || a.type === "quote") &&
            a.originalActivityId &&
            (!Array.isArray(a.originalMedia) || a.originalMedia.length === 0)
          ) {
            repostNeedsMedia.push({
              index: i,
              originalActivityId: a.originalActivityId,
            });
          }
        }

        // Fetch original activities to backfill missing originalMedia.
        if (repostNeedsMedia.length > 0) {
          const ids = repostNeedsMedia.map((r) => r.originalActivityId);
          let originalActivities = [];
          try {
            const actResult = await client.getActivities({ids});
            originalActivities =
              actResult && actResult.results &&
              Array.isArray(actResult.results) ?
              actResult.results :
              [];
          } catch (err) {
            console.warn("Failed to backfill originalMedia:", err.message);
          }
          // DEBUG: Log backfill details
          console.log("DEBUG backfill repostNeedsMedia count:", repostNeedsMedia.length);
          for (const repost of repostNeedsMedia) {
            const orig = originalActivities.find(
                (a) => a && a.id === repost.originalActivityId,
            );
            console.log("DEBUG backfill repost:", repost.originalActivityId, "orig found:", !!orig, "orig.media:", orig && orig.media ? orig.media.length : "none");
            const a = results[repost.index];
            if (orig) {
              // Backfill originalMedia if missing
              if ((!a.originalMedia || a.originalMedia.length === 0) && Array.isArray(orig.media) && orig.media.length > 0) {
                a.originalMedia = orig.media;
                console.log("DEBUG backfill applied media to repost index:", repost.index);
              }
              // Backfill originalText if missing
              if (!a.originalText && orig.text) {
                a.originalText = orig.text;
                console.log("DEBUG backfill applied text to repost index:", repost.index);
              }
            }
          }
        }

        // Fetch repost counts from Firestore (one batched getAll). GetStream
        // does not track reposts as a reaction — repostCount is maintained
        // by createMomentRepost on the moments/{id} Firestore document —
        // so we read it from there and merge it into each activity below.
        const repostCountByFirestoreId = {};
        try {
          const firestoreIds = [];
          const seen = new Set();
          for (const item of results) {
            const foreignId = cleanString(item && item.foreign_id);
            if (foreignId.startsWith("moment:")) {
              const id = foreignId.substring(7);
              if (id && !seen.has(id)) {
                seen.add(id);
                firestoreIds.push(id);
              }
            }
          }
          if (firestoreIds.length > 0) {
            const db = admin.firestore();
            const refs = firestoreIds.map((id) =>
              db.collection("moments").doc(id));
            const snaps = await db.getAll(...refs);
            for (const snap of snaps) {
              const data = snap.exists ? snap.data() : null;
              const count = data && typeof data.repostCount === "number" ?
                data.repostCount :
                0;
              repostCountByFirestoreId[snap.id] = count;
            }
          }
        } catch (err) {
          console.warn("loadMyTimelineMoments: failed to fetch repost counts:",
              err && err.message);
        }

        const activities = results.map((item) => {
          const activity = item || {};

          const reactionCounts = activity.reaction_counts || {};
          const ownReactions = activity.own_reactions || {};

          const ownLikes = Array.isArray(ownReactions.like) ?
            ownReactions.like :
            [];

          const ownBookmarks = Array.isArray(ownReactions.bookmark) ?
            ownReactions.bookmark :
            [];

          const parsedLat = Number(activity.lat);
          const parsedLng = Number(activity.lng);

          const activityLat = Number.isFinite(parsedLat) ? parsedLat : null;
          const activityLng = Number.isFinite(parsedLng) ? parsedLng : null;

          return {
            id: cleanString(activity.id),
            actor: cleanString(activity.actor),
            verb: cleanString(activity.verb),
            object: cleanString(activity.object),
            foreignId: cleanString(activity.foreign_id),
            time: cleanString(activity.time),

            type: cleanString(activity.type),
            text: cleanString(activity.text),

            authorUid: cleanString(activity.authorUid),
            authorName: cleanString(activity.authorName),
            authorPhotoUrl: cleanString(activity.authorPhotoUrl),

            visibility: cleanString(activity.visibility) || "public",

            locationLabel: cleanString(activity.locationLabel),
            city: cleanString(activity.city),
            country: cleanString(activity.country),
            lat: activityLat,
            lng: activityLng,

            media: Array.isArray(activity.media) ? activity.media : [],
            hashtags: Array.isArray(activity.hashtags) ?
            activity.hashtags :
            [],

            savedByMe: ownBookmarks.length > 0,
            myBookmarkReactionId: ownBookmarks.length > 0 ?
              cleanString(ownBookmarks[0].id) :
              "",

            pingId: cleanString(activity.pingId),
            eventId: cleanString(activity.eventId),

            reactionCounts,
            ownReactions,

            likeCount: Number(reactionCounts.like || 0),
            commentCount: Number(reactionCounts.comment || 0),
            // Aggregate bookmark count across ALL users — mirrors how
            // likeCount is extracted from GetStream's reaction_counts.
            // Without this the bookmark number in the feed only ever
            // showed the current user's own save (the optimistic local
            // count), never the true total.
            savedCount: Number(reactionCounts.bookmark || 0),
            // Repost count comes from Firestore (moments/{id}.repostCount)
            // because GetStream does not track reposts as a reaction. We
            // batch-fetched the moment docs above and looked up by ID.
            repostCount: repostCountByFirestoreId[(() => {
              const f = cleanString(activity.foreign_id);
              return f.startsWith("moment:") ? f.substring(7) : "";
            })()] || 0,

            originalActivityId: cleanString(activity.originalActivityId),
            originalAuthorUid: cleanString(activity.originalAuthorUid),
            originalAuthorName: cleanString(activity.originalAuthorName),
            originalAuthorPhotoUrl: cleanString(
                activity.originalAuthorPhotoUrl,
            ),
            originalText: cleanString(activity.originalText),
            originalMedia: Array.isArray(activity.originalMedia) ?
                activity.originalMedia :
                [],

            likedByMe: ownLikes.length > 0,
            myLikeReactionId: ownLikes.length > 0 ?
            cleanString(ownLikes[0].id) :
            "",

            // v83: passthrough the Open Graph link preview that
            // createMomentV2 stored on the Stream activity. v78
            // scraped and stored it correctly, but the read-side
            // allowlist below was hardcoded and never included
            // 'linkPreview', so the moment card never received it.
            // Pass through as-is (an object or null). If null or
            // not an object, the frontend's `is Map` guard skips
            // rendering the preview card.
            linkPreview: (activity.linkPreview &&
              typeof activity.linkPreview === "object") ?
              activity.linkPreview :
              null,
          };
        });

        console.log("loadMyTimelineMoments complete", {
          uid,
          count: activities.length,
          offset,
          isPagination,
          hasMore,
          nextOffset: hasMore ? nextOffset : null,
        });

        return {
          ok: true,
          debugVersion: "moments-pagination-v3-offset",
          feed: `timeline:${uid}`,
          count: activities.length,
          activities,
          offset,
          hasMore,
          nextOffset: hasMore ? nextOffset : null,
          isPagination,
        };
      } catch (error) {
        console.error("loadMyTimelineMoments failed", {
          uid,
          offset,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
          streamCode: error && error.error && error.error.code,
          streamDetail: error && error.error && error.error.detail,
        });

        throw new HttpsError(
            "internal",
            "Could not load timeline Moments.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
  );

// Load a single GetStream activity by ID — used by MomentDetailScreen to
// fetch the original moment's true stats when opening a repost/quote's original.
exports.loadSingleActivity = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const activityId = request.data && request.data.activityId;

      if (!uid) {
        throw new HttpsError("unauthenticated", "Must be signed in.");
      }
      if (!activityId) {
        throw new HttpsError("invalid-argument", "activityId is required.");
      }

      try {
        const client = getStreamFeedsClient();

        let activity = null;
        try {
          // getActivities returns {activities: [...]} for a single ID array
          // reactions: {counts: true} triggers the enrich/activities/ endpoint
          // which returns reaction_counts and own_reactions on each activity.
          const actResult = await client.getActivities({
            ids: [activityId],
            reactions: {counts: true, own: true},
          });
          const activities = actResult && actResult.activities &&
              Array.isArray(actResult.activities) ?
              actResult.activities :
              [];
          activity = activities.length > 0 ? activities[0] : null;
        } catch (err) {
          console.error("loadSingleActivity: getActivities failed:", err.message, err.stack);
        }

        if (!activity) {
          return {ok: false, error: "Activity not found."};
        }

        const reactionCounts = activity.reaction_counts || {};
        const ownReactions = activity.own_reactions || {};
        const ownLikes = Array.isArray(ownReactions.like)
            ? ownReactions.like : [];
        const ownBookmarks = Array.isArray(ownReactions.bookmark)
            ? ownReactions.bookmark : [];

        const parsedLat = Number(activity.lat);
        const parsedLng = Number(activity.lng);
        const activityLat = Number.isFinite(parsedLat) ? parsedLat : null;
        const activityLng = Number.isFinite(parsedLng) ? parsedLng : null;

        // Look up the Firestore moment doc for the repost count. We do
        // this here (not in the response builder) so the IIFE-style
        // foreign_id extraction is a clean local expression.
        let singleRepostCount = 0;
        try {
          const f = cleanString(activity.foreign_id);
          if (f.startsWith("moment:")) {
            const mid = f.substring(7);
            if (mid) {
              const snap = await admin.firestore()
                  .collection("moments").doc(mid).get();
              if (snap.exists) {
                const v = snap.get("repostCount");
                if (typeof v === "number") singleRepostCount = v;
              }
            }
          }
        } catch (err) {
          console.warn("loadSingleActivity: failed to fetch repost count:",
              err && err.message);
        }

        return {
          ok: true,
          activity: {
            id: cleanString(activity.id),
            actor: cleanString(activity.actor),
            verb: cleanString(activity.verb),
            object: cleanString(activity.object),
            foreignId: cleanString(activity.foreign_id),
            time: cleanString(activity.time),
            type: cleanString(activity.type),
            text: cleanString(activity.text),
            authorUid: cleanString(activity.authorUid),
            authorName: cleanString(activity.authorName),
            authorPhotoUrl: cleanString(activity.authorPhotoUrl),
            visibility: cleanString(activity.visibility) || "public",
            locationLabel: cleanString(activity.locationLabel),
            city: cleanString(activity.city),
            country: cleanString(activity.country),
            lat: activityLat,
            lng: activityLng,
            media: Array.isArray(activity.media) ? activity.media : [],
            hashtags: Array.isArray(activity.hashtags) ? activity.hashtags : [],
            savedByMe: ownBookmarks.length > 0,
            myBookmarkReactionId: ownBookmarks.length > 0
                ? cleanString(ownBookmarks[0].id) : "",
            pingId: cleanString(activity.pingId),
            eventId: cleanString(activity.eventId),
            reactionCounts,
            likeCount: Number(reactionCounts.like || 0),
            commentCount: Number(reactionCounts.comment || 0),
            // Aggregate bookmark count across ALL users — same as the
            // timeline response so the bookmark number in moment-detail
            // shows the true total, not just the current user's save.
            savedCount: Number(reactionCounts.bookmark || 0),
            // Repost count from Firestore (GetStream does not track
            // reposts as a reaction). Fetched above from moments/{id}.
            repostCount: singleRepostCount,
            originalActivityId: cleanString(activity.originalActivityId),
            originalAuthorUid: cleanString(activity.originalAuthorUid),
            originalAuthorName: cleanString(activity.originalAuthorName),
            originalAuthorPhotoUrl: cleanString(activity.originalAuthorPhotoUrl),
            originalText: cleanString(activity.originalText),
            originalMedia: Array.isArray(activity.originalMedia)
                ? activity.originalMedia : [],
            likedByMe: ownLikes.length > 0,
            myLikeReactionId: ownLikes.length > 0
                ? cleanString(ownLikes[0].id) : "",

            // v83: passthrough the Open Graph link preview that
            // createMomentV2 stored on the Stream activity. Same
            // fix as loadMyTimelineMoments - the read-side
            // allowlist never included 'linkPreview' so the
            // moment-detail screen never received it.
            linkPreview: (activity.linkPreview &&
              typeof activity.linkPreview === "object") ?
              activity.linkPreview :
              null,
          },
        };
      } catch (error) {
        console.error("loadSingleActivity failed", {
          uid, activityId,
          message: error && error.message,
          stack: error && error.stack,
        });
        throw new HttpsError(
            "internal", "Could not load activity.", {
              message: error && error.message,
            });
      }
    },
);

exports.toggleMomentLike = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const momentId = cleanString(request.data && request.data.momentId);
      const currentlyLiked =
        request.data && request.data.currentlyLiked === true;
      const existingReactionId = cleanString(
          request.data && request.data.reactionId,
      );

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      const firestoreMomentId = momentId || activityId;

      const client = getStreamFeedsClient();

      try {
        if (currentlyLiked) {
          let reactionId = existingReactionId;

          if (!reactionId) {
            const existing = await client.reactions.filter({
              activity_id: activityId,
              kind: "like",
              filter_user_id: uid,
              limit: 1,
            });

            const results = Array.isArray(existing.results) ?
              existing.results :
              [];

            reactionId = results.length > 0 ?
              cleanString(results[0].id) :
              "";
          }

          if (reactionId) {
            await safeDeleteReaction(client, reactionId);
          }

          // Remove from Firestore liked_moments subcollection
          await admin.firestore()
              .collection("users").doc(uid)
              .collection("liked_moments").doc(firestoreMomentId)
              .delete()
              .catch(() => {}); // ignore if already absent

          // Decrement Firestore likeCount
          // eslint-disable-next-line max-len
          await admin.firestore()
              .collection("moments").doc(firestoreMomentId)
              .set({
                likeCount: admin.firestore.FieldValue.increment(-1),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              }, {merge: true})
              .catch(() => {}); // non-fatal

          return {
            ok: true,
            liked: false,
            reactionId: "",
          };
        }

        const reaction = await client.reactions.add(
            "like",
            activityId,
            {},
            {
              userId: uid,
            },
        );

        // Write to Firestore liked_moments subcollection
        await admin.firestore()
            .collection("users").doc(uid)
            .collection("liked_moments").doc(firestoreMomentId)
            .set({likedAt: admin.firestore.FieldValue.serverTimestamp()})
            .catch(() => {}); // non-fatal

        // Increment Firestore likeCount
        // eslint-disable-next-line max-len
        await admin.firestore()
            .collection("moments").doc(firestoreMomentId)
            .set({
              likeCount: admin.firestore.FieldValue.increment(1),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, {merge: true})
            .catch(() => {}); // non-fatal

        return {
          ok: true,
          liked: true,
          reactionId: cleanString(reaction.id),
        };
      } catch (error) {
        console.error("toggleMomentLike failed", {
          uid,
          activityId,
          currentlyLiked,
          existingReactionId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not update Moment like.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.toggleMomentBookmark = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const momentId = cleanString(request.data && request.data.momentId);
      const currentlySaved =
        request.data && request.data.currentlySaved === true;
      const existingReactionId = cleanString(
          request.data && request.data.reactionId,
      );

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      const firestoreMomentId = momentId || activityId;

      const client = getStreamFeedsClient();

      try {
        if (currentlySaved) {
          let reactionId = existingReactionId;

          if (!reactionId) {
            const existing = await client.reactions.filter({
              activity_id: activityId,
              kind: "bookmark",
              filter_user_id: uid,
              limit: 1,
            });

            const results = Array.isArray(existing.results) ?
              existing.results :
              [];

            reactionId = results.length > 0 ?
              cleanString(results[0].id) :
              "";
          }

          await safeDeleteReaction(client, reactionId);

          // Remove from Firestore saved_moments subcollection
          await admin.firestore()
              .collection("users").doc(uid)
              .collection("saved_moments").doc(firestoreMomentId)
              .delete()
              .catch(() => {}); // ignore if already absent

          // Decrement Firestore savedCount
          // eslint-disable-next-line max-len
          await admin.firestore()
              .collection("moments").doc(firestoreMomentId)
              .set({
                savedCount: admin.firestore.FieldValue.increment(-1),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              }, {merge: true})
              .catch(() => {}); // non-fatal

          return {
            ok: true,
            saved: false,
            reactionId: "",
          };
        }

        const reaction = await client.reactions.add(
            "bookmark",
            activityId,
            {
              source: "pingmee_save",
            },
            {
              userId: uid,
            },
        );

        // Write to Firestore saved_moments subcollection
        await admin.firestore()
            .collection("users").doc(uid)
            .collection("saved_moments").doc(firestoreMomentId)
            .set({savedAt: admin.firestore.FieldValue.serverTimestamp()})
            .catch(() => {}); // non-fatal

        // Increment Firestore savedCount
        // eslint-disable-next-line max-len
        await admin.firestore()
            .collection("moments").doc(firestoreMomentId)
            .set({
              savedCount: admin.firestore.FieldValue.increment(1),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, {merge: true})
            .catch(() => {}); // non-fatal

        return {
          ok: true,
          saved: true,
          reactionId: cleanString(reaction.id),
        };
      } catch (error) {
        console.error("toggleMomentBookmark failed", {
          uid,
          activityId,
          currentlySaved,
          existingReactionId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not update Moment save.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.createMomentRepost = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const originalActivityId = cleanString(
          request.data && request.data.originalActivityId,
      );
      const quoteText = cleanString(request.data && request.data.quoteText);

      const originalAuthorUid = cleanString(
          request.data && request.data.originalAuthorUid,
      );
      const originalAuthorName = cleanString(
          request.data && request.data.originalAuthorName,
      ) || "Pingmee user";
      const originalAuthorPhotoUrl = cleanString(
          request.data && request.data.originalAuthorPhotoUrl,
      );
      const originalText = cleanString(
          request.data && request.data.originalText,
      );

      const rawOriginalMedia = Array.isArray(
          request.data && request.data.originalMedia,
      ) ?
        request.data.originalMedia :
        [];

      const originalMedia = rawOriginalMedia
          .slice(0, 4)
          .map((item) => {
            const data = item || {};

            return {
              type: cleanString(data.type).toLowerCase(),
              url: cleanString(data.url),
              thumbUrl: cleanString(data.thumbUrl),
              name: cleanString(data.name),
              contentType: cleanString(data.contentType),
            };
          })
          .filter((item) => {
            return item.url &&
              (item.type === "image" || item.type === "video");
          });

      // DEBUG: Log originalMedia to trace why images aren't showing in reposts
      console.log("DEBUG createRepost originalMedia count:", originalMedia.length);
      console.log("DEBUG createRepost originalMedia:", JSON.stringify(originalMedia));

      if (!originalActivityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing original activity.",
        );
      }

      // v86: relaxed the "Missing original Moment content" check.
      // The original v50/v63 validation was too strict — a repost
      // of a moment whose text/media didn't reach the timeline
      // response (or whose originalForeignId is the only source of
      // truth) was being rejected. The v85b consumer flow hits
      // this when reposting from a moment card that was loaded
      // before text/media passthrough was deployed. We now warn
      // + continue; the original can still be located via
      // originalActivityId + originalForeignId.
      if (!originalText && originalMedia.length === 0) {
        console.warn(
            "v86 createRepost: empty originalText + empty originalMedia; " +
            "proceeding anyway. quoteText=" + quoteText,
        );
      }

      // v86: log the raw request payload so we can see what the
      // consumer is actually sending. Helps diagnose future
      // "Missing X" errors without having to guess.
      console.log(
          "v86 createRepost: keys=" +
          JSON.stringify(Object.keys(request.data || {})) +
          " originalText=" + JSON.stringify(originalText) +
          " originalMediaCount=" + originalMedia.length +
          " originalActivityId=" + JSON.stringify(originalActivityId),
      );

      if (quoteText.length > 300) {
        throw new HttpsError(
            "invalid-argument",
            "Quote text is too long.",
        );
      }

      const db = admin.firestore();
      const client = getStreamFeedsClient();

      const streamUser = await getPublicUser(uid);
      const repostRef = db.collection("moments").doc();
      const repostId = repostRef.id;

      const isQuote = quoteText.length > 0;
      const nowIso = new Date().toISOString();

      const activity = {
        actor: `user:${uid}`,
        verb: isQuote ? "quote" : "repost",
        object: `moment:${repostId}`,
        foreign_id: `moment:${repostId}`,
        time: nowIso,

        type: isQuote ? "quote" : "repost",
        text: quoteText,

        authorUid: uid,
        authorName: streamUser.name,
        authorPhotoUrl: streamUser.image,

        visibility: "public",
        media: [],
        hashtags: extractHashtags(quoteText),

        originalActivityId,
        originalAuthorUid,
        originalAuthorName,
        originalAuthorPhotoUrl,
        originalText,
        originalMedia,

        source: "pingmee_repost",
      };

      try {
        const userFeed = client.feed("user", uid);
        const timelineFeed = client.feed("timeline", uid);

        await safeFollowFeed(timelineFeed, "user", uid);

        const streamActivity = await userFeed.addActivity(activity);

        await repostRef.set({
          streamActivityId: cleanString(streamActivity.id),
          streamForeignId: `moment:${repostId}`,

          creatorId: uid,
          type: isQuote ? "quote" : "repost",
          text: quoteText,

          originalActivityId,
          originalAuthorUid,
          originalAuthorName,
          originalAuthorPhotoUrl,
          originalText,
          originalMedia,

          media: [],
          hashtags: extractHashtags(quoteText),

          visibility: "public",
          status: "active",

          likeCount: 0,
          commentCount: 0,
          savedCount: 0,
          repostCount: 0,
          shareCount: 0,
          reportCount: 0,

          source: "pingmee_repost",

          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        // Increment Firestore repostCount on the original moment.
        // The originalActivityId is the GetStream UUID. The Firestore moment
        // ID is derived from the original moment's foreignId from the request.
        const originalForeignId = cleanString(
            request.data && request.data.originalForeignId,
        );
        const originalFirestoreId = originalForeignId.startsWith("moment:") ?
            originalForeignId.substring(7) :
            "";
        if (originalFirestoreId) {
          // eslint-disable-next-line max-len
          await admin.firestore()
              .collection("moments").doc(originalFirestoreId)
              .set({
                repostCount: admin.firestore.FieldValue.increment(1),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              }, {merge: true})
              .catch(() => {}); // non-fatal
        }

        return {
          ok: true,
          repostId,
          streamActivityId: streamActivity.id || "",
          type: isQuote ? "quote" : "repost",
        };
      } catch (error) {
        console.error("createMomentRepost failed", {
          uid,
          repostId,
          originalActivityId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not repost Moment.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.addMomentComment = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const text = cleanString(request.data && request.data.text);
      const parentCommentId = cleanString(
          request.data && request.data.parentCommentId,
      );
      const rootCommentId = cleanString(
          request.data && request.data.rootCommentId,
      );

      // v63: @mentions and rich attachments on the comment.
      // mentions is an array of UIDs. attachments is an array of objects:
      //   { kind: "image"|"sticker", url, thumbUrl?, width?, height?,
      //     stickerId?, stickerSource? }
      // Both are optional. We sanitize here so the rest of the function
      // can trust the shape.
      const rawMentions = request.data && request.data.mentions;
      const sanitizedMentions = Array.isArray(rawMentions) ?
        Array.from(new Set(
            rawMentions
                .map((m) => cleanString(m))
                .filter((m) => m && m.length <= 128),
        )).slice(0, 20) :
        [];
      const rawAttachments = request.data && request.data.attachments;
      const sanitizedAttachments = Array.isArray(rawAttachments) ?
        rawAttachments
            .filter((a) => a && typeof a === "object")
            .map((a) => ({
              kind: cleanString(a.kind) === "sticker" ? "sticker" : "image",
              url: cleanString(a.url),
              thumbUrl: cleanString(a.thumbUrl) || null,
              width: Number.isFinite(Number(a.width)) ?
                Number(a.width) :
                null,
              height: Number.isFinite(Number(a.height)) ?
                Number(a.height) :
                null,
              stickerId: cleanString(a.stickerId) || null,
              stickerSource: cleanString(a.stickerSource) === "giphy" ?
                "giphy" :
                null,
            }))
            .filter((a) => a.url && a.url.length <= 1024)
            .slice(0, 4) :
        [];

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      // v63: when rich attachments are present, the text itself is optional
      // (a sticker / image can be the whole comment). Still cap text length
      // when present.
      if (!text && sanitizedAttachments.length === 0) {
        throw new HttpsError(
            "invalid-argument",
            "Comment text or attachment is required.",
        );
      }

      if (text && text.length > 300) {
        throw new HttpsError(
            "invalid-argument",
            "Comment is too long.",
        );
      }

      const client = getStreamFeedsClient();
      const streamUser = await getPublicUser(uid);

      // data.parentId is the immediate parent comment id (for nested replies).
      // data.rootId is the top-level comment id (for fast fan-out queries).
      // data.mentionedUid is the user being replied to (the parent author);
      // used by the client to surface a "Replying to @name" pill and by the
      // server to write a notification row in users/{parentAuthorUid}/notifications.
      const reactionData = {
        text,
        authorUid: uid,
        authorName: streamUser.name,
        authorPhotoUrl: streamUser.image,
        mentions: sanitizedMentions,
        attachments: sanitizedAttachments,
      };
      let parentAuthorUid = "";
      if (parentCommentId) {
        try {
          const parentReaction = await client.reactions.get(parentCommentId);
          const parentData = parentReaction && parentReaction.data ?
            parentReaction.data :
            {};
          parentAuthorUid = cleanString(parentData.authorUid);
        } catch (parentError) {
          console.error(
              "addMomentComment: parentCommentId lookup failed",
              {parentCommentId, message: parentError && parentError.message},
          );
        }
        reactionData.parentId = parentCommentId;
        reactionData.rootId = rootCommentId || parentCommentId;
        if (parentAuthorUid) {
          reactionData.mentionedUid = parentAuthorUid;
        }
      }

      try {
        const reaction = await client.reactions.add(
            "comment",
            activityId,
            reactionData,
            {
              userId: uid,
            },
        );

        // eslint-disable-next-line max-len
        // Look up the activity to find its foreign_id, then increment
        // Firestore commentCount on the moment doc.
        try {
          const activity = await client.getActivities({ids: [activityId]});
          const found = Array.isArray(activity && activity.activities) ?
            activity.activities.find((a) => a && a.id === activityId) :
            null;
          const foreignId = cleanString(found && found.foreign_id);
          const firestoreMomentId = foreignId.startsWith("moment:") ?
            foreignId.substring(7) :
            "";
          if (firestoreMomentId) {
            // eslint-disable-next-line max-len
            await admin.firestore()
                .collection("moments").doc(firestoreMomentId)
                .set({
                  commentCount: admin.firestore.FieldValue.increment(1),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, {merge: true})
                .catch(() => {});
          }
        } catch (error) {
          console.error(
              "addMomentComment: failed to update commentCount",
              {error: error && error.message},
          );
        }

        // Best-effort notification for comment replies — skip on top-level
        // comments and skip self-replies. Notification is a single Firestore
        // doc under the parent's author; we don't increment any counters
        // here because the read-side listener on the client owns the badge
        // count.
        if (parentCommentId && parentAuthorUid && parentAuthorUid !== uid) {
          try {
            const notifRef = admin.firestore()
                .collection("users").doc(parentAuthorUid)
                .collection("notifications").doc();
            await notifRef.set({
              kind: "comment_reply",
              actorUid: uid,
              actorName: streamUser.name,
              actorPhotoUrl: streamUser.image,
              activityId,
              momentId: firestoreMomentId || null,
              parentCommentId,
              rootCommentId: rootCommentId || parentCommentId,
              commentId: cleanString(reaction.id),
              text,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              read: false,
            });
          } catch (notifError) {
            console.error(
                "addMomentComment: notification write failed",
                {message: notifError && notifError.message},
            );
          }
        }

        // v63: write a comment_mention notification to every mentioned UID.
        // Skip self-mentions. Use a single batched write to keep the cost
        // low and the order stable.
        if (sanitizedMentions.length > 0) {
          const mentionTargets = sanitizedMentions.filter(
              (m) => m && m !== uid,
          );
          if (mentionTargets.length > 0) {
            try {
              const mentionBatch = admin.firestore().batch();
              for (const mentionedUid of mentionTargets) {
                const ref = admin.firestore()
                    .collection("users").doc(mentionedUid)
                    .collection("notifications").doc();
                mentionBatch.set(ref, {
                  kind: "comment_mention",
                  actorUid: uid,
                  actorName: streamUser.name,
                  actorPhotoUrl: streamUser.image,
                  activityId,
                  momentId: firestoreMomentId || null,
                  parentCommentId: parentCommentId || null,
                  rootCommentId: (rootCommentId || parentCommentId) || null,
                  commentId: cleanString(reaction.id),
                  text,
                  mentions: mentionTargets,
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  read: false,
                });
              }
              await mentionBatch.commit();
            } catch (mentionError) {
              // eslint-disable-next-line max-len
              console.error(
                  "addMomentComment: comment_mention notification write failed",
                  {message: mentionError && mentionError.message},
              );
            }
          }
        }

        return {
          ok: true,
          comment: {
            id: cleanString(reaction.id),
            text,
            authorUid: uid,
            authorName: streamUser.name,
            authorPhotoUrl: streamUser.image,
            createdAt: cleanString(reaction.created_at),
            parentId: parentCommentId || null,
            rootId: (rootCommentId || parentCommentId) || null,
            mentionedUid: parentAuthorUid || null,
            mentions: sanitizedMentions,
            attachments: sanitizedAttachments,
          },
        };
      } catch (error) {
        console.error("addMomentComment failed", {
          uid,
          activityId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not add comment.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

// uploadCommentImage — accepts a base64 image body from the Flutter comment
// composer, decodes it, writes it to Firebase Storage at
// comments/{activityId}/{commentIdLocal}/{filename}, makes the file
// world-readable so any logged-in user can render the comment image, and
// returns the public url. Auth-gated at the cloud-function level.
exports.uploadCommentImage = onCall(
    {
      region: REGION,
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(
          request.data && request.data.activityId,
      );
      const commentIdLocal = cleanString(
          request.data && request.data.commentIdLocal,
      ) || `local-${Date.now()}`;
      const contentType = cleanString(
          request.data && request.data.contentType,
      ) || "image/jpeg";
      const base64Body = cleanString(
          request.data && request.data.base64,
      );

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      if (!contentType.startsWith("image/")) {
        throw new HttpsError(
            "invalid-argument",
            "contentType must be an image MIME type.",
        );
      }

      if (!base64Body) {
        throw new HttpsError(
            "invalid-argument",
            "Missing base64 image body.",
        );
      }

      // ~8 MB raw ceiling. Base64 inflates by 4/3 so cap the encoded string
      // at ~11 MB.
      if (base64Body.length > 11 * 1024 * 1024) {
        throw new HttpsError(
            "invalid-argument",
            "Image is too large (max 8 MB).",
        );
      }

      let buffer;
      try {
        buffer = Buffer.from(base64Body, "base64");
      } catch (decodeError) {
        throw new HttpsError(
            "invalid-argument",
            "Image body is not valid base64.",
        );
      }
      if (!buffer || buffer.length === 0) {
        throw new HttpsError(
            "invalid-argument",
            "Decoded image is empty.",
        );
      }

      // Pick a sensible file extension from the content type.
      const ext = contentType === "image/png" ?
        "png" :
        contentType === "image/gif" ?
          "gif" :
          contentType === "image/webp" ?
            "webp" :
            "jpg";
      const safeCommentId = commentIdLocal
          .replace(/[^A-Za-z0-9_-]/g, "_")
          .slice(0, 80) || "comment";
      const filename = `${Date.now()}_${safeCommentId}.${ext}`;
      const objectPath = `comments/${activityId}/${safeCommentId}/${filename}`;

      try {
        const bucket = admin.storage().bucket();
        const file = bucket.file(objectPath);
        await file.save(buffer, {
          resumable: false,
          contentType,
          metadata: {
            contentType,
            metadata: {
              uploadedBy: uid,
              activityId,
              commentIdLocal: safeCommentId,
            },
          },
        });
        // World-readable so any logged-in user rendering the comment can
        // GET the image without needing a signed URL. Auth is still gated
        // at the cloud-function layer for the write path.
        try {
          await file.makePublic();
        } catch (publicError) {
          // eslint-disable-next-line max-len
          console.error(
              "uploadCommentImage: makePublic failed",
              {objectPath, message: publicError && publicError.message},
          );
        }
        const publicUrl = `https://storage.googleapis.com/${bucket.name}/${objectPath}`;
        return {ok: true, url: publicUrl, path: objectPath};
      } catch (error) {
        console.error("uploadCommentImage failed", {
          uid,
          activityId,
          message: error && error.message,
          stack: error && error.stack,
        });
        throw new HttpsError(
            "internal",
            "Could not upload image.",
            {message: error && error.message},
        );
      }
    },
);

exports.loadMomentComments = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const rawLimit = Number(request.data && request.data.limit);
      const limit = Number.isFinite(rawLimit) ?
        Math.min(Math.max(rawLimit, 1), 50) :
        30;
      // parentCommentId filter — when present, only replies whose
      // data.parentId matches are returned. Used for the Threads-style
      // "View N replies" sub-page.
      const parentCommentId = cleanString(
          request.data && request.data.parentCommentId,
      );
      // rootCommentId filter — when present, returns the immediate top-level
      // comment plus ALL its children (root + every reply), for the
      // dedicated thread page where you want the original comment pinned
      // at the top. Takes priority over parentCommentId when both set.
      const rootCommentId = cleanString(
          request.data && request.data.rootCommentId,
      );
      // v73: optional cursor. When set, returns only comments with
      // id < beforeId. Combined with `limit` and the post-filter
      // branch below, this gives the client a stable cursor to
      // scroll the comments list infinitely without offset drift.
      const beforeId = cleanString(
          request.data && request.data.beforeId,
      );

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      const client = getStreamFeedsClient();
      const db = admin.firestore();

      try {
        // v73: windowLimit depends on whether we're paginating. The
        // first call (no beforeId) can fetch a generous window so a
        // moment with 200+ comments still loads on the first try. A
        // paginated call (beforeId set) only needs `limit + 20` of
        // padding for the post-filter by parent/root.
        const windowLimit = beforeId ?
          (limit + 20) :
          200;
        const filterParams = {
          activity_id: activityId,
          kind: "comment",
          limit: windowLimit,
        };
        if (beforeId) {
          // Stream reactions API supports `id_lt` for cursor-based
          // pagination. Using this (not offset) means the page is
          // stable even if new comments get posted mid-scroll.
          filterParams.id_lt = beforeId;
        }
        const response = await client.reactions.filter(filterParams);

        const results = Array.isArray(response.results) ?
          response.results :
          [];

        // Filter by parent / root client-side (Stream does not expose a
        // server-side `data.parentId` filter on reactions.filter).
        const filtered = results.filter((item) => {
          const data = item && item.data ? item.data : {};
          const itemParent = cleanString(data.parentId);
          const itemRoot = cleanString(data.rootId);
          if (rootCommentId) {
            if (itemRoot) {
              return itemRoot === rootCommentId;
            }
            // Top-level comment that started the thread.
            return cleanString(item && item.id) === rootCommentId;
          }
          if (parentCommentId) {
            return itemParent === parentCommentId;
          }
          // Top-level comments only: those with no parentId at all.
          return itemParent === "";
        });

        const trimmed = filtered.slice(0, limit);

        // v73: cursor metadata for the client. hasMore is true when
        // Stream returned the full window (meaning there might be
        // more comments past the page). nextCursor is the id of the
        // LAST comment in the page (oldest visible) — the client
        // passes that as beforeId on the next call. We use the LAST
        // item, not the trimmed-but-not-included one, because some
        // results may have been post-filtered out.
        // v75: cursor fix. Use trimmed[0].id (the OLDEST in the
        // page) not trimmed[trimmed.length-1].id (the NEWEST).
        // Stream's default sort for reactions.filter is id ASC
        // (oldest first), so trimmed[0] is the OLDEST comment in
        // this page. On load-more, id_lt: <oldest> returns items
        // even older than this page = all-new items. The frontend
        // re-sorts by createdAt desc so the new (older) items land
        // at the bottom of the displayed list.
        const hasMore = results.length === windowLimit &&
          trimmed.length > 0;
        const nextCursor = trimmed.length > 0 ?
          cleanString(trimmed[0] && trimmed[0].id) :
          null;
        console.log("v75 loadMomentComments", {
          activityId,
          beforeId: beforeId || null,
          windowLimit,
          resultsCount: results.length,
          filteredCount: filtered.length,
          trimmedCount: trimmed.length,
          hasMore,
          nextCursor,
          cursorPoints: trimmed.length > 0 ?
            `oldest=${trimmed[0].id} newest=${trimmed[trimmed.length - 1].id}` :
            null,
        });

        // Aggregate like/save/reply counts + per-comment "did I like/save
        // this?" by reading the user's own reaction filter for each
        // comment id. Stream gives us reaction_counts in a separate
        // endpoint, but pulling per-reaction keeps this single call
        // self-contained.
        const commentIds = trimmed.map((c) => cleanString(c && c.id))
            .filter((id) => id);

        // Single bulk request for the user's own like + save reactions on
        // these comment ids. Stream supports up to ~100 ids in one filter.
        const ownLikeSet = new Set();
        const ownSaveSet = new Set();
        const likeCountMap = {};
        const saveCountMap = {};
        const replyCountMap = {};

        if (commentIds.length > 0) {
          try {
            const ownLikesResp = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-like",
              filter_user_id: uid,
              limit: 100,
            });
            const ownLikes = Array.isArray(ownLikesResp.results) ?
              ownLikesResp.results :
              [];
            for (const r of ownLikes) {
              const target = cleanString(r && r.data &&
                r.data.targetCommentId);
              if (target) ownLikeSet.add(target);
            }

            const ownSavesResp = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-bookmark",
              filter_user_id: uid,
              limit: 100,
            });
            const ownSaves = Array.isArray(ownSavesResp.results) ?
              ownSavesResp.results :
              [];
            for (const r of ownSaves) {
              const target = cleanString(r && r.data &&
                r.data.targetCommentId);
              if (target) ownSaveSet.add(target);
            }

            // Global like/save counts per comment id. Stream doesn't
            // expose a per-target aggregation in the v1 filter, so we
            // do a single unfiltered request and bucket counts by
            // data.targetCommentId. 500 is the documented max for one
            // filter call; we cap at that.
            const allLikesResp = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-like",
              limit: 500,
            });
            const allLikes = Array.isArray(allLikesResp.results) ?
              allLikesResp.results :
              [];
            for (const r of allLikes) {
              const target = cleanString(r && r.data &&
                r.data.targetCommentId);
              if (target) {
                likeCountMap[target] =
                  (likeCountMap[target] || 0) + 1;
              }
            }

            const allSavesResp = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-bookmark",
              limit: 500,
            });
            const allSaves = Array.isArray(allSavesResp.results) ?
              allSavesResp.results :
              [];
            for (const r of allSaves) {
              const target = cleanString(r && r.data &&
                r.data.targetCommentId);
              if (target) {
                saveCountMap[target] =
                  (saveCountMap[target] || 0) + 1;
              }
            }
          } catch (aggregateError) {
            console.error(
                "loadMomentComments: aggregate reaction fetch failed",
                {message: aggregateError && aggregateError.message},
            );
          }
        }

        // Reply count: how many reactions have data.parentId === this id.
        // We already have the full `results` list above — bucket it once.
        for (const item of results) {
          const data = item && item.data ? item.data : {};
          const parent = cleanString(data.parentId);
          if (parent) {
            replyCountMap[parent] = (replyCountMap[parent] || 0) + 1;
          }
        }

        const comments = trimmed.map((item) => {
          const data = item && item.data ? item.data : {};
          const id = cleanString(item && item.id);

          // v63: surface mentions and attachments on the read path.
          const readMentions = Array.isArray(data.mentions) ?
            data.mentions
                .map((m) => cleanString(m))
                .filter((m) => m)
                .slice(0, 20) :
            [];
          const readAttachments = Array.isArray(data.attachments) ?
            data.attachments
                .filter((a) => a && typeof a === "object" &&
                  cleanString(a.url))
                .map((a) => ({
                  kind: cleanString(a.kind) === "sticker" ?
                    "sticker" :
                    "image",
                  url: cleanString(a.url),
                  thumbUrl: cleanString(a.thumbUrl) || null,
                  width: Number.isFinite(Number(a.width)) ?
                    Number(a.width) :
                    null,
                  height: Number.isFinite(Number(a.height)) ?
                    Number(a.height) :
                    null,
                  stickerId: cleanString(a.stickerId) || null,
                  stickerSource: cleanString(a.stickerSource) ===
                    "giphy" ?
                    "giphy" :
                    null,
                }))
                .slice(0, 4) :
            [];

          return {
            id,
            userId: cleanString(item && item.user_id),
            text: cleanString(data.text),
            authorUid: cleanString(data.authorUid) ||
              cleanString(item && item.user_id),
            authorName: cleanString(data.authorName) || "Pingmee user",
            authorPhotoUrl: cleanString(data.authorPhotoUrl),
            createdAt: cleanString(item && item.created_at),
            parentId: cleanString(data.parentId) || null,
            rootId: cleanString(data.rootId) || null,
            mentionedUid: cleanString(data.mentionedUid) || null,
            mentions: readMentions,
            attachments: readAttachments,
            likeCount: Number(likeCountMap[id] || 0),
            savedCount: Number(saveCountMap[id] || 0),
            replyCount: Number(replyCountMap[id] || 0),
            likedByMe: ownLikeSet.has(id),
            savedByMe: ownSaveSet.has(id),
          };
        });

        return {
          ok: true,
          count: comments.length,
          comments,
          hasMore,
          nextCursor,
        };
      } catch (error) {
        console.error("loadMomentComments failed", {
          uid,
          activityId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not load comments.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.createDirectChat = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const otherUid = cleanString(request.data && request.data.otherUid);

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      if (!otherUid || otherUid === uid) {
        throw new HttpsError(
            "invalid-argument",
            "Invalid chat user.",
        );
      }

      const otherSnap = await admin
          .firestore()
          .collection("users")
          .doc(otherUid)
          .get();

      if (!otherSnap.exists) {
        throw new HttpsError(
            "not-found",
            "That user does not exist.",
        );
      }

      const client = getStreamClient();

      const me = await getPublicUser(uid);
      const other = await getPublicUser(otherUid);

      await client.upsertUser(me);
      await client.upsertUser(other);

      const members = [uid, otherUid].sort();
      const channelId = `dm_${members[0]}_${members[1]}`;

      const channel = client.channel("messaging", channelId, {
        members,
        pingmeeType: "dm",
        created_by_id: uid,
      });

      await safeCreateChannel(channel);
      await channel.addMembers(members);

      return {
        channelId,
        cid: `messaging:${channelId}`,
      };
    },
);

// ============================================================
// Comment reactions — toggle like + save on a single comment.
// Mirrors the moment like / save pattern (Stream reaction + Firestore
// subcollection) so the read path can fetch all my own comment likes
// in one filter and the user's own state is denormalised into
// users/{uid}/liked_comments and users/{uid}/saved_comments.
// ============================================================

exports.toggleCommentLike = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const commentId = cleanString(request.data && request.data.commentId);
      const currentlyLiked =
        request.data && request.data.currentlyLiked === true;
      const existingReactionId = cleanString(
          request.data && request.data.reactionId,
      );

      if (!activityId || !commentId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId or commentId.",
        );
      }

      const client = getStreamFeedsClient();
      const db = admin.firestore();

      try {
        if (currentlyLiked) {
          let reactionId = existingReactionId;

          if (!reactionId) {
            const existing = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-like",
              filter_user_id: uid,
              limit: 50,
            });
            const results = Array.isArray(existing.results) ?
              existing.results :
              [];
            for (const r of results) {
              if (cleanString(r && r.data &&
                r.data.targetCommentId) === commentId) {
                reactionId = cleanString(r && r.id);
                break;
              }
            }
          }

          if (reactionId) {
            await safeDeleteReaction(client, reactionId);
          }

          await db.collection("users").doc(uid)
              .collection("liked_comments").doc(commentId)
              .delete()
              .catch(() => {});

          return {
            ok: true,
            liked: false,
            reactionId: "",
          };
        }

        const reaction = await client.reactions.add(
            "comment-like",
            activityId,
            {
              targetCommentId: commentId,
            },
            {
              userId: uid,
            },
        );

        await db.collection("users").doc(uid)
            .collection("liked_comments").doc(commentId)
            .set({likedAt: admin.firestore.FieldValue.serverTimestamp()})
            .catch(() => {});

        return {
          ok: true,
          liked: true,
          reactionId: cleanString(reaction.id),
        };
      } catch (error) {
        console.error("toggleCommentLike failed", {
          uid,
          activityId,
          commentId,
          message: error && error.message,
          code: error && error.code,
        });
        throw new HttpsError(
            "internal",
            "Could not update comment like.",
        );
      }
    },
);

exports.toggleCommentSave = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const commentId = cleanString(request.data && request.data.commentId);
      const momentId = cleanString(request.data && request.data.momentId);
      const currentlySaved =
        request.data && request.data.currentlySaved === true;
      const existingReactionId = cleanString(
          request.data && request.data.reactionId,
      );

      if (!activityId || !commentId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId or commentId.",
        );
      }

      const client = getStreamFeedsClient();
      const db = admin.firestore();

      try {
        if (currentlySaved) {
          let reactionId = existingReactionId;

          if (!reactionId) {
            const existing = await client.reactions.filter({
              activity_id: activityId,
              kind: "comment-bookmark",
              filter_user_id: uid,
              limit: 50,
            });
            const results = Array.isArray(existing.results) ?
              existing.results :
              [];
            for (const r of results) {
              if (cleanString(r && r.data &&
                r.data.targetCommentId) === commentId) {
                reactionId = cleanString(r && r.id);
                break;
              }
            }
          }

          if (reactionId) {
            await safeDeleteReaction(client, reactionId);
          }

          // saved_comments doc id is the same as the comment's reaction id
          // so each user has at most one row per comment and the
          // Saved Comments tab can paginate by .orderBy('savedAt', 'desc').
          await db.collection("users").doc(uid)
              .collection("saved_comments").doc(commentId)
              .delete()
              .catch(() => {});

          return {
            ok: true,
            saved: false,
            reactionId: "",
          };
        }

        const reaction = await client.reactions.add(
            "comment-bookmark",
            activityId,
            {
              targetCommentId: commentId,
              momentId: momentId || null,
            },
            {
              userId: uid,
            },
        );

        await db.collection("users").doc(uid)
            .collection("saved_comments").doc(commentId)
            .set({
              savedAt: admin.firestore.FieldValue.serverTimestamp(),
              momentId: momentId || null,
              activityId,
            })
            .catch(() => {});

        return {
          ok: true,
          saved: true,
          reactionId: cleanString(reaction.id),
        };
      } catch (error) {
        console.error("toggleCommentSave failed", {
          uid,
          activityId,
          commentId,
          message: error && error.message,
          code: error && error.code,
        });
        throw new HttpsError(
            "internal",
            "Could not update comment save.",
        );
      }
    },
);

// ============================================================
// sendCommentToConnection — wraps createDirectChat and posts a
// comment preview message into the chat. The text is the user's
// preview, prefixed with a structured marker so the chat renderer
// can show the comment card above the message bubble.
// ============================================================

exports.sendCommentToConnection = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const otherUid = cleanString(request.data && request.data.otherUid);
      const commentText = cleanString(
          request.data && request.data.commentText,
      );
      const commentAuthorName = cleanString(
          request.data && request.data.commentAuthorName,
      );
      const commentAuthorPhotoUrl = cleanString(
          request.data && request.data.commentAuthorPhotoUrl,
      );
      const momentId = cleanString(request.data && request.data.momentId);
      const momentText = cleanString(
          request.data && request.data.momentText,
      );
      const momentAuthorName = cleanString(
          request.data && request.data.momentAuthorName,
      );

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      if (!otherUid || otherUid === uid) {
        throw new HttpsError(
            "invalid-argument",
            "Invalid chat user.",
        );
      }

      if (!commentText) {
        throw new HttpsError(
            "invalid-argument",
            "Comment text is required.",
        );
      }

      const otherSnap = await admin.firestore()
          .collection("users").doc(otherUid).get();
      if (!otherSnap.exists) {
        throw new HttpsError(
            "not-found",
            "That user does not exist.",
        );
      }

      const client = getStreamClient();
      const me = await getPublicUser(uid);
      const other = await getPublicUser(otherUid);

      await client.upsertUser(me);
      await client.upsertUser(other);

      const members = [uid, otherUid].sort();
      const channelId = `dm_${members[0]}_${members[1]}`;

      const channel = client.channel("messaging", channelId, {
        members,
        pingmeeType: "dm",
        created_by_id: uid,
      });
      await safeCreateChannel(channel);
      await channel.addMembers(members);

      // Compose a short shared-comment message. The leading line is a
      // stable machine-readable header the client uses to render the
      // "shared comment" card; the user's note (or the comment text
      // itself, if they didn't add a note) is the body.
      const header = "pingmee_share_kind:shared_comment";
      const authorLine = commentAuthorName ?
        `From @${commentAuthorName.replace(/\s+/g, "")}` :
        "From a Pingmee comment";
      const momentLine = momentAuthorName ?
        `on @${momentAuthorName.replace(/\s+/g, "")}'s moment` :
        "";
      const note = cleanString(request.data && request.data.note);
      const body = note || commentText;

      const commentPreview = commentText.length > 240 ?
            commentText.substring(0, 240) + "…" :
            commentText;
      const composedText = [
        header,
        authorLine,
        momentLine,
        "",
        `💬 "${commentPreview}"`,
        "",
        body,
      ].filter((line) => line && line.length > 0).join("\n");

      try {
        const sent = await channel.sendMessage({
          text: composedText,
          customData: {
            pingmee_share_kind: "shared_comment",
            commentText,
            commentAuthorName,
            commentAuthorPhotoUrl,
            momentId: momentId || null,
            momentText: momentText || null,
            momentAuthorName: momentAuthorName || null,
            senderUid: uid,
            senderName: me.name,
            senderPhotoUrl: me.image,
          },
        });

        return {
          ok: true,
          channelId,
          cid: `messaging:${channelId}`,
          messageId: sent && sent.message ? sent.message.id : "",
        };
      } catch (error) {
        console.error("sendCommentToConnection failed", {
          uid,
          otherUid,
          message: error && error.message,
          code: error && error.code,
        });
        throw new HttpsError(
            "internal",
            "Could not share the comment.",
        );
      }
    },
);

exports.deleteMoment = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const foreignId = cleanString(request.data && request.data.foreignId);
      const momentId = momentIdFromForeignId(foreignId);

      if (!activityId || !momentId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing Moment reference.",
        );
      }

      const db = admin.firestore();
      const momentRef = db.collection("moments").doc(momentId);
      const momentSnap = await momentRef.get();

      if (!momentSnap.exists) {
        throw new HttpsError(
            "not-found",
            "Moment not found.",
        );
      }

      const moment = momentSnap.data() || {};
      const creatorId = cleanString(moment.creatorId);

      if (creatorId !== uid) {
        throw new HttpsError(
            "permission-denied",
            "You can only delete your own Moment.",
        );
      }

      const client = getStreamFeedsClient();
      const userFeed = client.feed("user", uid);

      try {
        await safeRemoveActivity(userFeed, activityId);

        await momentRef.set(
            {
              status: "deleted",
              deletedAt: admin.firestore.FieldValue.serverTimestamp(),
              deletedBy: uid,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            {merge: true},
        );

        return {
          ok: true,
          deleted: true,
          momentId,
          activityId,
        };
      } catch (error) {
        console.error("deleteMoment failed", {
          uid,
          momentId,
          activityId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
        });

        throw new HttpsError(
            "internal",
            "Could not delete Moment.",
            {
              message: error && error.message,
              code: error && error.code,
              statusCode: error && error.statusCode,
            },
        );
      }
    },
);

exports.reportMoment = onCall(
    {
      region: REGION,
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      const activityId = cleanString(request.data && request.data.activityId);
      const foreignId = cleanString(request.data && request.data.foreignId);
      const reason = cleanString(request.data && request.data.reason) ||
        "other";

      const momentId = momentIdFromForeignId(foreignId);

      if (!activityId || !momentId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing Moment reference.",
        );
      }

      const db = admin.firestore();
      const momentRef = db.collection("moments").doc(momentId);
      const reportRef = momentRef.collection("reports").doc(uid);

      try {
        await db.runTransaction(async (tx) => {
          const reportSnap = await tx.get(reportRef);

          if (reportSnap.exists) {
            return;
          }

          tx.set(reportRef, {
            reporterUid: uid,
            activityId,
            foreignId,
            reason,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          tx.set(
              momentRef,
              {
                reportCount: admin.firestore.FieldValue.increment(1),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              {merge: true},
          );
        });

        return {
          ok: true,
          reported: true,
          momentId,
        };
      } catch (error) {
        console.error("reportMoment failed", {
          uid,
          momentId,
          activityId,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
        });

        throw new HttpsError(
            "internal",
            "Could not report Moment.",
            {
              message: error && error.message,
              code: error && error.code,
            },
        );
      }
    },
);

exports.ensurePingChatChannel = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const pingId = cleanString(request.data && request.data.pingId);

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      if (!pingId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing pingId.",
        );
      }

      const db = admin.firestore();
      const pingRef = db.collection("pings").doc(pingId);
      const pingSnap = await pingRef.get();

      if (!pingSnap.exists) {
        throw new HttpsError(
            "not-found",
            "Ping not found.",
        );
      }

      const ping = pingSnap.data() || {};

      const creatorId =
        cleanString(ping.creatorId) ||
        cleanString(ping.createdBy) ||
        cleanString(ping.hostUid) ||
        cleanString(ping.hostId);

      const isCreator = creatorId === uid;

      const participantSnap = await pingRef
          .collection("participants")
          .doc(uid)
          .get();

      const participant = participantSnap.exists ? participantSnap.data() : {};
      const status = cleanString(participant.status).toLowerCase();

      const allowedStatuses = [
        "active",
        "approved",
        "joined",
        "member",
      ];

      const isAllowedParticipant =
        participantSnap.exists &&
        (
          !status ||
          allowedStatuses.includes(status)
        );

      if (!isCreator && !isAllowedParticipant) {
        throw new HttpsError(
            "permission-denied",
            "You are not allowed in this ping chat.",
        );
      }

      const approvedSnap = await pingRef
          .collection("participants")
          .where("status", "in", ["approved", "active", "joined", "member"])
          .get();

      const memberIds = new Set();

      if (creatorId) {
        memberIds.add(creatorId);
      }

      approvedSnap.docs.forEach((doc) => {
        const data = doc.data() || {};
        const memberUid = cleanString(data.uid) || doc.id;
        if (memberUid) {
          memberIds.add(memberUid);
        }
      });

      memberIds.add(uid);

      const members = Array.from(memberIds).filter(Boolean);

      const client = getStreamClient();

      const users = await Promise.all(
          members.map((memberUid) => getPublicUser(memberUid)),
      );

      await client.upsertUsers(users);

      const title =
        cleanString(ping.title) ||
        cleanString(ping.name) ||
        "Ping chat";

      const image =
        firstPingMediaImage(ping) ||
        cleanString(ping.coverUrl) ||
        cleanString(ping.imageUrl) ||
        cleanString(ping.photoUrl);

      const channelId = `ping_${pingId}`;

      const channel = client.channel("messaging", channelId, {
        name: title,
        image,
        members,
        pingId,
        pingmeeType: "ping",
        pingmeeMemberCount: members.length,
        created_by_id: creatorId || uid,
      });

      await safeCreateChannel(channel);

      await channel.addMembers(members);

      await channel.updatePartial({
        set: {
          name: title,
          image,
          pingId,
          pingmeeType: "ping",
          pingmeeMemberCount: members.length,
        },
      });

      return {
        channelId,
        cid: `messaging:${channelId}`,
        memberCount: members.length,
      };
    },
);

exports.removePingChatMember = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const pingId = cleanString(request.data && request.data.pingId);
      const targetUid =
        cleanString(request.data && request.data.memberUid) || uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      if (!pingId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing pingId.",
        );
      }

      if (!targetUid) {
        throw new HttpsError(
            "invalid-argument",
            "Missing memberUid.",
        );
      }

      const db = admin.firestore();
      const pingRef = db.collection("pings").doc(pingId);
      const pingSnap = await pingRef.get();

      if (!pingSnap.exists) {
        throw new HttpsError(
            "not-found",
            "Ping not found.",
        );
      }

      const ping = pingSnap.data() || {};

      const creatorId =
        cleanString(ping.creatorId) ||
        cleanString(ping.createdBy) ||
        cleanString(ping.hostUid) ||
        cleanString(ping.hostId);

      const isCreator = creatorId === uid;
      const isSelf = targetUid === uid;

      if (!isCreator && !isSelf) {
        throw new HttpsError(
            "permission-denied",
            "You cannot remove this ping chat member.",
        );
      }

      const client = getStreamClient();
      const channelId = `ping_${pingId}`;
      const channel = client.channel("messaging", channelId);

      try {
        await channel.removeMembers([targetUid]);
      } catch (error) {
        const message = cleanString(error.message).toLowerCase();

        const channelMissing =
          message.includes("not found") ||
          message.includes("does not exist") ||
          error.code === 16;

        if (!channelMissing) {
          throw error;
        }
      }

      return {
        ok: true,
        channelId,
        removedUid: targetUid,
      };
    },
);

exports.syncExpiredPingChatLifecycle = onSchedule(
    {
      region: REGION,
      schedule: "every 30 minutes",
      timeZone: "Africa/Lusaka",
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async () => {
      const db = admin.firestore();
      const now = new Date();
      const nowTs = admin.firestore.Timestamp.fromDate(now);

      const client = getStreamClient();

      const snap = await db
          .collection("pings")
          .where("endsAt", "<=", nowTs)
          .limit(200)
          .get();

      if (snap.empty) {
        console.log("syncExpiredPingChatLifecycle: no expired pings");
        return;
      }

      let readOnlyCount = 0;
      let archivedCount = 0;

      for (const doc of snap.docs) {
        const pingId = doc.id;
        const ping = doc.data() || {};

        const endsAt = dateFromValue(ping.endsAt);
        if (!endsAt) continue;

        const chatLifecycle =
          ping.chatLifecycle && typeof ping.chatLifecycle === "object" ?
            ping.chatLifecycle :
            {};

        const chatConfig =
          ping.chatConfig && typeof ping.chatConfig === "object" ?
            ping.chatConfig :
            {};
        const manuallyReopened =
          chatConfig.manuallyReopened === true ||
          chatLifecycle.manuallyReopened === true;
        if (manuallyReopened) {
          continue;
        }

        const existingReadOnlyAt = dateFromValue(ping.chatReadOnlyAt);
        const existingAutoArchiveAt = dateFromValue(ping.chatAutoArchiveAt);

        const chatReadOnlyAt = existingReadOnlyAt || addDays(endsAt, 3);
        const chatAutoArchiveAt = existingAutoArchiveAt || addDays(endsAt, 4);

        const shouldReadOnly = now >= chatReadOnlyAt;
        const shouldAutoArchive = now >= chatAutoArchiveAt;

        const alreadyReadOnly =
          ping.chatConfig &&
          ping.chatConfig.readOnly === true;

        const alreadyAutoArchived =
          chatLifecycle.autoArchived === true ||
          (
            ping.chatConfig &&
            ping.chatConfig.autoArchived === true
          );

        const updates = {
          chatReadOnlyAt:
            admin.firestore.Timestamp.fromDate(chatReadOnlyAt),
          chatAutoArchiveAt:
            admin.firestore.Timestamp.fromDate(chatAutoArchiveAt),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };

        if (shouldReadOnly && !alreadyReadOnly) {
          updates["chatConfig.readOnly"] = true;
          updates["chatConfig.readOnlyAt"] =
            admin.firestore.FieldValue.serverTimestamp();
          updates["chatLifecycle.readOnly"] = true;
          updates["chatLifecycle.readOnlyAt"] =
            admin.firestore.FieldValue.serverTimestamp();
          updates["chatLifecycle.warningMessage"] = [
            "This ping has ended.",
            "You can still view the conversation,",
            "but new messages are closed.",
          ].join(" ");

          readOnlyCount++;
        }

        if (shouldAutoArchive && !alreadyAutoArchived) {
          updates["chatConfig.autoArchived"] = true;
          updates["chatConfig.autoArchivedAt"] =
            admin.firestore.FieldValue.serverTimestamp();
          updates["chatLifecycle.autoArchived"] = true;
          updates["chatLifecycle.autoArchivedAt"] =
            admin.firestore.FieldValue.serverTimestamp();

          archivedCount++;
        }

        await doc.ref.set(updates, {merge: true});

        const channelId = `ping_${pingId}`;
        const cid = `messaging:${channelId}`;
        const channel = client.channel("messaging", channelId);

        try {
          await channel.updatePartial({
            set: {
              pingId,
              pingmeeType: "ping",
              pingmeeReadOnly: shouldReadOnly,
              pingmeeAutoArchived: shouldAutoArchive,
              chatReadOnlyAt: chatReadOnlyAt.toISOString(),
              chatAutoArchiveAt: chatAutoArchiveAt.toISOString(),
            },
          });
        } catch (error) {
          const message = cleanString(error.message).toLowerCase();
          const missing =
            message.includes("not found") ||
            message.includes("does not exist");

          if (!missing) {
            console.error("Stream ping lifecycle update failed", {
              pingId,
              error,
            });
          }
        }

        if (shouldAutoArchive && !alreadyAutoArchived) {
          const participantsSnap = await doc.ref
              .collection("participants")
              .where("status", "in", ["approved", "active", "joined", "member"])
              .get();

          const uids = new Set();

          const creatorId =
            cleanString(ping.creatorId) ||
            cleanString(ping.createdBy) ||
            cleanString(ping.hostUid) ||
            cleanString(ping.hostId);

          if (creatorId) {
            uids.add(creatorId);
          }

          participantsSnap.docs.forEach((participantDoc) => {
            const data = participantDoc.data() || {};
            const uid = cleanString(data.uid) || participantDoc.id;
            if (uid) {
              uids.add(uid);
            }
          });

          const batch = db.batch();
          let writeCount = 0;
          const prefsDocId = chatPrefsDocIdForCid(cid);

          for (const uid of uids) {
            const prefsRef = db
                .collection("users")
                .doc(uid)
                .collection("chatPrefs")
                .doc(prefsDocId);

            batch.set(
                prefsRef,
                {
                  archived: true,
                  autoArchived: true,
                  archivedReason: "ping_expired",
                  archivedAt: admin.firestore.FieldValue.serverTimestamp(),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                {merge: true},
            );

            writeCount++;
          }

          if (writeCount > 0) {
            await batch.commit();
          }
        }
      }

      console.log("syncExpiredPingChatLifecycle complete", {
        checked: snap.size,
        readOnlyCount,
        archivedCount,
      });
    },
);

exports.syncMyPingHistory = onCall(
    {
      region: REGION,
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      try {
        const db = admin.firestore();

        const pingsSnap = await db
            .collection("pings")
            .limit(500)
            .get();

        if (pingsSnap.empty) {
          return {
            ok: true,
            checked: 0,
            synced: 0,
          };
        }

        let synced = 0;
        let checked = 0;

        let batch = db.batch();
        let batchCount = 0;

        for (const pingDoc of pingsSnap.docs) {
          checked++;

          const pingId = pingDoc.id;
          const ping = pingDoc.data() || {};

          const participantSnap = await pingDoc.ref
              .collection("participants")
              .doc(uid)
              .get();

          if (!participantSnap.exists) {
            continue;
          }

          const participant = participantSnap.data() || {};
          const role = cleanString(participant.role).toLowerCase();
          const status = cleanString(participant.status).toLowerCase();

          if (role === "creator") {
            continue;
          }

          const allowedStatuses = [
            "approved",
            "active",
            "joined",
            "member",
            "left",
            "removed",
          ];

          if (!allowedStatuses.includes(status)) {
            continue;
          }

          const location = ping.location || {};
          const placeName = cleanString(location.placeName);
          const meetingPoint = cleanString(location.meetingPoint);

          let locationLine = "Nearby";

          if (placeName && meetingPoint) {
            locationLine = `${placeName} · ${meetingPoint}`;
          } else if (meetingPoint) {
            locationLine = meetingPoint;
          } else if (placeName) {
            locationLine = placeName;
          }

          const historyRef = db
              .collection("users")
              .doc(uid)
              .collection("ping_history")
              .doc(pingId);

          batch.set(
              historyRef,
              {
                pingId,
                role: "joined",
                participantStatus: status,
                creatorId: cleanString(ping.creatorId),
                title: cleanString(ping.title) || "Untitled ping",
                category: cleanString(ping.category) || "General",
                privacy: cleanString(ping.privacy) || "public",
                locationLine,
                participantCount: Number(ping.participantCount || 0),
                mediaCount: Number(ping.mediaCount || 0),
                media: Array.isArray(ping.media) ? ping.media : [],
                status: cleanString(ping.status) || "active",
                createdAt: ping.createdAt || null,
                createdAtLocal: ping.createdAtLocal || null,
                endsAt: ping.endsAt || null,
                joinedAt: participant.joinedAt ||
                  participant.approvedAt ||
                  participant.requestedAt ||
                  null,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              {
                merge: true,
              },
          );

          synced++;
          batchCount++;

          if (batchCount >= 450) {
            await batch.commit();
            batch = db.batch();
            batchCount = 0;
          }
        }

        if (batchCount > 0) {
          await batch.commit();
        }

        console.log("syncMyPingHistory complete", {
          uid,
          checked,
          synced,
        });

        return {
          ok: true,
          checked,
          synced,
        };
      } catch (error) {
        console.error("syncMyPingHistory failed", {
          uid,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
        });

        throw new HttpsError(
            "internal",
            "Could not sync ping history.",
            {
              message: error && error.message,
              code: error && error.code,
            },
        );
      }
    },
);

exports.reactivatePingChat = onCall(
    {
      region: REGION,
      secrets: [STREAM_API_KEY, STREAM_API_SECRET],
    },
    async (request) => {
      const uid = request.auth && request.auth.uid;
      const pingId = cleanString(request.data && request.data.pingId);

      if (!uid) {
        throw new HttpsError(
            "unauthenticated",
            "You must be logged in.",
        );
      }

      if (!pingId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing pingId.",
        );
      }

      const db = admin.firestore();
      const pingRef = db.collection("pings").doc(pingId);
      const pingSnap = await pingRef.get();

      if (!pingSnap.exists) {
        throw new HttpsError(
            "not-found",
            "Ping not found.",
        );
      }

      const ping = pingSnap.data() || {};

      const creatorId =
        cleanString(ping.creatorId) ||
        cleanString(ping.createdBy) ||
        cleanString(ping.hostUid) ||
        cleanString(ping.hostId);

      if (!creatorId || creatorId !== uid) {
        throw new HttpsError(
            "permission-denied",
            "Only the ping creator can revive this chat.",
        );
      }

      const participantsSnap = await pingRef
          .collection("participants")
          .where(
              "status",
              "in",
              ["approved", "active", "joined", "member"],
          )
          .get();

      const memberUids = new Set();

      memberUids.add(creatorId);

      participantsSnap.docs.forEach((participantDoc) => {
        const data = participantDoc.data() || {};
        const memberUid = cleanString(data.uid) || participantDoc.id;

        if (memberUid) {
          memberUids.add(memberUid);
        }
      });

      const now = admin.firestore.FieldValue.serverTimestamp();
      const channelId = `ping_${pingId}`;
      const cid = `messaging:${channelId}`;
      const prefsDocId = chatPrefsDocIdForCid(cid);

      await pingRef.set(
          {
            "chatConfig.readOnly": false,
            "chatConfig.autoArchived": false,
            "chatConfig.manuallyReopened": true,
            "chatConfig.reopenedAt": now,
            "chatConfig.reopenedBy": uid,

            "chatLifecycle.readOnly": false,
            "chatLifecycle.autoArchived": false,
            "chatLifecycle.manuallyReopened": true,
            "chatLifecycle.reopenedAt": now,
            "chatLifecycle.reopenedBy": uid,

            "updatedAt": now,
          },
          {
            merge: true,
          },
      );

      const batch = db.batch();
      let writeCount = 0;

      for (const memberUid of memberUids) {
        const prefsRef = db
            .collection("users")
            .doc(memberUid)
            .collection("chatPrefs")
            .doc(prefsDocId);

        batch.set(
            prefsRef,
            {
              archived: false,
              autoArchived: false,
              archivedReason: admin.firestore.FieldValue.delete(),
              unarchivedAt: now,
              updatedAt: now,
            },
            {
              merge: true,
            },
        );

        writeCount++;
      }

      const activityRef = pingRef.collection("activity").doc();

      batch.set(activityRef, {
        type: "chat_reactivated",
        title: "Chat revived",
        subtitle: "The creator reopened the expired ping chat",
        actorUid: uid,
        createdAt: now,
        extra: {
          pingId,
        },
      });

      if (writeCount > 0) {
        await batch.commit();
      }

      const client = getStreamClient();
      const channel = client.channel("messaging", channelId);

      try {
        await channel.updatePartial({
          set: {
            pingId,
            pingmeeType: "ping",
            pingmeeReadOnly: false,
            pingmeeAutoArchived: false,
            pingmeeReactivatedAt: new Date().toISOString(),
          },
        });
      } catch (error) {
        const message = cleanString(error.message).toLowerCase();

        const missing =
          message.includes("not found") ||
          message.includes("does not exist");

        if (!missing) {
          console.error("Stream ping chat revive failed", {
            pingId,
            error,
          });

          throw new HttpsError(
              "internal",
              "Chat was revived, but Stream update failed.",
          );
        }
      }

      return {
        ok: true,
        pingId,
        unarchivedCount: memberUids.size,
      };
    },
);


// ============================================================================
// Prune stale "online" presence
// ============================================================================
//
// Reads every `users/{uid}` doc that still claims to be online, and
// flips it to offline if the most recent heartbeat is older than the
// 2-minute staleness window used by the client-side helper
// `pingmeeIsUserOnlineFromUserData` (see profile_tab.dart).
//
// This is the server-side safety net for clients that crash, lose
// network, or are force-killed before `didChangeAppLifecycleState`
// can fire. Without it, a user who force-quits the app stays
// "online" forever (because nothing in the client ever writes
// `isOnline = false` for them). With this, the worst-case lag is
// the function's run cadence (default 1 minute).
//
// Reads are page-limited (500 per run) to keep memory bounded; if
// there are more than 500 stale online users, the next run picks up
// the rest. In practice the cardinality is well under this.
exports.pruneStaleOnlineUsers = onSchedule(
    {
      region: REGION,
      schedule: "every 1 minutes",
      timeZone: "Africa/Lusaka",
    },
    async () => {
      const db = admin.firestore();
      const now = new Date();
      const cutoff = new Date(now.getTime() - 2 * 60 * 1000); // 2 min
      const cutoffTs = admin.firestore.Timestamp.fromDate(cutoff);

      const snap = await db
          .collection("users")
          .where("isOnline", "==", true)
          .where("lastSeen", "<=", cutoffTs)
          .limit(500)
          .get();

      if (snap.empty) {
        console.log("pruneStaleOnlineUsers: no stale online users");
        return {flipped: 0};
      }

      const batch = db.batch();
      let flipped = 0;
      snap.forEach((docSnap) => {
        batch.update(docSnap.ref, {
          isOnline: false,
          // Keep the existing lastSeen — it is the actual last
          // activity timestamp and is useful for displaying "last
          // seen 3 minutes ago" etc. The "isOnline" flag is the
          // derivative; only that needs to be flipped.
        });
        flipped += 1;
      });

      await batch.commit();

      console.log("pruneStaleOnlineUsers: flipped", flipped, "users");
      return {flipped};
    },
);
