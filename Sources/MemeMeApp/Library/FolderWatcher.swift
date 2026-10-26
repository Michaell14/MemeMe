import Foundation

/// Watches one directory for added, removed or renamed entries (top level only).
///
/// Events arrive on the main queue; `onChange` fires once, 1 s after the first event of a burst,
/// so a large copy produces a handful of callbacks instead of hundreds.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let onChange: () -> Void
    /// Only touched on the main queue (the source's handler queue).
    private var pendingNotification: DispatchWorkItem?
    private var isCancelled = false

    private static let coalescingDelay: TimeInterval = 1.0

    /// DispatchSource file-system object (.write, .rename, .delete) on an O_EVTONLY descriptor;
    /// onChange delivered on the main queue, coalesced 1 s. nil when the folder can't be opened.
    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        self.onChange = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleNotification()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    deinit {
        pendingNotification?.cancel()
        if !isCancelled {
            source.cancel()
        }
    }

    /// Stops watching and closes the descriptor. Safe to call more than once.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pendingNotification?.cancel()
        pendingNotification = nil
        source.cancel()
    }

    private func scheduleNotification() {
        guard !isCancelled, pendingNotification == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingNotification = nil
            guard !self.isCancelled else { return }
            self.onChange()
        }
        pendingNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FolderWatcher.coalescingDelay, execute: work)
    }
}
