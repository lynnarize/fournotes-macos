import AppKit
import SwiftUI

// The Privacy Policy and Terms of Service for the Mac app. Written for this
// app, not copied from the web app's pages: no Google sign-in, no Drive sync,
// no Four Notes server. Checked against the code — Store/Persistence,
// Store/Attachments, Services/Keychain, AI/AIEngine, AI/AIProvider,
// Services/QuickTranscriber, Services/Assistant, Services/UpdateCheck. When
// what leaves the Mac changes, change this too, and bump `lastUpdated`.

enum LegalDocument: String, Identifiable, CaseIterable {
    case privacy, terms

    var id: String { rawValue }

    static let contact = "lynnarize@gmail.com"
    static let lastUpdated = "September 25, 2026"

    var title: String { self == .privacy ? "Privacy Policy" : "Terms of Service" }

    enum Block {
        case p(String), callout(String), h2(String), h3(String), list([String])
    }

    // Markdown: **bold**, *italic*, `code`, [links](…).
    var blocks: [Block] {
        switch self {
        case .privacy: return Self.privacyBlocks
        case .terms: return Self.termsBlocks
        }
    }

    private static let privacyBlocks: [Block] = [
        .p("This policy covers Four Notes for Mac (“the app”, “we”): a notes, to-do and spending app with an optional AI assistant. It explains what the app keeps, what can leave your Mac and when, and how to remove it. We don’t sell your information, show ads, or use analytics, tracking or crash-reporting tools."),
        .callout("**In short:** everything you create stays in a file on this Mac. There is no Four Notes account and no Four Notes server. Something leaves your Mac only when you use a cloud AI model you set up yourself, look up an exchange rate, or check for updates."),

        .h2("1. What stays on your Mac"),
        .list([
            "**Your content** — notes, to-dos, transactions, budgets, categories, sticky notes and settings — is saved in one file in the app’s own folder on this Mac. Settings → Data & privacy → *Show data file* shows where.",
            "**Images** you scan or add to notes are saved beside it, in the same folder.",
            "**API keys** and provider settings are kept in the macOS Keychain. They are never written to the data file or to a backup.",
            "**Small preferences** such as the theme and Edge Dock layout are kept in the app’s standard macOS preferences.",
        ]),
        .p("We have no copy of any of this and can’t see it. The app has no sign-in, and nothing is synced to a cloud by Four Notes. If you back up your Mac (for example with Time Machine or iCloud), the data file is included like any other file, under that service’s terms."),

        .h2("2. Things done on this Mac"),
        .list([
            "**Reading text from photos** uses Apple’s Vision framework, on this Mac.",
            "**Voice notes and dictation** use Apple’s speech recognition. Where your Mac supports it, the app requires recognition to happen on the Mac. For languages your Mac can’t transcribe itself, macOS may send the audio to Apple to transcribe, under [Apple’s privacy policy](https://www.apple.com/legal/privacy/). The recording itself is never sent to an AI provider.",
            "**Apple Intelligence**, if your Mac has it, answers on the Mac.",
            "**LM Studio or Ollama**, if you use one, runs on this Mac; the app talks to it at `localhost`.",
            "Reminders are local notifications scheduled on this Mac.",
        ]),

        .h2("3. Cloud AI models (only if you set one up)"),
        .p("You can add a cloud provider in Settings → AI & API keys — Anthropic, OpenRouter, OpenAI, Groq, Google Gemini, or another OpenAI-compatible service — with your own key. Requests go **straight from this Mac to that provider**; there is no Four Notes server in between. With the default *This Mac first* setting, the cloud model is asked only when you choose *Ask …* under a reply."),
        .p("When a cloud model is used, the app sends what that request needs:"),
        .list([
            "**Chat** — your message and a short summary of your data so it can answer: recent note titles and snippets, notes related to your question, your tasks, recent spending, budgets and categories, and your time zone and currency.",
            "**Daily brief and monthly review** — the tasks, spending and sticky notes they cover, and your name if you’ve set one.",
            "**Scanning** — the text read from the photo, or the photo itself if it couldn’t be read clearly.",
            "**Voice notes** — the transcript, to write it up. Not the audio.",
            "**Ideas from the web** — the note you asked about. The provider may search the web for it.",
        ]),
        .p("The provider’s own terms and privacy policy apply to what it receives — for example [Anthropic](https://www.anthropic.com/legal/privacy), [OpenRouter](https://openrouter.ai/privacy), [OpenAI](https://openai.com/policies/privacy-policy), [Groq](https://groq.com/privacy-policy/) or [Google](https://policies.google.com/privacy). Some providers, including some free models on OpenRouter, may log or use requests. Don’t use cloud AI for anything you don’t want that provider to receive."),

        .h2("4. Other connections"),
        .list([
            "**Exchange rates** — for a transaction in another currency, the app asks [Frankfurter](https://www.frankfurter.app), a public rates service, for the rate. Only the two currency codes are sent.",
            "**Checking for updates** — when you choose *Check for updates* in Settings, the app asks GitHub for the latest Four Notes release. Nothing about you or your data is sent. See [GitHub’s privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).",
            "**Links you open** — *Search the web* and *Add to Google Calendar* open your browser with the note or task title filled in. Nothing is sent until you open the link.",
        ]),
        .p("Like any internet request, these reveal your IP address to the service you reach."),

        .h2("5. Permissions"),
        .p("macOS asks before the app can use the microphone, speech recognition or notifications. You can turn each off at any time in System Settings → Privacy & Security, or Notifications. The app works without them."),

        .h2("6. Your choices"),
        .list([
            "**Export** everything to a file, or **import** a backup, in Settings → Data & privacy. Backups include images but not API keys.",
            "**Delete all local data** in Settings → Data & privacy erases your content, settings and saved API keys from this Mac. It can’t be undone.",
            "**Remove a provider key** in Settings → AI & API keys at any time.",
            "**Uninstalling** the app doesn’t remove its data folder; delete everything first if you want it gone.",
        ]),

        .h2("7. Children"),
        .p("The app is not directed at children under 13, and we don’t knowingly collect information from anyone, including children."),

        .h2("8. Changes to this policy"),
        .p("If this policy changes, the date at the top changes with it, and the new text ships with the app update."),

        .h2("9. Contact"),
        .p("Questions or requests about your privacy: [\(contact)](mailto:\(contact)). See also the Terms of Service."),
    ]

    private static let termsBlocks: [Block] = [
        .p("These terms apply to your use of Four Notes for Mac (“the app”). By using the app you agree to them. If you don’t agree, please don’t use it."),

        .h2("1. The app"),
        .p("Four Notes is a free Mac app for notes, to-dos and tracking spending, with an optional AI assistant. It is distributed through [GitHub](https://github.com/lynnarize/fournotes-macos/releases). Features may change between versions; some are marked *beta* and may be incomplete. The app doesn’t update itself — you choose when to install a new version."),

        .h2("2. Your content"),
        .p("You own what you create in the app. It is stored on your Mac, and you are responsible for it and for keeping backups — you can export one any time from Settings → Data & privacy. How the app handles your information is described in the Privacy Policy."),

        .h2("3. AI features"),
        .list([
            "The assistant can make mistakes — for example misreading a receipt amount, a date or a category. Check anything important before relying on it.",
            "Spending summaries, budgets and saving tips are for your own organisation only. They are **not** financial, tax, legal or investment advice.",
            "Which model answers depends on your setup: Apple Intelligence or a model server on this Mac, or a cloud provider you add.",
        ]),

        .h2("4. Your own API keys"),
        .p("If you add a key for a cloud provider (for example Anthropic, OpenRouter, OpenAI, Groq or Google Gemini), requests made with it are billed to your account with that provider, under their terms and usage policies. Keep your keys private; you are responsible for their use."),

        .h2("5. Acceptable use"),
        .p("Please don’t use the app for anything illegal, to store or produce unlawful content, or in ways that break the terms of the AI providers you connect it to."),

        .h2("6. Third-party services"),
        .p("The app can work with services run by others — cloud AI providers, Apple’s speech recognition and Apple Intelligence, a public exchange-rate service, GitHub, and links that open in your browser. Your use of them is also covered by their own terms and policies, and they may be unavailable at times."),

        .h2("7. No warranty"),
        .p("The app is provided free of charge, “as is” and “as available”, without warranties of any kind, including that it will be error-free or that data will never be lost."),

        .h2("8. Limitation of liability"),
        .p("To the extent the law allows, we are not liable for any indirect or consequential loss, or for loss of data, profits or savings, arising from your use of the app — including decisions made using AI output. Nothing in these terms limits rights you have under laws that can’t be excluded."),

        .h2("9. Ending use"),
        .p("You can stop using the app at any time. To remove your data, use *Delete all local data* in Settings → Data & privacy before deleting the app. We may stop making new versions; the app and your data stay on your Mac."),

        .h2("10. Changes to these terms"),
        .p("We may update these terms. The date at the top shows the latest version, and new text ships with app updates; continuing to use an updated app means you accept them."),

        .h2("11. Contact"),
        .p("Questions about these terms: [\(contact)](mailto:\(contact))."),
    ]
}

/// One document, readable in the app.
struct LegalSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let document: LegalDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Logo(size: 26)
                Text("Four Notes").font(FN.font(15, .bold)).foregroundStyle(p.text)
                Spacer()
                PrimaryButton(title: "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(p.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(document.title)
                        .font(FN.serif(32))
                        .foregroundStyle(p.text)
                    Text("Last updated \(LegalDocument.lastUpdated)")
                        .font(FN.small).foregroundStyle(p.muted)

                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }

                    Divider().overlay(p.line).padding(.top, 12)
                    Text(Self.markdown("Contact: [\(LegalDocument.contact)](mailto:\(LegalDocument.contact))"))
                        .font(FN.small).foregroundStyle(p.muted)
                }
                .textSelection(.enabled)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 720, height: 640)
        .background(p.bg)
    }

    @ViewBuilder
    private func view(for block: LegalDocument.Block) -> some View {
        switch block {
        case .p(let text):
            Text(Self.markdown(text))
                .font(.system(size: 14)).foregroundStyle(p.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .callout(let text):
            Text(Self.markdown(text))
                .font(.system(size: 14)).foregroundStyle(p.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .h2(let text):
            Text(text).font(FN.serif(21)).foregroundStyle(p.text).padding(.top, 10)
        case .h3(let text):
            Text(text).font(FN.serif(17, .medium)).foregroundStyle(p.text).padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(p.muted)
                        Text(Self.markdown(item))
                            .font(.system(size: 14)).foregroundStyle(p.text).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
