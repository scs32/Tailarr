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

        let slices = SharedState.load()
        guard !slices.isEmpty else {
            contentHandler(content)
            return
        }

        // A content-free wake can come from ANY server the device is
        // registered with (iOS gives one token per app), so fetch every
        // profile's slice and show the newest unseen message across all.
        NtfyFetcher.fetchUnseenAcross(slices) { results in
            defer { contentHandler(content) }
            let all = results.flatMap { $0.messages }.sorted { $0.time < $1.time }
            guard let newest = all.last else { return }

            content.title = newest.displayTitle
            content.body = newest.message ?? ""
            if all.count > 1 {
                content.body += " (+\(all.count - 1) more)"
            }
            content.threadIdentifier = newest.topic

            // Advance each slice's markers so BG refresh doesn't re-notify.
            for result in results where !result.messages.isEmpty {
                result.slice.markNotified(result.messages)
            }
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

/// One profile's slice of the app's shared-state file (tailarr_ntfy.json in
/// the App Group container). The file holds every server-owned profile's
/// subscription + markers under `profiles.<name>`; each slice reads/advances
/// its own entry. markNotified re-reads the whole file so concurrent slices
/// don't clobber each other's markers.
final class SharedState {
    let profile: String
    let url: String
    let token: String
    let topics: [String]
    let bgSince: Int
    let notifiedIds: [String]
    private let fileURL: URL

    private init?(profile: String, entry: [String: Any], fileURL: URL) {
        guard
            let url = entry["url"] as? String, !url.isEmpty,
            let topics = entry["topics"] as? [String], !topics.isEmpty
        else { return nil }
        self.profile = profile
        self.url = url
        self.token = entry["token"] as? String ?? ""
        self.topics = topics
        self.bgSince = entry["bg_since"] as? Int ?? 0
        self.notifiedIds = entry["notified_ids"] as? [String] ?? []
        self.fileURL = fileURL
    }

    private static func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NotificationService.appGroupId)?
            .appendingPathComponent("tailarr_ntfy.json")
    }

    /// Every profile slice with a usable subscription.
    static func load() -> [SharedState] {
        guard
            let fileURL = fileURL(),
            let data = try? Data(contentsOf: fileURL),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profiles = raw["profiles"] as? [String: Any]
        else { return [] }
        return profiles.compactMap { (name, value) in
            guard let entry = value as? [String: Any] else { return nil }
            return SharedState(profile: name, entry: entry, fileURL: fileURL)
        }
    }

    func markNotified(_ messages: [NtfyMessage]) {
        guard
            let data = try? Data(contentsOf: fileURL),
            var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var profiles = raw["profiles"] as? [String: Any],
            var entry = profiles[profile] as? [String: Any]
        else { return }

        var since = entry["bg_since"] as? Int ?? bgSince
        for message in messages where message.time > since { since = message.time }
        let priorIds = entry["notified_ids"] as? [String] ?? notifiedIds
        entry["bg_since"] = since
        entry["notified_ids"] = Array((messages.map { $0.id } + priorIds).prefix(25))
        profiles[profile] = entry
        raw["profiles"] = profiles
        if let out = try? JSONSerialization.data(withJSONObject: raw) {
            try? out.write(to: fileURL, options: .atomic)
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

struct SliceResult {
    let slice: SharedState
    let messages: [NtfyMessage]
}

enum NtfyFetcher {
    /// Fetch unseen messages for every profile slice concurrently, so a wake
    /// from any registered server surfaces the right content.
    static func fetchUnseenAcross(
        _ slices: [SharedState],
        completion: @escaping ([SliceResult]) -> Void
    ) {
        let group = DispatchGroup()
        var results: [SliceResult] = []
        let lock = NSLock()
        for slice in slices {
            group.enter()
            fetchUnseen(state: slice) { messages in
                lock.lock()
                results.append(SliceResult(slice: slice, messages: messages))
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results) }
    }

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
