import XCTest
@testable import PlexChannelsTV

final class ChannelSchedulingTests: XCTestCase {

    private let anchorDate = Date(timeIntervalSinceReferenceDate: 0)

    func testPlaybackPositionWithinSingleCycle() {
        let channel = makeChannel(durations: [60, 60])

        let start = channel.playbackPosition(at: anchorDate)
        XCTAssertEqual(start?.index, 0)
        XCTAssertEqual(start?.offset, 0, accuracy: 0.001)

        let midway = channel.playbackPosition(at: anchorDate.addingTimeInterval(30))
        XCTAssertEqual(midway?.index, 0)
        XCTAssertEqual(midway?.offset, 30, accuracy: 0.001)

        let secondStart = channel.playbackPosition(at: anchorDate.addingTimeInterval(60))
        XCTAssertEqual(secondStart?.index, 1)
        XCTAssertEqual(secondStart?.offset, 0, accuracy: 0.001)

        let secondMid = channel.playbackPosition(at: anchorDate.addingTimeInterval(90))
        XCTAssertEqual(secondMid?.index, 1)
        XCTAssertEqual(secondMid?.offset, 30, accuracy: 0.001)
    }

    func testPlaybackLoopsAfterCycle() {
        let channel = makeChannel(durations: [30, 60, 45])
        let total = 30 + 60 + 45

        let firstCycleEnd = channel.playbackPosition(at: anchorDate.addingTimeInterval(TimeInterval(total)))
        XCTAssertEqual(firstCycleEnd?.index, 0)
        XCTAssertEqual(firstCycleEnd?.offset, 0, accuracy: 0.001)

        let midwayNextCycle = channel.playbackPosition(at: anchorDate.addingTimeInterval(TimeInterval(total + 65)))
        XCTAssertEqual(midwayNextCycle?.index, 1)
        XCTAssertEqual(midwayNextCycle?.offset, 35, accuracy: 0.001)
    }

    func testPlaybackHandlesZeroDurationItemsGracefully() {
        let channel = makeChannel(durations: [0, 45, 0, 30])
        let position = channel.playbackPosition(at: anchorDate.addingTimeInterval(10))
        XCTAssertEqual(position?.index, 1)
        XCTAssertEqual(position?.offset, 10, accuracy: 0.001)
    }

    private func makeChannel(durations: [TimeInterval]) -> Channel {
        let items = durations.enumerated().map { index, duration in
            Channel.Media(
                id: "item-\(index)",
                title: "Item \(index)",
                duration: duration,
                metadataKey: nil,
                partKey: nil,
                partID: nil
            )
        }

        return Channel(
            name: "Test Channel",
            libraryKey: "lib",
            libraryType: .movie,
            createdAt: anchorDate,
            scheduleAnchor: anchorDate,
            items: items
        )
    }
}
