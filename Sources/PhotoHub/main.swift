import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--scan") {
    CommandLineScan.run(Array(CommandLine.arguments.dropFirst(index + 1)))
}
if let index = CommandLine.arguments.firstIndex(of: "--sort") {
    CommandLineSort.run(Array(CommandLine.arguments.dropFirst(index + 1)))
}
if let index = CommandLine.arguments.firstIndex(of: "--fix-dates") {
    CommandLineFixDates.run(Array(CommandLine.arguments.dropFirst(index + 1)))
}
if let index = CommandLine.arguments.firstIndex(of: "--sync") {
    CommandLineSync.run(Array(CommandLine.arguments.dropFirst(index + 1)))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
