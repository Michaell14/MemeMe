import XCTest
@testable import MemeMeCore

final class HotKeyShortcutTests: XCTestCase {
    private let k: UInt32 = 40
    private let space: UInt32 = 49
    private let f5: UInt32 = 96
    private let left: UInt32 = 123

    /// The problem as the panel's shortcut while the screen cut is on ⌥S.
    private func panelProblem(_ keyCode: UInt32, _ modifiers: UInt32) -> HotKeyShortcut.Problem? {
        HotKeyShortcut(keyCode: keyCode, modifiers: modifiers).problem(as: .panel, besides: .screenCut)
    }

    func testStandardIsOptionM() {
        XCTAssertEqual(HotKeyShortcut.standard.display(), "⌥M")
        XCTAssertEqual(HotKeyShortcut.standard.symbols(), ["⌥", "M"])
        XCTAssertEqual(HotKeyShortcut.standard.spokenName(), "Option M")
        XCTAssertNil(HotKeyShortcut.standard.problem(as: .panel, besides: .screenCut))
        XCTAssertEqual(HotKeyRole.panel.standard, .standard)
        XCTAssertEqual(HotKeyRole.screenCut.standard, .screenCut)
        XCTAssertEqual(HotKeyShortcut.screenCut.display(), "⌥S")
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
        XCTAssertEqual(panelProblem(k, 0), .needsModifier)
        XCTAssertEqual(panelProblem(k, HotKeyShortcut.shift), .needsModifier)
        XCTAssertNil(panelProblem(k, HotKeyShortcut.control))
        XCTAssertNil(panelProblem(k, HotKeyShortcut.option | HotKeyShortcut.shift))
    }

    func testFunctionKeysWorkAlone() {
        XCTAssertNil(panelProblem(f5, 0))
        XCTAssertNil(panelProblem(f5, HotKeyShortcut.command))
    }

    func testCommandAloneIsLeftToTheAppInFront() {
        XCTAssertEqual(panelProblem(k, HotKeyShortcut.command), .commandOnly)
        XCTAssertNil(panelProblem(k, HotKeyShortcut.command | HotKeyShortcut.shift))
    }

    func testEachShortcutRefusesTheOthersKeys() {
        XCTAssertEqual(HotKeyShortcut.screenCut.problem(as: .panel, besides: .screenCut), .inUse)
        XCTAssertEqual(HotKeyShortcut.screenCut.problemMessage(as: .panel, besides: .screenCut),
                       "⌥S cuts stickers from the screen. Pick another.")
        XCTAssertEqual(HotKeyShortcut.standard.problemMessage(as: .screenCut, besides: .standard),
                       "⌥M opens MemeMe. Pick another.")
        // Once the panel moved off ⌥M, the screen cut can have it.
        let controlOptionK = HotKeyShortcut(keyCode: k, modifiers: HotKeyShortcut.control | HotKeyShortcut.option)
        XCTAssertNil(HotKeyShortcut.standard.problem(as: .screenCut, besides: controlOptionK))
    }

    func testMacOSShortcutsAreRefused() {
        XCTAssertEqual(panelProblem(space, HotKeyShortcut.control), .reserved)
        XCTAssertEqual(panelProblem(21, HotKeyShortcut.command | HotKeyShortcut.shift), .reserved)
        XCTAssertEqual(HotKeyShortcut(keyCode: space, modifiers: HotKeyShortcut.control)
                        .problemMessage(as: .screenCut, besides: .standard),
                       "macOS uses ⌃Space. Pick another.")
        XCTAssertNil(HotKeyShortcut.standard.problemMessage(as: .panel, besides: .screenCut))
    }
}
