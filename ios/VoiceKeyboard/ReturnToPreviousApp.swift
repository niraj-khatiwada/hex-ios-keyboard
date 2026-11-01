import SwiftUI

/// An app we can send the user back to: the link that opens it and its name for the
/// "Back to <App>" button.
struct HostApp: Equatable {
    let url: URL
    let name: String
}

/// Apps we know how to reopen, by bundle ID. Reopening by link returns to the app, not
/// necessarily the exact chat or page; iOS decides what it restores.
enum HostAppCatalog {
    private static let entries: [String: (url: String, name: String)] = [
        // Apple
        "com.apple.mobilenotes": ("mobilenotes://", "Notes"),
        "com.apple.MobileSMS": ("sms://", "Messages"),
        "com.apple.mobilemail": ("message://", "Mail"),
        "com.apple.reminders": ("x-apple-reminderkit://", "Reminders"),
        "com.apple.mobilesafari": ("x-web-search://", "Safari"),
        // Messaging
        "net.whatsapp.WhatsApp": ("whatsapp://send", "WhatsApp"),
        "com.whatsapp.WhatsApp": ("whatsapp://send", "WhatsApp"),
        "net.whatsapp.WhatsAppSMB": ("whatsapp-business://", "WhatsApp Business"),
        "ph.telegra.Telegraph": ("tg://", "Telegram"),
        "org.whispersystems.signal": ("sgnl://", "Signal"),
        "com.facebook.Messenger": ("fb-messenger://", "Messenger"),
        "com.viber": ("viber://", "Viber"),
        "jp.naver.line": ("line://", "LINE"),
        "com.skype.skype": ("skype://", "Skype"),
        "com.hammerandchisel.discord": ("discord://", "Discord"),
        "com.discord.Discord": ("discord://", "Discord"),
        "com.snapchat.snapchat": ("snapchat://", "Snapchat"),
        "com.toyopagroup.picaboo": ("snapchat://", "Snapchat"),
        // Work
        "com.tinyspeck.chatlyio": ("slack://", "Slack"),
        "com.microsoft.skype.teams": ("msteams://", "Teams"),
        "com.microsoft.teams": ("msteams://", "Teams"),
        "com.microsoft.Office.Outlook": ("ms-outlook://", "Outlook"),
        "com.google.Gmail": ("googlegmail://", "Gmail"),
        "com.google.Docs": ("googledocs://", "Google Docs"),
        "notion.id": ("notion://", "Notion"),
        "us.zoom.videomeetings": ("zoomus://", "Zoom"),
        "com.linkedin.LinkedIn": ("linkedin://", "LinkedIn"),
        // Social & other
        "com.burbn.instagram": ("instagram://", "Instagram"),
        "com.atebits.Tweetie2": ("twitter://", "X"),
        "com.facebook.Facebook": ("fb://", "Facebook"),
        "com.reddit.Reddit": ("reddit://", "Reddit"),
        "com.zhiliaoapp.musically": ("snssdk1128://", "TikTok"),
        "com.openai.chat": ("chatgpt://", "ChatGPT"),
        "com.google.chrome.ios": ("googlechrome://", "Chrome"),
    ]

    private static let lowercased: [String: (url: String, name: String)] = {
        Dictionary(entries.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }()

    static func lookup(_ bundleID: String?) -> HostApp? {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let entry = entries[id] ?? lowercased[id.lowercased()],
              let url = URL(string: entry.url)
        else { return nil }
        return HostApp(url: url, name: entry.name)
    }
}

/// Sends the user back to the app they were typing in after the keyboard opened us, the way
/// Wispr Flow does on iOS 26.4+: learn the host from `HostAppObserver`, then reopen it by link.
@MainActor
final class ReturnController: ObservableObject {
    static let shared = ReturnController()

    enum Status: Equatable {
        case idle
        case returning
        /// Went back automatically.
        case returned(HostApp)
        /// Couldn't go back by ourselves; the user swipes back (or taps "Back to <App>").
        case manual(HostApp?)
    }

    @Published private(set) var status: Status = .idle

    /// How far back an observed host still counts as this handoff's, so a warm launch doesn't
    /// return to an app the user left minutes ago.
    private static let lookBack: TimeInterval = 5
    /// How long to wait for the host to show up on a cold launch.
    private static let hostWait: TimeInterval = 2
    /// The whole return must finish within this, or we show the swipe-back hint.
    private static let deadline: TimeInterval = 4.5

    private var attempt = UUID()

    /// `keyboardHost` is what the keyboard detected itself (works before iOS 26.4).
    func returnToHost(keyboardHost: String?, invokedAt: Date) {
        let attempt = UUID()
        self.attempt = attempt
        status = .returning
        let deadline = Date().addingTimeInterval(Self.deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
            guard let self, self.attempt == attempt, self.status == .returning else { return }
            DebugLog.log("return: timed out")
            self.status = .manual(nil)
        }

        if let keyboardHost, !keyboardHost.isEmpty {
            guard let host = HostAppCatalog.lookup(keyboardHost) else {
                DebugLog.log("return: \(keyboardHost) isn't in the app list")
                status = .manual(nil)
                return
            }
            open(host, attempt: attempt, deadline: deadline, retriesLeft: 4)
            return
        }

        HostAppObserver.shared.waitForHost(since: invokedAt.addingTimeInterval(-Self.lookBack), timeout: Self.hostWait) { [weak self] bundle in
            Task { @MainActor in
                guard let self, self.attempt == attempt else { return }
                guard let bundle else {
                    DebugLog.log("return: couldn't tell which app you came from")
                    self.status = .manual(nil)
                    return
                }
                guard let host = HostAppCatalog.lookup(bundle) else {
                    DebugLog.log("return: \(bundle) isn't in the app list")
                    self.status = .manual(nil)
                    return
                }
                self.open(host, attempt: attempt, deadline: deadline, retriesLeft: 4)
            }
        }
    }

    /// The "Back to <App>" button.
    func reopen(_ host: HostApp) {
        UIApplication.shared.open(host.url)
    }

    func reset() {
        attempt = UUID()
        status = .idle
    }

    private func open(_ host: HostApp, attempt: UUID, deadline: Date, retriesLeft: Int) {
        guard self.attempt == attempt else { return }
        // On a cold launch `open` can fail while we're still becoming active; that's worth a
        // retry. A failure while active means the user cancelled iOS's "Open <App>?" prompt.
        let wasActive = UIApplication.shared.applicationState == .active
        UIApplication.shared.open(host.url) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.attempt == attempt else { return }
                if opened {
                    DebugLog.log("return: opened \(host.name)")
                    self.status = .returned(host)
                } else if !wasActive, retriesLeft > 0, Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.open(host, attempt: attempt, deadline: deadline, retriesLeft: retriesLeft - 1)
                    }
                } else {
                    DebugLog.log("return: couldn't open \(host.name)")
                    self.status = .manual(host)
                }
            }
        }
    }
}
