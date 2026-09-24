#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CoreGraphics

// A scripted pass over the running app through the accessibility API.
//
// Unit tests cover the logic; this covers the wiring between views that unit
// tests cannot reach — in particular that the "Show" buttons actually navigate,
// which was broken for the app's whole life without anyone noticing.
//
//   swift smoke-test.swift
//
// Needs Accessibility permission for whichever process runs it
// (System Settings -> Privacy & Security -> Accessibility).

/// Matched by bundle id: the display name has a space, the executable does not.
let bundleID = "com.fournotes.mac"
var failures: [String] = []
var checks = 0

func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks += 1
    if passed {
        print("  ✔ \(name)")
    } else {
        print("  ✘ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(name)
    }
}

// MARK: - Accessibility plumbing

guard AXIsProcessTrusted() else {
    print("Accessibility permission is not granted for this process; cannot drive the app.")
    exit(2)
}

// A locked screen stops any app becoming active, and SwiftUI does not publish
// an accessibility tree for an inactive app — every check would fail for a
// reason that has nothing to do with the code.
if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
   (session["CGSSessionScreenIsLocked"] as? Int) == 1 {
    print("The screen is locked, so the app cannot be driven. Unlock and run again.")
    exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
else {
    print("\(bundleID) is not running. Build and launch it first.")
    exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    return (value as? [AXUIElement]) ?? []
}

func attribute(_ element: AXUIElement, _ key: String) -> String? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value as? String
}

func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 30 else { return [] }
    return [element] + children(element).flatMap { descendants($0, depth: depth + 1) }
}

func allElements() -> [AXUIElement] {
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
    return ((windows as? [AXUIElement]) ?? []).flatMap { descendants($0) }
}

func label(_ element: AXUIElement) -> String {
    attribute(element, kAXDescriptionAttribute as String)
        ?? attribute(element, kAXTitleAttribute as String)
        ?? attribute(element, kAXValueAttribute as String)
        ?? ""
}

/// Everything currently on screen that carries a name — static text, and the
/// buttons whose labels are the only text some sections have.
func visibleText() -> [String] {
    allElements().compactMap { element in
        let text = label(element)
        return text.isEmpty ? nil : text
    }
}

func showing(_ needle: String) -> Bool {
    visibleText().contains { $0.localizedCaseInsensitiveContains(needle) }
}

@discardableResult
func press(_ name: String, exact: Bool = false) -> Bool {
    for element in allElements() {
        let role = attribute(element, kAXRoleAttribute as String) ?? ""
        guard role.contains("Button") else { continue }
        let text = label(element)
        let hit = exact ? text == name : text.localizedCaseInsensitiveContains(name)
        if hit {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            return true
        }
    }
    return false
}

func settle(_ seconds: Double = 1.2) { Thread.sleep(forTimeInterval: seconds) }

// MARK: - The pass

app.activate()
settle()

print("\nTabs")
for tab in ["Today", "Notes", "To-Do", "Finance"] {
    let pressed = press(tab, exact: true)
    settle()
    check("\(tab) opens", pressed && showing(tab), detail: pressed ? "no heading" : "no sidebar row")
}

print("\nNavigation")
// The regression that matters: a "Show"-style jump has to switch tabs *and*
// reveal the row. `.onChange` could never do this, because switching tabs
// creates the destination view and the value was already set.
press("Today", exact: true)
settle()
// Each task row exposes "Complete <title>" next to "<title>", so the completion
// button names the task to click without guessing.
let taskTitle = allElements()
    .map(label)
    .first { $0.hasPrefix("Complete ") }
    .map { String($0.dropFirst("Complete ".count)) }

if let taskTitle {
    let pressed = press(taskTitle, exact: true)
    settle(1.6)
    check("clicking \"\(taskTitle)\" on Today reveals it in To-Do",
          pressed && showing("Status") && showing("Created"),
          detail: pressed ? "the task panel did not open" : "could not find the row")
} else {
    print("  – no task due today to click (load sample data to cover this)")
}

print("\nSheets")
press("Search or quick add")
settle()
let paletteUp = showing("GO TO")
check("the command palette opens", paletteUp)
if paletteUp {
    // A window shows one sheet at a time; asking for another used to do nothing
    // and leave the request stuck.
    press("Settings, budgets")
    settle(1.6)
    check("settings can replace the palette", showing("Appearance") || showing("Data & privacy"))
    press("Close")
    settle()
}

print("\nStability")
check("the app is still running", app.isTerminated == false)

// MARK: - Result

print("\n\(checks - failures.count)/\(checks) passed")
if failures.isEmpty {
    print("Smoke test passed.")
} else {
    print("Failed: \(failures.joined(separator: ", "))")
    exit(1)
}
