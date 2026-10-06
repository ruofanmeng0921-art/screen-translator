import AppKit
import Translation

enum TextVocabulary {
    static let interfaceTranslations: [String: String] = [
        "settings": "设置", "plugins": "插件", "skills": "技能", "extensions": "扩展",
        "connectors": "连接器", "permissions": "权限", "privacy": "隐私", "general": "通用",
        "help": "帮助", "search": "搜索", "recents": "最近", "tasks": "任务", "threads": "对话",
        "new task": "新任务", "new chat": "新对话", "new conversation": "新对话",
        "models": "模型", "model": "模型", "reasoning": "推理", "language": "语言",
        "languages": "语言", "memory": "记忆", "worktrees": "工作树", "agents": "智能体",
        "save": "保存", "save changes": "保存更改", "cancel": "取消", "done": "完成",
        "apply": "应用", "edit": "编辑", "delete": "删除", "remove": "移除",
        "open": "打开", "close": "关闭", "share": "共享", "continue": "继续", "retry": "重试",
        "install": "安装", "uninstall": "卸载", "update": "更新", "enable": "启用", "disable": "停用",
        "back": "返回", "next": "下一步", "advanced": "高级", "local": "本地", "remote": "远程",
        "on": "开启", "off": "关闭", "ok": "确定", "yes": "是", "no": "否"
    ]
    static let brands = ["Codex", "ChatGPT", "OpenAI", "GitHub", "GitLab", "MCP", "API", "OAuth",
                         "macOS", "iOS", "SwiftUI", "TypeScript", "JavaScript", "Python", "Node.js"]
    static let recognitionWords = brands + interfaceTranslations.keys.map { $0.capitalized } + ["GPT", "JSON", "YAML"]
    private static let nameExpressions: [(String, NSRegularExpression)] = brands.map { name in
        let glyphs = name.map { character -> String in
            switch character {
            case "I", "i", "l", "L": return "[IiLl1|]"
            case "O", "o": return "[Oo0]"
            default: return NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
        return (name, try! NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}_])" + glyphs + "(?![\\p{L}\\p{N}_])"))
    }
    private static let protectedExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])(?:GPT(?:[- ]?\d+(?:\.\d+)*(?:-[a-z0-9]+)*)?|Codex|ChatGPT|OpenAI|GitHub|GitLab|MCP|API|OAuth|macOS|iOS|SwiftUI|TypeScript|JavaScript|Python|Node\.js)(?![\p{L}\p{N}_])"#)
    private static let technicalExpression = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_])(?:RAG|LoRA|QLoRA|VAE|CLIP|KV cache|LLM|MCP|API|HTTP|HTTPS|SSH|TCP|UDP|DNS|URL|URI|JSON|YAML|XML|SQL|GPU|CPU|RAM|SSD|CUDA|ONNX|FAISS|PyTorch|TensorFlow|NumPy|ScreenCaptureKit|AppKit|[A-Za-z]+_[A-Za-z0-9_]+|[a-zA-Z]+[a-z][A-Z][a-zA-Z0-9]*)(?![\p{L}\p{N}_])"#)
    private static let wordExpression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])[A-Za-z]+(?:['’][A-Za-z]+)?(?![\p{L}\p{N}_])"#)
    @MainActor private static var dictionaryCache = [String: Bool]()

    static func comparisonKey(_ text: String) -> String {
        canonicalNames(text).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func canonicalNames(_ text: String) -> String {
        // Only restore known proper names with equal-length, visually ambiguous
        // I/l/1 and O/0 glyphs. Do not spell-correct ordinary words or model numbers.
        var result = text
        for (name, expression) in nameExpressions {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: name) }
            }
        }
        return result
    }

    static func labelKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":. …"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func interfaceTranslation(_ text: String) -> String? {
        guard let value = interfaceTranslations[labelKey(text)] else { return nil }
        return value + (text.hasSuffix("…") || text.hasSuffix("...") ? "…" : "")
    }

    static func protectedRanges(_ text: String) -> [Range<String.Index>] {
        let range = NSRange(text.startIndex..., in: text)
        return mergedRanges(protectedExpression.matches(in: text, range: range).map(\.range) +
                            technicalExpression.matches(in: text, range: range).map(\.range), in: text)
    }

    private static func mergedRanges(_ ranges: [NSRange], in text: String) -> [Range<String.Index>] {
        var merged = [NSRange]()
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { merged.append(range) }
        }
        return merged.compactMap { Range($0, in: text) }
    }

    @MainActor static func translationRanges(_ text: String) -> [Range<String.Index>] {
        let protected = protectedRanges(text)
        var ranges = protected.map { NSRange($0, in: text) }
        let checker = NSSpellChecker.shared
        guard let language = checker.availableLanguages.first(where: { $0.hasPrefix("en") }) else { return protected }
        for match in wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), !protected.contains(where: { $0.overlaps(range) }) else { continue }
            let word = String(text[range])
            guard word.count >= 3 else { continue }
            let key = word.lowercased()
            let unknown: Bool
            if let cached = dictionaryCache[key] { unknown = cached }
            else {
                unknown = checker.checkSpelling(of: key, startingAt: 0, language: language, wrap: false,
                                               inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
                if dictionaryCache.count > 2500 { dictionaryCache.removeAll(keepingCapacity: true) }
                dictionaryCache[key] = unknown
            }
            // Unfamiliar words may be specialist vocabulary or an OCR mistake.
            // In either case, preserve the original spelling rather than guess.
            if unknown { ranges.append(match.range) }
        }
        return mergedRanges(ranges, in: text)
    }

    @MainActor static func shouldPreserveEntireLine(_ text: String) -> Bool {
        guard interfaceTranslation(text) == nil else { return false }
        let ranges = translationRanges(text)
        guard !ranges.isEmpty else { return false }
        var remaining = text
        for range in ranges.reversed() { remaining.removeSubrange(range) }
        return !remaining.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
    }

    @MainActor static func safeTranslation(_ translated: String, for source: String) -> String {
        guard translated.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return source }
        for range in translationRanges(source) where !translated.contains(String(source[range])) { return source }
        return translated
    }

    static func isProtectedLabel(_ text: String) -> Bool {
        let ranges = protectedRanges(text)
        guard !ranges.isEmpty else { return false }
        var remaining = text
        for range in ranges.reversed() { remaining.removeSubrange(range) }
        return !remaining.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
    }

    static func isNonLanguage(_ text: String) -> Bool {
        // Versions, transfer rates, shortcuts, paths, and code identifiers are
        // screen data, rather than prose. Keep them readable in their original form.
        if text.contains("://") || text.hasPrefix("/") || text.hasPrefix("~/") { return true }
        if text.contains(where: { "⌘⌥⇧⌃".contains($0) }) { return true }
        let patterns = [
            #"(?i)^\s*[\d.,]+\s*(?:[KMGT]?B(?:/s|/sec)?|[KMGT]?bit/s|Hz|MHz|GHz|ms|px|fps|%)\s*$"#,
            #"(?i)^\S+\.(?:swift|py|tsx?|jsx?|json|ya?ml|md|csv|html|css|sh|plist|png|jpe?g|pdf|app)\s*$"#,
            #"(?i)^(?:ctrl|alt|cmd|command|option|shift|fn)(?:\s*[+ ]\s*\S+)+$"#,
            #"^(?:[a-z]+[A-Z][a-zA-Z0-9]*|[a-zA-Z]+_[a-zA-Z0-9_]+)\s*\([^)]*\)\s*;?$"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    @MainActor static func request(_ text: String) -> TranslationSession.Request {
        if #available(macOS 26.4, *) {
            var attributed = AttributedString()
            var cursor = text.startIndex
            for range in translationRanges(text) {
                attributed += AttributedString(text[cursor..<range.lowerBound])
                var term = AttributedString(text[range])
                term.translation.skipsTranslation = true
                attributed += term
                cursor = range.upperBound
            }
            attributed += AttributedString(text[cursor...])
            return TranslationSession.Request(sourceText: attributed, clientIdentifier: text)
        }
        return TranslationSession.Request(sourceText: text, clientIdentifier: text)
    }
}
