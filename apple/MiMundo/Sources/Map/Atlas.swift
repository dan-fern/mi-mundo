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
}

/// One country, ready to draw: metadata from the Rust map plus pre-built
/// SwiftUI paths in map coordinates (Equal Earth, y grows south).
struct AtlasCountry: Identifiable, Sendable {
    let meta: CountryMeta
    let coarse: Path
    let fine: Path
    let facts: CountryFacts?

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

    private init(world: World, countries: [AtlasCountry], outline: Path, graticule: Path) {
        self.world = world
        self.countries = countries
        self.outline = outline
        self.graticule = graticule
        self.bounds = outline.boundingRect
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
                  let factsURL = Bundle.main.url(forResource: "Countries", withExtension: "json")
            else { throw CocoaError(.fileNoSuchFile) }
            let world = try World(bytes: try Data(contentsOf: mapURL))
            let facts = try JSONDecoder().decode(
                [String: CountryFacts].self, from: try Data(contentsOf: factsURL)
            )
            let coarse = world.shapes(detail: .coarse)
            let fine = world.shapes(detail: .fine)
            let countries = world.countries().map { meta in
                AtlasCountry(
                    meta: meta,
                    coarse: path(rings: coarse[Int(meta.index)].rings),
                    fine: path(rings: fine[Int(meta.index)].rings),
                    facts: facts[meta.iso2]
                )
            }
            let atlas = Atlas(
                world: world,
                countries: countries,
                outline: path(rings: [worldOutline()]),
                graticule: graticulePath()
            )
            mapLog.info("Atlas loaded: \(countries.count) countries in \(Date.now.timeIntervalSince(start), format: .fixed(precision: 2)) s")
            return atlas
        }.value
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
