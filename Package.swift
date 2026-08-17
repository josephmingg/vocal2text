// swift-tools-version: 6.0
// DictationCore — the shared engine behind Vocal (macOS + iOS offline dictation).
// Pure-logic targets build and test on Linux; Apple-only targets are guarded so
// `swift test` stays green everywhere and CI's macOS job exercises the full graph.
import PackageDescription

// sherpa-onnx (the Burmese engine runtime, docs/04 §1) ships Apple-only
// binary xcframeworks. The dependency is host-conditioned rather than
// platform-conditioned: on a Linux host SwiftPM would still have to resolve
// the package and its pinned binary artifacts even though no target here
// could ever build them, so the manifest simply doesn't declare it there.
// Darwin hosts (swift test on macOS CI, Xcode for both apps) get the real
// dependency; ASREngineSherpaOnnx compiles to a stub everywhere else, the
// same shape as the WhisperKit guard.
//
// Pinned exact: the adapter is written against the v1.13.5 Swift shim and
// that tag's checksummed xcframeworks. Bump deliberately, re-reading the
// shim's signatures, not via automatic minor updates.
#if canImport(Darwin)
let sherpaOnnxDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.5")
]
let sherpaOnnxProducts: [Target.Dependency] = [
    .product(name: "sherpa-onnx", package: "sherpa-onnx", condition: .when(platforms: [.macOS, .iOS]))
]
#else
let sherpaOnnxDependencies: [Package.Dependency] = []
let sherpaOnnxProducts: [Target.Dependency] = []
#endif

let package = Package(
    name: "DictationCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "TextPipeline", targets: ["TextPipeline"]),
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        .library(name: "ProfileKit", targets: ["ProfileKit"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .library(name: "ASRKit", targets: ["ASRKit"]),
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "BridgeKit", targets: ["BridgeKit"]),
        .library(name: "AudioPipeline", targets: ["AudioPipeline"]),
        .library(name: "PersistenceKit", targets: ["PersistenceKit"]),
        .library(name: "ASREngineWhisperKit", targets: ["ASREngineWhisperKit"]),
        .library(name: "ASREngineAppleSpeech", targets: ["ASREngineAppleSpeech"]),
        .library(name: "ASREngineSherpaOnnx", targets: ["ASREngineSherpaOnnx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
    ] + sherpaOnnxDependencies,
    targets: [
        // ── Pure targets (Linux + Apple) ────────────────────────────────
        .target(name: "CoreModels"),
        .target(name: "TextPipeline", dependencies: ["CoreModels"]),
        .target(
            name: "CleanupKit",
            dependencies: ["CoreModels"],
            resources: [.copy("Resources/Prompts")]
        ),
        .target(name: "ProfileKit", dependencies: ["CoreModels"]),
        .target(name: "ModelStore", dependencies: ["CoreModels"]),
        .target(name: "ASRKit", dependencies: ["CoreModels"]),
        .target(
            name: "SessionKit",
            dependencies: ["CoreModels", "TextPipeline", "CleanupKit", "ProfileKit", "ASRKit"]
        ),
        // The App Group contract between the iOS app and its extensions
        // (docs/02 §3.1). Deliberately depends on CoreModels only: the
        // keyboard extension links it under a ~48–80 MB jetsam ceiling, so it
        // must never pull in GRDB, WhisperKit, or AVFoundation.
        .target(name: "BridgeKit", dependencies: ["CoreModels"]),

        // ── Apple-only targets (sources compile to stubs elsewhere) ────
        .target(name: "AudioPipeline", dependencies: ["CoreModels", "ASRKit"]),
        .target(
            name: "PersistenceKit",
            dependencies: [
                "CoreModels",
                .product(name: "GRDB", package: "GRDB.swift", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
        .target(
            name: "ASREngineWhisperKit",
            dependencies: [
                "CoreModels", "ASRKit",
                .product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
        .target(name: "ASREngineAppleSpeech", dependencies: ["CoreModels", "ASRKit"]),
        // Burmese engine (docs/04 §1, docs/11 G13): Omnilingual ASR CTC via
        // sherpa-onnx. ModelStore supplies the archive download machinery.
        .target(
            name: "ASREngineSherpaOnnx",
            dependencies: ["CoreModels", "ASRKit", "ModelStore"] + sherpaOnnxProducts
        ),

        // ── Tests ───────────────────────────────────────────────────────
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(
            name: "TextPipelineTests",
            dependencies: ["TextPipeline"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CleanupKitTests",
            dependencies: ["CleanupKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit"]),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore"]),
        .testTarget(name: "ASRKitTests", dependencies: ["ASRKit"]),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "ASRKit"]),
        .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"]),
        .testTarget(
            name: "PersistenceKitTests",
            dependencies: [
                "PersistenceKit",
                // Direct GRDB access lets a test forge a row this build cannot
                // decode, proving list queries survive it.
                .product(name: "GRDB", package: "GRDB.swift", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
        .testTarget(name: "AudioPipelineTests", dependencies: ["AudioPipeline"]),
        .testTarget(
            name: "ASREngineSherpaOnnxTests",
            dependencies: ["ASREngineSherpaOnnx", "ASRKit", "ModelStore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
