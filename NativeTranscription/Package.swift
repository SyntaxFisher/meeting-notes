// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MeetingTranscriber",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      exact: "0.17.1")
  ],
  targets: [
    // whisper.cpp v1.9.5 (release b5454 is the same commit), built with Metal.
    .binaryTarget(
      name: "whisper",
      url:
        "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
      checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
    .executableTarget(
      name: "MeetingTranscriber",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "whisper"],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
  ]
)
