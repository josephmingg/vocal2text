import SwiftUI
import WidgetKit

/// Vocal's widget extension. Today it carries one thing: the recording Live
/// Activity that drives the Dynamic Island (docs/02 FR-i1.3).
@main
struct VocalWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
