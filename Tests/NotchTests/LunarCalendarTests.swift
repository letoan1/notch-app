import XCTest
@testable import Notch

/// Âm lịch: so với các ngày Tết, Trung thu và tháng nhuận đã biết.
final class LunarCalendarTests: XCTestCase {
    func testTetDates() {
        XCTAssertEqual(LunarDate.fromSolar(22, 1, 2023), LunarDate(day: 1, month: 1, year: 2023))
        XCTAssertEqual(LunarDate.fromSolar(10, 2, 2024), LunarDate(day: 1, month: 1, year: 2024))
        XCTAssertEqual(LunarDate.fromSolar(29, 1, 2025), LunarDate(day: 1, month: 1, year: 2025))
        XCTAssertEqual(LunarDate.fromSolar(17, 2, 2026), LunarDate(day: 1, month: 1, year: 2026))
    }

    func testDayBeforeTetBelongsToPreviousYear() {
        XCTAssertEqual(LunarDate.fromSolar(28, 1, 2025), LunarDate(day: 29, month: 12, year: 2024))
        XCTAssertEqual(LunarDate.fromSolar(1, 1, 2025), LunarDate(day: 2, month: 12, year: 2024))
    }

    func testMidAutumn() {
        XCTAssertEqual(LunarDate.fromSolar(17, 9, 2024), LunarDate(day: 15, month: 8, year: 2024))
    }

    func testLeapMonths() {
        // Năm 2023 nhuận tháng 2, năm 2020 nhuận tháng 4.
        XCTAssertEqual(LunarDate.fromSolar(22, 3, 2023), LunarDate(day: 1, month: 2, year: 2023, leap: true))
        XCTAssertEqual(LunarDate.fromSolar(21, 3, 2023), LunarDate(day: 30, month: 2, year: 2023, leap: false))
        XCTAssertEqual(LunarDate.fromSolar(23, 5, 2020), LunarDate(day: 1, month: 4, year: 2020, leap: true))
    }

    func testCanChiYear() {
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 2024).canChiYear, "Giáp Thìn")
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 2025).canChiYear, "Ất Tỵ")
        XCTAssertEqual(LunarDate(day: 1, month: 1, year: 2026).canChiYear, "Bính Ngọ")
    }

    func testJulianDay() {
        XCTAssertEqual(LunarDate.jd(1, 1, 2000), 2451545)
    }

    func testDaysUntilTet() {
        func local(_ d: Int, _ m: Int, _ y: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Calendar.current.timeZone
            return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        XCTAssertEqual(LunarDate.daysUntilTet(from: local(17, 2, 2026)), 0)
        XCTAssertEqual(LunarDate.daysUntilTet(from: local(16, 2, 2026)), 1)
        XCTAssertEqual(LunarDate.daysUntilTet(from: local(1, 2, 2026)), 16)
        XCTAssertEqual(LunarDate(solar: local(10, 2, 2024)), LunarDate(day: 1, month: 1, year: 2024))
    }
}
