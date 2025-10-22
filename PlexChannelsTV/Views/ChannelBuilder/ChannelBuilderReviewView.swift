//
//  ChannelBuilderReviewView.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI

struct ChannelBuilderReviewView: View {
    @Binding var draft: ChannelDraft
    let libraries: [LibraryFilterSpec.LibraryRef]
    let counts: [String: ChannelBuilderViewModel.CountState]
    let totalItems: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Step 4 · Review")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                Text("Name")
                    .font(.headline)
                TextField("Channel Name", text: $draft.name)
                    .padding(.horizontal, 20)
                    .frame(width: 480, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }

            Toggle("Shuffle order", isOn: $draft.options.shuffle)
                .toggleStyle(.switch)

            if let totalItems {
                Text("Total items: \(totalItems)")
                    .font(.headline)
            } else {
                Text("Total items: pending")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Libraries")
                    .font(.headline)
                ForEach(libraries, id: \.id) { ref in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ref.title ?? "Library")
                                .font(.subheadline.bold())
                            Text(ref.type.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let countState = counts[ref.id], let total = countState.total {
                            Text("\(total)")
                                .font(.subheadline)
                        } else {
                            Text("—")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 20)
        }
        .padding(.vertical, 32)
    }
}
