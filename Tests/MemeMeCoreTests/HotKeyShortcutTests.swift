import XCTest
@testable import MemeMeCore

final class HotKeyShortcutTests: XCTestCase {
    private let k: UInt32 = 40
    private let space: UInt32 = 49
    private let f5: UInt32 = 96
    private let left: UInt32 = 123

    func testStandardIsOptionM() {
        XCTAssertEqual(HotKeyShortcut.standard.display(), "⌥M")
        XCTAssertEqual(HotKeyShortcut.standard.symbols(), ["⌥", "M"])
        XCTAssertEqual(HotKeyShortcut.standard.spokenName(), "Option M")
        XCTAssertNil(HotKeyShortcut.standard.problem)
    }

    func testModifiersShowInMenuOrder() {
        let all = HotKeyShortcut.command | HotKeyShortcut.shift | HotKeyShortcut.option | HotKeyShortcut.control
        let shortcut = HotKeyShortcut(keyCode: k, modifiers: all)
        XCTAssertEqual(shortcut.display(), "⌃⌥⇧⌘K")
        XCTAssertEqual(shortcut.spokenName(), "Control Option Shift Command K")
    }

    func testOtherFlagsAreDropped() {
        let capsLock: UInt32 = 1024
        XCTAssertEqual(HotKeyShortcut(keyCode: 46, modifiers: HotKeyShortcut.option | capsLock), .standard)
    }

    func testSpecialKeysHaveNames() {
        XCTAssertEqual(HotKeyShortcut(keyCode: space, modifiers: HotKeyShortcut.option).display(), "⌥Space")
        XCTAssertEqual(HotKeyShortcut(keyCode: left, modifiers: HotKeyShortcut.control).display(), "⌃←")
        XCTAssertEqual(HotKeyShortcut(keyCode: left, modifiers: HotKeyShortcut.control).spokenName(), "Control Left Arrow")
        XCTAssertEqual(HotKeyShortcut(keyCode: f5, modifiers: 0).display(), "F5")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 93), "Key 93")
    }

    func testTheLayoutNameReplacesOnlyCharacterKeys() {
        // AZERTY: the ANSI Q position is A.
        XCTAssertEqual(HotKeyShortcut(keyCode: 12, modifiers: HotKeyShortcut.option).display(keyName: "A"), "⌥A")
        XCTAssertEqual(HotKeyShortcut(keyCode: f5, modifiers: HotKeyShortcut.option).display(keyName: "x"), "⌥F5")
        XCTAssertEqual(HotKeyShortcut.standard.display(keyName: ""), "⌥M")
    }

    func testAKeyNeedsControlOptionOrCommand() {
        XCTAssertEqual(HotKeyShortcut(keyCode: k, modifiers: 0).problem, .needsModifier)
        XCTAssertEqual(HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.shift).problem, .needsModifier)
        XCTAssertNil(HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.control).problem)
        XCTAssertNil(HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.option | HotKeyShortcut.shift).problem)
    }

    func testFunctionKeysWorkAlone() {
        XCTAssertNil(HotKeyShortcut(keyCode: f5, modifiers: 0).problem)
        XCTAssertNil(HotKeyShortcut(keyCode: f5, modifiers: HotKeyShortcut.command).problem)
    }

    func testCommandAloneIsLeftToTheAppInFront() {
        XCTAssertEqual(HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.command).problem, .commandOnly)
        XCTAssertNil(HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.command | HotKeyShortcut.shift).problem)
    }

    func testTheScreenCutAndMacOSShortcutsAreRefused() {
        XCTAssertEqual(HotKeyShortcut.screenCut.problem, .screenCut)
        XCTAssertEqual(HotKeyShortcut(keyCode: space, modifiers: HotKeyShortcut.control).problem, .reserved)
        XCTAssertEqual(HotKeyShortcut(keyCode: 21, modifiers: HotKeyShortcut.command | HotKeyShortcut.shift).problem, .reserved)
        XCTAssertEqual(HotKeyShortcut(keyCode: space, modifiers: HotKeyShortcut.control).problemMessage(),
                       "macOS uses ⌃Space. Pick another.")
        XCTAssertNil(HotKeyShortcut.standard.problemMessage())
    }
}
