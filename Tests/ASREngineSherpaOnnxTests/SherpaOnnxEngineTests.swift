import ASRKit
import CoreModels
import Foundation
import ModelStore
import Testing
@testable import ASREngineSherpaOnnx

// MARK: - Variant facts (run everywhere, Linux included)

/// The archive URLs and byte counts are load-bearing: a typo here becomes a
/// 404 in the first-run download, and the byte counts are what availability
/// reports to the user. They are pinned to the measured values from the
/// FLEURS my_mm benchmark run (docs/benchmarks/burmese-asr-2026-08-17.md).
@Suite struct SherpaOnnxModelVariantTests {

    @Test func oneBArchiveFactsMatchTheBenchmarkedRelease() {
        let variant = SherpaOnnxModelVariant.omnilingual1B
        #expect(
            variant.archiveURL.absoluteString
                == "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-int8-2025-11-12.tar.bz2"
        )
        #expect(variant.archiveBytes == 786_404_815)
        #expect(variant.catalogID == "omni-asr-ctc-1b-int8")
        #expect(variant.modelRelativePath.hasSuffix("/model.int8.onnx"))
        #expect(variant.tokensRelativePath.hasSuffix("/tokens.txt"))
    }

    @Test func threeHundredMArchiveFactsMatchTheBenchmarkedRelease() {
        let variant = SherpaOnnxModelVariant.omnilingual300M
        #expect(
            variant.archiveURL.absoluteString
                == "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12.tar.bz2"
        )
        #expect(variant.archiveBytes == 292_571_207)
        #expect(variant.catalogID == "omni-asr-ctc-300m-int8")
    }

    /// The engine installs into `<root>/sherpa-onnx/<catalogID>/`, the layout
    /// ModelStore owns — so each variant's catalogID must name a real catalog
    /// entry for the sherpa-onnx engine, or the two tools manage different
    /// directories.
    @Test(arguments: [SherpaOnnxModelVariant.omnilingual1B, .omnilingual300M])
    func variantMatchesACatalogEntry(variant: SherpaOnnxModelVariant) {
        let entry = ModelCatalog.builtIn.first { $0.id == variant.catalogID }
        #expect(entry != nil)
        #expect(entry?.engine == "sherpa-onnx")
        #expect(entry?.languages.contains(.burmese) == true)
    }

    @Test func extractedDirectoryNamesMatchTheArchiveNames() {
        // Upstream archives extract to a directory named like the archive
        // minus ".tar.bz2" — verified against the benchmark run's layout.
        for variant in [SherpaOnnxModelVariant.omnilingual1B, .omnilingual300M] {
            let archiveName = variant.archiveURL.lastPathComponent
            #expect(archiveName == variant.extractedDirectoryName + ".tar.bz2")
        }
    }
}

// MARK: - Engine behavior (Apple platforms; needs no model files, no network)

#if canImport(SherpaOnnx)
@Suite struct SherpaOnnxEngineTests {

    /// A fresh empty install root — availability/prepare paths only, so no
    /// download and no recognizer construction ever happens here.
    private static func makeEngine(variant: SherpaOnnxModelVariant = .omnilingual1B) -> SherpaOnnxEngine {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SherpaOnnxEngineTests-\(UUID().uuidString)", isDirectory: true)
        return SherpaOnnxEngine(variant: variant, rootDirectory: root, autoDownload: false)
    }

    @Test func burmeseNeedsDownloadOnAFreshInstall() async {
        let engine = Self.makeEngine()
        let availability = await engine.availability(for: .burmese)
        #expect(availability == .needsDownload(bytes: SherpaOnnxModelVariant.omnilingual1B.archiveBytes))
    }

    @Test func nonBurmeseLanguagesAreUnsupported() async {
        // EN/ZH belong to the primary engine; this engine must not offer
        // itself for them (see availability(for:) in the adapter).
        let engine = Self.makeEngine()
        #expect(await engine.availability(for: .english).isUsable == false)
        #expect(await engine.availability(for: .chinese).isUsable == false)
    }

    @Test func prepareWithoutModelAndWithoutAutoDownloadThrows() async {
        let engine = Self.makeEngine()
        await #expect(throws: TranscriptionError.modelNotInstalled) {
            try await engine.prepare(languageMode: .pinned(.burmese))
        }
    }

    @Test func modelIsNotLoadedBeforePrepare() async {
        let engine = Self.makeEngine()
        #expect(await engine.isModelLoaded == false)
    }

    @Test func idAndDisplayNameAreStable() {
        let engine = Self.makeEngine()
        #expect(engine.id == "sherpa-onnx")
        #expect(engine.displayName == "Omnilingual ASR CTC 1B (int8)")
    }
}
#endif
