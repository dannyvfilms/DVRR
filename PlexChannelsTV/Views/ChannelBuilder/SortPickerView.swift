//
//  SortPickerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI

struct SortPickerView: View {
    @Binding var descriptor: SortDescriptor
    let availableKeys: [SortDescriptor.SortKey]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Step 3 · Sort")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 20) {
                // Sort By dropdown
                HStack(spacing: 16) {
                    Text("Sort By")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    
                    Menu {
                        ForEach(availableKeys, id: \.self) { key in
                            Button {
                                descriptor.key = key
                            } label: {
                                HStack {
                                    Text(key.displayName)
                                    if descriptor.key == key {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(descriptor.key.displayName)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                        }
                        .frame(width: 320, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
                
                // Order dropdown (only for non-random)
                if descriptor.key.supportsAscending {
                    HStack(spacing: 16) {
                        Text("Order")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        
                        Menu {
                            Button {
                                descriptor.order = .ascending
                            } label: {
                                HStack {
                                    Text(SortDescriptor.Order.ascending.displayName)
                                    if descriptor.order == .ascending {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Button {
                                descriptor.order = .descending
                            } label: {
                                HStack {
                                    Text(SortDescriptor.Order.descending.displayName)
                                    if descriptor.order == .descending {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(descriptor.order.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .imageScale(.small)
                            }
                            .frame(width: 320, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 16) {
                        Text("Order")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        
                        Text("Random order selected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 20)
    }
}
