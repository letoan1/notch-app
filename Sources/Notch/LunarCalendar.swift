import Foundation

/// Âm lịch Việt Nam, tính trên máy (thuật toán của Hồ Ngọc Đức, múi giờ UTC+7). Không cần mạng.
struct LunarDate: Equatable {
    let day: Int
    let month: Int
    let year: Int
    let leap: Bool

    private static let tz = 7.0

    init(day: Int, month: Int, year: Int, leap: Bool = false) {
        self.day = day; self.month = month; self.year = year; self.leap = leap
    }

    /// Ngày âm của ngày dương chứa `date` (theo múi giờ của máy).
    init(solar date: Date) {
        // Ngày dương theo lịch của máy (ô lịch người dùng thấy); đổi sang âm theo múi +7 bên trong thuật toán.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let c = cal.dateComponents([.day, .month, .year], from: date)
        self = Self.fromSolar(c.day!, c.month!, c.year!)
    }

    /// "Giáp Thìn"…
    var canChiYear: String {
        let can = ["Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ", "Canh", "Tân", "Nhâm", "Quý"]
        let chi = ["Tý", "Sửu", "Dần", "Mão", "Thìn", "Tỵ", "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi"]
        return can[(year + 6) % 10] + " " + chi[(year + 8) % 12]
    }

    /// Số ngày từ `date` tới mùng 1 Tết kế tiếp (0 = hôm nay là mùng 1).
    static func daysUntilTet(from date: Date) -> Int {
        // Ngày dương theo lịch của máy (ô lịch người dùng thấy); đổi sang âm theo múi +7 bên trong thuật toán.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let c = cal.dateComponents([.day, .month, .year], from: date)
        let today = jd(c.day!, c.month!, c.year!)
        let lunar = fromSolar(c.day!, c.month!, c.year!)
        if lunar.day == 1, lunar.month == 1, !lunar.leap { return 0 }
        return tetJD(lunarYear: lunar.year + 1) - today
    }

    // MARK: - Thuật toán

    static func jd(_ dd: Int, _ mm: Int, _ yy: Int) -> Int {
        let a = (14 - mm) / 12, y = yy + 4800 - a, m = mm + 12 * a - 3
        var j = dd + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        if j < 2299161 { j = dd + (153 * m + 2) / 5 + 365 * y + y / 4 - 32083 }
        return j
    }

    private static func newMoon(_ k: Int) -> Double {
        let T = Double(k) / 1236.85, T2 = T * T, T3 = T2 * T, dr = Double.pi / 180
        var jd1 = 2415020.75933 + 29.53058868 * Double(k) + 0.0001178 * T2 - 0.000000155 * T3
        jd1 += 0.00033 * sin((166.56 + 132.87 * T - 0.009173 * T2) * dr)
        let M = 359.2242 + 29.10535608 * Double(k) - 0.0000333 * T2 - 0.00000347 * T3
        let Mpr = 306.0253 + 385.81691806 * Double(k) + 0.0107306 * T2 + 0.00001236 * T3
        let F = 21.2964 + 390.67050646 * Double(k) - 0.0016528 * T2 - 0.00000239 * T3
        var c1 = (0.1734 - 0.000393 * T) * sin(M * dr) + 0.0021 * sin(2 * dr * M)
        c1 = c1 - 0.4068 * sin(Mpr * dr) + 0.0161 * sin(dr * 2 * Mpr)
        c1 = c1 - 0.0004 * sin(dr * 3 * Mpr)
        c1 = c1 + 0.0104 * sin(dr * 2 * F) - 0.0051 * sin(dr * (M + Mpr))
        c1 = c1 - 0.0074 * sin(dr * (M - Mpr)) + 0.0004 * sin(dr * (2 * F + M))
        c1 = c1 - 0.0004 * sin(dr * (2 * F - M)) - 0.0006 * sin(dr * (2 * F + Mpr))
        c1 = c1 + 0.0010 * sin(dr * (2 * F - Mpr)) + 0.0005 * sin(dr * (2 * Mpr + M))
        let deltat = T < -11 ? 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3
                             : -0.000278 + 0.000265 * T + 0.000262 * T2
        return jd1 + c1 - deltat
    }

    private static func sunLongitude(_ jdn: Double) -> Double {
        let T = (jdn - 2451545.0) / 36525, T2 = T * T, dr = Double.pi / 180
        let M = 357.52910 + 35999.05030 * T - 0.0001559 * T2 - 0.00000048 * T * T2
        let L0 = 280.46645 + 36000.76983 * T + 0.0003032 * T2
        var DL = (1.914600 - 0.004817 * T - 0.000014 * T2) * sin(dr * M)
        DL += (0.019993 - 0.000101 * T) * sin(dr * 2 * M) + 0.000290 * sin(dr * 3 * M)
        var L = (L0 + DL) * dr
        L -= Double.pi * 2 * (L / (Double.pi * 2)).rounded(.down)
        return L
    }

    private static func newMoonDay(_ k: Int) -> Int { Int((newMoon(k) + 0.5 + tz / 24).rounded(.down)) }
    private static func sunSector(_ dayNumber: Int) -> Int {
        Int((sunLongitude(Double(dayNumber) - 0.5 - tz / 24) / Double.pi * 6).rounded(.down))
    }

    private static func lunarMonth11(_ yy: Int) -> Int {
        let off = jd(31, 12, yy) - 2415021
        let k = Int((Double(off) / 29.530588853).rounded(.down))
        var nm = newMoonDay(k)
        if sunSector(nm) >= 9 { nm = newMoonDay(k - 1) }
        return nm
    }

    private static func leapMonthOffset(_ a11: Int) -> Int {
        let k = Int((Double(a11 - 2415021) / 29.530588853 + 0.5).rounded(.down))
        var last = 0, i = 1
        var arc = sunSector(newMoonDay(k + i))
        repeat {
            last = arc
            i += 1
            arc = sunSector(newMoonDay(k + i))
        } while arc != last && i < 14
        return i - 1
    }

    static func fromSolar(_ dd: Int, _ mm: Int, _ yy: Int) -> LunarDate {
        let dayNumber = jd(dd, mm, yy)
        let k = Int((Double(dayNumber - 2415021) / 29.530588853).rounded(.down))
        var monthStart = newMoonDay(k + 1)
        if monthStart > dayNumber { monthStart = newMoonDay(k) }
        var a11 = lunarMonth11(yy), b11 = a11
        var lunarYear: Int
        if a11 >= monthStart {
            lunarYear = yy
            a11 = lunarMonth11(yy - 1)
        } else {
            lunarYear = yy + 1
            b11 = lunarMonth11(yy + 1)
        }
        let day = dayNumber - monthStart + 1
        let diff = (monthStart - a11) / 29
        var leap = false
        var month = diff + 11
        if b11 - a11 > 365 {
            let leapDiff = leapMonthOffset(a11)
            if diff >= leapDiff {
                month = diff + 10
                if diff == leapDiff { leap = true }
            }
        }
        if month > 12 { month -= 12 }
        if month >= 11 && diff < 4 { lunarYear -= 1 }
        return LunarDate(day: day, month: month, year: lunarYear, leap: leap)
    }

    /// Ngày Julius của mùng 1 tháng Giêng năm âm `lunarYear` (Tết luôn nằm trong 21/1–20/2 dương lịch).
    private static func tetJD(lunarYear: Int) -> Int {
        let start = jd(21, 1, lunarYear)
        for d in 0..<31 {
            let (dd, mm, yy) = solar(fromJD: start + d)
            let l = fromSolar(dd, mm, yy)
            if l.day == 1, l.month == 1, !l.leap { return start + d }
        }
        return start
    }

    private static func solar(fromJD jd: Int) -> (Int, Int, Int) {
        let a = jd + 32044, b = (4 * a + 3) / 146097, c = a - b * 146097 / 4
        let d = (4 * c + 3) / 1461, e = c - 1461 * d / 4, m = (5 * e + 2) / 153
        return (e - (153 * m + 2) / 5 + 1, m + 3 - 12 * (m / 10), b * 100 + d - 4800 + m / 10)
    }
}
