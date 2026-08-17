import BridgeKit
import Foundation

import ActivityKit

/// The Live Activity contract (docs/02 FR-i1.3, AC-i6).
///
/// This file is compiled into *both* the app and the widget extension —
/// ActivityKit requires the attributes type to be identical in each binary,
/// and it cannot live in `BridgeKit` because that target is deliberately free
/// of Apple-UI frameworks so the keyboard can link it cheaply.
///
/// Its `ContentState` is `BridgeKit.RecordingActivityState`, so every string
/// the Dynamic Island renders is decided by code Linux CI already tests.
struct VocalRecordingAttributes: ActivityAttributes {
    typealias ContentState = RecordingActivityState

    /// Fixed for the life of the activity; the take's own identity.
    var takeID: String
}

