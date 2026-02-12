//
//  ChannelPlayerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/25/25.
//

import SwiftUI
import AVKit
import UIKit

struct ChannelPlayerView: View {
    let request: ChannelPlaybackRequest
    let onExit: () -> Void

    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore
    @State private var player = AVPlayer()
    @State private var playbackContext: PlaybackContext?
    @State private var playbackTask: Task<Void, Never>?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var playToEndObserver: Any?
    @State private var failToEndObserver: Any?
    @State private var accessLogObserver: Any?
    @State private var errorLogObserver: Any?
    @State private var playbackStalledObserver: Any?
    @State private var showDebugOverlay = false
    @State private var playbackError: String?
    @State private var isLoading = false
    @State private var hasAttemptedFallback = false
    @State private var hasAttemptedRelaxedTranscodeFallback = false
    @State private var hasAttemptedRemuxFallback = false
    @State private var pendingSeek: TimeInterval?
    @State private var ticker: Timer?
    @State private var currentTime: CMTime = .zero
    @State private var hasStartedPlayback = false
    @State private var adaptiveState = AdaptiveState()
    @State private var isRecovering = false
    @State private var hasLoggedSegmentStart = false
    @State private var resourceLoaderDelegate: PlexResourceLoaderDelegate?  // Retain the delegate
    @State private var lastSessionUpdate: Date?  // Track last session progress update
    @State private var sessionUpdateInFlight = false
    @State private var directPlayRejectedItemIDs: Set<String> = []

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                        withAnimation(.spring(duration: 0.25)) {
                            showDebugOverlay.toggle()
                        }
                    }
                )

            if isLoading {
                ProgressView("Preparing…")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding()
            } else if let playbackError {
                errorOverlay(message: playbackError)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showDebugOverlay, let context = playbackContext {
                debugOverlay(for: context)
                    .padding()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { startIfNeeded() }
        .onDisappear { cleanup() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Clean up session when app goes to background (e.g., simulator reset)
            if playbackContext != nil {
                cleanup()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            cleanup()
        }
    }
}

// MARK: - Playback Lifecycle

private extension ChannelPlayerView {
    func startIfNeeded() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        adaptiveState = AdaptiveState()

        guard let entry = initialPlaybackEntry() else {
            playbackError = "Unable to locate a playable item for this channel."
            AppLoggers.playback.error(
                "event=play.status status=failed reason=\"missing_entry\" channelID=\(request.channelID.uuidString, privacy: .public)"
            )
            return
        }

        AppLoggers.playback.info(
            "event=play.status status=starting channelID=\(request.channelID.uuidString, privacy: .public) itemID=\(entry.media.id, privacy: .public) offsetSec=\(Int(entry.offset))"
        )
        startPlayback(for: entry)
    }

    func initialPlaybackEntry() -> PlaybackEntry? {
        let channel = latestChannel(with: request.channelID) ?? request.channel

        if let index = channel.items.firstIndex(where: { $0.id == request.item.id }) {
            return PlaybackEntry(channel: channel, index: index, media: channel.items[index], offset: request.offset)
        }

        if channel.items.indices.contains(request.itemIndex) {
            return PlaybackEntry(channel: channel, index: request.itemIndex, media: channel.items[request.itemIndex], offset: request.offset)
        }

        return nil
    }

    func startPlayback(
        for entry: PlaybackEntry,
        options: PlexService.StreamRequestOptions = PlexService.StreamRequestOptions(),
        fallbackFrom previousPlan: PlexService.StreamPlan? = nil,
        fallbackReason: String? = nil
    ) {
        playbackTask?.cancel()
        AppLoggers.playback.info(
            "event=play.start itemID=\(entry.media.id, privacy: .public) offsetSec=\(Int(entry.offset))"
        )
        playbackTask = Task { [weak plexService] in
            guard let service = plexService else { return }

            do {
                await MainActor.run {
                    isLoading = true
                    if previousPlan == nil {
                        playbackError = nil
                    }
                    if previousPlan != nil {
                        isRecovering = true
                    }
                }

                let plan = try await service.streamURLForItem(
                    itemID: entry.media.id,
                    startAtSec: entry.offset,
                    options: effectiveRequestOptions(options, for: entry)
                )

                await MainActor.run {
                    if let originPlan = previousPlan {
                        logFallback(from: originPlan, to: plan, reason: fallbackReason ?? "direct_failed")
                    }
                    applyPlan(plan, to: entry, resetFallback: previousPlan == nil)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    handlePlaybackError(error, entry: entry)
                }
            }
        }
    }

    func applyPlan(_ plan: PlexService.StreamPlan, to entry: PlaybackEntry, resetFallback: Bool) {
        isLoading = false

        if resetFallback {
            hasAttemptedFallback = false
            hasAttemptedRelaxedTranscodeFallback = false
            hasAttemptedRemuxFallback = false
        }

        let refreshedChannel = latestChannel(with: entry.channel.id) ?? entry.channel
        let refreshedEntry = PlaybackEntry(
            channel: refreshedChannel,
            index: entry.index,
            media: entry.media,
            offset: entry.offset
        )

        // Check if we're switching items (existing playback context) vs fresh start
        let isSwitchingItems = playbackContext != nil
        
        playbackContext = PlaybackContext(entry: refreshedEntry, plan: plan, startedAt: Date())
        pendingSeek = (plan.mode == .direct && entry.offset > 0) ? entry.offset : nil
        currentTime = .zero
        adaptiveState.configure(for: plan, reset: resetFallback)
        hasLoggedSegmentStart = false
        isRecovering = false
        lastSessionUpdate = nil  // Reset session update tracker
        sessionUpdateInFlight = false
        
        // For HLS transcoding, wait for timeline API call and a brief startup delay before loading.
        // The transcoder session can take a moment to become ready, especially on first item start.
        if plan.mode == .hls, let sessionID = plan.sessionID {
            Task { @MainActor in
                await plexService.startPlaybackSession(
                    sessionID: sessionID,
                    itemID: entry.media.id,
                    offset: entry.offset,
                    duration: entry.media.duration
                )
                
                let startupDelay: UInt64 = isSwitchingItems ? 300_000_000 : 900_000_000
                try? await Task.sleep(nanoseconds: startupDelay)
                
                replacePlayerItem(with: plan, entry: refreshedEntry)
            }
        } else {
            // For direct play, start immediately and report session asynchronously
            if let sessionID = plan.sessionID {
                Task {
                    await plexService.startPlaybackSession(
                        sessionID: sessionID,
                        itemID: entry.media.id,
                        offset: entry.offset,
                        duration: entry.media.duration
                    )
                }
            }
            
            replacePlayerItem(with: plan, entry: refreshedEntry)
        }
    }

    func effectiveRequestOptions(_ options: PlexService.StreamRequestOptions, for entry: PlaybackEntry) -> PlexService.StreamRequestOptions {
        guard directPlayRejectedItemIDs.contains(entry.media.id) else { return options }
        var adjusted = options
        adjusted.preferDirect = false
        return adjusted
    }

    func replacePlayerItem(with plan: PlexService.StreamPlan, entry: PlaybackEntry) {
        clearPlayerObservers()

        #if targetEnvironment(simulator)
        // The simulator has been consistently failing decode on HLS with custom resource loading.
        // Use native AVURLAsset loading in simulator to avoid resource-loader side effects.
        let asset = AVURLAsset(url: plan.url)
        resourceLoaderDelegate = nil
        #else
        // Route HLS through a custom scheme so AVFoundation consistently uses our resource loader.
        let assetURL = resourceLoaderURL(for: plan)
        let asset = AVURLAsset(url: assetURL)

        // Create and retain resource loader delegate with Plex headers.
        // AVAssetResourceLoader only keeps a weak reference, so we must retain it.
        if let session = plexService.session {
            // Use the same product name and version as PlexService for consistency
            let loaderDelegate = PlexResourceLoaderDelegate(
                sessionID: plan.sessionID,
                token: session.server.accessToken,
                clientIdentifier: plexService.clientIdentifier,
                productName: plexService.productName,
                version: plexService.clientVersion,
                platform: "tvOS",
                device: "Apple TV",
                deviceName: "Apple TV"
            )
            resourceLoaderDelegate = loaderDelegate  // Retain the delegate
            asset.resourceLoader.setDelegate(loaderDelegate, queue: DispatchQueue.main)
        } else {
            resourceLoaderDelegate = nil
        }
        #endif
        
        let item = AVPlayerItem(asset: asset)
        // Increase forward buffer to trade startup speed for fewer simulator stalls.
        #if targetEnvironment(simulator)
        item.preferredForwardBufferDuration = 24
        #else
        item.preferredForwardBufferDuration = 12
        #endif
        player.replaceCurrentItem(with: item)
        configurePlayer(for: plan, entry: entry, item: item)
        configureObservers(for: item, entry: entry, plan: plan)
    }

    func resourceLoaderURL(for plan: PlexService.StreamPlan) -> URL {
        guard plan.mode == .hls else { return plan.url }
        return PlexResourceLoaderDelegate.resourceLoaderURL(for: plan.url)
    }

    func configurePlayer(for plan: PlexService.StreamPlan, entry: PlaybackEntry, item: AVPlayerItem) {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        let peakBitrate = plan.maxVideoBitrate.map { Double($0) * 1_000 } ?? 0
        item.preferredPeakBitRate = peakBitrate
        let peakKbps = Int((peakBitrate / 1_000).rounded())
        AppLoggers.playback.info(
            "event=play.playerConfig itemID=\(entry.media.id, privacy: .public) remux=\(plan.directStream ? 1 : 0) forwardBufferSec=12 preferredPeakBitRateKbps=\(peakKbps) waitsToMinimizeStalling=1 externalPlayback=0"
        )
    }
}

// MARK: - Observers & Notifications

private extension ChannelPlayerView {
    func configureObservers(for item: AVPlayerItem, entry: PlaybackEntry, plan: PlexService.StreamPlan) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Task { @MainActor in
                handleStatusChange(for: item, entry: entry, plan: plan)
            }
        }

        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handleItemEnded(entry: entry, plan: plan)
            }
        }

        failToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in
                handlePlaybackFailure(for: entry, plan: plan, error: error)
            }
        }

        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                logAccessEvent(for: item, plan: plan, entry: entry)
            }
        }

        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                logErrorEvent(for: item, plan: plan, entry: entry)
            }
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handlePlaybackStall(entry: entry, plan: plan)
            }
        }
    }

    func clearPlayerObservers() {
        statusObserver?.invalidate()
        statusObserver = nil

        if let observer = playToEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playToEndObserver = nil
        }

        if let observer = failToEndObserver {
            NotificationCenter.default.removeObserver(observer)
            failToEndObserver = nil
        }

        if let observer = accessLogObserver {
            NotificationCenter.default.removeObserver(observer)
            accessLogObserver = nil
        }

        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }

        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
    }
}

// MARK: - Status Handling

private extension ChannelPlayerView {
    @MainActor
    func handleStatusChange(for item: AVPlayerItem, entry: PlaybackEntry, plan: PlexService.StreamPlan) {
        switch item.status {
        case .readyToPlay:
            AppLoggers.playback.info(
                "event=play.status status=ready mode=\(plan.mode.rawValue, privacy: .public) itemID=\(entry.media.id, privacy: .public)"
            )
            startTicker()

            if let pendingSeek {
                performSeek(to: pendingSeek, item: item, entry: entry)
            } else {
                player.play()
            }

        case .failed:
            let nsError = item.error as NSError?
            let errorDomain = nsError?.domain ?? "unknown"
            let errorCode = nsError?.code ?? -1
            AppLoggers.playback.error(
                "event=play.status status=failed mode=\(plan.mode.rawValue, privacy: .public) itemID=\(entry.media.id, privacy: .public) errorDomain=\(errorDomain, privacy: .public) errorCode=\(errorCode, privacy: .public)"
            )
            handlePlaybackFailure(for: entry, plan: plan, error: item.error)

        case .unknown:
            AppLoggers.playback.info(
                "event=play.status status=unknown mode=\(plan.mode.rawValue, privacy: .public) itemID=\(entry.media.id, privacy: .public)"
            )

        @unknown default:
            break
        }
    }

    @MainActor
    func performSeek(to seconds: TimeInterval, item: AVPlayerItem, entry: PlaybackEntry) {
        pendingSeek = nil
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)

        AppLoggers.playback.info(
            "event=play.seek requestedSec=\(Int(seconds)) itemID=\(entry.media.id, privacy: .public)"
        )

        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            let result = finished ? "ok" : "fail"
            AppLoggers.playback.info(
                "event=play.seek result=\(result, privacy: .public) requestedSec=\(Int(seconds)) itemID=\(entry.media.id, privacy: .public)"
            )
            self.player.play()
        }
    }

    @MainActor
    func handlePlaybackFailure(for entry: PlaybackEntry, plan: PlexService.StreamPlan, error: Error?) {
        let nsError = (error as NSError?) ?? NSError(domain: "Playback", code: -1)
        let errorDomain = nsError.domain
        let errorCode = nsError.code
        let isHLSStartupAvailabilityError =
            errorCode == -1100 || errorCode == NSURLErrorResourceUnavailable

        // For HLS streams, early resource failures often mean transcoder output isn't ready yet
        // Retry once with a new session and slight delay
        if plan.mode == .hls && isHLSStartupAvailabilityError && !hasAttemptedFallback {
            hasAttemptedFallback = true
            AppLoggers.playback.warning(
                "event=play.retry itemID=\(entry.media.id, privacy: .public) reason=hls_resource_unavailable errorCode=\(errorCode)"
            )
            
            // Wait a moment for transcoder to initialize, then retry with new session
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                
                var options = plan.request
                #if targetEnvironment(simulator)
                options.forceNewSession = false
                #else
                options.forceNewSession = true  // Force new transcoder session
                #endif
                startPlayback(for: entry, options: options, fallbackFrom: plan, fallbackReason: "hls_resource_unavailable")
            }
            return
        }

        // Some streams can return an initial HLS payload that decodes poorly on first attempt
        // (CoreMediaErrorDomain -12881). Retry once with a fresh session and lower capped bitrate.
        if plan.mode == .hls,
           errorDomain == "CoreMediaErrorDomain",
           errorCode == -12881,
           !hasAttemptedFallback {
            hasAttemptedFallback = true
            AppLoggers.playback.warning(
                "event=play.retry itemID=\(entry.media.id, privacy: .public) reason=coremedia_decode_error errorCode=\(errorCode)"
            )

            Task { @MainActor in
                if let staleSessionID = plan.sessionID {
                    await plexService.stopPlaybackSession(
                        sessionID: staleSessionID,
                        itemID: entry.media.id,
                        offset: entry.offset
                    )
                }
                var options = plan.request
                options.preferDirect = false
                options.forceTranscode = true
                options.forceRemux = false
                options.forceNewSession = true
                options.preferredMaxBitrate = min(options.preferredMaxBitrate ?? 8_000, 6_000)
                startPlayback(for: entry, options: options, fallbackFrom: plan, fallbackReason: "coremedia_decode_error")
            }
            return
        }

        // Some Plex servers return 400 for strict transcode query variants on a recovery attempt.
        // Retry once with relaxed transcode params (no explicit codec/bitrate hints).
        if plan.mode == .hls,
           errorDomain == NSURLErrorDomain,
           errorCode == NSURLErrorBadServerResponse,
           plan.request.forceNewSession,
           !hasAttemptedRelaxedTranscodeFallback {
            hasAttemptedRelaxedTranscodeFallback = true
            AppLoggers.playback.warning(
                "event=play.retry itemID=\(entry.media.id, privacy: .public) reason=hls_start_bad_request_relaxed_transcode errorCode=\(errorCode)"
            )

            Task { @MainActor in
                if let staleSessionID = plan.sessionID {
                    await plexService.stopPlaybackSession(
                        sessionID: staleSessionID,
                        itemID: entry.media.id,
                        offset: entry.offset
                    )
                }
                var options = plan.request
                options.preferDirect = false
                options.forceTranscode = true
                options.forceRemux = false
                options.forceNewSession = true
                options.relaxedTranscodeParams = true
                options.preferredMaxBitrate = nil
                startPlayback(for: entry, options: options, fallbackFrom: plan, fallbackReason: "hls_start_bad_request_relaxed_transcode")
            }
            return
        }

        // If strict and relaxed transcode startup are both rejected (HTTP 400),
        // attempt a remux fallback (copy streams) with a fresh session.
        if plan.mode == .hls,
           errorDomain == NSURLErrorDomain,
           errorCode == NSURLErrorBadServerResponse,
           plan.request.forceNewSession,
           plan.request.relaxedTranscodeParams,
           !hasAttemptedRemuxFallback {
            hasAttemptedRemuxFallback = true
            AppLoggers.playback.warning(
                "event=play.retry itemID=\(entry.media.id, privacy: .public) reason=hls_start_bad_request_force_remux errorCode=\(errorCode)"
            )

            Task { @MainActor in
                if let staleSessionID = plan.sessionID {
                    await plexService.stopPlaybackSession(
                        sessionID: staleSessionID,
                        itemID: entry.media.id,
                        offset: entry.offset
                    )
                }
                var options = plan.request
                options.preferDirect = false
                options.forceTranscode = false
                options.forceRemux = true
                options.forceNewSession = true
                options.relaxedTranscodeParams = false
                options.preferredMaxBitrate = nil
                startPlayback(for: entry, options: options, fallbackFrom: plan, fallbackReason: "hls_start_bad_request_force_remux")
            }
            return
        }
        
        if plan.mode == .direct && !hasAttemptedFallback {
            hasAttemptedFallback = true
            let reason = (error as NSError?)?.localizedDescription ?? "direct_failed"
            if errorDomain == AVFoundationErrorDomain,
               errorCode == -11828 {
                directPlayRejectedItemIDs.insert(entry.media.id)
                AppLoggers.playback.info(
                    "event=play.directDisabled itemID=\(entry.media.id, privacy: .public) reason=cannot_open"
                )
            }
            var options = PlexService.StreamRequestOptions()
            options.preferDirect = false
            options.preferredMaxBitrate = max(adaptiveState.bitrateCap, 8_000)
            options.forceRemux = plan.directStream
            options.forceTranscode = false
            startPlayback(for: entry, options: options, fallbackFrom: plan, fallbackReason: reason)
            return
        }

        stopTicker()
        playbackError = nsError.localizedDescription
        AppLoggers.playback.error(
            "event=play.status status=failed itemID=\(entry.media.id, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(errorCode)"
        )
    }

    @MainActor
    func handleItemEnded(entry: PlaybackEntry, plan: PlexService.StreamPlan) {
        stopTicker()
        
        // Mark item as watched/scrobbled when playback completes
        if let sessionID = plan.sessionID {
            Task {
                // Report completion to Plex for scrobbling/On Deck
                let totalDuration = entry.media.duration
                await plexService.reportTimeline(
                    sessionID: sessionID,
                    itemID: entry.media.id,
                    offset: totalDuration,  // Report at end of item
                    state: "stopped",
                    duration: totalDuration
                )
            }
        }
        
        guard let nextEntry = nextPlaybackEntry(after: entry) else {
            playbackError = "No additional items available in this channel."
            AppLoggers.playback.error(
                "event=play.end endedItemID=\(entry.media.id, privacy: .public) nextItemID=none"
            )
            return
        }

        AppLoggers.playback.info(
            "event=play.end endedItemID=\(entry.media.id, privacy: .public) nextItemID=\(nextEntry.media.id, privacy: .public)"
        )
        AppLoggers.playback.info(
            "event=play.autoNext channelID=\(nextEntry.channel.id.uuidString, privacy: .public) nextItemID=\(nextEntry.media.id, privacy: .public)"
        )
        hasAttemptedFallback = false
        hasAttemptedRelaxedTranscodeFallback = false
        hasAttemptedRemuxFallback = false
        startPlayback(for: nextEntry)
    }
}

// MARK: - Logging Helpers

private extension ChannelPlayerView {
    func logFallback(from origin: PlexService.StreamPlan, to newPlan: PlexService.StreamPlan, reason: String) {
        AppLoggers.playback.info(
            "event=play.fallback from=\(origin.mode.rawValue, privacy: .public) to=\(newPlan.mode.rawValue, privacy: .public) directURL=\(origin.url.redactedForLogging(), privacy: .public) nextURL=\(newPlan.url.redactedForLogging(), privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    @MainActor
    func logAccessEvent(for item: AVPlayerItem, plan: PlexService.StreamPlan, entry: PlaybackEntry) {
        guard let event = item.accessLog()?.events.last else { return }
        let observed = Int(event.observedBitrate / 1000)
        let indicated = Int(event.indicatedBitrate / 1000)
        AppLoggers.playback.info(
            "event=play.accessLog mode=\(plan.mode.rawValue, privacy: .public) itemID=\(entry.media.id, privacy: .public) observedKbps=\(observed) indicatedKbps=\(indicated)"
        )
        logFirstSegmentIfNeeded(from: event, plan: plan, entry: entry)
        evaluateThroughput(observedKbps: observed, indicatedKbps: indicated, plan: plan, entry: entry)
    }

    @MainActor
    func logErrorEvent(for item: AVPlayerItem, plan: PlexService.StreamPlan, entry: PlaybackEntry) {
        guard let event = item.errorLog()?.events.last else { return }
        let domainValue = (event.errorDomain as String?) ?? ""
        let domain = domainValue.isEmpty ? "unknown" : domainValue
        AppLoggers.playback.error(
            "event=play.errorLog itemID=\(entry.media.id, privacy: .public) domain=\(domain, privacy: .public) status=\(event.errorStatusCode)"
        )
        #if !targetEnvironment(simulator)
        if plan.mode == .hls, domain == "CoreMediaErrorDomain", event.errorStatusCode == -16830 {
            attemptRecovery(for: plan, entry: entry, cause: .stall)
        }
        #endif
    }

    @MainActor
    func handlePlaybackStall(entry: PlaybackEntry, plan: PlexService.StreamPlan) {
        #if targetEnvironment(simulator)
        // Avoid aggressive restart loops on simulator; let AVPlayer attempt to recover in-place.
        return
        #else
        attemptRecovery(for: plan, entry: entry, cause: .stall)
        #endif
    }

    @MainActor
    func logFirstSegmentIfNeeded(from event: AVPlayerItemAccessLogEvent, plan: PlexService.StreamPlan, entry: PlaybackEntry) {
        guard plan.mode == .hls, !hasLoggedSegmentStart else { return }
        guard let uriString = event.uri, let url = URL(string: uriString) else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let candidateNames = ["start", "startTime", "offset", "begin"]
        var ptsValue: String?
        if let items = components?.queryItems {
            for name in candidateNames {
                if let value = items.first(where: { $0.name == name })?.value {
                    ptsValue = value
                    break
                }
            }
        }
        if ptsValue == nil, let fragment = components?.fragment {
            for name in candidateNames {
                if let range = fragment.range(of: "\(name)=") {
                    let remainder = fragment[range.upperBound...]
                    if let end = remainder.firstIndex(of: "&") {
                        ptsValue = String(remainder[..<end])
                    } else {
                        ptsValue = String(remainder)
                    }
                    break
                }
            }
        }
        guard let ptsValue else { return }
        hasLoggedSegmentStart = true
        AppLoggers.playback.info(
            "event=play.segmentFirst itemID=\(entry.media.id, privacy: .public) pts=\(ptsValue, privacy: .public) uri=\(url.redactedForLogging(), privacy: .public)"
        )
    }

    @MainActor
    func evaluateThroughput(observedKbps: Int, indicatedKbps: Int, plan: PlexService.StreamPlan, entry: PlaybackEntry) {
        #if targetEnvironment(simulator)
        return
        #endif
        guard plan.mode == .hls else { return }
        guard indicatedKbps > 0 else {
            adaptiveState.lowThroughputStart = nil
            return
        }

        // Trigger if observed is less than 60% of indicated (was 50%)
        if Double(observedKbps) < Double(indicatedKbps) * 0.6 {
            if adaptiveState.lowThroughputStart == nil {
                adaptiveState.lowThroughputStart = Date()
            } else if !adaptiveState.lowThroughputTriggered,
                      let start = adaptiveState.lowThroughputStart,
                      Date().timeIntervalSince(start) >= 5 {  // Reduced from 10s to be more proactive
                adaptiveState.lowThroughputTriggered = true
                attemptRecovery(for: plan, entry: entry, cause: .throughput(observed: observedKbps, indicated: indicatedKbps))
            }
        } else {
            adaptiveState.lowThroughputStart = nil
        }
    }

    @MainActor
    func attemptRecovery(for plan: PlexService.StreamPlan, entry: PlaybackEntry, cause: RecoveryCause) {
        guard plan.mode == .hls else { return }
        guard let context = playbackContext, context.plan.url == plan.url else { return }

        let now = Date()
        if let last = adaptiveState.lastRecovery, now.timeIntervalSince(last) < 5 {
            return
        }

        if cause.requiresEarlyWindow {
            let elapsed = now.timeIntervalSince(context.startedAt)
            if elapsed > 45 { return }
        }

        let previousBitrate = adaptiveState.bitrateCap
        var newOptions = plan.request
        newOptions.preferDirect = false
        let minimumCap = 3_000

        // When remuxing (directStream), we can't limit bitrate - it's copy-only
        // If remuxing stalls, it's likely a network/server issue - force transcoding as fallback
        let isRemuxing = plan.directStream

        var forceTranscodeTriggered = false
        if isRemuxing {
            // Remuxing failed - ALWAYS force actual transcoding as fallback on ANY stall
            // Can't reduce remux bitrate (it's copy-only), so must switch to transcoding
            if !adaptiveState.forceTranscode {
                adaptiveState.forceTranscode = true
                adaptiveState.bitrateCap = 6_000  // Start transcoding at 6Mbps
                forceTranscodeTriggered = true
            }
            adaptiveState.downshiftCount += 1
        } else if adaptiveState.forceTranscode {
            let reduced = max(Int(Double(previousBitrate) * 0.7), minimumCap)
            if reduced >= previousBitrate {
                AppLoggers.playback.error(
                    "event=play.recover.exhausted itemID=\(entry.media.id, privacy: .public) cause=\(cause.label)"
                )
                return
            }
            adaptiveState.bitrateCap = reduced
            adaptiveState.downshiftCount += 1
        } else if adaptiveState.downshiftCount >= 2 {
            adaptiveState.forceTranscode = true
            adaptiveState.bitrateCap = 6_000  // Reduced from 7Mbps for better stability
            forceTranscodeTriggered = true
            adaptiveState.downshiftCount += 1
        } else {
            // First stall: drop to 60% (more aggressive), subsequent stalls: 70%
            let reduction = adaptiveState.downshiftCount == 0 ? 0.6 : 0.7
            let reduced = max(Int(Double(previousBitrate) * reduction), minimumCap)
            if reduced == previousBitrate {
                return
            }
            adaptiveState.bitrateCap = reduced
            adaptiveState.downshiftCount += 1
        }

        adaptiveState.lowThroughputStart = nil
        adaptiveState.lastRecovery = now

        newOptions.forceTranscode = adaptiveState.forceTranscode
        newOptions.forceRemux = adaptiveState.forceTranscode ? false : plan.directStream
        // Only set bitrate limit when transcoding (not remuxing - remuxing copies original quality)
        newOptions.preferredMaxBitrate = adaptiveState.forceTranscode ? adaptiveState.bitrateCap : (plan.directStream ? nil : adaptiveState.bitrateCap)
        newOptions.forceNewSession = true  // Force new Plex transcoder session with updated bitrate

        let logBitrate = adaptiveState.bitrateCap
        switch cause {
        case .stall:
            if forceTranscodeTriggered {
                AppLoggers.playback.info(
                    "event=play.recover.forceTranscode itemID=\(entry.media.id, privacy: .public) cause=stall downshiftKbps=\(logBitrate)"
                )
            } else {
                AppLoggers.playback.info(
                    "event=play.recover itemID=\(entry.media.id, privacy: .public) cause=stall downshiftKbps=\(logBitrate)"
                )
            }
        case .throughput(let observed, let indicated):
            if forceTranscodeTriggered {
                AppLoggers.playback.info(
                    "event=play.recover.forceTranscode itemID=\(entry.media.id, privacy: .public) cause=throughput observedKbps=\(observed) indicatedKbps=\(indicated) downshiftKbps=\(logBitrate)"
                )
            } else {
                AppLoggers.playback.info(
                    "event=play.recover itemID=\(entry.media.id, privacy: .public) cause=throughput observedKbps=\(observed) indicatedKbps=\(indicated) downshiftKbps=\(logBitrate)"
                )
            }
        }

        stopTicker()
        player.pause()
        let currentSeconds = player.currentTime().seconds
        
        // When using copyts=1, currentTime() returns absolute PTS from the original file,
        // so we don't need to add entry.offset (which would double-count).
        // Use currentSeconds directly as the resume position.
        var resumeOffset = entry.offset
        if currentSeconds.isFinite && currentSeconds > 1 {
            // currentSeconds is already absolute position due to copyts=1
            resumeOffset = min(currentSeconds, entry.media.duration)
            AppLoggers.playback.info(
                "event=play.recover.position itemID=\(entry.media.id, privacy: .public) originalOffsetSec=\(Int(entry.offset)) currentTimeSec=\(Int(currentSeconds)) resumeOffsetSec=\(Int(resumeOffset))"
            )
        }
        let updatedEntry = PlaybackEntry(channel: entry.channel, index: entry.index, media: entry.media, offset: resumeOffset)
        adaptiveState.lowThroughputTriggered = false
        startPlayback(for: updatedEntry, options: newOptions, fallbackFrom: plan, fallbackReason: cause.label)
    }
}

// MARK: - Error Handling

private extension ChannelPlayerView {
    func handlePlaybackError(_ error: Error, entry: PlaybackEntry) {
        stopTicker()
        isLoading = false
        isRecovering = false

        let nsError = error as NSError
        playbackError = nsError.localizedDescription
        AppLoggers.playback.error(
            "event=play.status status=failed itemID=\(entry.media.id, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code)"
        )
    }
}

// MARK: - Channel Helpers

private extension ChannelPlayerView {
    func latestChannel(with id: Channel.ID) -> Channel? {
        channelStore.channels.first(where: { $0.id == id })
    }

    func nextPlaybackEntry(after entry: PlaybackEntry) -> PlaybackEntry? {
        let channel = latestChannel(with: entry.channel.id) ?? entry.channel
        guard !channel.items.isEmpty else { return nil }

        let nextIndex = (entry.index + 1) % channel.items.count
        let nextMedia = channel.items[nextIndex]
        return PlaybackEntry(channel: channel, index: nextIndex, media: nextMedia, offset: 0)
    }
}

// MARK: - UI Builders

private extension ChannelPlayerView {
    func errorOverlay(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback Error")
                .font(.title2)
                .bold()
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    func debugOverlay(for context: PlaybackContext) -> some View {
        let elapsed = elapsedSeconds(for: context)
        let total = context.entry.media.duration
        let nextTitle = nextPlaybackEntry(after: context.entry)?.media.title ?? "—"

        return VStack(alignment: .leading, spacing: 6) {
            Text(context.entry.channel.name)
                .font(.headline)
            Text(context.entry.media.title)
                .font(.callout)
            Text("Mode: \(context.plan.mode.rawValue.uppercased()) · \(context.plan.reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Offset: \(formatTime(elapsed)) / \(formatTime(total))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Token: \(context.plan.tokenType.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Next: \(nextTitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Timers

private extension ChannelPlayerView {
    func startTicker() {
        stopTicker()
        // Note: Cannot use [weak self] because ChannelPlayerView is a struct (SwiftUI View)
        // SwiftUI handles memory management, so direct capture is safe
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            currentTime = player.currentTime()
            
            // Periodically update session progress (every 30 seconds)
            let now = Date()
            if let context = playbackContext,
               let sessionID = context.plan.sessionID,
               !sessionUpdateInFlight,
               lastSessionUpdate == nil || now.timeIntervalSince(lastSessionUpdate!) >= 30 {
                sessionUpdateInFlight = true
                lastSessionUpdate = now
                Task { @MainActor in
                    let elapsed = elapsedSeconds(for: context)
                    await plexService.updatePlaybackSession(
                        sessionID: sessionID,
                        itemID: context.entry.media.id,
                        offset: elapsed,
                        duration: context.entry.media.duration
                    )
                    sessionUpdateInFlight = false
                }
            }
        }
    }

    func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    func elapsedSeconds(for context: PlaybackContext) -> TimeInterval {
        let base = max(0, context.entry.offset)
        let current = max(0, currentTime.seconds)

        // HLS on simulator often reports absolute playback time (already includes offset).
        if context.plan.mode == .hls {
            if current >= max(1, base - 2) {
                return min(current, context.entry.media.duration)
            }
            return min(base + current, context.entry.media.duration)
        }

        return min(base + current, context.entry.media.duration)
    }
}

// MARK: - Helpers

private extension ChannelPlayerView {
    func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "00:00" }
        let totalSeconds = Int(max(0, interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func cleanup() {
        playbackTask?.cancel()
        playbackTask = nil
        clearPlayerObservers()
        stopTicker()
        player.pause()
        
        // Report session stop to Plex server (critical for cleanup)
        if let context = playbackContext, let sessionID = context.plan.sessionID {
            let itemID = context.entry.media.id
            let elapsed = elapsedSeconds(for: context)
            
            // Use Task.detached to ensure cleanup completes even if view is deallocated
            Task.detached { [weak plexService] in
                guard let service = plexService else { return }
                await service.stopPlaybackSession(
                    sessionID: sessionID,
                    itemID: itemID,
                    offset: elapsed
                )
            }
        }
        
        resourceLoaderDelegate = nil  // Release the delegate
        playbackContext = nil  // Clear context to prevent duplicate cleanup
        onExit()
    }
}

// MARK: - Models

private extension ChannelPlayerView {
    struct PlaybackEntry {
        let channel: Channel
        let index: Int
        let media: Channel.Media
        let offset: TimeInterval
    }

    struct PlaybackContext {
        let entry: PlaybackEntry
        let plan: PlexService.StreamPlan
        let startedAt: Date
    }

    struct AdaptiveState {
        var bitrateCap: Int = 8_000  // Start conservative to reduce stalls
        var downshiftCount: Int = 0
        var forceTranscode: Bool = false
        var lowThroughputStart: Date?
        var lowThroughputTriggered = false
        var lastRecovery: Date?

        mutating func configure(for plan: PlexService.StreamPlan, reset: Bool) {
            // preferredMaxBitrate is now optional (nil for remuxing), use 8Mbps as default
            bitrateCap = plan.request.preferredMaxBitrate ?? 8_000
            forceTranscode = plan.request.forceTranscode
            if reset {
                downshiftCount = 0
                lowThroughputStart = nil
                lowThroughputTriggered = false
                lastRecovery = nil
            }
        }
    }

    enum RecoveryCause {
        case stall
        case throughput(observed: Int, indicated: Int)

        var label: String {
            switch self {
            case .stall:
                return "stall"
            case .throughput:
                return "throughput"
            }
        }

        var requiresEarlyWindow: Bool {
            switch self {
            case .stall:
                return true
            case .throughput:
                return false
            }
        }
    }
}
