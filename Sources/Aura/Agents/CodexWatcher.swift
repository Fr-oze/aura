import Foundation

/// Codex ne sait signaler que la fin d'un tour (`notify`). Pour voir aussi « au travail »,
/// Aura regarde la date de modification du journal de session le plus récent sous
/// `~/.codex/sessions`. Ça bouge pendant que Codex écrit, ça s'arrête quand il a fini.
/// Aucun hook à installer, aucune autorisation.
@MainActor
final class CodexWatcher {
    /// Session vue comme vivante tant que son journal a bougé il y a moins de ça.
    private static let activeWindow: TimeInterval = 8
    /// Journal immobile depuis ça : la session en direct est retirée (l'événement `notify`
    /// de Codex, lui, affiche « terminé » de son côté).
    private static let idleDelay: TimeInterval = 12
    /// Clé de session : volontairement fixe, Aura n'affiche qu'un Codex en direct à la fois.
    /// ponytail : une seule session suivie ; à éclater par dossier si Max lance deux Codex.
    private static let sessionKey = "codex-live"

    private let settings: SettingsStore
    private let root: URL
    private var timer: Timer?
    private var announced = false
    private var lastPath: String?
    private var lastCwd = ""

    var onEvent: ((IncomingEvent) -> Void)?

    init(settings: SettingsStore,
         root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")) {
        self.settings = settings
        self.root = root
    }

    func start() {
        guard timer == nil else { return }
        let created = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        created.tolerance = 0.5
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if announced {
            announced = false
            send(kind: .ended)
        }
    }

    private func tick() {
        guard settings.s.codexEnabled, settings.s.codexWatch else {
            if announced {
                announced = false
                send(kind: .ended)
            }
            return
        }

        guard let newest = CodexWatcher.newestFile(in: root) else { return }
        let age = Date().timeIntervalSince(newest.modified)

        if age <= CodexWatcher.activeWindow {
            if newest.url.path != lastPath {
                lastPath = newest.url.path
                lastCwd = CodexWatcher.readCwd(from: newest.url)
            }
            // Premier signe de vie = une action ; les rafraîchissements suivants sont muets.
            let firstTime = !announced
            announced = true
            send(kind: .working, silent: !firstTime)
        } else if announced, age >= CodexWatcher.idleDelay {
            announced = false
            send(kind: .ended)
        }
    }

    private func send(kind: EventKind, silent: Bool = false) {
        let event = IncomingEvent(source: .codex,
                                  session: CodexWatcher.sessionKey,
                                  cwd: lastCwd,
                                  kind: kind,
                                  title: "",
                                  detail: kind == .working ? "écrit" : "",
                                  app: "",
                                  silent: silent)
        onEvent?(event)
    }

    /// Premier objet JSON du journal : Codex y met le dossier de travail.
    private static func readCwd(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192),
              let text = String(data: head, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return "" }
        if let cwd = object["cwd"] as? String { return cwd }
        if let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
            return cwd
        }
        return ""
    }

    /// Fichier le plus récemment modifié sous `directory`. Descend dans le sous-dossier le plus
    /// récent à chaque niveau (Codex range par année/mois/jour) : jamais toute l'arborescence.
    static func newestFile(in directory: URL, depth: Int = 5) -> (url: URL, modified: Date)? {
        guard depth > 0 else { return nil }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]),
              !entries.isEmpty
        else { return nil }

        var bestFile: (url: URL, modified: Date)?
        var bestDirectory: (url: URL, modified: Date)?
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate
            else { continue }
            if values.isDirectory == true {
                if bestDirectory == nil || modified > bestDirectory!.modified {
                    bestDirectory = (entry, modified)
                }
            } else if bestFile == nil || modified > bestFile!.modified {
                bestFile = (entry, modified)
            }
        }

        // Un dossier plus récent qu'un fichier du même niveau contient forcément du plus frais.
        if let bestDirectory, bestFile == nil || bestDirectory.modified >= bestFile!.modified,
           let deeper = newestFile(in: bestDirectory.url, depth: depth - 1) {
            return deeper
        }
        return bestFile
    }
}
