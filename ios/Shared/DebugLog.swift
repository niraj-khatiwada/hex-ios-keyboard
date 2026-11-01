import Foundation

/// Appends timestamped lines to `debug.log` in the App Group so the keyboard and the app
/// write one shared timeline. Pull it from the Mac with:
/// xcrun devicectl device copy from --device <id> --domain-type appGroupDataContainer \
///   --domain-identifier group.com.niraj.voicekeyboard --source Library/debug.log --destination debug.log
enum DebugLog {
    private static let process = Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") == true ? "kbd" : "app"
    private static let queue = DispatchQueue(label: "DebugLog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(process)] \(message)"
        print(line)
        queue.async {
            guard let url = AppGroup.containerURL?.appendingPathComponent("Library/debug.log"),
                  let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
