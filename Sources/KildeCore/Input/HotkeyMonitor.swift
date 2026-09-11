import Foundation
import Carbon.HIToolbox

/// ホットキーのモディファイア。Carbon のビット表現を公開 API に漏らさないため、
/// KildeCore 独自の値として保持する。
public struct HotkeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let shift = HotkeyModifiers(rawValue: 1 << 1)
    public static let option = HotkeyModifiers(rawValue: 1 << 2)
    public static let control = HotkeyModifiers(rawValue: 1 << 3)
    public static let function = HotkeyModifiers(rawValue: 1 << 4)
}

/// パース済みのホットキー。keyCode は macOS の物理キーコード。
public struct Hotkey: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: HotkeyModifiers
    /// エイリアスと大文字小文字を正規化した表示文字列。
    public let normalized: String

    public init(keyCode: UInt32, modifiers: HotkeyModifiers, normalized: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.normalized = normalized
    }
}

/// `cmd+shift+r` 形式を副作用なしで解釈する。
public enum HotkeyParser {
    public static func parse(_ source: String) throws -> Hotkey {
        let parts = source.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw invalid(source, reason: "+ の前後に空の要素があります")
        }

        var modifiers: HotkeyModifiers = []
        var parsedKey: (code: UInt32, name: String)?
        for part in parts {
            if let modifier = modifier(for: part) {
                guard !modifiers.contains(modifier.value) else {
                    throw invalid(source, reason: "モディファイア \(modifier.name) が重複しています")
                }
                modifiers.insert(modifier.value)
                continue
            }
            guard parsedKey == nil, let candidate = key(for: part) else {
                let reason = parsedKey == nil ? "不明なキー \"\(part)\" です" : "キーは 1 つだけ指定してください"
                throw invalid(source, reason: reason)
            }
            parsedKey = candidate
        }

        guard !modifiers.isEmpty else {
            throw invalid(source, reason: "モディファイアを 1 つ以上指定してください")
        }
        guard let parsedKey else {
            throw invalid(source, reason: "キーを指定してください")
        }

        let orderedModifiers: [(HotkeyModifiers, String)] = [
            (.command, "cmd"), (.shift, "shift"), (.option, "opt"),
            (.control, "ctrl"), (.function, "fn"),
        ]
        let names = orderedModifiers.compactMap { modifiers.contains($0.0) ? $0.1 : nil }
        return Hotkey(keyCode: parsedKey.code, modifiers: modifiers,
                      normalized: (names + [parsedKey.name]).joined(separator: "+"))
    }

    private static func invalid(_ source: String, reason: String) -> KilError {
        KilError.failed("ホットキー \"\(source)\" が不正です: \(reason)")
    }

    private static func modifier(for token: String) -> (value: HotkeyModifiers, name: String)? {
        switch token {
        case "cmd", "command", "⌘": return (.command, "cmd")
        case "shift", "⇧": return (.shift, "shift")
        case "opt", "option", "alt", "⌥": return (.option, "opt")
        case "ctrl", "control", "^": return (.control, "ctrl")
        case "fn": return (.function, "fn")
        default: return nil
        }
    }

    private static func key(for token: String) -> (code: UInt32, name: String)? {
        if let code = letterKeyCodes[token] { return (code, token) }
        if let code = digitKeyCodes[token] { return (code, token) }
        if token.hasPrefix("f"), let number = Int(token.dropFirst()),
           let code = functionKeyCodes[number] {
            return (code, "f\(number)")
        }
        let aliases: [String: (UInt32, String)] = [
            "space": (UInt32(kVK_Space), "space"),
            "tab": (UInt32(kVK_Tab), "tab"),
            "left": (UInt32(kVK_LeftArrow), "left"),
            "arrowleft": (UInt32(kVK_LeftArrow), "left"),
            "arrow-left": (UInt32(kVK_LeftArrow), "left"),
            "arrow left": (UInt32(kVK_LeftArrow), "left"),
            "right": (UInt32(kVK_RightArrow), "right"),
            "arrowright": (UInt32(kVK_RightArrow), "right"),
            "arrow-right": (UInt32(kVK_RightArrow), "right"),
            "arrow right": (UInt32(kVK_RightArrow), "right"),
            "up": (UInt32(kVK_UpArrow), "up"),
            "arrowup": (UInt32(kVK_UpArrow), "up"),
            "arrow-up": (UInt32(kVK_UpArrow), "up"),
            "arrow up": (UInt32(kVK_UpArrow), "up"),
            "down": (UInt32(kVK_DownArrow), "down"),
            "arrowdown": (UInt32(kVK_DownArrow), "down"),
            "arrow-down": (UInt32(kVK_DownArrow), "down"),
            "arrow down": (UInt32(kVK_DownArrow), "down"),
            "return": (UInt32(kVK_Return), "return"),
            "enter": (UInt32(kVK_Return), "return"),
            "escape": (UInt32(kVK_Escape), "escape"),
            "esc": (UInt32(kVK_Escape), "escape"),
            "delete": (UInt32(kVK_Delete), "delete"),
        ]
        return aliases[token]
    }

    private static let letterKeyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
    ]

    private static let digitKeyCodes: [String: UInt32] = [
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
    ]

    private static let functionKeyCodes: [Int: UInt32] = [
        1: UInt32(kVK_F1), 2: UInt32(kVK_F2), 3: UInt32(kVK_F3),
        4: UInt32(kVK_F4), 5: UInt32(kVK_F5), 6: UInt32(kVK_F6),
        7: UInt32(kVK_F7), 8: UInt32(kVK_F8), 9: UInt32(kVK_F9),
        10: UInt32(kVK_F10), 11: UInt32(kVK_F11), 12: UInt32(kVK_F12),
    ]
}

/// Carbon のシステムワイドホットキー登録を管理する。
///
/// `start()` / `stop()` はメインスレッドから呼ぶこと。押下コールバックも Carbon の
/// メインイベントループ上、つまりメインスレッドで呼ばれる。CLI は待機中にメイン
/// RunLoop を回し、GUI は通常の AppKit イベントループをそのまま利用できる。
public final class HotkeyMonitor {
    private static let signature: OSType = 0x4B_49_4C_44 // "KILD"
    private static let identifierLock = NSLock()
    private static var nextIdentifier: UInt32 = 1

    public let source: String
    public let hotkey: Hotkey
    private let handler: () -> Void
    private let identifier: UInt32
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public init(_ source: String, handler: @escaping () -> Void) throws {
        self.source = source
        self.hotkey = try HotkeyParser.parse(source)
        self.handler = handler
        Self.identifierLock.lock()
        identifier = Self.nextIdentifier
        Self.nextIdentifier &+= 1
        Self.identifierLock.unlock()
    }

    /// 二重 start は無視する。登録済みの組合せとの衝突を含む登録失敗は KilError。
    public func start() throws {
        precondition(Thread.isMainThread, "HotkeyMonitor.start() はメインスレッドから呼んでください")
        guard hotkeyRef == nil, eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                return monitor.receive(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            eventHandlerRef = nil
            throw KilError.failed("ホットキー \"\(source)\" のイベント監視を開始できません (OSStatus \(installStatus))")
        }

        let hotkeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            hotkey.keyCode, carbonModifiers, hotkeyID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotkeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            hotkeyRef = nil
            throw KilError.failed("ホットキー \"\(source)\" を登録できません (他のアプリとの競合または OSStatus \(registerStatus))")
        }
    }

    /// 二重 stop は無視する。
    public func stop() {
        precondition(Thread.isMainThread, "HotkeyMonitor.stop() はメインスレッドから呼んでください")
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        hotkeyRef = nil
        eventHandlerRef = nil
    }

    private var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if hotkey.modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if hotkey.modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if hotkey.modifiers.contains(.option) { value |= UInt32(optionKey) }
        if hotkey.modifiers.contains(.control) { value |= UInt32(controlKey) }
        if hotkey.modifiers.contains(.function) { value |= UInt32(kEventKeyModifierFnMask) }
        return value
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID
        )
        guard status == noErr,
              receivedID.signature == Self.signature,
              receivedID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }
        handler()
        return noErr
    }
}

/// doctor が Carbon 登録経路を診断する。イベント配送は不要なので、一時登録後すぐ解除する。
public enum HotkeyDiagnostics {
    public static let probeKey = "cmd+opt+ctrl+shift+f12"

    public static func checkRegistration() throws {
        precondition(Thread.isMainThread, "ホットキー診断はメインスレッドから実行してください")
        let monitor = try HotkeyMonitor(probeKey) {}
        try monitor.start()
        monitor.stop()
    }
}

/// CLI と GUI で同じ優先順位を使うため、ホットキーの解決を KildeCore に置く。
public enum HotkeySettings {
    /// 優先順位は CLI 引数 > 設定ファイル > 待機モードなし。
    public static func resolve(explicit: String?, config: KildeConfig) throws -> String? {
        guard let source = explicit ?? config.hotkey else { return nil }
        _ = try HotkeyParser.parse(source)
        return source
    }
}
