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
- ✅ **Advanced channel builder** - Plex-style filter wizard with multi-library support
- ✅ **Nested filter rules** - Match All/Any groups with arbitrary nesting
- ✅ **Live item counts** - Debounced real-time counts as filters change
- ✅ **Smart sorting** - Title, year, date added, rating, random, and more
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

#### `PlexFilterCatalog` (Channel Builder)
**Purpose**: Provides available filter fields and enum values for a given library  
**Key Methods**:
- `availableFields(for: PlexLibrary)` - Returns filterable fields based on library type
- `options(for: FilterField, library: PlexLibrary)` - Fetches enum values (genres, labels, collections, etc.)

**Pattern**: Fetches from Plex's filters/sorts endpoint when available, otherwise derives from cached metadata.

#### `PlexQueryBuilder` (Channel Builder)
**Purpose**: Translates filter rules into Plex API queries or client-side filtering  
**Architecture**: `actor` for thread-safe concurrent operations
**Key Methods**:
- `buildChannelMedia(library:using:sort:limit:)` - **Entry point**: Executes filter group and returns matching media (routes to movie or TV path)
- `fetchMedia(library:using:sort:limit:)` - **Movie path**: Single-step filtering on movies or episode-only TV filters
- `buildChannelMediaForTVShows(library:using:sort:limit:)` - **TV path**: Two-step filtering (shows → episodes)
- `count(library:using:)` - Returns count of items matching filters (for live count badge)
- `mediaSnapshot(for:limit:mediaType:)` - Cached media fetching with progress callbacks

**Pattern**: Translates `FilterGroup` → server-side query where possible; falls back to client-side filtering when needed. Handles nested groups with Match All/Any logic.

**Critical Features**:
- **Actor-based concurrency** - Thread-safe media caching and concurrent access
- **TV Show Two-Step Filtering** - Separates show-level vs episode-level filters (see detailed section below)
- **Progress callbacks** - Real-time updates during long operations
- **Concurrent fetch prevention** - Prevents duplicate API calls for same library
- **Cache invalidation** - `invalidateCache(for:)` and `invalidateAllCache()`

**Movie vs TV Show Filtering Architecture**:

The filtering system uses **two distinct paths** based on library type and filter content:

**1. Movie Filtering (Single-Step Path)**:
```
buildChannelMedia() → fetchMedia() → filter → sort → limit → return
```
- **Entry**: `buildChannelMedia()` detects `library.type == .movie` → routes to `fetchMedia()`
- **Process**:
  1. Fetch all movies from cache via `mediaSnapshot(for:library, mediaType:.movie)`
  2. Apply filter group directly to movies (`items.filter { matches($0, group: group) }`)
  3. Apply sorting if provided
  4. Apply limit if provided
  5. Convert `PlexMediaItem` → `Channel.Media` and return
- **Key**: All filter rules apply directly to movie metadata (title, year, genre, etc. are all at the same level)

**2. TV Show Filtering (Two-Step Path with Show/Episode Separation)**:
```
buildChannelMedia() → buildChannelMediaForTVShows() → [show filtering → episode expansion → episode filtering] → sort → limit → return
```
- **Entry**: `buildChannelMedia()` detects `library.type == .show` → checks cache, routes to `buildChannelMediaForTVShows()`
- **Why Two-Step**: Plex stores TV metadata hierarchically - show metadata (title, year, network, studio) is separate from episode metadata (episode title, season, episode number). Must filter shows first to determine which shows match, then fetch their episodes.
- **Process**:
  1. **Filter Separation**: Split `FilterGroup` into show-level and episode-level filters
     - `showFilters = extractShowLevelFilters(group)` - Rules targeting: `.title`, `.year`, `.network`, `.studio`, `.contentRating`, `.country`
     - `episodeFilters = extractEpisodeLevelFilters(group)` - All other rules (episode title, season, etc.)
  2. **Show Filtering**: Fetch all shows from cache, filter by show-level criteria
     - `allShows = mediaSnapshot(for:library, mediaType:.show)`
     - `matchingShows = allShows.filter { matches($0, group: showFilters) }`
  3. **Episode Expansion**: Fetch episodes from each matching show
     - For each show in `matchingShows`, call `plexService.fetchShowEpisodes(showRatingKey:)`
     - Episodes are saved incrementally to episode cache after each show
     - Result: `allEpisodes` contains all episodes from matching shows
  4. **Episode Filtering**: Apply episode-level filters to expanded episodes
     - If `episodeFilters` not empty: `episodesFromMatchingShows = allEpisodes.filter { matches($0, group: episodeFilters) }`
  5. **Final Steps**: Apply sorting, limit, convert to `Channel.Media`
- **Cache Strategy**: 
  - Shows cached separately from episodes (`mediaType: .show` vs `.episode`)
  - If episode cache exists, uses cached episodes and skips show filtering (assumes all episodes already loaded)
  - If no episode cache, performs full two-step process and populates cache
- **Key Distinction**: Show-level filters determine which shows to consider; episode-level filters determine which episodes from those shows to include

**Show-Level Field Detection**:
- `isShowLevelField(_ field: FilterField) -> Bool` determines if a field applies to shows or episodes
- **Show-level fields**: `.title` (show title), `.year`, `.network`, `.studio`, `.contentRating`, `.country`
- **Episode-level fields**: All others (episode title, season, episode number, genres, labels, collections, etc.)
- `hasShowLevelFilters(_ group: FilterGroup) -> Bool` recursively checks if any rule in a filter group targets show-level fields

**Filter Extraction Methods**:
- `extractShowLevelFilters(_ group: FilterGroup) -> FilterGroup`: Recursively extracts only show-level rules and nested groups, preserves group mode (Match All/Any)
- `extractEpisodeLevelFilters(_ group: FilterGroup) -> FilterGroup`: Recursively extracts only episode-level rules and nested groups, preserves group mode
- **Critical**: Both methods preserve nested group structure and logic mode, ensuring Match All/Any semantics are maintained when filters are split

**When Each Path Is Used**:
- **Movie Path** (`fetchMedia`): Always used for `.movie` libraries
- **TV Path with Show Filtering** (`buildChannelMediaForTVShows`): Used when `library.type == .show` AND no episode cache exists
- **TV Path with Cached Episodes**: When `library.type == .show` AND episode cache exists, filters cached episodes directly (skips show filtering step, assumes all episodes already loaded from previous two-step run)
- **Episode-Only Filtering**: If TV library has no show-level filters, `fetchMedia` can be used directly with `mediaType: .episode` (but this path is less common)

**Important Implementation Details**:
- Episode cache key: `"\(library.uuid)_episode"` vs Show cache key: `"\(library.uuid)_show"`
- Episodes are fetched per-show via `plexService.fetchShowEpisodes()` using show's `ratingKey`
- Episode cache is saved incrementally after each show to prevent data loss on interruption
- Sorting is applied AFTER filtering (applies to final episode list, not shows)
- Show-level filtering happens BEFORE episode expansion (critical performance optimization - don't fetch episodes from shows that don't match)

#### `PlexSortCatalog` (Channel Builder)
**Purpose**: Provides available sort options for library types  
**Key Methods**:
- `availableSorts(for: PlexLibrary)` - Returns list of valid sort keys for library type

**Supported Sorts**:
- **Movies**: title, year, originallyAvailableAt, rating, audienceRating, contentRating, addedAt, lastViewedAt, random
- **TV Episodes**: title, grandparentTitle (show), originallyAvailableAt, addedAt, lastViewedAt, viewCount, random

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

#### Channel Builder Models (`Models/Filters/`)

**`FilterOperator`**: Enum defining comparison operators
- String ops: `.contains`, `.notContains`, `.is`, `.isNot`, `.beginsWith`, `.endsWith`
- Numeric ops: `.equals`, `.notEquals`, `.lt`, `.lte`, `.gt`, `.gte`
- Date ops: `.before`, `.on`, `.after`
- Boolean ops: `.is` / `.isNot`

**`FilterField`**: Typed enum with metadata for each filterable field
- `valueKind`: `.text`, `.number`, `.date`, `.enumMulti`, `.enumSingle`, `.boolean`
- `appliesTo`: `.movie`, `.show`, `.episode` (determines which library types support this field)

**`FilterRule`**: Single comparison `{ field, op, value }`

**`FilterGroup`**: Nested logic container
- `mode`: `.all` (AND) or `.any` (OR)
- `rules`: Array of `FilterRule`
- `groups`: Array of nested `FilterGroup` (supports arbitrary nesting)

**`LibraryFilterSpec`**: Associates library with its filter group
- `libraryID`: UUID of library
- `rootGroup`: Top-level `FilterGroup` for this library

**`ChannelDraft`**: Intermediate state during channel building
- `name`: User-provided or auto-generated
- `selectedLibraries`: Array of `LibraryRef` (id, key, title, type)
- `perLibrarySpecs`: Array of `LibraryFilterSpec` (one per selected library)
- `sort`: `SortDescriptor` (key + order)
- `options`: `{ shuffle: Bool }`

**`SortDescriptor`**: `{ key: SortKey, order: .asc | .desc }`

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

#### Channel Builder Views (`Views/ChannelBuilder/`)

**`ChannelBuilderFlowView`** (Main Wizard)
- **Presentation**: Full-screen cover with `.regularMaterial` background
- **Steps**: Libraries → Rules (per library) → Sort & Review (combined)
- **Navigation**: "Back" / "Next" / "Create Channel" buttons in footer
- **Preview Row**: Shows first 20 filtered items on Steps 2 & 3 (non-focusable, updates as filters change)
- **Focus Sections**: Separate focus sections for content, preview, and footer for better navigation
- **Scrolling**: Main ScrollView wraps all content, preview, and footer - entire page scrolls as one unit
- **Important**: Must use opaque background to hide channels view behind it

**`LibraryMultiPickerView`** (Step 1)
- Grid of library cards with checkmarks for selection
- Only libraries with same media type can be combined
- Cards show icon, title, and type with focus effects

**`RuleGroupBuilderView`** (Step 2)
- One instance per selected library
- **No internal ScrollView**: Content expands to full height, parent handles scrolling
- **Consistent spacing**: 24px between "Step 2" title and rule builder, 24px between rule builder and Channel Preview
- **Control Row** (24px spacing between buttons): 
  - "Match All/Any" toggle button (340px wide, focus-managed with 1.015 scale)
  - "Add Filter" button (220px wide, + icon, focus-managed)
  - "Add Group" button (220px wide, ... icon, focus-managed)
  - All buttons use `.plain` style with custom backgrounds, `.clipShape()` before `.scaleEffect()`, and 8px shadow
  - Buttons have padding: horizontal 20px, vertical 12px
- **Rule Rows** (20px spacing in HStack): Each row in a container with padding/background
  - Field dropdown (240px) - Menu with all available fields, focus-managed, single background layer
  - Operator dropdown (240px) - Menu wider to fit "Does Not Contain" etc., focus-managed, single background layer
  - Value editor (180-300px depending on type), focus-managed for enum menus
  - Trash button (70px × 50px, red tint, focus-managed with 1.015 scale, padding: 16px horizontal, 12px vertical)
  - All menus use `.clipShape()`, `.scaleEffect(1.015)`, and 6px shadow on focus
  - Menus have background applied at button level (not label level) to avoid double rectangles
- Value editor adapts to field type:
  - Text: TextField (300px)
  - Number: TextField (180px)
  - Date: DateValuePicker with quick picks (last 7/30/90 days, 300px)
  - Enum (multi/single): Dropdown menu with checkmarks (300px), focus-managed
  - Boolean: Toggle (180px)
- **Nested Groups**: Indented by 40px per level, with background on level > 0
- Live count debounced (250-400ms) to avoid excessive API calls
- **Button Best Practices Applied**: All buttons follow Critical Pattern #7 to prevent clipping

**`SortPickerView`** (Step 3 - Sort & Review Combined)
- **Sorting Section**:
  - List of available sorts for the primary library type
  - ASC/DESC toggle where applicable
  - Shuffle toggle
  - Defaults: Movies → Title (ASC), TV → Episode Air Date (DESC)
- **Review Section**:
  - Editable channel name field
  - Total items count (auto-calculated from filters)
  - Per-library breakdown with item counts
- **Layout**: Divider separates sorting from review sections
- **Button**: "Create Channel" (replaces old Step 4)

**`ChannelPreviewRow`** (Preview Component)
- **Purpose**: Shows live preview of filtered channel content
- **Display**: Horizontal scrolling row of 2:3 poster cards (180×270px) with title below
- **Header**: "Channel Preview" on left, item count badge on right (with `Spacer()` between)
- **Behavior**: 
  - Non-focusable (`.focusable(false)`) - navigation skips over it
  - Fetches first 20 items matching current filters via `viewModel.fetchPreviewMedia()`
  - Updates automatically when filters change (debounced)
  - Shows placeholder posters (8) with photo icon when no items match filters
- **Appears**: Steps 2 (Rules) and 3 (Sort & Review) above footer buttons
- **Implementation**: Matches "Up Next" row structure from main channels view
  - Poster (180×270px) on top
  - Title caption text below poster (left-aligned)
  - 24px spacing between posters
  - 8px spacing between poster and title
  - Placeholder posters: RoundedRectangle with photo icon overlay

**Channel Compilation Process**:
1. For each library, execute filter group via `PlexQueryBuilder.buildChannelMedia()`
2. Union all media IDs, dedupe by `media.id`
3. Apply sort (or shuffle if random/shuffle enabled)
4. Create `Channel` with `provenance: .filters(draft)` and persist
5. Return focus to new channel card on main screen

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

### 6. Full-Screen Modal Backgrounds

**The Problem**: When presenting full-screen covers (like Channel Builder), transparent backgrounds cause underlying views to show through, creating visual confusion and text intermingling.

**❌ WRONG** (causes text overlap):
```swift
var body: some View {
    VStack {
        content
    }
    .background(Color.black.opacity(0.001))  // ← Nearly transparent!
}
```

**✅ RIGHT**:
```swift
var body: some View {
    VStack {
        content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black)  // ← Opaque background
}
```

**Why**: 
- `.fullScreenCover` doesn't automatically provide an opaque backdrop on tvOS
- Must explicitly set opaque background to hide the view beneath
- `.frame(maxWidth: .infinity, maxHeight: .infinity)` ensures background fills entire screen
- Applies to: `ChannelBuilderFlowView`, any custom modal presentations

### 7. Actor-Based Concurrency

**Pattern**: Use `actor` for thread-safe concurrent operations that manage shared state.

**✅ DO THIS**:
```swift
actor PlexQueryBuilder {
    private var mediaCache: [String: [PlexMediaItem]] = [:]
    private var activeFetches: Set<String> = []
    
    func mediaSnapshot(for library: PlexLibrary) async throws -> [PlexMediaItem] {
        // Actor ensures thread-safe access to cache and activeFetches
        if let cached = mediaCache[cacheKey] {
            return cached
        }
        // ... fetch and cache
    }
}
```

**Why**: 
- Prevents race conditions in concurrent media fetching
- Ensures cache consistency across multiple async operations
- Provides structured concurrency for complex state management
- Critical for `PlexQueryBuilder` which manages shared caches and progress callbacks

### 8. TV Show Two-Step Filtering

**The Problem**: TV shows require filtering at both show-level (title, year, genre) and episode-level (episode title, season) metadata. Unlike movies where all metadata is at a single level, TV shows have a hierarchical structure where show metadata is separate from episode metadata.

**Architecture**: See detailed documentation in `PlexQueryBuilder` section above. This pattern summarizes the key concepts.

**Pattern**:
```swift
// Step 1: Determine if filters target show-level fields
func hasShowLevelFilters(_ group: FilterGroup) -> Bool {
    // Recursively check if any rules target show.title, show.year, etc.
    for rule in group.rules {
        if isShowLevelField(rule.field) { return true }
    }
    for nestedGroup in group.groups {
        if hasShowLevelFilters(nestedGroup) { return true }
    }
    return false
}

// Step 2: Separate filters by level
let showFilters = extractShowLevelFilters(group)      // .title, .year, .network, .studio, etc.
let episodeFilters = extractEpisodeLevelFilters(group) // Episode title, season, episode number, etc.

// Step 3: Two-step filtering process
// A. Filter shows first (prevents unnecessary episode fetching)
let allShows = try await mediaSnapshot(for: library, mediaType: .show)
let matchingShows = showFilters.isEmpty ? allShows : allShows.filter { matches($0, group: showFilters) }

// B. Expand to episodes from matching shows only
var allEpisodes: [PlexMediaItem] = []
for show in matchingShows {
    let showEpisodes = try await plexService.fetchShowEpisodes(showRatingKey: show.ratingKey)
    allEpisodes.append(contentsOf: showEpisodes)
    // Incremental cache save after each show
    await cacheStore.store(items: allEpisodes, for: episodeCacheKey)
}

// C. Apply episode-level filters to expanded episodes
let finalEpisodes = episodeFilters.isEmpty 
    ? allEpisodes 
    : allEpisodes.filter { matches($0, group: episodeFilters) }
```

**Key Methods** (in `PlexQueryBuilder`):
- `buildChannelMediaForTVShows()` - Main two-step filtering orchestrator
- `isShowLevelField(_ field: FilterField) -> Bool` - Determines if field targets shows or episodes
- `extractShowLevelFilters(_ group: FilterGroup) -> FilterGroup` - Recursively extracts show-level rules while preserving nested structure
- `extractEpisodeLevelFilters(_ group: FilterGroup) -> FilterGroup` - Recursively extracts episode-level rules while preserving nested structure

**Why**: 
- Plex stores TV metadata hierarchically - show metadata is separate from episode metadata
- Must filter shows first to determine which shows match criteria (performance: don't fetch episodes from shows that don't match)
- Then expand to episodes from matching shows
- Finally apply episode-level filters to the expanded episode list
- **Critical**: This two-step process MUST be maintained separately from movie filtering (which is single-step) because the data structure is fundamentally different

**Show-Level vs Episode-Level Fields**:
- **Show-level**: `.title` (show title), `.year`, `.network`, `.studio`, `.contentRating`, `.country`
- **Episode-level**: All others including episode title, season, episode number, genres (when filtered on episodes), labels, collections, etc.

**Cache Strategy**:
- Shows and episodes cached separately (`mediaType: .show` vs `.episode`)
- If episode cache exists, can skip show filtering and filter cached episodes directly
- If no episode cache, must perform full two-step process to populate cache
- Episode cache is saved incrementally (after each show) to prevent data loss on interruption

**Movie vs TV Show Difference**:
- **Movies**: Single-step - fetch movies, filter, sort, limit (all metadata at same level)
- **TV Shows**: Two-step - filter shows → expand to episodes → filter episodes → sort → limit (hierarchical metadata)
- **Critical**: These two paths MUST remain separate - do not try to unify them into a single method

### 9. Deterministic Randomization

**Pattern**: Use seeded random number generation for consistent "random" ordering.

```swift
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed == 0 ? 0xC0FFEE : seed
    }
    
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }
}

// Usage in channel creation
let channelID = UUID()
var generator = SeededRandomNumberGenerator(seed: deterministicSeed(for: channelID))
finalMedia.shuffle(using: &generator)
```

**Why**: Ensures same "random" order across app launches. Users expect consistent channel ordering.

### 10. Text Input Sanitization

**Pattern**: Sanitize text input to prevent filtering failures from invisible Unicode characters.

```swift
let sanitized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: "\u{FFFC}", with: "") // Object replacement character
    .replacingOccurrences(of: "\u{200B}", with: "") // Zero-width space
    .replacingOccurrences(of: "\u{200C}", with: "") // Zero-width non-joiner
    .replacingOccurrences(of: "\u{200D}", with: "") // Zero-width joiner
    .replacingOccurrences(of: "\u{FEFF}", with: "") // Zero-width no-break space
```

**Why**: Invisible Unicode characters can break Plex API filtering. Users can paste text with these characters from other apps.

### 11. Advanced Playback Recovery

**Pattern**: Sophisticated adaptive bitrate system with multiple recovery strategies.

```swift
struct AdaptiveState {
    var bitrateCap: Int = 8_000
    var downshiftCount: Int = 0
    var forceTranscode: Bool = false
    var lowThroughputStart: Date?
    var lastRecovery: Date?
}

enum RecoveryCause {
    case stall
    case throughput(observed: Int, indicated: Int)
}

func attemptRecovery(for plan: StreamPlan, entry: PlaybackEntry, cause: RecoveryCause) {
    // Complex logic for different recovery scenarios
    // - First stall: 40% bitrate reduction
    // - Subsequent stalls: 30% reduction
    // - Force transcode after 2 downshifts
    // - Force new session to prevent stale transcoder
}
```

**Why**: Network conditions vary. Must adapt bitrate proactively and recover from stalls intelligently.

### 12. Focus Section Management

**Pattern**: Use `.focusSectionIfAvailable()` for better tvOS navigation.

```swift
extension View {
    @ViewBuilder
    func focusSectionIfAvailable() -> some View {
        if #available(tvOS 14.0, *) {
            self.focusSection()
        } else {
            self
        }
    }
}

// Usage
VStack {
    content
        .focusSectionIfAvailable()
    footer
        .focusSectionIfAvailable()
}
```

**Why**: Improves navigation between different UI areas. Prevents focus conflicts in complex layouts.

### 13. Secure Logging Patterns

**Pattern**: Redact sensitive information from logs while maintaining debugging value.

```swift
extension URL {
    func redactedForLogging() -> String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return absoluteString
        }
        
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                if item.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame {
                    return URLQueryItem(name: item.name, value: "‹redacted›")
                }
                if let value = item.value, value.count > 128 {
                    return URLQueryItem(name: item.name, value: String(value.prefix(125)) + "...")
                }
                return item
            }
        }
        return components.string ?? absoluteString
    }
}
```

**Why**: Plex tokens are sensitive. Must redact them from logs while keeping URLs useful for debugging.

### 14. Memory Management Patterns

**Pattern**: Proper cleanup and weak references to prevent retain cycles.

```swift
// ✅ DO THIS - Weak reference in async closure
Task { [weak self] in
    guard let self else { return }
    await self.performOperation()
}

// ✅ DO THIS - Proper cleanup
func cleanup() {
    playbackTask?.cancel()
    playbackTask = nil
    clearPlayerObservers()
    stopTicker()
}

// ✅ DO THIS - StateObject vs ObservedObject
@StateObject private var coordinator = ChannelsCoordinator()  // Owns the object
@EnvironmentObject private var plexService: PlexService      // Injected dependency
```

**Why**: Prevents memory leaks and ensures proper resource cleanup in complex async operations.

### 15. Button Scaling & Clipping Prevention

**The Problem**: tvOS buttons scale on focus (typically 1.5-2%), and shadows extend beyond button bounds. Both the **internal layout**, **grid spacing**, and **container padding** must accommodate the scale effect AND shadow radius to prevent clipping.

**❌ WRONG** (causes shadow clipping):
```swift
LazyVGrid(columns: columns, spacing: 24) {  // ← Too tight for shadow!
    Button { action } label: {
        VStack {
            HStack {
                Image(systemName: "icon")  // ← No fixed size
                Text("Text")  // ← No constraints
            }
            .padding(16)  // ← Content touching edges
        }
        .frame(height: 140)
    }
}
.padding(.horizontal, 16)  // ← Not enough! Shadow clips at edges!
.scaleEffect(isFocused ? 1.05 : 1.0)  // ← Too much scale
.shadow(radius: 12)  // ← Shadow gets clipped!
```

**✅ RIGHT**:
```swift
LazyVGrid(columns: columns, spacing: 48) {  // ← Space for scale + shadow!
    Button { action } label: {
        HStack(alignment: .center, spacing: 20) {  // ← Horizontal layout
            Image(systemName: "icon")
                .frame(width: 40, height: 40)  // ← Fixed size
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(1)  // ← Constrained
                    .minimumScaleFactor(0.85)
                Text(item.subtitle)
                    .font(.subheadline)
            }
            .frame(maxHeight: 40)  // ← Match icon height
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 24)  // ← Internal padding
        .padding(.vertical, 20)
        .frame(height: 120)
        .background(background)
    }
}
.padding(.horizontal, 32)  // ← Container padding (2.5× shadow)
.clipShape(RoundedRectangle(cornerRadius: 18))
.scaleEffect(isFocused ? 1.015 : 1.0)  // ← Conservative 1.5% scale
.shadow(radius: 12)  // ← Shadow won't clip!
```

**Key Rules**:
1. **Shadow Spacing Formula**: `grid_spacing ≥ scale_buffer + (2 × shadow_radius) + visual_gap`
   - Scale buffer: ~10px for 1.5% on 300px cards
   - Shadow: 2 × 12px = 24px
   - Visual gap: 10-15px
   - **Total: 44-50px** (use 48px)

2. **Container Padding Formula**: `padding ≥ 2.5 × shadow_radius` (round up for safety)
   - For 12px shadow: **32px padding** (allows for shadow blur + tolerance)
   - Critical: Shadow blur extends beyond nominal radius
   - Prevents edge shadow clipping

3. **Scale factor: 1.015-1.02 max**: More than 2% risks overlap even with good spacing

4. **Internal padding**: Separate from container padding
   - Horizontal: **24px minimum** (prevents content from touching edges)
   - Vertical: **20px** (adequate breathing room)
   - Spacing between elements: **20px** (icon to text stack)

5. **Content height constraints**: Text must not exceed icon height
   - Icon: 40px fixed
   - Text stack: `maxHeight: 40px` (constrained to icon)
   - Use `.lineLimit(1)` on title to prevent overflow

6. **Horizontal layouts preferred**: Icon left, text middle, action right (not vertical)

7. **Clip before scaling**: Apply `.clipShape()` before `.scaleEffect()` 

8. **Shadow after everything**: Shadow applied last to avoid cutoff edges

9. **Fixed element sizes**: All icons/images need explicit frames

10. **Text constraints**: Use `.lineLimit()` + `.minimumScaleFactor()` on all text

11. **Button Focus Scaling - Counteracting tvOS Automatic Content Scaling**: When using `.focused()` with `.buttonStyle(.plain)`, tvOS automatically applies focus scaling (~1.015) to the content inside the button label. You MUST apply `.scaleEffect()` to scale the button container (background, overlay, border), BUT you must also apply an inverse `.scaleEffect()` to the content inside the label to prevent double-scaling.
    
    **The Problem**: tvOS automatically scales focused button content ~1.015. If you apply `.scaleEffect(1.015)` to the entire button, the content scales twice (~1.03 total) while the container scales once (~1.015), causing content to appear larger than the container.
    
    **❌ WRONG** (double-scaling content):
    ```swift
    Button { } label: {
        HStack {
            Text("Content")  // Gets scaled by tvOS (~1.015) AND scaleEffect (~1.015) = ~1.03
        }
        .padding()
        .background(Color.blue)  // Only gets scaled by scaleEffect (~1.015)
    }
    .buttonStyle(.plain)
    .focused($focus, equals: .button)
    .scaleEffect(isFocused ? 1.015 : 1.0)  // Scales container, but content scales twice!
    ```
    
    **✅ RIGHT** (uniform scaling with inverse content scale):
    ```swift
    Button { } label: {
        HStack {
            Text("Content")
                .foregroundStyle(isFocused ? .black : .white)  // Dark text when focused
        }
        .padding()
        // Inverse scaleEffect INSIDE label to counteract tvOS automatic content scaling
        .scaleEffect(isFocused ? 0.985 : 1.0)  // Counteracts tvOS ~1.015 scaling
        .animation(.easeInOut(duration: 0.075), value: isFocused)  // Twice as fast to match tvOS speed
        .background(Color.blue)  // Background scales with button scaleEffect
        .overlay(Rectangle().stroke())  // Overlay scales with button scaleEffect
    }
    .clipShape(RoundedRectangle(...))  // Clip BEFORE buttonStyle
    .buttonStyle(.plain)
    .focused($focus, equals: .button)
    .scaleEffect(isFocused ? 1.015 : 1.0)  // Scales button container
    .animation(.easeInOut(duration: 0.15), value: isFocused)  // Standard speed for container
    ```
    
    **Why**: 
    - tvOS applies automatic scaling (~1.015) to focused button content inside the label
    - We apply `.scaleEffect(1.015)` to scale the button container (background, overlay, border)
    - Content inside gets inverse `.scaleEffect(0.985)` to counteract tvOS scaling
    - Result: Container scales ~1.015, content scales ~1.015 (tvOS) × 0.985 (inverse) × 1.015 (button) ≈ ~1.015 uniformly
    - Background and overlay must be INSIDE the button label so they scale with the button's `.scaleEffect()`
    
    **Critical - Animation Synchronization**: 
    - Apply `.animation()` to BOTH the content's inverse scale (inside label) AND the button's scale (outside)
    - **Content animation must be TWICE AS FAST** as button animation to match tvOS's internal scaling speed
    - Content animation: `.easeInOut(duration: 0.075)` (half of button duration)
    - Button animation: `.easeInOut(duration: 0.15)` 
    - tvOS scales button content at approximately half the speed of the container during transitions
    - Without proper speed matching, content and container will scale at different rates during transitions, causing visual "hitches"
    
    **Key Principle**: 
    - Apply inverse `.scaleEffect()` to content INSIDE the button label to counteract tvOS automatic scaling
    - Apply `.animation()` to the inverse scale INSIDE the label with **HALF the duration** (0.075 vs 0.15) - tvOS scales content at ~half speed
    - Change text color to dark (`.foregroundStyle(isFocused ? .black : .white)`) when focused for proper contrast
    - Apply `.scaleEffect()` to the button AFTER `.buttonStyle()` to scale the container
    - Apply `.animation()` to the button scale with standard duration (0.15)
    - Background and overlay must be INSIDE the label so they scale with the button container
    - Content animation must be twice as fast as container animation to match tvOS's internal scaling behavior

**Example (Grid Cards - COMPLETE)**:
```swift
ScrollView {
    LazyVGrid(columns: [.flexible(), .flexible(), .flexible()], spacing: 48) {
        ForEach(items) { item in
            Button(action: { }) {
                HStack(alignment: .center, spacing: 20) {
                    // Icon on left
                    Image(systemName: "icon")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                    
                    // Text stack in middle - constrained to icon height
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(1)  // Single line to fit in 40px
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text(item.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 40)  // Constrain to icon height
                    
                    // Action on right
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 24)  // Internal padding
                .padding(.vertical, 20)
                .frame(height: 120)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(background)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.015 : 1.0)
            .shadow(color: isFocused ? .accentColor : .clear, radius: 12, x: 0, y: 4)
        }
    }
    .padding(.vertical, 24)
    .padding(.horizontal, 32)  // Container padding (2.5× shadow radius)
}
```

**Example (Rule Row with Trash Button)**:
```swift
HStack(spacing: 16) {
    Menu { /* field options */ } label: {
        HStack {
            Text(field.displayName).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down")
        }
        .frame(width: 220)  // Fixed width prevents clipping
        .padding()
        .background(Color.white.opacity(0.12))
    }
    .buttonStyle(.plain)
    
    Button(role: .destructive, action: onRemove) {
        Image(systemName: "trash")
            .frame(width: 50, height: 44)
    }
    .buttonStyle(.bordered)
}
.padding()  // Container padding prevents row overlap
.background(Color.white.opacity(0.04))
```

**Critical Distinction: Internal vs Container Padding**:
```
Internal Padding (.padding() inside button):
- Purpose: Keeps content away from button edges
- Horizontal: 24px minimum (icon/text won't touch sides)
- Vertical: 20px (adequate breathing room)
- Applied INSIDE the button label

Container Padding (.padding() on grid):
- Purpose: Prevents shadow clipping at screen edges
- Horizontal: 32px (2.5× shadow radius)
- Vertical: 24px
- Applied OUTSIDE the grid, on ScrollView content
```

**Math Examples**:

**1. Content Height Calculation**:
```
Card with frame(height: 120) and padding(20):
- Available content height: 120 - (20 top + 20 bottom) = 80px

Content in HStack (horizontal):
- Icon: 40px
- Text stack: ~40px (headline 20px + spacing 6px + subheadline 14px)
- TOTAL: 40px (icon determines height, text fits within)
- Result: 40px ≤ 80px available ✓

Vertical layout would need more height:
- Icon row: 40px + spacing: 10px + Title: 44px + spacing: 6px + Subtitle: 20px
- TOTAL: 120px > 80px available ✗ (CLIPS!)
```

**2. Shadow Spacing Calculation**:
```
For 12px shadow radius + 1.5% scale on ~300px cards:

Scale buffer:
- 300px × 0.015 = 4.5px growth per side = ~10px total buffer

Shadow space needed:
- 12px radius extends on all sides = 2 × 12px = 24px between cards

Visual separation:
- Minimum 10-15px for comfortable spacing

Total grid spacing needed:
- 10px (scale) + 24px (shadow) + 15px (visual) = 49px
- Use 48px (clean number)

Container padding needed:
- Shadow blur extends beyond nominal radius
- 12px shadow → **32px padding** (2.5× shadow, rounded up)
- Critical: This prevents edge clipping even with shadow blur
```

**Common Symptoms**:
- Buttons "cut off" when focused
- Content overflows button bounds
- Shadows have straight edges instead of rounded corners
- Text disappears or truncates on focus
- Buttons overlap neighboring elements
- "Invalid absolute dimension" warnings in console

**Applies to**: All custom buttons, cards, menus, and interactive elements in the Channel Builder and throughout the app.

### 16. Complex State Management

**Pattern**: Multi-layered state management with validation and error handling.

```swift
@StateObject private var viewModel: ChannelBuilderViewModel

// State transitions with validation
enum Step {
    case libraries
    case rules(Int)
}

// Error state management
@State private var errorMessage: String?
private var errorBinding: Binding<BuilderAlert?> {
    Binding(
        get: { viewModel.errorMessage.map { BuilderAlert(id: UUID(), message: $0) } },
        set: { newValue in
            if newValue == nil {
                viewModel.errorMessage = nil
            }
        }
    )
}

// Live preview updates with debouncing
.onChange(of: viewModel.previewUpdateTrigger) { _, _ in
    handlePreviewUpdate()
}
```

**Key Patterns**:
- **Step-based navigation** - Clear progression through complex workflows
- **Validation at each step** - Prevent invalid state transitions
- **Error state binding** - Convert internal errors to user-friendly alerts
- **Debounced updates** - Prevent excessive API calls during rapid changes
- **Preview state management** - Live updates without blocking UI

**Why**: Complex wizards need structured state management to prevent invalid states and provide smooth user experience.

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

### Actor Concurrency Issues

**Symptoms**: Crashes or data corruption during concurrent operations, logs show "Data race detected"

**Diagnosis**:
```bash
# Check for actor isolation violations
Thread Sanitizer will show data race warnings
# Look for direct access to actor properties without await
```

**Root Causes**:
1. **Direct property access** - Accessing actor properties without `await`
2. **Synchronous calls to actor methods** - Not using `await` for actor methods
3. **Shared mutable state** - Non-actor classes with mutable state accessed concurrently

**Fix**: 
- Always use `await` when calling actor methods
- Use `@MainActor` for UI updates
- Move shared state into actors

### TV Show Filtering Returns No Results

**Symptoms**: TV show filters return empty results even when shows exist

**Diagnosis**:
```bash
# Check logs for TV filtering steps
event=tvFilter.start showFilterEmpty=false episodeFilterEmpty=false
event=tvFilter.fetchedShows count=0  # ← Should be > 0
event=tvFilter.matchedShows count=0  # ← Should be > 0
```

**Root Causes**:
1. **Wrong filter separation** - Show-level filters applied to episodes
2. **Missing show metadata** - Shows don't have expected fields (title, year, etc.)
3. **Episode fetching failure** - `fetchShowEpisodes()` fails silently

**Fix**: 
- Verify `hasShowLevelFilters()` correctly identifies show vs episode fields
- Check show metadata has required fields
- Add error handling to `fetchShowEpisodes()`

### Random Channel Order Changes

**Symptoms**: Channel items appear in different order after app restart

**Diagnosis**: Check if using `SeededRandomNumberGenerator` with consistent seed

**Root Causes**:
1. **Using system random** - `Array.shuffled()` instead of seeded generator
2. **Inconsistent seed** - Different seed values across app launches
3. **Non-deterministic sorting** - Unstable sort algorithm

**Fix**: 
- Use `SeededRandomNumberGenerator` with channel ID as seed
- Ensure same seed across app launches
- Use stable sort algorithms

### Text Input Breaks Filtering

**Symptoms**: Filter rules don't work with certain text inputs, especially pasted text

**Diagnosis**: Check for invisible Unicode characters in filter values

**Root Causes**:
1. **Invisible Unicode characters** - Zero-width spaces, object replacement characters
2. **Non-printable characters** - Control characters that break API calls
3. **Encoding issues** - UTF-8 vs other encodings

**Fix**: Apply text sanitization pattern (see Critical Pattern #10)

### Playback Recovery Loops

**Symptoms**: Playback continuously recovers and stalls, logs show repeated recovery attempts

**Diagnosis**:
```bash
event=play.recover itemID=XXX cause=stall downshiftKbps=3000
event=play.recover itemID=XXX cause=stall downshiftKbps=1800
event=play.recover.exhausted itemID=XXX cause=stall
```

**Root Causes**:
1. **Network too slow** - Even minimum bitrate too high
2. **Recovery cooldown too short** - Rapid recovery attempts
3. **Stale transcoder session** - Plex serving old bitrate segments

**Fix**: 
- Increase recovery cooldown period
- Use `forceNewSession=true` on recovery
- Check network conditions

### Focus Navigation Issues

**Symptoms**: Focus gets stuck or jumps unexpectedly between UI areas

**Diagnosis**: Check focus section usage and focus state management

**Root Causes**:
1. **Missing focus sections** - No `.focusSection()` between UI areas
2. **Focus state conflicts** - Multiple `@FocusState` competing
3. **Focus restoration timing** - Restoring focus before view is ready

**Fix**: 
- Use `.focusSectionIfAvailable()` between major UI areas
- Centralize focus state at parent level
- Delay focus restoration with `DispatchQueue.main.async`

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

**Channel Builder**:
```
event=builder.view.show step=libraries
event=builder.rules.change libraryID=XXX field=genre op=contains
event=builder.count.start libraryID=XXX
event=builder.count.ok libraryID=XXX elapsedMs=234 remote=true total=42
event=builder.compile.start libraryCount=2 sort=title
event=builder.compile.ok perLibCounts=lib1:50,lib2:30 total=80 elapsedMs=1523
event=builder.persist.ok channelID=XXX itemCount=80
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
- [ ] Edit existing channels (re-open in builder with current filters)
- [ ] Custom channel artwork/branding
- [ ] Multiple server support (currently one server per session)
- [ ] TV show episode progression (watch next episode, not random)
- [ ] Time-based programming (holiday movies in December)
- [ ] Save/load filter presets
- [ ] Channel templates (e.g., "90s Action", "Family Friendly Comedy")

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

**v1.0** (Tasks 1-30):
- ✅ PIN-based auth with server discovery
- ✅ Channel creation from Plex libraries
- ✅ 24/7 scheduling with Now/Next
- ✅ Full artwork support (posters, backgrounds, logos)
- ✅ Direct play + HLS transcode with adaptive bitrate
- ✅ Smart buffer recovery (preserves playback position)
- ✅ Optimized buffering strategy (12s buffer, 8Mbps start, proactive downshift)
- ✅ tvOS-native focus and interactions
- ✅ Structured logging for diagnostics

**v1.1** (Task 31 - Channel Builder):
- ✅ **Plex-style Advanced Filters** - Full wizard with multi-step flow
- ✅ **Multi-library support** - Select multiple libraries with same media type
- ✅ **Nested filter rules** - Match All/Any groups with arbitrary nesting depth
- ✅ **Rich filter operators** - String, numeric, date, enum, boolean comparisons
- ✅ **Live item counts** - Debounced real-time count updates as rules change
- ✅ **Smart sorting** - Title, year, date added, rating, random, custom per type
- ✅ **Channel compilation** - Query builder with server-side + client-side filtering
- ✅ **Full-screen modal** - Fixed opaque background to prevent text intermingling
- ✅ **New services**: `PlexFilterCatalog`, `PlexQueryBuilder`, `PlexSortCatalog`
- ✅ **New models**: `FilterGroup`, `FilterRule`, `FilterOperator`, `FilterField`, `ChannelDraft`
- ✅ **New views**: `ChannelBuilderFlowView`, `LibraryMultiPickerView`, `RuleGroupBuilderView`, `SortPickerView`

**v1.1.1** (Task 31.1 - UI Refinements):
- ✅ **Button scaling fixes** - Systemic fix for button clipping/overflow issues across entire app
- ✅ **Library cards redesign** - Fixed icons, proper text scaling, consistent sizing
- ✅ **Rule builder improvements** - Wider fields (220px+), consistent button sizes, better spacing
- ✅ **Trash button integration** - Moved inside rule rows with consistent `.bordered` styling
- ✅ **Combined Sort & Review** - Step 3 now includes both sorting and review for streamlined UX
- ✅ **Channel preview row** - Live poster preview (20 items) on Steps 2 & 3 showing filtered results
- ✅ **Focus navigation** - Added `.focusSection()` for better vertical/horizontal navigation
- ✅ **Reduced logging noise** - Silenced successful artwork/image load logs (errors still logged)
- ✅ **New component**: `ChannelPreviewRow` - Non-focusable horizontal poster scrolling
- ✅ **Critical Pattern #7** - Documented button scaling/clipping prevention in AGENTS.md

**v1.1.2** (Code Review & Documentation):
- ✅ **Actor-based concurrency** - Documented `PlexQueryBuilder` actor pattern for thread safety
- ✅ **TV Show Two-Step Filtering** - Documented complex show → episode filtering architecture
- ✅ **Deterministic randomization** - Documented seeded random number generation for consistent ordering
- ✅ **Text input sanitization** - Documented Unicode character handling to prevent filter failures
- ✅ **Advanced playback recovery** - Documented adaptive bitrate and recovery system patterns
- ✅ **Focus section management** - Documented `.focusSectionIfAvailable()` usage patterns
- ✅ **Secure logging patterns** - Documented URL redaction and privacy considerations
- ✅ **Memory management guidelines** - Documented proper cleanup and weak reference patterns
- ✅ **Complex state management** - Documented multi-layered state management with validation
- ✅ **Enhanced troubleshooting** - Added 6 new troubleshooting sections for advanced patterns
- ✅ **Critical Patterns 7-16** - Comprehensive documentation of all architectural patterns

---

**Last Updated**: v1.1.2 (2025-01-12)  
**Status**: Comprehensive code review complete - All critical patterns and architectural decisions documented
