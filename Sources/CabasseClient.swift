import Foundation

/// Thin async wrapper over the amp's local REST API (StreamUnlimited platform,
/// re-branded Cabasse). Base is `http://<host>:34000`. No authentication.
struct CabasseClient {
    let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        self.session = Net.session(timeout: 35)   // long-poll waits up to ~10s server-side
    }

    enum ClientError: Error { case http(Int), badResponse }

    // MARK: Reads

    func deviceInfo() async throws -> DeviceInfoResponse {
        try await get("/System/DeviceInfo.json")
    }

    func playerState() async throws -> PlayerStateResponse {
        try await get("/Player/State.json")
    }

    func sources() async throws -> SourceSelectionResponse {
        try await get("/Player/SourceSelection.json")
    }

    func zoneState() async throws -> ZoneState {
        try await get("/Zone/State.json")
    }

    func powerState() async throws -> Bool {
        let r: PowerStateResponse = try await get("/System/PowerState.json")
        return r.power.state
    }

    func eq() async throws -> EQResponse {
        try await get("/Mixer/Capability/EQ.json")
    }

    func deapSettings() async throws -> DeapSettingsResponse {
        try await get("/Mixer/Capability/Deap/Settings.json")
    }

    func audioHubStats() async throws -> AudioHubStats {
        try await get("/System/AudioHub/Stats.json")
    }

    // MARK: Tone EQ writes (value only; range is -9...9)

    func setBass(_ value: Int) async throws {
        try await post("/Mixer/Capability/EQ/Bass.json", body: ["value": value])
    }

    func setTreble(_ value: Int) async throws {
        try await post("/Mixer/Capability/EQ/Treble.json", body: ["value": value])
    }

    // MARK: Transport (PUT, no body)

    func play()     async throws { try await put("/Player/Play.json") }
    func pause()    async throws { try await put("/Player/Pause.json") }
    func stop()     async throws { try await put("/Player/Stop.json") }
    func next()     async throws { try await put("/Player/Next.json") }
    func previous() async throws { try await put("/Player/Previous.json") }

    // MARK: Source & power

    func selectSource(id: Int) async throws {
        try await post("/Player/SourceSelection.json", body: ["id": id])
    }

    func setPower(_ on: Bool) async throws {
        try await post("/System/PowerState.json", body: ["state": on])
    }

    // MARK: Volume & mute — read-modify-write of the whole zone state.
    // The amp guards concurrent writes with an incrementing `generation`
    // sent back as the `If-None-Match` ETag; a 412 means someone else won,
    // so we refetch and retry once.

    func setVolume(_ value: Int) async throws {
        try await mutateZone { zone in
            let v = max(0, min(100, value))
            var rz = (zone["rendering_zones"] as? [[String: Any]]) ?? []
            guard !rz.isEmpty else { return false }
            rz[0]["volume"] = v
            zone["rendering_zones"] = rz
            return true
        }
    }

    func setMuted(_ muted: Bool) async throws {
        try await mutateZone { zone in
            var rz = (zone["rendering_zones"] as? [[String: Any]]) ?? []
            guard !rz.isEmpty else { return false }
            rz[0]["muted"] = muted
            zone["rendering_zones"] = rz
            return true
        }
    }

    /// Fetches the zone state, applies `edit`, and POSTs it back with the bumped
    /// generation as the `If-None-Match` header. Retries once on a 412 conflict.
    private func mutateZone(_ edit: (inout [String: Any]) -> Bool) async throws {
        for attempt in 0..<2 {
            let data = try await rawGET("/Zone/State.json")
            guard var zone = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ClientError.badResponse }

            let gen = (zone["generation"] as? Int) ?? 0
            zone["generation"] = gen + 1
            guard edit(&zone) else { return }

            let body = try JSONSerialization.data(withJSONObject: zone)
            var req = request("/Zone/State.json", method: "POST")
            req.setValue("\(gen + 1)", forHTTPHeaderField: "If-None-Match")
            req.httpBody = body

            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 412 && attempt == 0 { continue }   // conflict: refetch & retry
            guard (200...299).contains(code) else { throw ClientError.http(code) }
            return
        }
    }

    // MARK: - Primitives

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await rawGET(path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rawGET(_ path: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request(path, method: "GET"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw ClientError.http(code) }
        return data
    }

    private func put(_ path: String) async throws {
        let (_, resp) = try await session.data(for: request(path, method: "PUT"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw ClientError.http(code) }
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        var req = request(path, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw ClientError.http(code) }
    }

    // MARK: - Long-poll (ETag)

    /// Blocks until the resource at `path` changes (or the server's wait window
    /// elapses). Pass the last ETag; returns the fresh body plus the new ETag to
    /// feed into the next call. Returns `nil` body on a 304 (no change).
    func longPoll(_ path: String, etag: String?, wait: Int = 10) async throws -> (data: Data?, etag: String?) {
        var req = request(path, method: "GET")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        req.setValue("wait=\(wait)", forHTTPHeaderField: "Prefer")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        let newEtag = http.value(forHTTPHeaderField: "ETag") ?? etag
        if http.statusCode == 304 || http.statusCode == 204 {
            return (nil, newEtag)
        }
        guard (200...299).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        return (data, newEtag)
    }
}
