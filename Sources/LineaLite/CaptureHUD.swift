import AppKit
import QuartzCore

@MainActor
final class CaptureHUD {
  private let size = NSSize(width: 118, height: 30)
  private let panel: NSPanel
  private var bars: [(layer: CALayer, height: CGFloat)] = []
  private var phase: CGFloat = 0
  private var hideWorkItem: DispatchWorkItem?

  init() {
    panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
      backing: .buffered,
      defer: false
    )
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.canHide = false
    panel.isMovable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.alphaValue = 0.98
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
  }

  func showStarting() {
    showProcessing("准备中")
    panel.setAccessibilityLabel("麦克风启动中")
  }

  func showRecording(latched: Bool = false) {
    cancelPendingHide()
    phase = 0
    let root = makeRoot()
    let indicator = CALayer()
    indicator.name = "recording-indicator"
    indicator.frame = NSRect(x: 9, y: 10, width: 10, height: 10)
    indicator.cornerRadius = 5
    indicator.borderWidth = 1
    indicator.borderColor = NSColor.systemRed.withAlphaComponent(0.45).cgColor
    let mark = CALayer()
    mark.frame = NSRect(x: 3, y: 3, width: 4, height: 4)
    mark.cornerRadius = latched ? 0.8 : 2
    mark.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
    indicator.addSublayer(mark)
    root.addSublayer(indicator)
    panel.setAccessibilityLabel(latched ? "持续录音中，再按快捷键结束" : "录音中，松开快捷键结束")
    let heights: [CGFloat] = [8, 14, 21, 12, 26, 17, 23, 13, 19, 15, 9, 18, 11]
    let width: CGFloat = 3
    let gap: CGFloat = 3.5
    let startX: CGFloat = 26
    let foreground = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.84, alpha: 0.92).cgColor
    let accent = NSColor(srgbRed: 0.72, green: 0.70, blue: 0.64, alpha: 0.88).cgColor

    bars = heights.enumerated().map { index, baseHeight in
      let layer = CALayer()
      layer.name = "recording-wave"
      layer.frame = NSRect(x: startX + CGFloat(index) * (width + gap), y: 13, width: width, height: 4)
      layer.backgroundColor = (4...6).contains(index) ? accent : foreground
      layer.cornerRadius = 1.5
      layer.opacity = 0.22
      root.addSublayer(layer)
      return (layer, baseHeight)
    }
    show(root)
  }

  func setLevel(_ level: Double) {
    let level = CGFloat(max(0, min(level, 1)))
    phase = level == 0 ? 0 : phase + 0.40 + level * 1.18

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      let wave = level == 0 ? 0 : 0.22 + (sin(phase + CGFloat(index) * 0.72) + 1) / 2 * 0.78
      let height = min(max(4 + bar.height * level * wave * 2.1, 4), size.height - 7)
      bar.layer.frame.origin.y = (size.height - height) / 2
      bar.layer.frame.size.height = height
      bar.layer.opacity = Float(0.22 + level * (0.42 + wave * 0.36))
      bar.layer.cornerRadius = min(1.5, height / 2)
    }
    CATransaction.commit()
  }

  func showProcessing(_ title: String = "识别中") {
    cancelPendingHide()
    bars = []
    let root = makeRoot()
    let clip = CALayer()
    clip.frame = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
    clip.cornerRadius = clip.bounds.height / 2
    clip.masksToBounds = true
    root.addSublayer(clip)

    let fill = CALayer()
    fill.name = "processing-fill"
    fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    fill.position = CGPoint(x: 0, y: clip.bounds.midY)
    fill.bounds = NSRect(x: 0, y: 0, width: clip.bounds.width * 0.9, height: clip.bounds.height)
    fill.cornerRadius = clip.cornerRadius
    fill.masksToBounds = true
    fill.backgroundColor = NSColor(srgbRed: 0.73, green: 0.72, blue: 0.68, alpha: 0.32).cgColor
    clip.addSublayer(fill)

    // A waiting affordance, not measured ASR progress: reserve the last 10% for completion.
    let advance = CABasicAnimation(keyPath: "bounds.size.width")
    advance.fromValue = 4
    advance.toValue = fill.bounds.width
    advance.duration = 8
    advance.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fill.add(advance, forKey: "processing-advance")

    let sheen = CAGradientLayer()
    sheen.name = "processing-sheen"
    sheen.frame = NSRect(x: -32, y: 0, width: 32, height: clip.bounds.height)
    sheen.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
    sheen.startPoint = CGPoint(x: 0, y: 0.5)
    sheen.endPoint = CGPoint(x: 1, y: 0.5)
    fill.addSublayer(sheen)
    let sweep = CABasicAnimation(keyPath: "position.x")
    sweep.fromValue = -16
    sweep.toValue = clip.bounds.width + 16
    sweep.duration = 1.8
    sweep.repeatCount = .infinity
    sheen.add(sweep, forKey: "processing-sweep")

    show(root)
    panel.setAccessibilityLabel(title)
  }

  func showComplete() {
    let previous = panel.contentView?.layer?.sublayers?.first?.sublayers?.first
    let previousWidth = previous?.name == "processing-fill"
      ? (previous?.presentation()?.bounds.width ?? previous?.bounds.width) : nil
    let root = makeRoot()
    let fill = CALayer()
    fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    fill.frame = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
    fill.cornerRadius = (size.height - 4) / 2
    fill.backgroundColor = NSColor(srgbRed: 0.73, green: 0.72, blue: 0.68, alpha: 0.32).cgColor
    if let previousWidth {
      let finish = CABasicAnimation(keyPath: "bounds.size.width")
      finish.fromValue = previousWidth
      finish.toValue = fill.bounds.width
      finish.duration = 0.16
      fill.add(finish, forKey: "processing-complete")
    }
    root.addSublayer(fill)
    show(root)
    panel.setAccessibilityLabel("已完成")
    hide(after: 0.22)
  }

  func showCopied() {
    show(makeRoot())
    let message = NSTextField(labelWithString: "已复制 · ⌘V 粘贴")
    message.font = .systemFont(ofSize: 11, weight: .medium)
    message.textColor = .systemYellow
    message.alignment = .center
    message.frame = NSRect(x: 6, y: 8, width: size.width - 12, height: 15)
    panel.contentView?.addSubview(message)
    panel.setAccessibilityLabel("已复制，未自动写入，请手动粘贴")
    hide(after: 3)
  }

  func showError() {
    let root = makeRoot(error: true)
    let heights: [CGFloat] = [6, 14, 6]
    let width: CGFloat = 3
    let gap: CGFloat = 8
    let startX = (size.width - CGFloat(heights.count) * width - CGFloat(heights.count - 1) * gap) / 2
    let color = NSColor(srgbRed: 0.92, green: 0.42, blue: 0.38, alpha: 0.84).cgColor
    for (index, height) in heights.enumerated() {
      let layer = CALayer()
      layer.frame = NSRect(
        x: startX + CGFloat(index) * (width + gap),
        y: (size.height - height) / 2,
        width: width,
        height: height
      )
      layer.backgroundColor = color
      layer.cornerRadius = 1.5
      root.addSublayer(layer)
    }
    show(root)
    panel.setAccessibilityLabel("处理失败")
    hide(after: 1.2)
  }

  func hide() {
    cancelPendingHide()
    bars = []
    panel.orderOut(nil)
    panel.contentView = nil
  }

  private func makeRoot(error: Bool = false) -> CALayer {
    let root = CALayer()
    root.frame = NSRect(origin: .zero, size: size)
    root.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    root.backgroundColor = error
      ? NSColor(srgbRed: 0.12, green: 0.095, blue: 0.092, alpha: 0.92).cgColor
      : NSColor(srgbRed: 0.118, green: 0.114, blue: 0.106, alpha: 0.92).cgColor
    root.cornerRadius = size.height / 2
    root.borderWidth = 1
    root.borderColor = error
      ? NSColor(srgbRed: 0.92, green: 0.42, blue: 0.38, alpha: 0.25).cgColor
      : NSColor(srgbRed: 0.78, green: 0.76, blue: 0.70, alpha: 0.22).cgColor
    return root
  }

  private func show(_ root: CALayer) {
    cancelPendingHide()
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer = root
    panel.contentView = view
    panel.setFrame(panelFrame(), display: true)
    panel.orderFrontRegardless()
  }

  private func panelFrame() -> NSRect {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let screen else { return NSRect(x: 420, y: 80, width: size.width, height: size.height) }
    return NSRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.minY + 104,
      width: size.width,
      height: size.height
    )
  }

  private func hide(after delay: TimeInterval) {
    cancelPendingHide()
    let workItem = DispatchWorkItem { [weak self] in self?.hide() }
    hideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func cancelPendingHide() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
  }
}
