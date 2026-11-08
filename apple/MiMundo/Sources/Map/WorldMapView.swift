import SwiftUI

/// Where the map is looking: which map point sits at the middle of the view,
/// and how far zoomed in (1 = whole world fits).
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

/// Pan/zoom world map. No country names are drawn (quiz answers stay
/// hidden); tapping a country selects it.
struct WorldMapView: View {
    let atlas: Atlas
    @Binding var camera: MapCamera
    @Binding var selection: AtlasCountry?
    /// Space at the top covered by floating controls; the map fits below it.
    var topInset: CGFloat = 0

    @State private var gestureStart: MapCamera?

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
    private static let space = Color(red: 0.11, green: 0.16, blue: 0.24)
    private static let border = Color(red: 0.38, green: 0.33, blue: 0.27)
    private static let highlight = Color(red: 1.0, green: 0.82, blue: 0.25)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(.rect)
            .gesture(panAndZoom(size: size))
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                withAnimation(.easeInOut(duration: 0.3)) {
                    zoom(by: 2.5, around: location, size: size)
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                select(at: location, size: size)
            }
            .accessibilityElement()
            .accessibilityLabel("World map")
            .accessibilityHint("Drag to move, pinch to zoom, tap a country to learn about it.")
        }
        .background(Self.space)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = pointsPerMapUnit(size)
        context.concatenate(mapToScreen(size))
        let visible = CGRect(origin: .zero, size: size).applying(mapToScreen(size).inverted())
        let hairline = 1 / scale

        context.fill(atlas.outline, with: .color(Self.ocean))
        context.stroke(atlas.graticule, with: .color(.white.opacity(0.28)), lineWidth: 0.7 * hairline)

        let fine = camera.zoom >= MapCamera.fineDetailZoom
        let shown = atlas.countries.filter { $0.bounds.intersects(visible) }
        for country in shown {
            let color = Self.land[(Int(country.meta.colorGroup) - 1).clamped(to: 0...(Self.land.count - 1))]
            context.fill(fine ? country.fine : country.coarse, with: .color(color), style: FillStyle(eoFill: true))
        }
        for country in shown {
            context.stroke(fine ? country.fine : country.coarse,
                           with: .color(Self.border.opacity(0.55)), lineWidth: 0.6 * hairline)
        }
        if let selection, selection.bounds.intersects(visible) {
            let path = fine ? selection.fine : selection.coarse
            context.fill(path, with: .color(Self.highlight.opacity(0.85)), style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(Self.border), lineWidth: 2 * hairline)
        }
        context.stroke(atlas.outline, with: .color(.white.opacity(0.5)), lineWidth: 1.5 * hairline)
    }

    // MARK: Geometry

    /// Points per map unit at zoom 1: the whole world fits with a margin.
    private func fitScale(_ size: CGSize) -> CGFloat {
        let world = atlas.bounds
        let height = max(size.height - topInset, 1)
        return min(size.width / world.width, height / world.height) * 0.94
    }

    /// Screen point the camera center maps to: the middle of the area below
    /// the floating controls.
    private func viewCenter(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: topInset + (size.height - topInset) / 2)
    }

    private func pointsPerMapUnit(_ size: CGSize) -> CGFloat {
        fitScale(size) * camera.zoom
    }

    private func mapToScreen(_ size: CGSize, camera: MapCamera? = nil) -> CGAffineTransform {
        let camera = camera ?? self.camera
        let k = fitScale(size) * camera.zoom
        let c = viewCenter(size)
        return CGAffineTransform(translationX: c.x, y: c.y)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -camera.center.x, y: -camera.center.y)
    }

    private func mapPoint(at location: CGPoint, size: CGSize, camera: MapCamera? = nil) -> CGPoint {
        location.applying(mapToScreen(size, camera: camera).inverted())
    }

    /// Keeps the zoom in range and the world from sliding off screen.
    private func clamped(_ camera: MapCamera) -> MapCamera {
        var c = camera
        c.zoom = c.zoom.clamped(to: MapCamera.minZoom...MapCamera.maxZoom)
        let world = atlas.bounds
        c.center.x = c.center.x.clamped(to: world.minX...world.maxX)
        c.center.y = c.center.y.clamped(to: world.minY...world.maxY)
        return c
    }

    // MARK: Gestures

    private func panAndZoom(size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 4)
        let magnify = MagnifyGesture(minimumScaleDelta: 0.01)
        return drag.simultaneously(with: magnify)
            .onChanged { value in
                let start = gestureStart ?? camera
                if gestureStart == nil { gestureStart = start }
                var next = start
                if let magnify = value.second {
                    // Keep the map point under the pinch fixed while zooming.
                    let anchor = mapPoint(at: magnify.startLocation, size: size, camera: start)
                    next.zoom = (start.zoom * magnify.magnification)
                        .clamped(to: MapCamera.minZoom...MapCamera.maxZoom)
                    let k = fitScale(size) * next.zoom
                    next.center = CGPoint(
                        x: anchor.x - (magnify.startLocation.x - viewCenter(size).x) / k,
                        y: anchor.y - (magnify.startLocation.y - viewCenter(size).y) / k
                    )
                }
                if let drag = value.first {
                    let k = fitScale(size) * next.zoom
                    next.center.x -= drag.translation.width / k
                    next.center.y -= drag.translation.height / k
                }
                camera = clamped(next)
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func zoom(by factor: CGFloat, around location: CGPoint, size: CGSize) {
        let anchor = mapPoint(at: location, size: size)
        var next = camera
        next.zoom = (camera.zoom * factor).clamped(to: MapCamera.minZoom...MapCamera.maxZoom)
        let k = fitScale(size) * next.zoom
        next.center = CGPoint(
            x: anchor.x - (location.x - viewCenter(size).x) / k,
            y: anchor.y - (location.y - viewCenter(size).y) / k
        )
        camera = clamped(next)
    }

    private func select(at location: CGPoint, size: CGSize) {
        let point = mapPoint(at: location, size: size)
        // ~22 pt of fingertip slack, in map units.
        let tolerance = 22 / pointsPerMapUnit(size)
        let hit = atlas.country(at: point, tolerance: tolerance)
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = (hit?.id == selection?.id) ? nil : hit
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
