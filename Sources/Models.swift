import Foundation

// MARK: - Player state (/Player/State.json)

struct PlayerStateResponse: Decodable {
    let metaplayer: Metaplayer
    let version: String?

    struct Metaplayer: Decodable {
        let playback: Playback
        let metadata: Metadata?
        let source: String?
        let shuffle: Bool?
        let `repeat`: String?
    }

    struct Playback: Decodable {
        let state: String            // "playing" | "paused" | "stopped" | "transitioning"
        let position: Int?           // seconds
        let allowed_actions: [String]?
    }

    // Metadata keys are the abbreviated DLNA/StreamUnlimited set. Only the ones we display.
    struct Metadata: Decodable {
        let ti: String?              // title
        let ar: String?              // artist
        let al: String?              // album
        let mp: String?             // media provider (e.g. "vTuner", "Spotify")
        let uri: String?             // stream URI of what's playing (playable via UPnP)
        let thumbnail_uri: String?
        let ca: String?             // codec (e.g. "libfdk_aac")
        let mt: String?             // mime type (e.g. "audio/mp4")
        let sf: Int?                 // sample rate (Hz)
        let br: Int?                 // bitrate (bps)
        let bs: Int?                 // bit depth
        let ac: Int?                 // channels
    }
}

// MARK: - Source selection (/Player/SourceSelection.json)

struct SourceSelectionResponse: Decodable {
    let available_source: [Source]
    let current_source: Source?

    struct Source: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let streamable: Bool?
        let casting: Bool?
    }
}

// MARK: - Zone state (/Zone/State.json) — carries volume (0-100) and mute

struct ZoneState: Decodable {
    let generation: Int
    let rendering_zones: [RenderingZone]

    struct RenderingZone: Decodable {
        let volume: Int?
        let muted: Bool?
    }

    var volume: Int? { rendering_zones.first?.volume }
    var muted: Bool { rendering_zones.first?.muted ?? false }
}

// MARK: - Device info (/System/DeviceInfo.json)

struct DeviceInfoResponse: Decodable {
    let device_info: DeviceInfo
    struct DeviceInfo: Decodable {
        let ProductName: String?
        let SoftwareVersion: String?
        let friendly_name: String?
        let uuid: String?
    }
}

// MARK: - Tone EQ (/Mixer/Capability/EQ.json) — classic bass/treble, range -9..+9

struct EQResponse: Decodable {
    let system_mixer_eq: EQ
    struct EQ: Decodable {
        let treble: Band?
        let bass: Band?
    }
    struct Band: Decodable {
        let data_min: Int
        let data_max: Int
        let data_step: Int
        let value: Int
    }
}

// MARK: - DEAP profiles (/Mixer/Capability/Deap/Settings.json)
// Speaker+room correction, NOT a tone EQ. Read-only in this app.

struct DeapSettingsResponse: Decodable {
    let eq_list: [Profile]
    let current_id: String?

    struct Profile: Decodable {
        let id: String
        let displayName: String
        let positions: [Position]
        struct Position: Decodable {
            let displayName: String
            let id: String
        }
    }

    /// Human label for the active profile, e.g. "Minorca MC40 + Sub · Position 1".
    var currentLabel: String? {
        guard let current = current_id else { return nil }
        for profile in eq_list {
            if let pos = profile.positions.first(where: { $0.id == current }) {
                let position = pos.displayName.replacingOccurrences(of: "_", with: " ")
                return "\(profile.displayName) · \(position)"
            }
        }
        return nil
    }
}

// MARK: - Streaming health (/System/AudioHub/Stats.json)

struct AudioHubStats: Decodable {
    let history_length: Int?
    let acquisition_interval: Int?
    let stat_values: [Sample]

    struct Sample: Decodable, Hashable {
        let bytes_per_second: Int
        let rate_percent: Int      // buffer fill rate vs. demand; ≥100 = keeping up
        let buffered_time: Int     // milliseconds buffered
    }
}

// MARK: - Power (/System/PowerState.json)

struct PowerStateResponse: Decodable {
    let power: Power
    struct Power: Decodable { let state: Bool }
}
