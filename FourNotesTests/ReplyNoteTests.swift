import Foundation
import Testing
@testable import FourNotes

// Saving a chat reply to Notes, as it was shown. The reply below is the cloud
// itinerary that "yea save that" used to lose to a garbled local rewrite.

@Suite("Saving a reply as a note")
struct ReplyNoteTests {
    let reply = """
        Here's a relaxed **2-night Bali** plan for a rainy weekend:

        ### Day 1
        - **Ubud** — cafés and the Monkey Forest
        - *Covered* markets

        | Item | Cost |
        |---|---|
        | Accommodation (2 nights) | ~600–800k |
        | **Total** | **~1.2jt – 1.7jt** |

        Well within your **2jt** budget! 🎉

        ---

        Would you like me to:
        - **Save this itinerary as a note** in your trip ideas?
        - **Create tasks** (like booking tickets)?

        Let me know! 😊
        """

    @Test("the text is kept, the Markdown becomes note formatting, the offer goes")
    func content() {
        let note = ReplyNote.content(fromReply: reply)
        #expect(note.contains("Here's a relaxed 2-night Bali plan"))
        #expect(note.contains("### Day 1"))
        #expect(note.contains("• Ubud — cafés and the Monkey Forest"))
        #expect(note.contains("• Covered markets"))
        #expect(note.contains("• Accommodation (2 nights) — ~600–800k"))
        #expect(note.contains("• Total — ~1.2jt – 1.7jt"))
        #expect(!note.contains("**"))
        #expect(!note.contains("|---"))
        #expect(!note.contains("Would you like"))
        #expect(!note.contains("Let me know"))
        #expect(!note.hasSuffix("---"))
    }

    @Test("titled from the question, or the reply's heading")
    func title() {
        #expect(ReplyNote.title(reply: "Some text", question: "any recommendation for a rainy weekend in Bandung?")
                == "A rainy weekend in Bandung")
        #expect(ReplyNote.title(reply: "# Bali on a budget\nDay 1…", question: "ideas?") == "Bali on a budget")
        #expect(ReplyNote.title(reply: "Plan for Saturday: rest.", question: "hm") == "Plan for Saturday")
    }

    @Test("“save that” means the reply above; a note with its own text does not")
    func intent() {
        for yes in ["yea save that", "save it", "Save this as a note", "please save the itinerary", "simpan itu",
                    "save that to my notes"] {
            #expect(Intent.savesPreviousReply(yes), "\(yes)")
        }
        for no in ["save a note: buy milk", "note: ideas for the weekend", "save 25k for coffee tomorrow at Kopi Kenangan please",
                   "remind me to call mom"] {
            #expect(!Intent.savesPreviousReply(no), "\(no)")
        }
    }

    @Test("only a substantial reply offers the button")
    func worth() {
        #expect(ReplyNote.isWorthSaving(reply))
        #expect(!ReplyNote.isWorthSaving("Added “Call mom” to To-Do."))
    }

    @Test("“yes” to a reply that offered to save it saves that reply")
    func agreeing() {
        #expect(ReplyNote.offersToSave(reply))
        #expect(ReplyNote.offersToSave("Ideas:\n- Coffee\n- Museums\n\nWant me to create a note for your Bandung trip?"))
        #expect(!ReplyNote.offersToSave("Ideas:\n- Coffee\n- Museums\n\nLet me know if you'd like more ideas!"))
        for yes in ["yes", "yea", "sure, go ahead", "iya", "ok please"] { #expect(Intent.agrees(yes), "\(yes)") }
        #expect(!Intent.agrees("yes but make it a to-do for Friday with a reminder at 9"))
        #expect(!Intent.agrees("no thanks"))
    }

    @Test("a saved reply is titled from what it says it is, never from a “yes”")
    func titleFromLead() {
        let japan = "Here's a recommended 5-day Japan itinerary for October — great weather, autumn colors starting to show:\n\nDay 1 — Tokyo"
        #expect(ReplyNote.title(reply: japan, question: "Yes, ask OpenRouter") == "5-day Japan itinerary for October")
        let bandung = "Here's a recommended **Bandung itinerary** you can adapt for a weekend trip:\n\n---\n\nDay 1"
        #expect(ReplyNote.title(reply: bandung, question: nil) == "Bandung itinerary")
        // No opening to go by: the question, with "recommend" taken off.
        #expect(ReplyNote.title(reply: "Day 1\n- Tokyo", question: "recommend itinerary for Japan in October")
                == "Itinerary for Japan in October")
    }
}
