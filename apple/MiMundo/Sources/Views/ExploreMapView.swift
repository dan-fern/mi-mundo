import SwiftUI

/// The explore map (requirements §3.1) with the country card, under a
/// floating top bar supplied by the caller. Kids get it as their home;
/// parents open it from parent home. Each profile keeps its own map
/// position while the app runs.
struct ExploreMapView<TopBar: View>: View {
    let profileID: UUID
    var failureHint = "Ask a grown-up to reinstall Mi Mundo."
    @ViewBuilder let topBar: () -> TopBar

    @Environment(AtlasStore.self) private var atlasStore
    @Environment(MapCameraStore.self) private var cameraStore
    @State private var camera = MapCamera()
    @State private var selection: AtlasCountry?
    @State private var cardOnLeadingSide = false
    /// Bottom edge of the floating top bar in screen coordinates, measured
    /// so the map fits below it at any text size.
    @State private var topBarBottom: CGFloat = 96
    /// Where the country card is (global coordinates, like the full-screen
    /// map), so map labels and stars aren't placed under it.
    @State private var cardFrame: CGRect?

    var body: some View {
        ZStack {
            if let atlas = atlasStore.atlas {
                WorldMapView(
                    atlas: atlas, camera: $camera, selection: $selection,
                    cardOnLeadingSide: $cardOnLeadingSide,
                    insets: MapInsets(top: topBarBottom + 8,
                                      avoid: selection == nil ? [] : cardFrame.map { [$0] } ?? [])
                )
                .ignoresSafeArea()
            } else if atlasStore.failed {
                ContentUnavailableView("The map couldn't load", systemImage: "map",
                                       description: Text(failureHint))
            } else {
                ProgressView("Unrolling the map…")
                    .font(.title3)
            }

            VStack {
                topBar()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        topBarBottom = $0
                    }
                Spacer()
            }
            .padding(20)

            if let selection {
                // On the side away from the country so it's never covered;
                // on the left it clears the zoom buttons.
                HStack {
                    if !cardOnLeadingSide { Spacer() }
                    VStack {
                        Spacer(minLength: topBarBottom)
                        CountryCard(country: selection) {
                            withAnimation(.easeInOut(duration: 0.2)) { self.selection = nil }
                        }
                        .id(selection.id)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            cardFrame = $0
                        }
                        .transition(.move(edge: cardOnLeadingSide ? .leading : .trailing)
                            .combined(with: .opacity))
                    }
                    if cardOnLeadingSide { Spacer() }
                }
                .padding(.vertical, 20)
                .padding(.leading, cardOnLeadingSide ? 100 : 20)
                .padding(.trailing, 20)
            }
        }
        .onAppear { camera = cameraStore.camera(for: profileID) }
        .onChange(of: camera) { _, new in cameraStore.set(new, for: profileID) }
    }
}

/// The parent's way into the explore map: same map, with a back button.
struct ParentMapView: View {
    let parent: Profile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExploreMapView(profileID: parent.id, failureHint: "Try reinstalling Mi Mundo.") {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                Text("World map").font(.title2.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
