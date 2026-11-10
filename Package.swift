// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TaskDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TaskDeck", path: "Sources/TaskDeck")
    ]
)
