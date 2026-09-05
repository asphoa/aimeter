import Foundation

/// Local inference: what is loaded into memory right now, and how much of the
/// machine it is holding. Asks the runtimes over their loopback APIs; when a
/// runtime is not serving, that is reported as "not running" rather than
/// guessed at from disk.
final class LocalAIProvider: Provider, @unchecked Sendable {
    let id = "local"
    var title: String { L.t("p.local") }

    func fetchAll(manual: Bool) async -> [Reading] { [await fetch()] }

    private struct RuntimeProbe {
        var lines: [String] = []
        var loadedBytes: Double = 0
        var reached = false
        var badFormat = false
    }

    private func fetch() async -> Reading {
        async let ollama = probeOllama()
        async let lms = probeLMStudio()
        async let mlx = probeMLX()
        let (o, l, m) = await (ollama, lms, mlx)

        var r = Reading(id: id, title: title)
        var loadedBytes: Double = 0
        var anyRuntime = false

        for probe in [o, l, m] {
            if probe.reached { anyRuntime = true }
            if probe.badFormat {
                r.state = max(r.state, .warn)
                r.lines.append(L.t("p.invalid"))
            }
            r.lines.append(contentsOf: probe.lines)
            loadedBytes += probe.loadedBytes
        }

        if !anyRuntime {
            return .off(id, title, nil, L.t("l.none"))
        }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        if loadedBytes > 0 {
            let pct = loadedBytes / total * 100
            r.gauges.append(Gauge(label: L.t("l.ollama.reported"), percent: pct,
                                  text: "\(Fmt.gb(loadedBytes)) / \(Fmt.gb(total))", resetsAt: nil))
        }
        if let free = Sys.freeMemoryBytes() {
            r.lines.append(L.t("l.sysmem", Fmt.gb(free), Fmt.gb(total)))
            if free / total < 0.10 { r.state = .warn }
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
    }

    private func probeOllama() async -> RuntimeProbe {
        var probe = RuntimeProbe()
        guard let req = Net.get("http://127.0.0.1:11434/api/ps", timeout: 3) else { return probe }
        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch Net.JSONError.tooLarge {
            probe.reached = true
            probe.badFormat = true
            return probe
        }
        catch { return probe }

        guard http.statusCode == 200 else { return probe }
        probe.reached = true
        guard let root = obj as? [String: Any],
              let running = root["models"] as? [[String: Any]] else {
            probe.badFormat = true
            return probe
        }

        if running.isEmpty {
            probe.lines.append(L.t("l.ollama.idle"))
        } else {
            for m in running {
                let name = (m["name"] as? String) ?? (m["model"] as? String) ?? "?"
                let vram: Double
                switch Parse.findNumber(in: m, names: ["size_vram"]) {
                case .value(let n): vram = n
                case .missing, .invalid:
                    switch Parse.findNumber(in: m, names: ["size"]) {
                    case .value(let n): vram = n
                    default: vram = 0
                    }
                }
                probe.loadedBytes += vram
                var line = "Ollama: \(name) · \(Fmt.gb(vram))"
                if let until = m["expires_at"] as? String,
                   let d = ISO8601DateFormatter.withFractional.date(from: until)
                            ?? ISO8601DateFormatter().date(from: until) {
                    line += " · " + L.t("l.unload", Fmt.relative(d))
                }
                probe.lines.append(line)
            }
        }

        if let treq = Net.get("http://127.0.0.1:11434/api/tags", timeout: 3),
           let (tags, th) = try? await Net.json(treq), th.statusCode == 200,
           let tagRoot = tags as? [String: Any],
           let models = tagRoot["models"] as? [[String: Any]], !models.isEmpty {
            probe.lines.append(L.t("l.ollama.count", models.count))
        }
        return probe
    }

    private func probeLMStudio() async -> RuntimeProbe {
        var probe = RuntimeProbe()
        guard let req = Net.get("http://127.0.0.1:1234/v1/models", timeout: 3) else { return probe }
        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch Net.JSONError.tooLarge {
            probe.reached = true
            probe.badFormat = true
            return probe
        }
        catch { return probe }

        guard http.statusCode == 200 else { return probe }
        probe.reached = true
        guard let root = obj as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            probe.badFormat = true
            return probe
        }

        if models.isEmpty {
            probe.lines.append(L.t("l.lms.idle"))
        } else {
            for m in models.prefix(4) {
                probe.lines.append("LM Studio: \((m["id"] as? String) ?? "?")")
            }
        }
        return probe
    }

    private func probeMLX() async -> RuntimeProbe {
        var probe = RuntimeProbe()
        guard let req = Net.get("http://127.0.0.1:8081/v1/models", timeout: 3) else { return probe }
        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch Net.JSONError.tooLarge {
            probe.reached = true
            probe.badFormat = true
            return probe
        }
        catch { return probe }

        guard http.statusCode == 200 else { return probe }
        probe.reached = true
        guard let root = obj as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            probe.badFormat = true
            return probe
        }

        if models.isEmpty {
            probe.lines.append(L.t("l.mlx.idle"))
        } else {
            for m in models.prefix(4) {
                probe.lines.append("MLX: \((m["id"] as? String) ?? "?")")
            }
        }
        return probe
    }
}

enum Sys {
    /// free + inactive pages, which is what is actually reclaimable for a new model.
    static func freeMemoryBytes() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        return (Double(stats.free_count) + Double(stats.inactive_count)) * page
    }
}
