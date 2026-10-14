import AppKit
import PhoneUseCore
import QuartzCore
import SwiftUI

/// Receives input from a live screen, in image pixels.
@MainActor
protocol LiveScreenInput: AnyObject {
    func perform(_ action: PhoneAction)
    func type(_ text: String)
    func key(_ key: Key, modifiers: [Modifier])
}

extension PhoneSession: LiveScreenInput {}

/// Draws the newest frame aspect-fit and turns clicks, drags, and typing into input.
final class LiveScreenNSView: NSView {
    weak var input: (any LiveScreenInput)?
    /// Thumbnails pass clicks through to the SwiftUI view around them.
    var interactive = true
    private let frameLayer = CALayer()
    private let touchLayer = CAShapeLayer()
    private var imageSize: PixelSize?
    private var press: (start: PixelPoint, startView: CGPoint, time: ContinuousClock.Instant)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .trilinear
        layer?.addSublayer(frameLayer)
        touchLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
        touchLayer.strokeColor = NSColor.systemBlue.cgColor
        touchLayer.lineWidth = 3
        touchLayer.lineCap = .round
        layer?.addSublayer(touchLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = image
        CATransaction.commit()
        imageSize = image.map { PixelSize(width: $0.width, height: $0.height) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        touchLayer.frame = bounds
        CATransaction.commit()
    }

    private var mapping: AspectFitMapping? {
        guard let imageSize, bounds.width > 0, bounds.height > 0 else { return nil }
        return AspectFitMapping(image: imageSize, viewWidth: bounds.width, viewHeight: bounds.height)
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let pixel = mapping?.pixel(x: point.x, y: point.y) else { press = nil; return }
        press = (pixel, point, .now)
        drawTouch(from: point, to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        drawTouch(from: press.startView, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil; fadeTouch() }
        guard let press, let mapping else { return }
        let point = convert(event.locationInWindow, from: nil)
        let elapsed = ContinuousClock.now - press.time
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        input?.perform(PointerGesture.action(from: press.start, to: mapping.clampedPixel(x: point.x, y: point.y), milliseconds: milliseconds))
    }

    private func drawTouch(from start: CGPoint, to end: CGPoint) {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: start.x - 14, y: start.y - 14, width: 28, height: 28))
        if hypot(end.x - start.x, end.y - start.y) > 2 {
            path.move(to: start)
            path.addLine(to: end)
            path.addEllipse(in: CGRect(x: end.x - 10, y: end.y - 10, width: 20, height: 20))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        touchLayer.opacity = 1
        touchLayer.path = path
        CATransaction.commit()
    }

    private func fadeTouch() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        touchLayer.opacity = 0
        CATransaction.commit()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let input else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [Modifier] = []
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.command) { modifiers.append(.command) }
        if let special = Self.specialKeys[event.keyCode] {
            input.key(special, modifiers: modifiers + (flags.contains(.shift) ? [.shift] : []))
            return
        }
        if !modifiers.isEmpty {
            guard let letter = event.charactersIgnoringModifiers?.lowercased(), let key = Key(name: letter) else { NSSound.beep(); return }
            input.key(key, modifiers: modifiers + (flags.contains(.shift) ? [.shift] : []))
            return
        }
        let text = String((event.characters ?? "").unicodeScalars.filter { (0x20...0x7e).contains($0.value) }.map(Character.init))
        if text.isEmpty { NSSound.beep() } else { input.type(text) }
    }

    private static let specialKeys: [UInt16: Key] = [
        36: .enter, 76: .enter, 53: .escape, 51: .backspace, 48: .tab,
        123: .left, 124: .right, 125: .down, 126: .up,
    ]
}

struct LiveScreen: NSViewRepresentable {
    let session: PhoneSession
    var interactive = true
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> LiveScreenNSView {
        let view = LiveScreenNSView()
        view.input = session
        return view
    }

    func updateNSView(_ view: LiveScreenNSView, context: Context) {
        view.input = session
        view.interactive = interactive
        view.cornerRadius = cornerRadius
        view.show(session.image)
    }
}
