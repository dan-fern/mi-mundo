import MiMundoCore
import SwiftUI

/// A flag described as a layout and region colours (requirements §3.3),
/// from FlagLayouts.json (written by tools/check-flag-layouts.py, checked
/// against the flag pictures).
struct FlagOutlineSpec: Decodable, Equatable {
    let layout: String
    let colors: [String]
    /// The flag has an emblem, stars or other detail beyond its regions.
    /// The kid may draw it; it's never graded.
    let emblem: Bool
}

enum FlagOutlines {
    private static let all: [String: FlagOutlineSpec] = {
        guard let url = Bundle.main.url(forResource: "FlagLayouts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: FlagOutlineSpec].self, from: data)
        else { return [:] }
        return decoded
    }()

    /// The country's flag as an outline, if it can be drawn as one.
    static func spec(for country: AtlasCountry) -> FlagOutlineSpec? {
        guard country.hasFlag else { return nil }
        return all[country.meta.iso2.lowercased()]
    }

    /// By flag code ("fr").
    static func spec(code: String) -> FlagOutlineSpec? { all[code] }

    /// What's recorded as a drawn flag's answer: "v3:blue,white,red".
    static func summary(layout: String, colors: [String]) -> String {
        "\(layout):\(colors.joined(separator: ","))"
    }
}

/// The paint box (core `flag_palette`), as flag colours.
enum FlagPaint {
    static let names: [String] = flagPalette()

    static func color(_ name: String) -> Color {
        switch name {
        case "red": Color(red: 0.81, green: 0.07, blue: 0.15)
        case "maroon": Color(red: 0.54, green: 0.09, blue: 0.22)
        case "orange": Color(red: 1.0, green: 0.51, blue: 0.0)
        case "yellow": Color(red: 0.99, green: 0.82, blue: 0.09)
        case "green": Color(red: 0.0, green: 0.55, blue: 0.27)
        case "lightblue": Color(red: 0.42, green: 0.71, blue: 0.91)
        case "blue": Color(red: 0.0, green: 0.22, blue: 0.58)
        case "white": .white
        case "black": .black
        default: Color(white: 0.92)
        }
    }

    /// Said by VoiceOver and read aloud.
    static func spoken(_ name: String) -> String {
        name == "lightblue" ? "light blue" : name
    }
}

/// The regions of each layout, in the order the data's colours follow.
/// Regions are painted in this order, so later ones (a cross, a disc, a
/// triangle) sit on top of earlier ones; a tap paints the topmost.
enum FlagLayoutShape {
    static func regions(_ layout: String, in r: CGRect) -> [Path] {
        let w = r.width, h = r.height, x0 = r.minX, y0 = r.minY
        func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> Path {
            Path(CGRect(x: x0 + x * w, y: y0 + y * h, width: rw * w, height: rh * h))
        }
        func poly(_ points: [(CGFloat, CGFloat)]) -> Path {
            var p = Path()
            p.addLines(points.map { CGPoint(x: x0 + $0.0 * w, y: y0 + $0.1 * h) })
            p.closeSubpath()
            return p
        }
        func hStripes(_ n: Int, from: CGFloat = 0) -> [Path] {
            (0..<n).map { rect(from, CGFloat($0) / CGFloat(n), 1 - from, 1 / CGFloat(n)) }
        }
        func vStripes(_ n: Int) -> [Path] {
            (0..<n).map { rect(CGFloat($0) / CGFloat(n), 0, 1 / CGFloat(n), 1) }
        }
        func cross(cx: CGFloat, arm: CGFloat) -> Path {
            // Bars `arm` of the height thick; the vertical one at `cx`.
            let t = arm * h / w
            var p = rect(cx - t / 2, 0, t, 1)
            p.addPath(rect(0, 0.5 - arm / 2, 1, arm))
            return p
        }
        func disc(cx: CGFloat, radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x0 + cx * w - radius * h, y: y0 + 0.5 * h - radius * h,
                                   width: 2 * radius * h, height: 2 * radius * h))
        }
        let full = rect(0, 0, 1, 1)
        let quarters = [rect(0, 0, 0.5, 0.5), rect(0.5, 0, 0.5, 0.5), rect(0, 0.5, 0.5, 0.5), rect(0.5, 0.5, 0.5, 0.5)]

        switch layout {
        case "plain": return [full]
        case "h2": return hStripes(2)
        case "h3": return hStripes(3)
        case "h4": return hStripes(4)
        case "h5": return hStripes(5)
        case "v2": return vStripes(2)
        case "v3": return vStripes(3)
        case "nordic": return [full, cross(cx: 0.36, arm: 0.18)]
        case "nordic-bordered": return [full, cross(cx: 0.36, arm: 0.28), cross(cx: 0.36, arm: 0.13)]
        case "cross":
            let t = 0.2 * h / w, arm = 0.35 * h / w
            var p = rect(0.5 - t / 2, 0.15, t, 0.7)
            p.addPath(rect(0.5 - arm, 0.4, 2 * arm, 0.2))
            return [full, p]
        case "cross-quartered": return quarters + [cross(cx: 0.5, arm: 0.16)]
        case "quarters": return quarters
        case "disc": return [full, disc(cx: 0.5, radius: 0.3)]
        case "h3-disc": return hStripes(3) + [disc(cx: 0.5, radius: 0.2)]
        case "tri-h2": return hStripes(2) + [poly([(0, 0), (0.45, 0.5), (0, 1)])]
        case "tri-h3": return hStripes(3) + [poly([(0, 0), (0.35, 0.5), (0, 1)])]
        case "tri-h5": return hStripes(5) + [poly([(0, 0), (0.45, 0.5), (0, 1)])]
        case "bar-h2": return [rect(0, 0, 1.0 / 3, 1)] + hStripes(2, from: 1.0 / 3)
        case "bar-h3": return [rect(0, 0, 0.25, 1)] + hStripes(3, from: 0.25)
        case "saltire":
            let t: CGFloat = 0.08 // half the band, as a fraction of the height
            var band = poly([(0, 0), (t * h / w * 1.4, 0), (1, 1 - t * 1.4), (1, 1), (1 - t * h / w * 1.4, 1), (0, t * 1.4)])
            band.addPath(poly([(1, 0), (1, t * 1.4), (t * h / w * 1.4, 1), (0, 1), (0, 1 - t * 1.4), (1 - t * h / w * 1.4, 0)]))
            var topBottom = poly([(0, 0), (1, 0), (0.5, 0.5)])
            topBottom.addPath(poly([(0, 1), (1, 1), (0.5, 0.5)]))
            var sides = poly([(0, 0), (0.5, 0.5), (0, 1)])
            sides.addPath(poly([(1, 0), (0.5, 0.5), (1, 1)]))
            return [topBottom, sides, band]
        case "diagonal":
            // A band from the bottom of the hoist to the top of the fly.
            let t: CGFloat = 0.16
            return [poly([(0, 0), (1 - t, 0), (0, 1 - t)]),
                    poly([(0, 1 - t), (1 - t, 0), (1, 0), (1, t), (t, 1), (0, 1)]),
                    poly([(1, t), (1, 1), (t, 1)])]
        case "diagonal-split": return [poly([(0, 0), (1, 0), (0, 1)]), poly([(1, 0), (1, 1), (0, 1)])]
        case "canton": return [full, rect(0, 0, 0.5, 0.5)]
        case "canton-h2": return hStripes(2) + [rect(0, 0, 0.5 * h / w, 0.5)]
        case "diamond":
            return [full, poly([(0.5, 0.09), (0.93, 0.5), (0.5, 0.91), (0.07, 0.5)]), disc(cx: 0.5, radius: 0.21)]
        default: return [full]
        }
    }

    /// Spoken name of a layout, for VoiceOver and read-aloud.
    static func spoken(_ layout: String) -> String {
        switch layout {
        case "plain": "One colour"
        case "h2": "Two stripes across"
        case "h3": "Three stripes across"
        case "h4": "Four stripes across"
        case "h5": "Five stripes across"
        case "v2": "Two stripes up and down"
        case "v3": "Three stripes up and down"
        case "nordic": "A cross set to the left"
        case "nordic-bordered": "A cross with a border, set to the left"
        case "cross": "A cross in the middle"
        case "cross-quartered": "A cross with four corners"
        case "quarters": "Four squares"
        case "disc": "A circle in the middle"
        case "h3-disc": "Three stripes with a circle"
        case "tri-h2": "A triangle with two stripes"
        case "tri-h3": "A triangle with three stripes"
        case "tri-h5": "A triangle with five stripes"
        case "bar-h2": "A bar with two stripes"
        case "bar-h3": "A bar with three stripes"
        case "saltire": "A big X"
        case "diagonal": "A diagonal band"
        case "diagonal-split": "Split corner to corner"
        case "canton": "A box in the corner"
        case "canton-h2": "Two stripes with a corner box"
        case "diamond": "A diamond with a circle"
        default: layout
        }
    }
}

/// A flag outline: each region filled with its painted colour (or a pale
/// grey while still blank), the emblem strokes on top, and a frame.
struct FlagOutlineCanvas: View {
    let layout: String
    var painted: [String?] = []
    var strokes: [FlagStroke] = []
    /// Regions to ring in red after grading (wrong colour).
    var wrongRegions: Set<Int> = []

    var body: some View {
        Canvas { context, size in
            let r = CGRect(origin: .zero, size: size)
            let paths = FlagLayoutShape.regions(layout, in: r)
            for (i, path) in paths.enumerated() {
                let name = i < painted.count ? painted[i] : nil
                context.fill(path, with: .color(name.map(FlagPaint.color) ?? Color(white: 0.9)))
                context.stroke(path, with: .color(.black.opacity(name == nil ? 0.35 : 0.15)), lineWidth: 1)
            }
            for i in wrongRegions where i < paths.count {
                context.stroke(paths[i], with: .color(QuizColor.wrong), style: StrokeStyle(lineWidth: 4, dash: [8, 5]))
            }
            for stroke in strokes {
                var p = Path()
                p.addLines(stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                context.stroke(p, with: .color(FlagPaint.color(stroke.color)),
                               style: StrokeStyle(lineWidth: max(3, size.width / 60), lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.3), lineWidth: 1))
    }

    /// The topmost region under a point, for painting.
    static func region(at point: CGPoint, layout: String, size: CGSize) -> Int? {
        let paths = FlagLayoutShape.regions(layout, in: CGRect(origin: .zero, size: size))
        return paths.indices.last { paths[$0].contains(point) }
    }
}

/// One line of the emblem, in fractions of the flag's size.
struct FlagStroke: Equatable {
    var color: String
    var points: [CGPoint]
}

/// Drawing a flag on an outline: pick the layout, paint the regions, maybe
/// draw the emblem, then check. Grading (layout and colours only) is the
/// Rust core's `grade_flag_outline`.
struct FlagDrawingPanel: View {
    let country: AtlasCountry
    let spec: FlagOutlineSpec
    let layoutChoices: [String]
    /// Set once the drawing has been checked.
    let result: FlagDrawResult?
    let onCheck: (FlagDrawResult) -> Void
    let onUseChoices: () -> Void

    @State private var layout: String?
    @State private var painted: [String?] = []
    @State private var brush = "red"
    @State private var drawingEmblem = false
    @State private var strokes: [FlagStroke] = []
    @State private var drawingStroke = false

    var body: some View {
        if let result {
            checked(result)
        } else if let layout {
            painting(layout)
        } else {
            layoutPicker
        }
    }

    // MARK: Step 1: the layout

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What shape is it?")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(layoutChoices, id: \.self) { choice in
                    Button {
                        pick(choice)
                    } label: {
                        FlagOutlineCanvas(layout: choice)
                            .padding(8)
                            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(FlagLayoutShape.spoken(choice))
                }
            }
            helpButton
        }
    }

    private func pick(_ choice: String) {
        layout = choice
        painted = Array(repeating: nil, count: Int(flagLayoutRegions(layout: choice)))
        strokes = []
        drawingEmblem = false
    }

    // MARK: Step 2: the colours (and the emblem)

    private func painting(_ layout: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(drawingEmblem ? "Draw the emblem. It's just for fun!" : "Tap a colour, then tap the flag.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                let size = geo.size
                FlagOutlineCanvas(layout: layout, painted: painted, strokes: strokes)
                    .frame(width: size.width, height: size.height)
                    .contentShape(.rect)
                    // One gesture for both: painting fills the part under a
                    // tap; drawing the emblem follows the finger.
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard drawingEmblem else { return }
                            let p = CGPoint(x: drag.location.x / max(size.width, 1),
                                            y: drag.location.y / max(size.height, 1))
                            if drawingStroke {
                                strokes[strokes.count - 1].points.append(p)
                            } else {
                                strokes.append(FlagStroke(color: brush, points: [p]))
                                drawingStroke = true
                            }
                        }
                        .onEnded { drag in
                            drawingStroke = false
                            guard !drawingEmblem,
                                  let i = FlagOutlineCanvas.region(at: drag.startLocation, layout: layout, size: size),
                                  i < painted.count else { return }
                            painted[i] = brush
                        })
                    .accessibilityElement()
                    .accessibilityLabel("Your flag")
                    .accessibilityValue(paintedDescription)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            // Small enough that the whole card fits on an iPad mini in
            // landscape, with the map's top bar above it.
            .frame(maxWidth: 236)
            .frame(maxWidth: .infinity)

            palette

            HStack(spacing: 10) {
                Button {
                    self.layout = nil
                } label: {
                    Label("Shapes", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                if spec.emblem || drawingEmblem {
                    Button {
                        drawingEmblem.toggle()
                    } label: {
                        Label(drawingEmblem ? "Paint" : "Emblem",
                              systemImage: drawingEmblem ? "paintbrush.fill" : "pencil.tip")
                    }
                    .buttonStyle(.bordered)
                }
                if !strokes.isEmpty {
                    Button {
                        strokes.removeLast()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .font(.callout.weight(.semibold))
            .labelStyle(.titleAndIcon)

            Button {
                check(layout)
            } label: {
                Text(painted.contains(nil) ? "Paint every part" : "Check my flag")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(painted.contains(nil))
            helpButton
        }
    }

    private var paintedDescription: String {
        painted.enumerated().map { i, name in
            "part \(i + 1) \(name.map(FlagPaint.spoken) ?? "blank")"
        }.joined(separator: ", ")
    }

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(FlagPaint.names, id: \.self) { name in
                Button {
                    brush = name
                } label: {
                    Circle()
                        .fill(FlagPaint.color(name))
                        .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: brush == name ? 4 : 0).padding(-5))
                        .frame(width: 30, height: 30)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(FlagPaint.spoken(name))
                .accessibilityAddTraits(brush == name ? .isSelected : [])
            }
        }
    }

    private var helpButton: some View {
        Button(action: onUseChoices) {
            Label("Pick it from four instead (half points)", systemImage: "square.grid.2x2")
                .font(.callout)
        }
        .buttonStyle(.borderless)
    }

    private func check(_ layout: String) {
        let colors = painted.map { $0 ?? "" }
        let grade = gradeFlagOutline(layout: spec.layout, colors: spec.colors,
                                     chosenLayout: layout, painted: colors)
        onCheck(FlagDrawResult(layout: layout, painted: colors, strokes: strokes, grade: grade))
    }

    // MARK: After checking

    private func checked(_ result: FlagDrawResult) -> some View {
        let wrong = Set(result.grade.regionsRight.enumerated().filter { !$0.element }.map(\.offset))
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                FlagOutlineCanvas(layout: result.layout, painted: result.painted, strokes: result.strokes,
                                  wrongRegions: wrong)
                Text("Yours").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your flag")
            if !result.grade.correct, let asset = country.flagAsset {
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
    }
}

/// A checked outline drawing.
struct FlagDrawResult: Equatable {
    let layout: String
    let painted: [String]
    let strokes: [FlagStroke]
    let grade: FlagOutlineGrade
}
