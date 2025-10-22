//
//  SeededRandomNumberGenerator.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xC0FFEE : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }
}
