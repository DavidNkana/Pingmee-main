# Pingmee Firestore Schema (MVP + future-proof)

This file defines Firestore collections and fields.
DO NOT create random fields outside this schema.
All app screens must follow this schema.

---

## 1) users/{uid}

Purpose:
- Profile
- Discovery settings
- Interests
- Last known location

Document fields:

users/{uid} = {
  // Identity
  fullName: string,
  username: string,
  bio: string,
  age: number,
  gender: string,
  pronouns: string,
  photoUrl: string,
  email: string,
  phone: string,

  // Discovery
  visibilityMode: "public" | "interests_only" | "followers_only" | "invisible",
  distanceMiles: number,
  interests: [string],
  skills: [string],

  // Location
  lastLocation: {
    geopoint: GeoPoint,
    geohash: string
  },
  lastLocationUpdatedAt: timestamp,

  // Permissions toggles
  permissions: {
    location: boolean,
    notifications: boolean
  },

  // Flags
  onboardingComplete: boolean,
  profileLevel: number,

  // System
  createdAt: timestamp,
  updatedAt: timestamp,
  lastActiveAt: timestamp
}

Default values on signup:
- visibilityMode = "public"
- distanceMiles = 3
- interests = []
- permissions = { location: false, notifications: false }
- onboardingComplete = false
- profileLevel = 1

---

## 2) pings/{pingId}

Purpose:
- Map pins
- Feed cards
- Create ping

Document fields:

pings/{pingId} = {
  creatorId: string,   // uid

  // Content
  type: "hangout" | "help" | "event" | "trade" | "other",
  text: string,
  tags: [string],
  media: { photoUrl: string },

  // Geo
  location: {
    geopoint: GeoPoint,
    geohash: string
  },
  city: string,

  // Reach
  radiusMiles: number,
  visibilityMode: "public" | "interests_only" | "followers_only" | "invisible",

  // Lifecycle
  status: "active" | "ended" | "deleted",
  createdAt: timestamp,
  expiresAt: timestamp,         // default now + 24h
  pinnedUntil: timestamp,       // premium

  // Group chat
  chatId: string,

  // Counters
  participantCount: number,
  commentCount: number
}

Default values on ping creation:
- status = "active"
- expiresAt = now + 24 hours
- pinnedUntil = null
- chatId = ""
- participantCount = 0
- commentCount = 0

Premium rule:
- If pinnedUntil exists and pinnedUntil > now => ping is active even if expiresAt passed

---

## 3) chats/{chatId}

Purpose:
- DMs and group chats

Document fields:

chats/{chatId} = {
  type: "dm" | "group",
  members: [string],       // uids
  memberCount: number,
  admins: [string],

  title: string,
  photoUrl: string,

  pingId: string,
  eventId: string,

  lastMessage: {
    text: string,
    senderId: string,
    createdAt: timestamp,
    type: "text" | "system"
  },

  createdAt: timestamp,
  updatedAt: timestamp
}

---

## 4) chats/{chatId}/messages/{messageId}

Document fields:

messages/{messageId} = {
  senderId: string,
  type: "text" | "system" | "image",
  text: string,
  mediaUrl: string,
  createdAt: timestamp
}
