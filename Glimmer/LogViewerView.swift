//
//  LogViewerView.swift
//
//  The Troubleshooting log viewer — renders LogStore's in-app ring buffer
//  live, with a level filter, copy, and clear. Split out of
//  TroubleshootingPane.swift.
//

import AppKit
import SwiftUI

struct LogViewer: View {
    @State private var entries: [LogEntry] = []
    @State private var minimumLevel: LogLevel = .info
    // Refresh from the store on a gentle cadence so the log is live while open,
    // WITHOUT wrapping the buttons in a TimelineView (that churns their
    // accessibility modifiers and crashed SwiftUI). The buttons stay stable;
    // only the entries array changes.
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Level", selection: $minimumLevel) {
                    Text("All").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Notice").tag(LogLevel.notice)
                    Text("Warn").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy shown entries").disabled(visible.isEmpty)
                Button { LogStore.shared.clear(); reload() } label: { Image(systemName: "trash") }
                    .help("Clear log").disabled(entries.isEmpty)
            }

            if visible.isEmpty {
                Text("No log entries at this level yet. Start a stream and they'll appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { LogRow(entry: $0) }
                    }
                    .textSelection(.enabled)
                }
                .frame(height: 260)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private var visible: [LogEntry] {
        entries.filter { $0.level >= minimumLevel }
    }

    /// Pull the latest snapshot, but only re-render when it actually changed
    /// (cheap id/count compare) so the 1 Hz timer doesn't churn the view.
    private func reload() {
        let snap = LogStore.shared.snapshot()
        if snap.count != entries.count || snap.last?.id != entries.last?.id {
            entries = snap
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visible.map(\.plain).joined(separator: "\n"), forType: .string)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timeString)
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            Text(entry.category)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading).lineLimit(1)
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
    }

    private var color: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info, .notice: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
