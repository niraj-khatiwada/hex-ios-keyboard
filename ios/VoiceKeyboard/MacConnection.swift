import SwiftUI

/// Remembers which Mac to use and keeps a live WebSocket to it, so the server stopping or
/// coming back shows up immediately. Pairing normally happens by scanning the QR code on the
/// Mac dashboard, which opens voicekb://pair?url=…&token=….
@MainActor
final class MacConnection: ObservableObject {
    enum Status: Equatable {
        case notPaired
        case checking
        case connected(model: String)
        case wrongCode
        case unreachable
    }

    @Published private(set) var status: Status = .notPaired
    /// False while the Mac is still loading the Hex model.
    @Published private(set) var engineReady = true
    /// The model the Mac transcribes with, e.g. "Parakeet Unified English".
    @Published private(set) var modelName: String?
    /// Dictation history from the Mac, newest first. Text only.
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var historyLoading = false
    @Published private(set) var historyError: String?
    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("token") var token = ""

    private let discovery = ServerDiscovery()
    private var socket: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var failures = 0

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var hostDescription: String {
        URL(string: serverURL)?.host ?? serverURL
    }

    /// Handles voicekb://pair links. Returns false if the link isn't a pairing link.
    func pair(with link: URL) -> Bool {
        guard link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value
        else { return false }
        serverURL = url
        self.token = token
        DebugLog.log("paired from QR code: \(url)")
        Task { await reconnectNow() }
        return true
    }

    /// Pair by typing the code the Mac prints; the address is found on the network.
    func pair(code: String) async {
        token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        await reconnectNow()
    }

    /// Drops any current connection and connects again, e.g. after scanning a new QR code.
    func reconnectNow() async {
        closeSocket()
        reconnectTask?.cancel()
        failures = 0
        await check()
    }

    /// Finds the Mac (searching the network if needed) and opens the live connection.
    func check() async {
        guard !token.isEmpty else {
            status = .notPaired
            return
        }
        if socket != nil, isConnected { return }
        status = .checking

        if let url = URL(string: serverURL), url.host != nil,
           let health = try? await MacServerClient(baseURL: url, token: token).health() {
            connected(after: health)
            return
        }

        // Not set yet, or the Mac's IP changed: look for it on the network.
        for url in await discovery.findAll() {
            guard let health = try? await MacServerClient(baseURL: url, token: token).health() else { continue }
            serverURL = url.absoluteString
            connected(after: health)
            return
        }
        status = .unreachable
        scheduleReconnect()
    }

    func forget() {
        closeSocket()
        reconnectTask?.cancel()
        serverURL = ""
        token = ""
        status = .notPaired
    }

    // MARK: Live connection

    private func connected(after health: MacServerClient.Health) {
        guard health.authed else {
            closeSocket()
            status = .wrongCode
            return
        }
        status = .connected(model: health.model)
        modelName = health.modelName ?? health.model
        engineReady = health.ready
        openSocket()
    }

    private func openSocket() {
        closeSocket()
        reconnectTask?.cancel()
        guard let base = URL(string: serverURL), let host = base.host, !token.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = base.port
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)

        // Pings notice a dead connection (Wi-Fi dropped, Mac asleep) within a few seconds.
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                task.sendPing { error in
                    guard let error else { return }
                    Task { @MainActor in self?.dropped(task, error) }
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                case .failure(let error):
                    self.dropped(task, error)
                }
            }
        }
    }

    private struct ServerMessage: Decodable {
        let type: String
        let model: String?
        let modelName: String?
        let ready: Bool?
        let entry: HistoryItem?
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ServerMessage.self, from: data)
        else { return }
        switch message.type {
        case "status":
            failures = 0
            if let model = message.model { status = .connected(model: model) }
            modelName = message.modelName ?? message.model
            engineReady = message.ready ?? true
        case "history":
            if let entry = message.entry, !history.contains(where: { $0.id == entry.id }) {
                history.insert(entry, at: 0)
            }
        default:
            break
        }
    }

    // MARK: History

    func loadHistory() async {
        guard let url = URL(string: serverURL), url.host != nil, !token.isEmpty else {
            historyError = "Connect to your Mac to see your history."
            return
        }
        historyLoading = true
        defer { historyLoading = false }
        do {
            history = try await MacServerClient(baseURL: url, token: token).history()
            historyError = nil
        } catch {
            historyError = "Couldn't load history from your Mac."
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask, _ error: Error) {
        guard socket === task else { return }
        DebugLog.log("mac connection closed: \(error.localizedDescription)")
        closeSocket()
        if status != .wrongCode { status = .unreachable }
        scheduleReconnect()
    }

    private func closeSocket() {
        pingTask?.cancel()
        pingTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Retries every second while the Mac is away, so it reconnects as soon as `bun start` runs.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        failures += 1
        let delay = failures == 1 ? 0.5 : 1.0
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    private func reconnect() async {
        guard !token.isEmpty, socket == nil else { return }
        if let url = URL(string: serverURL), url.host != nil,
           let health = try? await MacServerClient(baseURL: url, token: token).health(timeout: 1.5) {
            DebugLog.log("mac back after \(failures) tries")
            failures = 0
            connected(after: health)
            return
        }
        // Every ~15 s, check whether the Mac moved to a new IP.
        if failures % 15 == 0, let url = await discovery.findAll(timeout: 3).first {
            serverURL = url.absoluteString
        }
        scheduleReconnect()
    }
}
