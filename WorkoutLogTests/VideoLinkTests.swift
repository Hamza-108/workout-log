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
            "https://youtu.be/\(id)?t=30",
            "https://www.youtube.com/watch?v=\(id)&t=42&list=PL1234567890&index=2",
            "https://www.youtube.com/watch?v=\(id)#t=30",
            "https://www.youtube.com/shorts/\(id)",
            "https://m.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/embed/\(id)?start=10",
            "  https://youtu.be/\(id)  ",
            "HTTPS://WWW.YOUTUBE.COM/watch?v=\(id)"
        ]
        for text in accepted {
            XCTAssertEqual(try VideoLink.normalized(text), canonical, text)
        }
        XCTAssertEqual(try VideoLink.normalized("https://youtu.be/abc_-ABC123"), "https://www.youtube.com/watch?v=abc_-ABC123")
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
        XCTAssertThrowsError(try VideoLink.validate(["Bench": "https://www.youtube.com/watch?v=\(id)&t=30"], exercises: ["Bench"]))
        XCTAssertThrowsError(try VideoLink.validate(["Bench": " https://www.youtube.com/watch?v=\(id) "], exercises: ["Bench"]))
    }
}
