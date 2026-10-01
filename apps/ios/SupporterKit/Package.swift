// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SupporterKit", platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "SupporterKit", targets: ["SupporterKit"])],
    dependencies: [.package(url: "https://github.com/RevenueCat/purchases-ios.git", exact: "5.91.0")],
    targets: [
        .target(name: "SupporterKit", dependencies: [.product(name: "RevenueCat", package: "purchases-ios")]),
        .testTarget(name: "SupporterKitTests", dependencies: ["SupporterKit"])
    ])
