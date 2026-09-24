import Foundation

// Swift decodes an array all-or-nothing: if one element fails, the whole array
// throws. For a document that is edited by two apps and may gain fields over
// time, that is the difference between losing one row and losing every note the
// user has — and, once the emptied collection is saved back, losing them from
// disk too.

/// Decodes as many elements as it can, reporting how many it had to skip.
struct LenientArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    init() {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                // The element still has to be consumed, or the container never
                // advances and this loops forever.
                _ = try? container.decode(AnyDecodable.self)
                skipped += 1
            }
        }
    }
}

/// Consumes one value of any shape, so a failed element can be stepped over.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), !single.decodeNil() { return }
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd { _ = try? unkeyed.decode(AnyDecodable.self) }
            return
        }
        _ = try? decoder.container(keyedBy: AnyKey.self)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a collection, keeping the rows it can read.
    func lenientArray<T: Decodable>(_ type: T.Type, forKey key: Key,
                                    skipped: inout Int) -> [T] {
        guard let decoded = try? decodeIfPresent(LenientArray<T>.self, forKey: key) else { return [] }
        skipped += decoded.skipped
        return decoded.elements
    }
}
