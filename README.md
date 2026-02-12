# DVRR (PlexChannelsTV)

Native `tvOS 17+` SwiftUI app that turns Plex libraries into always-on "live TV" channels.  
Channels are computed client-side with deterministic schedule offsets, so no backend is required.

MVP demo recording: https://youtu.be/FkOh5230XSM

## Feature Summary

### Authentication and Session
- PIN-based Plex linking via `plex.tv/link` (`PlexLinkService`, `LinkLoginView`).
- Keychain token persistence (`KeychainStorage`) with automatic session bootstrap (`AuthState`).
- Smart server selection from Plex resources:
  - prioritizes HTTPS
  - prefers non-relay connections
  - includes fallback URLs
- Session refresh flow triggered by `.plexSessionShouldRefresh`.

### Channel Modeling and Persistence
- `Channel` model stores:
  - channel metadata
  - source libraries
  - compiled media lineup
  - schedule anchor for 24/7 looping
- Wall-clock schedule computation:
  - `playbackPosition(at:)`
  - `nowPlaying`, `nextUp`, `timeRemaining`
- Persistent storage using JSON files (atomic writes) in `ChannelStore`.
- Channel ordering persisted separately (`channel_order.json`).

### Filtered Channel Builder
- Multi-library channel draft model (`ChannelDraft`) with per-library specs (`LibraryFilterSpec`).
- Nested boolean filter trees (`FilterGroup` + `FilterRule`) with Match All / Match Any semantics.
- Live count updates and preview compilation in `ChannelBuilderViewModel`.
- Sort support via `PlexSortCatalog` and `SortDescriptor`.
- Deterministic randomization with seeded RNG (`SeededRandomNumberGenerator`) for stable shuffle behavior.

### Query Execution and Caching
- Actor-based query engine (`PlexQueryBuilder`) for thread-safe, concurrent media workflows.
- Supports:
  - server-side / local hybrid filtering
  - filter matching for movie and TV metadata
  - two-step TV handling (show-level + episode-level workflows)
- Disk + memory cache for library snapshots (`LibraryMediaCacheStore`) to reduce repeated Plex pagination/fetch cost.

### Playback and Recovery
- `ChannelsCoordinator` centralizes playback presentation state.
- `ChannelPlayerView` supports:
  - direct play attempts first
  - HLS transcoding fallback
  - adaptive bitrate downshift logic
  - forced new transcoder sessions after stalls/failures
  - session start/stop reporting back to Plex
- `PlexService` stream planning includes remux/transcode control and MKV-specific strategy.

### Artwork and Performance
- Candidate-based artwork selection (background/poster/logo) on `Channel.Media`.
- Cached image pipeline (`PlexImageCache`, `CachedAsyncImage`) with memory/cost limits.
- tvOS-focused interaction patterns:
  - focus-aware channel rows
  - play/pause command menus
  - full-screen modal flows

## Project Layout

- `PlexChannelsTV/PlexChannelsTVApp.swift`: app composition and dependency wiring
- `PlexChannelsTV/Application/AuthState.swift`: auth/session lifecycle orchestration
- `PlexChannelsTV/Networking/PlexLinkService.swift`: Plex PIN/link + resources/account calls
- `PlexChannelsTV/Services/PlexService.swift`: Plex API/session/stream/artwork service
- `PlexChannelsTV/Services/PlexQueryBuilder.swift`: actor-based filter/query compiler
- `PlexChannelsTV/Services/ChannelStore.swift`: channel CRUD + persistence
- `PlexChannelsTV/Models/Channel.swift`: channel/schedule/media model
- `PlexChannelsTV/Views/ChannelBuilder/*`: channel wizard UI + state
- `PlexChannelsTV/Views/ChannelPlayerView.swift`: playback runtime

## Dependency

- `PlexKit` (SPM): `https://github.com/lcharlick/PlexKit` (resolved at `1.7.2` in this repo).

## Integrating Into an Existing Swift Plex App

This codebase is easiest to integrate as a "channel engine" layer, then bind it to your existing UI/navigation.

### 1) Add/Align Core Dependencies
1. Add `PlexKit` to your existing app target.
2. Ensure your app supports async/await and SwiftUI state propagation (`ObservableObject` / environment or DI container).

### 2) Bring Over Core Modules
Copy or refactor these modules into your app:
- `Models`: `Channel`, filter models, `ChannelPlaybackRequest`
- `Services`: `PlexService`, `PlexQueryBuilder`, `PlexFilterCatalog`, `PlexSortCatalog`, `ChannelStore`, `LibraryMediaCacheStore`, `ChannelsCoordinator`
- `Networking`: `PlexLinkService`, link models/parser/headers
- `Utilities`: `KeychainStorage`, image cache, loggers, seeded RNG

If you already have equivalents, keep your APIs and adapt these implementations behind protocols.

### 3) Wire Authentication and Session
1. Create a single shared `PlexService`.
2. Create `PlexLinkService` using the same Plex client identity values you use elsewhere.
3. Initialize `AuthState(plexService:linkService:)`.
4. Use your existing login entrypoint to trigger `requestPin` -> `pollPin` -> `completeLink`.

Minimal composition pattern:

```swift
let plexService = PlexService()
let linkService = PlexLinkService(
    clientIdentifier: plexService.clientIdentifier,
    product: "Your App Name",
    version: appVersion,
    device: "Apple TV",
    platform: "tvOS",
    deviceName: "Apple TV"
)
let authState = AuthState(plexService: plexService, linkService: linkService)
let channelStore = ChannelStore()
```

### 4) Integrate Channel Build + Compile
1. Use `ChannelBuilderViewModel` + `ChannelBuilderFlowView` (or your own UI) to collect filters/sort/options.
2. For each selected library, call `PlexQueryBuilder.buildChannelMedia(...)`.
3. Merge and dedupe by media ID, then create `Channel`.
4. Persist via `channelStore.addChannel(_:)`.

### 5) Integrate Playback
1. Use `ChannelsCoordinator` as the single source of truth for playback requests.
2. Present `ChannelPlayerView` from coordinator state.
3. Feed `ChannelPlayerView` with `PlexService` + `ChannelStore` so it can refresh channels and recover streams.

### 6) Keep Scheduling Deterministic
- Preserve `scheduleAnchor` and channel lineup order.
- Compute playback from wall clock using `Channel.playbackPosition(at:)`.
- If you implement random order, keep seeded shuffle to avoid user-visible reorder drift between app launches.

### 7) Keep Caches and Persistence in App-Specific Paths
- `ChannelStore` writes JSON under documents.
- `LibraryMediaCacheStore` writes library snapshots under app support.
- Keep these stores on-device; no server needed for schedule state.

## Integration Tips for Third-Party Plex Clients

- Treat Plex auth and channel engine as independent layers:
  - auth layer yields active server/token context
  - channel layer compiles and persists channel state
  - playback layer resolves direct/transcode stream plans
- Avoid duplicate Plex sessions across modules. Share one `PlexService` per signed-in profile.
- If your app is multi-profile, namespace persisted channel/cache files by profile/server identifier.
- If you are iOS-first, keep the service/model layer and replace tvOS-specific view/focus behaviors.

## Build and Test

- Open `PlexChannelsTV.xcodeproj` in Xcode.
- Build target: `PlexChannelsTV` (tvOS).
- Example test command:

```bash
xcodebuild test \
  -project PlexChannelsTV.xcodeproj \
  -scheme PlexChannelsTV \
  -destination 'platform=tvOS Simulator,name=Apple TV'
```

## License

No license file is currently included in this repository. Add one before redistributing.
