# Link Previews in Feed Moments (Stream-way)

**Date:** 2026-07-23
**Status:** Draft — awaiting user review
**Owner:** Alex (orchestration) + Anthony (plan) + Sacha (implementation)

## Goal

When a user posts a moment containing a URL, the feed renders a
**link preview card** below the text — exactly how Stream Chat
renders a link preview on a message. The card shows the site's
name, title, description, and thumbnail image. Tapping the card
opens the URL in the device browser.

For YouTube / video URLs the thumbnail is the video poster; the
card is otherwise identical (a video-type Play overlay is a
nice-to-have but the thumbnail is the user-visible artifact that
matters most).

**Status on master:** Most of this is already shipped. v78
(via `ping_files/functions/index.js` `_scrapeLinkPreview` +
`shared_moment_widgets.dart` `_LinkPreviewCard`) wires the full
server-side scrape → Firestore mirror → read-path unwrap →
client card render. The gaps are listed under "Deltas" below.

## What Already Works (v78, on master)

### Backend
- `_scrapeLinkPreview(rawUrl)` helper (`index.js` line 850):
  - URL validation + SSRF guard (refuses private/loopback hosts)
  - `fetch()` with 5s `AbortController` timeout, 1MB body cap
  - OG meta tag parsing: `og:title`, `og:description`, `og:image`,
    `og:site_name`; Twitter card fallback for image
  - Relative URL resolution against the page URL
  - HTML entity decoding
  - Title truncation, description truncation, image resolution
  - Returns `{url, title, description, image, siteName}` or `null`
- `createMomentV2` calls `_scrapeLinkPreview` on the first URL in
  the moment text (line 1303), attaches the result to
  `activity.linkPreview` and to `moments/{id}.linkPreview` on
  Firestore (line 1345)
- `scrapeLinkPreview` exposed as a separate callable (line 1003)
  so the client can request a preview independently

### Client
- `_LinkPreviewCard` widget (`shared_moment_widgets.dart` line
  1757) renders the OG card with image, title, description,
  siteName, tap-to-open via `url_launcher`
- `SharedMomentCard` and `SharedOriginalCard` check
  `data["linkPreview"] is Map` and render the card after the body
  text (line 338-345)
- `loadMyTimelineMoments` and `loadSingleActivity` unwrap
  `activity.linkPreview` so the field survives the round trip
  (lines 2026-2028, 2246-2248)

## Deltas (what this design adds)

### Delta 1: Extend the OG timeout from 5s to 30s

User picked 30s as the budget for slow sites. The v78 code uses
5s; some pages (news sites with redirects, AMP pages, social
media share URLs) genuinely take 6-10s to respond. Bumping to
30s gives those pages a chance without making the post feel
slow (typical OG response is 1-3s).

**Change:** `_scrapeLinkPreview` accepts an optional
`timeoutMs` parameter (default 30000), passed in by
`createMomentV2`. The hard cap stays at 30s — anything beyond
that is treated as a fail.

### Delta 2: Add `type` field ("link" vs "video")

The current scraper returns a flat object with no `type`. The
client treats everything as a generic link card. For YouTube /
Vimeo URLs the image is the video thumbnail (works visually)
but there's no "Play" affordance and no distinction in the
data.

**Change:** `_scrapeLinkPreview` returns an additional `type`
field. Detected via:
- If the URL hostname matches `youtube.com`, `youtu.be`,
  `vimeo.com`, `dailymotion.com` → `type: "video"`
- Else if `og:type` is `video.*` → `type: "video"`
- Else if the page has `og:video` or `og:video:url` →
  `type: "video"`
- Else → `type: "link"`

The client widget renders a small Play overlay (semi-transparent
black circle, white triangle) on top of the image when
`type == "video"`. Subtle, but communicates "tap to play" vs
"tap to read".

### Delta 3: Make URLs tappable inline in the moment body

The moment text is currently rendered as a plain `Text` widget.
If the user writes "Check this out https://x.com" the URL is
visible but not tappable — they have to copy-paste it into a
browser, which is a poor UX. Stream Chat makes URLs in the
message body tappable inline.

**Change:** in `shared_moment_widgets.dart`, replace the plain
`Text(text)` (and the italic repost variant) with a helper that
splits the text by URL regex and wraps each URL in
`TextSpan` with a `TapGestureRecognizer` that calls
`launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)`.
URLs are styled blue + underlined. Punctuation adjacent to the
URL (`,`, `.`, `!`, `?`, etc.) stays outside the tappable span.

### Delta 4: Tappable inline URLs everywhere moment text is shown

There are at least 3 places the moment text gets rendered:
1. `SharedMomentCard` — full moment card in the feed
2. `SharedOriginalCard` — original moment in a quote repost
3. Possibly a comment snippet, a search result snippet, a
   repost preview snippet

Apply the inline-tappable helper in all of them. Quick search
to confirm.

## Data Flow (post-design)

```
User posts: "Check this out https://www.youtube.com/watch?v=xyz"
            │
            ▼
   createMomentV2 cloud function
            │
            ├─ findFirstUrl(text) — uses existing first-URL regex
            │
            ├─ _scrapeLinkPreview(url, 30000) — extended with:
            │   • 30s timeout
            │   • type detection (video vs link)
            │   • YouTube / Vimeo / Dailymotion host match
            │
            ├─ result: {
            │   url, title, description, image, siteName,
            │   type: "video"  ← NEW
            │ }
            │
            ├─ Write activity.linkPreview to Stream
            └─ Mirror to Firestore moments/{id}.linkPreview
            │
            ▼
       Flutter client
            │
            ├─ _LinkPreviewCard renders card with:
            │   • image (network, fallback placeholder)
            │   • site name
            │   • title
            │   • description
            │   • Play overlay if type == "video"  ← NEW
            │   • Tap → launchUrl
            │
            └─ Body text rendered with tappable inline URLs  ← NEW
                  "Check this out [https://..." (blue, tappable)
```

## Component Changes

### Backend (`ping_files/functions/index.js`)

**Modify `_scrapeLinkPreview` (line 850):**
- Add optional `timeoutMs` param (default 30000; `createMomentV2`
  passes 30000 explicitly)
- After the URL is validated, detect `type`:
  ```js
  const host = (parsed.hostname || "").toLowerCase();
  const isVideoHost = (
    host === "youtu.be" ||
    host === "youtube.com" ||
    host === "www.youtube.com" ||
    host === "m.youtube.com" ||
    host === "vimeo.com" ||
    host === "www.vimeo.com" ||
    host === "dailymotion.com" ||
    host === "www.dailymotion.com"
  );
  const ogType = metaContent(body, { property: "og:type" });
  const hasOgVideo = !!(
    metaContent(body, { property: "og:video" }) ||
    metaContent(body, { property: "og:video:url" })
  );
  const type = (isVideoHost || ogType.startsWith("video") || hasOgVideo)
    ? "video" : "link";
  ```
- Include `type` in the returned object (after the title
  truncation block)
- Bump default timeout to 30s

**Modify `createMomentV2` (line 1303):**
- Pass `30000` as the explicit timeout to
  `_scrapeLinkPreview(url)`:
  `const linkPreview = await _scrapeLinkPreview(urlMatch[0], 30000);`

### Client (`ping_files/lib/main_app/tabs/feed/shared_moment_widgets.dart`)

**New widget `_TappableRichText`:**
- Stateless, takes `String text` and a `TextStyle baseStyle`
- Splits text by `RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false)`
- Strips trailing punctuation from each URL match
  (`.`, `,`, `!`, `?`, `;`, `:`, `)`, `]`, `"`, `'`) back into
  plain text segments
- Returns `Text.rich(TextSpan(children: [...]))` with plain
  text spans and tappable URL spans
- URL style: `baseStyle.copyWith(color: AppColors.brandGreen,
  decoration: TextDecoration.underline)`. Tap → `launchUrl`

**Modify `SharedMomentCard` (line 305+) and `SharedOriginalCard`
(line 700+):**
- Replace the plain `Text(text, ...)` and italic `Text('"$text"', ...)`
  with `_TappableRichText(text: text, baseStyle: ...)`
- Add a `const SizedBox(height: 8)` between the text and the
  link preview card (already 10; no change needed if it's there)

**Modify `_LinkPreviewCard` (line 1757):**
- Add `type` field to the preview map extraction: `final type = _str("type");`
- Wrap the `Image.network` in a `Stack` and overlay a small Play
  badge when `type == "video"`:
  ```dart
  if (type == "video" && image.isNotEmpty)
    Positioned.fill(
      child: Align(
        alignment: Alignment.center,
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(.6),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.play_arrow, color: Colors.white, size: 28),
        ),
      ),
    )
  ```

**Find + fix any other `Text(text)` rendering of moment text.**
Search the file for `Text(text,` and `Text('"$text"'` patterns
plus any place the text is rendered from `data["text"]` etc.

## Error Handling (unchanged from v78)

| Failure | Behavior |
|---|---|
| Text has no URL | No linkPreview. Post succeeds. No card. |
| URL fetch throws (network down) | `_scrapeLinkPreview` returns `null`. Post succeeds. No card. |
| URL fetch times out (>30s now, was 5s) | Returns `null`. Post succeeds. No card. |
| Response body > 1MB | Returns `null`. No card. |
| No OG tags in response | Returns `null` (no title/description/image). No card. |
| `launchUrl` fails in client | SnackBar "Couldn't open link" (existing pattern). |
| Image network fails | Card shows title + description + site name with a grey link icon placeholder (existing). |

## Testing

Backend (Anthony + Sacha):
1. Post moment with `https://www.youtube.com/watch?v=dQw4w9WgXcQ` → verify `linkPreview.type == "video"` and the title/image/description populate from YouTube's og:* tags
2. Post with `https://www.nytimes.com/` → verify `type == "link"` and a real image+title come back
3. Post with a 404 URL → verify post succeeds with no linkPreview
4. Post with a slow page (>5s, <30s) → verify the post returns within ~10s and linkPreview populates
5. Post with a slow page (>30s) → verify the post returns within ~32s and no linkPreview
6. Post with a private IP (e.g. `http://10.0.0.1`) → verify the scraper refuses (SSRF guard) and no linkPreview

Client (Jobs + Handre):
1. Post moment with YouTube URL → card shows thumbnail + "YouTube" label + video title, with a Play overlay in the center
2. Post moment with article URL → card shows image + title + description + site name, no Play overlay
3. Tap card → browser opens
4. Tap inline URL in the text body → browser opens
5. Body text shows the URL in blue with underline; punctuation outside the link
6. Post moment with no URL → no card, no inline link
7. Post with URL to a site that fails OG → no card but the URL in text is still tappable
8. Test on quoted repost text (`'"$text"'`) — italic but URLs still tappable
9. Test the case where two URLs are in the text — both tappable, only the first gets a card

Deployment verification:
1. `firebase deploy --only functions:createMomentV2` (one function at a time to dodge the v94 CPU quota issue)
2. Post a moment with a real URL → check Firebase function logs for `v78 _scrapeLinkPreview` lines
3. Verify activity in Stream dashboard shows `linkPreview` field
4. Pull client, run, post → card renders

## Files Changed

Backend:
- `ping_files/functions/index.js` — extend `_scrapeLinkPreview`
  with timeoutMs param + type detection; pass 30000 from
  `createMomentV2`

Client:
- `ping_files/lib/main_app/tabs/feed/shared_moment_widgets.dart`
  — add `_TappableRichText` helper; replace plain `Text(text)` in
  `SharedMomentCard` and `SharedOriginalCard`; extend
  `_LinkPreviewCard` with `type` field + Play overlay

No new dependencies on either side.

## Risks

1. **Cloud Run CPU quota** (same as v94). Workaround: deploy
   `createMomentV2` alone. If still hitting quota, bump
   `maxInstances` or split the function.
2. **30s in-band scrape means slow posts.** In the worst case
   (target site is dead-slow), the post takes 32s. Most users
   won't hit this. For an MVP it's acceptable; a future v2
   could move scraping to a background function (with the
   card appearing after enrichment).
3. **YouTube rate limiting.** YouTube's robots.txt is fine
   for our `User-Agent: PingmeeBot/1.0`; if they ever block,
   video URLs just won't have a card (but the URL stays
   tappable in the text). Acceptable degradation.
4. **Sites without OG tags.** Maybe 20% of sites. No card, URL
   still tappable. Acceptable.

## Decision Log

- **2026-07-23 — A vs B (one card vs many):** A (first URL only,
  inline tappable for the rest). Matches Stream Chat.
- **2026-07-23 — Sync vs async scrape:** A (in-band, 30s
  timeout, fail-silent). Same UX as Stream Chat.
- **2026-07-23 — Third-party vs hand-rolled:** Use existing v78
  hand-rolled scraper (no new dependency). Just extend it.
- **2026-07-23 — Spec location:** Repo
  `ping_files/docs/superpowers/specs/2026-07-23-link-previews-design.md`.
  No local copy retained.

## What's NOT in this design (deferred)

- Background (async) scraping with placeholder card → enriched
  card upgrade
- Multiple cards per moment (multiple URLs each get a card)
- Open Graph for non-public URLs (SSRF guard stays)
- Per-domain scraper rules (YouTube could return duration,
  channel name, view count)
- Iframe / video playback in the card (the card just opens the
  browser to the watch URL; that's correct UX for now)
- Caching scraped previews to avoid re-scraping the same URL
  for every user (Firestore cache layer)
