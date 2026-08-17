import Foundation
import Testing

@testable import AudioPipeline

// FR-1.3 low-disk guard decision logic (docs/11 G4). The stat side is
// Darwin-only; the decision is pure and runs everywhere.

@Test func unknownCapacityIsNotCritical() {
    // A failed stat must not fail takes on healthy disks.
    #expect(!DiskSpaceGuard.isCritical(availableBytes: nil))
}

@Test func capacityBelowTheFloorIsCritical() {
    #expect(DiskSpaceGuard.isCritical(availableBytes: DiskSpaceGuard.minimumFreeBytes - 1))
    #expect(DiskSpaceGuard.isCritical(availableBytes: 0))
}

@Test func capacityAtOrAboveTheFloorIsNotCritical() {
    #expect(!DiskSpaceGuard.isCritical(availableBytes: DiskSpaceGuard.minimumFreeBytes))
    #expect(!DiskSpaceGuard.isCritical(availableBytes: .max))
}
