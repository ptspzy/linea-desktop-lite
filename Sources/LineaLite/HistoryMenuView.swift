import AppKit

@MainActor
final class HistoryMenuView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let searchField = NSSearchField()
  private let copyButton = NSButton()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "No dictations yet")
  private let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
  private let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
  private let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
  private var entries: [HistoryEntry] = []
  private var visibleEntries: [HistoryEntry] = []
  private var now = Date()

  override var intrinsicContentSize: NSSize {
    NSSize(width: 352, height: 386)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureHistoryList()
  }

  convenience init() {
    self.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureHistoryList()
  }

  func update(entries: [HistoryEntry], now: Date = Date()) {
    self.entries = entries
    self.now = now
    applyFilter()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let searchY = bounds.height - 173
    copyButton.frame = NSRect(x: bounds.width - 46, y: searchY, width: 30, height: 24)
    searchField.frame = NSRect(x: 16, y: searchY, width: copyButton.frame.minX - 24, height: 24)
    scrollView.frame = NSRect(x: 16, y: 16, width: bounds.width - 32, height: searchY - 26)
    emptyLabel.frame = scrollView.frame.insetBy(dx: 12, dy: 12)
    textColumn.width = max(120, scrollView.contentSize.width - timeColumn.width - appColumn.width - 20)
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
    let top = bounds.height

    drawText(
      "Activity",
      in: NSRect(x: 16, y: top - 29, width: 100, height: 18),
      font: .systemFont(ofSize: 13, weight: .semibold),
      color: .labelColor
    )
    drawText(
      "\(entries.count) clips · \(entries.reduce(0) { $0 + $1.text.count }) chars",
      in: NSRect(x: 136, y: top - 29, width: bounds.width - 152, height: 18),
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor,
      alignment: .right
    )

    let cell: CGFloat = 9
    let gap: CGFloat = 3
    let gridTop = top - 40
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
      in: NSRect(x: bounds.width - 108, y: top - 67, width: 92, height: 16),
      font: .systemFont(ofSize: 11, weight: .medium),
      color: .secondaryLabelColor
    )
    drawText(
      "\(lastWeek.reduce(0) { $0 + $1.count }) clips",
      in: NSRect(x: bounds.width - 108, y: top - 91, width: 92, height: 22),
      font: .systemFont(ofSize: 16, weight: .semibold),
      color: .labelColor
    )
    drawText(
      "\(lastWeek.reduce(0) { $0 + $1.characters }) chars",
      in: NSRect(x: bounds.width - 108, y: top - 110, width: 92, height: 16),
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor
    )

    NSColor.separatorColor.setFill()
    NSRect(x: 16, y: top - 133, width: bounds.width - 32, height: 1).fill()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    visibleEntries.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let tableColumn, visibleEntries.indices.contains(row) else { return nil }
    let entry = visibleEntries[row]
    let label = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
      ?? makeLabel(identifier: tableColumn.identifier)

    switch tableColumn.identifier {
    case timeColumn.identifier:
      label.stringValue = timeLabel(for: entry.createdAt, calendar: .current)
      label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
      label.textColor = .secondaryLabelColor
      label.alignment = .left
      label.toolTip = nil
    case appColumn.identifier:
      label.stringValue = entry.appName ?? ""
      label.font = .systemFont(ofSize: 10)
      label.textColor = .tertiaryLabelColor
      label.alignment = .right
      label.toolTip = entry.appName
    default:
      label.stringValue = entry.text
      label.font = .systemFont(ofSize: 11)
      label.textColor = .labelColor
      label.alignment = .left
      label.toolTip = entry.text
    }
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    copyButton.isEnabled = selectedEntry != nil
  }

  func controlTextDidChange(_ obj: Notification) {
    guard obj.object as? NSSearchField === searchField else { return }
    applyFilter()
  }

  private func configureHistoryList() {
    searchField.placeholderString = "Search history"
    searchField.delegate = self
    addSubview(searchField)

    copyButton.image = NSImage(
      systemSymbolName: "doc.on.doc",
      accessibilityDescription: "Copy selected transcript"
    )
    copyButton.imagePosition = .imageOnly
    copyButton.bezelStyle = .inline
    copyButton.isBordered = false
    copyButton.toolTip = "Copy selected transcript"
    copyButton.target = self
    copyButton.action = #selector(copySelected(_:))
    copyButton.isEnabled = false
    addSubview(copyButton)

    timeColumn.width = 44
    timeColumn.resizingMask = []
    textColumn.minWidth = 120
    textColumn.resizingMask = .autoresizingMask
    appColumn.width = 72
    appColumn.resizingMask = []
    tableView.addTableColumn(timeColumn)
    tableView.addTableColumn(textColumn)
    tableView.addTableColumn(appColumn)
    tableView.headerView = nil
    tableView.rowHeight = 24
    tableView.intercellSpacing = NSSize(width: 6, height: 0)
    tableView.backgroundColor = .clear
    tableView.selectionHighlightStyle = .regular
    tableView.allowsMultipleSelection = false
    tableView.delegate = self
    tableView.dataSource = self
    tableView.target = self
    tableView.doubleAction = #selector(copySelected(_:))

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    addSubview(scrollView)

    emptyLabel.alignment = .center
    emptyLabel.textColor = .tertiaryLabelColor
    emptyLabel.font = .systemFont(ofSize: 12)
    addSubview(emptyLabel)
  }

  private func applyFilter() {
    let selectedID = selectedEntry?.id
    visibleEntries = filteredHistoryEntries(entries, query: searchField.stringValue)
    tableView.reloadData()
    if let selectedID, let row = visibleEntries.firstIndex(where: { $0.id == selectedID }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
    copyButton.isEnabled = selectedEntry != nil
    emptyLabel.stringValue = entries.isEmpty ? "No dictations yet" : "No matches"
    emptyLabel.isHidden = !visibleEntries.isEmpty
  }

  @objc private func copySelected(_ sender: Any?) {
    guard let entry = selectedEntry else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(entry.text, forType: .string)
  }

  private var selectedEntry: HistoryEntry? {
    guard visibleEntries.indices.contains(tableView.selectedRow) else { return nil }
    return visibleEntries[tableView.selectedRow]
  }

  private func makeLabel(identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.identifier = identifier
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
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
