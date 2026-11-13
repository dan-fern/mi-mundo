import Foundation
import MiMundoCore
import SwiftUI
import os

private let mapLog = Logger(subsystem: "com.danfern.mimundo", category: "map")

/// Facts shown on a country card (from Countries.json, built from Wikidata).
struct CountryFacts: Decodable, Sendable {
    let capitals: [String]
    let population: Int?
    let languages: [String]
    let landmarks: [Landmark]
    /// Where each capital is, in the same order as `capitals`.
    let capitalPoints: [Landmark]
    /// Governs itself and has residents: used by quiz presets ("all of
    /// Europe") so they aren't padded with small territories.
    let independent: Bool
    /// Quiz-sized part of the world ("Balkans", "Caribbean"), at most 14
    /// independent countries each (tools/build-countries.py REGIONS).
    let region: String

    struct Landmark: Decodable, Sendable, Hashable {
        let name: String
        let lon: Double
        let lat: Double
    }
}

/// A physical feature ready to draw (from Features.bin): rivers are open
/// polylines, lakes/deserts/ranges are filled rings, peaks are a point.
struct MapFeature: Sendable {
    /// Stable position in Features.bin (keeps label placement steady).
    let index: Int
    let kind: FeatureKind
    let name: String
    let minZoom: CGFloat
    let labelMinZoom: CGFloat
    let label: CGPoint
    let labelAngle: Angle
    let elevation: Int
    let path: Path
    let bounds: CGRect
    /// Rivers only: the course cut into short runs with their own bounds,
    /// so a zoomed-in view strokes only the bit of the Amazon on screen.
    let pieces: [(path: Path, bounds: CGRect)]
    /// Text drawn for the label (peaks add their height), built once.
    let labelText: String
    /// Quiz reveal rule: who owns the name, and which countries it names.
    var reveal = NameReveal()
}

/// A landmark pin on the map.
struct LandmarkPin: Sendable {
    let name: String
    let point: CGPoint
    /// Position in its country's own list (0 = most famous): pins are placed
    /// in this order so famous sites win label space, not alphabetical ones.
    let rank: Int
    let reveal: NameReveal
}

/// Which country a map name belongs to, for quiz reveals.
struct NameReveal: Sendable, Equatable {
    /// Country under the label (nil at sea, e.g. the Caspian).
    var owner: UInt32?
    /// Countries the name itself names: the Niger river, Lake Chad, the
    /// Panama Canal, Mount Kenya.
    var mentions: Set<UInt32> = []
}

/// Which names the map may show (requirements §3.2): everything while
/// exploring. In a quiz, a name shows once the country it sits in has been
/// guessed (names at sea show) and only if it doesn't name a target country
/// that hasn't been guessed yet. Feature shapes (rivers, lakes…) always draw.
enum MapLabelMode: Equatable, Sendable {
    case explore
    case quiz(targets: Set<UInt32>, revealed: Set<UInt32>)

    func shows(_ reveal: NameReveal) -> Bool {
        switch self {
        case .explore:
            return true
        case let .quiz(targets, revealed):
            if let owner = reveal.owner, !revealed.contains(owner) { return false }
            return reveal.mentions.isDisjoint(with: targets.subtracting(revealed))
        }
    }
}

/// Main-thread memory of which labels the map placed last frame, so they
/// are tried first next frame and don't flicker while panning.
final class LabelMemory: @unchecked Sendable {
    // Only touched by the map Canvas, which renders on the main thread.
    var placed: Set<String> = []
}

/// One country, ready to draw: metadata from the Rust map plus pre-built
/// SwiftUI paths in map coordinates (Equal Earth, y grows south).
struct AtlasCountry: Identifiable, Sendable {
    let meta: CountryMeta
    let coarse: Path
    let fine: Path
    let facts: CountryFacts?
    /// Capitals in map coordinates; starred when the country is selected.
    let capitals: [CGPoint]
    /// This country's famous places, most famous first; pinned on the map
    /// while the country is selected. A site shared with a neighbour
    /// (Victoria Falls) is in both countries' lists.
    var landmarks: [LandmarkPin] = []

    var id: UInt32 { meta.index }
    var name: String { meta.name }
    var bounds: CGRect {
        CGRect(
            x: CGFloat(meta.minX), y: CGFloat(meta.minY),
            width: CGFloat(meta.maxX - meta.minX), height: CGFloat(meta.maxY - meta.minY)
        )
    }
    /// Asset name in Flags.xcassets, if this country has a flag.
    var flagAsset: String? {
        meta.iso2 == "-99" ? nil : "flag-\(meta.iso2.lowercased())"
    }
}

/// The whole bundled world: loaded once, off the main thread, then shared.
final class Atlas: Sendable {
    let world: World
    let countries: [AtlasCountry]
    /// Edge of the projected world (the "map paper").
    let outline: Path
    /// Lines of latitude/longitude every 30°.
    let graticule: Path
    let bounds: CGRect
    /// Rivers, lakes, deserts, ranges and peaks, drawn as you zoom in.
    /// In label priority order (deserts and ranges, then water, then peaks;
    /// earlier-appearing first) so drawing never sorts per frame.
    let features: [MapFeature]
    /// Every landmark once, most famous first (each country's #1, then each
    /// #2, …). Quiz mode pins these on guessed countries; explore mode pins
    /// only the selected country's own list (`AtlasCountry.landmarks`).
    let landmarks: [LandmarkPin]
    let labelMemory = LabelMemory()

    private init(world: World, countries: [AtlasCountry], outline: Path, graticule: Path,
                 features: [MapFeature], landmarks: [LandmarkPin]) {
        self.world = world
        self.countries = countries
        self.outline = outline
        self.graticule = graticule
        self.bounds = outline.boundingRect
        self.features = features
        self.landmarks = landmarks
    }

    /// Country under a map point. `tolerance` (map units) lets a fingertip
    /// that just misses a tiny island still select it.
    func country(at point: CGPoint, tolerance: CGFloat) -> AtlasCountry? {
        world.countryAt(x: Float(point.x), y: Float(point.y), tolerance: Float(tolerance))
            .map { countries[Int($0)] }
    }

    static func load() async throws -> Atlas {
        try await Task.detached(priority: .userInitiated) {
            let start = Date.now
            guard let mapURL = Bundle.main.url(forResource: "World", withExtension: "bin"),
                  let factsURL = Bundle.main.url(forResource: "Countries", withExtension: "json"),
                  let featuresURL = Bundle.main.url(forResource: "Features", withExtension: "bin")
            else { throw CocoaError(.fileNoSuchFile) }
            let world = try World(bytes: try Data(contentsOf: mapURL))
            let facts = try JSONDecoder().decode(
                [String: CountryFacts].self, from: try Data(contentsOf: factsURL)
            )
            let coarse = world.shapes(detail: .coarse)
            let fine = world.shapes(detail: .fine)
            let countries = world.countries().map { meta in
                let countryFacts = facts[meta.iso2]
                return AtlasCountry(
                    meta: meta,
                    coarse: path(rings: coarse[Int(meta.index)].rings),
                    fine: path(rings: fine[Int(meta.index)].rings),
                    facts: countryFacts,
                    capitals: (countryFacts?.capitalPoints ?? []).map {
                        let p = project(lonDeg: $0.lon, latDeg: $0.lat)
                        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                    }
                )
            }
            let mentions = MentionIndex(countries: countries)
            // Each feature belongs to the country under its label (for
            // quiz-mode reveals); a little tolerance catches coastal labels.
            let features = try loadFeatures(bytes: try Data(contentsOf: featuresURL)).enumerated()
                .map { i, f in
                    var feature = mapFeature(f, index: i)
                    feature.reveal = NameReveal(
                        owner: world.countryAt(x: f.labelX, y: f.labelY, tolerance: 0.01),
                        mentions: mentions.countries(named: f.name)
                    )
                    return feature
                }
                .sorted { ($0.kind.labelPriority, $0.labelMinZoom, $0.index)
                    < ($1.kind.labelPriority, $1.labelMinZoom, $1.index) }
            let countryOfISO = Dictionary(
                countries.map { ($0.meta.iso2, $0.meta.index) }, uniquingKeysWith: { first, _ in first }
            )
            var seen = Set<String>()
            let landmarks = facts.keys.sorted().flatMap { iso2 in
                facts[iso2]!.landmarks.enumerated().map { (iso2, $0.offset, $0.element) }
            }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) } // every #1 first, then #2…
            .filter { seen.insert($0.2.name).inserted } // cross-border sites once
            .map { iso2, rank, lm in
                let p = project(lonDeg: lm.lon, latDeg: lm.lat)
                return LandmarkPin(name: lm.name, point: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                                   rank: rank,
                                   reveal: NameReveal(owner: countryOfISO[iso2],
                                                      mentions: mentions.countries(named: lm.name)))
            }
            let pinnedCountries = countries.map { country in
                var country = country
                country.landmarks = (country.facts?.landmarks ?? []).enumerated().map { rank, lm in
                    let p = project(lonDeg: lm.lon, latDeg: lm.lat)
                    return LandmarkPin(name: lm.name, point: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                                       rank: rank,
                                       reveal: NameReveal(owner: country.id,
                                                          mentions: mentions.countries(named: lm.name)))
                }
                return country
            }
            let atlas = Atlas(
                world: world,
                countries: pinnedCountries,
                outline: path(rings: [worldOutline()]),
                graticule: graticulePath(),
                features: features,
                landmarks: landmarks
            )
            mapLog.info("Atlas loaded: \(countries.count) countries in \(Date.now.timeIntervalSince(start), format: .fixed(precision: 2)) s")
            return atlas
        }.value
    }

    private static func mapFeature(_ f: PhysicalFeature, index: Int) -> MapFeature {
        let path: Path
        switch f.kind {
        case .river: path = Self.path(lines: f.parts)
        case .peak: path = Path()
        case .lake, .desert, .range: path = Self.path(rings: f.parts)
        }
        let label = CGPoint(x: CGFloat(f.labelX), y: CGFloat(f.labelY))
        let labelText = switch f.kind {
        case .peak: "\(f.name)\n\(Int(f.elevationM).formatted()) m"
        case .desert: f.name.uppercased()
        default: f.name
        }
        return MapFeature(
            index: index, kind: f.kind, name: f.name,
            minZoom: CGFloat(f.minZoom), labelMinZoom: CGFloat(f.labelMinZoom),
            label: label, labelAngle: .radians(Double(f.labelAngle)),
            elevation: Int(f.elevationM), path: path,
            bounds: f.kind == .peak ? CGRect(origin: label, size: .zero) : path.boundingRect,
            pieces: f.kind == .river ? riverPieces(f.parts) : [],
            labelText: labelText
        )
    }

    /// A river's lines cut into runs of up to 32 points (sharing end points so
    /// the stroke stays joined), each with its own bounds for culling.
    private static func riverPieces(_ lines: [[Float]]) -> [(path: Path, bounds: CGRect)] {
        var pieces: [(path: Path, bounds: CGRect)] = []
        for line in lines where line.count >= 4 {
            let points = stride(from: 0, to: line.count - 1, by: 2).map {
                CGPoint(x: CGFloat(line[$0]), y: CGFloat(line[$0 + 1]))
            }
            var start = 0
            while start < points.count - 1 {
                let end = min(start + 32, points.count - 1)
                var path = Path()
                path.addLines(Array(points[start...end]))
                pieces.append((path, path.boundingRect))
                start = end
            }
        }
        return pieces
    }

    private static func path(lines: [[Float]]) -> Path {
        var path = Path()
        for line in lines where line.count >= 4 {
            path.move(to: CGPoint(x: CGFloat(line[0]), y: CGFloat(line[1])))
            var i = 2
            while i + 1 < line.count {
                path.addLine(to: CGPoint(x: CGFloat(line[i]), y: CGFloat(line[i + 1])))
                i += 2
            }
        }
        return path
    }

    private static func path(rings: [[Float]]) -> Path {
        var path = Path()
        for ring in rings where ring.count >= 6 {
            path.move(to: CGPoint(x: CGFloat(ring[0]), y: CGFloat(ring[1])))
            var i = 2
            while i + 1 < ring.count {
                path.addLine(to: CGPoint(x: CGFloat(ring[i]), y: CGFloat(ring[i + 1])))
                i += 2
            }
            path.closeSubpath()
        }
        return path
    }

    private static func graticulePath() -> Path {
        var path = Path()
        func point(_ lon: Double, _ lat: Double) -> CGPoint {
            let p = project(lonDeg: lon, latDeg: lat)
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        for lon in stride(from: -150.0, through: 150.0, by: 30.0) {
            path.move(to: point(lon, 90))
            for lat in stride(from: 88.0, through: -90.0, by: -2.0) { path.addLine(to: point(lon, lat)) }
        }
        for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
            path.move(to: point(-180, lat))
            path.addLine(to: point(180, lat))
        }
        return path
    }
}

extension FeatureKind {
    /// Label placement order: big areas, then water, then peaks.
    var labelPriority: Int {
        switch self {
        case .desert: 0
        case .range: 1
        case .lake: 2
        case .river: 3
        case .peak: 4
        }
    }
}

/// Finds the countries a place name mentions ("Lake Chad" → Chad, "Congo" →
/// both Congos), so quiz mode can hold such names back until those
/// countries are guessed. Matches whole words, case-insensitively, against
/// each country's name and the part after "of the" / "of" (the Congo in
/// "Democratic Republic of the Congo").
struct MentionIndex {
    private var cores: [(words: [Substring], country: UInt32)] = []

    init(countries: [AtlasCountry]) {
        for c in countries {
            let name = c.name.lowercased()
            var forms = [name]
            for marker in [" of the ", " of "] {
                if let r = name.range(of: marker, options: .backwards) {
                    forms.append(String(name[r.upperBound...]))
                    break
                }
            }
            for form in Set(forms) {
                let words = Self.words(form)
                if !words.isEmpty { cores.append((words, c.id)) }
            }
        }
    }

    func countries(named place: String) -> Set<UInt32> {
        let words = Self.words(place.lowercased())
        var found = Set<UInt32>()
        for core in cores where core.words.count <= words.count {
            for start in 0...(words.count - core.words.count)
                where Array(words[start..<(start + core.words.count)]) == core.words {
                found.insert(core.country)
                break
            }
        }
        return found
    }

    private static func words(_ text: String) -> [Substring] {
        text.split { !$0.isLetter }
    }
}

/// Loads the atlas once for the whole app.
@MainActor
@Observable
final class AtlasStore {
    private(set) var atlas: Atlas?
    private(set) var failed = false

    func loadIfNeeded() async {
        guard atlas == nil, !failed else { return }
        do {
            atlas = try await Atlas.load()
        } catch {
            mapLog.error("Atlas failed to load: \(error, privacy: .public)")
            failed = true
        }
    }
}
