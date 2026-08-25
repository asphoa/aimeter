import Foundation

/// Local inference: what is loaded into memory right now, and how much of the
/// machine it is holding. Asks the runtimes over their loopback APIs; when a
/// runtime is not serving, that is reported as "not running" rather than
/// guessed at from disk.
final class LocalAIProvider: Provider, @unchecked Sendable {
    let id = "local"
    var title: String { L.t("p.local") }

    func fetchAll(manual: Bool) async -> [Reading] { [await fetch()] }

    private func fetch() async -> Reading {
        var r = Reading(id: id, title: title)
        var loadedBytes: Double = 0
        var anyRuntime = false

        // --- Ollama ---
        if let req = Net.get("http://127.0.0.1:11434/api/ps", timeout: 3),
           let (obj, http) = try? await Net.json(req), http.statusCode == 200 {
            anyRuntime = true
            let running = ((obj as? [String: Any])?["models"] as? [[String: Any]]) ?? []
            if running.isEmpty {
                r.lines.append(L.t("l.ollama.idle"))
            } else {
                for m in running {
                    let name = (m["name"] as? String) ?? (m["model"] as? String) ?? "?"
                    let vram = findNumber(in: m, names: ["size_vram"]) ?? findNumber(in: m, names: ["size"]) ?? 0
                    loadedBytes += vram
                    var line = "Ollama: \(name) · \(Fmt.gb(vram))"
                    if let until = m["expires_at"] as? String,
                       let d = ISO8601DateFormatter.withFractional.date(from: until)
                                ?? ISO8601DateFormatter().date(from: until) {
                        line += " · " + L.t("l.unload", Fmt.relative(d))
                    }
                    r.lines.append(line)
                }
            }
            if let treq = Net.get("http://127.0.0.1:11434/api/tags", timeout: 3),
               let (tags, th) = try? await Net.json(treq), th.statusCode == 200 {
                let n = (((tags as? [String: Any])?["models"] as? [[String: Any]]) ?? []).count
                if n > 0 { r.lines.append(L.t("l.ollama.count", n)) }
            }
        }

        // --- LM Studio ---
        if let req = Net.get("http://127.0.0.1:1234/v1/models", timeout: 3),
           let (obj, http) = try? await Net.json(req), http.statusCode == 200 {
            anyRuntime = true
            let models = ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            if models.isEmpty {
                r.lines.append(L.t("l.lms.idle"))
            } else {
                for m in models.prefix(4) {
                    r.lines.append("LM Studio: \((m["id"] as? String) ?? "?")")
                }
            }
        }

        // --- MLX (mlx_lm.server / mlx_vlm.server) ---
        // Same OpenAI-compatible /v1/models shape as LM Studio, just a
        // different default port - this is the community-server pattern
        // people running their own MLX venv (rather than Ollama or LM
        // Studio) tend to land on, this machine's own local-model setup
        // included.
        if let req = Net.get("http://127.0.0.1:8081/v1/models", timeout: 3),
           let (obj, http) = try? await Net.json(req), http.statusCode == 200 {
            anyRuntime = true
            let models = ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            if models.isEmpty {
                r.lines.append(L.t("l.mlx.idle"))
            } else {
                for m in models.prefix(4) {
                    r.lines.append("MLX: \((m["id"] as? String) ?? "?")")
                }
            }
        }

        if !anyRuntime {
            return .off(id, title, nil, L.t("l.none"))
        }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        if loadedBytes > 0 {
            let pct = loadedBytes / total * 100
            r.gauges.append(Gauge(label: L.t("g.modelmem"), percent: pct,
                                  text: "\(Fmt.gb(loadedBytes)) / \(Fmt.gb(total))", resetsAt: nil))
        }
        if let free = Sys.freeMemoryBytes() {
            r.lines.append(L.t("l.sysmem", Fmt.gb(free), Fmt.gb(total)))
            if free / total < 0.10 { r.state = .warn }
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
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
