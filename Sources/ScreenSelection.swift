import AppKit
import ScreenCaptureKit

// A user-selected display is authorized by the macOS picker. This does not
// enumerate unapproved screens or alter the system's stored TCC records.
@MainActor
final class ScreenSelection: NSObject, SCContentSharingPickerObserver {
    static let shared = ScreenSelection()
    private let picker = SCContentSharingPicker.shared
    private var pending: CheckedContinuation<SCContentFilter, Error>?
    private var filter: SCContentFilter?
    private var registered = false

    func select() async throws -> SCContentFilter {
        if let filter { return filter }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = continuation
                if !registered {
                    picker.add(self)
                    registered = true
                }
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = .singleDisplay
                configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier!]
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.maximumStreamCount = 1
                picker.isActive = true
                NSApp.activate(ignoringOtherApps: true)
                picker.present(using: .display)
            }
        } onCancel: {
            Task { @MainActor in self.cancelPending() }
        }
    }

    func reset() {
        filter = nil
        cancelPending()
    }

    func shutdown() {
        reset()
        if registered { picker.remove(self); registered = false }
        picker.isActive = false
    }

    private func cancelPending() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard let continuation = self.pending else { return }
            self.pending = nil
            self.filter = filter
            continuation.resume(returning: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancelPending() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            let continuation = self.pending
            self.pending = nil
            continuation?.resume(throwing: error)
        }
    }
}
