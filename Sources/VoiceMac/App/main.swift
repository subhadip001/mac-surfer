import AppKit

// Entry point. A plain `main.swift` + NSApplication is used instead of a
// SwiftUI `App` scene because this is an LSUIElement menu-bar app: it owns no
// window at launch, and we want explicit control over the status item,
// overlay panel, and hot-key registration order.
//
// `NSApplication.delegate` is a weak reference, so the delegate is held here.
var applicationDelegate: AppDelegate?

// Headless verification of the transcript/router/graph logic. Runs without a
// microphone, a network connection, or any UI.
// Kept synchronous: adding `await` to top-level code would make the whole file
// an async context, which `MainActor.assumeIsolated` below cannot be called from.
if CommandLine.arguments.contains("--self-test") {
    Task.detached {
        let status = await SelfTest.run()
        exit(status)
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    applicationDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
