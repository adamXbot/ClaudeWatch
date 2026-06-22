import Foundation

// Entry point. `--dump` runs the headless inspector; `--render-test` validates the
// browser thread renderer; otherwise launch the menu-bar app.
if CommandLine.arguments.contains("--dump") {
    DumpRunner.run()
} else if CommandLine.arguments.contains("--render-test") {
    RenderTest.run()
} else {
    ClaudeWatchApp.main()
}
