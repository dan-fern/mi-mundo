import MiMundoCore
import SwiftData
import SwiftUI

/// Colours for quiz text and buttons, dark enough for white text and for
/// text on the light material (WCAG AA): plain `.orange` and `.green` aren't.
enum QuizColor {
    static let points = Color(red: 0.70, green: 0.35, blue: 0.0)
    static let button = Color(red: 0.72, green: 0.36, blue: 0.0)
    static let right = Color(red: 0.08, green: 0.48, blue: 0.20)
    static let wrong = Color(red: 0.76, green: 0.18, blue: 0.14)
}

/// Playing today's quiz (requirements §3.2): the map zooms to the quiz's
/// countries, the player taps them in any order and answers pick-from-four
/// questions about each. One try per question; the right answer is shown
/// either way. Kids and parents play the same screen.
struct QuizPlayView: View {
    let quiz: QuizSet
    let profile: Profile

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AtlasStore.self) private var atlasStore

    @State private var attempt: QuizAttempt?
    @State private var targets: [QuizTarget] = []
    @State private var nothingToAsk = false
    /// What has been answered this sitting: country → kind → was it right.
    @State private var answered: [UInt32: [QuestionKind: Bool]] = [:]
    @State private var points = 0
    @State private var question: ActiveQuestion?
    /// After a wrong name answer: the country that was picked, shown on the
    /// map until Next, so the kid sees where it really is.
    @State private var wrongPick: UInt32?
    @State private var camera = MapCamera()
    @State private var fit: MapFit?
    @State private var cardOnLeadingSide = false
    /// Card frames by question, so an outgoing card can't leave its frame
    /// behind as the "keep labels away from here" rect.
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var topBarBottom: CGFloat = 96
    @State private var viewSize: CGSize = .zero
    @State private var showingSummary = false
    @State private var confirmingStop = false
    @State private var saveFailed = false
    /// The full-screen pad for drawing a flag freehand.
    @State private var drawingPad = false
    /// Once the player uses a read-aloud button, verdicts are read too.
    @State private var readingAloud = false
    @State private var speaker = CardSpeaker()
    @AccessibilityFocusState private var promptFocused: Bool

    /// A question on screen: its buttons, and the pick once made.
    struct ActiveQuestion: Equatable {
        let target: UInt32
        let kind: QuestionKind
        let correct: String
        let choices: [String]
        /// Which country each button stands for (stats: "confused with").
        let countryIDs: [String: String]
        /// Each answer's country name: flag answers are country codes.
        let names: [String: String]
        /// Each answer's flag picture, for flag questions.
        let flags: [String: String]
        /// The flag's outline (§3.3), if it has one, with the layouts
        /// offered when drawing on it.
        var outline: FlagOutlineSpec? = nil
        var layoutChoices: [String] = []
        /// How a flag question is being answered. It starts freehand; help
        /// steps down to the outline (still full points), then to picking
        /// from four (half points).
        var flagMode: FlagMode = .freehand
        /// The checked outline drawing, once drawn.
        var drawing: FlagDrawResult? = nil
        /// The checked freehand drawing, once drawn.
        var freehand: FreehandResult? = nil
        let askedAt: Date
        /// The side its card opens on, kept with it so the card leaves the
        /// way it came even if the next card opens on the other side.
        let leading: Bool
        var picked: String?
        var earned = 0

        var key: String { "\(target)-\(kind.rawValue)" }

        var isDrawing: Bool { kind == .flag && flagMode == .outline && outline != nil }
        var isFreehand: Bool { kind == .flag && flagMode == .freehand }
        /// Right, by the grader for a drawing, else by the button picked.
        var isRight: Bool { freehand?.grade.correct ?? drawing?.grade.correct ?? (picked == correct) }
    }

    enum FlagMode: Equatable {
        case freehand, outline, choices
    }

    var body: some View {
        ZStack {
            if let atlas = atlasStore.atlas {
                map(atlas)
            } else {
                ProgressView("Unrolling the map…").font(.title3)
            }

            VStack {
                topBar
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        topBarBottom = $0
                    }
                Spacer()
            }
            .padding(20)

            if let question, let target = targets.first(where: { $0.id == question.target }) {
                HStack {
                    if !question.leading { Spacer() }
                    VStack {
                        Spacer(minLength: topBarBottom)
                        QuestionCard(
                            country: target.country, question: question,
                            isLastForCountry: pendingKinds(for: target).isEmpty,
                            showsFlag: !quiz.asksFlag, speaker: speaker, promptFocused: $promptFocused,
                            onSpeak: { readingAloud = true }, onPick: choose, onNext: next,
                            onDrawn: drawn, onUseChoices: useChoices,
                            onUseOutline: useOutline, onStartDrawing: { drawingPad = true }
                        )
                        .id(question.key)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            cardFrames[question.key] = frame
                        }
                        .transition(reduceMotion ? .opacity
                            : .move(edge: question.leading ? .leading : .trailing).combined(with: .opacity))
                    }
                    if question.leading { Spacer() }
                }
                .padding(.vertical, 20)
                .padding(.leading, question.leading ? 100 : 20)
                .padding(.trailing, 20)
            }

            if nothingToAsk {
                NothingToAsk { dismiss() }
            }

            if showingSummary, let attempt {
                Color.black.opacity(0.35).ignoresSafeArea()
                QuizSummary(quizTitle: quiz.title, attemptNumber: attempt.number,
                            correct: correctCount, total: totalQuestions,
                            countries: targets.count, points: points, speaker: speaker,
                            readAloud: readingAloud) {
                    dismiss()
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .background(MapCanvas.space)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .onAppear(perform: start)
        .onChange(of: atlasStore.atlas == nil) { _, _ in start() }
        .onDisappear { speaker.stop() }
        .alert("That answer didn't save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try it again.")
        }
        .fullScreenCover(isPresented: $drawingPad) {
            if let asked = question, let target = targets.first(where: { $0.id == asked.target }) {
                FreehandPad(country: target.country, spec: asked.outline, onCheck: drew,
                            onCancel: { drawingPad = false })
            }
        }
    }

    // MARK: Map

    private func map(_ atlas: Atlas) -> some View {
        let current = question.flatMap { q in targets.first { $0.id == q.target }?.country }
        let avoid = question.flatMap { cardFrames[$0.key] }.map { [$0] } ?? []
        return WorldMapView(
            atlas: atlas, camera: $camera, selection: .constant(current),
            cardOnLeadingSide: $cardOnLeadingSide,
            insets: MapInsets(top: topBarBottom + 8, avoid: avoid),
            labelMode: .quiz(targets: Set(targets.map(\.id)), revealed: revealed),
            onPick: { country in tapped(country) },
            namedCountries: named,
            marks: marks,
            fit: fit,
            quizTargets: Set(targets.filter { !isDone($0) }.map(\.id)),
            quizHighlight: true,
            accessibilityHintText: "A quiz map. Use Find one for me to pick the next country, or tap a country with a blue border."
        )
        .ignoresSafeArea()
    }

    private var marks: [UInt32: QuizMark] {
        var marks = Dictionary(uniqueKeysWithValues: targets.map { target in
            guard isDone(target) else { return (target.id, QuizMark.todo) }
            let allRight = answered[target.id]?.values.allSatisfy { $0 } ?? false
            return (target.id, allRight ? QuizMark.right : .missed)
        })
        if let wrongPick, marks[wrongPick] == nil { marks[wrongPick] = .missed }
        return marks
    }

    /// Countries whose river, lake and landmark names may show: finished,
    /// and named correctly (or never asked for their name).
    private var revealed: Set<UInt32> {
        Set(targets.filter { isDone($0) && answered[$0.id]?[.name] != false }.map(\.id))
    }

    /// Countries whose own name is drawn: once the name question is behind
    /// them (or straight away if the quiz doesn't ask for names), plus a
    /// wrongly picked country while its mistake is on screen.
    private var named: Set<UInt32> {
        var named = Set(targets.filter { !$0.kinds.contains(.name) || answered[$0.id]?[.name] != nil }.map(\.id))
        if let wrongPick { named.insert(wrongPick) }
        return named
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                if remaining == 0 { dismiss() } else { confirmingStop = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.bold())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Stop the quiz")
            .confirmationDialog("Stop now?", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("Stop for now") { dismiss() }
            } message: {
                Text("Your answers are saved. You can finish later.")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title).font(.title3.bold()).lineLimit(1)
                Text(remaining == 0 ? "All done!" : "^[\(remaining) country](inflect: true) left")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Label("\(points)", systemImage: "star.fill")
                .font(.title3.bold())
                .foregroundStyle(QuizColor.points)
                .contentTransition(.numericText())
                .accessibilityLabel("\(points) points")

            Spacer(minLength: 8)

            if remaining > 0, question == nil {
                Button(action: findOne) {
                    Label("Find one for me", systemImage: "scope")
                        .font(.headline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Picks the next country to answer")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: State

    private func pendingKinds(for target: QuizTarget) -> [QuestionKind] {
        target.kinds.filter { answered[target.id]?[$0] == nil }
    }

    private func isDone(_ target: QuizTarget) -> Bool {
        pendingKinds(for: target).isEmpty
    }

    private var remaining: Int { targets.count { !isDone($0) } }
    private var totalQuestions: Int { targets.reduce(0) { $0 + $1.kinds.count } }
    private var correctCount: Int { answered.values.reduce(0) { $0 + $1.values.count { $0 } } }

    private func start() {
        guard attempt == nil, !nothingToAsk, let atlas = atlasStore.atlas else { return }
        targets = QuizTarget.all(for: quiz, in: atlas)
        guard !targets.isEmpty else {
            nothingToAsk = true // nothing is created, nothing is locked
            return
        }
        guard let attempt = QuizPlay.begin(quiz, targets: targets, for: profile, in: context) else {
            dismiss() // no longer today's quiz
            return
        }
        self.attempt = attempt
        // Carry on a sitting that was left part-way.
        let attemptID = attempt.id
        let earlier = (try? context.fetch(FetchDescriptor<QuizAnswer>(
            predicate: #Predicate { $0.attemptID == attemptID }))) ?? []
        let idOf = Dictionary(targets.map { ($0.country.meta.id, $0.id) }, uniquingKeysWith: { a, _ in a })
        for answer in earlier {
            guard let id = idOf[answer.countryID], let kind = answer.kind else { continue }
            answered[id, default: [:]][kind] = answer.correct
            points += answer.pointsAwarded
        }
        if let bounds = Self.bounds(of: targets.map(\.country)) {
            fit = MapFit(rect: bounds)
        }
        if remaining == 0 { finish() }
    }

    /// Box around some countries' main landmasses (France without French
    /// Guiana and Réunion, Russia without the far side of the ±180° line).
    private static func bounds(of countries: [AtlasCountry]) -> CGRect? {
        countries.map(\.mainBounds).reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func tapped(_ country: AtlasCountry) {
        // A question waiting for an answer can be swapped for another
        // country; one showing its result is finished with "Next" first.
        if let question, question.picked != nil { return }
        guard let target = targets.first(where: { $0.id == country.id }), !isDone(target) else { return }
        ask(target)
    }

    private func ask(_ target: QuizTarget) {
        guard let atlas = atlasStore.atlas, let attempt,
              let kind = pendingKinds(for: target).first else { return }
        speaker.stop()
        // Same seed every time this question comes up in this sitting, so
        // leaving and coming back can't re-roll the wrong answers.
        let seed = QuestionSeed.make(attempt: attempt.id, country: target.country.meta.id, kind: kind)
        let answeredIDs = Set(targets.filter { answered[$0.id]?[.name] != nil }.map(\.id))
        let made = atlas.choices(for: kind, about: target.country, excluding: answeredIDs, seed: seed)
        var asked = ActiveQuestion(target: target.id, kind: kind, correct: made.correct, choices: made.all,
                                   countryIDs: made.countries.mapValues(\.meta.id),
                                   names: made.countries.mapValues(\.name),
                                   flags: made.countries.compactMapValues(\.flagAsset), askedAt: .now,
                                   leading: cardOnLeadingSide)
        if kind == .flag, let spec = FlagOutlines.spec(for: target.country) {
            asked.outline = spec
            asked.layoutChoices = flagLayoutChoices(correct: spec.layout, seed: seed)
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { question = asked }
        promptFocused = true
    }

    /// Help: the same question, picked from four (half points).
    private func useChoices() { setFlagMode(.choices) }

    /// Help: the same question, drawn on an outline (still full points).
    private func useOutline() { setFlagMode(.outline) }

    private func setFlagMode(_ mode: QuizPlayView.FlagMode) {
        guard var asked = question, asked.picked == nil else { return }
        asked.flagMode = mode
        withAnimation(reduceMotion ? nil : .snappy) { question = asked }
    }

    /// A checked freehand drawing: recorded with its grade, at full points.
    private func drew(_ result: FreehandResult) {
        drawingPad = false
        choose("freehand:\(result.grade.scorePercent)%", drawing: nil, freehand: result, correctAnswer: "freehand")
    }

    /// A checked flag drawing: recorded with its grade, at full points.
    private func drawn(_ result: FlagDrawResult) {
        guard let outline = question?.outline else { return }
        choose(FlagOutlines.summary(layout: result.layout, colors: result.painted),
               drawing: result, freehand: nil, correctAnswer: FlagOutlines.summary(layout: outline.layout, colors: outline.colors))
    }

    private func choose(_ choice: String) {
        choose(choice, drawing: nil, freehand: nil, correctAnswer: nil)
    }

    private func choose(_ choice: String, drawing: FlagDrawResult?, freehand: FreehandResult?,
                        correctAnswer: String?) {
        guard var asked = question, asked.picked == nil, let attempt, let atlas = atlasStore.atlas,
              let target = targets.first(where: { $0.id == asked.target }) else { return }
        speaker.stop()
        let drawn = drawing != nil || freehand != nil
        let chosenCountry = !drawn
            ? asked.countryIDs[choice].flatMap { id in atlas.countries.first { $0.meta.id == id } }
            : nil
        // Name and capital buttons have always been full points; a flag
        // picked from four is the half-points help (§3.3).
        let multipleChoice = asked.kind == .flag && !drawn
        guard let saved = QuizPlay.record(choice, correctAnswer: correctAnswer ?? asked.correct, kind: asked.kind,
                                          country: target.country, chosenCountry: chosenCountry,
                                          choices: drawing != nil ? asked.layoutChoices : (drawn ? [] : asked.choices),
                                          multipleChoice: multipleChoice,
                                          isCorrect: freehand?.grade.correct ?? drawing?.grade.correct,
                                          quiz: quiz, attempt: attempt,
                                          askedAt: asked.askedAt, in: context) else {
            saveFailed = true // nothing changes: the question can be answered again
            return
        }
        asked.picked = choice
        asked.drawing = drawing
        asked.freehand = freehand
        asked.earned = saved.pointsAwarded
        let right = asked.isRight
        withAnimation(reduceMotion ? nil : .snappy) {
            question = asked
            answered[target.id, default: [:]][asked.kind] = right
            points += asked.earned
            // Show where the wrong pick is: the country tapped by name, or
            // the country whose flag was picked.
            if !right, asked.kind != .capital, let chosenCountry, chosenCountry.id != target.id {
                wrongPick = chosenCountry.id
            }
        }
        let verdict = right
            ? (asked.earned > 0 ? "Yes! \(asked.earned) points." : "Yes!")
            : QuestionCard.missed(asked, country: target.country)
        if readingAloud { speaker.say([verdict]) }
        AccessibilityNotification.Announcement(verdict).post()
    }

    private func next() {
        // Only from an answered question: a second tap on Next while the
        // card changes must not draw a new question.
        guard let asked = question, asked.picked != nil,
              let target = targets.first(where: { $0.id == asked.target }) else { return }
        speaker.stop()
        wrongPick = nil
        if !isDone(target) {
            ask(target) // its next question (the capital)
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { question = nil }
        if remaining == 0 { finish() }
    }

    private func finish() {
        if let attempt { QuizPlay.finish(attempt, in: context) }
        if let bounds = Self.bounds(of: targets.map(\.country)) {
            fit = MapFit(rect: bounds, token: (fit?.token ?? 0) + 1)
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { showingSummary = true }
    }

    /// Jumps to a country still to do: the one nearest the middle of the
    /// view. Tiny islands and city states are hard to find and to tap. The
    /// card then opens on the side away from where the country lands.
    private func findOne() {
        let pending = targets.filter { !isDone($0) }
        let center = camera.center
        let distance = { (t: QuizTarget) -> CGFloat in
            hypot(t.country.mainBounds.midX - center.x, t.country.mainBounds.midY - center.y)
        }
        guard let nearest = pending.min(by: { distance($0) < distance($1) }),
              let atlas = atlasStore.atlas else { return }
        let bounds = nearest.country.mainBounds
        // Room around it to see its neighbours: a big country fills most
        // of the view, a tiny one sits in a small region around it.
        let side = max(max(bounds.width, bounds.height) * 1.6, 0.35)
        let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if viewSize != .zero {
            let layout = MapLayout(atlas: atlas, size: viewSize, insets: MapInsets(top: topBarBottom + 8))
            let landed = CGPoint(x: bounds.midX, y: bounds.midY)
                .applying(layout.mapToScreen(layout.camera(fitting: rect)))
            cardOnLeadingSide = landed.x > viewSize.width / 2
        }
        fit = MapFit(rect: rect, token: (fit?.token ?? 0) + 1)
        ask(nearest)
    }
}

/// One question: what's asked, four big answers (each can be read aloud),
/// then the verdict and a Next button.
private struct QuestionCard: View {
    let country: AtlasCountry
    let question: QuizPlayView.ActiveQuestion
    let isLastForCountry: Bool
    /// The flag gives the answer away once flag questions exist (§3.3).
    let showsFlag: Bool
    let speaker: CardSpeaker
    var promptFocused: AccessibilityFocusState<Bool>.Binding
    let onSpeak: () -> Void
    let onPick: (String) -> Void
    let onNext: () -> Void
    let onDrawn: (FlagDrawResult) -> Void
    let onUseChoices: () -> Void
    let onUseOutline: () -> Void
    let onStartDrawing: () -> Void

    private var prompt: String {
        switch question.kind {
        case .name: "Which country is this?"
        case .capital: "What is the capital of \(country.name)?"
        case .flag: question.flagMode == .choices || (question.flagMode == .outline && question.outline == nil)
            ? "Which flag belongs to \(country.name)?" : "Draw the flag of \(country.name)!"
        }
    }

    /// What a wrong answer hears: the right answer, in words.
    static func missed(_ question: QuizPlayView.ActiveQuestion, country: AtlasCountry) -> String {
        if let freehand = question.freehand {
            let missing = freehand.grade.missingColours.map(FlagPaint.spoken)
            return missing.isEmpty
                ? "Good try! Some parts are different. Here's the flag of \(country.name)."
                : "Good try! It needs \(ListFormatter.localizedString(byJoining: missing)) too. Here's the flag of \(country.name)."
        }
        if let drawing = question.drawing {
            return drawing.grade.layoutRight
                ? "Good try! Some colours are different. Here's the flag of \(country.name)."
                : "Good try! Its shape is different. Here's the flag of \(country.name)."
        }
        guard question.kind == .flag else { return "Good try! It's \(question.correct)." }
        let picked = question.picked.flatMap { question.names[$0] }
        return picked.map { "Good try! That's the flag of \($0)." } ?? "Good try!"
    }

    /// Flags are read out by number: their names would give the answer.
    private var spokenChoices: [String] {
        question.kind == .flag ? [] : question.choices.map { $0 + "." }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    SpeakButton(label: "Read the question") {
                        onSpeak()
                        speaker.say([prompt] + spokenChoices)
                    }
                    if showsFlag, question.kind == .capital, let flag = country.flagAsset {
                        Image(flag)
                            .resizable()
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .frame(width: 72)
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.15)))
                            .accessibilityHidden(true)
                    }
                    Text(prompt)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused(promptFocused)
                    Spacer(minLength: 0)
                }

                if question.isFreehand {
                    FreehandPanel(country: country, result: question.freehand, hasOutline: question.outline != nil,
                                  onStart: onStartDrawing, onUseOutline: onUseOutline, onUseChoices: onUseChoices)
                } else if question.isDrawing, let outline = question.outline {
                    FlagDrawingPanel(country: country, spec: outline, layoutChoices: question.layoutChoices,
                                     result: question.drawing, onCheck: onDrawn, onUseChoices: onUseChoices)
                } else if question.kind == .flag {
                    flagGrid
                } else {
                    wordChoices
                }

                if let picked = question.picked {
                    verdict(picked)
                    Button(action: onNext) {
                        Text(isLastForCountry ? "Done" : "Next question")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Four flags, two by two. Once answered, each shows whose it is.
    private var flagGrid: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(Array(stride(from: 0, to: question.choices.count, by: 2)), id: \.self) { row in
                GridRow {
                    ForEach(question.choices[row..<min(row + 2, question.choices.count)], id: \.self) { choice in
                        let number = (question.choices.firstIndex(of: choice) ?? 0) + 1
                        Button {
                            onPick(choice)
                        } label: {
                            FlagChoice(asset: question.flags[choice], number: number,
                                       name: question.names[choice] ?? "", state: state(of: choice))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(question.picked == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var wordChoices: some View {
        ForEach(question.choices, id: \.self) { choice in
            // The speaker sits on the leading side, well away from
            // the answer, so reaching for it can't pick an answer.
            HStack(spacing: 22) {
                SpeakButton(label: "Read \(choice)") {
                    onSpeak()
                    speaker.say([choice])
                }
                Button {
                    onPick(choice)
                } label: {
                    ChoiceLabel(text: choice, state: state(of: choice))
                }
                .buttonStyle(.plain)
                // Not .disabled: that would grey out the green and
                // red verdict colours.
                .allowsHitTesting(question.picked == nil)
            }
        }
    }

    private func state(of choice: String) -> ChoiceLabel.State {
        guard let picked = question.picked else { return .open }
        if choice == question.correct { return .right }
        return choice == picked ? .wrong : .faded
    }

    @ViewBuilder
    private func verdict(_ picked: String) -> some View {
        let right = question.isRight
        HStack(spacing: 10) {
            Image(systemName: right ? "checkmark.circle.fill" : "lightbulb.fill")
                .font(.title2)
                .foregroundStyle(right ? QuizColor.right : QuizColor.points)
            if right {
                Text(question.earned > 0 ? "Yes! +\(question.earned)" : "Yes!")
                    .font(.title3.bold())
            } else {
                Text(Self.missed(question, country: country))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One flag answer. Before answering it's just the flag (its name would
/// give it away); after, the right one turns green, a wrong pick red, and
/// each says whose flag it is.
private struct FlagChoice: View {
    let asset: String?
    let number: Int
    let name: String
    let state: ChoiceLabel.State

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let asset {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.2)))
                } else {
                    Image(systemName: "flag").font(.largeTitle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 90)
            if state != .open {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .foregroundStyle(state == .right || state == .wrong ? Color.white : Color.primary)
        .background(background, in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            switch state {
            case .right: badge("checkmark")
            case .wrong: badge("xmark")
            default: EmptyView()
            }
        }
        .opacity(state == .faded ? 0.45 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline.bold())
            .padding(6)
            .background(background, in: .circle)
            .offset(x: 6, y: -6)
    }

    private var background: Color {
        switch state {
        case .open, .faded: Color(uiColor: .secondarySystemBackground)
        case .right: QuizColor.right
        case .wrong: QuizColor.wrong
        }
    }

    private var accessibilityText: String {
        switch state {
        case .open: "Flag \(number)"
        case .right: "Flag \(number), \(name), the right answer"
        case .wrong: "Flag \(number), \(name), not right"
        case .faded: "Flag \(number), \(name)"
        }
    }
}

private struct ChoiceLabel: View {
    enum State { case open, right, wrong, faded }

    let text: String
    let state: State

    var body: some View {
        HStack {
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch state {
            case .right: Image(systemName: "checkmark").font(.title3.bold())
            case .wrong: Image(systemName: "xmark").font(.title3.bold())
            default: EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .foregroundStyle(state == .right || state == .wrong ? Color.white : Color.primary)
        .background(background, in: .rect(cornerRadius: 16))
        .opacity(state == .faded ? 0.45 : 1)
        .contentShape(.rect)
        .accessibilityLabel(accessibilityText)
    }

    private var background: Color {
        switch state {
        case .open, .faded: Color(uiColor: .secondarySystemBackground)
        case .right: QuizColor.right
        case .wrong: QuizColor.wrong
        }
    }

    private var accessibilityText: String {
        switch state {
        case .right: "\(text), the right answer"
        case .wrong: "\(text), not right"
        default: text
        }
    }
}

/// A small "read this aloud" button for kids who can't read yet.
private struct SpeakButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.15), in: .circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(label)
    }
}

/// Shown instead of a quiz that has no questions it can ask (only capital
/// questions about places without a capital, say). Nothing is saved.
private struct NothingToAsk: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "questionmark.folder").font(.system(size: 48))
            Text("This quiz has no questions yet").font(.title2.bold())
            Text("Ask a grown-up to check today's quiz.")
                .font(.headline).foregroundStyle(.secondary)
            Button("OK", action: onDone)
                .buttonStyle(.borderedProminent)
                .font(.title3.bold())
        }
        .padding(32)
        .background(.regularMaterial, in: .rect(cornerRadius: 32))
    }
}

/// The end of a sitting: stars, how many were right, points earned, and
/// something kind to say even when most answers were wrong.
private struct QuizSummary: View {
    let quizTitle: String
    let attemptNumber: Int
    let correct: Int
    let total: Int
    let countries: Int
    let points: Int
    let speaker: CardSpeaker
    let readAloud: Bool
    let onDone: () -> Void

    private var stars: Int { Int(quizStars(correct: UInt32(clamping: correct), total: UInt32(clamping: total))) }

    private var cheer: String {
        switch stars {
        case 3: "Amazing!"
        case 2: "Great job!"
        case 1: "Nice work! You're learning."
        default: "Good try! You visited \(countries) places today."
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(quizTitle).font(.title2.bold()).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < stars ? "star.fill" : "star")
                        .font(.system(size: 54))
                        .foregroundStyle(i < stars ? Color.yellow : Color.gray.opacity(0.4))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(stars) of 3 stars")
            Text(cheer).font(.title2.bold()).multilineTextAlignment(.center)
            Text("\(correct) of \(total) right")
                .font(.title.bold())
            Label("+\(points) points", systemImage: "star.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(QuizColor.points)
            Text(QuizWorth.note(forAttempt: attemptNumber))
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onDone) {
                Text("Done")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
        }
        .padding(32)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: .rect(cornerRadius: 32))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear {
            let words = [cheer, "\(correct) of \(total) right.", "\(points) points.",
                         QuizWorth.note(forAttempt: attemptNumber)]
            if readAloud { speaker.say(words) }
            AccessibilityNotification.Announcement(words.joined(separator: " ")).post()
        }
    }
}

/// What a sitting is worth, in words (the numbers are the Rust core's:
/// full, half, a quarter, then practice only; requirements §3.4). Tries are
/// counted for each time the quiz comes up in the queue, not per day.
enum QuizWorth {
    static func short(forAttempt number: Int) -> String {
        switch number {
        case ...1: "Full points"
        case 2: "Half points"
        case 3: "Quarter points"
        default: "Just for practice"
        }
    }

    static func note(forAttempt number: Int) -> String {
        switch number {
        case ...1: "First try: full points."
        case 2: "Second try: half points."
        case 3: "Third try: quarter points."
        default: "Practice round: no points this time."
        }
    }
}

/// The way into today's quiz, for a kid's top bar or the parent home.
/// Shows nothing when there is no quiz today.
struct TodayQuizButton: View {
    let profile: Profile
    var prominent = true
    var compact = false

    @Environment(\.modelContext) private var context
    @Query(FetchDescriptor<QuizSet>(predicate: #Predicate { $0.removedAt == nil })) private var quizzes: [QuizSet]
    @Query private var records: [QueueRecord]
    @Query private var attempts: [QuizAttempt]
    @State private var playing: QuizSet?

    init(profile: Profile, prominent: Bool = true, compact: Bool = false) {
        self.profile = profile
        self.prominent = prominent
        self.compact = compact
        let id = profile.id
        _attempts = Query(filter: #Predicate<QuizAttempt> { $0.profileID == id })
    }

    private var today: QuizSet? {
        quizzes.first { $0.id == records.first?.currentQuizID }
    }

    /// This player's sittings of today's quiz, this time it has come up.
    private var sittings: [QuizAttempt] {
        guard let today, let run = records.first?.run else { return [] }
        return attempts.filter { $0.quizSetID == today.id && $0.run == run }
    }

    var body: some View {
        if let today {
            let unfinished = sittings.contains { $0.finishedAt == nil }
            let finished = sittings.count { $0.finishedAt != nil }
            let title = unfinished ? "Keep going" : finished == 0 ? "Today's quiz" : "Play again"
            let detail = unfinished ? today.title : QuizWorth.short(forAttempt: finished + 1)
            Button {
                playing = today
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.headline)
                        if !compact {
                            Text(detail)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: finished > 0 && !unfinished ? "arrow.counterclockwise" : "questionmark.circle.fill")
                        .font(.title2)
                }
                .frame(minHeight: 44)
            }
            .modifier(QuizButtonStyle(prominent: prominent && (finished == 0 || unfinished)))
            .buttonBorderShape(.capsule)
            .accessibilityLabel(unfinished ? "Keep going with today's quiz" : finished == 0 ? "Play today's quiz" : "Play today's quiz again")
            .accessibilityValue(detail)
            .fullScreenCover(item: $playing) { quiz in
                QuizPlayView(quiz: quiz, profile: profile)
            }
        }
    }
}

private struct QuizButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(QuizColor.button)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
