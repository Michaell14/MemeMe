import Foundation
import Network

/// Cheap, thread-safe answers to "should background work wait?" and "is this network metered?".
enum SystemConditions {
    private static let lock = NSLock()
    /// Guarded by `lock`.
    private static var expensivePath = false
    /// Guarded by `lock`. Created once by `startMonitoring()`.
    private static var pathMonitor: NWPathMonitor?
    private static let monitorQueue = DispatchQueue(label: "com.mememe.network-monitor", qos: .utility)

    /// Low Power Mode or thermal state ≥ .serious.
    static var shouldDeferBackgroundWork: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }

    /// From a shared NWPathMonitor (isExpensive || isConstrained); false until the first path update.
    static var isOnExpensiveNetwork: Bool {
        lock.lock()
        let value = expensivePath
        lock.unlock()
        return value
    }

    /// Idempotent.
    static func startMonitoring() {
        lock.lock()
        if pathMonitor != nil {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        lock.unlock()

        monitor.pathUpdateHandler = { path in
            SystemConditions.setExpensive(path.isExpensive || path.isConstrained)
        }
        monitor.start(queue: monitorQueue)
    }

    private static func setExpensive(_ value: Bool) {
        lock.lock()
        expensivePath = value
        lock.unlock()
    }
}
