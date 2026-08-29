import AppKit

final class HistoryMenuView: NSView {
  private let recentLimit = 4
  private var entries: [HistoryEntry] = []
  private var now = Date()

  override var intrinsicContentSize: NSSize {
    NSSize(width: 328, height: 278)
  }

  func update(entries: [HistoryEntry], now: Date = Date()) {
    self.entries = entries
    self.now = now
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let weekday = calendar.component(.weekday, from: today) - 1
    let currentWeek = calendar.date(byAdding: .day, value: -weekday, to: today)!
    let start = calendar.date(byAdding: .day, value: -15 * 7, to: currentWeek)!
    let end = calendar.date(byAdding: .day, value: 111, to: start)!
    let activity = historyActivity(entries: entries, endingAt: end, days: 112, calendar: calendar)
    let visibleActivity = activity.filter { $0.date <= today }
    let maximum = visibleActivity.map(\.characters).max() ?? 0

    drawText(
      "Activity",
      in: NSRect(x: 16, y: 249, width: 100, height: 18),
      font: .systemFont(ofSize: 13, weight: .semibold),
      color: .labelColor
    )
    drawText(
      "\(entries.count) clips · \(entries.reduce(0) { $0 + $1.text.count }) chars",
      in: NSRect(x: 136, y: 249, width: 176, height: 18),
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor,
      alignment: .right
    )

    let cell: CGFloat = 9
    let gap: CGFloat = 3
    let gridTop: CGFloat = 238
    for (index, day) in activity.enumerated() where day.date <= today {
      let column = index / 7
      let row = index % 7
      let rect = NSRect(
        x: 16 + CGFloat(column) * (cell + gap),
        y: gridTop - cell - CGFloat(row) * (cell + gap),
        width: cell,
        height: cell
      )
      let level = historyActivityLevel(characters: day.characters, maximum: maximum)
      activityColor(level: level).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

      if calendar.isDate(day.date, inSameDayAs: today) {
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        outline.stroke()
      }
    }

    let lastWeek = visibleActivity.suffix(7)
    drawText(
      "Last 7 days",
      in: NSRect(x: 220, y: 211, width: 92, height: 16),
      font: .systemFont(ofSize: 11, weight: .medium),
      color: .secondaryLabelColor
    )
    drawText(
      "\(lastWeek.reduce(0) { $0 + $1.count }) clips",
      in: NSRect(x: 220, y: 187, width: 92, height: 22),
      font: .systemFont(ofSize: 16, weight: .semibold),
      color: .labelColor
    )
    drawText(
      "\(lastWeek.reduce(0) { $0 + $1.characters }) chars",
      in: NSRect(x: 220, y: 168, width: 92, height: 16),
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor
    )

    NSColor.separatorColor.setFill()
    NSRect(x: 16, y: 145, width: 296, height: 1).fill()
    drawText(
      "Recent",
      in: NSRect(x: 16, y: 119, width: 100, height: 18),
      font: .systemFont(ofSize: 13, weight: .semibold),
      color: .labelColor
    )

    let recent = Array(entries.prefix(recentLimit))
    if recent.isEmpty {
      drawText(
        "No dictations yet",
        in: NSRect(x: 16, y: 66, width: 296, height: 20),
        font: .systemFont(ofSize: 12),
        color: .tertiaryLabelColor,
        alignment: .center
      )
      return
    }

    for (index, entry) in recent.enumerated() {
      let y = 92 - CGFloat(index) * 25
      drawText(
        timeLabel(for: entry.createdAt, calendar: calendar),
        in: NSRect(x: 16, y: y, width: 42, height: 17),
        font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        color: .secondaryLabelColor
      )
      drawText(
        entry.text,
        in: NSRect(x: 64, y: y, width: 166, height: 17),
        font: .systemFont(ofSize: 11),
        color: .labelColor
      )
      drawText(
        entry.appName ?? "",
        in: NSRect(x: 236, y: y, width: 76, height: 17),
        font: .systemFont(ofSize: 10),
        color: .tertiaryLabelColor,
        alignment: .right
      )
    }
  }

  private func activityColor(level: Int) -> NSColor {
    guard level > 0 else { return .quaternaryLabelColor.withAlphaComponent(0.35) }
    return .controlAccentColor.withAlphaComponent(0.25 + CGFloat(level) * 0.18)
  }

  private func timeLabel(for date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d"
    return formatter.string(from: date)
  }

  private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
      in: rect,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }
}
