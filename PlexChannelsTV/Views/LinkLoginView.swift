//
//  LinkLoginView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import SwiftUI

struct LinkLoginView: View {
    @EnvironmentObject private var authState: AuthState
    @EnvironmentObject private var plexService: PlexService

    @State private var pin: PinResponse?
    @State private var remainingSeconds: Int = 0
    @State private var statusMessage: String?
    @State private var isRequesting = false
    @State private var isPolling = false
    @State private var showLegacyLogin = false

    @State private var countdownTimer: Timer?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Link Your Plex Account")
                    .font(.largeTitle)

                Text("On your phone or computer, open plex.tv/link and enter the code below.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
            }

            if let pin {
                VStack(spacing: 24) {
                    Text(pin.code.uppercased())
                        .font(.system(size: 80, weight: .heavy, design: .monospaced))
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.thinMaterial)
                        )

                    if let qrURL = pin.qr {
                        AsyncImage(url: qrURL) { image in
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                                .padding(8)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } placeholder: {
                            ProgressView()
                        }
                    }

                    Text("Code expires in \(formattedTime(remainingSeconds)).")
                        .font(.headline)

                    Text(statusMessage ?? (isPolling ? "Waiting for approval…" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                if isRequesting {
                    ProgressView("Requesting code…")
                        .progressViewStyle(.circular)
                } else {
                    Button("Generate Code", action: refreshCode)
                        .buttonStyle(.borderedProminent)
                }
            }

            if authState.linkingError != nil {
                Text(authState.linkingError ?? "")
                    .foregroundStyle(.red)
            }

            HStack(spacing: 20) {
                Button("Regenerate Code", action: refreshCode)
                    .buttonStyle(.bordered)
                    .disabled(isRequesting)

                Button("More Options") {
                    showLegacyLogin = true
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if pin == nil {
                refreshCode()
            }
        }
        .onDisappear {
            invalidateTimers()
        }
        .sheet(isPresented: $showLegacyLogin) {
            LoginView()
                .environmentObject(plexService)
                .environmentObject(authState)
        }
    }

    private func refreshCode() {
        pollTask?.cancel()
        pollTask = nil
        invalidateTimers()
        statusMessage = nil
        authState.linkingError = nil

        guard !authState.isLinked else {
            return
        }

        isRequesting = true

        Task {
            do {
                let newPin = try await authState.requestPin()
                await MainActor.run {
                    pin = newPin
                    remainingSeconds = newPin.expiresIn
                    startCountdown(expiresAt: newPin.expiresAt)
                    startPolling(for: newPin)
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    pin = nil
                }
            }

            await MainActor.run {
                isRequesting = false
            }
        }
    }

    private func startCountdown(expiresAt: Date) {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let remaining = Int(max(0, expiresAt.timeIntervalSince(Date())))
            remainingSeconds = remaining

            if remaining <= 0 {
                countdownTimer?.invalidate()
                countdownTimer = nil
                statusMessage = "Code expired. Generate a new one."
                pollTask?.cancel()
                pollTask = nil
                isPolling = false
                pin = nil
            }
        }
    }

    private func startPolling(for pin: PinResponse) {
        guard !authState.isLinked else {
            isPolling = false
            return
        }

        isPolling = true
        pollTask = Task {
            do {
                let token = try await authState.pollPin(id: pin.id, until: pin.expiresAt)
                try await authState.completeLink(authToken: token)
                await MainActor.run {
                    statusMessage = "Linked! Loading your libraries…"
                    isPolling = false
                    invalidateTimers()
                }
            } catch {
                if error is CancellationError || (error as? LinkError) == .alreadyLinked {
                    await MainActor.run {
                        isPolling = false
                        pollTask = nil
                    }
                    return
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isPolling = false
                    pollTask = nil
                }
            }
        }
    }

    private func invalidateTimers() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func formattedTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

#Preview {
    let plexService = PlexService()
    let linkService = PlexLinkService(
        clientIdentifier: plexService.clientIdentifier,
        product: "PlexChannelsTV",
        version: "1.0",
        device: "Apple TV",
        platform: "tvOS",
        deviceName: "Apple TV"
    )
    let authState = AuthState(plexService: plexService, linkService: linkService)

    return LinkLoginView()
        .environmentObject(authState)
        .environmentObject(plexService)
}
