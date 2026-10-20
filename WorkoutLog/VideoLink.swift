import Foundation

// Optional per-exercise YouTube links. Links are only stored and opened, never fetched.
enum VideoLink {
    private static let allowedHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Returns a canonical video link with an optional start time in seconds.
    static func normalized(_ text: String?) throws -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            throw LogError(message: "Enter a YouTube link without spaces.")
        }
        let link = canonicalScheme(trimmed)
        let pieces = link.components(separatedBy: CharacterSet(charactersIn: "/?#"))
        guard pieces.count >= 3, pieces[0] == "https:", pieces[1] == "" else {
            throw LogError(message: "Video links must start with https://.")
        }
        // The authority has to be exactly an allowed host: no credentials, no port, no look alike domains.
        let authority = pieces[2]
        guard allowedHosts.contains(authority.lowercased()) else {
            throw LogError(message: "Use a link from youtube.com or youtu.be.")
        }
        guard let parts = URLComponents(string: link) else {
            throw LogError(message: "Use a YouTube link that starts with https:// and points to youtube.com or youtu.be.")
        }
        guard let id = videoID(in: parts, host: authority.lowercased()) else {
            throw LogError(message: "Use a YouTube video link with an 11 character video ID.")
        }
        let time = try startTime(in: parts)
        return "https://www.youtube.com/watch?v=\(id)" + (time.map { "&t=\($0)" } ?? "")
    }

    /// Checks stored links of a template or workout: every key must be one of its exercises
    /// and every value must already be in the canonical form.
    static func validate(_ links: [String: String]?, exercises: [String]) throws {
        guard let links else { return }
        for exercise in links.keys.sorted() {
            guard let link = links[exercise] else { continue }
            guard exercises.contains(exercise) else {
                throw LogError(message: "Video links must use the exercise names of this workout.")
            }
            guard let canonical = try normalized(link) else {
                throw LogError(message: "Remove the empty video link for \(exercise).")
            }
            guard canonical == link else {
                throw LogError(message: "Use the standard YouTube address for \(exercise): \(canonical)")
            }
        }
    }

    // Keeps an upper case scheme parseable without changing the rest of the link.
    private static func canonicalScheme(_ text: String) -> String {
        guard let range = text.range(of: "://", options: .caseInsensitive) else { return text }
        guard text[text.startIndex..<range.lowerBound].lowercased() == "https" else { return text }
        return "https" + String(text[range.lowerBound...])
    }

    private static func videoID(in parts: URLComponents, host: String) -> String? {
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        var segments = path.components(separatedBy: "/")
        guard segments.first == "" else { return nil }  // the path has to be absolute
        segments.removeFirst()
        if host == "youtu.be" {
            guard segments.count == 1 else { return nil }
            return validID(segments[0])
        }
        guard let first = segments.first?.lowercased() else { return nil }
        switch first {
        case "watch":
            guard segments.count == 1 else { return nil }
            guard let value = parts.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
            return validID(value)
        case "shorts", "embed":
            guard segments.count == 2 else { return nil }
            return validID(segments[1])
        default:
            return nil
        }
    }

    private static func startTime(in parts: URLComponents) throws -> Int? {
        var values = (parts.queryItems ?? []).filter { $0.name == "t" || $0.name == "start" }.map(\.value)
        if let fragment = parts.fragment {
            if fragment.hasPrefix("t=") { values.append(String(fragment.dropFirst(2))) }
            else if fragment.hasPrefix("start=") { values.append(String(fragment.dropFirst(6))) }
        }
        var result: Int?
        for value in values {
            guard let value else { throw LogError(message: "The YouTube start time is empty.") }
            let seconds = try duration(value)
            if let result, result != seconds {
                throw LogError(message: "The YouTube link contains conflicting start times.")
            }
            result = seconds
        }
        return result
    }

    private static func duration(_ text: String) throws -> Int {
        let error = LogError(message: "Use a non-negative YouTube start time, such as 90, 90s or 1m30s.")
        guard !text.isEmpty else { throw error }
        if text.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            guard let seconds = Int(text) else { throw error }
            return seconds
        }
        var number = ""
        var total = 0
        var previousUnit = 3601
        let units: [Character: Int] = ["h": 3600, "m": 60, "s": 1]
        for character in text {
            if character >= "0", character <= "9" { number.append(character); continue }
            guard let unit = units[character], unit < previousUnit, let value = Int(number) else { throw error }
            let (seconds, multiplyOverflow) = value.multipliedReportingOverflow(by: unit)
            let (sum, addOverflow) = total.addingReportingOverflow(seconds)
            guard !multiplyOverflow, !addOverflow else { throw error }
            total = sum
            previousUnit = unit
            number = ""
        }
        guard number.isEmpty else { throw error }
        return total
    }

    private static func validID(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        guard scalars.count == 11, scalars.allSatisfy({ idCharacters.contains($0) }) else { return nil }
        return text
    }
}
