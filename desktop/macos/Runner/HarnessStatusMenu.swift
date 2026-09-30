import Cocoa
import CoreText

/// Unread conversations in the system menu bar. Dart owns the
/// unread ledger and navigation; AppKit only presents a snapshot and its receipts.
final class HarnessStatusMenu: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Harness")
  private(set) var statusItem: NSStatusItem?
  private var entries: [[String: Any]] = []
  private var enabled = false
  private var workspaceAvailable = false
  private var tracking = false
  private var dirty = true
  private let showWindow: () -> Void
  private let emit: (String, Any?) -> Void

  init(installStatusItem: Bool = true, showWindow: @escaping () -> Void,
       emit: @escaping (String, Any?) -> Void) {
    self.showWindow = showWindow
    self.emit = emit
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    if installStatusItem {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      statusItem = item
      item.menu = menu
      item.button?.imagePosition = .imageOnly
      item.button?.setAccessibilityLabel("Harness notifications")
    }
    update([:])
  }

  deinit {
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }

  func update(_ state: [String: Any]) {
    let nextEnabled = state["enabled"] as? Bool == true
    let nextAvailable = state["statusMenuEntries"] != nil
    let nextEntries = (state["statusMenuEntries"] as? [[String: Any]] ?? [])
      .filter { $0["unread"] as? Bool == true }
    guard dirty || enabled != nextEnabled || workspaceAvailable != nextAvailable ||
          !NSArray(array: entries).isEqual(to: nextEntries) else { return }
    enabled = nextEnabled
    workspaceAvailable = nextAvailable
    entries = nextEntries
    let count = entries.count
    statusItem?.button?.image = Self.badgeImage(logo: NSImage(named: "HarnessStatusIcon"),
                                              count: workspaceAvailable ? count : nil)
    statusItem?.button?.toolTip = workspaceAvailable ? "Harness · \(count) unread" : "Harness"
    statusItem?.button?.setAccessibilityValue("\(count) unread")
    dirty = true
    // Never move a conversation out from under the pointer. Stale actions are
    // revalidated against `entries`, even while the displayed menu stays still.
    if !tracking { rebuild() }
    if !workspaceAvailable { menu.cancelTracking() }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if !tracking && dirty { rebuild() }
  }

  func menuWillOpen(_ menu: NSMenu) {
    if dirty { rebuild() }
    tracking = true
  }

  func menuDidClose(_ menu: NSMenu) {
    tracking = false
    // AppKit dispatches the selected item after closing. Rebuild on next open
    // or update so its receipt remains the snapshot the person selected.
  }

  private func rebuild() {
    dirty = false
    menu.removeAllItems()
    if entries.isEmpty {
      let empty = NSMenuItem(title: workspaceAvailable ? "No unread notifications" : "Open Harness to get started",
                            action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      // Dart supplies tab order and newest-first rows within each tab. IDs keep
      // identically named tabs separate; nil holds sessions outside open tabs.
      var groups: [String?] = []
      var grouped: [String?: [[String: Any]]] = [:]
      for entry in entries {
        let group = entry["tabId"] as? String
        if grouped[group] == nil { groups.append(group) }
        grouped[group, default: []].append(entry)
      }
      for (index, group) in groups.enumerated() {
        if index > 0 { menu.addItem(.separator()) }
        let rows = grouped[group]!
        let first = rows[0]
        let title = first["tabName"] as? String ?? "Other sessions"
        let heading = NSMenuItem(title: compact(title), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        heading.toolTip = title
        menu.addItem(heading)
        for entry in rows {
          let title = entry["title"] as? String ?? "Unavailable harness"
          let row = add(compact(title), "openStatusHarness", enabled: enabled && entry["unavailable"] as? String == nil)
          row.representedObject = entry
          row.indentationLevel = 1
          row.state = .on
          row.onStateImage = Self.unreadDot
          let status = entry["unavailable"] as? String ?? entry["label"] as? String
          row.toolTip = [title, entry["detail"] as? String, status].compactMap { $0 }.joined(separator: " · ")
          row.setAccessibilityLabel([title, status, "Unread"]
            .compactMap { $0 }.joined(separator: ", "))
        }
      }
    }
    menu.addItem(.separator())
    add("New Harness…", "newAgent", enabled: enabled)
    add("Open Harness…", "addAgent", enabled: enabled)
    let clear = add("Clear All Notifications", "clearStatusNotifications",
                    enabled: enabled && !entries.isEmpty)
    clear.representedObject = entries
    menu.addItem(.separator())
    add("Show Harness", "openWindow")
    add("Settings…", "settings", enabled: enabled)
    menu.addItem(.separator())
    add("Quit Harness", "quit")
  }

  @discardableResult private func add(_ title: String, _ action: String, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(selected(_:)), keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier(action)
    item.target = self
    item.isEnabled = enabled
    menu.addItem(item)
    return item
  }

  @objc private func selected(_ item: NSMenuItem) {
    guard item.isEnabled, let action = item.identifier?.rawValue else { return }
    switch action {
    case "openWindow": showWindow()
    case "quit": NSApp.terminate(nil)
    case "openStatusHarness":
      guard enabled, let receipt = item.representedObject as? [String: Any],
            entries.contains(where: { sameReceipt($0, receipt) && $0["unavailable"] as? String == nil }) else { return }
      // Dart opens the destination before revealing the window, so activating
      // the previously selected tab cannot acknowledge the wrong notification.
      emit(action, receipt)
    case "clearStatusNotifications":
      guard enabled, let receipts = item.representedObject as? [[String: Any]] else { return }
      emit(action, ["receipts": receipts])
    default:
      guard enabled else { return }
      showWindow()
      emit(action, nil)
    }
  }

  private func sameReceipt(_ current: [String: Any], _ displayed: [String: Any]) -> Bool {
    ["machineId", "agentId", "readToken", "questionId"].allSatisfy {
      current[$0] as? String == displayed[$0] as? String
    }
  }

  private func compact(_ text: String) -> String {
    let line = text.components(separatedBy: .newlines).joined(separator: " ")
    return line.count > 56 ? String(line.prefix(55)) + "…" : line
  }

  /// A single template mask lets AppKit tint the logo and badge together for
  /// the menu bar's appearance and selection. Clear digits and a small halo
  /// keep the overlapping badge legible without painting a fixed background.
  private static func badgeImage(logo: NSImage?, count: Int?) -> NSImage {
    let label: String
    if let count, count > 0 {
      label = count > 99 ? "99+" : String(count)
    } else {
      label = ""
    }
    let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { bounds in
      // Balance the portrait's fine cutouts against neighboring system symbols.
      logo?.draw(in: NSRect(x: label.isEmpty ? (bounds.width - 17) / 2 : 2, y: label.isEmpty ? 2.5 : 4,
                           width: 17, height: 17))
      if !label.isEmpty, let context = NSGraphicsContext.current?.cgContext {
        let badge = NSRect(x: bounds.maxX - 15, y: 0.5, width: 12.5, height: 12.5)
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: badge.insetBy(dx: -0.75, dy: -0.75))
        context.restoreGState()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let size: CGFloat = label.count == 1 ? 9.5 : label.count == 2 ? 8.5 : 6.5
        let text = NSAttributedString(string: label, attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
          .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.textPosition = NSPoint(x: badge.midX - ink.midX, y: badge.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = count.map { "\($0) unread" } ?? "Harness"
    return image
  }

  private static let unreadDot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
    NSColor.systemBlue.setFill()
    NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6)).fill()
    return true
  }
}
