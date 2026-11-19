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
                // Parents take the same quiz as the kids (§3.8); their
                // sittings never move the queue on.
                TodayQuizButton(profile: parent, prominent: false)
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
    @State private var editRefused = false
    @State private var swapRefused = false
    @State private var confirmingShuffle = false

    private var todayID: UUID? { records.first?.currentQuizID }
    /// A kid answered in today's quiz: it can't be changed until the queue moves on.
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
                    .swipeActions(edge: .leading) {
                        if quiz.id != todayID && !todayLocked {
                            Button("Make today's", systemImage: "star.fill") {
                                if !QuizQueue.makeToday(quiz, in: context) { swapRefused = true }
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        if quiz.id != todayID && !todayLocked {
                            Button("Make today's quiz", systemImage: "star.fill") {
                                if !QuizQueue.makeToday(quiz, in: context) { swapRefused = true }
                            }
                        }
                    }
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
                    Text("Everyone gets the same quiz each day. At 11 pm US Eastern the queue moves on to the next quiz, but only if at least one kid tried today's. After the last quiz it starts again from the top, worth full points.")
                    if todayLocked {
                        Text("A kid has answered today's quiz, so it can't be changed or removed until the queue moves on.")
                    } else if quizzes.count > 1 {
                        Text("Until a kid answers a question, you can edit or remove today's quiz, or swipe right on another quiz to make it today's.")
                    }
                    if isFull { Text("The queue is full. Remove a quiz to add another.") }
                }
            }
        }
        .navigationTitle("Quiz queue")
        .toolbar {
            if quizzes.count > 2 {
                Button("Shuffle", systemImage: "shuffle") { confirmingShuffle = true }
            }
            if quizzes.count > 1 { EditButton() }
        }
        .confirmationDialog("Shuffle the queue?", isPresented: $confirmingShuffle, titleVisibility: .visible) {
            Button("Shuffle") { QuizQueue.shuffle(in: context) }
        } message: {
            Text("The quizzes go in a random order. Today's quiz stays today's.")
        }
        .onAppear { QuizQueue.refresh(in: context) }
        .sheet(isPresented: $adding) {
            QuizEditor(heading: "New quiz", saveTitle: "Add", draft: QuizDraft()) { draft in
                QuizQueue.add(draft, by: parent, in: context)
            }
        }
        .sheet(item: $editing) { quiz in
            QuizEditor(heading: "Edit quiz", saveTitle: "Save", draft: QuizDraft(quiz)) { draft in
                // Checked again here: a kid may have started it while the
                // editor was open.
                if !QuizQueue.edit(quiz, to: draft, in: context) { editRefused = true }
            }
        }
        .alert("A kid just started today's quiz", isPresented: $swapRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Today's quiz can't be swapped once a kid has answered a question. It moves on at 11 pm US Eastern.")
        }
        .alert("Today's quiz was just started", isPresented: $editRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A kid answered a question while you were editing, so your changes weren't saved. You can change it once the queue moves on.")
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

    @Environment(AtlasStore.self) private var atlasStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(quiz.title).font(.headline)
                Text("^[\(quiz.countryIDs.count) country](inflect: true) · \(quiz.questionSummary) · \(quiz.perfectPoints(in: atlasStore.atlas)) points for a perfect first try")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if locked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Started by a kid, can't be changed until the queue moves on")
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
                    NavigationLink {
                        RegionPicker(regions: regions, selection: $draft.countryIDs, title: $draft.title)
                    } label: {
                        Label("Use whole regions", systemImage: "globe")
                    }
                    NavigationLink {
                        RandomQuizPicker(regions: regions, selection: $draft.countryIDs, title: $draft.title)
                    } label: {
                        Label("Pick at random", systemImage: "dice")
                    }
                    .disabled(regions.isEmpty)
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
                    QuestionToggle(title: "Flag", isOn: $draft.asksFlag, points: $draft.flagPoints,
                                   note: "For drawing it (a mirror image earns ¾, the right colours in the wrong places ½). Picking it from four flags instead earns half (\(QuizScoring.firstTry(base: draft.flagPoints, multipleChoice: true))).")
                } header: {
                    Text("Questions for each country")
                } footer: {
                    Text("Points are for a right answer on the first try. Each time a quiz comes up in the queue, a second try is worth three quarters, a third half, and after that it's just for fun. A right answer always earns at least 1 point.")
                }

                if draft.isValid {
                    Section {
                        LabeledContent("Points for a perfect first try", value: "\(maxPoints) points")
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

    /// Counts only questions really asked (no capital question for a place
    /// without a capital, no flag question for one without a flag picture).
    private var maxPoints: Int {
        guard let atlas = atlasStore.atlas else { return 0 }
        let draft = draft
        return QuizTarget.all(countryIDs: draft.countryIDs, asks: draft.asks, in: atlas).reduce(0) { total, target in
            total + target.kinds.reduce(0) {
                $0 + QuizScoring.best($1, base: draft.basePoints(for: $1), country: target.country)
            }
        }
    }

    /// "France, Italy, Spain and 9 more".
    private var chosenNames: String {
        let chosen = Set(draft.countryIDs)
        let names = regions.flatMap(\.countries).filter { chosen.contains($0.meta.id) }.map(\.name).sorted()
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(shown) and \(names.count - 6) more" : shown
    }

}

private struct QuestionToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var points: Int
    var note: String?

    var body: some View {
        Toggle(title, isOn: $isOn)
        if isOn {
            Stepper(value: $points, in: QuizDraft.pointsRange, step: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("^[\(points) point](inflect: true) each")
                        .foregroundStyle(.secondary)
                    if let note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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

/// A random quiz (beta feedback): how many countries, and from where (one
/// region, one continent, or anywhere). The picking is the Rust core's
/// `random_quiz`; "Pick again" rolls a new set.
private struct RandomQuizPicker: View {
    let regions: [QuizRegion]
    @Binding var selection: [String]
    @Binding var title: String

    @State private var count = 10
    @State private var scope: RandomQuizScope = .region
    /// The name this screen last gave the quiz, so rolling again can rename
    /// it, but a name the parent typed is kept.
    @State private var givenTitle: String?

    private static let scopes: [(RandomQuizScope, String)] = [
        (.region, "Neighbours"), (.continent, "One continent"), (.world, "Anywhere"),
    ]

    private var candidates: [QuizCandidate] {
        regions.flatMap { region in
            region.independent.map { QuizCandidate(id: $0.meta.id, region: region.name, continent: region.continent) }
        }
    }

    private var chosen: [AtlasCountry] {
        var left = Set(selection)
        return regions.flatMap(\.countries).filter { left.remove($0.meta.id) != nil }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Form {
            Section {
                Stepper("^[\(count) country](inflect: true)", value: $count, in: 1...40)
                Picker("From", selection: $scope) {
                    ForEach(Self.scopes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(scopeNote)
            }
            Section {
                Button(selection.isEmpty || givenTitle == nil ? "Pick countries" : "Pick again", systemImage: "dice") {
                    roll()
                }
            }
            if givenTitle != nil, !chosen.isEmpty {
                Section("^[\(chosen.count) country](inflect: true)") {
                    Text(chosen.map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Random quiz")
    }

    private var scopeNote: String {
        switch scope {
        case .region: "All from one region, picked at random: countries next to each other."
        case .continent: "All from one continent, picked at random."
        case .world: "From anywhere in the world."
        }
    }

    private func roll() {
        let quiz = randomQuiz(candidates: candidates, count: UInt32(count), scope: scope,
                              seed: .random(in: .min ... .max))
        selection = quiz.countryIds
        let name = "Random: " + (quiz.area ?? "the world")
        let typed = title.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || typed == givenTitle { title = name }
        givenTitle = name
    }
}

/// Pick any set of countries: searchable, grouped by region, with an
/// "all / none" button per region. Territories are hidden unless asked for.
/// Pick one or more whole regions ("Polynesia" + "Melanesia"); ticking a
/// region adds its self-governing countries, unticking removes them.
/// Countries picked another way are left alone.
private struct RegionPicker: View {
    let regions: [QuizRegion]
    @Binding var selection: [String]
    @Binding var title: String

    private func isOn(_ region: QuizRegion) -> Bool {
        let ids = Set(selection)
        return !region.independent.isEmpty && region.independent.allSatisfy { ids.contains($0.meta.id) }
    }

    private var chosenRegions: [QuizRegion] { regions.filter(isOn) }

    private func toggle(_ region: QuizRegion) {
        let ids = region.independent.map(\.meta.id)
        if isOn(region) {
            selection.removeAll { ids.contains($0) }
        } else {
            for id in ids where !selection.contains(id) { selection.append(id) }
        }
    }

    var body: some View {
        List {
            ForEach(regions.map(\.continent).uniqued(), id: \.self) { continent in
                let inContinent = regions.filter { $0.continent == continent && !$0.independent.isEmpty }
                if !inContinent.isEmpty {
                    Section(continent) {
                        ForEach(inContinent) { region in
                            Button {
                                toggle(region)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(region.name).foregroundStyle(.primary)
                                        Text("^[\(region.independent.count) country](inflect: true)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: isOn(region) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isOn(region) ? Color.accentColor : .secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isOn(region) ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .navigationTitle("Whole regions")
        .safeAreaInset(edge: .bottom) {
            Text("^[\(selection.count) country](inflect: true) chosen")
                .font(.headline)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .onDisappear {
            // Name the quiz after the regions if the parent hasn't named it.
            let names = chosenRegions.map(\.name)
            if title.trimmingCharacters(in: .whitespaces).isEmpty, !names.isEmpty {
                title = ListFormatter.localizedString(byJoining: names)
            }
        }
    }
}

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
    /// Why the last tap did nothing, shown briefly in the bar.
    @State private var notice: String?

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
                Text(notice ?? "Tap countries to add or remove them")
                    .font(.headline)
                    .foregroundStyle(notice == nil ? Color.primary : QuizColor.points)
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
        // Only places with a country card can be quizzed; say so, or the
        // parent would think the tap missed.
        guard country.facts != nil else {
            notice = "\(country.name) can't be in a quiz"
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                notice = nil
            }
            return
        }
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
