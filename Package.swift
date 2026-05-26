// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromiumBranches",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ChromiumBranches", targets: ["ChromiumBranches"]),
    ],
    targets: [
        .executableTarget(name: "ChromiumBranches"),
    ]
)
