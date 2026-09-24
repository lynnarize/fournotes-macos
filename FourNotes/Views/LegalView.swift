import AppKit
import SwiftUI

// The Privacy Policy and Terms of Service, as published with the web app
// (src/app/privacy/page.tsx, src/app/terms/page.tsx, src/components/LegalPage.tsx).
// The text is the web's, word for word; keep the two in step. Above it, a box
// set apart from the policy says how the Mac app differs, because the policy
// describes the web app's browser storage, Google sync and server.

enum LegalDocument: String, Identifiable, CaseIterable {
    case privacy, terms

    var id: String { rawValue }

    static let contact = "lynnarize@gmail.com"
    static let lastUpdated = "September 18, 2026"

    var title: String { self == .privacy ? "Privacy Policy" : "Terms of Service" }

    var webURL: URL? {
        URL(string: self == .privacy ? "https://fournotes.vercel.app/privacy" : "https://fournotes.vercel.app/terms")
    }

    /// How the Mac app differs from what the web text describes. Checked
    /// against the code: Store/Persistence, Services/Keychain, AI/AIEngine,
    /// Services/QuickTranscriber.
    var macNotes: [String] {
        switch self {
        case .privacy:
            return [
                "Your notes, tasks and spending are saved in a file on this Mac, not in a browser. The Mac app has no Google sign-in and no Drive sync.",
                "API keys are kept in the macOS Keychain.",
                "AI requests go straight from this Mac to the provider you set up (for example OpenRouter, Anthropic or OpenAI). There is no Four Notes server in between, and no shared daily allowance.",
                "With Apple Intelligence, or a model server on this Mac (LM Studio, Ollama), requests don't leave the Mac.",
                "Voice recordings and dictation are transcribed by Apple's speech recognition, on this Mac where it's supported. Only the text is sent to a model, when you ask for a write-up.",
            ]
        case .terms:
            return [
                "The Mac app keeps your data in a file on this Mac. Google sign-in, Drive sync and the shared AI allowance apply to the web app only; on the Mac, AI requests use the provider and key you set up, or run on this Mac.",
            ]
        }
    }

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
        .p("Four Notes (“the app”, “we”) is a notes, to-do and personal-finance app with an AI assistant, available at [fournotes.vercel.app](https://fournotes.vercel.app). This policy explains what information the app handles, where it goes, and the choices you have. We don’t sell your information, show ads, or use tracking or analytics tools."),
        .callout("**In short:** your notes, tasks and spending are stored in your own browser. They leave your device only when you use an AI feature, or when you turn on Google Drive sync, which saves a copy in a private folder of *your own* Google Drive."),
        .h2("1. Information stored on your device"),
        .p("Everything you create — notes, to-dos, transactions, budgets, categories, sticky notes and settings — is saved in your browser’s local storage on your device. We do not have a database of user content and cannot see it. Scan thumbnails and any API keys you enter in Settings are also kept only on your device."),
        .h2("2. Google user data"),
        .p("Signing in with Google is optional. It is used only to back up your data and sync it between your devices. This section describes how Four Notes accesses, uses, shares, protects, retains and deletes Google user data."),
        .h3("2.1 Data accessed"),
        .p("When you choose *Continue with Google*, the app requests these permissions and nothing else:"),
        .list([
            "**Your Google account email address** (scopes `openid` and `email`).",
            "**Your name** from your Google profile (scope `profile`). The app uses only your first name; it does not use your profile photo or any other profile information.",
            "**The app’s own data in your Google Drive** (scope `drive.appdata`): a single file, `four-notes-sync.json`, in a hidden app-data folder that only Four Notes can open.",
        ]),
        .p("The app **cannot see, open, list, change or delete any other file** in your Google Drive. It does not access your contacts, calendar, Gmail, photos or any other Google data."),
        .h3("2.2 How we use Google user data"),
        .list([
            "**Email address** — to show which Google account is connected, and to count your daily allowance of the app’s shared AI requests (signed-in users get a larger allowance).",
            "**First name** — to fill in “Your name” in Settings, which the daily brief uses to greet you. It is filled in once, only if you haven’t set a name yourself, and you can change or clear it at any time.",
            "**Drive app data** — to save your notes, to-dos, transactions, sticky notes and a few settings (currency, budgets, display name, voice replies) to the sync file, and to read that file back so the same data appears on your other devices.",
        ]),
        .p("Google user data is used only to provide these features to you. It is **not** sold, **not** used for advertising, **not** used to build profiles, and **not** used to develop, improve or train AI or machine-learning models. No one at Four Notes reads it: we have no database and no copy of it."),
        .h3("2.3 Data sharing, transfer and disclosure"),
        .p("We do not share, sell, transfer or disclose Google user data to third parties. Your email address is never sent to AI providers or anyone else. The sync file only moves between your own Google Drive and your own devices. The only exceptions are:"),
        .list([
            "**Google**, which provides sign-in and stores the file in your Drive, and **Vercel**, our hosting provider, whose servers pass requests between your browser and Google to run the app. Neither receives Google user data from us for any other purpose.",
            "If required by law.",
        ]),
        .p("Notes restored from the sync file are ordinary notes on your device. Like any of your notes, they are sent to an AI provider only when you use an AI feature, and only the parts needed for that request (see section 3)."),
        .h3("2.4 Data storage and protection"),
        .list([
            "The sync file is stored in your own Google Drive, under your Google account. We do not store it on our servers.",
            "To keep syncing, Google issues a refresh token. It is stored only on your device, in a cookie encrypted with AES-256-GCM and marked HttpOnly, so scripts on the page cannot read it. It is not stored in any database.",
            "Short-lived access tokens are kept only in your browser’s memory (never saved) and expire after one hour.",
            "Your email address is stored on your device only: inside the encrypted cookie, and in local storage to show the connected account.",
            "Your first name is kept inside the encrypted cookie and, once filled in, as your display name in Settings (on your device and in your sync file, like your other settings).",
            "All traffic uses HTTPS. The app requests only the minimum permissions it needs.",
        ]),
        .h3("2.5 Data retention and deletion"),
        .list([
            "**Sync file** — kept in your Google Drive until you delete it. Use *Delete Drive copy* in Settings → Cloud sync, or in Google Drive go to Settings → Manage apps → Four Notes → Options → *Delete hidden app data*.",
            "**Sign-in token, email address and name** — these are kept in the encrypted cookie on your device for up to 180 days; your email is also saved in your browser’s local storage to show which account is connected. These are deleted immediately when you choose *Disconnect*, which also revokes the app’s access with Google.",
            "**Daily allowance counter** — your email address (or IP address when signed out) is held in server memory only to count requests, and is cleared every day.",
            "**Display name** — kept as a setting until you change or clear it in Settings → General, or delete your data.",
            "**Sign-in protection cookie** — deleted after 10 minutes.",
            "You can remove the app’s access at any time from [your Google Account’s third-party connections](https://myaccount.google.com/permissions). For any request about your data, contact [\(contact)](mailto:\(contact)).",
        ]),
        .h3("2.6 Limited Use"),
        .p("Four Notes’ use and transfer of information received from Google APIs to any other app will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements."),
        .h2("3. AI features"),
        .p("When you use the assistant — chat, scanning a photo, a voice recording, the daily brief or the monthly review — the app’s server sends what’s needed for that request to an AI provider and returns the answer to you:"),
        .list([
            "your message, or the photo or recording you chose;",
            "a short summary of your data so the assistant can answer (for example recent tasks, spending and note titles, and notes related to your question).",
        ]),
        .p("The provider is [OpenRouter](https://openrouter.ai/privacy), which routes the request to an AI model provider; if you add your own key in Settings, the request goes to that provider instead (for example [Anthropic](https://www.anthropic.com/legal/privacy), or OpenAI or Groq for speech-to-text, or Voyage AI for search). Their own privacy policies apply to what they receive; some free models are offered by providers that may log or use the requests they receive, as described in OpenRouter’s policy. Our server does not store the content of these requests; it keeps only technical logs such as which model answered and how many tokens were used."),
        .p("Don’t use the AI features for information you don’t want sent to an AI provider."),
        .h2("4. Other services"),
        .list([
            "**Exchange rates** — for foreign-currency transactions the app looks up rates from a public currency service. Only the currency codes are sent.",
            "**Hosting** — the app is hosted on [Vercel](https://vercel.com/legal/privacy-policy), which processes standard request information (such as IP address and browser type) to serve the site.",
        ]),
        .h2("5. Abuse protection"),
        .p("To stop the shared AI allowance from being misused, the server counts requests per IP address, or per Google account email when you’re signed in. These counts are held briefly in server memory, are not stored in a database, and reset daily."),
        .h2("6. Cookies and local storage"),
        .p("The app uses your browser’s local storage for your data and preferences, and two cookies only when you connect Google: a short-lived one that protects the sign-in against forgery, and the encrypted sync cookie described above. There are no advertising or tracking cookies."),
        .h2("7. Your choices and deleting your data"),
        .list([
            "**Export** a backup of everything from Settings → Data & privacy.",
            "**Delete everything** on this device from Settings → Data & privacy (this also removes saved API keys).",
            "**Delete Drive copy** and **Disconnect** as described in section 2.",
        ]),
        .h2("8. Children"),
        .p("The app is not directed at children under 13, and we do not knowingly collect information from them."),
        .h2("9. Changes to this policy"),
        .p("If this policy changes, we will update the date at the top of this page. For significant changes that affect your Google data, we will ask for your consent again where required."),
        .h2("10. Contact"),
        .p("Questions or requests about your privacy: [\(contact)](mailto:\(contact)). See also our Terms of Service."),
    ]

    private static let termsBlocks: [Block] = [
        .p("These terms apply to your use of Four Notes (“the app”), available at [fournotes.vercel.app](https://fournotes.vercel.app). By using the app you agree to them. If you don’t agree, please don’t use the app."),
        .h2("1. The service"),
        .p("Four Notes is a free app for notes, to-dos and tracking your spending, with an optional AI assistant and optional backup to your own Google Drive. Features may change, and some depend on third-party services that may be unavailable at times."),
        .h2("2. Your content"),
        .p("You own what you create in the app. It is stored on your device and, if you turn on sync, in your own Google Drive. You are responsible for your content and for keeping your own backups (you can export one any time from Settings → Data & privacy). How we handle your information is described in the Privacy Policy."),
        .h2("3. AI features"),
        .list([
            "The assistant can make mistakes — for example misreading a receipt amount, a date or a category. Check anything important before relying on it.",
            "Spending summaries, budgets and saving tips are for your own organisation only. They are **not** financial, tax, legal or investment advice.",
            "The free AI allowance is limited each day and may be reduced, paused or changed.",
        ]),
        .h2("4. Your own API keys"),
        .p("If you add your own API key (for example for OpenRouter, Anthropic, OpenAI, Groq or Voyage AI), requests made with it are billed to your account with that provider under their terms. Keep your keys private; you are responsible for their use."),
        .h2("5. Acceptable use"),
        .p("Please don’t:"),
        .list([
            "use the app for anything illegal, or to store or produce unlawful content;",
            "try to get around the shared AI allowance, overload the service, or use it through automated scripts;",
            "try to access other people’s data or interfere with the app’s security.",
        ]),
        .p("We may block access that breaks these rules or threatens the service."),
        .h2("6. Third-party services"),
        .p("The app works with services run by others, including Google (sign-in and Drive), OpenRouter and other AI providers, and Vercel (hosting). Your use of them is also covered by their own terms and policies."),
        .h2("7. No warranty"),
        .p("The app is provided free of charge, “as is” and “as available”, without warranties of any kind, including that it will be uninterrupted, error-free or that data will never be lost."),
        .h2("8. Limitation of liability"),
        .p("To the extent the law allows, we are not liable for any indirect or consequential loss, or for loss of data, profits or savings, arising from your use of the app — including decisions made using AI output. Nothing in these terms limits rights you have under laws that can’t be excluded."),
        .h2("9. Ending use"),
        .p("You can stop using the app at any time. To remove your data, use *Delete everything* and *Delete Drive copy* in Settings, and disconnect the app from your Google account. We may discontinue the app; if so, your data remains on your device and in your Drive."),
        .h2("10. Changes to these terms"),
        .p("We may update these terms. The date at the top shows the latest version; continuing to use the app means you accept the updated terms."),
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
                if let url = document.webURL {
                    GhostButton(action: { NSWorkspace.shared.open(url) }) { Text("Open on the web") }
                }
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

                    macBox.padding(.vertical, 6)

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

    /// Set apart from the policy's own text: the app's note, not the policy.
    private var macBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon("monitor", size: 15).foregroundStyle(p.accent)
                Text("On the Mac app").font(FN.bodyMedium).foregroundStyle(p.text)
            }
            Text("This text was written for the web app. Where the Mac app works differently:")
                .font(FN.small).foregroundStyle(p.muted)
            ForEach(document.macNotes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(p.muted)
                    Text(note).font(FN.body).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.accent.opacity(0.25), lineWidth: 1))
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
