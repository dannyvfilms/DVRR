//
//  Item.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
