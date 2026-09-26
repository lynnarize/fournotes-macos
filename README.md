# Four Notes for Mac

Notes, to-dos, spending and an assistant that files things for you — in one
calm, fast, native Mac app. Built entirely in SwiftUI and AppKit, private by
default, and useful with no account, no key and no network.

## Features

- **Today** — your day on one page: a written brief, what's due (tick it off
  right there), heads-up alerts, quick notes, and the assistant in the middle.
  The brief reads as one paragraph or point by point.
- **Notes** — a rich-text editor with real bullet, numbered and checklist
  lists, spell-checking, find, undo, tags, sharing and printing. A focus mode
  gives a note the whole window.
- **To-Do** — a board (To Do, Doing, Done) with due dates, reminders,
  repeating tasks and bills. Type "call Budi Friday 9am" and the date is
  filled in.
- **Finance** *(beta)* — spending by month and category, budgets, split bills,
  subscription detection, upcoming payments, a monthly review and a yearly
  report (CSV and PDF). Paste an e-wallet notification and it becomes a
  transaction.
- **Assistant** — ask about your notes, tasks and money, or tell it to add
  something: "Spent 45k on lunch at Warteg", "Remind me to pay rent on the 5th
  every month". It answers on this Mac first and offers the cloud only when a
  question needs the internet.
- **Scan and record** — a receipt photo becomes spending; a voice memo becomes
  a note with its to-dos. Text is read and speech transcribed on this Mac.
- **Edge Dock** — a small handle on the edge of the screen, over any app and
  any Space, that opens a drawer of mini apps: quick note, today's tasks,
  dictation with a live level meter, a one-line spend, what's coming up, and
  the assistant. Drag cards to rearrange them. ⇧⌘. opens it.
- **Sticky Edge** — stick notes to the dock's handle; they wait on the edge of
  the screen and open on hover.
- **Themes** — System, Light, Paper (warm paper, ink-brown text) and Dark.
- **First-run setup** — a short walkthrough of the app, the look, the assistant
  and your currency. Run it again from Settings → General.

## The assistant

Settings → AI & API keys has two groups, and you choose which is asked first.

| | What | Setup |
|---|---|---|
| **On this Mac** | Apple Intelligence, or a model in LM Studio or Ollama | Found automatically — **Use**, **Start**, **Stop** |
| **In the cloud** | One tab each, as in the web app: **OpenRouter** (Free: tested free models · Paid: any model, billed to your credits), **OpenCode** (Free: Zen's free models · Go: the subscription), **Claude**, and **Other** (OpenAI, Groq, Google Gemini, or any OpenAI-compatible API) | Your key and a model per tab; **Ask this first** picks which answers first |

The assistant helps with general questions, advice and writing, but it doesn't
write code and won't help with anything that could cause harm, whichever model
answers. Cloud replies, billed to your key, are kept to a sensible length; a
model on this Mac costs nothing to run, so it may answer at length. Refused
requests are turned away on the Mac, before any model is asked.

- **This Mac first** (the default) keeps answers on your Mac. When a question
  needs the internet, the reply offers to ask the cloud model — nothing is sent
  until you say so.
- **Cloud first** asks the cloud model and falls back to this Mac if it fails;
  the reply says which model answered and why.
- **With nothing set up**, scanning, voice notes, reminders, budgets, search and
  export still work. With Apple Intelligence, so do chat, the daily brief and
  the monthly review — offline and free.

Requests go straight from your Mac to the provider you choose. There is no
Four Notes server in between.

## Privacy

- Everything you create is saved in one file on your Mac:
  `~/Library/Containers/com.fournotes.mac/Data/Library/Application Support/FourNotes/four-notes-v1.json`
  (Settings → Data & privacy → **Show data file**).
- API keys are kept in the macOS Keychain, never in that file or a backup.
- No Four Notes account, analytics, tracking or ads. Besides a cloud AI model
  you add yourself, the app only goes online to look up exchange rates
  (currency codes only), once a day (or when you ask) to check GitHub for a
  newer release — Settings → About turns the daily check off —
  and, if you turn it on, to sync with Google Drive.
- **Sync** (optional, Settings → Sync): sign in with Google and your notes,
  to-dos, spending and sticky notes are kept in step with the web app at
  [app.fournotes.xyz](https://app.fournotes.xyz), through one file in a
  private app folder in your own Google Drive. Scans, sample data and API keys
  stay on the Mac.
- Settings → Data & privacy exports and restores a backup, and erases
  everything.

## Requirements

- macOS 26 or later
- Xcode 27, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`) to generate the project

Apple Intelligence features need a Mac that supports it; everything else runs
without it.

## Build and run

```bash
xcodegen generate
open FourNotes.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project FourNotes.xcodeproj -scheme FourNotes -configuration Release build
```

`project.yml` is the source of truth for the Xcode project; run
`xcodegen generate` after adding or removing files.

## Google Drive sync setup

Sync stays hidden until the build has a Google client ID.

1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials),
   open **the same project as the web app's OAuth client**. Drive's private app
   folder belongs to the project, so a client in another project would see an
   empty folder and never meet the web app's data.
2. **Create credentials → OAuth client ID → iOS**, with bundle ID
   `com.fournotes.mac`. The iOS type has no client secret and redirects to
   `com.googleusercontent.apps.<id>:/oauth2redirect`, which the app handles
   itself; there is no redirect URI to register.
3. Put the client ID in `project.yml` → `GOOGLE_CLIENT_ID`, then
   `xcodegen generate`.

The client ID is not a secret: an installed app's ID ships inside it anyway,
so it is fine to commit. The user's sign-in is kept in their Keychain.

## Make an installer

```bash
./scripts/make-dmg.sh
```

Builds Release and writes `build/FourNotes-<version>.dmg` — the app, an
Applications shortcut and a drag-to-install background. The first run asks to
let Terminal control Finder, which lays out the window.

The build is ad-hoc signed. On another Mac, open it the first time with
right-click → **Open** (or System Settings → Privacy & Security → **Open
Anyway**). A Developer ID signature and notarization remove that step.

## Versions and releases

- **Version** is `MARKETING_VERSION` in `project.yml`.
- **Build number** is stamped at build time: `CFBundleVersion` becomes the
  commit count and `FNGitCommit` the short hash (`-dirty` with uncommitted
  changes). Settings → About shows all three, so any build can be traced to
  its commit.
- **Releases** are tagged `v<version>`. One command keeps the app, the tag and
  the GitHub release in step — it sets the version, commits, builds the disk
  image from that commit, then asks before tagging, pushing and publishing:

```bash
./scripts/release.sh 0.1.2
```

Settings → About → **Check for updates** compares the running version with
the latest GitHub release. The app also checks on its own once a day (30
seconds after launch, then whenever a day has passed), using a conditional
request so an unchanged release costs nothing against GitHub's rate limit. A
newer version puts a dot on Settings in the sidebar until Settings is opened.

## Tests

```bash
./scripts/run-tests.sh
```

The suite (Swift Testing) covers money parsing and formatting, dates and
recurrence, budgets and splits, subscription detection, saving and loading,
search, the note editor's document format, the edge dock's layout, and how
model output is checked before anything is saved. It needs no key, network or
model server.

Optional evaluations run real requests against a model, and are off unless
switched on:

```bash
TEST_RUNNER_FOURNOTES_EVAL_AFM=1 ./scripts/run-tests.sh                 # Apple Intelligence
TEST_RUNNER_FOURNOTES_EVAL_OPENROUTER=<model> ./scripts/run-tests.sh    # OpenRouter, key from the Keychain
TEST_RUNNER_FOURNOTES_EVAL_LOCAL=<model> ./scripts/run-tests.sh         # a model server on localhost:1234
TEST_RUNNER_FOURNOTES_EVAL_LOCALSERVER=1 ./scripts/run-tests.sh         # LM Studio / Ollama detection
```

`scripts/smoke-test.swift` drives the running app through the accessibility API
(`swift scripts/smoke-test.swift`, with the app open and the screen unlocked).

## Keyboard shortcuts

| | |
|---|---|
| ⌘N / ⇧⌘N / ⌥⌘N | New note / task / transaction |
| ⌘K | Search or quick add |
| ⌘1 – ⌘4 | Today, Notes, To-Do, Finance |
| ⇧⌘I | Scan a receipt or note |
| ⇧⌘R | Record a voice note |
| ⇧⌘. | Open the edge dock |
| ⌘, | Settings |

## Project layout

```
FourNotes/
  App/        app entry, menus, shared app objects
  AI/         the assistant: providers, on-device model, prompts, tools
  Dock/       the edge dock, its mini apps and Sticky Edge
  Design/     theme, icons, shared components, motion
  Models/     notes, tasks, money, dates, recurrence, insights
  Services/   assistant, background jobs, dictation, local model servers, search
  Store/      the document, saving and loading, attachments
  Views/      Today, Notes, To-Do, Finance, Settings, setup
FourNotesTests/  unit tests (Swift Testing)
scripts/      installer (make-dmg.sh), release (release.sh), tests (run-tests.sh, smoke-test.swift)
project.yml   XcodeGen project definition
```

## Credits

Notes are set in [Open Sans](https://github.com/googlefonts/opensans), the same
face as the web app, bundled in `FourNotes/Resources/Fonts` under the SIL Open
Font License 1.1 (`OFL.txt` beside it, and inside the built app).

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. The bundled Open Sans font keeps its own license (above).

Unless you say otherwise, any contribution you submit for inclusion is
dual-licensed as above, without any additional terms or conditions.
