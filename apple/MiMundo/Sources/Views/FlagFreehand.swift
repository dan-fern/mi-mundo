import MiMundoCore
import SwiftUI
import UIKit

/// Freehand flag drawing (requirements §3.3, step 3): the kid draws the
/// whole flag on a blank canvas. Grading is the Rust core's
/// `grade_freehand`: both the real flag and the drawing are shrunk to the
/// same small grid and compared colour by colour, skipping emblems and small
/// details, with some slack on placement.
enum FlagGrid {
    static let width = 48
    static let height = 36
    static var size: CGSize { CGSize(width: width, height: height) }

    /// Draws into a small RGBA bitmap and names each pixel's paint colour.
    static func classify(_ draw: (CGContext, CGSize) -> Void) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let made: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // UIKit-style coordinates: origin top left.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            UIGraphicsPushContext(ctx)
            draw(ctx, size)
            UIGraphicsPopContext()
            return true
        }
        return made ? [UInt8](classifyPixels(rgba: Data(bytes))) : []
    }

    /// The real flag, classified.
    static func reference(asset: String) -> [UInt8] {
        guard let image = UIImage(named: asset) else { return [] }
        return classify { _, size in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// The flag's plain outline (no emblem), classified: where the real
    /// flag differs from it is detail the grader skips.
    static func outline(_ spec: FlagOutlineSpec?) -> [UInt8] {
        guard let spec else { return [] }
        return classify { ctx, size in
            let paths = FlagLayoutShape.regions(spec.layout, in: CGRect(origin: .zero, size: size))
            for (i, path) in paths.enumerated() where i < spec.colors.count {
                ctx.addPath(path.cgPath)
                ctx.setFillColor(UIColor(FlagPaint.color(spec.colors[i])).cgColor)
                ctx.fillPath()
            }
        }
    }

    /// A drawing, classified; untouched canvas stays blank.
    static func drawing(_ sketch: FlagSketch) -> [UInt8] {
        classify { ctx, size in sketch.render(in: ctx, size: size) }
    }
}

/// What the kid drew: an optional background colour and strokes, all in
/// fractions of the canvas so it draws the same at any size.
struct FlagSketch: Equatable {
    var background: String?
    var strokes: [FlagStroke] = []
    /// Stroke width per stroke, as a fraction of the canvas width.
    var widths: [CGFloat] = []

    var isEmpty: Bool { background == nil && strokes.isEmpty }

    func render(in ctx: CGContext, size: CGSize) {
        if let background {
            ctx.setFillColor(UIColor(FlagPaint.color(background)).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (i, stroke) in strokes.enumerated() {
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first else { continue }
            ctx.setStrokeColor(UIColor(FlagPaint.color(stroke.color)).cgColor)
            ctx.setFillColor(UIColor(FlagPaint.color(stroke.color)).cgColor)
            let width = (i < widths.count ? widths[i] : 0.05) * size.width
            if points.count == 1 {
                // A dab.
                ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                continue
            }
            ctx.setLineWidth(width)
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.strokePath()
        }
    }
}

/// Shows a sketch on a white card.
struct FlagSketchView: View {
    let sketch: FlagSketch

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            context.withCGContext { ctx in sketch.render(in: ctx, size: size) }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.3), lineWidth: 1))
    }
}

/// A graded freehand drawing.
struct FreehandResult: Equatable {
    let sketch: FlagSketch
    let grade: FreehandGrade
}

/// The full-screen drawing pad: a big canvas, the paint box, brush sizes,
/// a bucket for the background, undo and clear.
struct FreehandPad: View {
    let country: AtlasCountry
    let spec: FlagOutlineSpec?
    let onCheck: (FreehandResult) -> Void
    let onCancel: () -> Void

    @State private var sketch = FlagSketch()
    @State private var brush = "red"
    @State private var width: CGFloat = 0.08
    @State private var bucket = false
    @State private var drawingStroke = false
    @State private var checking = false

    private static let sizes: [(String, CGFloat)] = [("Thin", 0.025), ("Medium", 0.08), ("Big", 0.16)]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Back", action: onCancel)
                    .font(.title3)
                Spacer()
                Text("Draw the flag of \(country.name)!")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Back", action: onCancel).font(.title3).hidden()
            }
            HStack(alignment: .top, spacing: 18) {
                canvas
                tools
            }
            .frame(maxHeight: .infinity)
            Button {
                check()
            } label: {
                Text(sketch.isEmpty ? "Draw something first" : "Check my flag")
                    .font(.title3.bold())
                    .frame(maxWidth: 420, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(sketch.isEmpty || checking)
        }
        .padding(24)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            FlagSketchView(sketch: sketch)
                .frame(width: size.width, height: size.height)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !bucket else { return }
                        let p = CGPoint(x: min(max(drag.location.x / max(size.width, 1), 0), 1),
                                        y: min(max(drag.location.y / max(size.height, 1), 0), 1))
                        if drawingStroke {
                            sketch.strokes[sketch.strokes.count - 1].points.append(p)
                        } else {
                            sketch.strokes.append(FlagStroke(color: brush, points: [p]))
                            sketch.widths.append(width)
                            drawingStroke = true
                        }
                    }
                    .onEnded { _ in
                        drawingStroke = false
                        if bucket {
                            sketch.background = brush
                            bucket = false
                        }
                    })
                .accessibilityElement()
                .accessibilityLabel("Drawing canvas")
                .accessibilityHint("Draw the flag with your finger or Apple Pencil")
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 3), spacing: 8) {
                ForEach(FlagPaint.names, id: \.self) { name in
                    Button {
                        brush = name
                    } label: {
                        Circle()
                            .fill(FlagPaint.color(name))
                            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: brush == name ? 4 : 0).padding(-5))
                            .frame(width: 40, height: 40)
                            .frame(width: 48, height: 48)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(FlagPaint.spoken(name))
                    .accessibilityAddTraits(brush == name ? .isSelected : [])
                }
            }
            Picker("Brush", selection: $width) {
                ForEach(Self.sizes, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Button {
                bucket.toggle()
            } label: {
                Label(bucket ? "Tap the flag" : "Fill background", systemImage: "drop.fill")
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(bucket ? .orange : nil)
            HStack {
                Button {
                    if !sketch.strokes.isEmpty {
                        sketch.strokes.removeLast()
                        sketch.widths.removeLast()
                    } else {
                        sketch.background = nil
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    sketch = FlagSketch()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .font(.title3)
            if spec?.emblem == true {
                Text("Emblems and small details are just for fun: they're not marked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 168)
    }

    private func check() {
        guard let asset = country.flagAsset else { return }
        checking = true
        let grade = gradeFreehand(reference: Data(FlagGrid.reference(asset: asset)),
                                  drawing: Data(FlagGrid.drawing(sketch)),
                                  outline: Data(FlagGrid.outline(spec)),
                                  width: UInt32(FlagGrid.width), height: UInt32(FlagGrid.height))
        onCheck(FreehandResult(sketch: sketch, grade: grade))
    }
}

/// The question card's part for freehand: start drawing, the help ladder,
/// and afterwards the drawing beside the real flag.
struct FreehandPanel: View {
    let country: AtlasCountry
    let result: FreehandResult?
    /// Whether the outline help exists for this flag.
    let hasOutline: Bool
    let onStart: () -> Void
    let onUseOutline: () -> Void
    let onUseChoices: () -> Void

    var body: some View {
        if let result {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    FlagSketchView(sketch: result.sketch)
                    Text("Yours").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your drawing")
                if let asset = country.flagAsset {
                    VStack(spacing: 4) {
                        Image(asset)
                            .resizable()
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.3)))
                        Text(country.name).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("The flag of \(country.name)")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onStart) {
                    Label("Start drawing", systemImage: "pencil.and.scribble")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                if hasOutline {
                    Button(action: onUseOutline) {
                        Label("Use an outline (still full points)", systemImage: "square.split.2x1")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
                Button(action: onUseChoices) {
                    Label("Pick it from four instead (half points)", systemImage: "square.grid.2x2")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

#if DEBUG
/// Debug check of the freehand grader against every flag picture: launch
/// with `-flagSelfCheck` and read the console. For every flag, a copy of
/// the real flag must pass and a blank canvas must fail; for every flag
/// with an outline, the plain outline (no emblem) must pass, because
/// emblems are never graded.
enum FreehandSelfCheck {
    static func run() {
        guard CommandLine.arguments.contains("-flagSelfCheck") else { return }
        let codes = UIImage.flagCodes
        var failures: [String] = []
        let size = (UInt32(FlagGrid.width), UInt32(FlagGrid.height))
        for code in codes {
            let reference = FlagGrid.reference(asset: "flag-\(code)")
            guard !reference.isEmpty else { continue }
            let spec = FlagOutlines.spec(code: code)
            let outline = FlagGrid.outline(spec)
            let copy = gradeFreehand(reference: Data(reference), drawing: Data(reference),
                                     outline: Data(outline), width: size.0, height: size.1)
            if !copy.correct { failures.append("\(code) copy \(copy.scorePercent)% \(copy.missingColours)") }
            let blank = gradeFreehand(reference: Data(reference), drawing: Data([UInt8](repeating: 255, count: reference.count)),
                                      outline: Data(outline), width: size.0, height: size.1)
            if blank.correct { failures.append("\(code) blank passed") }
            if spec != nil {
                let plain = gradeFreehand(reference: Data(reference), drawing: Data(outline),
                                          outline: Data(outline), width: size.0, height: size.1)
                if !plain.correct { failures.append("\(code) outline \(plain.scorePercent)% \(plain.missingColours)") }
            }
        }
        // Drawing another country's flag should almost never pass.
        let refs = Dictionary(uniqueKeysWithValues: codes.map { ($0, FlagGrid.reference(asset: "flag-\($0)")) })
        var wrongPasses: [String] = []
        for a in codes {
            let outline = FlagGrid.outline(FlagOutlines.spec(code: a))
            for b in codes where b != a {
                let g = gradeFreehand(reference: Data(refs[a]!), drawing: Data(refs[b]!), outline: Data(outline),
                                      width: size.0, height: size.1)
                if g.correct { wrongPasses.append("\(b)→\(a)") }
            }
        }
        print("FLAG SELF CHECK: other flags passing: \(wrongPasses.count) of \(codes.count * (codes.count - 1))")
        print("FLAG SELF CHECK: \(wrongPasses.joined(separator: " "))")
        print("FLAG SELF CHECK: \(codes.count) flags, \(failures.count) failures")
        failures.forEach { print("FLAG SELF CHECK: \($0)") }
    }
}

extension UIImage {
    /// Two-letter codes with a flag picture.
    static var flagCodes: [String] {
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        return letters.flatMap { a in letters.map { a + $0 } }.filter { UIImage(named: "flag-\($0)") != nil }
    }
}
#endif
