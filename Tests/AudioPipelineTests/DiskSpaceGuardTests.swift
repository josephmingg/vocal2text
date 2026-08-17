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

// MARK: - Live level meter (FR-4.1)

@Test func silenceMetersAtZero() {
    #expect(AudioLevelMeter.level(for: []) == 0)
    #expect(AudioLevelMeter.level(for: [Float](repeating: 0, count: 512)) == 0)
}

@Test func fullScaleMetersAtOne() {
    #expect(AudioLevelMeter.level(for: [Float](repeating: 1, count: 512)) == 1)
    // Polarity must not matter: RMS, not mean.
    #expect(AudioLevelMeter.level(for: [Float](repeating: -1, count: 512)) == 1)
}

@Test func ordinarySpeechLandsInTheVisibleMiddle() {
    // ~-26 dBFS, a normal speaking level: the bar should be clearly alive,
    // which is the whole point of metering in decibels rather than amplitude.
    let level = AudioLevelMeter.level(for: [Float](repeating: 0.05, count: 512))
    #expect(level > 0.4)
    #expect(level < 0.8)
}

@Test func levelsRiseWithLoudness() {
    let quiet = AudioLevelMeter.level(for: [Float](repeating: 0.01, count: 512))
    let medium = AudioLevelMeter.level(for: [Float](repeating: 0.1, count: 512))
    let loud = AudioLevelMeter.level(for: [Float](repeating: 0.5, count: 512))
    #expect(quiet < medium)
    #expect(medium < loud)
}

@Test func inaudibleRoomToneStaysAtTheFloor() {
    // Below the -60 dB floor the meter clamps instead of going negative.
    #expect(AudioLevelMeter.level(for: [Float](repeating: 0.0001, count: 512)) == 0)
}

@Test func levelsAreAlwaysDrawable() {
    // Whatever the input, the waveform gets a value it can render.
    for amplitude: Float in [0, 0.0001, 0.01, 0.2, 1, 2] {
        let level = AudioLevelMeter.level(for: [Float](repeating: amplitude, count: 64))
        #expect(level >= 0)
        #expect(level <= 1)
    }
}

// MARK: - Audio retention policy (FR-5.1, docs/11 G9)

@Test func neverKeepsNothing() {
    #expect(!AudioRetentionPolicy.keepsAudio(retentionDays: AudioRetentionPolicy.never))
    // Anything already on disk under "Never" is expired by definition.
    #expect(
        AudioRetentionPolicy.isExpired(
            createdAt: Date(), retentionDays: AudioRetentionPolicy.never
        )
    )
}

@Test func foreverNeverExpires() {
    #expect(AudioRetentionPolicy.keepsAudio(retentionDays: AudioRetentionPolicy.forever))
    let ancient = Date(timeIntervalSince1970: 0)
    #expect(
        !AudioRetentionPolicy.isExpired(
            createdAt: ancient, retentionDays: AudioRetentionPolicy.forever
        )
    )
}

@Test func aWindowExpiresOnlyPastItsEnd() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
    let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
    #expect(!AudioRetentionPolicy.isExpired(createdAt: sixDaysAgo, retentionDays: 7, now: now))
    #expect(AudioRetentionPolicy.isExpired(createdAt: eightDaysAgo, retentionDays: 7, now: now))
}

@Test func anUnreadableDateCountsAsExpired() {
    // An undateable file is an orphan; keeping voice recordings that no
    // retention window can ever reach would be the worse failure.
    #expect(AudioRetentionPolicy.isExpired(createdAt: nil, retentionDays: 30))
    #expect(!AudioRetentionPolicy.isExpired(createdAt: nil, retentionDays: AudioRetentionPolicy.forever))
}
