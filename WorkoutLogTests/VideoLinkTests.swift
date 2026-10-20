import XCTest
@testable import WorkoutLog

@MainActor
final class VideoLinkTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"
    private var canonical: String { "https://www.youtube.com/watch?v=\(id)" }

    func testAcceptedSpellingsBecomeTheCanonicalLink() throws {
        let accepted = [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)",
            "https://www.youtube.com/shorts/\(id)",
            "https://m.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "  https://youtu.be/\(id)  ",
            "HTTPS://WWW.YOUTUBE.COM/watch?v=\(id)"
        ]
        for text in accepted {
            XCTAssertEqual(try VideoLink.normalized(text), canonical, text)
        }
        XCTAssertEqual(try VideoLink.normalized("https://youtu.be/abc_-ABC123"), "https://www.youtube.com/watch?v=abc_-ABC123")
    }

    func testTimestampsSurviveNormalizationAndTrackingIsDropped() throws {
        let cases: [(String, Int)] = [
            ("https://youtu.be/\(id)?t=90&si=tracking", 90),
            ("https://www.youtube.com/watch?v=\(id)&t=90s&list=PL123", 90),
            ("https://www.youtube.com/watch?v=\(id)&t=1m30s", 90),
            ("https://m.youtube.com/watch?v=\(id)&t=1h2m3s", 3723),
            ("https://www.youtube.com/embed/\(id)?start=90", 90),
            ("https://www.youtube.com/watch?v=\(id)#t=1m30s", 90),
            ("https://youtu.be/\(id)?t=0", 0),
            ("https://www.youtube.com/shorts/\(id)?t=2m", 120),
            ("https://www.youtube.com/watch?v=\(id)&start=90&t=90s#t=1m30s", 90)
        ]
        for (input, seconds) in cases {
            let expected = canonical + "&t=\(seconds)"
            XCTAssertEqual(try VideoLink.normalized(input), expected, input)
            XCTAssertEqual(try VideoLink.normalized(expected), expected)
            XCTAssertNoThrow(try VideoLink.validate(["Bench": expected], exercises: ["Bench"]))
        }
    }

    func testRejectsInvalidOrConflictingStartTimesInsteadOfLosingThem() {
        for time in ["", "-1", "+2", "1.5", "abc", "1:30", "1s2m", "1m2m", "h", "1m30", "999999999999999999999999999999999", "9223372036854775807h"] {
            XCTAssertThrowsError(try VideoLink.normalized(canonical + "&t=" + time), time)
        }
        XCTAssertThrowsError(try VideoLink.normalized(canonical + "&t"))
        XCTAssertThrowsError(try VideoLink.normalized(canonical + "&t=30&start=90"))
        XCTAssertThrowsError(try VideoLink.normalized(canonical + "&t=30#t=90"))
    }

    func testBlankLinksAreDropped() throws {
        XCTAssertNil(try VideoLink.normalized(nil))
        XCTAssertNil(try VideoLink.normalized(""))
        XCTAssertNil(try VideoLink.normalized("   "))
        XCTAssertNil(try VideoLink.normalized("\n\t "))
    }

    func testRejectsUntrustedHostsAndSchemes() {
        let rejected = [
            "http://www.youtube.com/watch?v=\(id)",
            "ftp://www.youtube.com/watch?v=\(id)",
            "www.youtube.com/watch?v=\(id)",
            "https://evil.com/watch?v=\(id)",
            "https://youtube.com.evil.com/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)",
            "https://www.youtube.com.attacker.net/watch?v=\(id)",
            "https://youtu.be.evil.com/\(id)",
            "https://www.youtube.com/watch?v=\(id) extra"
        ]
        for text in rejected {
            XCTAssertThrowsError(try VideoLink.normalized(text), text)
        }
    }

    func testRejectsCredentialsAndPorts() {
        let rejected = [
            "https://user@www.youtube.com/watch?v=\(id)",
            "https://user:pass@www.youtube.com/watch?v=\(id)",
            "https://www.youtube.com@evil.com/watch?v=\(id)",
            "https://www.youtube.com:443/watch?v=\(id)",
            "https://www.youtube.com:8443/watch?v=\(id)",
            "https://youtu.be:443/\(id)"
        ]
        for text in rejected {
            XCTAssertThrowsError(try VideoLink.normalized(text), text)
        }
    }

    func testRejectsInvalidVideoIDs() {
        let rejected = [
            "https://www.youtube.com/watch?v=dQw4w9WgXc",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXc!",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ%20",
            "https://www.youtube.com/watch?list=PL123",
            "https://www.youtube.com/shorts/dQw4w9WgXc",
            "https://www.youtube.com/embed/dQw4w9WgXcQQ",
            "https://youtu.be/dQw4w9WgXcQ/extra",
            "https://www.youtube.com/watch/dQw4w9WgXcQ",
            "https://www.youtube.com/playlist?list=PL123"
        ]
        for text in rejected {
            XCTAssertThrowsError(try VideoLink.normalized(text), text)
        }
    }

    func testValidateAcceptsMissingAndCanonicalLinks() throws {
        XCTAssertNoThrow(try VideoLink.validate(nil, exercises: ["Bench", "Press"]))
        XCTAssertNoThrow(try VideoLink.validate([:], exercises: ["Bench"]))
        XCTAssertNoThrow(try VideoLink.validate(["Bench": canonical], exercises: ["Bench", "Press"]))
        let link = try XCTUnwrap(try VideoLink.normalized("https://youtu.be/\(id)"))
        XCTAssertNoThrow(try VideoLink.validate(["Bench": link], exercises: ["Bench"]))
    }

    func testValidateRejectsUnknownExerciseKeys() {
        XCTAssertThrowsError(try VideoLink.validate(["Squat": canonical], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["bench": canonical], exercises: ["Bench"]))
    }

    func testValidateRejectsBlankInvalidAndNoncanonicalLinks() {
        XCTAssertThrowsError(try VideoLink.validate(["Bench": ""], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": "   "], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": "https://evil.com/watch?v=\(id)"], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": "http://www.youtube.com/watch?v=\(id)"], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": "https://youtu.be/\(id)"], exercises: ["Bench"]))
        XCTAssertNoThrow(try VideoLink.validate(["Bench": "https://www.youtube.com/watch?v=\(id)&t=30"], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": " https://www.youtube.com/watch?v=\(id) "], exercises: ["Bench"]))
    }
}
