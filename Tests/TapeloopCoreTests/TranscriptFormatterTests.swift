import Foundation
import TapeloopCore
import XCTest

final class TranscriptFormatterTests: XCTestCase {
    private let transcript = Transcript(
        locale: "en-US", createdAt: Date(timeIntervalSince1970: 0),
        segments: [
            TranscriptSegment(start: 751.2, end: 781.9, speaker: .system, text: "Okay, the release is Friday."),
            TranscriptSegment(start: 782, end: 799.5, speaker: .microphone, text: "I will send the deck\ntonight."),
            TranscriptSegment(start: 3723.4567, end: 3725, text: "No speaker here."),
        ])

    func testTimestamps() {
        XCTAssertEqual(TranscriptFormatter.timestamp(0), "00:00")
        XCTAssertEqual(TranscriptFormatter.timestamp(782.9), "13:02")
        XCTAssertEqual(TranscriptFormatter.timestamp(3599.99), "59:59")
        XCTAssertEqual(TranscriptFormatter.timestamp(3600), "1:00:00")
        XCTAssertEqual(TranscriptFormatter.timestamp(3723), "1:02:03")
        XCTAssertEqual(TranscriptFormatter.timestamp(-5), "00:00")
    }

    func testPlainText() {
        XCTAssertEqual(
            TranscriptFormatter.plainText(transcript, title: "Weekly sync"),
            """
            Weekly sync

            [12:31] System: Okay, the release is Friday.
            [13:02] You: I will send the deck tonight.
            [1:02:03] No speaker here.

            """)
        XCTAssertEqual(
            TranscriptFormatter.plainText(Transcript(locale: "en", segments: [transcript.segments[1]]), title: " "),
            "[13:02] You: I will send the deck tonight.\n")
    }

    func testSRT() {
        XCTAssertEqual(
            TranscriptFormatter.srt(transcript),
            """
            1
            00:12:31,200 --> 00:13:01,900
            System: Okay, the release is Friday.

            2
            00:13:02,000 --> 00:13:19,500
            You: I will send the deck tonight.

            3
            01:02:03,457 --> 01:02:05,000
            No speaker here.

            """)
    }

    func testSRTClampsBackwardsTimes() {
        let odd = Transcript(locale: "en", segments: [TranscriptSegment(start: 10, end: 9, text: "x")])
        XCTAssertEqual(TranscriptFormatter.srt(odd), "1\n00:00:10,000 --> 00:00:10,000\nx\n")
        XCTAssertEqual(TranscriptFormatter.srt(Transcript(locale: "en", segments: [])), "")
    }

    func testSpeakerNames() {
        XCTAssertEqual(TranscriptFormatter.speakerName(.microphone), "You")
        XCTAssertEqual(TranscriptFormatter.speakerName(.system), "System")
    }
}
