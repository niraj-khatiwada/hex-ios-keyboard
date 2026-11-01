import Network
import SwiftUI

/// Remembers which Mac to use and keeps a live WebSocket to it, so the server stopping or
/// coming back shows up immediately. Pairing normally happens by scanning the QR code on the
/// Mac dashboard, which opens voicekb://pair?url=…&tailscale=…&token=….
///
/// The Mac can have two addresses: its home network one, and a Tailscale one that works from
/// anywhere. The home one is tried first (it's faster); when the network changes, the
/// connection moves to whichever works.
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
    /// The address in use right now. DictationSession sends clips here.
    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("token") var token = ""
    /// Every known address for the Mac, home network first, one per line.
    @AppStorage("serverAddresses") private var addressesRaw = ""

    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?

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

    /// True when the current connection goes over Tailscale rather than the home network.
    var isViaTailscale: Bool { Self.isTailscale(serverURL) }

    /// Whether the Mac can be reached away from home.
    var hasTailscaleAddress: Bool { addresses.contains(where: Self.isTailscale) }

    /// Tailscale hands out addresses in 100.64.0.0/10.
    static func isTailscale(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Known addresses, home network first, then Tailscale.
    private var addresses: [String] {
        var list = addressesRaw.split(separator: "\n").map(String.init)
        if !serverURL.isEmpty, !list.contains(serverURL) { list.append(serverURL) }
        return list.sorted { !Self.isTailscale($0) && Self.isTailscale($1) }
    }

    private func saveAddresses(_ list: [String]) {
        let cleaned = list.filter { URL(string: $0)?.host != nil }
        guard !cleaned.isEmpty else { return }
        let joined = cleaned.joined(separator: "\n")
        if joined != addressesRaw {
            addressesRaw = joined
            DebugLog.log("mac addresses: \(cleaned.joined(separator: ", "))")
        }
    }

    init() {
        // Leaving or rejoining Wi-Fi: move the connection right away instead of waiting
        // for a ping to fail.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted())"
            Task { @MainActor in self?.networkChanged(signature: signature) }
        }
        pathMonitor.start(queue: .main)
    }

    /// Handles voicekb://pair links. Returns false if the link isn't a pairing link.
    func pair(with link: URL) -> Bool {
        guard link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value
        else { return false }
        let tailscale = items.first(where: { $0.name == "tailscale" })?.value
        addressesRaw = ""
        saveAddresses([url] + (tailscale.map { [$0] } ?? []))
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

        if await connectToFirstReachable() { return }

        // Not set yet, or the Mac's home IP changed: look for it on the network.
        for url in await discovery.findAll() {
            guard let health = try? await MacServerClient(baseURL: url, token: token).health() else { continue }
            saveAddresses([url.absoluteString] + addresses.filter(Self.isTailscale))
            serverURL = url.absoluteString
            connected(after: health)
            return
        }
        status = .unreachable
        scheduleReconnect()
    }

    /// Tries each known address, home network first, and connects to the first that answers.
    private func connectToFirstReachable() async -> Bool {
        for address in addresses {
            guard let url = URL(string: address), url.host != nil else { continue }
            // Home is quick to answer or fail; Tailscale may need a moment to wake its tunnel.
            let timeout: TimeInterval = Self.isTailscale(address) ? 4 : 1.5
            let health: MacServerClient.Health
            do {
                health = try await MacServerClient(baseURL: url, token: token).health(timeout: timeout)
            } catch {
                let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
                DebugLog.log("can't reach \(address): \(error.localizedDescription) (\(code))")
                continue
            }
            if serverURL != address { DebugLog.log("mac reachable via \(Self.isTailscale(address) ? "Tailscale" : "home network"): \(address)") }
            serverURL = address
            connected(after: health)
            return true
        }
        return false
    }

    /// The network changed (left Wi-Fi, joined Wi-Fi, Tailscale came up): prefer the home
    /// address when it answers, and otherwise make sure we're on one that does.
    private func networkChanged(signature: String) {
        guard lastPathSignature != nil else {
            lastPathSignature = signature
            return
        }
        guard signature != lastPathSignature, !token.isEmpty else { return }
        lastPathSignature = signature
        DebugLog.log("network changed: \(signature)")
        Task {
            // Give new routes a moment to settle.
            try? await Task.sleep(for: .milliseconds(600))
            if let home = addresses.first(where: { !Self.isTailscale($0) }), let url = URL(string: home),
               let health = try? await MacServerClient(baseURL: url, token: token).health(timeout: 1.2) {
                if serverURL != home || socket == nil {
                    DebugLog.log("switching to home network")
                    serverURL = home
                    connected(after: health)
                }
                return
            }
            // Home isn't reachable; if that's what we were using, find another route now.
            if !isViaTailscale || socket == nil { await reconnectNow() }
        }
    }

    func forget() {
        closeSocket()
        reconnectTask?.cancel()
        addressesRaw = ""
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
        if let list = health.addresses { saveAddresses(list) }
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
        let addresses: [String]?
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
            if let list = message.addresses { saveAddresses(list) }
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
        if await connectToFirstReachable() {
            DebugLog.log("mac back after \(failures) tries")
            failures = 0
            return
        }
        // Every ~15 s, check whether the Mac moved to a new IP.
        if failures % 15 == 0, let url = await discovery.findAll(timeout: 3).first {
            serverURL = url.absoluteString
        }
        scheduleReconnect()
    }
}
