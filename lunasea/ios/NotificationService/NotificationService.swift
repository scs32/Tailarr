import UserNotifications

/// Pointer-push fetch: the server's wake push is content-free
/// ({"aps":{"mutable-content":1,"alert":{...generic...}}}); this extension
/// fetches the real messages from the user's OWN ntfy server (Funnel HTTPS —
/// no tsnet needed here) and rewrites the notification before display.
/// On any failure the generic "New activity on your server" text goes
/// through untouched — an honest fallback, never a dropped notification.
///
/// Config comes from the App Group file the main app mirrors its
/// notification settings into (see NtfySharedState in the Flutter side).
/// The extension advances the same `bg_since`/`notified_ids` markers the
/// BGAppRefresh path uses, so push and polling never double-notify.
class NotificationService: UNNotificationServiceExtension {
    static let appGroupId = "group.com.stephenspeicher.tailarr"

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent =
            request.content.mutableCopy() as? UNMutableNotificationContent
        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        guard let state = SharedState.load() else {
            contentHandler(content)
            return
        }

        NtfyFetcher.fetchUnseen(state: state) { messages in
            defer { contentHandler(content) }
            guard let newest = messages.last else { return }

            content.title = newest.displayTitle
            content.body = newest.message ?? ""
            if messages.count > 1 {
                content.body += " (+\(messages.count - 1) more)"
            }
            content.threadIdentifier = newest.topic

            // Advance the shared markers so BG refresh doesn't re-notify.
            state.markNotified(messages)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // ~30s budget exhausted — deliver whatever we have (usually the
        // generic fallback).
        if let contentHandler = contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }
}

/// Minimal mirror of the app's shared-state file (tailarr_ntfy.json in the
/// App Group container). Read/modify/write kept small and atomic; the app
/// side treats unknown keys as passthrough so the two writers coexist.
final class SharedState {
    let url: String
    let token: String
    let topics: [String]
    let bgSince: Int
    let notifiedIds: [String]
    private var raw: [String: Any]
    private let fileURL: URL

    private init?(raw: [String: Any], fileURL: URL) {
        guard
            let url = raw["url"] as? String, !url.isEmpty,
            let topics = raw["topics"] as? [String], !topics.isEmpty
        else { return nil }
        self.url = url
        self.token = raw["token"] as? String ?? ""
        self.topics = topics
        self.bgSince = raw["bg_since"] as? Int ?? 0
        self.notifiedIds = raw["notified_ids"] as? [String] ?? []
        self.raw = raw
        self.fileURL = fileURL
    }

    static func load() -> SharedState? {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NotificationService.appGroupId)
        else { return nil }
        let fileURL = container.appendingPathComponent("tailarr_ntfy.json")
        guard
            let data = try? Data(contentsOf: fileURL),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SharedState(raw: raw, fileURL: fileURL)
    }

    func markNotified(_ messages: [NtfyMessage]) {
        var since = bgSince
        for message in messages where message.time > since { since = message.time }
        raw["bg_since"] = since
        raw["notified_ids"] = Array(
            (messages.map { $0.id } + notifiedIds).prefix(25))
        if let data = try? JSONSerialization.data(withJSONObject: raw) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

struct NtfyMessage {
    let id: String
    let time: Int
    let topic: String
    let title: String?
    let message: String?

    var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        if topic == "tlr-ops" { return "Server" }
        if topic.hasPrefix("tlr-media-") {
            let service = String(topic.dropFirst("tlr-media-".count))
            if !service.isEmpty { return service.prefix(1).uppercased() + service.dropFirst() }
        }
        return topic.isEmpty ? "Tailarr" : topic
    }
}

enum NtfyFetcher {
    /// One-shot poll of everything unseen since the background marker.
    /// Wakes are coalesced server-side (one per 10s burst), so ALL unseen
    /// messages are fetched, never just one.
    static func fetchUnseen(
        state: SharedState,
        completion: @escaping ([NtfyMessage]) -> Void
    ) {
        // First-ever fetch: look back one hour, not the whole server cache.
        let since = state.bgSince != 0
            ? state.bgSince
            : Int(Date().timeIntervalSince1970) - 3600
        let topicPath = state.topics.joined(separator: ",")
        guard
            var components = URLComponents(
                string: "\(state.url)/\(topicPath)/json")
        else {
            completion([])
            return
        }
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: String(since)),
        ]
        guard let url = components.url else {
            completion([])
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        if !state.token.isEmpty {
            request.setValue("Bearer \(state.token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let body = String(data: data, encoding: .utf8) else {
                completion([])
                return
            }
            let seen = Set(state.notifiedIds)
            var messages: [NtfyMessage] = []
            for line in body.split(separator: "\n") {
                guard
                    let lineData = line.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any],
                    json["event"] as? String == "message",
                    let id = json["id"] as? String, !id.isEmpty,
                    !seen.contains(id)
                else { continue }
                messages.append(NtfyMessage(
                    id: id,
                    time: json["time"] as? Int ?? 0,
                    topic: json["topic"] as? String ?? "",
                    title: json["title"] as? String,
                    message: json["message"] as? String))
            }
            messages.sort { $0.time < $1.time }
            completion(messages)
        }.resume()
    }
}
