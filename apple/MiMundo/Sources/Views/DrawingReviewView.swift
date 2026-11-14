import SwiftData
import SwiftUI

/// Parent review of flag drawings (requirements §5.3): every drawing with
/// the app's verdict, newest first; a parent can mark any of them right or
/// wrong, which rescores the answer.
struct DrawingReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(AtlasStore.self) private var atlasStore
    @Query(sort: \FlagDrawing.drawnAt, order: .reverse) private var drawings: [FlagDrawing]
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]

    @State private var who: UUID?
    @State private var show: Filter = .all
    @State private var saveFailed = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case missed = "Marked wrong"
        case changed = "Changed by you"
        var id: String { rawValue }
    }

    private var drawers: [Profile] {
        let ids = Set(drawings.map(\.profileID))
        return profiles.filter { ids.contains($0.id) }
    }

    private var shown: [FlagDrawing] {
        drawings.filter { d in
            (who == nil || d.profileID == who) && {
                switch show {
                case .all: true
                case .missed: !d.isCorrect
                case .changed: d.parentVerdict != nil
                }
            }()
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $show) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if drawers.count > 1 {
                    Picker("Who", selection: $who) {
                        Text("Everyone").tag(UUID?.none)
                        ForEach(drawers) { p in
                            Text("\(p.emoji) \(p.name)").tag(Optional(p.id))
                        }
                    }
                }
            } footer: {
                Text("The app is lenient: emblems and small details aren't marked. If it got one wrong, change it here. A drawing you mark right earns what it was worth on that try.")
            }

            if shown.isEmpty {
                Section {
                    Text(drawings.isEmpty ? "No flags drawn yet. Drawings from flag questions show up here."
                                          : "Nothing to show with these filters.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(shown) { drawing in
                        DrawingRow(drawing: drawing,
                                   country: atlasStore.atlas?.countries.first { $0.meta.id == drawing.countryID },
                                   who: profiles.first { $0.id == drawing.profileID },
                                   onVerdict: { verdict in
                                       if !DrawingReview.setVerdict(verdict, on: drawing, in: context) {
                                           saveFailed = true
                                       }
                                   })
                    }
                }
            }
        }
        .navigationTitle("Flag drawings")
        .alert("That change didn't save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct DrawingRow: View {
    let drawing: FlagDrawing
    let country: AtlasCountry?
    let who: Profile?
    let onVerdict: (Bool?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 4) {
                drawingView.frame(width: 150)
                Text(drawing.methodRaw == "outline" ? "On an outline" : "Freehand")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                if let asset = country?.flagAsset {
                    Image(asset)
                        .resizable()
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(width: 110)
                        .clipShape(.rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.3)))
                }
                Text("The real flag").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(country?.name ?? drawing.countryID).font(.headline)
                Text("\(who.map { "\($0.emoji) \($0.name)" } ?? "Someone") · \(drawing.drawnAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
                verdictLabel
            }
            Spacer(minLength: 8)
            Menu {
                Button("Mark right", systemImage: "checkmark") { onVerdict(true) }
                Button("Mark wrong", systemImage: "xmark") { onVerdict(false) }
                if drawing.parentVerdict != nil {
                    Button("Go back to the app's verdict", systemImage: "arrow.uturn.backward") { onVerdict(nil) }
                }
            } label: {
                Text("Change")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var drawingView: some View {
        switch drawing.decoded {
        case .freehand(let sketch):
            FlagSketchView(sketch: sketch)
        case .outline(let layout, let painted, let strokes):
            FlagOutlineCanvas(layout: layout, painted: painted, strokes: strokes)
        case nil:
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.9)).aspectRatio(4 / 3, contentMode: .fit)
        }
    }

    private var verdictLabel: some View {
        let right = drawing.isCorrect
        let by = drawing.parentVerdict == nil ? "the app" : "you"
        return Label(right ? "Right (\(by))" : "Not right (\(by))",
                     systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(right ? QuizColor.right : QuizColor.wrong)
    }
}
