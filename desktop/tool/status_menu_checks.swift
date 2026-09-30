// Appended to the production AppKit source by check_swarm_titlebar.sh --status-menu.
private struct StatusMenuFailure: Error { let message: String }
private var checks = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  guard value() else { throw StatusMenuFailure(message: message) }
  checks += 1
}

private func renderedStatusPixels(_ image: NSImage) -> Data {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
    pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = image.size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}

private func fixture(_ agent: String, project: String = "autonomous-harness",
                     tabId: String? = "tab-build", tabName: String = "Build", machine: String = "office",
                     unread: Bool = true, token: String = "first", offline: Bool = false) -> [String: Any] {
  var row: [String: Any] = ["machineId": machine,
    "agentId": agent, "title": agent, "tabName": tabId == nil ? "Other sessions" : tabName, "unread": unread,
    "detail": "Office Mac · \(project)"]
  row["tabId"] = tabId
  if unread { row["readToken"] = token; row["label"] = "Finished" }
  if offline { row["unavailable"] = "Offline" }
  return row
}

private extension HarnessStatusMenu {
  func item(_ action: String) -> NSMenuItem {
    menu.items.first { $0.identifier?.rawValue == action }!
  }
  func row(_ agent: String) -> NSMenuItem {
    menu.items.first { ($0.representedObject as? [String: Any])?["agentId"] as? String == agent }!
  }
  func click(_ item: NSMenuItem) { menu.performActionForItem(at: menu.index(of: item)) }
}

_ = NSApplication.shared
var emitted: [(String, Any?)] = []
var reveals = 0
let status = HarnessStatusMenu(installStatusItem: false, showWindow: { reveals += 1 },
                               emit: { emitted.append(($0, $1)) })
do {
  var rows = [fixture("General chat conversation"),
              fixture("DeepSeek model", project: "No Project", unread: false),
              fixture("Math addition inquiry", project: "No Project", tabId: nil, offline: true)]
  status.update(["enabled": true, "statusMenuEntries": rows])
  try check(status.menu.items.filter { $0.state == .on }.count == 2, "Unread rows have dots")
  try check(status.row("General chat conversation").onStateImage != nil, "A blue dot replaces the checkmark")
  try check(status.menu.items.contains { $0.title == "Build" && !$0.isEnabled } &&
            status.menu.items.contains { $0.title == "Other sessions" && !$0.isEnabled }, "Tabs and other sessions use native section headings")
  try check(!status.row("Math addition inquiry").isEnabled, "Offline conversations stay visible but disabled")
  try check(status.row("Math addition inquiry").toolTip?.contains("Offline") == true, "Unavailable state is explained")
  try check(!status.menu.items.contains { $0.title == "DeepSeek model" }, "Read conversations are absent from the notification menu")
  status.click(status.row("General chat conversation"))
  try check(emitted.last?.0 == "openStatusHarness" && reveals == 0, "Navigation is sent before revealing the window")
  status.click(status.item("newAgent"))
  status.click(status.item("settings"))
  try check(emitted.suffix(2).map { $0.0 } == ["newAgent", "settings"] && reveals == 2,
            "New Harness and Settings reveal the window and reuse existing actions")

  status.menuWillOpen(status.menu)
  let selected = status.row("General chat conversation")
  let before = emitted.count
  rows[0] = fixture("General chat conversation", token: "newer")
  rows.append(fixture("New result", project: "website", tabId: "tab-website", tabName: "Website"))
  status.update(["enabled": true, "statusMenuEntries": rows])
  try check(status.row("General chat conversation") === selected &&
            !status.menu.items.contains { $0.title == "Website" }, "Arrivals do not move open-menu rows")
  status.click(selected)
  try check(emitted.count == before, "A replaced notification cannot dispatch an old click")
  status.click(status.item("clearStatusNotifications"))
  let receipt = emitted.last?.1 as? [String: Any]
  let cleared = receipt?["receipts"] as? [[String: Any]]
  try check(emitted.last?.0 == "clearStatusNotifications" && cleared?.count == 2 &&
            cleared?.first?["readToken"] as? String == "first", "Clear sends only displayed receipts, never new arrivals")
  status.menuDidClose(status.menu)
  status.menuNeedsUpdate(status.menu)
  try check(status.menu.items.contains { $0.title == "Website" }, "The next opening shows new arrivals")

  status.menuWillOpen(status.menu)
  let originalLocation = status.row("General chat conversation")
  rows[0]["tabId"] = "tab-review"
  rows[0]["tabName"] = "Review"
  status.update(["enabled": true, "statusMenuEntries": rows])
  status.click(originalLocation)
  let originalReceipt = emitted.last?.1 as? [String: Any]
  try check(emitted.last?.0 == "openStatusHarness" && originalReceipt?["tabId"] as? String == "tab-build",
            "A current notification retains its displayed destination when tabs change")
  try check(!status.menu.items.contains { $0.title == "Review" }, "Tab changes do not move open-menu rows")
  status.menuDidClose(status.menu)
  status.menuNeedsUpdate(status.menu)
  try check(status.menu.items.contains { $0.title == "Review" }, "The next opening reflects the new tab group")

  status.update(["enabled": false, "statusMenuEntries": rows])
  try check(!status.item("newAgent").isEnabled && !status.item("addAgent").isEnabled && !status.item("settings").isEnabled &&
            !status.item("clearStatusNotifications").isEnabled, "A modal disables workspace actions")
  status.click(status.item("openWindow"))
  try check(reveals == 3, "Show Harness remains available during a modal")
  status.update(["enabled": true, "statusMenuEntries": []])
  try check(status.menu.items.first?.title == "No unread notifications" &&
            !status.item("clearStatusNotifications").isEnabled, "An empty inbox is explicit and cannot be cleared")
  let open = status.menu.items.first { $0.title == "Open Harness…" }!
  status.click(open)
  try check(emitted.last?.0 == "addAgent" && reveals == 4,
            "Open Harness reveals the window and opens the existing-session picker even with no notifications")
  let beforeShow = emitted.count
  status.click(status.menu.items.first { $0.title == "Show Harness" }!)
  try check(reveals == 5 && emitted.count == beforeShow,
            "Show Harness only reveals the app, without opening a picker")
  status.update([:])
  try check(!status.menu.items.contains { $0.identifier?.rawValue == "openStatusHarness" }, "Sign-out removes all conversation data")
  try check(status.item("openWindow").isEnabled && status.item("quit").isEnabled &&
            !status.item("addAgent").isEnabled,
            "The signed-out menu still offers Show and Quit, but cannot open the session picker")
  // Exercise the actual AppKit status button: the displayed number must agree
  // with the notification rows, with a bare icon after the last read.
  func checkCounter() throws {
    let assets = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_TITLEBAR_ASSETS"]!)
    let logo = NSImage(contentsOf: assets.deletingLastPathComponent().appendingPathComponent(
      "macos/Runner/Assets.xcassets/HarnessStatusIcon.imageset/HarnessStatusIcon.svg"))
    try check(logo != nil, "The menu bar template loads from the Harness artwork")
    logo?.setName("HarnessStatusIcon")
    let indicator = HarnessStatusMenu(showWindow: {}, emit: { _, _ in })
    indicator.update(["enabled": true, "statusMenuEntries": rows])
    try check(indicator.statusItem?.button?.title == "" &&
              indicator.statusItem?.button?.image?.accessibilityDescription == "3 unread" &&
              indicator.statusItem?.button?.image?.isTemplate == true &&
              indicator.statusItem?.button?.accessibilityValue() as? String == "3 unread",
              "The monochrome Harness template carries the count badge without a separate text label")
    let unreadPixels = renderedStatusPixels(indicator.statusItem!.button!.image!)
    indicator.update(["enabled": true, "statusMenuEntries": []])
    try check(indicator.statusItem?.button?.image?.accessibilityDescription == "0 unread" &&
              indicator.statusItem?.button?.toolTip == "Harness · 0 unread" &&
              indicator.statusItem?.button?.accessibilityValue() as? String == "0 unread",
              "An empty inbox keeps its exact count in the tooltip and accessibility value")
    let zeroPixels = renderedStatusPixels(indicator.statusItem!.button!.image!)
    let badgeSize = indicator.statusItem?.button?.image?.size
    indicator.update(["enabled": true, "statusMenuEntries": (0..<101).map { fixture("Task \($0)") }])
    try check(indicator.statusItem?.button?.image?.size == badgeSize &&
              indicator.statusItem?.button?.accessibilityValue() as? String == "101 unread",
              "Large counts keep the logo and badge footprint and expose the exact value to accessibility")
    indicator.update([:])
    try check(indicator.statusItem?.button?.image?.accessibilityDescription == "Harness",
              "Sign-out clears the account's counter")
    let plainPixels = renderedStatusPixels(indicator.statusItem!.button!.image!)
    try check(zeroPixels == plainPixels,
              "Zero notifications render only the plain icon, without a number or badge circle")
    try check(unreadPixels != plainPixels,
              "Unread notifications add a visible badge to the icon")
  }
  try checkCounter()
  status.update(["enabled": true, "statusMenuEntries": [
    fixture("API result", tabId: "tab-one", tabName: "Work"),
    fixture("Website result", project: "website", tabId: "tab-one", tabName: "Work", machine: "laptop"),
    fixture("Review result", tabId: "tab-two", tabName: "Work"),
    fixture("Background result", tabId: nil),
  ]])
  let headings = status.menu.items.filter { !$0.isEnabled && !$0.isSeparatorItem && $0.representedObject == nil }
  try check(headings.map { $0.title } == ["Work", "Work", "Other sessions"],
            "Tab IDs keep equal names separate, combine projects and machines, and preserve section order")
  try check(status.menu.index(of: status.row("Website result")) < status.menu.index(of: headings[1]) &&
            status.menu.index(of: status.row("Review result")) > status.menu.index(of: headings[1]),
            "Each row stays inside its tab's section")
  try check(status.row("Website result").toolTip?.contains("website") == true,
            "Project context remains available in the row tooltip")
  print("Harness status menu passed \(checks) checks")
} catch {
  fputs("Harness status menu failed: \(error)\n", stderr)
  exit(1)
}
