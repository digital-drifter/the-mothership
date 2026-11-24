import Foundation
import Testing
@testable import MothershipCore

@Suite struct RefreshPolicyTests {
    @Test func testTheFrontmostAppPollsEverySecond() -> Void {
        #expect(RefreshPolicy.interval(appIsActive: true) == .seconds(1))
        #expect(RefreshPolicy.tolerance(appIsActive: true) == .milliseconds(100))
    }

    @Test func testABackgroundAppPollsEveryFiveSecondsWithLooseTiming() -> Void {
        #expect(RefreshPolicy.interval(appIsActive: false) == .seconds(5))
        #expect(RefreshPolicy.tolerance(appIsActive: false) == .seconds(1))
    }
}
