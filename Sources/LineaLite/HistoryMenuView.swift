import AppKit

@MainActor
final class HistoryMenuView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  var onDelete: ((HistoryEntry) -> Void)? { didSet { updateSelection() } }
  var onCorrect: ((HistoryEntry) -> Void)? { didSet { updateSelection() } }

  private let titleLabel = NSTextField(labelWithString: "历史记录")
  private let retainedLabel = NSTextField(labelWithString: "")
  private let todayLabel = NSTextField(labelWithString: "")
  private let weekLabel = NSTextField(labelWithString: "")
  private let activityView = HistoryActivityView()
  private let searchField = NSSearchField()
  private let copyButton = NSButton()
  private let correctButton = NSButton()
  private let deleteButton = NSButton()
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "暂无历史记录")
  private let previewScrollView = NSScrollView()
  private let preview = NSTextView()
  private let detailLabel = NSTextField(labelWithString: "未选择记录")
  private let separator = NSBox()
  private let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
  private let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
  private let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
  private var entries: [HistoryEntry] = []
  private var visibleEntries: [HistoryEntry] = []
  private var now = Date()
  private var copyPasteboard = NSPasteboard.general

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 392, height: 444) }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureHistoryList()
  }

  convenience init() { self.init(frame: .zero) }

  convenience init(pasteboard: NSPasteboard) {
    self.init(frame: .zero)
    copyPasteboard = pasteboard
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureHistoryList()
  }

  func update(entries: [HistoryEntry], now: Date = Date()) {
    self.entries = entries
    self.now = now
    activityView.update(entries: entries, now: now)
    let activity = historyActivity(entries: entries, endingAt: now, days: 7, calendar: .current)
    retainedLabel.stringValue = "已保留 \(entries.count) 条"
    todayLabel.stringValue = "今天 \(activity.last?.count ?? 0) 条 · \(activity.last?.characters ?? 0) 字"
    weekLabel.stringValue = "近 7 天 \(activity.reduce(0) { $0 + $1.count }) 条"
    for label in [todayLabel, weekLabel] {
      label.toolTip = "\(label.stringValue)（仅统计已保留记录）"
      label.setAccessibilityLabel(label.toolTip)
    }
    applyFilter()
  }

  override func layout() {
    super.layout()
    let width = max(0, bounds.width - 28)
    titleLabel.frame = NSRect(x: 14, y: 12, width: width * 0.4, height: 18)
    retainedLabel.frame = NSRect(x: titleLabel.frame.maxX, y: 12, width: width * 0.6, height: 18)
    todayLabel.frame = NSRect(x: 14, y: 36, width: width * 0.65, height: 16)
    weekLabel.frame = NSRect(x: todayLabel.frame.maxX, y: 36, width: width * 0.35, height: 16)
    activityView.frame = NSRect(x: 14, y: 62, width: width, height: 66)
    searchField.frame = NSRect(x: 14, y: 140, width: width, height: 24)
    scrollView.frame = NSRect(x: 14, y: 174, width: width, height: max(40, bounds.height - 264))
    scrollView.tile()
    textColumn.width = max(40, scrollView.contentSize.width - timeColumn.width - appColumn.width - 18)
    emptyLabel.frame = NSRect(x: 26, y: scrollView.frame.midY - 9, width: max(0, width - 24), height: 18)
    separator.frame = NSRect(x: 14, y: scrollView.frame.maxY + 5, width: width, height: 1)
    previewScrollView.frame = NSRect(x: 14, y: scrollView.frame.maxY + 14, width: width, height: 32)
    preview.frame.size.width = previewScrollView.contentSize.width
    preview.textContainer?.containerSize = NSSize(width: previewScrollView.contentSize.width, height: .greatestFiniteMagnitude)
    for (index, button) in [copyButton, correctButton, deleteButton].enumerated() {
      button.frame = NSRect(x: bounds.width - 104 + CGFloat(index) * 32, y: bounds.height - 40, width: 26, height: 26)
    }
    detailLabel.frame = NSRect(x: 14, y: bounds.height - 35, width: max(0, width - 100), height: 18)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let tableColumn, visibleEntries.indices.contains(row) else { return nil }
    let entry = visibleEntries[row]
    let label = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField
      ?? NSTextField(labelWithString: "")
    label.identifier = tableColumn.identifier
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.font = .systemFont(ofSize: 12)
    label.textColor = .labelColor
    switch tableColumn.identifier {
    case timeColumn.identifier:
      label.stringValue = formattedDate(entry.createdAt, compact: true)
      label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      label.textColor = .secondaryLabelColor
      label.toolTip = formattedDate(entry.createdAt)
    case appColumn.identifier:
      label.stringValue = entry.appName ?? ""
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
      label.toolTip = entry.appName
    default:
      label.stringValue = entry.text.components(separatedBy: .newlines).joined(separator: " ")
      label.toolTip = entry.text
    }
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

  func controlTextDidChange(_ obj: Notification) {
    guard obj.object as? NSSearchField === searchField else { return }
    applyFilter()
  }

  private func configureHistoryList() {
    for label in [titleLabel, retainedLabel, todayLabel, weekLabel, detailLabel, emptyLabel] {
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.maximumNumberOfLines = 1
      addSubview(label)
    }
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    retainedLabel.alignment = .right
    weekLabel.alignment = .right
    retainedLabel.toolTip = "本机当前保留的历史记录，不代表全部使用量"
    searchField.placeholderString = "搜索内容或应用"
    searchField.setAccessibilityLabel("搜索历史记录")
    searchField.delegate = self
    addSubview(searchField)
    addSubview(activityView)

    for (button, symbol, title, action) in [
      (copyButton, "doc.on.doc", "复制记录", #selector(copySelected(_:))),
      (correctButton, "pencil", "纠正记录", #selector(correctSelected(_:))),
      (deleteButton, "trash", "删除记录", #selector(deleteSelected(_:))),
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      button.imagePosition = .imageOnly
      button.bezelStyle = .inline
      button.isBordered = false
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.target = self
      button.action = action
      button.isEnabled = false
      addSubview(button)
    }

    timeColumn.title = "时间"
    timeColumn.width = 48
    timeColumn.resizingMask = []
    textColumn.title = "转写内容"
    textColumn.minWidth = 40
    textColumn.resizingMask = .autoresizingMask
    appColumn.title = "应用"
    appColumn.width = 66
    appColumn.resizingMask = []
    for column in [timeColumn, textColumn, appColumn] { tableView.addTableColumn(column) }
    tableView.rowHeight = 26
    tableView.intercellSpacing = NSSize(width: 6, height: 0)
    tableView.backgroundColor = .clear
    tableView.selectionHighlightStyle = .regular
    tableView.allowsMultipleSelection = false
    tableView.allowsColumnReordering = false
    tableView.allowsColumnResizing = false
    tableView.setAccessibilityLabel("历史记录列表")
    tableView.delegate = self
    tableView.dataSource = self
    tableView.target = self
    tableView.doubleAction = #selector(copySelected(_:))
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    addSubview(scrollView, positioned: .below, relativeTo: emptyLabel)
    emptyLabel.alignment = .center

    separator.boxType = .separator
    addSubview(separator)
    preview.isEditable = false
    preview.isSelectable = true
    preview.isRichText = false
    preview.drawsBackground = false
    preview.font = .systemFont(ofSize: 12)
    preview.textColor = .labelColor
    preview.textContainerInset = .zero
    preview.textContainer?.lineFragmentPadding = 0
    preview.textContainer?.widthTracksTextView = true
    preview.isVerticallyResizable = true
    preview.isHorizontallyResizable = false
    preview.autoresizingMask = [.width]
    preview.setAccessibilityLabel("选中记录全文")
    previewScrollView.documentView = preview
    previewScrollView.hasVerticalScroller = true
    previewScrollView.autohidesScrollers = true
    previewScrollView.drawsBackground = false
    addSubview(previewScrollView)
    update(entries: [])
  }

  private func applyFilter() {
    let selectedID = selectedEntry?.id
    visibleEntries = filteredHistoryEntries(entries, query: searchField.stringValue)
    tableView.reloadData()
    if let row = visibleEntries.firstIndex(where: { $0.id == selectedID }) ?? (visibleEntries.isEmpty ? nil : 0) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
    emptyLabel.stringValue = entries.isEmpty ? "暂无历史记录" : "没有匹配的记录"
    emptyLabel.isHidden = !visibleEntries.isEmpty
    updateSelection()
  }

  private func updateSelection() {
    let entry = selectedEntry
    copyButton.isEnabled = entry != nil
    correctButton.isEnabled = entry != nil && onCorrect != nil
    deleteButton.isEnabled = entry != nil && onDelete != nil
    preview.string = entry?.text ?? ""
    preview.scrollToBeginningOfDocument(nil)
    detailLabel.stringValue = entry.map {
      [formattedDate($0.createdAt), $0.appName].compactMap { $0 }.joined(separator: " · ")
    } ?? "未选择记录"
    detailLabel.toolTip = detailLabel.stringValue
  }

  @objc private func copySelected(_ sender: Any?) {
    guard let entry = selectedEntry else { return }
    let pasteboard = copyPasteboard
    pasteboard.clearContents()
    detailLabel.stringValue = pasteboard.setString(entry.text, forType: .string) ? "已复制" : "复制失败"
    detailLabel.toolTip = detailLabel.stringValue
    NSAccessibility.post(element: detailLabel, notification: .valueChanged)
  }

  @objc private func deleteSelected(_ sender: Any?) {
    guard let entry = selectedEntry else { return }
    onDelete?(entry)
  }

  @objc private func correctSelected(_ sender: Any?) {
    guard let entry = selectedEntry else { return }
    onCorrect?(entry)
  }

  private var selectedEntry: HistoryEntry? {
    guard visibleEntries.indices.contains(tableView.selectedRow) else { return nil }
    return visibleEntries[tableView.selectedRow]
  }

  private func formattedDate(_ date: Date, compact: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = compact
      ? (Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d")
      : "yyyy/M/d HH:mm"
    return formatter.string(from: date)
  }
}

@MainActor
final class HistoryActivityView: NSView {
  private let periodLabel = NSTextField(labelWithString: "近 16 周 · 字数")
  private let scopeLabel = NSTextField(labelWithString: "仅统计已保留记录")
  private let lowLabel = NSTextField(labelWithString: "少")
  private let highLabel = NSTextField(labelWithString: "多")
  private var activity: [HistoryActivityDay] = []
  private var cells: [(day: HistoryActivityDay, rect: NSRect)] = []
  private var today = Date()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    for label in [periodLabel, scopeLabel, lowLabel, highLabel] {
      label.font = .systemFont(ofSize: 10)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      addSubview(label)
    }
    setAccessibilityLabel("近 16 周听写活动，仅统计已保留记录")
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  required init?(coder: NSCoder) { nil }

  func update(entries: [HistoryEntry], now: Date) {
    let calendar = Calendar.current
    today = calendar.startOfDay(for: now)
    let offset = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
    let end = calendar.date(byAdding: .day, value: 6 - offset, to: today)!
    activity = historyActivity(entries: entries, endingAt: end, days: 112, calendar: calendar)
    needsLayout = true
    needsDisplay = true
    setAccessibilityValue("\(activity.filter { $0.date <= today }.reduce(0) { $0 + $1.count }) 条已保留记录")
  }

  override func layout() {
    super.layout()
    let legendX: CGFloat = 160
    periodLabel.frame = NSRect(x: legendX, y: 0, width: max(0, bounds.width - legendX), height: 14)
    scopeLabel.frame = NSRect(x: legendX, y: 18, width: max(0, bounds.width - legendX), height: 14)
    lowLabel.frame = NSRect(x: legendX, y: 43, width: 16, height: 14)
    highLabel.frame = NSRect(x: legendX + 82, y: 43, width: 16, height: 14)
    removeAllToolTips()
    cells = activity.enumerated().compactMap { index, day in
      guard day.date <= today else { return nil }
      let rect = NSRect(x: 1 + CGFloat(index / 7) * 9, y: 3 + CGFloat(index % 7) * 9, width: 6, height: 6)
      addToolTip(rect.insetBy(dx: -1, dy: -1), owner: self, userData: nil)
      return (day, rect)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let maximum = cells.map { $0.day.characters }.max() ?? 0
    for cell in cells {
      color(level: historyActivityLevel(characters: cell.day.characters, maximum: maximum)).setFill()
      NSBezierPath(roundedRect: cell.rect, xRadius: 1, yRadius: 1).fill()
      if cell.day.date == today {
        NSColor.secondaryLabelColor.setStroke()
        let outline = NSBezierPath(roundedRect: cell.rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
        outline.lineWidth = 0.75
        outline.stroke()
      }
    }
    for level in 0...4 {
      color(level: level).setFill()
      NSBezierPath(roundedRect: NSRect(x: 179 + CGFloat(level) * 12, y: 46, width: 7, height: 7), xRadius: 1, yRadius: 1).fill()
    }
  }

  func dayToolTip(at point: NSPoint) -> String? {
    guard let cell = cells.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/M/d"
    return "\(formatter.string(from: cell.day.date)) · \(cell.day.count) 条 · \(cell.day.characters) 字（已保留）"
  }

  @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
    dayToolTip(at: point) ?? ""
  }

  private func color(level: Int) -> NSColor {
    NSColor.labelColor.withAlphaComponent(level == 0 ? 0.08 : 0.18 + CGFloat(level) * 0.16)
  }
}
