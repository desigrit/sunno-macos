import Foundation

/// A bounded tail of the engine's failure output, for a bug report.
///
/// **An allow-list, not a filter**, which is the same decision the diagnostics export is
/// built on and taken for the same reason: this is text a user may hand to a stranger. Only
/// lines that look like a Python failure are kept, so an engine that one day decided to print
/// a caption could not leak one through here.
///
/// The Windows build excludes its engine log from diagnostics entirely, because filtering it
/// was designed three times and every round found a way through. Collecting nothing but
/// tracebacks in the first place is that lesson applied earlier, and it still leaves a
/// maintainer something to read.
///
/// Its own type rather than statics on `BackendHost`, which is `@MainActor`: this is written
/// from the pipe's reader queue and read from the main actor, and an isolated static would be
/// the wrong tool for a thing that is deliberately reachable from both.
final class EngineDiagnostics: @unchecked Sendable {

    static let shared = EngineDiagnostics()

    /// Bounded, because a crash loop would otherwise print until memory ran out.
    private let maxLines = 60
    private let lock = NSLock()
    private var lines: [String] = []

    private static let markers = [
        "[error]", "Traceback", "File \"", "ModuleNotFoundError", "ImportError",
        "OSError", "RuntimeError", "ValueError", "During handling of the above",
    ]

    /// Anything that looks like a filesystem path, reduced to almost nothing.
    ///
    /// The allow-list keeps a line, and the line may carry a path: `[error] could not start
    /// recording: [Errno 13] Permission denied: '/Users/someone/Custody case/Recordings'`,
    /// or a traceback frame naming the home directory.
    ///
    /// A maintainer reading a bug report needs to know *which source file* failed. They never
    /// need the directories above it, and those are where the disclosure lives — the account
    /// name, and whatever the user called the folder they record into. So a path ending in
    /// something file-shaped keeps only that name, and a path ending in a directory is
    /// replaced outright. `…/app.py` is useful; `…/Custody case` is somebody's life.
    /// Quoted paths first, because a Mac path very often contains a space and the unquoted
    /// pattern below has to stop at one. Python reports them quoted —
    /// `Permission denied: '/Users/someone/Custody case/Recordings'` — so the quotes are what
    /// makes the whole path recognisable as one thing.
    private static let quotedPathPattern = try? NSRegularExpression(
        pattern: "'(/[^']*)'|\"(/[^\"]*)\"")

    private static let pathPattern = try? NSRegularExpression(
        pattern: "/(?:[^/\\s\"',)]+/)+[^/\\s\"',)]*")

    private static func reduce(path: Substring) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return "<path>" }
        // A dot is the only cheap signal that this is a file rather than a folder, and the
        // failure mode is the safe one: a directory with a dot in its name is redacted less,
        // a file without an extension is redacted more.
        return last.contains(".") ? "…/\(last)" : "<path>"
    }

    /// Rewrite every match of `regex` through `transform`, left to right.
    private static func replacing(_ text: String, _ regex: NSRegularExpression,
                                  _ transform: (Substring) -> String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += transform(text[range])
            last = range.upperBound
        }
        result += text[last...]
        return result
    }

    /// Redacted in addition to paths, because the app is careful never to put a device name
    /// in a report: "Headset (R-Phonak hearing aid)" tells the reader that the user wears a
    /// hearing aid. PortAudio names the device in some of its errors, so the one string the
    /// app knows to be sensitive is removed by name.
    private var sensitive: [String] = []

    func redactDeviceName(_ name: String?) {
        guard let name, name.count > 3 else { return }
        lock.lock()
        if !sensitive.contains(name) { sensitive.append(name) }
        lock.unlock()
    }

    private func scrub(_ line: String, secrets: [String]) -> String {
        var out = line
        for secret in secrets {
            out = out.replacingOccurrences(of: secret, with: "<device>")
        }
        if let quoted = Self.quotedPathPattern {
            out = Self.replacing(out, quoted) { match in
                // Keep the quotes, so the sentence still reads as one.
                let quote = match.first.map(String.init) ?? "'"
                return quote + Self.reduce(path: match.dropFirst().dropLast()) + quote
            }
        }
        if let bare = Self.pathPattern {
            out = Self.replacing(out, bare) { Self.reduce(path: $0) }
        }
        return out
    }

    func note(_ chunk: String) {
        // One acquisition. `sensitive` is written from the main actor and read here on the
        // pipe's queue, so it has to be under the same lock as `lines`.
        lock.lock()
        let secrets = sensitive
        lock.unlock()

        var kept: [String] = []
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let looksLikeFailure = Self.markers.contains { trimmed.hasPrefix($0) }
                || trimmed.hasSuffix("Error")
            if looksLikeFailure {
                // Truncated first, so one enormous line cannot fill the buffer on its own.
                kept.append(scrub(String(raw.prefix(400)), secrets: secrets))
            }
        }
        guard !kept.isEmpty else { return }
        lock.lock()
        lines.append(contentsOf: kept)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    /// What the engine said before it died, or nil when it said nothing worth keeping.
    func collected() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Forgotten when an engine starts cleanly, so a failure reported later is this run's and
    /// not a leftover from the last one.
    func reset() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
