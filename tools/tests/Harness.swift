import Foundation

/// A lightweight assertion harness, not XCTest. `swift test` runs through
/// SwiftPM, which spawns its own sandbox-exec for manifest evaluation and
/// cannot nest inside some sandboxed environments - the same reason build.sh
/// calls `swiftc` directly instead of `swift build`. Test code has to be
/// compiled and run the same way as everything else in this project.
enum T {
    nonisolated(unsafe) static var tests = 0
    nonisolated(unsafe) static var assertions = 0
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var skipped = 0
    nonisolated(unsafe) private static var skipReasons: [(String, String)] = []

    static func beginTest(_ name: String) {
        tests += 1
    }

    static func skip(_ name: String, _ reason: String) {
        skipped += 1
        skipReasons.append((name, reason))
        print("SKIP  \(name)  — \(reason)")
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "",
                      file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        if ok {
            passed += 1
        } else {
            failed += 1
            let where_ = "\(file)".split(separator: "/").last ?? "?"
            print("FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")  (\(where_):\(line))")
        }
    }

    static func eq<V: Equatable>(_ name: String, _ got: V, _ want: V,
                                 file: StaticString = #file, line: UInt = #line) {
        check(name, got == want, "got \(got), want \(want)", file: file, line: line)
    }

    static func near(_ name: String, _ got: Double, _ want: Double, tol: Double = 0.01,
                     file: StaticString = #file, line: UInt = #line) {
        check(name, abs(got - want) <= tol, "got \(got), want ~\(want)", file: file, line: line)
    }

    static func isNil<V>(_ name: String, _ got: V?,
                         file: StaticString = #file, line: UInt = #line) {
        check(name, got == nil, "got \(String(describing: got)), want nil", file: file, line: line)
    }

    static func notNil<V>(_ name: String, _ got: V?,
                          file: StaticString = #file, line: UInt = #line) {
        check(name, got != nil, "want non-nil", file: file, line: line)
    }

    static func summary() -> Int32 {
        for (name, reason) in skipReasons {
            print("skipped: \(name): \(reason)")
        }
        print("\n\(tests) tests, \(assertions) assertions, \(skipped) skipped")
        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
