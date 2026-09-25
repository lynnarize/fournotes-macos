import AppKit
import SwiftUI

// One provider slot in Settings → AI & API keys: the model server on this
// Mac (LM Studio, Ollama), or the cloud's Other tab (OpenAI, Groq, Gemini, any
// OpenAI-compatible API; OpenRouter and OpenCode have tabs of their own, see
// CloudSettings). The key goes in the Keychain; choice, address and model are
// ordinary settings. The engine re-reads them on save.

struct ProviderSlotEditor: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var engine: AIEngine
    @ObservedObject private var servers = LocalServers.shared

    let slot: AIProvider.Slot
    /// Told when the provider or its key changes.
    var onChange: () -> Void = {}

    @State private var providerId = ""
    @State private var base = ""
    @State private var model = ""
    @State private var status: String?
    @State private var models: [String] = []

    private var chosen: AIProvider? { AIProvider.find(providerId) }
    private var title: String { slot == .local ? "Model server" : "Provider" }
    /// The cloud's Other tab leaves out the providers with tabs of their own.
    private var choices: [AIProvider] { AIProvider.all(in: slot).filter { !$0.hasOwnTab } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if slot == .local {
                detected
            }
            labelled(slot == .local ? "Or choose by hand" : title) {
                TextMenu(title: chosen?.name ?? "None", help: "Choose a \(title.lowercased())") {
                    [.item("None", checked: chosen == nil) { choose(nil) }, .divider]
                        + choices.map { provider in
                            .item(provider.name, checked: provider.id == providerId) { choose(provider) }
                        }
                }
            }

            if let chosen {
                labelled("Address") {
                    BoxedField(placeholder: chosen.baseURL.isEmpty ? "https://example.com/v1" : chosen.baseURL,
                               text: $base) { save() }
                }
                if let keyItem = slot.keyItem {
                    KeyField(item: keyItem) {
                        engine.refresh()
                        onChange()
                    }
                }
                labelled("Model") {
                    HStack(spacing: 8) {
                        BoxedField(placeholder: chosen.modelHint, text: $model) { save() }
                        if !models.isEmpty {
                            TextMenu(title: "Choose", help: "Models \(chosen.name) offers") { modelEntries }
                        }
                    }
                }
                HStack(spacing: 8) {
                    SecondaryButton(title: "Save") { save() }
                    SecondaryButton(title: "Test") { Task { await test() } }
                    if let page = chosen.keyPage, let url = URL(string: page) {
                        Button("Get a \(chosen.name) key") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.fn)
                            .font(FN.small)
                            .foregroundStyle(p.accent)
                            .padding(.leading, 4)
                    }
                }
                if let status {
                    Text(status).font(FN.small).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
        }
        .animation(Motion.standard, value: status)
        .animation(Motion.standard, value: providerId)
        .animation(Motion.standard, value: servers.status)
        .onAppear(perform: load)
        .task { if slot == .local { await servers.refresh() } }
    }

    // MARK: - Found on this Mac

    /// LM Studio and Ollama, as found: running or not, with Use, Start and Stop.
    @ViewBuilder
    private var detected: some View {
        let found = LocalServers.Kind.allCases.filter {
            servers.status[$0]?.installed == true || servers.status[$0]?.running == true
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Found on this Mac").font(FN.small).foregroundStyle(p.muted)
            if found.isEmpty {
                Text(servers.status.isEmpty ? "Looking…"
                     : "No model server found. LM Studio and Ollama are free to install.")
                    .font(FN.small).foregroundStyle(p.faint)
                if !servers.status.isEmpty {
                    HStack(spacing: 12) {
                        linkButton("Get LM Studio", "https://lmstudio.ai")
                        linkButton("Get Ollama", "https://ollama.com")
                    }
                }
            }
            ForEach(found) { kind in serverRow(kind) }
            if let error = servers.lastError {
                Text(error).font(FN.small).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func serverRow(_ kind: LocalServers.Kind) -> some View {
        let state = servers.status[kind] ?? .init()
        let inUse = providerId == kind.providerId
        let working = servers.working.contains(kind)
        return HStack(spacing: 10) {
            Circle()
                .fill(state.running ? p.ok : p.faint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.name).font(FN.bodyMedium).foregroundStyle(p.text)
                Text(working ? (state.running ? "Stopping…" : "Starting…")
                     : state.running ? "Running · \(state.models.count) model\(state.models.count == 1 ? "" : "s")"
                     : "Stopped")
                    .font(FN.small).foregroundStyle(p.muted)
            }
            Spacer(minLength: 8)
            if inUse {
                StatusPill(text: "In use", tone: .good, dot: false)
            } else if state.running, !state.models.isEmpty {
                SecondaryButton(title: "Use") { use(kind) }
            }
            SecondaryButton(title: state.running ? "Stop" : "Start") {
                Task { state.running ? await servers.stop(kind) : await servers.start(kind) }
            }
            .disabled(working)
            .opacity(working ? 0.5 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func linkButton(_ title: String, _ address: String) -> some View {
        Button(title) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
            .buttonStyle(.fn)
            .font(FN.small)
            .foregroundStyle(p.accent)
    }

    /// Fills in the server, its address and a chat model — no typing.
    private func use(_ kind: LocalServers.Kind) {
        guard let provider = AIProvider.find(kind.providerId) else { return }
        choose(provider)
        let models = servers.status[kind]?.models ?? []
        // A reading model (OCR) can't hold a conversation; prefer one that can.
        model = models.first { !$0.localizedCaseInsensitiveContains("ocr") } ?? models.first ?? ""
        self.models = models
        save()
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(FN.small).foregroundStyle(p.muted)
            content()
        }
    }

    /// The fetched list, narrowed by what is typed in the model field.
    private var modelEntries: [MenuEntry] {
        let typed = model.trimmingCharacters(in: .whitespaces)
        let matching = typed.isEmpty || models.contains(typed)
            ? models
            : models.filter { $0.localizedCaseInsensitiveContains(typed) }
        return matching.prefix(60).map { id in
            .item(id, checked: id == model) {
                model = id
                save()
            }
        }
    }

    private func load() {
        providerId = Keychain.read(slot.idItem) ?? ""
        if chosen?.hasOwnTab == true { providerId = "" }
        base = Keychain.read(slot.baseURLItem).flatMap { $0.isEmpty ? nil : $0 } ?? chosen?.baseURL ?? ""
        model = Keychain.read(slot.modelItem) ?? ""
    }

    private func choose(_ provider: AIProvider?) {
        let changed = provider?.id != providerId
        providerId = provider?.id ?? ""
        base = provider?.baseURL ?? ""
        if changed {
            model = ""
            models = []
            // A key belongs to one provider.
            if let keyItem = slot.keyItem { Keychain.write(keyItem, nil) }
        }
        status = nil
        save(quietly: true)
        if changed { onChange() }
    }

    private func save(quietly: Bool = false) {
        Keychain.write(slot.idItem, providerId.isEmpty ? nil : providerId)
        let address = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // The preset's own address is not stored, so it can be corrected in an update.
        Keychain.write(slot.baseURLItem, address.isEmpty || address == chosen?.baseURL ? nil : address)
        Keychain.write(slot.modelItem, model.trimmingCharacters(in: .whitespaces))
        engine.refresh()
        guard !quietly, let chosen else { return }
        if let missing = missingPiece {
            status = "Saved. \(missing)"
        } else if slot == .local {
            status = engine.priority == .localFirst
                ? "Saved · \(chosen.shortName) answers first, on this Mac."
                : "Saved · \(chosen.shortName) answers when the cloud can't."
        } else if let first = engine.cloudTabs.first, first != .other {
            status = "Saved · \(first.label) is asked first; \(chosen.shortName) steps in when it can't answer."
        } else {
            status = engine.priority == .localFirst
                ? "Saved · used when you tap “Ask \(engine.cloudOffer ?? chosen.shortName)”, or when this Mac has no model."
                : "Saved · \(chosen.shortName) answers first."
        }
    }

    /// What still stops the provider from being used.
    private var missingPiece: String? {
        guard let chosen else { return nil }
        if chosen.needsKey, let keyItem = slot.keyItem, Keychain.read(keyItem)?.isEmpty != false {
            return "Add your \(chosen.name) key to use it."
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model to use it." }
        return nil
    }

    private func test() async {
        guard let chosen else { return }
        save(quietly: true)
        status = "Checking…"
        let client = OpenAICompatibleClient(
            provider: chosen,
            baseURL: base.isEmpty ? chosen.baseURL : base,
            apiKey: slot.keyItem.flatMap(Keychain.read),
            model: model)
        do {
            let found = try await client.listModels()
            models = found
            let current = model.trimmingCharacters(in: .whitespaces)
            var line = "Connected to \(chosen.shortName) · \(found.count) models"
            if current.isEmpty {
                line += " · choose one with Choose"
            } else if !found.isEmpty, !found.contains(current) {
                line += " · “\(current)” isn't one of them"
            } else {
                line += " · using \(current)"
            }
            status = line
        } catch {
            status = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
