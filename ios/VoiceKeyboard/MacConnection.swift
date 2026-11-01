import SwiftUI

/// Remembers which Mac to use and whether it answers. Pairing normally happens by scanning
/// the QR code on the Mac dashboard, which opens voicekb://pair?url=…&token=….
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
    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("token") var token = ""

    private let discovery = ServerDiscovery()

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
        Task { await check() }
        return true
    }

    /// Pair by typing the code the Mac prints; the address is found on the network.
    func pair(code: String) async {
        token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        await check()
    }

    func check() async {
        guard !token.isEmpty else {
            status = .notPaired
            return
        }
        status = .checking

        if let url = URL(string: serverURL), url.host != nil,
           let health = try? await MacServerClient(baseURL: url, token: token).health() {
            status = health.authed ? .connected(model: health.model) : .wrongCode
            return
        }

        // Not set yet, or the Mac's IP changed: look for it on the network.
        for url in await discovery.findAll() {
            guard let health = try? await MacServerClient(baseURL: url, token: token).health() else { continue }
            serverURL = url.absoluteString
            status = health.authed ? .connected(model: health.model) : .wrongCode
            return
        }
        status = .unreachable
    }

    func forget() {
        serverURL = ""
        token = ""
        status = .notPaired
    }
}
