import Foundation

// lubdub reference client — models + API.
//
// The server is the open-source lubdub (this repository):
//   POST   /letters                 {content, title?, reveal_at | lock_for}
//   GET    /letters?limit&offset    -> {total, offset, now, letters: [...]}
//   GET    /letters/{id}
//   DELETE /letters/{id}            retract (locked) / delete (revealed)
// Auth: Authorization: Bearer <writer_token> — this app is the writer's side.
// Replying is the agent's door (localhost, no token) and never happens here.
//
// There is no websocket: the wall polls while visible and refreshes when a
// countdown runs out. Reveals and replies arrive a poll late at worst.

struct LetterReply: Identifiable, Equatable {
    let id: String
    let content: String
    let ts: Double
}

struct Letter: Identifiable, Equatable {
    let id: String
    var title: String
    var content: String
    var ts: Double
    var revealAt: Double
    var status: String          // locked / revealed
    var revealedAt: Double?
    var replies: [LetterReply]
    /// A tlock letter is ciphertext while locked: even the writer gets only
    /// the door plate back, so there is no content to show until the reveal.
    var tlock: Bool

    var locked: Bool { status != "revealed" }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        title = d["title"] as? String ?? ""
        content = d["content"] as? String ?? ""
        ts = (d["ts"] as? NSNumber)?.doubleValue ?? 0
        revealAt = (d["reveal_at"] as? NSNumber)?.doubleValue ?? 0
        status = d["status"] as? String ?? "locked"
        revealedAt = (d["revealed_at"] as? NSNumber)?.doubleValue
        tlock = d["tlock"] as? Bool ?? false
        replies = (d["replies"] as? [[String: Any]] ?? []).compactMap { r in
            guard let rid = (r["id"] as? String) ?? (r["id"] as? NSNumber)?.stringValue else { return nil }
            return LetterReply(id: rid, content: r["content"] as? String ?? "",
                               ts: (r["ts"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.ts < $1.ts }
    }
}

enum LetterFormat {
    static func when(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        var f: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()
        if !Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) { f = f.year() }
        return d.formatted(f)
    }

    /// "in 2d 3h" / "in 3h 12m" / "in 5m" / "any moment now".
    /// The countdown is not decoration (see the README's field notes): an
    /// absolute time alone gets misread — by agents, and by humans too.
    static func countdown(_ secs: Double) -> String {
        guard secs > 30 else { return "any moment now" }
        let m = Int(secs / 60), h = m / 60, d = h / 24
        if d > 0 { return h % 24 > 0 ? "in \(d)d \(h % 24)h" : "in \(d)d" }
        if h > 0 { return m % 60 > 0 ? "in \(h)h \(m % 60)m" : "in \(h)h" }
        return "in \(max(1, m))m"
    }

    static func lockedFor(_ l: Letter) -> String {
        let m = Int((l.revealAt - l.ts) / 60), h = m / 60, d = h / 24
        if d > 0 { return "locked \(d)d" }
        if h > 0 { return "locked \(h)h" }
        return "locked \(max(1, m))m"
    }
}

@MainActor
final class LetterStore: ObservableObject {
    static let shared = LetterStore()

    @Published private(set) var letters: [Letter] = []
    @Published private(set) var total = 0
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var posting = false
    /// Server clock minus ours — countdowns trust the server's `now`,
    /// not the local clock.
    private(set) var skew: Double = 0

    var now: Double { Date().timeIntervalSince1970 + skew }

    /// Where your lubdub lives. Edited in the app's settings sheet; kept in
    /// UserDefaults together with the writer token (a reference client's
    /// shortcut — swap in the Keychain if that bothers you).
    static var baseURL: URL? {
        var s = (UserDefaults.standard.string(forKey: "lubdub_server") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest? {
        guard let base = Self.baseURL, let url = URL(string: path, relativeTo: base) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        let token = UserDefaults.standard.string(forKey: "lubdub_token") ?? ""
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    // MARK: - The wall

    func reload() async {
        guard !loading else { return }
        guard let req = request("letters?limit=100&offset=0") else {
            error = "no server yet — set the address in settings"
            loaded = true
            return
        }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard code == 200, let j else {
                error = (j?["error"] as? String).map { "the server said: \($0)" }
                    ?? "the server answered \(code)"
                return
            }
            if let n = (j["now"] as? NSNumber)?.doubleValue { skew = n - Date().timeIntervalSince1970 }
            letters = (j["letters"] as? [[String: Any]] ?? []).compactMap(Letter.init)
            total = (j["total"] as? NSNumber)?.intValue ?? letters.count
            error = nil
        } catch {
            self.error = "couldn't reach the server"
        }
    }

    // MARK: - Writing

    /// One of the two, same as the API: `.at(date)` -> reveal_at,
    /// `.after("3h")` -> lock_for. Server errors land in `error` verbatim.
    enum Reveal { case at(Date), after(String) }

    func create(title: String, content: String, reveal: Reveal) async -> Bool {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        guard var r = request("letters", method: "POST") else {
            error = "no server yet — set the address in settings"
            return false
        }
        posting = true
        defer { posting = false }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var j: [String: Any] = ["content": body]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { j["title"] = t }
        switch reveal {
        case .at(let d): j["reveal_at"] = Int(d.timeIntervalSince1970)
        case .after(let s): j["lock_for"] = s
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: j)
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard code == 200, o?["ok"] as? Bool != false, let id = o?["id"] as? String else {
                error = (o?["error"] as? String) ?? "the letter didn't go in (\(code))"
                return false
            }
            error = nil
            let at = (o?["reveal_at"] as? NSNumber)?.doubleValue ?? 0
            if let l = Letter(["id": id, "title": t, "content": body,
                               "ts": Date().timeIntervalSince1970, "reveal_at": at, "status": "locked"]) {
                letters.insert(l, at: 0)
                total += 1
            }
            Task { await reload() }
            return true
        } catch {
            self.error = "couldn't reach the server — the letter didn't go in"
            return false
        }
    }

    static func seconds(_ s: String) -> Double {
        guard let n = Double(s.dropLast()) else { return 3600 }
        switch s.last {
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return n
        }
    }

    // MARK: - Retract / delete

    func delete(_ id: String) async -> Bool {
        guard let req = request("letters/\(id)", method: "DELETE") else { return false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard code == 200 || code == 404, o?["ok"] as? Bool != false else {
                error = (o?["error"] as? String) ?? "couldn't take it back (\(code))"
                return false
            }
        } catch {
            self.error = "couldn't reach the server — nothing was taken back"
            return false
        }
        letters.removeAll { $0.id == id }
        total = max(0, total - 1)
        return true
    }
}
