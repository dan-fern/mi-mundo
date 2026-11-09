import SwiftData
import SwiftUI

/// A child's home: the explore worldview (requirements §3.1), with their
/// name, attendance gauge and streak floating on top.
struct ChildHomeView: View {
    let child: Profile
    let onSwitchPlayer: () -> Void

    @Environment(AtlasStore.self) private var atlasStore
    @Environment(MapCameraStore.self) private var cameraStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var camera = MapCamera()
    @State private var selection: AtlasCountry?
    @State private var confirmingSwitch = false
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
                                       description: Text("Ask a grown-up to reinstall Mi Mundo."))
            } else {
                ProgressView("Unrolling the map…")
                    .font(.title3)
            }

            VStack {
                topBar
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
        .onAppear { camera = cameraStore.camera(for: child.id) }
        .onChange(of: camera) { _, new in cameraStore.set(new, for: child.id) }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            ProfileAvatar(emoji: child.emoji, size: 52)
            Text(child.name).font(.title2.bold()).lineLimit(1)
            WithAttendance(childID: child.id) { summary in
                AttendanceGauge(summary: summary)
                if summary.streak > 1 {
                    // At big text sizes, just the star and the number.
                    Label {
                        Text(typeSize.isAccessibilitySize ? "\(summary.streak)" : "\(summary.streak) days in a row!")
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .font(.headline)
                    .accessibilityLabel("\(summary.streak) days in a row")
                }
            }
            Button {
                confirmingSwitch = true
            } label: {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Switch player")
            // Attached to the button so on iPad the popover points at it.
            .confirmationDialog("Switch player?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
                Button("Switch player", action: onSwitchPlayer)
            } message: {
                Text("\(child.name)'s map will stay right where it is.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
