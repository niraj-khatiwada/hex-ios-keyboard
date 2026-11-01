import SwiftUI

/// Everything you've dictated, newest first. Text only; the audio stays on the Mac.
struct HistoryView: View {
    @EnvironmentObject private var mac: MacConnection
    @State private var search = ""
    @State private var copiedID: String?

    private var items: [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return mac.history }
        return mac.history.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let error = mac.historyError, mac.history.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(items) { item in
                row(item)
                    .swipeActions(edge: .trailing) {
                        if !item.text.isEmpty {
                            Button { copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .tint(.accentColor)
                        }
                    }
                    .contextMenu {
                        if !item.text.isEmpty {
                            Button { copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                    }
            }
        }
        .overlay {
            if mac.historyLoading && mac.history.isEmpty {
                ProgressView("Loading history…")
            } else if items.isEmpty && mac.historyError == nil {
                if search.isEmpty {
                    ContentUnavailableView("No dictations yet", systemImage: "mic",
                                           description: Text("What you dictate shows up here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search what you've dictated")
        .refreshable { await mac.loadHistory() }
        .task { await mac.loadHistory() }
    }

    private func row(_ item: HistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = item.error {
                    Text("Failed: \(error)").foregroundStyle(.red)
                } else if item.text.isEmpty {
                    Text("No speech").italic().foregroundStyle(.secondary)
                } else {
                    Text(item.text).textSelection(.enabled)
                }
                Text(item.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.text.isEmpty {
                Button { copy(item) } label: {
                    Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy")
            }
        }
        .padding(.vertical, 2)
    }

    private func copy(_ item: HistoryItem) {
        UIPasteboard.general.string = item.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copiedID = item.id }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == item.id { withAnimation { copiedID = nil } }
        }
    }
}
