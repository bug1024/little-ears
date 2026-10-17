import Foundation

struct AquariumConfiguration: Codable, Equatable, Sendable {
    static let defaultsKey = "aquarium.configuration.v1"
    static let maximumFish = 40
    var fishCounts: [Int: Int] = Dictionary(uniqueKeysWithValues: [300, 304, 306, 310, 314, 316, 323, 325].map { ($0, 1) })
    var blueBackdrop = false
    var showMoray = true
    var showStarfish = true
    var bubbles = true
    var caustics = true
    var ambientEnabled = false
    var ambientVolume = 0.16
    var duckDuringPlayback = true
    var energySaving = false
    var moonJellyCount = 3
    init() {}
    private enum CodingKeys: String, CodingKey {
        case fishCounts, blueBackdrop, showMoray, showStarfish, bubbles, caustics, ambientEnabled, ambientVolume, duckDuringPlayback, energySaving, moonJellyCount
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fishCounts = try c.decodeIfPresent([Int: Int].self, forKey: .fishCounts) ?? fishCounts
        blueBackdrop = try c.decodeIfPresent(Bool.self, forKey: .blueBackdrop) ?? blueBackdrop
        showMoray = try c.decodeIfPresent(Bool.self, forKey: .showMoray) ?? showMoray
        showStarfish = try c.decodeIfPresent(Bool.self, forKey: .showStarfish) ?? showStarfish
        bubbles = try c.decodeIfPresent(Bool.self, forKey: .bubbles) ?? bubbles
        caustics = try c.decodeIfPresent(Bool.self, forKey: .caustics) ?? caustics
        ambientEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientEnabled) ?? ambientEnabled
        ambientVolume = try c.decodeIfPresent(Double.self, forKey: .ambientVolume) ?? ambientVolume
        duckDuringPlayback = try c.decodeIfPresent(Bool.self, forKey: .duckDuringPlayback) ?? duckDuringPlayback
        energySaving = try c.decodeIfPresent(Bool.self, forKey: .energySaving) ?? energySaving
        moonJellyCount = try c.decodeIfPresent(Int.self, forKey: .moonJellyCount) ?? moonJellyCount
    }
    var totalFish: Int { fishCounts.values.reduce(0, +) }
    var framesPerSecond: Int { energySaving ? 24 : 30 }
    var shadowResolution: Int { energySaving ? 1024 : 2048 }
    var maximumDrawableDimension: CGFloat { energySaving ? 1280 : 2560 }

    func normalized() -> Self {
        var value = self, remaining = Self.maximumFish
        value.fishCounts = [:]
        for id in fishCounts.keys.sorted() where (300...327).contains(id) {
            let count = min(remaining, max(0, min(3, fishCounts[id] ?? 0)))
            if count > 0 { value.fishCounts[id] = count; remaining -= count }
        }
        value.ambientVolume = ambientVolume.isFinite ? min(1, max(0, ambientVolume)) : 0.16
        value.moonJellyCount = min(5, max(0, moonJellyCount))
        return value
    }
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved.normalized()
    }
    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(normalized()) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A single policy governs both the display link and environmental sound.
struct AquariumActivity: Equatable {
    var presented = false
    var windowVisible = false
    var appHidden = false
    var systemAsleep = false
    var reducedMotion = false
    var canRun: Bool { presented && windowVisible && !appHidden && !systemAsleep }
    var animate: Bool { canRun && !reducedMotion }
}

struct AquariumSpecies: Decodable, Identifiable {
    let id: Int
    let name: String
}

enum AquariumResources {
    static var assets: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("AquariumAssets", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tank.json").path) ? $0 : nil }
    }
    static var shader: URL {
        get throws { try shader(in: .main) }
    }
    static func shader(in application: Bundle) throws -> URL {
        // SwiftPM's generated accessor checks beside the executable bundle and
        // then the developer's build directory, not Contents/Resources in an app.
        let packageName = "LittleEars_LittleEars.bundle"
        let locations = [application.resourceURL?.appendingPathComponent(packageName),
                         application.bundleURL.appendingPathComponent(packageName)]
        for location in locations.compactMap({ $0 }) {
            if let bundle = Bundle(url: location),
               let url = bundle.url(forResource: "Fish", withExtension: "metal", subdirectory: "Shaders") {
                return url
            }
        }
        if let url = application.url(forResource: "Fish", withExtension: "metal", subdirectory: "Shaders") {
            return url
        }
        #if SWIFT_PACKAGE
        // Only command-line builds/tests may use SwiftPM's build-directory fallback.
        if application.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "Fish", withExtension: "metal", subdirectory: "Shaders") {
            return url
        }
        #endif
        throw NSError(domain: "LittleEars.AquariumResources", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "缺少水族箱着色器资源，请重新安装完整应用。"])
    }
    static func catalog(at assets: URL) throws -> [AquariumSpecies] {
        try JSONDecoder().decode([AquariumSpecies].self, from: Data(contentsOf: assets.appendingPathComponent("fish-species.json")))
    }
}
