import XCTest
@testable import TextGrabberCore

final class DoublePressTests: XCTestCase {
    private let option: UInt = 1 << 19
    private var two: DoublePressMachine.Key { .init(code: 19, modifiers: option) }
    private var three: DoublePressMachine.Key { .init(code: 20, modifiers: option) }

    func testTwoQuickPressesFireAndNothingReachesTheApp() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyUp(code: 19), .hold)
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .fire(two))
        XCTAssertEqual(machine.keyUp(code: 19), .drop)
        XCTAssertFalse(machine.timeout())
        // The next ordinary key up of that key gets through.
        XCTAssertEqual(machine.keyUp(code: 19), .pass)
    }

    func testOnePressIsSentOnWhenTheTimeRunsOut() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyUp(code: 19), .hold)
        XCTAssertTrue(machine.timeout())
        XCTAssertEqual(machine.keyDown(three, isRepeat: false), .pass)
    }

    func testAnotherKeySendsTheFirstPressOnBeforeIt() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyDown(three, isRepeat: false), .release)
        XCTAssertFalse(machine.timeout())
    }

    func testTheSameKeyWithOtherModifiersIsAnotherKey() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyDown(.init(code: 19, modifiers: 0), isRepeat: false), .release)
    }

    func testHoldingTheKeyDownIsAnOrdinaryPress() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyDown(two, isRepeat: true), .release)
        XCTAssertEqual(machine.keyDown(two, isRepeat: true), .pass)
        XCTAssertEqual(machine.keyUp(code: 19), .pass)
    }

    func testSecondPressWhileTheFirstIsStillDownSwallowsBothKeyUps() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .hold)
        XCTAssertEqual(machine.keyDown(two, isRepeat: false), .fire(two))
        XCTAssertEqual(machine.keyUp(code: 19), .drop)
        XCTAssertEqual(machine.keyUp(code: 19), .drop)
        XCTAssertEqual(machine.keyUp(code: 19), .pass)
    }

    func testAKeyUpThatNeverCameDoesNotSwallowALaterPress() {
        var machine = DoublePressMachine(watched: [two])
        _ = machine.keyDown(two, isRepeat: false)
        _ = machine.keyDown(two, isRepeat: false)   // fired; two key ups owed
        XCTAssertEqual(machine.keyUp(code: 19), .drop)
        // The second key up was lost (the capture took the keyboard). A new press starts afresh.
        XCTAssertEqual(machine.keyDown(.init(code: 19, modifiers: 0), isRepeat: false), .pass)
        XCTAssertEqual(machine.keyUp(code: 19), .pass)
    }

    func testUnwatchedKeysPass() {
        var machine = DoublePressMachine(watched: [two])
        XCTAssertEqual(machine.keyDown(three, isRepeat: false), .pass)
        XCTAssertEqual(machine.keyUp(code: 20), .pass)
    }
}
