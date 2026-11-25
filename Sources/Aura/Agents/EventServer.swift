import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Une requête en cours : permet de répondre plus tard (validation bloquante)
/// et de savoir si le client a raccroché entre-temps.
final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var finished = false                      // file du serveur uniquement
    private var clientGone: (@MainActor () -> Void)?  // thread principal uniquement

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Envoie la réponse puis ferme la connexion. Les appels suivants sont ignorés.
    func reply(status: Int, json: String) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            let body = Data(json.utf8)
            let head = "HTTP/1.1 \(status) \(HTTPExchange.reason(status))\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Connection: close\r\n\r\n"
            var packet = Data(head.utf8)
            packet.append(body)
            let connection = self.connection
            connection.send(content: packet, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// Appelé si le client ferme la connexion avant d'avoir reçu sa réponse.
    @MainActor
    func onClientGone(_ handler: @escaping @MainActor () -> Void) {
        clientGone = handler
    }

    @MainActor
    private func fireClientGone() {
        let handler = clientGone
        clientGone = nil
        handler?()
    }

    /// À appeler sur la file du serveur, une fois la requête lue en entier.
    fileprivate func watchForDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
            if isComplete || error != nil {
                guard !self.finished else { return }
                self.finished = true
                self.connection.cancel()
                Task { @MainActor in
                    self.fireClientGone()
                }
            } else {
                self.watchForDisconnect()
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

enum ServerState: Equatable {
    case stopped
    case running(Int)
    case failed(String)
}

/// Serveur HTTP minimal, à l'écoute sur 127.0.0.1 uniquement.
final class EventServer: @unchecked Sendable {
    private static let maxBody = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.maxlab.aura.server")
    private var listener: NWListener?

    /// Appelés sur le thread principal. À régler avant `start`.
    var onRequest: (@MainActor (HTTPRequest, HTTPExchange) -> Void)?
    var onState: (@MainActor (ServerState) -> Void)?

    func start(port: Int) {
        stop()
        guard (1024...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            report(.failed("Port invalide (choisis entre 1024 et 65535)."))
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host.ipv4(IPv4Address.loopback),
                                                              port: nwPort)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report(.running(port))
                case .failed(let error):
                    self?.report(.failed(EventServer.describe(error, port: port)))
                case .waiting(let error):
                    self?.report(.failed(EventServer.describe(error, port: port)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            report(.failed("Impossible d'ouvrir le port \(port) : \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard let listener else { return }
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        self.listener = nil
        report(.stopped)
    }

    // MARK: Interne

    private static func describe(_ error: NWError, port: Int) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Le port \(port) est déjà pris par une autre app."
        }
        return "Port \(port) indisponible : \(error.localizedDescription)"
    }

    private func report(_ state: ServerState) {
        let callback = onState
        Task { @MainActor in
            callback?(state)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data(), sentContinue: false)
    }

    private func read(_ connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if buffer.count > EventServer.maxBody + 16384 {
                HTTPExchange(connection: connection, queue: self.queue)
                    .reply(status: 413, json: "{\"error\":\"too large\"}")
                return
            }

            switch EventServer.parse(buffer) {
            case .complete(let request):
                self.dispatch(request, connection)
            case .invalid:
                HTTPExchange(connection: connection, queue: self.queue)
                    .reply(status: 400, json: "{\"error\":\"bad request\"}")
            case .incomplete(let expectsContinue):
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                var sent = sentContinue
                if expectsContinue && !sent {
                    sent = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in })
                }
                self.read(connection, buffer: buffer, sentContinue: sent)
            }
        }
    }

    private func dispatch(_ request: HTTPRequest, _ connection: NWConnection) {
        let exchange = HTTPExchange(connection: connection, queue: queue)
        // Une page web ne doit pas pouvoir parler à Aura : les navigateurs envoient "Origin".
        if request.headers["origin"] != nil {
            exchange.reply(status: 403, json: "{\"error\":\"forbidden\"}")
            return
        }
        exchange.watchForDisconnect()
        let callback = onRequest
        Task { @MainActor in
            if let callback {
                callback(request, exchange)
            } else {
                exchange.reply(status: 404, json: "{\"error\":\"not found\"}")
            }
        }
    }

    private enum ParseResult {
        case incomplete(expectsContinue: Bool)
        case invalid
        case complete(HTTPRequest)
    }

    private static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data([13, 10, 13, 10])
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > 16384 ? .invalid : .incomplete(expectsContinue: false)
        }

        let headText = String(decoding: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        let method = String(requestLine[0]).uppercased()
        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmed.lowercased()
            let value = line[line.index(after: colon)...].trimmed
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid }

        let bodyStart = headerEnd.upperBound
        if buffer.endIndex - bodyStart < length {
            let expects = (headers["expect"] ?? "").lowercased().contains("100-continue")
            return .incomplete(expectsContinue: expects)
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}
