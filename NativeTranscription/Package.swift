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
    .executableTarget(
      name: "MeetingTranscriber",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
  ]
)
