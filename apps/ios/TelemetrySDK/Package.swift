// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The baseline remains buildable when the external SDK artifact is unavailable.
// Enabling reporting requires a separate build that compiles and tests the SDK.
let includeSDK = ProcessInfo.processInfo.environment["SIGNALWORD_WITH_SENTRY"] == "1"
var targets: [Target] = [.target(name: "LinkRuntime", linkerSettings: [.linkedLibrary("c++")])]
if includeSDK {
    targets.append(.binaryTarget(name: "Sentry", url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.29.0/Sentry.xcframework.zip", checksum: "63fe5a7258097fded9ef485bbb1d8e80e1e91d419ee6d8a6ad405454b5b50fef"))
}
let package = Package(name: "TelemetrySDK", platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "SignalWordSentry", targets: includeSDK ? ["Sentry", "LinkRuntime"] : ["LinkRuntime"])], targets: targets)
