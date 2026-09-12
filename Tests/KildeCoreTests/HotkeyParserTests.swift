import XCTest
@testable import KildeCore

/// 純粋な文字列パーサだけを検証する。Carbon のグローバル登録は副作用があるため行わない。
final class HotkeyParserTests: XCTestCase {
    func testParsesSupportedModifierAliases() throws {
        let cases: [(String, String, HotkeyModifiers)] = [
            ("cmd+r", "cmd+r", [.command]),
            ("command+r", "cmd+r", [.command]),
            ("⌘+r", "cmd+r", [.command]),
            ("shift+r", "shift+r", [.shift]),
            ("⇧+r", "shift+r", [.shift]),
            ("opt+r", "opt+r", [.option]),
            ("option+r", "opt+r", [.option]),
            ("alt+r", "opt+r", [.option]),
            ("⌥+r", "opt+r", [.option]),
            ("ctrl+r", "ctrl+r", [.control]),
            ("control+r", "ctrl+r", [.control]),
            ("^+r", "ctrl+r", [.control]),
        ]
        for (source, normalized, modifiers) in cases {
            let parsed = try HotkeyParser.parse(source)
            XCTAssertEqual(parsed.normalized, normalized, source)
            XCTAssertEqual(parsed.modifiers, modifiers, source)
        }
    }

    func testAcceptsCaseAndWhitespaceAndNormalizesModifierOrder() throws {
        let parsed = try HotkeyParser.parse("  SHIFT + Command + Option + CTRL + R  ")
        XCTAssertEqual(parsed.normalized, "cmd+shift+opt+ctrl+r")
        XCTAssertEqual(parsed.modifiers, [.command, .shift, .option, .control])
    }

    func testRejectsFunctionModifier() {
        // fn は登録だけ成功して押下が届かないため、待機のままにならないよう専用エラーで弾く
        for source in ["fn+r", "cmd+fn+r", "FN+R"] {
            XCTAssertThrowsError(try HotkeyParser.parse(source), source) { error in
                XCTAssertTrue("\(error)".contains("fn キーはホットキーに使えません"), "\(source): \(error)")
            }
        }
    }

    func testParsesAllSupportedKeys() {
        let letters = (UnicodeScalar("a").value...UnicodeScalar("z").value)
            .compactMap(UnicodeScalar.init).map(String.init)
        let digits = (0...9).map(String.init)
        let functionKeys = (1...12).map { "f\($0)" }
        let named = ["space", "tab", "left", "right", "up", "down",
                     "return", "escape", "delete"]
        for key in letters + digits + functionKeys + named {
            XCTAssertNoThrow(try HotkeyParser.parse("cmd+\(key)"), key)
        }
    }

    func testParsesArrowAndNamedKeyAliases() throws {
        XCTAssertEqual(try HotkeyParser.parse("cmd+arrow-left").normalized, "cmd+left")
        XCTAssertEqual(try HotkeyParser.parse("cmd+arrow left").normalized, "cmd+left")
        XCTAssertEqual(try HotkeyParser.parse("cmd+arrowright").normalized, "cmd+right")
        XCTAssertEqual(try HotkeyParser.parse("cmd+arrow-up").normalized, "cmd+up")
        XCTAssertEqual(try HotkeyParser.parse("cmd+arrowdown").normalized, "cmd+down")
        XCTAssertEqual(try HotkeyParser.parse("cmd+enter").normalized, "cmd+return")
        XCTAssertEqual(try HotkeyParser.parse("cmd+esc").normalized, "cmd+escape")
    }

    func testRejectsInvalidInputs() {
        let invalid = [
            "", "r", "cmd", "cmd+shift", "cmd+f13", "cmd+unknown",
            "cmd+r+s", "cmd++r", "+cmd+r", "cmd+r+", "cmd+command+r",
        ]
        for source in invalid {
            XCTAssertThrowsError(try HotkeyParser.parse(source), source) { error in
                if !source.isEmpty {
                    XCTAssertTrue("\(error)".contains(source), "\(source): \(error)")
                }
            }
        }
    }
}
