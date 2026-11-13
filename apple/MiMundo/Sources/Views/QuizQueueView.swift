import MiMundoCore
import SwiftData
import SwiftUI

/// The live query every queue screen uses: quizzes in the queue, in order.
private let queuedQuizzes = FetchDescriptor<QuizSet>(
    predicate: #Predicate { $0.removedAt == nil },
    sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]
)

/// "Quiz of the day" on the parent home: today's quiz and a way into the queue.
struct QuizOfTheDaySection: View {
    let parent: Profile

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(queuedQuizzes) private var quizzes: [QuizSet]
    @Query private var records: [QueueRecord]

    private var today: QuizSet? {
        quizzes.first { $0.id == records.first?.currentQuizID }
    }

    var body: some View {
        Section("Quiz of the day") {
            if let today {
                QuizRow(quiz: today, badge: .today)
            } else {
                Text("No quiz today. Add one to the queue.")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                QuizQueueView(parent: parent)
            } label: {
                LabeledContent("Quiz queue", value: "\(quizzes.count) of \(queueMax())")
            }
        }
        .onAppear { QuizQueue.refresh(in: context) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { QuizQueue.refresh(in: context) }
        }
    }
}

/// The family quiz queue (requirements §5.4): add, edit, reorder and remove
/// quizzes, and see which is today's and which comes next.
struct QuizQueueView: View {
    let parent: Profile

    @Environment(\.modelContext) private var context
    @Query(queuedQuizzes) private var quizzes: [QuizSet]
    @Query private var records: [QueueRecord]
    @State private var adding = false
    @State private var editing: QuizSet?

    private var todayID: UUID? { records.first?.currentQuizID }
    /// Someone started today's quiz: it can't be changed until tomorrow.
    private var todayLocked: Bool { records.first?.started ?? false }
    private var nextID: UUID? {
        let cycle = queueFromToday(queue: quizzes.map(\.id.uuidString), current: todayID?.uuidString)
        return cycle.count > 1 ? UUID(uuidString: cycle[1]) : nil
    }
    private var isFull: Bool { quizzes.count >= Int(queueMax()) }

    var body: some View {
        List {
            if quizzes.isEmpty {
                ContentUnavailableView {
                    Label("No quizzes yet", systemImage: "list.star")
                } description: {
                    Text("Add a quiz and it becomes today's quiz for the whole family.")
                }
            }
            Section {
                ForEach(quizzes) { quiz in
                    let locked = quiz.id == todayID && todayLocked
                    Button {
                        editing = quiz
                    } label: {
                        QuizRow(quiz: quiz, badge: badge(for: quiz), locked: locked)
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .deleteDisabled(locked)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
                Button {
                    adding = true
                } label: {
                    Label("Add a quiz", systemImage: "plus.circle.fill")
                }
                .disabled(isFull)
            } header: {
                if !quizzes.isEmpty { Text("\(quizzes.count) of \(queueMax()) quizzes") }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Everyone gets the same quiz each day. At 10 pm US Eastern the queue moves on to the next quiz, but only if at least one kid tried today's. After the last quiz it starts again from the top, worth full points.")
                    if todayLocked {
                        Text("Today's quiz has been started, so it can't be changed until tomorrow.")
                    }
                    if isFull { Text("The queue is full. Remove a quiz to add another.") }
                }
            }
        }
        .navigationTitle("Quiz queue")
        .toolbar {
            if quizzes.count > 1 { EditButton() }
        }
        .onAppear { QuizQueue.refresh(in: context) }
        .sheet(isPresented: $adding) {
            QuizEditor(heading: "New quiz", saveTitle: "Add", draft: QuizDraft()) { draft in
                QuizQueue.add(draft, by: parent, in: context)
            }
        }
        .sheet(item: $editing) { quiz in
            QuizEditor(heading: "Edit quiz", saveTitle: "Save", draft: QuizDraft(quiz)) { draft in
                quiz.apply(draft)
                context.saveOrRollback("edit quiz")
            }
        }
    }

    private func badge(for quiz: QuizSet) -> QuizRow.Badge? {
        if quiz.id == todayID { return .today }
        if quiz.id == nextID { return .next }
        return nil
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = quizzes
        ordered.move(fromOffsets: source, toOffset: destination)
        QuizQueue.reorder(ordered, in: context)
    }

    private func delete(at offsets: IndexSet) {
        for quiz in offsets.map({ quizzes[$0] }) where !(quiz.id == todayID && todayLocked) {
            QuizQueue.remove(quiz, in: context)
        }
    }
}

/// One quiz in a list: title, what it covers, and whether it's today's.
struct QuizRow: View {
    enum Badge {
        case today, next

        var text: String { self == .today ? "Today" : "Next" }
        var color: Color { self == .today ? .orange : .blue }
    }

    let quiz: QuizSet
    var badge: Badge?
    var locked = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(quiz.title).font(.headline)
                Text("^[\(quiz.countryIDs.count) country](inflect: true) · \(quiz.questionSummary) · up to \(quiz.maxPoints) points")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if locked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Started today, can't be changed until tomorrow")
            }
            if let badge {
                Text(badge.text)
                    .font(.footnote.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badge.color.opacity(0.18), in: .capsule)
                    .foregroundStyle(badge.color)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// Create or edit a quiz: its name, countries, questions and points.
private struct QuizEditor: View {
    let heading: String
    let saveTitle: String
    let onSave: (QuizDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AtlasStore.self) private var atlasStore
    @State private var draft: QuizDraft
    @State private var pickingOnMap = false

    init(heading: String, saveTitle: String, draft: QuizDraft, onSave: @escaping (QuizDraft) -> Void) {
        self.heading = heading
        self.saveTitle = saveTitle
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    private var regions: [QuizRegion] {
        atlasStore.atlas.map(QuizRegion.all(in:)) ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("For example: South America", text: $draft.title)
                }

                Section {
                    NavigationLink {
                        CountryPicker(regions: regions, selection: $draft.countryIDs)
                    } label: {
                        LabeledContent("Choose countries", value: "\(draft.countryIDs.count) chosen")
                    }
                    Button {
                        pickingOnMap = true
                    } label: {
                        Label("Choose on the map", systemImage: "hand.tap")
                    }
                    .disabled(atlasStore.atlas == nil)
                    Menu {
                        let continents = Dictionary(grouping: regions.filter { !$0.independent.isEmpty }, by: \.continent)
                        ForEach(regions.map(\.continent).uniqued(), id: \.self) { continent in
                            if let inContinent = continents[continent] {
                                Section(continent) {
                                    ForEach(inContinent) { region in
                                        Button("\(region.name) (\(region.independent.count))") { fill(with: region) }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Use a whole region", systemImage: "globe")
                    }
                    if !draft.countryIDs.isEmpty {
                        Text(chosenNames)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Countries")
                } footer: {
                    if regions.isEmpty { Text("The map is still loading…") }
                }

                Section {
                    QuestionToggle(title: "Country name", isOn: $draft.asksName, points: $draft.namePoints)
                    QuestionToggle(title: "Capital", isOn: $draft.asksCapital, points: $draft.capitalPoints)
                    LabeledContent("Flag", value: "Coming soon")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Questions for each country")
                } footer: {
                    Text("Points are for a right answer the first time a quiz is taken. A second try that day is worth half, a third a quarter.")
                }

                if draft.isValid {
                    Section {
                        LabeledContent("Most a kid can earn", value: "\(maxPoints) points")
                    }
                }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $pickingOnMap) {
                if let atlas = atlasStore.atlas {
                    MapCountryPicker(atlas: atlas, selection: $draft.countryIDs)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        var saved = draft
                        saved.title = draft.trimmedTitle
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }

    private var maxPoints: Int {
        draft.countryIDs.count * ((draft.asksName ? draft.namePoints : 0)
            + (draft.asksCapital ? draft.capitalPoints : 0))
    }

    /// "France, Italy, Spain and 9 more".
    private var chosenNames: String {
        let chosen = Set(draft.countryIDs)
        let names = regions.flatMap(\.countries).filter { chosen.contains($0.meta.id) }.map(\.name).sorted()
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(shown) and \(names.count - 6) more" : shown
    }

    private func fill(with region: QuizRegion) {
        draft.countryIDs = region.independent.map(\.meta.id)
        if draft.trimmedTitle.isEmpty { draft.title = region.name }
    }
}

private struct QuestionToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var points: Int

    var body: some View {
        Toggle(title, isOn: $isOn)
        if isOn {
            Stepper(value: $points, in: QuizDraft.pointsRange, step: 5) {
                Text("^[\(points) point](inflect: true) each")
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
        }
    }
}

/// A part of the world a quiz can be built from: quiz-sized groups of at
/// most 14 countries ("Balkans", "Caribbean"), set in the country data
/// (tools/build-countries.py REGIONS), listed by continent.
struct QuizRegion: Identifiable {
    let name: String
    let continent: String
    /// Every place in the region that has a country card, by name.
    let countries: [AtlasCountry]

    var id: String { name }
    /// Self-governing countries only: what "the whole region" means.
    var independent: [AtlasCountry] { countries.filter { $0.facts?.independent == true } }

    private static let continentOrder = ["Africa", "North America", "South America", "Asia", "Europe", "Oceania"]

    static func all(in atlas: Atlas) -> [QuizRegion] {
        let quizzable = atlas.countries.filter { $0.facts != nil }
        let grouped = Dictionary(grouping: quizzable) { $0.facts!.region }
        return grouped.map { name, members in
            // The continent most of its countries are on (the Caribbean's
            // islands are all North America; Antarctica stays last).
            let continents = Dictionary(grouping: members, by: \.meta.continent)
            let continent = continents.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }!.key
            return QuizRegion(name: name, continent: continent,
                              countries: members.sorted { $0.name < $1.name })
        }
        .sorted {
            let rank = { (r: QuizRegion) in continentOrder.firstIndex(of: r.continent) ?? continentOrder.count }
            return (rank($0), $0.name) < (rank($1), $1.name)
        }
    }
}

/// Pick any set of countries: searchable, grouped by region, with an
/// "all / none" button per region. Territories are hidden unless asked for.
private struct CountryPicker: View {
    let regions: [QuizRegion]
    @Binding var selection: [String]

    @State private var search = ""
    @State private var showTerritories = false

    private var chosen: Set<String> { Set(selection) }

    private func visible(in region: QuizRegion) -> [AtlasCountry] {
        let pool = showTerritories ? region.countries : region.independent
        guard !search.isEmpty else { return pool }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Show territories too", isOn: $showTerritories)
            } footer: {
                Text("Places like Greenland, Puerto Rico and Hong Kong.")
            }
            ForEach(regions) { region in
                let countries = visible(in: region)
                if !countries.isEmpty {
                    Section {
                        ForEach(countries) { country in
                            Button {
                                toggle(country.meta.id)
                            } label: {
                                CountryPickerRow(country: country, isChosen: chosen.contains(country.meta.id))
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(region.name)
                            Spacer()
                            let all = countries.allSatisfy { chosen.contains($0.meta.id) }
                            Button(all ? "None" : "All") { set(countries, chosen: !all) }
                                .font(.subheadline.bold())
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Find a country")
        .navigationTitle("\(selection.count) chosen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selection.isEmpty {
                Button("Clear") { selection = [] }
            }
        }
        .onAppear {
            // Don't hide something that's already chosen.
            let independent = Set(regions.flatMap(\.independent).map(\.meta.id))
            if !chosen.isSubset(of: independent) { showTerritories = true }
        }
    }

    private func toggle(_ id: String) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
    }

    private func set(_ countries: [AtlasCountry], chosen makeChosen: Bool) {
        let ids = countries.map(\.meta.id)
        selection.removeAll { ids.contains($0) }
        if makeChosen { selection.append(contentsOf: ids) }
    }
}

private struct CountryPickerRow: View {
    let country: AtlasCountry
    let isChosen: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let flag = country.flagAsset {
                Image(flag)
                    .resizable()
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(width: 40)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.15)))
                    .accessibilityHidden(true)
            }
            Text(country.name)
            Spacer()
            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isChosen ? Color.accentColor : Color(uiColor: .tertiaryLabel))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each kept only the first time it appears.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Choose a quiz's countries by tapping them on the map: handy for a few
/// neighbours ("the Benelux", "around Lake Victoria"). Country names are
/// shown here (it's the parent's map), chosen countries are tinted teal.
private struct MapCountryPicker: View {
    let atlas: Atlas
    @Binding var selection: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var camera = MapCamera()
    @State private var noSelection: AtlasCountry?
    @State private var cardSide = false
    @State private var topBarBottom: CGFloat = 96

    private var chosen: Set<UInt32> {
        let ids = Set(selection)
        return Set(atlas.countries.filter { ids.contains($0.meta.id) }.map(\.id))
    }

    var body: some View {
        ZStack(alignment: .top) {
            WorldMapView(
                atlas: atlas, camera: $camera, selection: $noSelection,
                cardOnLeadingSide: $cardSide,
                insets: MapInsets(top: topBarBottom + 8),
                chosen: chosen,
                onPick: toggle,
                showsCountryNames: true
            )
            .ignoresSafeArea()

            HStack(spacing: 14) {
                Text("Tap countries to add or remove them")
                    .font(.headline)
                Spacer()
                Text("\(selection.count) chosen")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .padding(20)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                topBarBottom = $0
            }
        }
    }

    private func toggle(_ country: AtlasCountry) {
        // Only places with a country card can be quizzed.
        guard country.facts != nil else { return }
        let id = country.meta.id
        withAnimation(.snappy) {
            if let index = selection.firstIndex(of: id) {
                selection.remove(at: index)
            } else {
                selection.append(id)
            }
        }
    }
}
