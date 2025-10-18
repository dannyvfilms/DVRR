//
//  LoginView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var plexService: PlexService

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var validationMessage: String?

    private var isFormValid: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private var currentError: String? {
        if let validationMessage {
            return validationMessage
        }
        return plexService.lastError?.errorDescription
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Sign in to Plex to continue")
                    .font(.title2)
                    .multilineTextAlignment(.center)

                Text("Enter the Plex account credentials you use to access your server. Your password is used only to obtain an authentication token and is not stored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 20) {
                TextField("Plex username or email", text: $username)
                    .textContentType(.username)
                    .submitLabel(.next)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
            }
            .frame(maxWidth: 420)

            if let currentError {
                Text(currentError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
            }

            Button(action: signIn) {
                if plexService.isAuthenticating {
                    HStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Signing In…")
                    }
                } else {
                    Text("Sign In")
                        .bold()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isFormValid || plexService.isAuthenticating)

            Spacer()
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .animation(.easeInOut(duration: 0.2), value: plexService.isAuthenticating)
        .animation(.easeInOut(duration: 0.2), value: currentError)
    }

    private func signIn() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else {
            validationMessage = "Please enter both your Plex username (or email) and password."
            return
        }

        validationMessage = nil

        Task {
            do {
                try await plexService.authenticate(username: trimmedUsername, password: password)
                password = ""
            } catch {
                if let serviceError = error as? PlexService.ServiceError {
                    validationMessage = serviceError.errorDescription
                } else {
                    validationMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(PlexService())
}
