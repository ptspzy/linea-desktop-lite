import AppKit
import QuartzCore

@MainActor
final class CaptureHUD {
  private let size = NSSize(width: 118, height: 30)
  private let panel: NSPanel
  private let activityIndicator = NSProgressIndicator()
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
    indicator.frame = NSRect(x: 6, y: 12, width: 6, height: 6)
    indicator.cornerRadius = latched ? 1 : 3
    indicator.backgroundColor = NSColor.systemRed.cgColor
    root.addSublayer(indicator)
    panel.setAccessibilityLabel(latched ? "持续录音中，再按快捷键结束" : "录音中，松开快捷键结束")
    let heights: [CGFloat] = [8, 14, 21, 12, 26, 17, 23, 13, 19, 15, 9, 18, 11]
    let width: CGFloat = 3
    let gap: CGFloat = 3.5
    let startX = (size.width - CGFloat(heights.count) * width - CGFloat(heights.count - 1) * gap) / 2
    let foreground = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.84, alpha: 0.92).cgColor
    let accent = NSColor(srgbRed: 0.72, green: 0.70, blue: 0.64, alpha: 0.88).cgColor

    bars = heights.enumerated().map { index, baseHeight in
      let layer = CALayer()
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
    show(makeRoot())
    panel.setAccessibilityLabel(title)

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .white
    label.sizeToFit()
    let startX = (size.width - label.frame.width - 24) / 2
    label.frame.origin = NSPoint(x: startX + 24, y: (size.height - label.frame.height) / 2)

    activityIndicator.style = .spinning
    activityIndicator.controlSize = .small
    activityIndicator.isIndeterminate = true
    activityIndicator.isDisplayedWhenStopped = false
    activityIndicator.appearance = NSAppearance(named: .darkAqua)
    activityIndicator.frame = NSRect(x: startX, y: (size.height - 16) / 2, width: 16, height: 16)
    panel.contentView?.addSubview(activityIndicator)
    panel.contentView?.addSubview(label)
    activityIndicator.startAnimation(nil)
  }

  func showComplete() {
    let root = makeRoot()
    let fill = CALayer()
    fill.frame = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
    fill.cornerRadius = (size.height - 4) / 2
    fill.backgroundColor = NSColor(srgbRed: 0.54, green: 0.52, blue: 0.48, alpha: 0.38).cgColor
    root.addSublayer(fill)
    show(root)
    hide(after: 0.22)
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
    hide(after: 1.2)
  }

  func hide() {
    cancelPendingHide()
    activityIndicator.stopAnimation(nil)
    bars = []
    panel.orderOut(nil)
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
    activityIndicator.stopAnimation(nil)
    activityIndicator.removeFromSuperview()
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
