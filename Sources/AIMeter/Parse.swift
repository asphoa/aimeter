import Foundation

/// Typed parse outcome: success, absent field, or present but unusable.
enum ParseResult<T: Sendable>: Sendable {
    case value(T)
    case missing
    case invalid
}

enum Parse {
    private static let maxMagnitude = 1e15

    /// Accepts only finite Double/Int from JSON — rejects Bool, NaN, Infinity, |x|>1e15.
    static func number(_ value: Any?) -> ParseResult<Double> {
        guard let value else { return .missing }
        if value is Bool { return .invalid }
        if let n = value as? Double {
            guard n.isFinite, abs(n) <= maxMagnitude else { return .invalid }
            return .value(n)
        }
        if let n = value as? Int {
            let d = Double(n)
            guard d.isFinite, abs(d) <= maxMagnitude else { return .invalid }
            return .value(d)
        }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .invalid }
            let d = n.doubleValue
            guard d.isFinite, abs(d) <= maxMagnitude else { return .invalid }
            return .value(d)
        }
        if let s = value as? String {
            guard let d = Double(s), d.isFinite, abs(d) <= maxMagnitude else { return .invalid }
            return .value(d)
        }
        return .invalid
    }

    /// Used/limit → used percent; requires limit > 0.
    static func percent(used: Double, limit: Double) -> ParseResult<Double> {
        guard limit > 0, used.isFinite, limit.isFinite else { return .invalid }
        return .value(max(0, min(100, used / limit * 100)))
    }

    static func findNumber(in obj: Any, names: [String]) -> ParseResult<Double> {
        let wanted = normalised(names)
        func walk(_ o: Any) -> ParseResult<Double>? {
            if let d = o as? [String: Any] {
                for (k, v) in d.sorted(by: { $0.key < $1.key }) where wanted.contains(norm(k)) {
                    switch number(v) {
                    case .value(let n): return .value(n)
                    case .invalid: return .invalid
                    case .missing: break
                    }
                }
                for (_, v) in d.sorted(by: { $0.key < $1.key }) {
                    if let r = walk(v) { return r }
                }
            } else if let a = o as? [Any] {
                for v in a { if let r = walk(v) { return r } }
            }
            return nil
        }
        return walk(obj) ?? .missing
    }

    static func findString(in obj: Any, names: [String]) -> ParseResult<String> {
        let wanted = normalised(names)
        func walk(_ o: Any) -> ParseResult<String>? {
            if let d = o as? [String: Any] {
                for (k, v) in d.sorted(by: { $0.key < $1.key }) where wanted.contains(norm(k)) {
                    if let s = v as? String, !s.isEmpty { return .value(s) }
                }
                for (_, v) in d.sorted(by: { $0.key < $1.key }) {
                    if let r = walk(v) { return r }
                }
            } else if let a = o as? [Any] {
                for v in a { if let r = walk(v) { return r } }
            }
            return nil
        }
        return walk(obj) ?? .missing
    }

    /// Stable gauge id for history (English slug, not a localized label).
    static func gaugeId(label: String, kind: GaugeKind) -> String {
        let slug = label.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "gauge" : slug
        return "\(kind.rawValue):\(base)"
    }
}

private func norm(_ k: String) -> String {
    k.lowercased().replacingOccurrences(of: "_", with: "")
}

private func normalised(_ names: [String]) -> Set<String> { Set(names.map(norm)) }

/// Display truncation with full text preserved for accessibility.
enum DisplayLimit {
    static let label = 64
    static let value = 64
    static let notice = 200

    static func truncate(_ s: String, max: Int) -> (display: String, full: String) {
        guard s.count > max else { return (s, s) }
        let end = s.index(s.startIndex, offsetBy: max)
        return (String(s[..<end]) + "…", s)
    }
}
