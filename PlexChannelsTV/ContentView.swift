//
//  ContentView.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var plexService: PlexService

    var body: some View {
        Group {
            if plexService.session != nil {
                MainContentView()
            } else {
                LoginView()
            }
        }
    }
}

private struct MainContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @EnvironmentObject private var plexService: PlexService

    var body: some View {
        NavigationSplitView {
            List {
                Section(header: Text("Libraries")) {
                    ForEach(plexService.session?.libraries ?? [], id: \.uuid) { library in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(library.title ?? "Unknown Library")
                                .font(.headline)
                            Text(library.type.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Sample Data")) {
                    ForEach(items) { item in
                        NavigationLink {
                            Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                        } label: {
                            Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out", role: .destructive) {
                        plexService.signOut()
                    }
                }
            }
        } detail: {
            if let serverName = plexService.session?.server.name {
                VStack(spacing: 12) {
                    Text(serverName)
                        .font(.title2)
                    Text("Select a library or sample item to continue.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select an item")
            }
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
        .environmentObject(PlexService())
}
