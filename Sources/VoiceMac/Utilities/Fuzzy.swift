import Foundation

/// Fuzzy string scoring used for resolving spoken app names and AX elements.
///
/// Speech-to-text output is noisy ("vs code", "v s code", "visual studio"), so
/// exact matching is not sufficient. Scores are in 0...1; callers apply a
/// threshold rather than trusting a bare best-match.
enum Fuzzy {
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Strips spaces too — "vs code" and "vscode" collapse to the same key.
    static func squeeze(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: " ", with: "")
    }

    /// 0...1 similarity. Combines several signals because each one alone has a
    /// failure mode: prefix matching misses "code" -> "Visual Studio Code",
    /// edit distance misses abbreviations, subsequence over-matches short input.
    static func score(query: String, candidate: String) -> Double {
        let q = normalize(query)
        let c = normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }

        if q == c { return 1.0 }

        let qs = squeeze(q)
        let cs = squeeze(c)
        if qs == cs { return 0.98 }

        var best = 0.0

        // Whole-string prefix: "chrom" -> "chrome"
        if cs.hasPrefix(qs) {
            best = max(best, 0.90 + 0.05 * (Double(qs.count) / Double(cs.count)))
        }

        // Any word in the candidate starts with the query: "code" -> "visual studio code"
        let candidateWords = c.split(separator: " ").map(String.init)
        let queryWords = q.split(separator: " ").map(String.init)

        if candidateWords.contains(where: { $0 == q }) {
            best = max(best, 0.88)
        }
        if candidateWords.contains(where: { $0.hasPrefix(qs) && qs.count >= 3 }) {
            best = max(best, 0.82)
        }

        // Every query word matches some candidate word in order: "visual code"
        if queryWords.count > 1 {
            var index = 0
            var matched = 0
            for qw in queryWords {
                while index < candidateWords.count {
                    if candidateWords[index].hasPrefix(qw) { matched += 1; index += 1; break }
                    index += 1
                }
            }
            if matched == queryWords.count {
                best = max(best, 0.86)
            }
        }

        // Initials: "vsc" -> "Visual Studio Code"
        if qs.count >= 2, candidateWords.count >= 2 {
            let initials = candidateWords.compactMap { $0.first }.map(String.init).joined()
            if initials == qs { best = max(best, 0.84) }
        }

        // Substring containment, discounted by how much of the candidate is covered.
        if cs.contains(qs), qs.count >= 3 {
            best = max(best, 0.70 + 0.15 * (Double(qs.count) / Double(cs.count)))
        }

        // Edit distance as the general fallback.
        let distance = levenshtein(qs, cs)
        let ratio = 1.0 - Double(distance) / Double(max(qs.count, cs.count))
        if ratio > 0 { best = max(best, ratio * 0.80) }

        return min(best, 1.0)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[bChars.count]
    }
}
