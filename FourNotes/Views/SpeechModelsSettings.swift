import AppKit
import SwiftUI

// Settings → AI & API keys → Speech models: download Whisper and the speaker model
// inside the app, watch it come in (size, speed, time left), pause, resume, cancel,
// and delete it again. See Services/SpeechModels.swift.

struct SpeechModelsSettings: View {
    @ObservedObject private var models = SpeechModels.shared
    @Environment(\.palette) private var p
    @State private var confirmDelete: SpeechModels.Pack?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribe recordings on this Mac with Whisper, and tell who said what. Downloaded once from Hugging Face, then they work offline and nothing you record leaves this Mac.")
                .font(FN.small).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(SpeechModels.packs) { pack in
                PackRow(pack: pack, status: models.status(pack), confirmDelete: $confirmDelete)
                if pack.id != SpeechModels.packs.last?.id { Divider().overlay(p.line) }
            }

            if models.isInstalled(SpeechModels.whisper) {
                Divider().overlay(p.line)
                Toggle(isOn: $models.useForRecordings) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Whisper for recordings").font(FN.body).foregroundStyle(p.text)
                        Text(models.useForRecordings
                             ? "Recordings are transcribed with Whisper\(models.isInstalled(SpeechModels.speakers) ? ", speakers told apart" : ""). Apple's recognizer still shows the words live."
                             : "Apple's speech recognizer transcribes recordings.")
                            .font(FN.small).foregroundStyle(p.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "this model")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pack = confirmDelete { models.delete(pack) }
                confirmDelete = nil
            }
            Button("Keep it", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("It's removed from this Mac and frees \(SpeechModels.size(confirmDelete.map { models.status($0).total ?? $0.approxBytes } ?? 0)). You can download it again any time.")
        }
    }
}

private struct PackRow: View {
    @ObservedObject private var models = SpeechModels.shared
    @Environment(\.palette) private var p
    let pack: SpeechModels.Pack
    let status: SpeechModels.Status
    @Binding var confirmDelete: SpeechModels.Pack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Icon(pack.icon, size: 15).foregroundStyle(p.accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pack.name).font(FN.bodyMedium).foregroundStyle(p.text)
                        if status.phase == .installed {
                            Text("Installed").font(FN.tiny).foregroundStyle(p.success)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(p.successSubtle, in: Capsule())
                        }
                    }
                    Text("\(pack.detail) \(SpeechModels.size(status.total ?? pack.approxBytes)).")
                        .font(FN.small).foregroundStyle(p.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                buttons
            }

            if showsProgress {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressBar(ratio: status.phase == .verifying || status.phase == .preparing ? 1 : status.fraction,
                                tone: status.phase == .paused ? p.textMuted : p.accent)
                    Text(progressLine)
                        .font(FN.small).monospacedDigit().foregroundStyle(p.textMuted)
                        .accessibilityLabel(progressLine)
                }
                .padding(.leading, 25)
                .transition(.opacity)
            }

            if case .failed(let message) = status.phase {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Icon("warning", size: 13).foregroundStyle(p.danger)
                    Text(message).font(FN.small).foregroundStyle(p.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 25)
            }
        }
        .animation(Motion.standard, value: status.phase)
    }

    private var showsProgress: Bool {
        switch status.phase {
        case .listing, .downloading, .paused, .verifying, .preparing: return true
        case .failed: return status.received > 0
        case .notInstalled, .installed: return false
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch status.phase {
            case .notInstalled:
                PrimaryButton(title: "Download", icon: "download") { models.download(pack) }
            case .listing, .downloading:
                SecondaryButton(title: "Pause") { models.pause(pack) }
                GhostButton(action: { models.cancel(pack) }) { Text("Cancel") }
            case .paused:
                PrimaryButton(title: "Resume") { models.download(pack) }
                GhostButton(action: { models.cancel(pack) }) { Text("Cancel") }
            case .failed:
                PrimaryButton(title: status.received > 0 ? "Resume" : "Try again") { models.download(pack) }
                GhostButton(action: { models.cancel(pack) }) { Text("Cancel") }
            case .verifying, .preparing:
                EmptyView()
            case .installed:
                GhostButton(action: { NSWorkspace.shared.activateFileViewerSelecting([models.folder(pack)]) }) { Text("Show in Finder") }
                SecondaryButton(title: "Delete") { confirmDelete = pack }
            }
        }
        .fixedSize()
    }

    /// "42% · 263 MB of 627 MB · 12 MB/s · about 1 min left"
    private var progressLine: String {
        switch status.phase {
        case .listing: return "Getting the file list from Hugging Face…"
        case .verifying: return "Checking the files…"
        case .preparing: return "Getting it ready for this Mac (first time only, a minute or two)…"
        default: break
        }
        let total = status.total ?? pack.approxBytes
        var parts = ["\(Int(status.fraction * 100))%", "\(SpeechModels.size(status.received)) of \(SpeechModels.size(total))"]
        if status.phase == .paused { return "Paused · " + parts.joined(separator: " · ") }
        if let rate = status.rate, rate > 0 {
            parts.append("\(SpeechModels.size(Int64(rate)))/s")
            if let left = timeLeft(seconds: Double(total - status.received) / rate) { parts.append(left) }
        }
        return parts.joined(separator: " · ")
    }

    private func timeLeft(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "less than a minute left" }
        if seconds < 3600 { return "about \(Int((seconds / 60).rounded())) min left" }
        return "about \(Int(seconds / 3600)) h \(Int((seconds.truncatingRemainder(dividingBy: 3600) / 60).rounded())) min left"
    }
}
