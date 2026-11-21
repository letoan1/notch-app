import XCTest
@testable import Notch

final class VietQRTests: XCTestCase {
    func testCRC16CheckValue() {
        // Giá trị kiểm chuẩn của CRC-16/CCITT-FALSE.
        XCTAssertEqual(VietQR.crc16("123456789"), 0x29B1)
        XCTAssertEqual(VietQR.crc16(""), 0xFFFF)
    }

    func testStaticPayload() {
        XCTAssertEqual(VietQR.payload(bin: "970436", account: "0123456789"),
                       "00020101021138540010A00000072701240006970436011001234567890208QRIBFTTA53037045802VN63046A15")
    }

    func testDynamicPayloadWithAmountAndNote() {
        let s = VietQR.payload(bin: "970436", account: "0123456789", amount: 50000, note: "cafe")
        XCTAssertEqual(s, "00020101021238540010A00000072701240006970436011001234567890208QRIBFTTA53037045405500005802VN62080804cafe63044CFA")
    }

    func testZeroAmountAndEmptyNoteAreOmitted() {
        let s = VietQR.payload(bin: "970436", account: "1", amount: 0, note: "")
        XCTAssertTrue(s.hasPrefix("000201010212"))
        XCTAssertFalse(s.contains("5401"))
        XCTAssertFalse(s.contains("6208"))
    }

    func testChecksumCoversPayload() {
        let s = VietQR.payload(bin: "970422", account: "999888777", amount: 12345, note: "Tiền nhà")
        let body = String(s.dropLast(4))
        XCTAssertTrue(body.hasSuffix("6304"))
        XCTAssertEqual(String(s.suffix(4)), String(format: "%04X", VietQR.crc16(body)))
    }

    func testBankBINsAreUnique() {
        XCTAssertEqual(Set(VietQR.banks.map(\.bin)).count, VietQR.banks.count)
        XCTAssertTrue(VietQR.banks.allSatisfy { $0.bin.count == 6 && $0.bin.allSatisfy(\.isNumber) })
    }
}
