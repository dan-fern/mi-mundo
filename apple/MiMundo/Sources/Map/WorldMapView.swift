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

/// Screen layout the map has to work around: the floating top bar.
struct MapInsets: Equatable {
    var top: CGFloat = 0
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
                      layout: MapLayout(atlas: atlas, size: size, insets: insets))
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
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
