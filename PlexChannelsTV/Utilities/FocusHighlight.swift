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

    var body: some View {
        content.focusable(true, onFocusChange: onChange)
    }
}
#endif
