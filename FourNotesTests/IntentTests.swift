import Foundation
import Testing
@testable import FourNotes

// The checks the on-device tools make against what the user actually typed.
// Each one exists because the model got that case wrong in the evaluation.

@Suite("Intent")
struct IntentTests {
    @Test("questions are recognised", arguments: [
        "what did I spend most on this month?", "what's on my to-do list?", "how much is left in my food budget",
        "berapa pengeluaran bulan ini?", "show my tasks", "is the report done?",
    ])
    func questions(_ message: String) { #expect(Intent.isQuestion(message)) }

    @Test("requests are not questions, even with a question mark", arguments: [
        "can you remind me to call mom tomorrow?", "coffee 25k at Kopi Kenangan", "remind me in 2 hours",
        "note: ideas for the weekend", "set my food budget to 1.5M a month", "got my salary today, 10jt",
    ])
    func requests(_ message: String) { #expect(!Intent.isQuestion(message)) }

    @Test("the one amount a message states", arguments: [
        ("coffee 25k at Kopi Kenangan", 25_000.0), ("paid 150rb for gas", 150_000),
        ("got my salary today, 10jt", 10_000_000), ("GoPay: Pembayaran Rp 35.000 ke Gojek berhasil", 35_000),
        ("Remind me to pay rent of 2.5jt every month on the 5th at 9am", 2_500_000),
        ("set my food budget to 1.5M a month", 1_500_000),
    ])
    func amounts(_ message: String, _ expected: Double) { #expect(Intent.amount(in: message) == expected) }

    @Test("no amount, or no single amount")
    func noAmount() {
        #expect(Intent.amount(in: "remind me in 2 hours") == nil)
        #expect(Intent.amount(in: "tomorrow at 10 am") == nil)
        #expect(Intent.amount(in: "coffee 25k and cake 30k") == nil)
    }

    @Test("repeats said in so many words")
    func repeats() {
        #expect(Intent.repeats("water the plants every Monday at 8am") == .WEEKLY)
        #expect(Intent.repeats("pay rent every month on the 5th") == .MONTHLY)
        #expect(Intent.repeats("bayar listrik tiap bulan") == .MONTHLY)
        #expect(Intent.repeats("take vitamins daily") == .DAILY)
        #expect(Intent.repeats("call mom tomorrow") == nil)
    }

    @Test("money coming in")
    func income() {
        #expect(Intent.isIncome("got my salary today, 10jt"))
        #expect(Intent.isIncome("terima transfer 500rb dari Andi"))
        #expect(!Intent.isIncome("coffee 25k"))
    }

    @Test("task titles lose the scaffolding")
    func titles() {
        #expect(Intent.cleanTitle("Quick note: Book lounge room for tomorrow", now: Date()) == "Book lounge room")
        #expect(Intent.cleanTitle("remind me to call mom tomorrow at 7pm", now: Date()) == "Call mom")
        #expect(Intent.cleanTitle("buy milk", now: Date()) == "Buy milk")
    }

    @Test("an amount the user never wrote is not used")
    func inventedAmount() {
        // The model once attached a Rp 150,000 bill to this reminder.
        #expect(Intent.amount(in: "ingatkan saya bayar listrik besok jam 9 pagi", modelSaid: "150rb") == nil)
        // With two amounts in the message, the model's pick is trusted when it is one of them.
        #expect(Intent.amount(in: "coffee 25k and cake 30k", modelSaid: "30k") == 30_000)
        #expect(Intent.amount(in: "coffee 25k and cake 30k", modelSaid: "40k") == nil)
    }

    @Test("an e-wallet notice of money received is income")
    func walletIncome() {
        let parsed = Wallet.parseNotification("OVO: Anda menerima Rp 500.000 dari Budi")
        #expect(parsed?.amount == -500_000)
        #expect(parsed?.category == "Income")
    }

    @Test("a question about a note is a question, never a note to save")
    func noteQuestion() throws {
        // What the editor's "Ask the assistant…" puts in the box, sent as is.
        let bare = try #require(Intent.noteQuestion("About my note “Weekend trip ideas”: "))
        #expect(bare.title == "Weekend trip ideas")
        #expect(bare.ask.isEmpty)
        #expect(Intent.isQuestion("About my note “Weekend trip ideas”:"))
        #expect(Intent.isQuestion("About my note “Weekend trip ideas”: which is cheapest"))
        // Asked to do something with it, it is a request.
        #expect(!Intent.isQuestion("About my note “Weekend trip ideas”: add a task to book the hotel"))
        #expect(Intent.noteQuestion("Weekend trip ideas") == nil)
    }

    @Test("an empty question about a note is asked plainly")
    func expandedNoteQuestion() {
        #expect(Intent.expandingNoteQuestion("About my note “Trip”: ").contains("summary"))
        #expect(Intent.expandingNoteQuestion("About my note “Trip”: which is cheapest?")
                == "About my note “Trip”: which is cheapest?")
        #expect(Intent.expandingNoteQuestion("hello") == "hello")
    }

    @Test("an amount a model misread is taken from the message")
    func ground() {
        let misread: [AIAction] = [.addTransaction(merchant: "Kopi Kenangan", amount: 25, currency: nil,
                                                   category: "Food & Drink", date: "2026-09-23", items: [],
                                                   splitWith: [], noteRef: nil)]
        guard case let .addTransaction(_, amount, _, _, _, _, _, _)? = Intent.ground(misread, in: "coffee 25k at Kopi Kenangan").first
        else { Issue.record("no transaction"); return }
        #expect(amount == 25_000)
        // Income keeps its sign.
        let income: [AIAction] = [.addTransaction(merchant: "Salary", amount: -10, currency: nil, category: "Income",
                                                  date: "2026-09-23", items: [], splitWith: [], noteRef: nil)]
        guard case let .addTransaction(_, salary, _, _, _, _, _, _)? = Intent.ground(income, in: "got my salary, 10jt").first
        else { Issue.record("no transaction"); return }
        #expect(salary == -10_000_000)
        // A message with no amount leaves the model's alone.
        #expect(Intent.ground(misread, in: "coffee at Kopi Kenangan") == misread)
    }

    @Test("recommendations and ideas are offered to the cloud; filing is not")
    func worldKnowledge() {
        #expect(Intent.wantsWorldKnowledge("any recommendation for a rainy weekend?"))
        #expect(Intent.wantsWorldKnowledge("rekomendasi kopi di Bandung"))
        #expect(Intent.wantsWorldKnowledge("what should I cook tonight"))
        #expect(!Intent.wantsWorldKnowledge("coffee 25k at Kopi Kenangan"))
        #expect(!Intent.wantsWorldKnowledge("remind me to call mom tomorrow"))
        #expect(Intent.looksOutOfScope("I can't give travel advice, but I can help with your notes."))
        #expect(Intent.looksOutOfScope("I help with notes, tasks and spending."))
        #expect(!Intent.looksOutOfScope("Added “Call mom” to To-Do."))
    }

    @Test("this Mac first keeps to this Mac while it has a model")
    func priority() {
        #expect(AIEngine.ordered(local: ["lmstudio", "apple"], cloud: ["claude"], priority: .localFirst)
                == ["lmstudio", "apple"])
        // Nothing local: the cloud answers rather than nothing.
        #expect(AIEngine.ordered(local: [String](), cloud: ["openrouter"], priority: .localFirst) == ["openrouter"])
        // Cloud first still falls back to this Mac.
        #expect(AIEngine.ordered(local: ["apple"], cloud: ["claude", "openrouter"], priority: .cloudFirst)
                == ["claude", "openrouter", "apple"])
    }

    @Test("the cloud is offered for what needs the internet, never for small talk")
    func needsCloud() {
        let greeting = "Hi! I help with notes, tasks and spending. What’s on your mind?"
        #expect(!Intent.needsCloud("Hi", localReply: greeting, aboutNote: false))
        #expect(!Intent.needsCloud("thanks!", localReply: "You’re welcome!", aboutNote: false))
        #expect(!Intent.needsCloud("coffee 25k at Kopi Kenangan", localReply: "Logged Rp 25,000.", aboutNote: false))
        #expect(Intent.needsCloud("any recommendation for a rainy weekend in Bandung?",
                                  localReply: "Bandung has great coffee.", aboutNote: false))
        #expect(Intent.needsCloud("About my note “Trip”: ", localReply: "Your note lists Bali.", aboutNote: true))
        #expect(Intent.needsCloud("what is the capital of France?",
                                  localReply: "I help with notes, tasks and spending.", aboutNote: false))
        #expect(!Intent.needsCloud("what's on my to-do list?",
                                   localReply: "You have one task: Book dentist appointment.", aboutNote: false))
    }

    @Test("questions and recommendation requests are answered with no tools")
    func answerOnly() {
        #expect(Intent.answerOnly("recommend itinery on bandung"))
        #expect(Intent.answerOnly("what model are you"))
        #expect(Intent.answerOnly("what did I spend most on this month?"))
        #expect(!Intent.answerOnly("note: ideas for the weekend — Bandung, Bali"))
        #expect(!Intent.answerOnly("save a Bandung itinerary note"))
        #expect(!Intent.answerOnly("remind me to call mom tomorrow"))
        #expect(!Intent.answerOnly("coffee 25k at Kopi Kenangan"))
    }

    @Test("a failure is named in a few words")
    func reasons() {
        #expect(AIEngine.reason(APIError.server("OpenRouter rejected that key. Check it in Settings.")) == "key rejected")
        #expect(AIEngine.reason(APIError.offline) == "offline")
        #expect(AIEngine.reason(APIError.server("This free model is busy right now.")) == "busy or rate limited")
        #expect(AIEngine.reason(APIError.server("The connection to OpenRouter dropped.")) == "connection failed")
    }
}
