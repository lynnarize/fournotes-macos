import AppKit
import SwiftUI

// "A new version is available": what's new, and a button that downloads the disk image
// and opens it. Shown once a launch when the daily check finds a release, and from
// Settings → About or Four Notes → Check for Updates…. The app is sandboxed and can't
// swap itself out, so the last step is the familiar one: drag the new app over the old
// one in Applications, with a button to quit this copy first.

struct UpdateSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeModal) private var closeModal
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(FN.font(18, .medium))
                        .foregroundStyle(p.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(FN.font(13))
                        .foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                IconButton("x", size: 16, box: 30, help: "Close", action: close)
            }
            .padding(.bottom, 18)

            if let notes = updates.available?.notes {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("What's new")
                    ScrollView {
                        Text(notes)
                            .font(FN.font(13))
                            .lineSpacing(4)
                            .foregroundStyle(p.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(p.surfaceMuted, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
                }
                .padding(.bottom, 18)
            }

            progress

            HStack(spacing: 8) {
                actions
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 480)
        .animation(Motion.standard, value: updates.download)
    }

    // MARK: - Words

    private var version: String { updates.available?.version ?? "" }

    private var title: String {
        if case .opened = updates.download { return "Almost there" }
        return "Four Notes \(version) is available"
    }

    private var subtitle: String {
        if case .opened = updates.download {
            return "In the window that opened, drag Four Notes to Applications and replace the old copy. Quit this one first so it can be replaced, then open the new one."
        }
        return "You have \(AppVersion.marketing). Your notes, tasks and spending stay as they are."
    }

    // MARK: - Progress

    @ViewBuilder
    private var progress: some View {
        switch updates.download {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressBar(ratio: fraction, tone: p.accent)
                Text(fraction > 0 ? "Downloading… \(Int(fraction * 100))%" : "Downloading…")
                    .font(FN.small)
                    .monospacedDigit()
                    .foregroundStyle(p.textMuted)
            }
            .transition(.opacity)
        case .opened(let file):
            HStack(spacing: 8) {
                Icon("check", size: 14).foregroundStyle(p.success)
                Text("Saved to \(file.deletingLastPathComponent().lastPathComponent)").foregroundStyle(p.textSecondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.fn)
                    .foregroundStyle(p.foreground)
                    .underline()
            }
            .font(FN.small)
            .transition(.opacity)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Icon("warning", size: 14).foregroundStyle(p.danger)
                Text(message).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
            }
            .font(FN.small)
            .transition(.opacity)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        switch updates.download {
        case .opened:
            GhostButton(action: { if let page = updates.available?.page { NSWorkspace.shared.open(page) } }) {
                Text("Release page")
            }
            Spacer()
            SecondaryButton(title: "Not now", action: close)
            PrimaryButton(title: "Quit Four Notes") { NSApp.terminate(nil) }
        case .downloading:
            Spacer()
            SecondaryButton(title: "Cancel") { updates.cancelDownload() }
        case .idle, .failed:
            GhostButton(action: {
                updates.skip()
                close()
            }) { Text("Skip this version") }
            Spacer()
            SecondaryButton(title: "Later", action: close)
            PrimaryButton(title: updates.available?.download == nil ? "Open release page" : "Download and install",
                          icon: "download") { updates.downloadAndOpen() }
        }
    }

    private func close() {
        if case .downloading = updates.download { updates.cancelDownload() }
        if let closeModal { closeModal() } else { dismiss() }
    }
}
