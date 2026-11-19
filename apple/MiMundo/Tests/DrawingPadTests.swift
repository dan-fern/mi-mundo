import CoreGraphics
import XCTest
@testable import MiMundo

/// The drawing pad's paint bucket fills the area tapped, up to the lines
/// (beta feedback: it used to fill the whole canvas behind a line).
@MainActor
final class DrawingPadTests: XCTestCase {
    private let w = FlagFill.width, h = FlagFill.height

    /// A line straight down the middle, edge to edge.
    private var splitDownTheMiddle: FlagSketch {
        FlagSketch(strokes: [FlagStroke(color: "black", points: [CGPoint(x: 0.5, y: -0.1), CGPoint(x: 0.5, y: 1.1)])],
                   widths: [0.025])
    }

    private func share(_ fill: FlagFill, xs: Range<Double>) -> Double {
        let columns = Int(xs.lowerBound * Double(w))..<Int(xs.upperBound * Double(w))
        let covered = columns.reduce(0) { sum, x in sum + (0..<h).filter { fill.covers(x: x, y: $0) }.count }
        return Double(covered) / Double(columns.count * h)
    }

    func testFillStopsAtALineAcrossTheCanvas() throws {
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.25, y: 0.5), color: "blue",
                                               on: splitDownTheMiddle, guide: nil))
        XCTAssertGreaterThanOrEqual(share(fill, xs: 0.0..<0.45), 0.97, "the whole left side")
        XCTAssertLessThanOrEqual(share(fill, xs: 0.55..<1.0), 0.03, "nothing past the line")
    }

    func testFillOnAnEmptyCanvasCoversEverything() throws {
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.5, y: 0.5), color: "red", on: FlagSketch(), guide: nil))
        XCTAssertGreaterThanOrEqual(share(fill, xs: 0.0..<1.0), 0.97)
    }

    func testTheTracingOutlineStopsAFill() throws {
        // France's outline: three vertical bands.
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.15, y: 0.5), color: "blue", on: FlagSketch(), guide: "v3"))
        XCTAssertGreaterThanOrEqual(share(fill, xs: 0.0..<0.3), 0.97)
        XCTAssertLessThanOrEqual(share(fill, xs: 0.4..<1.0), 0.03)
        // Without the outline, the same tap fills it all.
        let open = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.15, y: 0.5), color: "blue", on: FlagSketch(), guide: nil))
        XCTAssertGreaterThanOrEqual(share(open, xs: 0.0..<1.0), 0.97)
    }

    func testAnEarlierFillOfAnotherColourStopsTheNext() throws {
        var sketch = splitDownTheMiddle
        sketch.fills.append(try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.25, y: 0.5), color: "blue", on: sketch, guide: nil)))
        let right = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.75, y: 0.5), color: "red", on: sketch, guide: nil))
        XCTAssertLessThanOrEqual(share(right, xs: 0.0..<0.45), 0.03)
        XCTAssertGreaterThanOrEqual(share(right, xs: 0.55..<1.0), 0.97)
    }

    func testAFillWithTheOutlineReachesTheOutlineLeavingNoSeam() throws {
        // Review: fills stopped two cells short of each guide line, which
        // left a white seam between stripes once the outline was hidden.
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.15, y: 0.5), color: "blue", on: FlagSketch(), guide: "v3"))
        XCTAssertGreaterThanOrEqual(share(fill, xs: 0.30..<0.333), 0.9, "right up to the line at a third")
        XCTAssertLessThanOrEqual(share(fill, xs: 0.36..<1.0), 0.03)
    }

    func testTappingTheOutlineFillsNothing() {
        // Review: a tap on the guide line used to fill the whole outline.
        let onTheLine = CGPoint(x: 1.0 / 3.0, y: 0.5)
        XCTAssertNil(FlagFill.make(at: onTheLine, color: "red", on: FlagSketch(), guide: "v3"))
    }

    func testALineTheSameColourAsTheAreaStillStopsAFill() throws {
        // A white line on the blank (white) canvas looks like nothing, but
        // it's a line the kid drew.
        let white = FlagSketch(strokes: [FlagStroke(color: "white", points: [CGPoint(x: 0.5, y: -0.1), CGPoint(x: 0.5, y: 1.1)])],
                               widths: [0.025])
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.25, y: 0.5), color: "red", on: white, guide: nil))
        XCTAssertLessThanOrEqual(share(fill, xs: 0.55..<1.0), 0.03)
    }

    func testACrossOutlineIsOneShapeWithoutABoxInTheMiddle() throws {
        // Review: the cross's two bars were stroked separately, so the guide
        // drew a box where they meet and a fill stopped at it.
        let fill = try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.4, y: 0.5), color: "white", on: FlagSketch(), guide: "cross"))
        let centre = (FlagFill.height / 2) * FlagFill.width + FlagFill.width / 2
        XCTAssertTrue(fill.covers(x: centre % FlagFill.width, y: centre / FlagFill.width), "the middle of the cross fills too")
    }

    func testTappingALineFillsNothing() {
        XCTAssertNil(FlagFill.make(at: CGPoint(x: 0.5, y: 0.5), color: "red", on: splitDownTheMiddle, guide: nil))
    }

    func testAFilledDrawingIsGradedByWhatItShows() throws {
        // Blue left, red right, white middle left blank: a France-ish flag.
        var sketch = FlagSketch(strokes: [
            FlagStroke(color: "black", points: [CGPoint(x: 0.333, y: -0.1), CGPoint(x: 0.333, y: 1.1)]),
            FlagStroke(color: "black", points: [CGPoint(x: 0.667, y: -0.1), CGPoint(x: 0.667, y: 1.1)]),
        ], widths: [0.01, 0.01])
        sketch.fills.append(try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.1, y: 0.5), color: "blue", on: sketch, guide: nil)))
        sketch.fills.append(try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.9, y: 0.5), color: "red", on: sketch, guide: nil)))
        let cells = FlagGrid.drawing(sketch)
        let blue = UInt8(FlagPaint.names.firstIndex(of: "blue")!)
        let red = UInt8(FlagPaint.names.firstIndex(of: "red")!)
        let row = FlagGrid.height / 2
        XCTAssertEqual(cells[row * FlagGrid.width + 2], blue)
        XCTAssertEqual(cells[row * FlagGrid.width + FlagGrid.width - 3], red)
        XCTAssertNotEqual(cells[row * FlagGrid.width + FlagGrid.width / 2], red, "the middle stays unfilled")
    }

    func testUndoTakesBackTheNewestStrokeOrFill() throws {
        var sketch = splitDownTheMiddle
        sketch.fills.append(try XCTUnwrap(FlagFill.make(at: CGPoint(x: 0.25, y: 0.5), color: "blue", on: sketch, guide: nil)))
        sketch.strokes.append(FlagStroke(color: "red", points: [CGPoint(x: 0.1, y: 0.1)]))
        sketch.widths.append(0.05)
        sketch.undo() // the dab, drawn after the fill
        XCTAssertEqual(sketch.strokes.count, 1)
        XCTAssertEqual(sketch.fills.count, 1)
        sketch.undo() // the fill
        XCTAssertTrue(sketch.fills.isEmpty)
        sketch.undo() // the line
        XCTAssertTrue(sketch.isEmpty)
    }

    func testOldDrawingsWithoutFillsStillDecode() throws {
        let json = #"{"background":"red","strokes":[],"widths":[]}"#
        let sketch = try JSONDecoder().decode(FlagSketch.self, from: Data(json.utf8))
        XCTAssertEqual(sketch.background, "red")
        XCTAssertTrue(sketch.fills.isEmpty)
        XCTAssertFalse(sketch.isEmpty)
    }
}
