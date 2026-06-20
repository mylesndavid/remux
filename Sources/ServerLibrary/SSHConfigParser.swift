import Foundation

/// Parses an OpenSSH client config (`~/.ssh/config`) into `SavedServer` entries
/// for the Server Library "Import" action.
///
/// Each concrete (non-wildcard) `Host` alias becomes one `SavedServer` whose
/// `sshConfigAlias` is the alias — so connecting uses the bare alias and lets
/// OpenSSH resolve everything from the config ("connect by nickname"). The
/// block's `HostName`/`User`/`Port`/`IdentityFile` are captured too, for display.
///
/// Scope (deliberately bounded): handles `Host`, `HostName`, `User`, `Port`,
/// `IdentityFile`, and `Include` (with `~` expansion and simple `*`/`?` globbing
/// of the included path). `Match` blocks, token expansion (`%h`, `%p`), and
/// negated patterns are not interpreted — `Match` blocks and wildcard `Host`
/// patterns are skipped rather than misimported.
public enum SSHConfigParser {
    /// The default user SSH config location.
    public static var defaultConfigURL: URL {
        URL(fileURLWithPath: (NSString(string: "~/.ssh/config").expandingTildeInPath))
    }

    /// Parses the config at `url` (default: `~/.ssh/config`) into saved servers.
    /// Returns an empty array if the file is missing or unreadable.
    public static func parse(configURL url: URL? = nil) -> [SavedServer] {
        let root = url ?? defaultConfigURL
        var visited = Set<String>()
        var servers: [SavedServer] = []
        var seenAliases = Set<String>()
        parseFile(at: root, visited: &visited, servers: &servers, seenAliases: &seenAliases)
        return servers
    }

    // MARK: - Internals

    private struct Block {
        var aliases: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
    }

    private static func parseFile(
        at url: URL,
        visited: inout Set<String>,
        servers: inout [SavedServer],
        seenAliases: inout Set<String>,
        depth: Int = 0
    ) {
        guard depth < 16 else { return } // guard against pathological Include cycles
        let standardized = url.standardizedFileURL.path
        guard !visited.contains(standardized) else { return }
        visited.insert(standardized)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        var current: Block?

        func flush(_ block: Block?) {
            guard let block else { return }
            for alias in block.aliases {
                let key = alias.lowercased()
                guard !seenAliases.contains(key) else { continue }
                seenAliases.insert(key)
                servers.append(
                    SavedServer(
                        nickname: alias,
                        host: block.hostName ?? alias,
                        username: block.user,
                        port: block.port,
                        identityFile: block.identityFile,
                        sshConfigAlias: alias,
                        group: "SSH Config"
                    )
                )
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, value) = splitKeyValue(line)
            guard let keyword else { continue }
            let lowerKey = keyword.lowercased()

            switch lowerKey {
            case "host":
                flush(current)
                let tokens = tokenize(value)
                let concrete = tokens.filter { !isWildcard($0) }
                current = concrete.isEmpty ? Block() : Block(aliases: concrete)

            case "match":
                // Match blocks are not interpreted; end any current host block.
                flush(current)
                current = nil

            case "hostname":
                current?.hostName = value.isEmpty ? nil : value

            case "user":
                current?.user = value.isEmpty ? nil : value

            case "port":
                if let p = Int(value) { current?.port = p }

            case "identityfile":
                let expanded = NSString(string: stripQuotes(value)).expandingTildeInPath
                current?.identityFile = expanded.isEmpty ? nil : expanded

            case "include":
                // Includes apply at the point they appear; flush the current block
                // first so its directives are not leaked into included files.
                flush(current)
                current = nil
                for included in resolveIncludePaths(value, relativeTo: url) {
                    parseFile(at: included, visited: &visited, servers: &servers, seenAliases: &seenAliases, depth: depth + 1)
                }

            default:
                continue
            }
        }
        flush(current)
    }

    /// Splits a config line into keyword + value, supporting both `Key value`
    /// and `Key=value` forms.
    private static func splitKeyValue(_ line: String) -> (String?, String) {
        if let eq = line.firstIndex(of: "="),
           line[line.startIndex..<eq].rangeOfCharacter(from: .whitespaces) == nil {
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return (key.isEmpty ? nil : key, value)
        }
        guard let sep = line.rangeOfCharacter(from: .whitespaces) else {
            return (line.isEmpty ? nil : line, "")
        }
        let key = String(line[line.startIndex..<sep.lowerBound])
        let value = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key.isEmpty ? nil : key, value)
    }

    private static func tokenize(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { stripQuotes(String($0)) }
    }

    private static func stripQuotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func isWildcard(_ token: String) -> Bool {
        token.contains("*") || token.contains("?") || token.hasPrefix("!")
    }

    /// Resolves `Include` argument(s) into concrete file URLs. Relative paths are
    /// resolved against `~/.ssh`; supports a single `*`/`?` glob in the final path
    /// component (the common `Include config.d/*` case).
    private static func resolveIncludePaths(_ value: String, relativeTo parent: URL) -> [URL] {
        let sshDir = URL(fileURLWithPath: (NSString(string: "~/.ssh").expandingTildeInPath), isDirectory: true)
        var results: [URL] = []
        for token in tokenize(value) {
            let expanded = NSString(string: token).expandingTildeInPath
            let base: URL = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : sshDir.appendingPathComponent(expanded)

            let lastComponent = base.lastPathComponent
            if lastComponent.contains("*") || lastComponent.contains("?") {
                let dir = base.deletingLastPathComponent()
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                let regex = globToRegex(lastComponent)
                for name in entries.sorted() where name.range(of: regex, options: [.regularExpression]) != nil {
                    results.append(dir.appendingPathComponent(name))
                }
            } else {
                results.append(base)
            }
        }
        return results
    }

    private static func globToRegex(_ glob: String) -> String {
        var out = "^"
        for ch in glob {
            switch ch {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                out += "\\" + String(ch)
            default: out += String(ch)
            }
        }
        out += "$"
        return out
    }
}
