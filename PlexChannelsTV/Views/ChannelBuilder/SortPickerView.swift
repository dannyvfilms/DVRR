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
        VStack(alignment: .leading, spacing: 24) {
            Text("Step 3 · Sort")
                .font(.title2.bold())

            Picker("Sort By", selection: $descriptor.key) {
                ForEach(availableKeys, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.inline)
            .frame(maxWidth: 420)

            if descriptor.key.supportsAscending {
                Picker("Order", selection: $descriptor.order) {
                    Text(SortDescriptor.Order.ascending.displayName).tag(SortDescriptor.Order.ascending)
                    Text(SortDescriptor.Order.descending.displayName).tag(SortDescriptor.Order.descending)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            } else {
                Text("Random order selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 32)
    }
}
