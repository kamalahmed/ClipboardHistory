import Foundation

/// Understands date phrases typed into the search box, so "7 days ago" or
/// "last week invoice" filters by time as well as text.
///
/// Recognised phrases (case-insensitive, digits or words one…thirty):
///   "today", "yesterday"
///   "3 days ago" / "three days ago"     → just that day
///   "last 7 days" / "last seven days"   → a range ending now
///   "last week"                         → the last 7 days
///
/// The matched phrase is removed from the query; whatever remains still
/// searches the content as usual.
enum DateQueryParser {

    struct Result: Equatable {
        var text: String
        var from: Date?
        var to: Date?
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "fourteen": 14, "fifteen": 15, "twenty": 20, "thirty": 30
    ]

    static func parse(_ raw: String,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Result {
        let query = raw.trimmingCharacters(in: .whitespaces)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> (Date, Date) {
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        }

        // Each pattern pairs a regex with "number → date range".
        let patterns: [(String, (Int) -> (Date, Date))] = [
            (#"last\s+(\d+|\w+)\s+days?"#, { n in
                (calendar.date(byAdding: .day, value: -(n - 1), to: today)!, day(0).1)
            }),
            (#"(\d+|\w+)\s+days?\s+ago"#, { n in day(n) }),
            (#"last\s+week"#, { _ in
                (calendar.date(byAdding: .day, value: -6, to: today)!, day(0).1)
            }),
            (#"yesterday"#, { _ in day(1) }),
            (#"today"#, { _ in day(0) })
        ]

        for (pattern, range) in patterns {
            let regex = try! NSRegularExpression(pattern: pattern,
                                                 options: [.caseInsensitive])
            let full = NSRange(query.startIndex..., in: query)
            guard let match = regex.firstMatch(in: query, range: full),
                  let matchRange = Range(match.range, in: query) else { continue }

            // Resolve the captured number, if the pattern has one.
            var number = 1
            if match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: query) {
                let word = query[capture].lowercased()
                if let n = Int(word) {
                    number = n
                } else if let n = numberWords[word] {
                    number = n
                } else {
                    continue   // "some days ago" — not a number, not a date phrase
                }
            }
            guard number > 0 else { continue }

            let (from, to) = range(number)
            var rest = query
            rest.removeSubrange(matchRange)
            return Result(text: rest.trimmingCharacters(in: .whitespaces),
                          from: from, to: to)
        }

        return Result(text: query, from: nil, to: nil)
    }
}
