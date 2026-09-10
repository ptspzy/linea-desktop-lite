#if HUD_REGRESSION_STANDALONE
import AppKit

@main
enum HUDRegression {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared
    let hud = CaptureHUD()
    defer { hud.hide() }
    hud.showProcessing()
    let panel = NSApplication.shared.windows.first { $0 is NSPanel && $0.isVisible }!
    let frame = panel.frame
    for title in ["识别中", "准备中", "导入模型"] {
      if title == "准备中" { hud.showStarting() } else { hud.showProcessing(title) }
      let view = panel.contentView!
      let clip = view.layer!.sublayers!.first!
      let fill = clip.sublayers!.first!
      let advance = fill.animation(forKey: "processing-advance") as! CABasicAnimation
      let sweep = fill.sublayers!.first!.animation(forKey: "processing-sweep") as! CABasicAnimation
      precondition(view.subviews.isEmpty && panel.frame == frame, "No spinner/text or layout shift")
      precondition(fill.anchorPoint.x == 0 && fill.position.x == 0)
      precondition(advance.keyPath == "bounds.size.width" && !advance.autoreverses && advance.repeatCount == 0)
      precondition((advance.fromValue as! CGFloat) < (advance.toValue as! CGFloat))
      precondition(fill.bounds.width < clip.bounds.width && clip.bounds.contains(fill.frame))
      precondition(sweep.keyPath == "position.x" && !sweep.autoreverses)
      precondition((sweep.fromValue as! CGFloat) < (sweep.toValue as! CGFloat))
      precondition(panel.accessibilityLabel() == (title == "准备中" ? "麦克风启动中" : title))
      if title == "识别中" {
        var previous: CGFloat = 0
        // Sample across the old reversal and beyond the new waiting cap.
        for delay in [0.1, 0.5, 2.1, 2.5, 3.2] {
          RunLoop.current.run(until: Date().addingTimeInterval(delay))
          let width = fill.presentation()?.bounds.width ?? fill.bounds.width
          precondition(width + 0.01 >= previous && width < clip.bounds.width, "Waiting fill must never retreat or finish early")
          previous = width
        }
        try snapshot(view, named: "processing")
      }
      for latched in [false, true] {
        hud.showRecording(latched: latched)
        let layers = panel.contentView!.layer!.sublayers!
        let indicator = layers.first { $0.name == "recording-indicator" }!
        let mark = indicator.sublayers!.first!
        precondition(indicator.bounds.contains(mark.frame) && mark.bounds.size == NSSize(width: 4, height: 4))
        precondition(mark.cornerRadius == (latched ? 0.8 : 2))
        for level in [0.0, 0.5, 1.0] {
          hud.setLevel(level)
          for wave in layers where wave.name == "recording-wave" {
            precondition(wave.frame.minX >= indicator.frame.maxX + 7)
            precondition(panel.contentView!.bounds.contains(wave.frame))
          }
        }
        if title == "识别中" { try snapshot(panel.contentView!, named: latched ? "recording-tap" : "recording-hold") }
      }
    }
    for (show, label) in [(hud.showComplete, "已完成"), (hud.showCopied, "已复制，未自动写入，请手动粘贴"),
                           (hud.showError, "处理失败")] {
      hud.showProcessing()
      show()
      precondition(panel.accessibilityLabel() == label)
      if label == "已完成" {
        let fill = panel.contentView!.layer!.sublayers!.first!
        let finish = fill.animation(forKey: "processing-complete") as! CABasicAnimation
        precondition(fill.bounds.width == frame.width - 4 && !finish.autoreverses)
        precondition((finish.fromValue as! CGFloat) < (finish.toValue as! CGFloat))
      } else if label.hasPrefix("已复制") {
        let view = panel.contentView!
        let message = view.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(view.bounds.contains(message.frame))
        precondition(message.intrinsicContentSize.width <= message.bounds.width)
        precondition(message.stringValue.contains("⌘V"))
        try snapshot(view, named: "copied-only")
      }
      hud.showProcessing()
      RunLoop.current.run(until: Date().addingTimeInterval(1.3))
      precondition(panel.isVisible, "An older terminal-state timer must not hide new processing")
    }
    hud.hide()
    precondition(!panel.isVisible && panel.contentView == nil, "Hidden HUD must release all animation layers")
    print("PASS: one-way waiting fill, no premature completion, compact recording marks and state cleanup")
  }

  @MainActor
  private static func snapshot(_ view: NSView, named name: String) throws {
    guard CommandLine.arguments.count > 1 else { return }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
    )
  }
}
#endif
