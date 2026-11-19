import SwiftUI
import XCTest
@testable import MiMundo

/// The Swift region shapes and the Rust core's layout table are two lists
/// that must agree. `core/tests/fixtures/flag-layout-regions.json` is the
/// shared record: this checks it against the shapes the app draws, and the
/// Rust test `layout_region_counts_match_the_swift_shapes` checks it against
/// the core. (Future work: move the geometry into Rust so there is one list.)
final class FlagLayoutTests: XCTestCase {
    func testEveryLayoutsRegionCountMatchesTheFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/tests/fixtures/flag-layout-regions.json")
        let counts = try JSONDecoder().decode([String: Int].self, from: try Data(contentsOf: fixture))
        XCTAssertFalse(counts.isEmpty)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        for (layout, expected) in counts {
            XCTAssertEqual(FlagLayoutShape.regions(layout, in: rect).count, expected, layout)
        }
    }
}
