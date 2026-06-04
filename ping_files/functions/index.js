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

          status: "active",

          likeCount: 0,
          commentCount: 0,
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

      try {
        const client = getStreamFeedsClient();
        const timelineFeed = client.feed("timeline", uid);

        // Make sure own posts are visible in own timeline.
        await safeFollowFeed(timelineFeed, "user", uid);

        const response = await timelineFeed.get({
          limit,
          reactions: {
            own: true,
            counts: true,
            recent: true,
          },
          user_id: uid,
        });

        const results = Array.isArray(response.results) ?
          response.results :
          [];

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

            originalActivityId: cleanString(activity.originalActivityId),
            originalAuthorUid: cleanString(activity.originalAuthorUid),
            originalAuthorName: cleanString(activity.originalAuthorName),
            originalAuthorPhotoUrl: cleanString(
                activity.originalAuthorPhotoUrl,
            ),
            originalText: cleanString(activity.originalText),

            likedByMe: ownLikes.length > 0,
            myLikeReactionId: ownLikes.length > 0 ?
            cleanString(ownLikes[0].id) :
            "",
          };
        });

        console.log("loadMyTimelineMoments complete", {
          uid,
          count: activities.length,
        });

        return {
          ok: true,
          debugVersion: "moments-location-v1",
          feed: `timeline:${uid}`,
          count: activities.length,
          activities,
        };
      } catch (error) {
        console.error("loadMyTimelineMoments failed", {
          uid,
          message: error && error.message,
          stack: error && error.stack,
          code: error && error.code,
          statusCode: error && error.statusCode,
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
              .collection("liked_moments").doc(activityId)
              .delete()
              .catch(() => {}); // ignore if already absent

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
            .collection("liked_moments").doc(activityId)
            .set({likedAt: admin.firestore.FieldValue.serverTimestamp()})
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
              .collection("saved_moments").doc(activityId)
              .delete()
              .catch(() => {}); // ignore if already absent

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
            .collection("saved_moments").doc(activityId)
            .set({savedAt: admin.firestore.FieldValue.serverTimestamp()})
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
              item.type === "image";
          });

      if (!originalActivityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing original activity.",
        );
      }

      if (!originalText && originalMedia.length === 0) {
        throw new HttpsError(
            "invalid-argument",
            "Missing original Moment content.",
        );
      }

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
          shareCount: 0,
          reportCount: 0,

          source: "pingmee_repost",

          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

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

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      if (!text) {
        throw new HttpsError(
            "invalid-argument",
            "Comment text is required.",
        );
      }

      if (text.length > 300) {
        throw new HttpsError(
            "invalid-argument",
            "Comment is too long.",
        );
      }

      const client = getStreamFeedsClient();
      const streamUser = await getPublicUser(uid);

      try {
        const reaction = await client.reactions.add(
            "comment",
            activityId,
            {
              text,
              authorUid: uid,
              authorName: streamUser.name,
              authorPhotoUrl: streamUser.image,
            },
            {
              userId: uid,
            },
        );

        return {
          ok: true,
          comment: {
            id: cleanString(reaction.id),
            text,
            authorUid: uid,
            authorName: streamUser.name,
            authorPhotoUrl: streamUser.image,
            createdAt: cleanString(reaction.created_at),
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

      if (!activityId) {
        throw new HttpsError(
            "invalid-argument",
            "Missing activityId.",
        );
      }

      const client = getStreamFeedsClient();

      try {
        const response = await client.reactions.filter({
          activity_id: activityId,
          kind: "comment",
          limit,
        });

        const results = Array.isArray(response.results) ?
          response.results :
          [];

        const comments = results.map((item) => {
          const data = item && item.data ? item.data : {};

          return {
            id: cleanString(item && item.id),
            userId: cleanString(item && item.user_id),
            text: cleanString(data.text),
            authorUid: cleanString(data.authorUid) ||
              cleanString(item && item.user_id),
            authorName: cleanString(data.authorName) || "Pingmee user",
            authorPhotoUrl: cleanString(data.authorPhotoUrl),
            createdAt: cleanString(item && item.created_at),
          };
        });

        return {
          ok: true,
          count: comments.length,
          comments,
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
