# PlexChannelsTV - AI Agent Guide

## Mission
Native **tvOS 17+** SwiftUI app that creates **fake "live TV" channels** from a user's Plex library. Users link their Plex account, select libraries, and the app automatically generates 24/7 channels that play content in a loop with computed wall-clock offsets. No server-side infrastructure—everything is client-side.

---

## Current State (What Works)

### Authentication & Connection
- ✅ **PIN-based auth** via `plex.tv/link` (no password storage)
- ✅ **Remote connection priority** - prefers non-relay HTTPS endpoints
- ✅ **Token persistence** in Keychain via `KeychainStorage`
- ✅ **Auto-reconnect** on app launch if session exists
- ✅ **Server fallback** - tries multiple connection URLs if one fails

### Channel System
- ✅ **Default seeded channels** - Auto-creates 4 channels on first run
- ✅ **Persistent storage** - Channels saved to disk (Documents/channels.json)
- ✅ **Scheduling algorithm** - Modular arithmetic for 24/7 loops
- ✅ **Now/Next computation** - Shows current item + upcoming with countdown
- ✅ **30-second refresh** - TimelineView updates countdown automatically

### Artwork & UI
- ✅ **Plex artwork transcoding** - Properly encoded URLs with nested tokens
- ✅ **ClearLogo support** - Movie logos overlay on backgrounds
- ✅ **Smart loading states** - No text flash before logos load
- ✅ **Cached images** - NSCache with 150 item limit, 128MB
- ✅ **Aligned layout** - Channel names + "Up Next" on same baseline
- ✅ **Full-screen content** - No unwanted padding/clipping

### Playback
- ✅ **Direct play** - Prefers native streams when codec-compatible
- ✅ **HLS transcode fallback** - Conservative 8Mbps start, adaptive downshift on issues
- ✅ **Smart buffering** - 12-second forward buffer (up from 3s) for smoother playback
- ✅ **Proactive quality adjustment** - Detects low throughput in 5s, drops to 60% on first stall
- ✅ **Force remux for MKV** - Copies streams without re-encoding
- ✅ **Computed offsets** - Seeks to correct wall-clock position
- ✅ **Coordinator pattern** - Centralized playback state management

### User Interaction (tvOS-specific)
- ✅ **Button focus** - Standard tvOS scale + parallax with `.buttonStyle(.plain)`
- ✅ **Long-press menus** - Via `.onPlayPauseCommand` + `confirmationDialog`
- ✅ **Focus restoration** - Returns focus after sheet dismissal
- ✅ **Structured logging** - `os.log.Logger` with categories for debugging

---

## Architecture

### Core Services

#### `PlexService` (Networking)
**Purpose**: All Plex API communication + artwork URL construction  
**Key Methods**:
- `establishSession()` - PIN auth → server selection → library fetch
- `streamURLForItem()` - Negotiates direct vs transcode with fallback logic
- `backgroundArtworkURL()` / `posterArtworkURL()` / `logoArtworkURL()` - Transcoded image URLs
- `buildTranscodedArtworkURL()` - **Critical**: Adds token to nested URL then URL-encodes

**Important**: This service manages token types (server vs account) and tries both on 401 errors.

#### `ChannelStore` (State)
**Purpose**: Manages channel CRUD + persistence  
**Storage**: `Documents/channels.json` (not UserDefaults - too large)  
**Key Methods**:
- `loadChannelsFromDisk()` / `saveChannelsToDisk()` - JSON persistence
- `channel(for: PlexLibrary)` - Finds existing channel for library
- `add()` / `remove()` - Triggers automatic disk save

**Important**: Uses `@Published var channels: [Channel]` so SwiftUI auto-updates.

#### `ChannelsCoordinator` (Playback)
**Purpose**: Centralized playback state machine  
**Pattern**: ObservableObject that views inject into ChannelPlayerView  
**Key Methods**:
- `present(request: ChannelPlaybackRequest)` - Queues playback
- `dismiss()` - Clears player

**Why**: Prevents multiple player instances and manages transitions cleanly.

#### `ImageCache` (Performance)
**Purpose**: In-memory NSCache for Plex artwork  
**Configuration**: 
- `countLimit: 150` (max images)
- `totalCostLimit: 128MB`
- Cost = `width × height × scale²`

**Pattern**: `CachedAsyncImage` wrapper that checks cache before network fetch.

### Data Models

#### `Channel`
```swift
struct Channel {
    let id: UUID
    let name: String
    let libraryKey: String
    let libraryType: PlexMediaType
    let scheduleAnchor: Date  // Start time for 24/7 loop
    let items: [Media]
}
```

**Scheduling Logic** (`playbackPosition(at:)`:
1. Calculate elapsed time since `scheduleAnchor`
2. Modulo by `totalDuration` to get position in loop
3. Walk through items subtracting durations until we find current item
4. Return `(index, media, offset)`

#### `Channel.Media`
```swift
struct Media {
    let id: String  // Plex ratingKey
    let title: String
    let duration: TimeInterval
    let artwork: Artwork {
        thumb, art, parentThumb, grandparentThumb,
        grandparentArt, grandparentTheme, theme
    }
}
```

**Artwork Candidate Priority**:
- **Background**: `art` → `grandparentArt` → `thumb` → `parentThumb` → `grandparentThumb`
- **Poster**: `thumb` → `parentThumb` → `grandparentThumb` → `art` → `grandparentArt`
- **Logo**: `/library/metadata/{id}/clearLogo` → `grandparentTheme` → `theme`

**Why clearLogo first**: Plex stores movie logos at predictable path, so we try it first even though it's not in metadata.

### Views

#### `ChannelsView` (Main Screen)
**Layout**:
```
VStack {
  header (user info + Add Channel + Force Play Now)
  HStack(alignment: .top) {
    nowColumn {
      channel name (headline, secondary)
      nowCard (560×315 with background + logo)
      nowDetails (title + "Now Playing · X:XX left")
    }
    upNextColumn {
      "Up Next" (headline, secondary)
      ScrollView (horizontal posters 180×270)
    }
  }
}
.padding(.horizontal, 80)
.padding(.top, 40)
// NO .padding(.bottom) - let content extend to edge
```

**Critical**: Remove all `Spacer(minLength: 0)` that push content up and cause clipping.

#### `ChannelRowView` (Individual Channel)
**Pattern**: Each channel is a standalone row with:
- `TimelineView(.periodic(from: .now, by: 30))` - Auto-updates countdown
- `@FocusState` for focus management per button
- `.onPlayPauseCommand` for long-press → `confirmationDialog`

**Button Structure** (MUST FOLLOW):
```swift
Button { action } label: {
  // content (ZStack for artwork)
}
.frame(width: W, height: H)
.clipShape(RoundedRectangle(...))  // ← Clip BEFORE buttonStyle
.buttonStyle(.plain)  // ← Use .plain for custom content
.focused($focusState, equals: id)
.onPlayPauseCommand { menuTarget = .now }
```

**Why this order**: `.clipShape` BEFORE `.buttonStyle` ensures focus highlight stays within rounded bounds.

#### `ChannelPlayerView` (Playback)
**Pattern**: Full-screen `VideoPlayer` with overlay controls  
**Features**:
- Adaptive bitrate on stalls (downgrades from 10Mbps → 7Mbps)
- Watchdog timer (5s) to detect coordinator issues
- Error handling with retry logic
- Logging for diagnostics (`event=play.*`)

---

## Critical Patterns (MUST FOLLOW)

### 1. tvOS Button Interactions

**✅ DO THIS**:
```swift
Button { primaryAction() } label: { content }
    .buttonStyle(.plain)
    .onPlayPauseCommand { showMenu = true }

.confirmationDialog("", isPresented: $showMenu) {
    Button("Option 1") { action1() }
    Button("Option 2") { action2() }
    Button("Cancel", role: .cancel) {}
}
```

**❌ NEVER DO THIS**:
```swift
Button { action } label: { content }
    .onLongPressGesture { }  // ← BLOCKS TAP
    .contextMenu { }  // ← PREVENTS PRIMARY ACTION
```

**Why**: On tvOS, `.onLongPressGesture` intercepts tap events, and `.contextMenu` prevents the button's primary action from firing. Always use `.onPlayPauseCommand` for secondary actions.

### 2. Plex Artwork URLs

**The Problem**: Plex transcoder requires **nested URL with token**, then **URL-encoded**.

**Wrong** (causes 404):
```swift
url=/library/metadata/123/thumb/456
// Plex can't parse unencoded URL in query param
```

**Right**:
```swift
// 1. Build target URL with token
let target = baseURL + "/library/metadata/123/thumb/456?X-Plex-Token=ABC"

// 2. Use URLComponents (auto-encodes)
URLQueryItem(name: "url", value: target.absoluteString)
// Result: url=https%3A%2F%2Fserver%3A32400%2Flibrary%2F...
```

**Implementation**: See `PlexService.buildTranscodedArtworkURL()` lines 487-522.

### 3. Image Loading States

**Pattern for no flash before logo**:
```swift
CachedAsyncImage(url: logoURL) { phase in
    switch phase {
    case .success(let image):
        image  // Show logo
    case .failure:
        Text(fallback)  // Show text ONLY on failure
    case .empty:
        Color.clear  // Show nothing while loading
            .frame(height: 60)  // Maintain layout
    }
}
```

**Why**: Prevents text from flashing on screen before logo loads. Users see smooth appearance.

### 4. Channel Persistence

**Pattern**:
```swift
// Save entire array atomically
let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("channels.json")
let data = try JSONEncoder().encode(channels)
try data.write(to: url, options: .atomic)
```

**Why**: 
- Can't use `UserDefaults` - channel JSON is too large (>1MB with 800 items)
- Atomic write prevents corruption on crash
- Gracefully handles missing `artwork` field for backward compatibility

### 5. Focus Management

**Pattern**: Use `@FocusState` at parent level, pass binding to children:
```swift
// Parent (ChannelsView)
@FocusState private var focusedCard: FocusTarget?

// Child (ChannelRowView)
Button { } label: { }
    .focused($focusState, equals: .now(channelID))
```

**Why**: Centralized focus state prevents conflicts and enables programmatic focus changes.

---

## Troubleshooting Guide

### Artwork Not Loading (HTTP 404)

**Symptoms**: Gray rectangles instead of posters, logs show `event=image.load status=404`

**Diagnosis**:
```bash
# Check logs in Console.app
Subsystem: PlexChannelsTV
Category: Net

# Look for:
event=artwork.poster path=/library/metadata/XXX/thumb/YYY
event=image.load status=404 url=...
```

**Root Causes**:
1. **Nested URL not encoded** - See "Critical Patterns #2" above
2. **Missing token in nested URL** - Must be in BOTH outer and inner URL
3. **Wrong artwork path** - Check `Channel.Media.Artwork` has valid fields

**Fix**: Review `PlexService.buildTranscodedArtworkURL()` - it should add token to target URL first, then let URLComponents encode it.

### Buttons Not Responding to Taps

**Symptoms**: Short press does nothing, logs show no `event=channel.tap.action`

**Diagnosis**:
```bash
# Check logs
event=channel.focus channelID=XXX  # Focus works?
event=channel.tap.action  # Button pressed? (SHOULD see this)
event=channel.tap.received  # Handler called? (SHOULD see this)
```

**Root Causes**:
1. **`.onLongPressGesture` present** - Intercepts taps
2. **`.contextMenu` present** - Blocks primary action
3. **Gesture recognizer conflict** - Multiple competing handlers
4. **Button not actually focusable** - Missing `.focused()` modifier

**Fix**: Remove all gesture modifiers from Button, use clean structure from "Critical Patterns #1".

### Playback Stuttering/Buffering

**Symptoms**: Video pauses frequently, logs show `event=play.errorLog status=-12318`

**Diagnosis**:
```bash
# Check network logs
event=play.plan mode=hls remux=1 bitrateKbps=10000
event=play.accessLog observedKbps=5664  # < indicatedKbps!
event=play.recover cause=stall downshiftKbps=7000
```

**Root Causes**:
1. **Network congestion** - Observed bitrate < indicated
2. **Transcoding delay** - Plex server can't keep up
3. **Wrong stream type** - Should be remuxing MKV, not transcoding

**Fix**: 
- For MKV: Ensure `forceRemux=true` and `directStream=1` in HLS params
- Network issues: Let adaptive bitrate handle it (auto-downgrades)
- Check Plex server resources (CPU, disk I/O)

### Layout Clipping at Bottom

**Symptoms**: Second channel row cuts off, can't scroll to see full content

**Diagnosis**: Look for unwanted padding or spacers in layout hierarchy.

**Common Culprits**:
```swift
// BAD
VStack {
    channelList
    Spacer(minLength: 0)  // ← Pushes content up!
}
.padding(.vertical, 40)  // ← Bottom padding clips content

// GOOD
VStack {
    channelList  // ScrollView handles its own height
}
.padding(.horizontal, 80)
.padding(.top, 40)  // Only top, let bottom extend
```

**Fix**: Remove ALL `Spacer()` and `.padding(.bottom)` from containers around ScrollViews.

### Logo Loading but Text Still Shows

**Symptoms**: Movie title text flashes before logo appears

**Root Cause**: Loading state shows text fallback immediately.

**Fix**: Change `.empty` case to show `Color.clear` instead of text (see "Critical Patterns #3").

---

## Design Decisions & Rationale

### Why Client-Side Scheduling?

**Decision**: Compute playback position on device, not server.

**Rationale**:
- No server infrastructure needed
- Works offline once channels loaded
- Instant channel switching (just math, no API calls)
- Scales infinitely (no server load)

**Trade-offs**: 
- Channels must be pre-populated (can't add items dynamically)
- All users see same schedule (no personalization per device)

### Why Disk Storage for Channels?

**Decision**: Save to `Documents/channels.json` instead of UserDefaults.

**Rationale**:
- UserDefaults has ~1MB practical limit
- Channels with 800 items = ~2MB JSON
- Atomic file writes prevent corruption
- Easier to debug (can inspect JSON directly)

**Trade-offs**: Must handle file I/O errors gracefully.

### Why Coordinator Pattern for Playback?

**Decision**: Central `ChannelsCoordinator` manages all playback requests.

**Rationale**:
- Prevents multiple AVPlayer instances competing
- Single source of truth for playback state
- Easier to debug (all transitions logged)
- Can queue requests if player busy

**Trade-offs**: Slightly more complex wiring (must inject coordinator).

### Why CachedAsyncImage Instead of AsyncImage?

**Decision**: Custom wrapper with NSCache instead of SwiftUI's built-in.

**Rationale**:
- Control over cache limits (150 items, 128MB)
- Explicit cost calculation for better memory management
- Can prefetch images before they're visible
- Better logging for diagnostics

**Trade-offs**: More code to maintain.

### Why No Custom Video Player?

**Decision**: Use AVKit's `VideoPlayer` instead of custom AVPlayerLayer.

**Rationale**:
- Free system controls (play/pause, seek, info panel)
- Automatic tvOS integration (Now Playing, Control Center)
- Handles edge cases (audio sessions, interruptions)
- Less code = fewer bugs

**Trade-offs**: Can't heavily customize UI (but don't need to).

---

## Known Issues & Workarounds

### Issue: PIN Polling Continues After Link

**Status**: Fixed (Task 25)  
**Solution**: Cancel polling task in `onDisappear` of `LinkLoginView`.

### Issue: MKV Files Won't Direct Play

**Status**: Expected behavior  
**Reason**: tvOS doesn't natively support MKV container  
**Workaround**: Force remux (copy streams to HLS) - no transcoding needed, just container change.

### Issue: Focus Highlight Clips Rounded Corners

**Status**: Fixed (Task 27)  
**Solution**: Apply `.clipShape()` BEFORE `.buttonStyle()` so focus effect respects bounds.

### Issue: clearLogo Returns 404 for Some Movies

**Status**: Expected behavior  
**Reason**: Not all Plex movies have clearLogos  
**Workaround**: Fallback to text title (see "Critical Patterns #3").

### Issue: Channel Countdown Doesn't Update

**Status**: Fixed (Task 18)  
**Solution**: Use `TimelineView(.periodic(from: .now, by: 30))` instead of manual timer.

### Issue: Playback Skips Forward on Buffer Recovery

**Status**: Fixed (Task 28)  
**Symptoms**: When HLS stream stalls and recovers, playback jumps forward (e.g., from 1hr 46min to 3hr 8min)  
**Root Cause**: When using `copyts=1` (copy timestamps), AVPlayer's `currentTime()` returns absolute PTS from original file, not relative time. Recovery code was adding `entry.offset` to `currentSeconds`, double-counting the offset.  
**Solution**: Use `currentSeconds` directly as resume position since it's already absolute with `copyts=1`. See `ChannelPlayerView.attemptRecovery()` lines 569-580.

### Issue: Frequent Playback Stalls/Buffering

**Status**: Improved (Task 29)  
**Symptoms**: Repeated `MEDIA_PLAYBACK_STALL` events, especially on remote/WiFi connections  
**Root Causes**: 
1. Very small buffer (3s) left no headroom for network fluctuations
2. Aggressive initial bitrate (10Mbps) exceeded available bandwidth
3. Slow reaction to throughput issues (10s detection window)
4. Conservative downshift (30%) didn't free enough bandwidth

**Solutions Applied**:
1. **Increased buffer**: 3s → 12s forward buffer (`preferredForwardBufferDuration`)
2. **Conservative start**: 10Mbps → 8Mbps initial bitrate
3. **Faster detection**: 10s → 5s throughput monitoring window
4. **Aggressive first downshift**: 40% drop on first stall (vs 30%), gives immediate bandwidth headroom
5. **Earlier threshold**: Trigger at 60% throughput (vs 50%) to catch issues sooner

**Expected Result**: Significantly fewer stalls, smoother playback, but slightly longer initial buffering.

**Follow-up (Task 30)**: Initial improvements reduced stall frequency, but revealed Plex was still serving old bitrate segments after recovery due to session reuse. Added `forceNewSession` option to generate unique session IDs (with timestamp) on recovery, forcing Plex to start fresh transcoder with new bitrate immediately.

**Follow-up (Task 31)**: Added automatic retry for transient network errors (NSURLError -1008, -1009, -1005, -1001). Retries up to 2 times with 1-second delay and forces new session on each attempt. Prevents one-off failures from showing error overlay. **Important**: Only retries on initial playback startup - does NOT retry during stall recovery to avoid creating too many sessions and overwhelming Plex transcoder.

---

## Logging & Debugging

### Structured Logging

**Setup**: `os.log.Logger` with subsystem `PlexChannelsTV`

**Categories**:
- `App` - Lifecycle, session management
- `Channel` - Focus, button taps, menu actions
- `Playback` - Stream negotiation, player state
- `Net` - Network requests, image loading

**Usage**:
```swift
import OSLog
AppLoggers.net.info("event=image.load status=200 bytes=\(count)")
```

### Key Events to Monitor

**Auth Flow**:
```
event=session serverURI=... tokenKind=server
event=net.request method=GET url=.../library/sections
event=net.response status=200 elapsedMs=104
```

**Button Interaction**:
```
event=channel.focus channelID=XXX
event=channel.tap.action button=now
event=channel.tap.received handler=handlePlayNow
event=player.present route=cover source=tap
```

**Playback**:
```
event=play.plan mode=hls remux=1 bitrateKbps=10000
event=play.start itemID=XXX offsetSec=3296
event=play.status status=ready mode=hls
event=play.errorLog domain=CoreMediaErrorDomain status=-12318
```

**Artwork**:
```
event=artwork.background itemID=XXX path=/library/metadata/XXX/art/YYY
event=artwork.background.success mode=transcoded url=...
event=image.load status=starting url=...
event=image.load status=200 bytes=45123 url=...
event=image.load status=success url=...
```

### Console.app Filtering

**Quick Filters**:
```
subsystem:PlexChannelsTV
subsystem:PlexChannelsTV category:Net
subsystem:PlexChannelsTV eventMessage:CONTAINS "error"
subsystem:PlexChannelsTV eventMessage:CONTAINS "404"
```

---

## Future Considerations

### Potential Features
- [ ] Edit existing channels (currently can only add/remove)
- [ ] Custom channel artwork/branding
- [ ] Multiple server support (currently one server per session)
- [ ] TV show episode progression (watch next episode, not random)
- [ ] Time-based programming (holiday movies in December)

### Technical Debt
- [ ] Error handling in `ChannelSeeder` is overly broad (`catch { }`)
- [ ] No unit tests for scheduling math (should add property-based tests)
- [ ] Image cache doesn't have LRU eviction (just size-based)
- [ ] No retry logic for failed artwork loads

### Performance Optimizations
- [ ] Lazy load channel items (currently loads all 800 upfront)
- [ ] Virtual scrolling for Up Next (currently renders all visible)
- [ ] Image prefetching is greedy (prefetches 6 items even if not scrolling)

---

## Compliance Notes

**Plex API**:
- ✅ Use plex.tv/link (never store password)
- ✅ Stable client identifier (UUID persisted in Keychain)
- ✅ Standard X-Plex-* headers on every request
- ✅ HTTPS only (plex.direct endpoints)

**Apple**:
- ✅ Public APIs only (AVKit, SwiftUI, os.log)
- ✅ ATS compliant (all HTTPS, no exceptions)
- ✅ No commerce/IAP (free app, external content)
- ✅ Reader app (accesses user's existing Plex library)

**Branding**:
- ✅ No Plex logos in app icon
- ✅ Nominative use only ("works with your Plex library")

---

## Version History

**v1.0** (Tasks 1-29):
- ✅ PIN-based auth with server discovery
- ✅ Channel creation from Plex libraries
- ✅ 24/7 scheduling with Now/Next
- ✅ Full artwork support (posters, backgrounds, logos)
- ✅ Direct play + HLS transcode with adaptive bitrate
- ✅ Smart buffer recovery (preserves playback position)
- ✅ Optimized buffering strategy (12s buffer, 8Mbps start, proactive downshift)
- ✅ tvOS-native focus and interactions
- ✅ Structured logging for diagnostics

---

**Last Updated**: Task 31 (2025-10-22)  
**Status**: MVP Complete - All core features working, buffering optimized with automatic retry on transient errors
