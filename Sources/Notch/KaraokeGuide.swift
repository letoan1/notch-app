import Foundation

/// Giọng dẫn cho câu khó khi karaoke: bình thường tắt giọng ca sĩ, tới câu hát nhanh / dày chữ thì cho giọng
/// ca sĩ hát nhỏ để dẫn. LRC chỉ có mốc theo dòng nên "khó" đo bằng số chữ cái mỗi giây của dòng.
enum KaraokeGuide {
    /// Mức giọng ca sĩ ở câu khó (0…1).
    static let level = 0.45
    /// Ballad ~6–9 chữ cái/giây, rap / điệp khúc dồn ~13+.
    static let lettersPerSecond = 12.0

    /// `next` = mốc dòng kế tiếp (nil: dòng cuối). Dòng quá ngắn (tiếng hô, "oh oh") không tính.
    static func isHard(_ text: String, start: Double, next: Double?) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 15, let next, next > start else { return false }
        // Khoảng nghỉ dài sau dòng (dạo nhạc) không làm dòng trông "thưa": chỉ tính tối đa 8 giây.
        return Double(letters) / min(next - start, 8) >= lettersPerSecond
    }
}
