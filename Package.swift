// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MeetingNotesCore", targets: ["MeetingNotesCore"]),
        .executable(name: "MeetingNotesApp", targets: ["MeetingNotesApp"]),
        .executable(name: "meeting-notes-cli", targets: ["meeting-notes-cli"]),
    ],
    dependencies: [
        // Pinned exactly: FluidAudio is pre-1.0 and its diarizer API still drifts.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        // Local notes generation. mlx-swift-lm carries the model implementations;
        // the two Hugging Face packages supply the downloader and tokenizer it
        // adapts to its own protocols.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MeetingNotesCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "MeetingNotesApp",
            dependencies: ["MeetingNotesCore"]
        ),
        .executableTarget(
            name: "meeting-notes-cli",
            dependencies: ["MeetingNotesCore"]
        ),
        .testTarget(
            name: "MeetingNotesCoreTests",
            dependencies: ["MeetingNotesCore"]
        ),
    ]
)
