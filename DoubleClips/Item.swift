//
//  Item.swift
//  DoubleClips
//
//  Created by Nguyen Thanh Long on 25/11/25.
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
