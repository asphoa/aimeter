import Foundation

/// Cursor's usage is deliberately shown as a link, not a number.
///
/// Owner's decision "B-0": Cursor has no public usage API. The two
/// undocumented routes that would work anyway — reading Cursor's own stored
/// token to call its private RPC, or scraping the dashboard with a browser
/// session — were both weighed and rejected: neither is a route this project
/// wants to depend on. So this row exists only to point at the real page.
final class CursorProvider: Provider, @unchecked Sendable {
    let id = "cursor"
    var title: String { L.t("p.cursor") }
    private let cfg: Config
    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        guard FileManager.default.fileExists(atPath: "/Applications/Cursor.app") else { return [] }
        return [.off(id, title, "Cursor", L.t("x.cursor.link"))]
    }
}
