import Foundation

enum RecipeMap {
    /// JSONPath's deliberately tiny safe subset: $, .key and [n]. A bare key
    /// keeps the old GenericProvider's stable depth-first search semantics.
    static func value(at path: String, in obj: Any) -> Any? {
        if !path.hasPrefix("$") {
            if path.contains(",") {
                for name in path.split(separator: ",").map(String.init) {
                    if let found = value(at: name, in: obj) { return found }
                }
                return nil
            }
            guard !path.isEmpty,
                  path.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return bare(path, in: obj)
        }
        if path == "$" { return obj }
        var index = path.index(after: path.startIndex)
        var node: Any = obj
        while index < path.endIndex {
            if path[index] == "." {
                index = path.index(after: index)
                let start = index
                while index < path.endIndex, path[index] != ".", path[index] != "[" {
                    index = path.index(after: index)
                }
                guard start < index, let dict = node as? [String: Any] else { return nil }
                let key = String(path[start..<index])
                guard key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                      let next = dict[key] else { return nil }
                node = next
            } else if path[index] == "[" {
                index = path.index(after: index)
                let start = index
                while index < path.endIndex, path[index].isNumber { index = path.index(after: index) }
                guard start < index, index < path.endIndex, path[index] == "]",
                      let n = Int(path[start..<index]), let array = node as? [Any],
                      array.indices.contains(n) else { return nil }
                node = array[n]
                index = path.index(after: index)
            } else {
                return nil
            }
        }
        return node
    }

    static func apply(_ map: MapSpec, to data: Data, pick: String = "last") -> Reading {
        var reading = Reading(id: "recipe", title: "Recipe")
        guard map.format == "json" || map.format == "jsonl" else {
            reading.state = .warn; reading.lines = [L.t("a.unknown")]
            return reading
        }
        let obj: Any
        if map.format == "jsonl" {
            guard let record = pickJSONLRecord(data, pick: pick) else {
                reading.state = .warn; reading.lines = [L.t("a.unknown")]
                return reading
            }
            obj = record
        } else if let parsed = try? JSONSerialization.jsonObject(with: data) {
            obj = parsed
        } else {
            reading.state = .warn; reading.lines = [L.t("a.unknown")]
            return reading
        }

        var missing = false
        for spec in map.gauges {
            guard let gauge = makeGauge(spec, obj: obj) else { missing = true; continue }
            reading.gauges.append(gauge)
        }
        for line in map.lines {
            if let found = value(at: line.value, in: obj), let text = string(found) {
                reading.lines.append(line.prefix + text)
            }
        }
        if let path = map.snapshotAt, let found = value(at: path, in: obj) {
            reading.snapshotAt = date(found)
        }
        if missing || (map.gauges.isEmpty && reading.lines.isEmpty) {
            reading.state = .warn
            reading.lines.append(L.t("a.unknown"))
        } else {
            reading.state = worstState(reading.gauges)
        }
        return reading
    }

    static func unmappedTopLevelKeys(_ map: MapSpec, in data: Data) -> [String] {
        let obj: Any?
        if map.format == "jsonl" {
            obj = pickJSONLRecord(data, pick: "last")
        } else {
            obj = try? JSONSerialization.jsonObject(with: data)
        }
        guard let dict = obj as? [String: Any] else { return [] }
        var used = Set<String>()
        let paths = map.gauges.flatMap { [$0.value, $0.used, $0.limit, $0.remaining, $0.resetsAt] }
            + map.lines.map(\.value) + [map.snapshotAt]
        for case let path? in paths {
            if path.hasPrefix("$.") {
                let tail = path.dropFirst(2)
                if let first = tail.split(whereSeparator: { $0 == "." || $0 == "[" }).first {
                    used.insert(String(first))
                }
            } else if !path.hasPrefix("$") { used.insert(path) }
        }
        return dict.keys.filter { !used.contains($0) }.sorted()
    }

    private static func pickJSONLRecord(_ data: Data, pick: String) -> [String: Any]? {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var records: [[String: Any]] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let dict = obj as? [String: Any] else { continue }
            records.append(dict)
        }
        guard !records.isEmpty else { return nil }
        if pick == "first" { return records.first }
        if pick.hasPrefix("newestBy:") {
            let path = String(pick.dropFirst("newestBy:".count))
            var best: (record: [String: Any], stamp: Double)?
            for record in records {
                guard let raw = value(at: path, in: record),
                      let stamp = sortKey(raw) else { continue }
                if best == nil || stamp > best!.stamp { best = (record, stamp) }
            }
            return best?.record ?? records.last
        }
        return records.last
    }

    private static func sortKey(_ value: Any) -> Double? {
        switch Parse.number(value) {
        case .value(let n): return n
        case .missing, .invalid:
            if let text = value as? String { return ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970 }
            return nil
        }
    }

    private static func makeGauge(_ spec: GaugeSpec, obj: Any) -> Gauge? {
        let unit = spec.unit.lowercased()
        let reset = spec.resetsAt.flatMap { value(at: $0, in: obj) }.flatMap(date)
        let kind = window(spec.window)

        if let usedPath = spec.used, let limitPath = spec.limit,
           let used = number(value(at: usedPath, in: obj)),
           let limit = number(value(at: limitPath, in: obj)), limit != 0 {
            let percent = max(0, min(100, used / limit * 100))
            return Gauge(label: spec.label, percent: percent,
                         text: String(format: "%.0f%%", percent), resetsAt: reset, kind: kind)
        }
        if let remainingPath = spec.remaining, let limitPath = spec.limit,
           let remaining = number(value(at: remainingPath, in: obj)),
           let limit = number(value(at: limitPath, in: obj)), limit != 0 {
            let percent = max(0, min(100, 100 - remaining / limit * 100))
            return Gauge(label: spec.label, percent: percent,
                         text: String(format: "%.0f%%", percent), resetsAt: reset, kind: kind)
        }
        if let remainingPath = spec.remaining, unit == "fraction",
           let remaining = number(value(at: remainingPath, in: obj)) {
            let percent = max(0, min(100, 100 - remaining * 100))
            return Gauge(label: spec.label, percent: percent,
                         text: String(format: "%.0f%%", percent), resetsAt: reset, kind: kind)
        }
        guard let path = spec.value, let raw = value(at: path, in: obj) else { return nil }
        if unit == "text", let text = string(raw) {
            return Gauge(label: spec.label, percent: nil, text: text, resetsAt: reset, kind: kind)
        }
        switch Parse.number(raw) {
        case .value(let n):
            switch unit {
            case "percent":
                let percent = max(0, min(100, n))
                return Gauge(label: spec.label, percent: percent,
                             text: String(format: "%.0f%%", percent), resetsAt: reset, kind: kind)
            case "fraction":
                let percent = max(0, min(100, n * 100))
                return Gauge(label: spec.label, percent: percent,
                             text: String(format: "%.0f%%", percent), resetsAt: reset, kind: kind)
            case "tokens":
                return Gauge(label: spec.label, percent: nil,
                             text: String(format: "%.0f", n), resetsAt: reset, kind: kind)
            case "bytes":
                return Gauge(label: spec.label, percent: nil,
                             text: Fmt.gb(n), resetsAt: reset, kind: kind)
            default:
                return Gauge(label: spec.label, percent: nil,
                             text: Fmt.money(n, unit.uppercased()), resetsAt: reset, kind: kind)
            }
        case .missing, .invalid:
            return nil
        }
    }

    static func window(_ value: String) -> GaugeKind {
        switch value {
        case "5h": return .shortWindow
        case "weekly": return .longWindow
        case "model": return .modelWindow
        default: return .other
        }
    }

    private static func bare(_ name: String, in obj: Any) -> Any? {
        let wanted = name.lowercased().replacingOccurrences(of: "_", with: "")
        if let dict = obj as? [String: Any] {
            for key in dict.keys.sorted() {
                if key.lowercased().replacingOccurrences(of: "_", with: "") == wanted {
                    return dict[key]
                }
            }
            for key in dict.keys.sorted() {
                if let found = bare(name, in: dict[key] as Any) { return found }
            }
        } else if let array = obj as? [Any] {
            for item in array { if let found = bare(name, in: item) { return found } }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch Parse.number(value) {
        case .value(let n): return n
        case .missing, .invalid: return nil
        }
    }

    private static func string(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func date(_ value: Any) -> Date? {
        if let n = number(value) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
