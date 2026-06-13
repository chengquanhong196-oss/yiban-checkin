import XCTest
@testable import YibanCheckinCore

final class YibanCheckinTests: XCTestCase {

    // MARK: - Config

    func testConfigDefaults() {
        let c = Config()
        XCTAssertEqual(c.radiusMeters, 500)
        XCTAssertEqual(c.checkinStartHour, 21)
        XCTAssertEqual(c.checkinStartMinute, 30)
        XCTAssertEqual(c.checkinMethod, "auto")
    }

    // MARK: - Keychain

    func testKeychainSetGetDelete() {
        Keychain.set("test123", forKey: "test_key")
        XCTAssertEqual(Keychain.get("test_key"), "test123")
        Keychain.delete("test_key")
        XCTAssertNil(Keychain.get("test_key"))
    }

    // MARK: - Logger

    func testLoggerLevels() {
        // Logger should default to info level, not crash
        Logger.info("test info")
        Logger.warn("test warn")
        Logger.error("test error")
        // just verifying no crash
        XCTAssertTrue(true)
    }

    // MARK: - Location

    func testHaversineDistance() {
        // Use LocationChecker's haversine function indirectly
        let checker = LocationChecker(config: Config())
        // Just check it initializes without crash
        XCTAssertNotNil(checker)
    }

    // MARK: - School Database

    func testSchoolDatabaseSearch() {
        let results = SchoolDatabase.search("福州")
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertTrue(results.contains(where: { $0.name == "福州大学" }))
    }

    func testSchoolDatabaseCampusCount() {
        guard let fzu = SchoolDatabase.find(name: "福州大学") else {
            XCTFail("福州大学 should exist")
            return
        }
        XCTAssertEqual(fzu.campuses.count, 4)
        XCTAssertEqual(fzu.yibanAct, "iapp7463")
    }

    func testSchoolDatabaseEmptySearch() {
        let results = SchoolDatabase.search("不存在的学校名xyzqwe")
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Verification Solver

    func testVerificationSolverShapes() {
        XCTAssertTrue(VerificationSolver.allShapes.count > 10)
        XCTAssertTrue(VerificationSolver.is3DShape.contains("立方体"))
        XCTAssertFalse(VerificationSolver.is3DShape.contains("三角形"))
    }

    func testColorDistance() {
        let red = NSColor.red
        let blue = NSColor.blue
        let dist = VerificationSolver.colorDistance(red, blue)
        XCTAssertGreaterThan(dist, 0.5)
    }

    // MARK: - Checkin History

    func testDaysInMonth() {
        let days = CheckinHistory.daysPassedThisMonth()
        XCTAssertTrue(days >= 28 && days <= 31)
    }

    // MARK: - API Error

    func testAPIErrorPermanent() {
        let perm = APIError.loginFailed("密码错误", permanent: true)
        XCTAssertTrue(perm.isPermanent)

        let temp = APIError.loginFailed("网络超时", permanent: false)
        XCTAssertFalse(temp.isPermanent)
    }

    // MARK: - Permission Checker

    func testDiagnosticRuns() {
        let result = PermissionChecker.runDiagnostics(config: Config())
        // Should return a result with issues (no config set)
        XCTAssertNotNil(result)
    }
}
