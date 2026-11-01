import Foundation

/// Cross-process signals between the keyboard and the app. Darwin notifications carry no payload.
final class DarwinNotifications {
    static let shared = DarwinNotifications()

    private var handlers: [String: () -> Void] = [:]
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    func post(_ command: Command) {
        CFNotificationCenterPostNotification(center, CFNotificationName(command.rawValue as CFString), nil, nil, true)
    }

    func observe(_ command: Command, handler: @escaping () -> Void) {
        let name = command.rawValue
        if handlers[name] == nil {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer, let name = name?.rawValue as String? else { return }
                    let me = Unmanaged<DarwinNotifications>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { me.handlers[name]?() }
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
        handlers[name] = handler
    }
}
