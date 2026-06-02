#if os(iOS)
import SwiftUI
import UIKit
import RworkClient

/// The iOS input **host** that assembles the four inert table-stakes components (doc 17 §2.5)
/// into one working input surface, replacing the plain SwiftUI `TextField` on iOS.
///
/// The four components are deliberately UIKit-free or single-purpose and own no wiring; this is
/// the `UIView` that owns and connects them:
///
/// - **Hardware keyboard** — the key-encoding presses are intercepted **on the IME proxy** (the
///   only first responder, so the only view that receives `UIPress` events), classified by
///   ``InputRouting``, and surfaced to this host via the proxy's `onKeyPress`/`onKeyRelease`.
///   Key-path presses (Esc / Tab / arrows / Return / Delete and Ctrl/Alt+letter) are fed into a
///   ``KeyRepeater`` (manual auto-repeat, since UIKit fires each physical key once); each
///   ``KeyRepeater`` fire encodes the press to bytes and forwards them to `sendInput`. Plain
///   printable presses fall through to the proxy's text system so CJK composition is never broken.
/// - **Software keyboard accessory** — a ``KeyboardAccessoryBar`` is the view's
///   `inputAccessoryView`, shown/hidden by ``KeyboardAccessoryDecision`` driven from the
///   keyboard-frame notifications. Its `onKey` (Esc/Tab/arrows, Ctrl-folded) forwards to
///   `sendInput`.
/// - **IME / printable text** — the embedded ``IMEProxyTextView`` is the sole first responder;
///   its committed `onText` (post-IME-composition) is UTF-8 encoded and forwarded to `sendInput`.
/// - **Floating cursor** — the spacebar long-press floating cursor is delivered to the text-input
///   first responder; ``IMEProxyTextView`` forwards `begin/update/end` to a
///   ``FloatingCursorController``, whose `onArrows` (← / →) forward to `sendInput`.
///
/// Everything reaches `RworkClient.sendInput` through ``InputBarModel``. Only committed
/// printable / IME text is recorded into the B1 echo-dedup ring (``InputBarModel/sendText(_:over:)``,
/// no implicit Enter), because the PTY echoes only that. Control sequences — special keys,
/// Ctrl/Alt codes, accessory taps, floating-cursor arrows — go through the **non-recording**
/// ``InputBarModel/sendRaw(_:over:record:)`` (`record: false`): the PTY never echoes them, so
/// recording them would leave stale bytes that could later swallow a real TUI redraw.
public struct TerminalInputHost: UIViewRepresentable {
    private let model: InputBarModel
    private let client: RworkClient?

    public init(model: InputBarModel, client: RworkClient?) {
        self.model = model
        self.client = client
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model, client: client)
    }

    public func makeUIView(context: Context) -> TerminalInputResponderView {
        let view = TerminalInputResponderView()
        context.coordinator.attach(to: view)
        // Become first responder so the software/hardware keyboard targets this surface.
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    public func updateUIView(_ uiView: TerminalInputResponderView, context: Context) {
        // The client can change across reconnects; keep the coordinator's send target current.
        context.coordinator.client = client
    }

    public static func dismantleUIView(_ uiView: TerminalInputResponderView, coordinator: Coordinator) {
        uiView.teardown()
    }

    /// Owns the per-instance send glue: turns the components' byte/text callbacks into
    /// `InputBarModel` sends on the main actor, recording for B1 dedup.
    @MainActor
    public final class Coordinator {
        let model: InputBarModel
        var client: RworkClient?

        init(model: InputBarModel, client: RworkClient?) {
            self.model = model
            self.client = client
        }

        func attach(to view: TerminalInputResponderView) {
            view.onKeyBytes = { [weak self] bytes in self?.sendRaw(bytes) }
            view.onText = { [weak self] text in self?.sendText(text) }
        }

        private func sendRaw(_ bytes: [UInt8]) {
            guard let client else { return }
            let model = model
            Task { await model.sendRaw(bytes, over: client) }
        }

        private func sendText(_ text: String) {
            guard let client else { return }
            let model = model
            Task { await model.sendText(text, over: client) }
        }
    }
}

/// The custom `UIResponder` (a `UIView`) that physically hosts the four components and owns the
/// hardware-key / keyboard-frame plumbing. The SwiftUI ``TerminalInputHost`` is the thin
/// representable around it.
public final class TerminalInputResponderView: UIView {
    /// Forwarded raw bytes for the key path (hardware keys, accessory taps, floating-cursor arrows).
    var onKeyBytes: (([UInt8]) -> Void)?
    /// Forwarded committed text (IME / printable), already post-composition.
    var onText: ((String) -> Void)?

    private let proxy = IMEProxyTextView()
    private let accessoryDecision = KeyboardAccessoryDecision()
    private let floatingCursor = FloatingCursorController()
    private lazy var accessoryBar = KeyboardAccessoryBar()

    /// Manual key-repeat for the hardware path: each fire re-encodes the held press to bytes.
    /// Keyed by the classified press so last-key-wins / release work per the component contract.
    private lazy var repeater = KeyRepeater<InputRouting.KeyPress>(
        scheduler: DispatchRepeatScheduler()
    ) { [weak self] press in
        guard let bytes = TerminalInputResponderView.encode(press) else { return }
        // The scheduler fires on a background queue; hop to main for the SwiftUI/UIKit send.
        // `[weak self]` on the inner hop too: a fire already in flight when the view is torn
        // down must NOT deliver a stale byte through a half-dismantled view.
        DispatchQueue.main.async { [weak self] in self?.onKeyBytes?(bytes) }
    }

    /// Whether the accessory bar should currently be attached (software keyboard on screen).
    private var accessoryVisible = false

    init() {
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configure() {
        backgroundColor = .clear
        // The IME proxy is the text first responder; embed it so iOS routes composed text to it.
        // It is also the only view that receives `UIPress` events, so the key-encoding presses
        // it intercepts are fed into the repeater here (special keys + Ctrl/Alt combos).
        addSubview(proxy)
        proxy.onText = { [weak self] text in self?.onText?(text) }
        proxy.onKeyPress = { [weak self] press in self?.repeater.keyDown(press) }
        proxy.onKeyRelease = { [weak self] press in self?.repeater.keyUp(press) }
        proxy.onFloatingCursorBegin = { [weak self] point in self?.floatingCursor.begin(at: point) }
        proxy.onFloatingCursorUpdate = { [weak self] point in self?.floatingCursor.update(at: point) }
        proxy.onFloatingCursorEnd = { [weak self] in self?.floatingCursor.end() }

        // Floating-cursor arrow runs go straight to the key path.
        floatingCursor.onArrows = { [weak self] bytes in self?.onKeyBytes?(bytes) }

        // Accessory bar: Esc/Tab/arrows (and Ctrl-folded letters) forward to the key path.
        accessoryBar.onKey = { [weak self] bytes in self?.onKeyBytes?(bytes) }

        // Keyboard-frame notifications drive the accessory show/hide decision.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// Tears down notifications + repeater (called on SwiftUI dismantle). The repeater's `stop()`
    /// is thread-safe (its own lock), and `removeObserver` is safe from any thread, so `deinit`
    /// performs the same cleanup directly without hopping the main actor.
    func teardown() {
        repeater.stop()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        // `repeater`'s own `deinit` cancels its in-flight timer; here we only drop the
        // notification observers (safe from any thread, no main-actor hop).
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: First responder + IME embedding

    public override var canBecomeFirstResponder: Bool { true }

    /// We are a transparent lifecycle host; the embedded IME proxy is the **sole** first responder
    /// (it owns both text composition and the `pressesBegan` key interception). Becoming first
    /// responder here forwards straight to the proxy so there is never an ambiguous responder
    /// order between text input and key handling.
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        proxy.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        repeater.stop()
        return proxy.resignFirstResponder()
    }

    // MARK: inputAccessoryView (the accessory bar, gated by the decision)

    public override var inputAccessoryView: UIView? {
        accessoryVisible ? accessoryBar : nil
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        setAccessory(visible: accessoryDecision.shouldShowAccessoryBar(keyboardHeight: Double(frame.height)))
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        setAccessory(visible: false)
    }

    private func setAccessory(visible: Bool) {
        guard visible != accessoryVisible else { return }
        accessoryVisible = visible
        // Reloading input views re-queries `inputAccessoryView` so the bar attaches/detaches.
        proxy.reloadInputViews()
        reloadInputViews()
    }

    // MARK: Key encoding (the proxy classifies; this host encodes each repeater fire)

    /// Encodes a classified key-path press into the raw terminal bytes for `sendInput`. Returns
    /// `nil` for a press that carries nothing to send (e.g. a bare modifier).
    nonisolated static func encode(_ press: InputRouting.KeyPress) -> [UInt8]? {
        if press.isSpecial, let bytes = specialBytes(for: press) { return bytes }
        // Ctrl/Alt + letter: fold to a control code (Ctrl-C → 0x03) or ESC-prefix (Alt-b).
        let base = press.charactersIgnoringModifiers
        guard let scalar = base.unicodeScalars.first else { return nil }
        if press.control {
            return KeyboardAccessoryBar.controlCode(for: scalar)
        }
        if press.option {
            // Meta/Alt: ESC prefix + the base letter (the xterm metaSendsEscape convention).
            return [0x1B] + Array(base.utf8)
        }
        // A Command-combo is an app shortcut, not terminal input — nothing to send.
        return nil
    }

    /// Byte sequence for a special key. Arrows/Esc/Tab reuse the accessory bar's verified table;
    /// Return → CR, Delete → DEL.
    private nonisolated static func specialBytes(for press: InputRouting.KeyPress) -> [UInt8]? {
        // Disambiguate the special keys by their committed characters where unambiguous.
        switch press.characters {
        case "\u{1B}": return KeyboardAccessoryBar.Key.escape.bytes
        case "\t":     return KeyboardAccessoryBar.Key.tab.bytes
        case "\r", "\n": return [0x0D]               // CR (Enter)
        case "\u{7F}", "\u{08}": return [0x7F]        // DEL (Backspace)
        default: break
        }
        // Arrows have empty `characters`; fall back to the ignoring-modifiers cursor sequences.
        switch press.charactersIgnoringModifiers {
        case UIKeyCommand.inputUpArrow:    return KeyboardAccessoryBar.Key.up.bytes
        case UIKeyCommand.inputDownArrow:  return KeyboardAccessoryBar.Key.down.bytes
        case UIKeyCommand.inputLeftArrow:  return KeyboardAccessoryBar.Key.left.bytes
        case UIKeyCommand.inputRightArrow: return KeyboardAccessoryBar.Key.right.bytes
        default: return nil
        }
    }
}
#endif
