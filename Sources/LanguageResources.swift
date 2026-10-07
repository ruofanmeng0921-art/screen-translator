import Foundation
import Combine
import Translation

struct TranslationPair {
    let source: Locale.Language
    let target: Locale.Language
}

enum LanguageReadiness: Equatable { case ready, missing, unsupported }

@MainActor
enum LanguageResources {
    private static var cachedPair: TranslationPair?

    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    static func pair() async -> TranslationPair {
        if let cachedPair { return cachedPair }
        let supported = await availability().supportedLanguages
        let source = supported.first { $0.languageCode?.identifier == "en" && $0.maximalIdentifier.hasSuffix("-US") }
            ?? supported.first { $0.languageCode?.identifier == "en" }
            ?? Locale.Language(identifier: "en-US")
        let target = supported.first { $0.maximalIdentifier.hasPrefix("zh-Hans") }
            ?? Locale.Language(identifier: "zh-Hans")
        let resolved = TranslationPair(source: source, target: target)
        cachedPair = resolved
        return resolved
    }

    static func configuration(_ pair: TranslationPair) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return .init(source: pair.source, target: pair.target, preferredStrategy: .lowLatency)
        }
        return .init(source: pair.source, target: pair.target)
    }

    static func installedSession(_ pair: TranslationPair) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return .init(installedSource: pair.source, target: pair.target, preferredStrategy: .lowLatency)
        }
        return .init(installedSource: pair.source, target: pair.target)
    }

    static func readiness(_ session: TranslationSession, pair: TranslationPair) async throws -> LanguageReadiness {
        // This session cannot request downloads. Checking it never opens a
        // language permission sheet or mistakes an accepted download for ready.
        do {
            _ = try await session.translate("Hello")
            return .ready
        } catch {
            if TranslationError.notInstalled ~= error {
                let status = await availability().status(from: pair.source, to: pair.target)
                return status == .unsupported ? .unsupported : .missing
            }
            if TranslationError.unsupportedSourceLanguage ~= error ||
                TranslationError.unsupportedTargetLanguage ~= error ||
                TranslationError.unsupportedLanguagePairing ~= error { return .unsupported }
            throw error
        }
    }
}

@MainActor
final class LanguageSetupModel: ObservableObject {
    enum Phase: Equatable { case checking, missing, downloading, ready, failed(String) }
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published var resumeWhenReady = false
    private var pair: TranslationPair?
    private var operation = UUID()
    private var lastConfiguration: TranslationSession.Configuration?
    private var probe: TranslationSession?
    private let checker: (TranslationSession, TranslationPair) async throws -> LanguageReadiness
    var downloadRequestID: UUID? { configuration == nil ? nil : operation }

    init(checker: @escaping (TranslationSession, TranslationPair) async throws -> LanguageReadiness = {
        try await LanguageResources.readiness($0, pair: $1)
    }) { self.checker = checker }

    var message: String {
        switch phase {
        case .checking: return "正在检查已安装的英语和简体中文语言包…"
        case .missing: return "英语或简体中文语言包尚未就绪。只需要在这台 Mac 上下载一次。"
        case .downloading: return "正在准备语言包，安装完成并验证通过后会自动继续。可以取消或关闭窗口，稍后再检查。"
        case .ready: return "英语和简体中文语言包已就绪，不需要再次下载。"
        case .failed(let message): return message
        }
    }

    func check() async {
        cancel()
        phase = .checking
        let token = operation
        let pair = await LanguageResources.pair()
        guard operation == token, !Task.isCancelled else { return }
        self.pair = pair
        do {
            let result = try await checkResources(pair, token: token)
            guard operation == token, !Task.isCancelled else { return }
            apply(result)
        } catch {
            guard operation == token, !Task.isCancelled else { return }
            phase = .failed("语言包检查暂时失败，请重新检查。\n\(error.localizedDescription)")
        }
    }

    func download() {
        guard phase == .missing, let pair else { return }
        operation = UUID()
        phase = .downloading
        var next = lastConfiguration ?? LanguageResources.configuration(pair)
        next.invalidate()
        lastConfiguration = next
        configuration = next
    }

    func finishDownload(using session: TranslationSession, requestID: UUID) async {
        guard operation == requestID, phase == .downloading, let pair else { return }
        let token = requestID
        do {
            try await session.prepareTranslation()
            guard operation == token, !Task.isCancelled else { return }
            while operation == token, !Task.isCancelled {
                let result = try await checkResources(pair, token: token)
                guard operation == token, !Task.isCancelled else { return }
                if result != .missing {
                    apply(result)
                    configuration = nil
                    return
                }
                // prepareTranslation can return while a shared download is
                // still in progress. Poll a non-download session, without
                // presenting another system sheet or claiming success early.
                try await Task.sleep(for: .milliseconds(700))
            }
        } catch {
            guard operation == token, !Task.isCancelled else { return }
            configuration = nil
            phase = .failed("语言包尚未准备完成，请检查网络后重新检查。\n\(error.localizedDescription)")
        }
    }

    func cancel() {
        operation = UUID()
        probe?.cancel()
        probe = nil
        configuration = nil
        phase = .missing
    }

    private func apply(_ result: LanguageReadiness) {
        switch result {
        case .ready: phase = .ready
        case .missing: phase = .missing
        case .unsupported: phase = .failed("这台 Mac 的系统翻译暂不支持英文到简体中文，请确认系统版本。")
        }
    }

    private func checkResources(_ pair: TranslationPair, token: UUID) async throws -> LanguageReadiness {
        let session = LanguageResources.installedSession(pair)
        probe = session
        defer { session.cancel(); if operation == token { probe = nil } }
        return try await checker(session, pair)
    }
}
