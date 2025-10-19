# agents.md 

## Mission
Build a native **tvOS** SwiftUI app that signs into a user’s **Plex** account (via **plex.tv/link**), browses their libraries, and creates **fake “live TV” channels** from their media. Tuning a channel computes the **wall-clock offset** for the current item and plays a **standard Plex stream** (direct or Plex-transcoded)—no server-side stitching or hosting.

## What success looks like
- Link with **plex.tv/link**; fetch servers/libraries; prove access with posters/quick-play.
- Create channels from libraries with simple **filters + sort**, store locally, and **auto-play** with Now/Next.
- Smooth tvOS focus/remote experience; one clear primary action per view.

## Scope & non-goals
- Scope: **tvOS 17+**; SwiftUI + AVKit (`VideoPlayer`); client-only persistence (Keychain, UserDefaults).
- Non-goals: custom muxers, server infrastructure, Emby/Jellyfin in MVP (keep interfaces modular so they can be added later).

## Guardrails
- Use **documented Plex endpoints** and **X-Plex-\*** headers with a stable **client identifier**; token required post-auth.  [oai_citation:0‡developer.plex.tv](https://developer.plex.tv/pms/?utm_source=chatgpt.com)
- Prefer **HTTPS** connection URIs (e.g., `plex.direct`) and comply with **App Transport Security (ATS)**; avoid weakening ATS.  [oai_citation:1‡Apple Developer](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity?utm_source=chatgpt.com)
- Store tokens in **Keychain**; never persist passwords.

## External interfaces (Plex)
- **Device link PIN:**  
  `POST https://plex.tv/api/v2/pins?strong=false` → `{ id, code, qr, expiresAt }`  
  `GET  https://plex.tv/api/v2/pins/{id}` → `{ authToken }` (poll until present).  [oai_citation:2‡python-plexapi.readthedocs.io](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/myplex.html?utm_source=chatgpt.com)
- **Server discovery:**  
  `GET https://plex.tv/api/resources?includeHttps=1&includeRelay=1` with `X-Plex-Token`.  [oai_citation:3‡developer.plex.tv](https://developer.plex.tv/pms/?utm_source=chatgpt.com)
- **Libraries & items:**  
  `GET {server}/library/sections` and `.../sections/{id}/all` (collect ids, titles, duration, thumb, type/genre).  
- **Playback:**  
  Prefer **direct part** URL when compatible; fallback to Plex **universal HLS transcode**. (All with `X-Plex-Token`.)  [oai_citation:4‡Postman](https://www.postman.com/fyvekatz/m-c-s-public-workspace/documentation/f2uw7pj/plex-api?utm_source=chatgpt.com)

## Architecture (high level)
- **AuthState** (ObservableObject): holds `PlexSession { userToken, serverURI, serverAccessToken }`.
- **PlexService**: networking (PIN flow, resources, libraries, items, quick-play URL).
- **ChannelManager**: create/seed/list channels; schedule math; persistence.
- **Views**: `LinkLoginView`, `ChannelsView`, `LibraryPickerView`, `ChannelWizardView`, `PlayerView`.
- **Scheduling**: given `startTime` and ordered `[Item(duration)]`, compute `(index, offset)` by modular accumulation; expose **Now/Next** and **time-left**.

## Data model (MVP)
- `PlexLibrary { id, title, type }`
- `PlexItem { id, title, durationSec, thumbPath, kind, genres[], addedAt }`
- `Channel { id, name, itemIDs[], startTime, options{ shuffle, sort } }`

## UX principles
- First run must **prove link** (posters + quick-play) and **nudge** to create a channel.
- Exactly **one primary CTA** per screen; predictable tvOS **focus**; obvious highlight states.
- Channel rows show **Now / Next** with a ticking countdown.

---

## Recent updates
- Task 22 summary: removed inline delete controls from channel cards, moved channel management to a future workflow, and upgraded focus handling to tvOS 17-style `FocusState` with two-parameter `onChange`.
- Task 23 summary: hardened channel playback negotiation with richer Plex query headers, direct-vs-transcode logging, and Quick Play reuse of prepared stream descriptors.

---

## Milestones & Tasks (1–23)

**1. Env setup** — Create SwiftUI tvOS app in Xcode; run on simulator.  
**2. Plex API plumbing** — Add headers/client ID; auth & resources; libraries fetch.  
**3. Login screen** — Basic username/password (later superseded by PIN); persist token; route to main.  
**4. Libraries + Channel model** — Fetch libraries; define `Channel`; prepare schedule fields.  
**5. Channels screen** — List channels; navigation to player; empty state.  
**6. Playback** — `AVPlayer`/`VideoPlayer`; compute offset; replace item on end.  
**7. Test & hardening** — Error handling, retries, small perf fixes.

**8. Header/status strip** — Show “Linked to {User} · {Server} · {N} libraries” with a single **Add Channel** CTA; remove duplicate buttons.  
**9. First-run flow** — If no channels, auto-present **LibraryPicker** (sheet).  
**10. Light wizard** — Two steps: name/shuffle/start; preview current `(item, offset)`; create/persist channel.  
**11. Proof carousel** — “From your libraries” posters with **Quick Play**; validates streams.  
**12. Now/Next on rows** — Compute & display current and upcoming item; update every 30s.  
**13. Focus polish** — Clear highlight/focus animations; default focus rules.

**14. Fix selection bugs** — Make posters and library rows real `Button`s with `.focusEffect(.highlight)`; selection triggers action (play/pick).  
**15. Picker → Wizard wiring** — Library selection sets `pickedLibrary`; presents `ChannelWizard` sheet; cancel returns.  
**16. Default seeded channels** — On first run (once), auto-create: Movies—Mix, Movies—Action, TV—Mix, TV—Comedy (client-side filters).  
**17. MVP Advanced Filters** — Wizard adds: multi-library selection; filters (Genre, Year ≥/≤/=, Duration ≥/≤); sort (Random, Title A–Z, Date Added).  
**18. Now/Next correctness** — Rollover logic + countdown ticks; no restart needed.  
**19. Quick-Play polish** — Service method prefers direct play, falls back to HLS; show title; restore focus on back.  
**20. UX cleanup** — Enforce single-CTA rule; empty state = copy only; when ≥1 channel, default focus = first channel.
**21. Remote Connections** - Prioritized remote Plex endpoints after PIN linking to avoid off-LAN stalls and added connection ordering tests.
**22. Channel management workflow** — Move delete/edit actions into a dedicated management flow, restore removal once UX is ready, and adopt `FocusState` + tvOS 17 `onChange` semantics to resolve focus deprecation warnings.
**23. Stream reliability** — Ensure channel/Quick Play taps negotiate direct vs transcode streams with full Plex headers, expose diagnostics, and surface playback errors.

---

## Compliance Addendum (Plex + Apple)

### Plex (legal & API use)
- **TOS scope**: Your app must access and display **only the user’s own Plex content** and services in accordance with Plex’s Terms of Service (no scraping, no redistribution, no resale of Plex services). Don’t imply affiliation or create an agency relationship.  [oai_citation:5‡Plex](https://www.plex.tv/about/privacy-legal/plex-terms-of-service/?utm_source=chatgpt.com)
- **Headers & identity**: Always send the required **X-Plex-\*** headers (stable **Client-Identifier**, Product, Platform, Device, Version). Do **not** rotate identifiers to evade rate-limits or tracking; use a consistent UUID per install.  [oai_citation:6‡developer.plex.tv](https://developer.plex.tv/pms/?utm_source=chatgpt.com)
- **Auth (plex.tv/link)**: Use the official **PIN** flow only: create a PIN, poll for `authToken`, then use that token for resource discovery and playback. Do **not** capture or store the user’s Plex password.  [oai_citation:7‡python-plexapi.readthedocs.io](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/myplex.html?utm_source=chatgpt.com)
- **Branding/trademarks**: Do not use Plex’s **name or logos** in your app **icon**, **app name**, or marketing in a way that implies endorsement. Follow Plex trademark guidelines; seek written permission for any logo usage beyond nominative references.  [oai_citation:8‡Plex](https://www.plex.tv/about/privacy-legal/plex-trademarks-and-guidelines/?utm_source=chatgpt.com)
- **Content rights**: Never provide third-party media or facilitate piracy. Your app only schedules and plays what the user already has in Plex. (Plex API access requires a valid token; unauthorized requests return 401.)  [oai_citation:9‡Postman](https://www.postman.com/fyvekatz/m-c-s-public-workspace/documentation/f2uw7pj/plex-api?utm_source=chatgpt.com)

### Apple (App Store & platform)
- **Public APIs only**: Use only documented tvOS APIs; no private frameworks or SPI. This is a common rejection (App Store Review Guideline **2.5.1**).  [oai_citation:10‡Apple Developer](https://developer.apple.com/app-store/review/guidelines/?utm_source=chatgpt.com)
- **Networking (ATS)**: All network calls must be **HTTPS** and meet **ATS** requirements; if a non-HTTPS URI is unavoidable, document and narrowly scope ATS exceptions—but the goal is **no exceptions** (use `https` `plex.direct` endpoints).  [oai_citation:11‡Apple Developer](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity?utm_source=chatgpt.com)
- **Reader-style access**: It’s acceptable for users to sign in to an external account (Plex) to access content acquired elsewhere, provided the app doesn’t **sell** digital content or features that require **IAP**. Avoid links or language that direct users to external purchasing flows inside the app. (See App Store Review Guidelines sections on reader apps and payments.)  [oai_citation:12‡Apple Developer](https://developer.apple.com/app-store/review/guidelines/?utm_source=chatgpt.com)
- **Privacy**: Declare data practices in App Privacy; do not collect sensitive data beyond what’s necessary (token, basic device info). No device fingerprinting or tracking without consent.
- **IP & naming**: Avoid app names or descriptions that could confuse users about affiliation with Plex (Guideline **5.2** intellectual property).  [oai_citation:13‡Apple Developer](https://developer.apple.com/app-store/review/guidelines/?utm_source=chatgpt.com)

### Engineering controls we will implement
- **Keychain-only token**; no password storage; logout clears token and local caches.  
- **Stable Client ID** persisted once; standard **X-Plex** headers on every call.  [oai_citation:14‡developer.plex.tv](https://developer.plex.tv/pms/?utm_source=chatgpt.com)  
- **HTTPS-only** transport; choose `https` connections from `/api/resources`; no ATS exceptions.  [oai_citation:15‡Apple Developer](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity?utm_source=chatgpt.com)  
- **Branding hygiene**: App name/icons avoid Plex marks; copy uses nominative “works with your Plex library” phrasing only.  [oai_citation:16‡Plex](https://www.plex.tv/about/privacy-legal/plex-trademarks-and-guidelines/?utm_source=chatgpt.com)  
- **No commerce**: No external purchasing links; no IAP needed to access the user’s own content.  [oai_citation:17‡Apple Developer](https://developer.apple.com/app-store/review/guidelines/?utm_source=chatgpt.com)

---
