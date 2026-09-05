import AppKit
import Foundation

// MARK: - entry point
//
// @main rather than a plain main.swift: top-level executable statements are
// only allowed in a file literally named main.swift, and that name is already
// taken by the app itself (deliberately excluded from this build - see
// test.sh).

@main
struct Runner {
    static func main() {
        let integration = CommandLine.arguments.contains("--integration")
        let start = Date()
        runHermeticTests()
        if integration {
            runIntegrationTests()
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "(%.2fs)", elapsed))
        exit(T.summary())
    }
}
