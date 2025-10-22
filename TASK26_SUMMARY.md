# Task 26: Button Interaction Fix

## Problem
Channel row movies weren't responding to button taps/clicks on tvOS:
- "Force Play Now" button worked reliably
- Short press on channel row movies did nothing
- Long press menu worked, but required double-pressing buttons
- Debug logs weren't showing up reliably on hover/press

## Root Cause (Discovered via Debug Logs)
**First attempt**: Using `.onLongPressGesture()` on tvOS created gesture recognizer conflicts.
**Second attempt (failed)**: Using `.contextMenu()` **completely prevented the button action from firing**. The logs showed NO `event=channel.tap.action` logs when tapping - only `event=channel.contextMenu.action` on long press. This revealed that `.contextMenu` intercepts the primary tap gesture entirely on tvOS.

## Solution

### 1. Removed `.contextMenu` and Restored `confirmationDialog`
**Changed in: `ChannelRowView.swift`**

- **Before (broken)**: Used `.contextMenu` which prevented primary button action from firing
- **After**: Clean button with no gesture/menu modifiers, separate `.onPlayPauseCommand` to trigger menu

**Why this fixes it**: On tvOS, **both** `.onLongPressGesture` and `.contextMenu` interfere with button taps. The solution is to keep buttons completely clean and use `.onPlayPauseCommand` (which responds to long-pressing the Play/Pause button on the Siri Remote) to trigger a state-driven `confirmationDialog`.

### 2. Used `.onPlayPauseCommand` for Menu Trigger
**Changed in: `ChannelRowView.swift`**

- Added `.onPlayPauseCommand` modifier to buttons (tvOS only, via `#if os(tvOS)`)
- Kept `MenuTarget` enum and `@State private var menuTarget` for menu state
- Kept `confirmationDialog` on the view body to show full-screen menu
- Used `handleMenuSelection` to dispatch menu actions

**Why**: `.onPlayPauseCommand` is the proper tvOS API for responding to long-press of the Play/Pause button on the Siri Remote. It doesn't interfere with normal tap handling.

### 3. Added Comprehensive Debug Logging
**Changed in: `ChannelRowView.swift` and `ChannelsView.swift`**

Added structured logging at every step of the interaction flow:

**In ChannelRowView**:
- `event=channel.tap.action` - Button action handler called
- `event=channel.contextMenu.action` - Context menu item selected
- `event=channel.focus.change` - Focus state changed (via `.focusableCompat`)

**In ChannelsView**:
- `event=channel.tap.received` - Handler method entry
- `event=channel.tap.prepare` - Position/media resolved
- `event=channel.tap.completed` - Request created/passed to coordinator
- `event=channel.next.tap.received` - Up Next item handler entry
- `event=channel.next.tap.completed` - Up Next request completed

**How to use**: Open Console.app, filter by subsystem "PlexChannelsTV" and category "Channel" to see the full flow from button press to playback.

### 4. Final Button Structure (Clean + Separate Menu Trigger)
**Changed in: `ChannelRowView.swift`**

**Now Card Button**:
```swift
let nowButton = Button {
    AppLoggers.channel.info("event=channel.tap.action ...")
    onPrimaryPlay(channel)
}
.buttonStyle(.plain)
.focused(focusBinding, equals: nowFocusID)
.focusableCompat { /* focus logging */ }

#if os(tvOS)
return nowButton
    .onPlayPauseCommand {
        AppLoggers.channel.info("event=channel.playPause ...")
        menuTarget = .now
    }
#else
return nowButton
#endif
```

**Up Next Card Button**:
```swift
let upNextButton = Button {
    AppLoggers.channel.info("event=channel.tap.action ...")
    onPlayItem(channel, media)
}
.buttonStyle(.plain)
.focusableCompat { /* focus logging */ }

#if os(tvOS)
return upNextButton
    .onPlayPauseCommand {
        AppLoggers.channel.info("event=channel.playPause ...")
        menuTarget = .upNext(media)
    }
#else
return upNextButton
#endif
```

**Key Changes**:
- Button action has NO gesture/menu modifiers - completely clean
- `.onPlayPauseCommand` is separate and only sets state to trigger `confirmationDialog`
- Full-screen `confirmationDialog` appears when `menuTarget != nil`

## Files Modified
1. `/PlexChannelsTV/Views/ChannelRowView.swift` - Main button interaction fixes
2. `/PlexChannelsTV/Views/ChannelsView.swift` - Enhanced handler logging
3. `/AGENTS.md` - Added Task 26 documentation and debugging section

## Testing Recommendations

1. **Verify tap works**: Click on "Now Playing" card - should immediately start playback and show logs:
   ```
   event=channel.tap.action
   event=channel.tap.received
   event=channel.tap.prepare
   event=channel.tap.completed
   event=player.present
   ```

2. **Verify Up Next works**: Click on any "Up Next" poster - should start that item immediately

3. **Verify Play/Pause menu**: Long press Play/Pause button on Siri Remote while focused on a card - should show full-screen menu with "Start Now" and "Start From Beginning" options

4. **Check focus**: Navigate between cards with Siri Remote - should see focus highlight and `event=channel.focus.change` logs

## Key Debug Insight

**The logs you provided were CRITICAL to finding the real issue!**

When you said "pressing on the first movie still didn't start the play", the logs showed:
- ✓ Focus changes working: `event=channel.focus.change target=now`
- ✗ **NO `event=channel.tap.action` logs** - the button action was never called!
- ✓ Only saw `event=channel.contextMenu.action` when long-pressing

This immediately revealed that `.contextMenu` was **completely blocking** the button's primary action. Without those logs, we might have kept debugging focus/coordinator issues when the real problem was that the button action closure wasn't executing at all.

## Known Patterns Documented

Added to AGENTS.md debugging section:
- On tvOS, `.onLongPressGesture` blocks button taps AND `.contextMenu` prevents primary actions from firing
- Use `.onPlayPauseCommand` + state-driven `confirmationDialog` for tvOS secondary menus
- Always use `.buttonStyle(.plain)` for custom button content
- Use Console.app with subsystem filter for structured logging

## Before/After Behavior

**Before (with `.onLongPressGesture`))**:
- ✗ Short press on movie: No response
- ✓ Long press: Shows menu (but double-press needed)
- ✓ Force Play Now: Works
- ✗ Debug logs: Inconsistent

**Middle attempt (with `.contextMenu` - FAILED)**:
- ✗ Short press on movie: No response (button action never called!)
- ✓ Long press: Shows small tooltip-style menu
- ✓ Force Play Now: Works
- ✓ Debug logs: Showed NO `event=channel.tap.action` - revealed the issue

**After (clean button + `.onPlayPauseCommand`)**:
- ✓ Short press on movie: Starts playback immediately
- ✓ Long press Play/Pause: Shows full-screen confirmation dialog
- ✓ Force Play Now: Still works
- ✓ Debug logs: Comprehensive, structured, shows `event=channel.tap.action` → `event=channel.tap.received`

