import Foundation

enum CanvasServiceError: LocalizedError {
    case notConnected
    case invalidTenant
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Canvas is not connected. Add a token in Settings → Connections."
        case .invalidTenant: return "The Canvas tenant URL is invalid."
        case .requestFailed(let message): return message
        case .invalidResponse: return "Canvas returned an unexpected response."
        }
    }
}

struct StickmanCanvasItem: Equatable {
    let title: String
    let date: Date?
    let course: String?
    let url: String?
}

final class CanvasService {
    static let shared = CanvasService()

    static let baseURLDefaultsKey = "StickmanCanvasBaseURL"

    private let session: URLSession
    private let isoFormatter = ISO8601DateFormatter()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: Self.baseURLDefaultsKey),
              let url = Self.normalizedBaseURL(from: raw)
        else { return nil }
        return url
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://\(raw)" }
        guard var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.standardized
    }

    func upcomingItems() async throws -> [StickmanCanvasItem] {
        guard let token = StickmanCredentialStore.shared.read(service: "Stickman Canvas Access Token"), !token.isEmpty else {
            throw CanvasServiceError.notConnected
        }
        guard let baseURL else { throw CanvasServiceError.invalidTenant }
        let url = baseURL.appendingPathComponent("api/v1/users/self/upcoming_events")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CanvasServiceError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CanvasServiceError.requestFailed(
                http.statusCode == 401
                    ? "Canvas rejected the token. Reconnect it in Settings → Connections."
                    : "Canvas request failed with status \(http.statusCode)."
            )
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CanvasServiceError.invalidResponse
        }
        return rows.compactMap(Self.item(from:))
    }

    func upcomingSummary() async -> String {
        do {
            let items = try await upcomingItems()
            guard !items.isEmpty else { return "Canvas has no upcoming assignments or events." }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let rows = items.prefix(15).map { item in
                let date = item.date.map { formatter.string(from: $0) } ?? "No due date"
                let course = item.course.map { " · \($0)" } ?? ""
                let url = item.url.map { " · \($0)" } ?? ""
                return "• \(date) — \(item.title)\(course)\(url)"
            }
            return "Upcoming Canvas work:\n\(rows.joined(separator: "\n"))"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func item(from json: [String: Any]) -> StickmanCanvasItem? {
        let assignment = json["assignment"] as? [String: Any]
        let title = (json["title"] as? String)
            ?? (assignment?["name"] as? String)
            ?? (json["name"] as? String)
        guard let title, !title.isEmpty else { return nil }
        let rawDate = (json["start_at"] as? String)
            ?? (json["end_at"] as? String)
            ?? (assignment?["due_at"] as? String)
        let date = rawDate.flatMap { ISO8601DateFormatter().date(from: $0) }
        let course = (json["context_name"] as? String) ?? (assignment?["course_id"] as? NSNumber).map { "Course \($0)" }
        let url = (json["html_url"] as? String) ?? (assignment?["html_url"] as? String)
        return StickmanCanvasItem(title: title, date: date, course: course, url: url)
    }
}
