import SwiftData
import SwiftUI

/// A child's home: the explore worldview (requirements §3.1), with their
/// name, attendance gauge and streak floating on top.
struct ChildHomeView: View {
    let child: Profile
    let onSwitchPlayer: () -> Void

    @Environment(AtlasStore.self) private var atlasStore
    @Environment(MapCameraStore.self) private var cameraStore
    @State private var camera = MapCamera()
    @State private var selection: AtlasCountry?
    @State private var confirmingSwitch = false

    var body: some View {
        ZStack {
            if let atlas = atlasStore.atlas {
                WorldMapView(atlas: atlas, camera: $camera, selection: $selection, topInset: 96)
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
                Spacer()
            }
            .padding(20)

            if let selection {
                HStack {
                    Spacer()
                    VStack {
                        Spacer()
                        CountryCard(country: selection) {
                            withAnimation(.easeInOut(duration: 0.2)) { self.selection = nil }
                        }
                        .id(selection.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(20)
            }
        }
        .onAppear { camera = cameraStore.camera(for: child.id) }
        .onChange(of: camera) { _, new in cameraStore.set(new, for: child.id) }
        .confirmationDialog("Switch player?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
            Button("Switch player", action: onSwitchPlayer)
        } message: {
            Text("\(child.name)'s map will stay right where it is.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            ProfileAvatar(emoji: child.emoji, size: 52)
            Text(child.name).font(.title2.bold())
            WithAttendance(childID: child.id) { summary in
                AttendanceGauge(summary: summary)
                if summary.streak > 1 {
                    Label {
                        Text("\(summary.streak) days in a row!")
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .font(.headline)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
