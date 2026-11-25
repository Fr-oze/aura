import Foundation

enum HookTarget: String, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Fichier de configuration modifié, relatif au dossier personnel.
    var relativePath: String {
        switch self {
        case .claude: return ".claude/settings.json"
        case .codex: return ".codex/config.toml"
        case .cursor: return ".cursor/hooks.json"
        }
    }
}

enum InstallOutcome {
    case installed(backup: String?)
    /// Codex a déjà un `notify` qui n'est pas celui d'Aura : on le montre et on demande.
    case conflict(existing: String)
    case failed(String)
}

struct InstallerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Installe et retire les hooks d'Aura dans la configuration des agents.
/// Chaque écriture est précédée d'une sauvegarde horodatée du fichier (`.bak`).
/// Tout ce qu'Aura ajoute contient le chemin `/.aura/hook.sh` : c'est ce qui permet de ne retirer que ça.
enum HookInstaller {
    static let marker = "/.aura/hook.sh"
    /// Délai accordé par l'agent au hook de validation (secondes). Le délai d'Aura est plafonné à 300 s.
    static let approvalHookTimeout = 330
    private static let savedPrefix = "# aura-saved: "

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var auraDirectory: URL { home.appendingPathComponent(".aura", isDirectory: true) }
    static var scriptURL: URL { auraDirectory.appendingPathComponent("hook.sh") }
    static var configURL: URL { auraDirectory.appendingPathComponent("config.sh") }
    /// Commande `aura`, appelée par les agents pour poser une question dans l'encoche.
    static var commandURL: URL { auraDirectory.appendingPathComponent("bin/aura") }

    static func fileURL(for target: HookTarget) -> URL {
        home.appendingPathComponent(target.relativePath)
    }

    // MARK: État

    static func isInstalled(_ target: HookTarget) -> Bool {
        guard let text = try? String(contentsOf: fileURL(for: target), encoding: .utf8) else { return false }
        switch target {
        case .claude, .cursor:
            return text.contains(marker)
        case .codex:
            let lines = text.components(separatedBy: "\n")
            guard let range = codexNotifyRange(in: lines) else { return false }
            return lines[range].joined(separator: "\n").contains(marker)
        }
    }

    // MARK: Script et réglages partagés

    /// Copie hook.sh du bundle vers ~/.aura/ et écrit le port et le délai.
    static func installScript(port: Int, timeout: Double) throws {
        guard let bundled = Bundle.main.url(forResource: "hook", withExtension: "sh") else {
            throw InstallerError(message: "hook.sh est introuvable dans l'app. Reconstruis-la avec ./build.sh.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: auraDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: scriptURL.path) {
            try fm.removeItem(at: scriptURL)
        }
        try fm.copyItem(at: bundled, to: scriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try writeConfig(port: port, timeout: timeout)
    }

    /// Installe (ou met à jour) ~/.aura/bin/aura à chaque lancement. Indépendant des hooks :
    /// la commande marche même si aucun hook n'est installé.
    static func installCommand() {
        guard let bundled = Bundle.main.url(forResource: "aura", withExtension: nil) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pas de comparaison de contenu : le fichier est minuscule, on réécrit à chaque lancement.
        try? fm.removeItem(at: commandURL)
        guard (try? fm.copyItem(at: bundled, to: commandURL)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
    }

    /// Met à jour ~/.aura/config.sh (lu par hook.sh). Ne fait rien tant que les hooks ne sont pas installés.
    static func refreshConfigIfInstalled(port: Int, timeout: Double) {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            // La commande `aura` lit aussi le port : on garde config.sh à jour même sans hooks.
            try? FileManager.default.createDirectory(at: auraDirectory, withIntermediateDirectories: true)
            try? writeConfig(port: port, timeout: timeout)
            return
        }
        try? writeConfig(port: port, timeout: timeout)
    }

    private static func writeConfig(port: Int, timeout: Double) throws {
        let wait = Int(timeout.rounded()) + 10
        let text = "# Écrit par Aura. Ne pas modifier : ce fichier est réécrit à chaque changement de réglage.\n"
            + "AURA_PORT=\(port)\n"
            + "AURA_WAIT=\(wait)\n"
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Commande shell qui lance le script, entre apostrophes si le chemin contient une espace.
    private static var scriptCommand: String {
        let path = scriptURL.path
        return path.contains(" ") ? "'\(path)'" : path
    }

    // MARK: Installation

    static func install(_ target: HookTarget, port: Int, timeout: Double, replaceCodexNotify: Bool) -> InstallOutcome {
        do {
            try installScript(port: port, timeout: timeout)
            let url = fileURL(for: target)
            switch target {
            case .claude:
                var root = try readJSON(url)
                stripClaude(&root)
                addClaude(&root)
                let backupName = try backup(url)
                try writeJSON(root, to: url)
                return .installed(backup: backupName)
            case .cursor:
                var root = try readJSON(url)
                stripCursor(&root)
                addCursor(&root)
                let backupName = try backup(url)
                try writeJSON(root, to: url)
                return .installed(backup: backupName)
            case .codex:
                return try installCodex(url, replace: replaceCodexNotify)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Désinstallation

    /// Retire uniquement ce qu'Aura a ajouté. Renvoie un message d'erreur, ou nil si tout va bien.
    static func uninstall(_ target: HookTarget) -> String? {
        let url = fileURL(for: target)
        guard FileManager.default.fileExists(atPath: url.path), isInstalled(target) else { return nil }
        do {
            switch target {
            case .claude:
                var root = try readJSON(url)
                stripClaude(&root)
                _ = try backup(url)
                try writeJSON(root, to: url)
            case .cursor:
                var root = try readJSON(url)
                stripCursor(&root)
                _ = try backup(url)
                try writeJSON(root, to: url)
            case .codex:
                let text = try String(contentsOf: url, encoding: .utf8)
                var kept: [String] = []
                for line in text.components(separatedBy: "\n") {
                    if line.hasPrefix(savedPrefix) {
                        kept.append(String(line.dropFirst(savedPrefix.count)))
                    } else if line.contains(marker) && line.trimmed.hasPrefix("notify") {
                        continue
                    } else {
                        kept.append(line)
                    }
                }
                _ = try backup(url)
                try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            removeScriptIfUnused()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func removeScriptIfUnused() {
        guard !HookTarget.allCases.contains(where: { isInstalled($0) }) else { return }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: configURL)
        // Le dossier n'est retiré que s'il est vide.
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: auraDirectory.path), rest.isEmpty {
            try? FileManager.default.removeItem(at: auraDirectory)
        }
    }

    // MARK: Sauvegarde et JSON

    /// Copie le fichier à côté de lui avec un suffixe horodaté. Renvoie le nom de la copie, ou nil s'il n'y avait rien à sauvegarder.
    private static func backup(_ url: URL) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = "\(url.lastPathComponent).\(formatter.string(from: Date())).bak"
        var destination = url.deletingLastPathComponent().appendingPathComponent(name)
        var attempt = 1
        while fm.fileExists(atPath: destination.path) {
            attempt += 1
            name = "\(url.lastPathComponent).\(formatter.string(from: Date()))-\(attempt).bak"
            destination = url.deletingLastPathComponent().appendingPathComponent(name)
        }
        try fm.copyItem(at: url, to: destination)
        return name
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmed.isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InstallerError(message: "\(url.lastPathComponent) n'est pas un JSON valide (commentaires ou virgule en trop ?). Fichier laissé intact.")
        }
        guard let object = parsed as? [String: Any] else {
            throw InstallerError(message: "\(url.lastPathComponent) ne contient pas un objet JSON. Fichier laissé intact.")
        }
        return object
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    private static func isOurs(_ command: Any?) -> Bool {
        guard let command = command as? String else { return false }
        return command.contains(marker)
    }

    // MARK: Claude Code — ~/.claude/settings.json
    // Format : hooks.<Événement> = [ { "matcher": "...", "hooks": [ { "type": "command", "command": "...", "timeout": s } ] } ]

    private static func claudeGroup(event: String, matcher: String?, timeout: Int) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": "\(scriptCommand) claude \(event)",
                    "timeout": timeout
                ] as [String: Any]
            ]
        ]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func addClaude(_ root: inout [String: Any]) {
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let entries: [(event: String, matcher: String?, timeout: Int)] = [
            ("PreToolUse", "Bash", approvalHookTimeout),
            ("PostToolUse", nil, 5),
            ("Notification", nil, 5),
            ("Stop", nil, 5),
            ("UserPromptSubmit", nil, 5)
        ]
        for entry in entries {
            var groups = (hooks[entry.event] as? [Any]) ?? []
            groups.append(claudeGroup(event: entry.event, matcher: entry.matcher, timeout: entry.timeout))
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
    }

    private static func stripClaude(_ root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var touched = false
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            var changed = false
            for item in groups {
                guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else {
                    kept.append(item)
                    continue
                }
                let remaining = handlers.filter { handler in
                    !isOurs((handler as? [String: Any])?["command"])
                }
                if remaining.count == handlers.count {
                    kept.append(item)
                    continue
                }
                changed = true
                if !remaining.isEmpty {
                    group["hooks"] = remaining
                    kept.append(group)
                }
            }
            guard changed else { continue }
            touched = true
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        guard touched else { return }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
    }

    // MARK: Cursor — ~/.cursor/hooks.json
    // Format : { "version": 1, "hooks": { "<événement>": [ { "command": "...", "timeout": s } ] } }

    private static func addCursor(_ root: inout [String: Any]) {
        if root["version"] == nil {
            root["version"] = 1
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let entries: [(event: String, timeout: Int)] = [
            ("beforeShellExecution", approvalHookTimeout),
            ("afterFileEdit", 5),
            ("stop", 5)
        ]
        for entry in entries {
            var list = (hooks[entry.event] as? [Any]) ?? []
            let item: [String: Any] = [
                "command": "\(scriptCommand) cursor \(entry.event)",
                "timeout": entry.timeout
            ]
            list.append(item)
            hooks[entry.event] = list
        }
        root["hooks"] = hooks
    }

    private static func stripCursor(_ root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var touched = false
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let remaining = list.filter { item in
                !isOurs((item as? [String: Any])?["command"])
            }
            guard remaining.count != list.count else { continue }
            touched = true
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        guard touched else { return }
        root["hooks"] = hooks
    }

    // MARK: Codex — ~/.codex/config.toml
    // Format : clé racine `notify = ["programme", "arg"]` ; Codex ajoute le JSON de l'événement en dernier argument.

    private static var codexLine: String {
        let path = scriptURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "notify = [\"\(path)\", \"codex\"]"
    }

    /// Lignes de la clé racine `notify` (avant la première table), s'il y en a une.
    private static func codexNotifyRange(in lines: [String]) -> ClosedRange<Int>? {
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmed
            if trimmedLine.hasPrefix("[") { return nil } // première table : fin des clés racine
            guard trimmedLine.hasPrefix("notify") else { continue }
            let rest = trimmedLine.dropFirst("notify".count).trimmed
            guard rest.hasPrefix("=") else { continue }

            // Tableau éventuellement écrit sur plusieurs lignes : on va jusqu'au crochet fermant.
            var depth = 0
            var end = index
            for cursor in index..<lines.count {
                depth += lines[cursor].filter { $0 == "[" }.count
                depth -= lines[cursor].filter { $0 == "]" }.count
                end = cursor
                if depth <= 0 { break }
            }
            return index...end
        }
        return nil
    }

    private static func installCodex(_ url: URL, replace: Bool) throws -> InstallOutcome {
        let fm = FileManager.default
        let text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")

        if let range = codexNotifyRange(in: lines) {
            let existing = lines[range].joined(separator: "\n")
            if existing.contains(marker) {
                lines.replaceSubrange(range, with: [codexLine])
            } else if replace {
                let saved = lines[range].map { savedPrefix + $0 }
                lines.replaceSubrange(range, with: saved + [codexLine])
            } else {
                return .conflict(existing: existing.trimmed)
            }
        } else {
            // Les clés racine doivent précéder les tables : on écrit tout en haut.
            lines.insert(codexLine, at: 0)
        }

        let backupName = try backup(url)
        var output = lines.joined(separator: "\n")
        if !output.hasSuffix("\n") {
            output += "\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
        return .installed(backup: backupName)
    }
}
