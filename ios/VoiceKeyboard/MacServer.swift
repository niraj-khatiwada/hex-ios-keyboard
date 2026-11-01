import Foundation
import Network

/// One dictation, as the Mac's history stores it (text only — audio stays on the Mac).
struct HistoryItem: Decodable, Identifiable, Equatable {
    let id: String
    /// Milliseconds since 1970.
    let at: Double
    let text: String
    let error: String?

    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

/// Talks to the Bun server in `mac-server/`.
struct MacServerClient {
    var baseURL: URL
    var token: String

    struct Health: Decodable { let ok: Bool; let authed: Bool; let model: String; let modelName: String?; let ready: Bool }
    private struct Result: Decodable { let text: String?; let error: String? }

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func health(timeout: TimeInterval = 5) async throws -> Health {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Health.self, from: data)
    }

    func history(limit: Int = 500) async throws -> [HistoryItem] {
        var components = URLComponents(url: baseURL.appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([HistoryItem].self, from: data)
    }

    func transcribe(wav: Data) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: wav)
        let result = try? JSONDecoder().decode(Result.self, from: data)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 { throw ServerError(message: "Wrong token — check the app settings") }
            throw ServerError(message: result?.error ?? "Mac server error \(http.statusCode)")
        }
        guard let text = result?.text else { throw ServerError(message: "Bad response from Mac") }
        return text
    }
}

/// Finds the Mac server on the local network via Bonjour (`_voicekb._tcp`).
@MainActor
final class ServerDiscovery: ObservableObject {
    struct Found: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []

    func search() {
        stop()
        found = []
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_voicekb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in results.forEach { self?.resolve($0.endpoint) } }
        }
        browser.start(queue: .main)
        self.browser = browser
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.stop() }
    }

    /// Searches until something turns up or `timeout` passes.
    func findAll(timeout: TimeInterval = 4) async -> [URL] {
        search()
        let deadline = Date().addingTimeInterval(timeout)
        while found.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let urls = found.map(\.url)
        stop()
        return urls
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.forEach { $0.cancel() }
        resolving = []
        isSearching = false
    }

    /// Bonjour gives a service name; connect once to learn its IP and port.
    private func resolve(_ endpoint: NWEndpoint) {
        guard case let .service(name, _, _, _) = endpoint else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                var hostString = "\(host)"
                if let pct = hostString.firstIndex(of: "%") { hostString = String(hostString[..<pct]) }
                if let url = URL(string: "http://\(hostString):\(port.rawValue)") {
                    Task { @MainActor in
                        guard let self, !self.found.contains(where: { $0.url == url }) else { return }
                        self.found.append(Found(name: name, url: url))
                    }
                }
            }
            connection.cancel()
        }
        connection.start(queue: .main)
        resolving.append(connection)
    }
}
