import AppKit
import Combine
import SQLite3

/// Une ligne de la base du Centre de notifications, déjà décodée.
struct RawNotice: Sendable {
    var recID: Int64
    var bundleID: String
    var title: String
    var subtitle: String
    var body: String
    var delivered: Double
}

struct NoticeBatch: Sendable {
    var records: [RawNotice] = []
    var maxID: Int64 = 0
    var maxDate: Double = 0
}

enum NoticeReadError: Error, Sendable {
    case notFound
    case denied
    case failed(String)
}

/// Lecture seule de la base SQLite du Centre de notifications. Aucun état : tout est statique
/// et peut tourner hors du thread principal.
///
/// Emplacements (vérifiés en novembre 2026) :
/// - macOS 15 Sequoia et 26 Tahoe : `~/Library/Group Containers/group.com.apple.usernoted/db2/db`
///   (protégé par TCC : il faut l'Accès complet au disque) ;
/// - macOS 14 et avant : `$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db`.
///
/// Schéma utilisé : table `record` (`rec_id`, `app_id`, `data` = plist binaire, `delivered_date`
/// en secondes depuis 2001) et table `app` (`app_id`, `identifier` = identifiant de bundle).
/// Le plist contient `app` et `req` → `titl`, `subt`, `body`.
enum NoticeDatabase {
    static let modernRelativePath = "Library/Group Containers/group.com.apple.usernoted/db2/db"
    static let legacyRelativePath = "com.apple.notificationcenter/db2/db"

    static var modernURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(modernRelativePath)
    }

    static var legacyURL: URL? {
        let size = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, size) > 0 else { return nil }
        let directory = String(cString: buffer)
        guard !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(legacyRelativePath)
    }

    /// Vrai si le fichier s'ouvre en lecture (donc si macOS nous laisse y accéder).
    static func canRead(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// Cherche la base : d'abord l'emplacement moderne, puis l'ancien.
    static func locate() -> Result<URL, NoticeReadError> {
        let fileManager = FileManager.default
        let modern = modernURL
        if canRead(modern) {
            return .success(modern)
        }
        if let legacy = legacyURL, canRead(legacy) {
            return .success(legacy)
        }
        // Rien de lisible : soit macOS bloque le dossier moderne, soit la base n'existe pas.
        let container = modern.deletingLastPathComponent().deletingLastPathComponent().path
        if fileManager.fileExists(atPath: modern.path) || fileManager.fileExists(atPath: container) {
            return .failure(.denied)
        }
        if let legacy = legacyURL, fileManager.fileExists(atPath: legacy.path) {
            return .failure(.denied)
        }
        // Sur macOS 15 et plus, sans Accès complet au disque le dossier peut sembler absent.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
            return .failure(.denied)
        }
        return .failure(.notFound)
    }

    /// Date de modification la plus récente entre `db-wal` et `db` : un simple `stat`.
    static func stamp(_ url: URL) -> Double {
        var newest = 0.0
        for suffix in ["-wal", ""] {
            let path = url.path + suffix
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attributes[.modificationDate] as? Date {
                newest = max(newest, date.timeIntervalSinceReferenceDate)
            }
        }
        return newest
    }

    /// Lit les notifications plus récentes que les repères donnés.
    /// `baselineOnly` : ne renvoie que les repères actuels (au démarrage, pour ne pas rejouer l'historique).
    static func fetch(from url: URL, afterID: Int64, afterDate: Double, baselineOnly: Bool) -> Result<NoticeBatch, NoticeReadError> {
        guard canRead(url) else {
            return .failure(FileManager.default.fileExists(atPath: url.path) ? .denied : .notFound)
        }

        // Copie de travail (db + journal WAL) : les notifications toutes fraîches vivent dans le WAL,
        // et on ne pose ainsi aucun verrou sur la base de macOS. Sur APFS la copie est un clone instantané.
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("aura-notices-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }

        var copied = false
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: folder.appendingPathComponent("db" + suffix))
            }
            copied = true
        } catch {
            copied = false
        }

        var database: OpaquePointer?
        var opened = false
        if copied {
            let path = folder.appendingPathComponent("db").path
            opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
            if !opened {
                sqlite3_close(database)
                database = nil
            }
        }
        if !opened {
            // Repli : la base d'origine, en lecture seule et « immutable » (aucun verrou, mais sans le WAL).
            let uri = url.absoluteString + "?mode=ro&immutable=1"
            opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        }
        guard opened, let handle = database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            sqlite3_close(database)
            return .failure(.failed(message))
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)

        var batch = NoticeBatch(records: [], maxID: afterID, maxDate: afterDate)

        if baselineOnly {
            var statement: OpaquePointer?
            let sql = "SELECT MAX(rec_id), MAX(delivered_date) FROM record"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                sqlite3_finalize(statement)
                return .failure(.failed("schéma inattendu : \(message)"))
            }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                batch.maxID = max(batch.maxID, sqlite3_column_int64(statement, 0))
                batch.maxDate = max(batch.maxDate, sqlite3_column_double(statement, 1))
            }
            return .success(batch)
        }

        var statement: OpaquePointer?
        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?1 OR r.delivered_date > ?2
            ORDER BY r.delivered_date ASC, r.rec_id ASC
            LIMIT 40
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            return .failure(.failed("schéma inattendu : \(message)"))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, afterID)
        sqlite3_bind_double(statement, 2, afterDate)

        while sqlite3_step(statement) == SQLITE_ROW {
            let recID = sqlite3_column_int64(statement, 0)
            let identifier = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let delivered = sqlite3_column_double(statement, 3)
            batch.maxID = max(batch.maxID, recID)
            batch.maxDate = max(batch.maxDate, delivered)

            var payload = Data()
            let length = Int(sqlite3_column_bytes(statement, 2))
            if length > 0, let blob = sqlite3_column_blob(statement, 2) {
                payload = Data(bytes: blob, count: length)
            }
            if let record = decode(payload, recID: recID, identifier: identifier, delivered: delivered) {
                batch.records.append(record)
            }
        }
        return .success(batch)
    }

    /// Décode le plist binaire d'une notification. Toute clé manquante donne une chaîne vide.
    static func decode(_ data: Data, recID: Int64, identifier: String, delivered: Double) -> RawNotice? {
        var root: [String: Any] = [:]
        if !data.isEmpty,
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = object as? [String: Any] {
            root = dictionary
        }
        let request = root["req"] as? [String: Any] ?? [:]

        var bundleID = identifier
        if bundleID.isEmpty {
            bundleID = text(root["app"])
        }
        // Les notifications du système sont préfixées (« _SYSTEM_CENTER_:com.apple… »).
        if let colon = bundleID.lastIndex(of: ":") {
            bundleID = String(bundleID[bundleID.index(after: colon)...])
        }

        let title = text(request["titl"] ?? request["title"])
        let subtitle = text(request["subt"] ?? request["subtitle"])
        let body = text(request["body"])
        guard !bundleID.isEmpty, !(title.isEmpty && subtitle.isEmpty && body.isEmpty) else { return nil }
        return RawNotice(recID: recID, bundleID: bundleID, title: title, subtitle: subtitle,
                         body: body, delivered: delivered)
    }

    /// Texte d'une valeur de plist, quel que soit son type réel.
    private static func text(_ value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let list = value as? [Any] {
            return list.map { text($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ""
    }
}

struct KnownApp: Identifiable, Equatable {
    var id: String
    var name: String
}

/// Surveille la base du Centre de notifications et publie les nouvelles notifications.
@MainActor
final class NotificationWatcher: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case running
        case noAccess
        case notFound
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Dernières notifications vues par Aura, la plus récente en premier.
    @Published private(set) var items: [NoticeItem] = []
    /// Apps dont Aura a déjà vu une notification (pour les listes des réglages).
    @Published private(set) var knownApps: [KnownApp] = []
    /// Chemin de la base retenue, affiché dans les réglages.
    @Published private(set) var databasePath = ""

    /// Notification à montrer dans l'encoche. Le booléen indique une app prioritaire.
    var onPresent: ((NoticeItem, Bool) -> Void)?

    static let historyLimit = 30
    private static let appsKey = "aura.notices.apps.v1"
    private static let ownBundleID = "com.maxlab.aura"

    private let settings: SettingsStore
    private let queue = DispatchQueue(label: "aura.notices", qos: .utility)
    private var timer: Timer?
    private var url: URL?
    private var lastStamp = 0.0
    private var lastID: Int64 = 0
    private var lastDate = 0.0
    private var hasBaseline = false
    private var busy = false
    private var session = 0
    private var idleTicks = 0

    init(settings: SettingsStore) {
        self.settings = settings
        let stored = UserDefaults.standard.stringArray(forKey: NotificationWatcher.appsKey) ?? []
        knownApps = stored.map { KnownApp(id: $0, name: AppLookup.name(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var isRunning: Bool { timer != nil }

    // MARK: Cycle de vie

    func start() {
        guard timer == nil else { return }
        session += 1
        status = .starting
        hasBaseline = false
        busy = false
        url = nil
        lastStamp = 0
        idleTicks = 0

        // Sondage léger : un `stat` toutes les 1,5 s, la base n'est lue que si elle a bougé.
        let created = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        created.tolerance = 0.5
        RunLoop.main.add(created, forMode: .common)
        timer = created
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session += 1
        busy = false
        if status != .off { status = .off }
    }

    /// Bouton « Revérifier » des réglages : retente tout de suite la localisation et l'ouverture.
    func recheck() {
        guard timer != nil else { return }
        url = nil
        hasBaseline = false
        idleTicks = 0
        tick()
    }

    /// Efface la liste d'Aura. La base de macOS n'est jamais modifiée.
    func clear() {
        if !items.isEmpty { items = [] }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Bouton « Tester » : une fausse notification, sans passer par la base.
    func test() {
        let item = NoticeItem(bundleID: "com.apple.MobileSMS",
                              appName: AppLookup.name(for: "com.apple.MobileSMS"),
                              title: "Camille",
                              subtitle: "",
                              body: "Tu as vu la nouvelle encoche ? Elle est folle.",
                              date: Date())
        push(item)
        onPresent?(item, false)
    }

    // MARK: Sondage

    private func tick() {
        guard !busy else { return }

        guard let url else {
            // Base pas encore trouvée : on réessaie tout de suite, puis toutes les 6 s environ.
            if idleTicks % 4 == 0 {
                locate()
            }
            idleTicks += 1
            return
        }

        let stamp = NoticeDatabase.stamp(url)
        if stamp == 0 {
            // Fichier devenu illisible (autorisation retirée, base déplacée).
            self.url = nil
            hasBaseline = false
            idleTicks = 0
            return
        }
        guard !hasBaseline || stamp != lastStamp else { return }
        read(url, stamp: stamp)
    }

    private func locate() {
        busy = true
        let current = session
        queue.async { [weak self] in
            let result = NoticeDatabase.locate()
            Task { @MainActor [weak self] in
                guard let self, self.session == current else { return }
                self.busy = false
                switch result {
                case .success(let found):
                    self.url = found
                    self.databasePath = found.path
                    self.tick()
                case .failure(let error):
                    self.apply(error)
                }
            }
        }
    }

    private func read(_ url: URL, stamp: Double) {
        busy = true
        let current = session
        let afterID = lastID
        let afterDate = lastDate
        let baselineOnly = !hasBaseline
        queue.async { [weak self] in
            let result = NoticeDatabase.fetch(from: url, afterID: afterID, afterDate: afterDate,
                                              baselineOnly: baselineOnly)
            Task { @MainActor [weak self] in
                guard let self, self.session == current else { return }
                self.busy = false
                switch result {
                case .success(let batch):
                    self.lastStamp = stamp
                    self.lastID = max(self.lastID, batch.maxID)
                    self.lastDate = max(self.lastDate, batch.maxDate)
                    if self.status != .running { self.status = .running }
                    if baselineOnly {
                        self.hasBaseline = true
                    } else {
                        self.ingest(batch.records)
                    }
                case .failure(let error):
                    self.url = nil
                    self.hasBaseline = false
                    self.idleTicks = 1
                    self.apply(error)
                }
            }
        }
    }

    private func apply(_ error: NoticeReadError) {
        let next: Status
        switch error {
        case .notFound: next = .notFound
        case .denied: next = .noAccess
        case .failed(let message): next = .failed(message)
        }
        if status != next { status = next }
    }

    // MARK: Nouvelles notifications

    private func ingest(_ records: [RawNotice]) {
        guard !records.isEmpty else { return }
        let config = settings.s
        let ignored = Set(config.noticeIgnored.map { $0.lowercased() })
        let priority = Set(config.noticePriority.map { $0.lowercased() })

        var latest: NoticeItem?
        var latestIsPriority = false

        for record in records {
            let key = record.bundleID.lowercased()
            // Les notifications d'Aura elle-même ne repassent pas par l'encoche.
            guard key != NotificationWatcher.ownBundleID else { continue }
            remember(app: record.bundleID)
            guard !ignored.contains(key) else { continue }

            let date = record.delivered > 0 ? Date(timeIntervalSinceReferenceDate: record.delivered) : Date()
            let item = NoticeItem(bundleID: record.bundleID,
                                  appName: AppLookup.name(for: record.bundleID),
                                  title: record.title,
                                  subtitle: record.subtitle,
                                  body: record.body,
                                  date: date)
            push(item)

            let isPriority = priority.contains(key)
            // « Ne pas déranger » d'Aura : seules les apps prioritaires sortent encore.
            if !config.noticeDND || isPriority {
                if latest == nil || isPriority || !latestIsPriority {
                    latest = item
                    latestIsPriority = isPriority
                }
            }
        }

        if let latest {
            onPresent?(latest, latestIsPriority)
        }
    }

    private func push(_ item: NoticeItem) {
        var list = items
        list.insert(item, at: 0)
        if list.count > NotificationWatcher.historyLimit {
            list.removeLast(list.count - NotificationWatcher.historyLimit)
        }
        items = list
    }

    private func remember(app bundleID: String) {
        guard !knownApps.contains(where: { $0.id.lowercased() == bundleID.lowercased() }) else { return }
        var list = knownApps
        list.append(KnownApp(id: bundleID, name: AppLookup.name(for: bundleID)))
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownApps = list
        UserDefaults.standard.set(list.map(\.id), forKey: NotificationWatcher.appsKey)
    }
}
