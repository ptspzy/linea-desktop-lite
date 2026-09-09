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
      let indicator = view.subviews.compactMap { $0 as? NSProgressIndicator }.first!
      let label = view.subviews.compactMap { $0 as? NSTextField }.first!
      precondition(indicator.style == .spinning && indicator.isIndeterminate)
      precondition(!indicator.isDisplayedWhenStopped && label.stringValue == title)
      precondition(panel.frame == frame && view.subviews.count == 2)
      precondition(view.bounds.contains(indicator.frame) && view.bounds.contains(label.frame))
      precondition(!indicator.frame.intersects(label.frame))
      precondition(panel.accessibilityLabel() == (title == "准备中" ? "麦克风启动中" : title))
      // Stay past the old 2.4-second turning point: only a spinner, never a fill bar.
      RunLoop.current.run(until: Date().addingTimeInterval(title == "识别中" ? 3 : 0.1))
      precondition(indicator.style == .spinning && indicator.frame.size == NSSize(width: 16, height: 16))
      precondition(view.layer?.sublayers?.allSatisfy { $0.animation(forKey: "processing") == nil } != false)
      if title == "识别中", CommandLine.arguments.count > 1 {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
          to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("processing.png")
        )
      }
      hud.showRecording()
      precondition(indicator.superview == nil, "Recording must remove the busy indicator")
    }
    for show in [hud.showComplete, hud.showError] {
      hud.showProcessing()
      let indicator = panel.contentView!.subviews.compactMap { $0 as? NSProgressIndicator }.first!
      show()
      precondition(indicator.superview == nil, "Terminal states must remove the busy indicator")
      hud.showProcessing()
      RunLoop.current.run(until: Date().addingTimeInterval(1.3))
      precondition(panel.isVisible, "An older terminal-state timer must not hide new processing")
    }
    hud.hide()
    precondition(!panel.isVisible)
    print("PASS: native indeterminate HUD, stable layout, state transitions and hide cancellation")
  }
}
#endif
