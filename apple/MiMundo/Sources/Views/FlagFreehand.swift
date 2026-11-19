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

/// What the kid drew: fills and strokes, in fractions of the canvas so it
/// draws the same at any size. Fills sit behind every stroke (a stroke
/// drawn later goes over a fill; a fill never covers a line).
struct FlagSketch: Equatable, Codable {
    /// A whole-canvas colour: only in drawings from before fills were
    /// bounded by lines (the old "fill background" bucket).
    var background: String?
    var strokes: [FlagStroke] = []
    /// Stroke width per stroke, as a fraction of the canvas width.
    var widths: [CGFloat] = []
    var fills: [FlagFill] = []

    init(background: String? = nil, strokes: [FlagStroke] = [], widths: [CGFloat] = [], fills: [FlagFill] = []) {
        self.background = background
        self.strokes = strokes
        self.widths = widths
        self.fills = fills
    }

    // Older saved drawings have no `fills`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        strokes = try c.decodeIfPresent([FlagStroke].self, forKey: .strokes) ?? []
        widths = try c.decodeIfPresent([CGFloat].self, forKey: .widths) ?? []
        fills = try c.decodeIfPresent([FlagFill].self, forKey: .fills) ?? []
    }

    var isEmpty: Bool { background == nil && strokes.isEmpty && fills.isEmpty }

    /// Undo: the most recent stroke or fill (a fill made after all the
    /// current strokes is the newest).
    mutating func undo() {
        if let fill = fills.last, fill.after >= strokes.count {
            fills.removeLast()
        } else if !strokes.isEmpty {
            strokes.removeLast()
            if !widths.isEmpty { widths.removeLast() }
        } else {
            background = nil
        }
    }

    func render(in ctx: CGContext, size: CGSize, strokesOnly: Bool = false) {
        let canvas = CGRect(origin: .zero, size: size)
        if !strokesOnly {
            if let background {
                ctx.setFillColor(UIColor(FlagPaint.color(background)).cgColor)
                ctx.fill(canvas)
            }
            for fill in fills {
                fill.render(in: ctx, rect: canvas)
            }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (i, stroke) in strokes.enumerated() {
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first else { continue }
            let color = strokesOnly ? UIColor.black.cgColor : UIColor(FlagPaint.color(stroke.color)).cgColor
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
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

/// A paint-bucket fill: the area around where the kid tapped, up to the
/// lines (and the tracing outline, if it was showing), worked out once on
/// a small grid and kept as a mask so it draws the same every time.
struct FlagFill: Equatable, Codable {
    static let width = 192
    static let height = 144

    var color: String
    /// One bit per cell of the `width`×`height` grid, row by row from the top.
    var mask: Data
    /// How many strokes there were when it was made (for undo order).
    var after: Int

    func covers(x: Int, y: Int) -> Bool {
        let i = y * Self.width + x
        return mask.count > i / 8 && mask[i / 8] & (1 << UInt8(i % 8)) != 0
    }

    func render(in ctx: CGContext, rect: CGRect) {
        guard let image = maskImage() else { return }
        ctx.saveGState()
        // Images draw bottom-up; the sketch's coordinates run top-down.
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(UIColor(FlagPaint.color(color)).cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// Mask pictures, made once per fill rather than on every redraw (the
    /// pad redraws on every touch while drawing). NSCache is thread-safe.
    nonisolated(unsafe) private static let images = NSCache<NSData, CGImage>()

    private func maskImage() -> CGImage? {
        let key = mask as NSData
        if let cached = Self.images.object(forKey: key) { return cached }
        guard let image = makeMaskImage() else { return nil }
        Self.images.setObject(image, forKey: key)
        return image
    }

    private func makeMaskImage() -> CGImage? {
        var gray = [UInt8](repeating: 0, count: Self.width * Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width where covers(x: x, y: y) { gray[y * Self.width + x] = 255 }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The fill for a tap at `point` (fractions of the canvas): every grid
    /// cell joined to it (sideways or up and down) that looks the same as
    /// it does, so lines and other colours stop it. With `guide`, the
    /// tracing outline's lines stop it too. Nil on a line.
    static func make(at point: CGPoint, color: String, on sketch: FlagSketch, guide: String?) -> FlagFill? {
        let (w, h) = (width, height)
        let size = CGSize(width: w, height: h)
        // What's there now, without smoothing so every cell is one colour.
        let seen = pixels(size: size) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            sketch.render(in: ctx, size: size)
        }
        // Where the strokes are, and the tracing outline's lines: both stop
        // a fill (whatever their colour), and the fill reaches one cell under
        // them, so its edge sits on the line instead of leaving a gap.
        let lines = pixels(size: size) { ctx in sketch.render(in: ctx, size: size, strokesOnly: true) }
        let guideLines = guide.map { layout in
            pixels(size: size) { ctx in
                ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.setLineWidth(2)
                for path in FlagLayoutShape.guide(layout, in: CGRect(origin: .zero, size: size)) {
                    ctx.addPath(path.cgPath)
                    ctx.strokePath()
                }
            }
        } ?? [UInt32](repeating: 0, count: w * h)
        guard !seen.isEmpty, lines.count == w * h, guideLines.count == w * h else { return nil }
        let wall = { (i: Int) in lines[i] != 0 || guideLines[i] != 0 }
        let sx = min(max(Int(point.x * CGFloat(w)), 0), w - 1)
        let sy = min(max(Int(point.y * CGFloat(h)), 0), h - 1)
        let start = sy * w + sx
        let target = seen[start]
        guard !wall(start) else { return nil } // tapped a line or the outline
        var inside = [Bool](repeating: false, count: w * h)
        var stack = [start]
        inside[start] = true
        while let i = stack.popLast() {
            let (x, y) = (i % w, i / w)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if !inside[j], !wall(j), seen[j] == target {
                    inside[j] = true
                    stack.append(j)
                }
            }
        }
        var grown = inside
        for i in 0..<(w * h) where inside[i] {
            let (x, y) = (i % w, i / w)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h && wall(ny * w + nx) {
                grown[ny * w + nx] = true
            }
        }
        var bits = Data(repeating: 0, count: (w * h + 7) / 8)
        for i in 0..<(w * h) where grown[i] { bits[i / 8] |= 1 << UInt8(i % 8) }
        return FlagFill(color: color, mask: bits, after: sketch.strokes.count)
    }

    /// Renders into a small RGBA grid (top-left origin, no smoothing) and
    /// returns one value per cell (0 where nothing was drawn).
    private static func pixels(size: CGSize, draw: (CGContext) -> Void) -> [UInt32] {
        let (w, h) = (Int(size.width), Int(size.height))
        var out = [UInt32](repeating: 0, count: w * h)
        let made: Bool = out.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(false)
            ctx.interpolationQuality = .none
            draw(ctx)
            return true
        }
        return made ? out : []
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
/// draw or fill, an optional tracing outline, undo and clear. Everything a
/// kid taps is big (beta feedback: the tools were hard to hit).
struct FreehandPad: View {
    let country: AtlasCountry
    let spec: FlagOutlineSpec?
    /// Saves the drawing as the answer; false if it couldn't be saved (the
    /// pad stays open with the drawing, to try again).
    let onCheck: (FreehandResult) -> Bool
    let onCancel: () -> Void

    @State private var sketch = FlagSketch()
    @State private var brush = "red"
    @State private var width: CGFloat = 0.08
    @State private var filling = false
    @State private var showOutline = false
    /// The stroke the finger is drawing, by index. Cleared when the touch
    /// ends or is cancelled, and by undo and clear (a second finger can tap
    /// them mid-stroke).
    @State private var currentStroke: Int?
    @GestureState private var touching = false
    @State private var checking = false
    @State private var confirmingClear = false
    @State private var saveFailed = false
    @State private var confirmingLeave = false

    private static let sizes: [(name: String, width: CGFloat)] = [("Thin", 0.025), ("Medium", 0.08), ("Big", 0.16)]
    private static let toolSize: CGFloat = 64
    private static let toolsWidth: CGFloat = 3 * 64 + 2 * 10

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Back") {
                    if sketch.isEmpty { onCancel() } else { confirmingLeave = true }
                }
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
            if saveFailed {
                Text("That didn't save. Your drawing is still here: please check it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(Color(uiColor: .systemGroupedBackground))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // A stray tap mustn't throw a drawing away.
        .confirmationDialog("Leave without checking your flag?", isPresented: $confirmingLeave,
                            titleVisibility: .visible) {
            Button("Leave", role: .destructive, action: onCancel)
            Button("Keep drawing", role: .cancel) {}
        } message: {
            Text("Your drawing will be lost.")
        }
        .confirmationDialog("Clear your drawing?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                currentStroke = nil
                sketch = FlagSketch()
            }
            Button("Keep it", role: .cancel) {}
        }
        .onChange(of: touching) { _, now in
            if !now { currentStroke = nil }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            FlagSketchView(sketch: sketch)
                .overlay {
                    if showOutline, let spec {
                        OutlineGuide(layout: spec.layout)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { drag in
                        guard !filling else { return }
                        let p = point(drag.location, in: size)
                        if let i = currentStroke, sketch.strokes.indices.contains(i) {
                            sketch.strokes[i].points.append(p)
                        } else {
                            sketch.strokes.append(FlagStroke(color: brush, points: [p]))
                            sketch.widths.append(width)
                            currentStroke = sketch.strokes.count - 1
                        }
                    }
                    .onEnded { drag in
                        currentStroke = nil
                        if filling, let fill = FlagFill.make(at: point(drag.location, in: size), color: brush,
                                                             on: sketch, guide: showOutline ? spec?.layout : nil) {
                            sketch.fills.append(fill)
                        }
                    })
                .accessibilityElement()
                .accessibilityLabel("Drawing canvas")
                .accessibilityAddTraits(.allowsDirectInteraction)
                .accessibilityHint(filling ? "Tap an area to fill it" : "Draw the flag with your finger or Apple Pencil")
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }

    private func point(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / max(size.width, 1), 0), 1),
                y: min(max(location.y / max(size.height, 1), 0), 1))
    }

    private var tools: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.toolSize), spacing: 10), count: 3), spacing: 10) {
                    ForEach(FlagPaint.names, id: \.self) { name in
                        Button {
                            brush = name
                        } label: {
                            Circle()
                                .fill(FlagPaint.color(name))
                                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: brush == name ? 5 : 0).padding(-6))
                                .frame(width: 52, height: 52)
                                .frame(width: Self.toolSize, height: Self.toolSize)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(FlagPaint.spoken(name))
                        .accessibilityAddTraits(brush == name ? .isSelected : [])
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Self.sizes, id: \.width) { size in
                        let on = width == size.width && !filling
                        Button {
                            width = size.width
                            filling = false
                        } label: {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 8 + size.width * 140, height: 8 + size.width * 140)
                                .frame(width: Self.toolSize, height: Self.toolSize)
                                .background(on ? Color.accentColor.opacity(0.2) : Color(uiColor: .secondarySystemGroupedBackground),
                                            in: .rect(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: on ? 3 : 0))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(size.name) brush")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                HStack(spacing: 10) {
                    ToolButton(title: filling ? "Fill: on" : "Fill", symbol: filling ? "drop.circle.fill" : "drop.fill",
                               on: filling) { filling.toggle() }
                        .accessibilityHint("Then tap an area of the flag to fill it with the colour")
                    ToolButton(title: "Undo", symbol: "arrow.uturn.backward") {
                        currentStroke = nil
                        sketch.undo()
                    }
                        .disabled(sketch.isEmpty)
                }
                HStack(spacing: 10) {
                    if spec != nil {
                        ToolButton(title: showOutline ? "Hide outline" : "Add outline", symbol: "square.dashed",
                                   on: showOutline) { showOutline.toggle() }
                            .accessibilityHint("Shows the flag's shapes as lines to trace and fill")
                    }
                    ToolButton(title: "Clear", symbol: "trash", role: .destructive) { confirmingClear = true }
                        .disabled(sketch.isEmpty)
                }
                if spec?.emblem == true {
                    Text("Emblems and small details are just for fun: they're not marked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: Self.toolsWidth)
    }

    private func check() {
        guard let asset = country.flagAsset else { return }
        checking = true
        var grade = gradeFreehand(reference: Data(FlagGrid.reference(asset: asset)),
                                  drawing: Data(FlagGrid.drawing(sketch)),
                                  outline: Data(FlagGrid.outline(spec)),
                                  width: UInt32(FlagGrid.width), height: UInt32(FlagGrid.height))
        // Some flags' mirror image is another country's flag (Ireland and
        // Côte d'Ivoire): that's a mix-up, not "so close", so only the
        // right-colours half.
        if grade.credit == .mirrored, !mirrorCreditAllowed(iso2: country.meta.iso2) {
            grade.credit = .colours
        }
        if !onCheck(FreehandResult(sketch: sketch, grade: grade)) {
            checking = false
            saveFailed = true
        }
    }
}

/// A big labelled tool button for the drawing pad.
private struct ToolButton: View {
    let title: String
    let symbol: String
    var on = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.callout.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(on ? .orange : nil)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The flag's shapes as dashed lines over the canvas: a tracing guide. Not
/// part of the drawing (it isn't graded), but fills stop at its lines.
private struct OutlineGuide: View {
    let layout: String

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                ForEach(Array(FlagLayoutShape.guide(layout, in: rect).enumerated()), id: \.offset) { _, path in
                    path.stroke(Color.gray.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The question card's part for a flag drawing: start drawing, or the help
/// (pick from four, half points), and afterwards the drawing beside the
/// real flag.
struct FreehandPanel: View {
    let country: AtlasCountry
    let result: FreehandResult?
    let onStart: () -> Void
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
            VStack(spacing: 12) {
                Button(action: onStart) {
                    Label("Start drawing", systemImage: "pencil.and.scribble")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                Button(action: onUseChoices) {
                    VStack(spacing: 2) {
                        Label("Pick it from four instead", systemImage: "square.grid.2x2")
                            .font(.title3.bold())
                        Text("half points")
                            .font(.footnote)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .accessibilityLabel("Pick it from four instead, half points")
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
