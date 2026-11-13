import MiMundoCore
import SwiftUI

/// Where the map is looking: which map point sits at the middle of the
/// visible area, and how far zoomed in (1 = whole world fits).
struct MapCamera: Equatable, Sendable {
    var center: CGPoint = .zero
    var zoom: CGFloat = 1

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 80
    /// Above this zoom the detailed (1:50m) outlines are drawn.
    static let fineDetailZoom: CGFloat = 2.5
}

/// Remembers each kid's map position while the app is running, so
/// switching players and back doesn't lose their place.
@MainActor
@Observable
final class MapCameraStore {
    private var cameras: [UUID: MapCamera] = [:]

    func camera(for profileID: UUID) -> MapCamera {
        cameras[profileID] ?? MapCamera()
    }

    func set(_ camera: MapCamera, for profileID: UUID) {
        cameras[profileID] = camera
    }
}

/// Screen layout the map has to work around: the floating top bar, and
/// anything else floating over it (the country card) that labels, pins
/// and stars should stay out from under.
struct MapInsets: Equatable {
    var top: CGFloat = 0
    /// Rects in the map view's coordinates.
    var avoid: [CGRect] = []
}

/// Pan/zoom world map. No country names are drawn (quiz answers stay
/// hidden); tapping a country selects it, tapping the sea clears it.
struct WorldMapView: View {
    let atlas: Atlas
    @Binding var camera: MapCamera
    @Binding var selection: AtlasCountry?
    /// Set on each tap: true when the tapped country is on the right half of
    /// the screen, so the card opens on the left and never covers it.
    @Binding var cardOnLeadingSide: Bool
    var insets = MapInsets()
    var labelMode: MapLabelMode = .explore

    /// Baseline for the gesture in progress.
    @State private var gesture: GestureBaseline?
    /// True only while a pan/pinch is in progress. `@GestureState` resets on
    /// both end *and* cancellation (Control Center, a notification), which
    /// clears the baseline so the next gesture can never jump.
    @GestureState private var gestureActive = false

    private struct GestureBaseline {
        var camera: MapCamera
        /// Drag translation already folded into `camera` (rebased when a
        /// pinch turns into a one-finger drag).
        var translation: CGSize = .zero
        var pinching = false
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            MapCanvas(atlas: atlas, camera: camera, selection: selection,
                      layout: MapLayout(atlas: atlas, size: size, insets: insets),
                      labelMode: labelMode,
                      covered: insets.avoid + [Self.controlsRect(in: size)])
                // Map labels are already big; past this they mostly collide
                // and vanish, so they stop growing (the card keeps growing).
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentShape(.rect)
                .gesture(panAndZoom(size: size))
                .onChange(of: gestureActive) { _, active in
                    if !active { gesture = nil }
                }
                .onTapGesture(coordinateSpace: .local) { location in
                    select(at: location, size: size)
                }
                .onChange(of: size) { _, newSize in
                    camera = layout(newSize).clamped(camera)
                }
                .accessibilityElement()
                .accessibilityLabel("World map")
                .accessibilityHint("Drag to move, pinch to zoom, tap a country to learn about it.")
                .overlay(alignment: .bottomLeading) { controls(size: size) }
        }
        .background(MapCanvas.space)
    }

    /// Where the zoom buttons sit (bottom left), so labels avoid them.
    static func controlsRect(in size: CGSize) -> CGRect {
        // 56 pt buttons, 12 pt apart, 20 pt padding (+12 pt more below).
        let button: CGFloat = 56
        let width: CGFloat = button + 40
        let height: CGFloat = button * 3 + 24 + 52
        return CGRect(x: 0, y: size.height - height, width: width, height: height)
    }

    /// Big zoom buttons (pinching is hard for small hands) and a "whole
    /// world" button so a kid lost in the ocean can always get back.
    private func controls(size: CGSize) -> some View {
        let layout = layout(size)
        let center = CGPoint(x: size.width / 2, y: insets.top + (size.height - insets.top) / 2)
        return VStack(spacing: 12) {
            mapButton("plus.magnifyingglass", label: "Zoom in") {
                camera = layout.zoomed(camera, by: 2, around: center)
            }
            mapButton("minus.magnifyingglass", label: "Zoom out") {
                camera = layout.zoomed(camera, by: 0.5, around: center)
            }
            mapButton("globe.americas.fill", label: "Show the whole world") {
                camera = layout.clamped(MapCamera())
            }
        }
        .padding(20)
        .padding(.bottom, 12)
    }

    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35), action)
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func layout(_ size: CGSize) -> MapLayout {
        MapLayout(atlas: atlas, size: size, insets: insets)
    }

    // MARK: Gestures

    private func panAndZoom(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .simultaneously(with: MagnifyGesture(minimumScaleDelta: 0.01))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                var base = gesture ?? GestureBaseline(camera: camera)
                let pinching = value.second != nil
                if base.pinching && !pinching {
                    // A finger lifted mid-pinch: continue as a drag from
                    // where the pinch left the map, without snapping back.
                    base = GestureBaseline(camera: camera,
                                           translation: value.first?.translation ?? .zero)
                }
                base.pinching = pinching
                gesture = base
                camera = nextCamera(from: base, value: value, size: size)
            }
            .onEnded { _ in gesture = nil }
    }

    private func nextCamera(
        from base: GestureBaseline,
        value: SimultaneousGesture<DragGesture, MagnifyGesture>.Value,
        size: CGSize
    ) -> MapCamera {
        let layout = layout(size)
        var next = base.camera
        if let magnify = value.second {
            next = layout.zoomed(base.camera, by: magnify.magnification, around: magnify.startLocation)
        }
        if let drag = value.first {
            let k = layout.pointsPerUnit(next)
            next.center.x -= (drag.translation.width - base.translation.width) / k
            next.center.y -= (drag.translation.height - base.translation.height) / k
        }
        return layout.clamped(next)
    }

    private func select(at location: CGPoint, size: CGSize) {
        let layout = layout(size)
        let point = layout.mapPoint(at: location, camera: camera)
        // ~22 pt of fingertip slack, in map units.
        let hit = atlas.country(at: point, tolerance: 22 / layout.pointsPerUnit(camera))
        if let hit {
            let box = hit.bounds.applying(layout.mapToScreen(camera))
            cardOnLeadingSide = box.midX > size.width / 2
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            // Tapping the selected country again keeps it; the sea clears it.
            selection = hit
        }
    }
}

/// The map's geometry for one view size: fitting, transforms, zooming and
/// clamping. Pure value type so gestures, taps and drawing agree.
struct MapLayout {
    let atlas: Atlas
    let size: CGSize
    let insets: MapInsets
    /// Area not covered by the floating top bar.
    private var visible: CGRect {
        CGRect(x: 0, y: insets.top, width: size.width, height: max(size.height - insets.top, 1))
    }

    /// Points per map unit at zoom 1: the whole world fits with a margin.
    private var fitScale: CGFloat {
        let world = atlas.bounds
        return min(visible.width / world.width, visible.height / world.height) * 0.94
    }

    func pointsPerUnit(_ camera: MapCamera) -> CGFloat {
        fitScale * camera.zoom
    }

    func mapToScreen(_ camera: MapCamera) -> CGAffineTransform {
        let k = pointsPerUnit(camera)
        return CGAffineTransform(translationX: visible.midX, y: visible.midY)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -camera.center.x, y: -camera.center.y)
    }

    func mapPoint(at location: CGPoint, camera: MapCamera) -> CGPoint {
        location.applying(mapToScreen(camera).inverted())
    }

    /// Zooms by `factor`, keeping the map point under `anchor` fixed.
    func zoomed(_ camera: MapCamera, by factor: CGFloat, around anchor: CGPoint) -> MapCamera {
        let mapAnchor = mapPoint(at: anchor, camera: camera)
        var next = camera
        next.zoom = (camera.zoom * factor).clamped(to: MapCamera.minZoom...MapCamera.maxZoom)
        let k = pointsPerUnit(next)
        next.center = CGPoint(x: mapAnchor.x - (anchor.x - visible.midX) / k,
                              y: mapAnchor.y - (anchor.y - visible.midY) / k)
        return clamped(next)
    }

    /// Keeps the zoom in range and the world covering the view: a kid can't
    /// drag the world off the screen. When the world is smaller than the
    /// view along an axis, it stays centered on that axis.
    func clamped(_ camera: MapCamera) -> MapCamera {
        var c = camera
        c.zoom = c.zoom.clamped(to: MapCamera.minZoom...MapCamera.maxZoom)
        let world = atlas.bounds
        let k = pointsPerUnit(c)
        let halfW = visible.width / 2 / k
        let halfH = visible.height / 2 / k
        c.center.x = world.width <= 2 * halfW ? world.midX
            : c.center.x.clamped(to: (world.minX + halfW)...(world.maxX - halfW))
        c.center.y = world.height <= 2 * halfH ? world.midY
            : c.center.y.clamped(to: (world.minY + halfH)...(world.maxY - halfH))
        return c
    }

    /// Map rectangle currently on screen (for culling).
    func visibleMapRect(_ camera: MapCamera) -> CGRect {
        CGRect(origin: .zero, size: size).applying(mapToScreen(camera).inverted())
    }
}

/// Draws the map. Its camera is animatable (center and log-zoom), so
/// `withAnimation` changes glide instead of jumping.
struct MapCanvas: View, Animatable {
    let atlas: Atlas
    var camera: MapCamera
    let selection: AtlasCountry?
    let layout: MapLayout
    var labelMode: MapLabelMode = .explore
    /// Screen rects with controls or the card on top: nothing is placed there.
    var covered: [CGRect] = []

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(camera.center.x, camera.center.y), log(camera.zoom)) }
        set {
            camera.center = CGPoint(x: newValue.first.first, y: newValue.first.second)
            camera.zoom = exp(newValue.second)
        }
    }

    // Political-atlas palette: muted land colors, one per Natural Earth
    // MAPCOLOR7 group so neighboring countries always differ.
    private static let land: [Color] = [
        Color(red: 0.94, green: 0.87, blue: 0.64), // sand
        Color(red: 0.78, green: 0.86, blue: 0.64), // sage
        Color(red: 0.94, green: 0.79, blue: 0.66), // apricot
        Color(red: 0.75, green: 0.85, blue: 0.78), // seafoam
        Color(red: 0.88, green: 0.80, blue: 0.88), // heather
        Color(red: 0.96, green: 0.84, blue: 0.68), // wheat
        Color(red: 0.85, green: 0.88, blue: 0.62), // olive
    ]
    private static let ocean = Color(red: 0.55, green: 0.75, blue: 0.89)
    static let space = Color(red: 0.11, green: 0.16, blue: 0.24)
    private static let border = Color(red: 0.30, green: 0.26, blue: 0.21)
    /// Selected country: much darker and redder than every land color, so
    /// it stands out by lightness too (not hue alone).
    private static let highlight = Color(red: 0.86, green: 0.30, blue: 0.20)
    private static let highlightEdge = Color(red: 0.35, green: 0.08, blue: 0.05)

    var body: some View {
        Canvas { context, _ in draw(in: &context) }
    }

    private func draw(in context: inout GraphicsContext) {
        let k = layout.pointsPerUnit(camera)
        let visible = layout.visibleMapRect(camera)
        let hairline = 1 / k
        var map = context
        map.concatenate(layout.mapToScreen(camera))

        map.fill(atlas.outline, with: .color(Self.ocean))
        map.stroke(atlas.graticule, with: .color(.white.opacity(0.28)), lineWidth: 0.7 * hairline)

        let fine = camera.zoom >= MapCamera.fineDetailZoom
        let shown = atlas.countries.filter { $0.bounds.intersects(visible) }
        for country in shown {
            let color = Self.land[(Int(country.meta.colorGroup) - 1).clamped(to: 0...(Self.land.count - 1))]
            map.fill(fine ? country.fine : country.coarse, with: .color(color), style: FillStyle(eoFill: true))
        }
        let features = atlas.features.filter {
            $0.minZoom <= camera.zoom && $0.bounds.intersects(visible)
        }
        drawPhysical(features, in: &map, hairline: hairline)
        for country in shown {
            map.stroke(fine ? country.fine : country.coarse,
                       with: .color(Self.border.opacity(0.8)), lineWidth: 0.7 * hairline)
        }
        if let selection, selection.bounds.intersects(visible) {
            let path = fine ? selection.fine : selection.coarse
            map.fill(path, with: .color(Self.highlight), style: FillStyle(eoFill: true))
            map.stroke(path, with: .color(Self.highlightEdge), lineWidth: 3 * hairline)
            // Tiny countries (a few points across): add a ring so the
            // selection is visible at all.
            let box = selection.bounds.applying(layout.mapToScreen(camera))
            if max(box.width, box.height) < 14 {
                let ring = CGRect(x: box.midX - 18, y: box.midY - 18, width: 36, height: 36)
                context.stroke(Path(ellipseIn: ring), with: .color(Self.highlightEdge), lineWidth: 3)
                context.stroke(Path(ellipseIn: ring.insetBy(dx: 3, dy: 3)), with: .color(.white), lineWidth: 2)
            }
        }
        map.stroke(atlas.outline, with: .color(.white.opacity(0.5)), lineWidth: 1.5 * hairline)
        drawMarkersAndLabels(features, in: &context, visible: visible)
    }

    // MARK: Physical features

    private static let water = Color(red: 0.55, green: 0.75, blue: 0.89)
    private static let river = Color(red: 0.27, green: 0.53, blue: 0.80)
    private static let sand = Color(red: 0.93, green: 0.80, blue: 0.50)
    private static let waterText = Color(red: 0.10, green: 0.30, blue: 0.58)
    private static let landText = Color(red: 0.42, green: 0.27, blue: 0.12)

    /// Quiz mode: zoom from which landmarks appear on guessed countries. (A
    /// pin is only drawn when its name fits too, so there are never mystery
    /// dots.) Explore mode pins the selected country's landmarks at any zoom.
    static let landmarkZoom: CGFloat = 4

    /// Deserts (sandy wash), lakes, then rivers, in map space under borders.
    private func drawPhysical(_ features: [MapFeature], in map: inout GraphicsContext, hairline: CGFloat) {
        for f in features where f.kind == .desert {
            map.fill(f.path, with: .color(Self.sand.opacity(0.45)), style: FillStyle(eoFill: true))
        }
        for f in features where f.kind == .lake {
            map.fill(f.path, with: .color(Self.water), style: FillStyle(eoFill: true))
            map.stroke(f.path, with: .color(Self.river.opacity(0.6)), lineWidth: 0.6 * hairline)
        }
        // Rivers get a little thicker as you zoom in, but stay hairline-ish.
        let riverWidth = (0.8 + 0.25 * log2(camera.zoom)).clamped(to: 0.8...2.2) * hairline
        let style = StrokeStyle(lineWidth: riverWidth, lineCap: .round, lineJoin: .round)
        let visible = layout.visibleMapRect(camera)
        for f in features where f.kind == .river {
            for piece in f.pieces where piece.bounds.intersects(visible) {
                map.stroke(piece.path, with: .color(Self.river), style: style)
            }
        }
    }

    /// Capital star, peaks, landmark pins and labels, in screen space so they
    /// stay the same size at any zoom. Labels are placed in priority order
    /// (last frame's labels first, so they don't flicker while panning) and
    /// skipped if they would overlap one already placed, the top bar, the
    /// zoom buttons or the card. Map labels use smaller type than the rest
    /// of the kid UI so the map stays readable.
    private func drawMarkersAndLabels(_ features: [MapFeature], in context: inout GraphicsContext,
                                      visible: CGRect) {
        let toScreen = layout.mapToScreen(camera)
        // Open area: below the floating top bar.
        let screen = CGRect(x: 0, y: layout.insets.top, width: layout.size.width,
                            height: max(layout.size.height - layout.insets.top, 0))
        // Anchors farther out than this can't have an on-screen label.
        let reach = screen.insetBy(dx: -160, dy: -60)
        var placed: [CGRect] = covered
        var named: Set<String> = []
        var labels: [(text: GraphicsContext.ResolvedText, at: CGPoint, angle: Angle)] = []
        var pinDots: [CGRect] = []
        var starBoxes: [CGRect] = []
        let memory = atlas.labelMemory
        var placedKeys: Set<String> = []

        func free(_ rect: CGRect) -> Bool {
            screen.contains(rect) && !placed.contains { $0.intersects(rect) }
        }

        // Capital star(s) of the selected country, first so nothing covers
        // them. In a quiz the star would answer "what's the capital?", so it
        // follows the same reveal rule as names.
        if let selection, labelMode.shows(NameReveal(owner: selection.id)) {
            for capital in selection.capitals {
                let p = capital.applying(toScreen)
                let box = CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)
                guard screen.contains(box) else { continue }
                MapSymbol.drawCapitalStar(in: &context, at: p, radius: 11)
                placed.append(box)
                starBoxes.append(box)
            }
        }

        func place(_ text: Text, at point: CGPoint, angle: Angle = .zero, padding: CGFloat = 4) -> Bool {
            let resolved = context.resolve(text)
            let size = resolved.measure(in: CGSize(width: 320, height: 100))
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
            // Rotated text: test against its axis-aligned bounds.
            let bounds = rect.applying(CGAffineTransform(translationX: point.x, y: point.y)
                .rotated(by: angle.radians).translatedBy(x: -point.x, y: -point.y))
                .insetBy(dx: -padding, dy: -padding)
            guard free(bounds) else { return false }
            placed.append(bounds)
            labels.append((resolved, point, angle))
            return true
        }

        // Peak triangles: on screen and clear of what's there, or not at all
        // (a peak's name is only drawn with its triangle).
        var peaksDrawn = Set<Int>()
        for f in features where f.kind == .peak {
            let p = f.label.applying(toScreen)
            let box = CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
            guard free(box) else { continue }
            var tri = Path()
            tri.move(to: CGPoint(x: p.x, y: p.y - 7))
            tri.addLine(to: CGPoint(x: p.x + 7, y: p.y + 5))
            tri.addLine(to: CGPoint(x: p.x - 7, y: p.y + 5))
            tri.closeSubpath()
            context.fill(tri, with: .color(Self.landText))
            placed.append(box)
            peaksDrawn.insert(f.index)
        }

        // Candidates in priority order, with last frame's labels moved to
        // the front of their group.
        func steady<T>(_ items: [T], key: (T) -> String) -> [T] {
            let (kept, rest) = items.reduce(into: ([T](), [T]())) { acc, item in
                if memory.placed.contains(key(item)) { acc.0.append(item) } else { acc.1.append(item) }
            }
            return kept + rest
        }
        let labelled = features.filter {
            !$0.name.isEmpty && $0.labelMinZoom <= camera.zoom && labelMode.shows($0.reveal)
                && reach.contains($0.label.applying(toScreen))
                && ($0.kind != .peak || peaksDrawn.contains($0.index))
        }
        let areas = steady(labelled.filter { $0.kind.labelPriority <= 1 }) { "f\($0.index)" }
        let others = steady(labelled.filter { $0.kind.labelPriority > 1 }) { "f\($0.index)" }
        // Landmarks. Exploring: only the selected country's, like its
        // capital star, so the map isn't cluttered with pins. In a quiz:
        // those of countries already guessed, as a reward, once zoomed in.
        let pins: [LandmarkPin]
        switch labelMode {
        case .explore:
            pins = selection?.landmarks ?? []
        case .quiz:
            pins = camera.zoom >= Self.landmarkZoom
                ? steady(atlas.landmarks.filter {
                    visible.contains($0.point) && labelMode.shows($0.reveal)
                }) { "l\($0.name)" }
                : []
        }

        // The selected country's landmarks come first (they're what the kid
        // asked about), then big areas, then water and peaks.
        for pin in pins {
            let at = pin.point.applying(toScreen)
            func dot(_ p: CGPoint) -> CGRect { CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14) }
            // A landmark in the capital (the Colosseum in Rome) would sit
            // under the star: its pin slides just beside the star instead,
            // on whichever side its name also fits.
            var spots = [at]
            if let star = starBoxes.first(where: { $0.intersects(dot(at)) }) {
                spots = [CGPoint(x: star.midX + 21, y: star.midY + 14),
                         CGPoint(x: star.midX - 21, y: star.midY + 14)]
            }
            let label = Text(pin.name).font(.subheadline.weight(.bold)).foregroundStyle(.black.opacity(0.8))
            for p in spots where free(dot(p)) && place(label, at: CGPoint(x: p.x, y: p.y + 18)) {
                placed.append(dot(p))
                pinDots.append(dot(p))
                placedKeys.insert("l\(pin.name)")
                break
            }
        }
        for f in areas where !named.contains(f.name) {
            if placeFeatureLabel(f) { named.insert(f.name) }
        }
        for f in others where !named.contains(f.name) {
            if placeFeatureLabel(f) { named.insert(f.name) }
        }
        memory.placed = placedKeys

        func placeFeatureLabel(_ f: MapFeature) -> Bool {
            let p = f.label.applying(toScreen)
            let text: Text
            var at = p
            switch f.kind {
            case .desert:
                text = Text(f.labelText).font(.headline.italic()).tracking(2)
                    .foregroundStyle(Self.landText.opacity(0.85))
            case .range:
                text = Text(f.labelText).font(.headline.italic().weight(.semibold))
                    .foregroundStyle(Self.landText)
            case .lake, .river:
                text = Text(f.labelText).font(.subheadline.italic())
                    .foregroundStyle(Self.waterText)
            case .peak:
                text = Text(f.labelText).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.landText)
                at.y += 22
            }
            guard place(text, at: at, angle: f.kind == .river ? f.labelAngle : .zero) else { return false }
            placedKeys.insert("f\(f.index)")
            return true
        }

        // All labels in one layer with one soft white halo (two shadow
        // passes for the whole set, not per label).
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .white.opacity(0.95), radius: 1.5))
            layer.addFilter(.shadow(color: .white.opacity(0.8), radius: 3))
            for label in labels {
                var l = layer
                l.translateBy(x: label.at.x, y: label.at.y)
                l.rotate(by: label.angle)
                l.draw(label.text, at: .zero, anchor: .center)
            }
        }
        for dot in pinDots {
            MapSymbol.drawLandmarkPin(in: &context, in: dot)
        }
    }
}

/// The map's two symbols, shared with the country card so its rows are a
/// legend: the same gold star means "capital", the same pin "famous place".
enum MapSymbol {
    static let starFill = Color(red: 1.0, green: 0.84, blue: 0.20)
    static let starEdge = Color(red: 0.35, green: 0.08, blue: 0.05)
    /// Deep violet: far from the red selection highlight and every land
    /// color, so pins stay visible on the selected country.
    static let pinFill = Color(red: 0.36, green: 0.18, blue: 0.62)
    static let pinEdge = Color(red: 0.12, green: 0.05, blue: 0.22)

    /// Five-pointed star, point up, centered on `center`.
    static func star(at center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? radius : radius * 0.45
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func drawCapitalStar(in context: inout GraphicsContext, at center: CGPoint, radius: CGFloat) {
        let star = star(at: center, radius: radius)
        context.fill(star, with: .color(starFill))
        context.stroke(star, with: .color(starEdge),
                       style: StrokeStyle(lineWidth: max(1.5, radius / 5.5), lineJoin: .round))
    }

    static func drawLandmarkPin(in context: inout GraphicsContext, in rect: CGRect) {
        context.fill(Path(ellipseIn: rect), with: .color(pinEdge))
        context.fill(Path(ellipseIn: rect.insetBy(dx: rect.width * 0.1, dy: rect.width * 0.1)),
                     with: .color(.white))
        context.fill(Path(ellipseIn: rect.insetBy(dx: rect.width * 0.24, dy: rect.width * 0.24)),
                     with: .color(pinFill))
    }
}

/// The capital star as a view (card legend), drawn exactly like the map's.
struct CapitalStarIcon: View {
    var size: CGFloat = 28
    var body: some View {
        Canvas { context, canvasSize in
            MapSymbol.drawCapitalStar(in: &context,
                                      at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2 + 1),
                                      radius: size / 2 - 1)
        }
        .frame(width: size, height: size)
    }
}

/// The landmark pin as a view (card legend), drawn exactly like the map's.
struct LandmarkPinIcon: View {
    var size: CGFloat = 22
    var body: some View {
        Canvas { context, canvasSize in
            MapSymbol.drawLandmarkPin(in: &context, in: CGRect(origin: .zero, size: canvasSize))
        }
        .frame(width: size, height: size)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
