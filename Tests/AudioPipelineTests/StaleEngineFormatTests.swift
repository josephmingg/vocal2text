#if canImport(AVFoundation)
import AVFoundation
import Testing

@testable import AudioPipeline

// Field crash: a prepared engine kept the previous input device's format, and
// installTap raised an uncatchable exception on the mismatch. The prepared
// engine is now discarded whenever its node and the hardware disagree.

private func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
}

@Test func aMatchingFormatKeepsThePreparedEngine() {
    let node = format(rate: 48_000, channels: 1)
    #expect(MicrophoneCapture.formatsAgree(node: node, hardware: format(rate: 48_000, channels: 1)))
}

@Test func aRateChangeSinceThePreheatDiscardsIt() {
    // e.g. AirPods connected: 48 kHz built-in mic → 24 kHz headset mic.
    let node = format(rate: 48_000, channels: 1)
    #expect(!MicrophoneCapture.formatsAgree(node: node, hardware: format(rate: 24_000, channels: 1)))
}

@Test func aChannelChangeSinceThePreheatDiscardsIt() {
    let node = format(rate: 48_000, channels: 2)
    #expect(!MicrophoneCapture.formatsAgree(node: node, hardware: format(rate: 48_000, channels: 1)))
}
#endif
