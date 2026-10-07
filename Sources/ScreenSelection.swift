import AppKit
import ScreenCaptureKit

// A user-selected display is authorized by the macOS picker. This does not
// enumerate unapproved screens or alter the system's stored TCC records.
@MainActor
final class ScreenSelection: NSObject, SCContentSharingPickerObserver {
    static let shared = ScreenSelection()
    private let picker = SCContentSharingPicker.shared
    private struct PendingSelection {
        let id: UUID
        let continuation: CheckedContinuation<SCContentFilter, Error>
    }
    private var pending: PendingSelection?
    private var filter: SCContentFilter?
    private var registered = false

    func select() async throws -> SCContentFilter {
        if let filter { return filter }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancelSelection()
                pending = PendingSelection(id: requestID, continuation: continuation)
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
            Task { @MainActor in self.cancelSelection(requestID: requestID) }
        }
    }

    func reset() {
        filter = nil
        cancelSelection()
    }

    func shutdown() {
        reset()
        if registered { picker.remove(self); registered = false }
        picker.isActive = false
    }

    func cancelSelection() { cancelSelection(requestID: nil) }

    private func cancelSelection(requestID: UUID?) {
        guard let pending, requestID == nil || pending.id == requestID else { return }
        let continuation = pending.continuation
        self.pending = nil
        picker.isActive = false
        continuation.resume(throwing: CancellationError())
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard let pending = self.pending else { return }
            self.pending = nil
            self.filter = filter
            pending.continuation.resume(returning: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancelSelection() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            let continuation = self.pending?.continuation
            self.pending = nil
            picker.isActive = false
            continuation?.resume(throwing: error)
        }
    }
}
