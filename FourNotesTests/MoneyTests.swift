import Testing
@testable import FourNotes

// Money parsing and formatting. The web app accepts Indonesian shorthand
// ("25rb", "1,5jt") and both separator conventions, so these pin that behaviour
// down before anything is changed.

@Suite("Money.parse")
struct MoneyParseTests {

    @Test("plain numbers")
    func plain() {
        #expect(Money.parse("25000") == 25_000)
        #expect(Money.parse("0") == 0)
        #expect(Money.parse("1234.56") == 1234.56)
    }

    @Test("Indonesian shorthand", arguments: [
        ("25k", 25_000.0), ("25rb", 25_000.0), ("25 ribu", 25_000.0),
        ("1.5jt", 1_500_000.0), ("1,5jt", 1_500_000.0),
        ("2juta", 2_000_000.0), ("1.5M", 1_500_000.0),
    ])
    func shorthand(input: String, expected: Double) {
        #expect(Money.parse(input) == expected)
    }

    @Test("thousand separators both ways")
    func separators() {
        #expect(Money.parse("Rp 25.000") == 25_000)        // Indonesian
        #expect(Money.parse("25,000.00") == 25_000)        // US
        #expect(Money.parse("IDR 1.250.000") == 1_250_000)
        #expect(Money.parse("128.500") == 128_500)
    }

    @Test("rejects things that are not amounts")
    func rejects() {
        #expect(Money.parse("") == nil)
        #expect(Money.parse("hello") == nil)
        #expect(Money.parse("25kg") == nil)   // trailing letters that aren't a unit
        #expect(Money.parse("25 kg") == nil)
    }

    @Test("an amount followed by a word is still an amount")
    func followedByWord() {
        #expect(Money.parse("lunch 45.000 di Warteg") == 45_000)
        #expect(Money.parse("Rp 45.000 di Warteg") == 45_000)
        #expect(Money.parse("coffee 25k at Starbucks") == 25_000)
        #expect(Money.parse("45000 makan siang") == 45_000)
        #expect(Money.parse("15000 kemarin") == 15_000)
        #expect(Money.parse("Gojek - 35000") == 35_000)
    }

    @Test("ranges, codes, a year and metres don't become the amount or its sign")
    func notTheAmount() {
        #expect(Money.parse("Harga 25000-30000") == 30_000)
        #expect(Money.parse("Kode ABC-99999 bayar 50000") == 50_000)
        #expect(Money.parse("Invoice 2026 Rp 500") == 500)
        #expect(Money.parse("Invoice 2026 $45") == 45)
        #expect(Money.parse("beli 5m kabel 50000") == 50_000)
        #expect(Money.parse("INV2026 total 75k") == 75_000)
        #expect(Money.parse("1.5M") == 1_500_000)
    }

    @Test("a count or a measure beside the price is not the price")
    func countsAndMeasures() {
        #expect(Money.parse("Grab 2 orang 50rb") == 50_000)
        #expect(Money.parse("Ticket 2 pax 150k") == 150_000)
        #expect(Money.parse("3 liter 60000") == 60_000)
        #expect(Money.parse("Pay 2 bills 350000") == 350_000)
        #expect(Money.parse("3 liter") == nil)
    }

    // MARK: - The defects this suite exists to catch

    @Test("negative amounts are income, not spending")
    func negatives() {
        // Transaction.amount documents "positive = spend, negative = income",
        // and the Income category depends on it. Typing -50000 must not become
        // +50000 and get counted as spending.
        #expect(Money.parse("-50000") == -50_000)
        #expect(Money.parse("-25k") == -25_000)
        #expect(Money.parse("Rp -25.000") == -25_000)
    }

    @Test("an overflowing number is rejected, never infinity")
    func overflow() {
        // Double("1e19...") returns +infinity rather than nil. A non-finite
        // amount reaching the model permanently breaks saving (JSONEncoder
        // throws) and traps every Int(Double) conversion in the UI.
        for input in ["10000000000000000000", "1" + String(repeating: "0", count: 40), "9e999"] {
            let parsed = Money.parse(input)
            #expect(parsed == nil || Money.isValidAmount(parsed!),
                    "\(input) parsed to an amount the app cannot store")
        }
    }

    @Test("scientific notation round-trips")
    func scientific() {
        // FX rates below 1 are formatted as "6.5e-05"; the user must be able to
        // type that back in.
        #expect(Money.parse("6.5e-05") != nil)
    }
}

@Suite("Money.format")
struct MoneyFormatTests {

    @Test("zero-decimal currencies")
    func zeroDecimal() {
        #expect(Money.format(25_000, "IDR").contains("25,000"))
        #expect(!Money.format(25_000, "IDR").contains(".00"))
    }

    @Test("compact form")
    func compact() {
        #expect(Money.format(1_500_000, "IDR", compact: true).contains("1.5M"))
        #expect(Money.format(25_000, "IDR", compact: true).contains("25K"))
    }

    @Test("never traps on extreme or non-finite input")
    func extremes() {
        // Money.format(_, compact: true) feeds Int(Double); infinity traps.
        // Reached from every chart axis, stat card and the report table.
        for value in [Double.infinity, -.infinity, .nan, 1e30, -1e30, .greatestFiniteMagnitude] {
            _ = Money.format(value, "IDR", compact: true)
            _ = Money.format(value, "IDR")
        }
    }
}
