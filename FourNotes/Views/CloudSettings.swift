import AppKit
import SwiftUI

// Settings → AI & API keys → In the cloud: one tab per provider, as on the web
// (src/components/ApiKeysSection.tsx). OpenRouter's free models come first:
// one free key and the app is fully working. The same key can switch to paid
// models; OpenCode (Zen's free models, or a Go subscription), Claude and any
// other OpenAI-compatible provider are the alternatives. Each tab keeps its
// own key, and the one picked with "Ask this first" answers first.

struct CloudProviderTabs<Claude: View>: View {
    typealias Tab = CloudProviders.Tab

    @Environment(\.palette) private var p
    @EnvironmentObject private var engine: AIEngine
    @ViewBuilder let claude: () -> Claude

    @State private var tab: Tab = .openrouter
    /// Tabs with a key saved, re-read when a key changes rather than on every draw.
    @State private var keyed: Set<Tab> = []

    @State private var orPaid = false
    @State private var orFreeModel = ""
    @State private var orPaidModel = ""
    @State private var paidModels: [OpenRouterModels.PaidModel]?
    @State private var paidError = false

    @State private var ocTier: OpenCodeModels.Tier = .free
    @State private var ocModel = ""

    @State private var results: [Tab: (ok: Bool, message: String)] = [:]
    @State private var testing: Tab?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            VStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .openrouter: openRouter
                case .opencode: openCode
                case .anthropic:
                    claude()
                    useFirst(.anthropic)
                case .other:
                    ProviderSlotEditor(slot: .cloud, onChange: keysChanged)
                    useFirst(.other)
                }
            }
            .animation(Motion.standard, value: tab)
        }
        .onAppear(perform: load)
        // A key saved on the Claude tab, or on Other, is only seen by the engine.
        .onChange(of: engine.revision) { refreshKeyed() }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                let on = tab == t
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Text(t.label)
                        if keyed.contains(t) {
                            Circle()
                                .fill(engine.cloudTabs.first == t ? p.ok : p.faint)
                                .frame(width: 6, height: 6)
                                .help(engine.cloudTabs.first == t ? "Key saved · asked first" : "Key saved")
                        }
                    }
                    .font(FN.font(12, on ? .semibold : .regular))
                    .foregroundStyle(on ? p.text : p.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(on ? p.text : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }

    // MARK: - OpenRouter

    @ViewBuilder
    private var openRouter: some View {
        header(badge: orPaid ? "Paid" : "Free", tone: orPaid ? p.accent : p.ok,
               title: "OpenRouter",
               link: orPaid ? ("Add credits", OpenRouterModels.creditsPage) : ("Get a free key", OpenRouterModels.keysPage))
        KeyField(item: .openrouterKey, onChange: keysChanged)
        HStack(spacing: 8) {
            tierSwitch(paid: orPaid, paidLabel: "Paid") { paid in
                orPaid = paid
                Keychain.write(.openrouterTier, paid ? "paid" : nil)
                saved(.openrouter)
            }
            if orPaid {
                BoxedField(placeholder: paidModels != nil ? "Search, e.g. claude, gpt, gemini"
                               : paidError ? "Model id, e.g. provider/model" : "Loading models…",
                           text: $orPaidModel) { pickPaid(orPaidModel) }
                if let paidModels, !paidModels.isEmpty {
                    TextMenu(title: "Choose", help: "OpenRouter's paid models") { paidEntries(paidModels) }
                }
            } else {
                TextMenu(title: freeLabel, help: "OpenRouter's tested free models") {
                    OpenRouterModels.free.map { m in
                        .item(m.menuLabel, checked: m.id == orFreeModel) {
                            orFreeModel = m.id
                            Keychain.write(.openrouterModel, m.id)
                            saved(.openrouter)
                        }
                    }
                }
            }
        }
        hint(orPaid ? paidHint : freeHint)
        if orPaid, !OpenRouterModels.isModelId(orPaidModel) {
            Text("Pick a paid model, or switch back to Free. Until then a free model answers.")
                .font(FN.small).foregroundStyle(p.danger)
        }
        testRow(.openrouter)
        useFirst(.openrouter)
    }

    private var freeLabel: String {
        OpenRouterModels.free.first { $0.id == orFreeModel }?.label
            ?? OpenRouterModels.free.first?.label ?? "Default"
    }

    private var paidInfo: OpenRouterModels.PaidModel? { paidModels?.first { $0.id == orPaidModel } }

    private var freeHint: String {
        let tested = OpenRouterModels.checkedAt
            .map { " (tested \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
        return "Free, with daily limits. Only models that correctly file to-dos and transactions are listed"
            + tested + "; if one is busy, the next is tried."
    }

    private var paidHint: String {
        var line = ""
        if let m = paidInfo {
            line = "\(m.name): \(OpenRouterModels.perMillion(m.prompt)) / \(OpenRouterModels.perMillion(m.completion)) "
                + "per 1M tokens in / out"
                + (m.context > 0 ? ", \(m.context / 1000)K context" : "")
                + (m.vision ? ", reads photos. " : ", text only. ")
        }
        return line + "Billed to your OpenRouter credits, no daily limit. Used for every AI feature"
            + (paidInfo?.vision == false ? " except photos, which go to a free model that reads them." : ".")
    }

    /// The paid list, narrowed by what is typed in the model field.
    private func paidEntries(_ all: [OpenRouterModels.PaidModel]) -> [MenuEntry] {
        let typed = orPaidModel.trimmingCharacters(in: .whitespaces)
        let matching = typed.isEmpty || all.contains(where: { $0.id == typed })
            ? all
            : all.filter { $0.id.localizedCaseInsensitiveContains(typed) || $0.name.localizedCaseInsensitiveContains(typed) }
        return matching.prefix(60).map { m in
            .item(m.menuLabel, checked: m.id == orPaidModel) { pickPaid(m.id) }
        }
    }

    private func pickPaid(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces)
        orPaidModel = id
        Keychain.write(.openrouterPaidModel, id.isEmpty ? nil : id)
        // Unknown models are assumed to read photos.
        let known = paidModels?.first { $0.id == id }
        Keychain.write(.openrouterPaidTextOnly, known.map { $0.vision ? nil : "1" } ?? nil)
        saved(.openrouter)
    }

    /// The paid list is long and changes often: loaded live, only once Paid is picked.
    private func loadPaidModels() async {
        guard paidModels == nil else { return }
        do {
            let list = try await OpenRouterModels.paid()
            paidModels = list
            paidError = list.isEmpty
        } catch {
            paidError = true
        }
    }

    // MARK: - OpenCode

    @ViewBuilder
    private var openCode: some View {
        let go = ocTier == .go
        header(badge: go ? "Go" : "Free", tone: go ? p.accent : p.ok,
               title: "OpenCode",
               link: go ? ("Subscribe to Go", OpenCodeModels.goPage) : ("Get a key", OpenCodeModels.keysPage))
        KeyField(item: .opencodeKey, onChange: keysChanged)
        HStack(spacing: 8) {
            tierSwitch(paid: go, paidLabel: "Go") { paid in
                ocTier = paid ? .go : .free
                Keychain.write(.opencodeTier, paid ? OpenCodeModels.Tier.go.rawValue : nil)
                ocModel = CloudProviders.openCodeModel
                saved(.opencode)
            }
            TextMenu(title: OpenCodeModels.label(ocModel, tier: ocTier), help: "OpenCode models") {
                OpenCodeModels.models(ocTier).map { m in
                    .item(m.menuLabel, checked: m.id == ocModel) {
                        ocModel = m.id
                        Keychain.write(ocTier == .go ? .opencodeGoModel : .opencodeModel, m.id)
                        saved(.opencode)
                    }
                }
            }
        }
        hint(go
             ? "Uses your OpenCode Go subscription ($10/month) with its 5-hour, weekly and monthly limits. Photos go to DeepSeek V4 Flash Vision, included in Go."
             : "OpenCode Zen's free models. They may use your prompts to improve the model. Photos go to DeepSeek V4 Flash Vision, which needs a Zen balance.")
        testRow(.opencode)
        useFirst(.opencode)
    }

    // MARK: - Pieces

    private func header(badge: String, tone: Color, title: String, link: (String, String)) -> some View {
        HStack(spacing: 8) {
            Text(badge.uppercased())
                .font(FN.font(10, .semibold))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tone, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(title).font(FN.bodyMedium).foregroundStyle(p.text)
            Spacer(minLength: 8)
            Button("\(link.0) ↗") { if let url = URL(string: link.1) { NSWorkspace.shared.open(url) } }
                .buttonStyle(.fn)
                .font(FN.small)
                .foregroundStyle(p.accent)
        }
    }

    private func tierSwitch(paid: Bool, paidLabel: String, onPick: @escaping (Bool) -> Void) -> some View {
        SegmentedTabs(items: [("free", "Free"), ("paid", paidLabel)],
                      selection: Binding(get: { paid ? "paid" : "free" }, set: { onPick($0 == "paid") }))
            .fixedSize()
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(FN.small).foregroundStyle(p.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func testRow(_ t: Tab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SecondaryButton(title: testing == t ? "Testing…" : "Test") { Task { await test(t) } }
                .disabled(testing != nil || !keyed.contains(t))
                .opacity(testing != nil || !keyed.contains(t) ? 0.5 : 1)
            if let r = results[t] {
                Text("\(r.ok ? "✓" : "✗") \(r.message)")
                    .font(FN.small)
                    .foregroundStyle(r.ok ? p.ok : p.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(Motion.standard, value: results[t]?.message)
    }

    /// Only worth showing once there's a choice to make.
    @ViewBuilder
    private func useFirst(_ t: Tab) -> some View {
        let ready = engine.cloudTabs
        if ready.count > 1, ready.contains(t) {
            if ready.first == t {
                Text("✓ Asked first in the cloud").font(FN.small).foregroundStyle(p.ok)
            } else if let first = ready.first {
                Button("Ask this first, instead of \(first.label)") {
                    CloudProviders.prefer(t)
                    engine.refresh()
                }
                .buttonStyle(.fn)
                .font(FN.small)
                .foregroundStyle(p.accent)
            }
        }
    }

    // MARK: - State

    private func load() {
        orPaid = CloudProviders.openRouterPaid
        orFreeModel = Keychain.read(.openrouterModel) ?? OpenRouterModels.defaultModel
        orPaidModel = Keychain.read(.openrouterPaidModel) ?? ""
        ocTier = CloudProviders.openCodeTier
        ocModel = CloudProviders.openCodeModel
        refreshKeyed()
        // Open on the provider asked first.
        if let first = engine.cloudTabs.first { tab = first }
        if orPaid { Task { await loadPaidModels() } }
    }

    private func refreshKeyed() {
        keyed = Set(Tab.allCases.filter(CloudProviders.hasKey))
    }

    private func keysChanged() {
        refreshKeyed()
        results = [:]
        engine.refresh()
    }

    private func saved(_ t: Tab) {
        results[t] = nil
        engine.refresh()
        if t == .openrouter, orPaid { Task { await loadPaidModels() } }
    }

    private func test(_ t: Tab) async {
        let client = t == .openrouter ? CloudProviders.openRouter() : CloudProviders.openCode()
        guard let client else { return }
        testing = t
        defer { testing = nil }
        let label = t == .openrouter
            ? (orPaid && OpenRouterModels.isModelId(orPaidModel) ? orPaidModel : freeLabel)
            : OpenCodeModels.label(ocModel, tier: ocTier)
        results[t] = await client.checkKey(modelLabel: label)
    }
}
