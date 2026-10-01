import Foundation

#if canImport(Sentry)
import Sentry

/// Opt-in per build configuration. Missing configuration never delays app startup.
enum CrashReporting {
    static let sdkAvailable = true
    static func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SignalWordCrashReportingEnabled") as? String == "YES",
              let dsn = Bundle.main.object(forInfoDictionaryKey: "SignalWordSentryDSN") as? String,
              let components = URLComponents(string: dsn), components.scheme == "https",
              components.host?.range(of: "^o[0-9]+\\.ingest(?:\\.(?:us|de))?\\.sentry\\.io$", options: .regularExpression) != nil,
              components.user != nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.sendClientReports = false
            options.enableMemoryIntrospection = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.maxBreadcrumbs = 0
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableSwizzling = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            // Sentry exposes UIKit interaction tracing only on UIKit platforms.
            // The macOS serializer test still exercises the same privacy filter.
            #if canImport(UIKit)
            options.enableUserInteractionTracing = false
            #endif
            options.enableAutoSessionTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableAppHangTracking = false
            options.enableMetricKit = false
            options.enableMetrics = false
            options.enableLogs = false
            #if canImport(UIKit)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif
            options.beforeBreadcrumb = { _ in nil }
            options.beforeSend = sanitized
        }
    }

    /// Construct a new event rather than trying to remove every possible private field.
    /// Native addresses remain useful for crash grouping; messages, registers,
    /// breadcrumbs, request data, contexts and memory values are not copied.
    static func sanitized(_ original: Event) -> Event? {
        let safe = Event(level: original.level)
        safe.timestamp = original.timestamp
        safe.releaseName = original.releaseName.flatMap { value in
            value.range(of: "^[A-Za-z0-9.-]+@[0-9.]+\\+[0-9]+$", options: .regularExpression) != nil ? value : nil
        }
        safe.dist = original.dist.flatMap { Int($0) != nil ? $0 : nil }
        safe.debugMeta = original.debugMeta?.compactMap { image in
            guard let id = image.debugID, UUID(uuidString: id) != nil,
                  let imageAddress = address(image.imageAddress) else { return nil }
            let clean = DebugMeta()
            clean.type = "macho"
            clean.debugID = id
            clean.imageAddress = imageAddress
            clean.imageVmAddress = address(image.imageVmAddress)
            clean.imageSize = image.imageSize
            // Image UUIDs allow symbolication without copying local file paths.
            return clean
        }
        safe.environment = "invited-pilot"
        safe.exceptions = original.exceptions?.map { exception in
            let result = Exception(value: "Application failure", type: "SignalWordFailure")
            if let stack = exception.stacktrace {
                result.stacktrace = sanitizedStack(stack)
            }
            return result
        }
        safe.threads = original.threads?.filter { $0.crashed == true } .map { thread in
            let clean = SentryThread(threadId: thread.threadId)
            clean.crashed = true
            clean.stacktrace = thread.stacktrace.map(sanitizedStack)
            return clean
        }
        return safe
    }

    private static func sanitizedStack(_ stack: SentryStacktrace) -> SentryStacktrace {
        SentryStacktrace(frames: stack.frames.map { frame in
            let clean = Frame()
            clean.instructionAddress = address(frame.instructionAddress)
            clean.imageAddress = address(frame.imageAddress)
            clean.symbolAddress = address(frame.symbolAddress)
            clean.inApp = frame.inApp
            return clean
        }, registers: [:])
    }

    private static func address(_ value: String?) -> String? {
        guard let value, value.range(of: "^0x[0-9a-fA-F]{1,16}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

#else
/// A missing optional SDK cannot prevent authentication, alerts, or recovery.
enum CrashReporting {
    static let sdkAvailable = false
    static func start() {}
}
#endif
