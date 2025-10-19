//
//  FocusHighlight.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/21/25.
//

import SwiftUI

extension View {
    /// No-op placeholder to keep legacy focus extension references compiling across toolchains.
    func highlightFocusEffect() -> some View {
        self
    }

    /// Wraps focus change handling so legacy toolchains compile without deprecated warnings.
    func focusableCompat(_ onChange: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        FocusLegacyWrapper(content: self, onChange: onChange)
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct FocusLegacyWrapper<Content: View>: View {
    let content: Content
    let onChange: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        if #available(tvOS 15.0, *) {
            FocusStateWrapper(content: content, onChange: onChange)
        } else {
            content.focusable(true, onFocusChange: onChange)
        }
    }
}

@available(tvOS 15.0, *)
private struct FocusStateWrapper<Content: View>: View {
    let content: Content
    let onChange: (Bool) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        if #available(tvOS 17.0, *) {
            content
                .focusable(true)
                .focused($isFocused)
                .onChange(of: isFocused) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    onChange(newValue)
                }
        } else {
            content
                .focusable(true)
                .focused($isFocused)
                .onChange(of: isFocused) { newValue in
                    onChange(newValue)
                }
        }
    }
}
#endif
