import MiMundoCore
import SwiftData
import SwiftUI

/// Playing today's quiz (requirements §3.2): the map zooms to the quiz's
/// countries, the player taps them in any order and answers pick-from-four
/// questions about each. One try per question; the right answer is shown
/// either way. Kids and parents play the same screen.
struct QuizPlayView: View {
    let quiz: QuizSet
    let profile: Profile

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AtlasStore.self) private var atlasStore

    @State private var attempt: QuizAttempt?
    @State private var targets: [QuizTarget] = []
    /// What has been answered this sitting: country → kind → was it right.
    @State private var answered: [UInt32: [QuestionKind: Bool]] = [:]
    @State private var points = 0
    @State private var question: ActiveQuestion?
    @State private var camera = MapCamera()
    @State private var fit: MapFit?
    @State private var cardOnLeadingSide = false
    @State private var cardFrame: CGRect?
    @State private var topBarBottom: CGFloat = 96
    @State private var showingSummary = false
    @State private var confirmingStop = false
    @State private var speaker = CardSpeaker()

    /// A question on screen: its buttons, and the pick once made.
    struct ActiveQuestion: Equatable {
        let target: UInt32
        let kind: QuestionKind
        let correct: String
        let choices: [String]
        var picked: String?
        var earned = 0
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
                    if !cardOnLeadingSide { Spacer() }
                    VStack {
                        Spacer(minLength: topBarBottom)
                        QuestionCard(
                            country: target.country, question: question,
                            isLastForCountry: pendingKinds(for: target).isEmpty,
                            speaker: speaker, onPick: choose, onNext: next
                        )
                        .id("\(question.target)-\(question.kind.rawValue)")
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

            if showingSummary, let attempt {
                Color.black.opacity(0.35).ignoresSafeArea()
                QuizSummary(quizTitle: quiz.title, attemptNumber: attempt.number,
                            correct: correctCount, total: totalQuestions, points: points) {
                    dismiss()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .background(MapCanvas.space)
        .onAppear(perform: start)
        .onChange(of: atlasStore.atlas == nil) { _, _ in start() }
        .onDisappear { speaker.stop() }
    }

    // MARK: Map

    private func map(_ atlas: Atlas) -> some View {
        let current = question.flatMap { q in targets.first { $0.id == q.target }?.country }
        return WorldMapView(
            atlas: atlas, camera: $camera, selection: .constant(current),
            cardOnLeadingSide: $cardOnLeadingSide,
            insets: MapInsets(top: topBarBottom + 8,
                              avoid: question == nil ? [] : cardFrame.map { [$0] } ?? []),
            labelMode: .quiz(targets: Set(targets.map(\.id)), revealed: revealed),
            onPick: { country in tapped(country) },
            namedCountries: named,
            marks: marks,
            fit: fit
        )
        .ignoresSafeArea()
    }

    private var marks: [UInt32: QuizMark] {
        Dictionary(uniqueKeysWithValues: targets.map { target in
            guard isDone(target) else { return (target.id, QuizMark.todo) }
            let allRight = answered[target.id]?.values.allSatisfy { $0 } ?? false
            return (target.id, allRight ? .right : .missed)
        })
    }

    /// Countries whose river, lake and landmark names may show: finished,
    /// and named correctly (or never asked for their name).
    private var revealed: Set<UInt32> {
        Set(targets.filter { isDone($0) && answered[$0.id]?[.name] != false }.map(\.id))
    }

    /// Countries whose own name is drawn: once the name question is behind
    /// them (or straight away if the quiz doesn't ask for names).
    private var named: Set<UInt32> {
        Set(targets.filter { !$0.kinds.contains(.name) || answered[$0.id]?[.name] != nil }.map(\.id))
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
            .confirmationDialog("Stop the quiz?", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("Stop for now") { dismiss() }
            } message: {
                Text("Your answers are saved. You can carry on later today.")
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
                .foregroundStyle(.orange)
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
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
        guard attempt == nil, let atlas = atlasStore.atlas else { return }
        guard let attempt = QuizPlay.begin(quiz, for: profile, in: context) else {
            dismiss() // no longer today's quiz
            return
        }
        self.attempt = attempt
        targets = QuizTarget.all(for: quiz, in: atlas)
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
        if !targets.isEmpty, remaining == 0 { finish() }
    }

    /// Box around some countries. A country that wraps the ±180° line
    /// (Russia, Fiji) reports a world-wide box, so its label point stands
    /// in for it rather than zooming out to the whole world.
    private static func bounds(of countries: [AtlasCountry]) -> CGRect? {
        countries.map { country -> CGRect in
            guard country.bounds.width > 4 else { return country.bounds }
            return CGRect(x: CGFloat(country.meta.labelX) - 0.5, y: CGFloat(country.meta.labelY) - 0.3,
                          width: 1, height: 0.6)
        }
        .reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func tapped(_ country: AtlasCountry) {
        // A question waiting for an answer can be swapped for another
        // country; one showing its result is finished with "Next" first.
        if let question, question.picked != nil { return }
        guard let target = targets.first(where: { $0.id == country.id }), !isDone(target) else { return }
        ask(target)
    }

    private func ask(_ target: QuizTarget) {
        guard let atlas = atlasStore.atlas, let kind = pendingKinds(for: target).first else { return }
        speaker.stop()
        let made = atlas.choices(for: kind, about: target.country, seed: .random(in: .min ... .max))
        withAnimation(.easeInOut(duration: 0.25)) {
            question = ActiveQuestion(target: target.id, kind: kind, correct: made.correct, choices: made.all)
        }
    }

    private func choose(_ choice: String) {
        guard var asked = question, asked.picked == nil, let attempt,
              let target = targets.first(where: { $0.id == asked.target }) else { return }
        speaker.stop()
        let saved = QuizPlay.record(choice, correctAnswer: asked.correct, kind: asked.kind,
                                    country: target.country, quiz: quiz, attempt: attempt, in: context)
        asked.picked = choice
        asked.earned = saved?.pointsAwarded ?? 0
        withAnimation(.snappy) {
            question = asked
            answered[target.id, default: [:]][asked.kind] = choice == asked.correct
            points += asked.earned
        }
    }

    private func next() {
        guard let asked = question, let target = targets.first(where: { $0.id == asked.target }) else { return }
        speaker.stop()
        if !isDone(target) {
            ask(target) // its next question (the capital)
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { question = nil }
        if remaining == 0 { finish() }
    }

    private func finish() {
        if let attempt { QuizPlay.finish(attempt, in: context) }
        if let bounds = Self.bounds(of: targets.map(\.country)) {
            fit = MapFit(rect: bounds, token: (fit?.token ?? 0) + 1)
        }
        withAnimation(.spring(duration: 0.4)) { showingSummary = true }
    }

    /// Jumps to a country still to do: the one nearest the middle of the
    /// view. Tiny islands and city states are hard to find and to tap.
    private func findOne() {
        let pending = targets.filter { !isDone($0) }
        let nearest = pending.min { a, b in
            func distance(_ t: QuizTarget) -> CGFloat {
                hypot(CGFloat(t.country.meta.labelX) - camera.center.x, CGFloat(t.country.meta.labelY) - camera.center.y)
            }
            return distance(a) < distance(b)
        }
        guard let nearest, let bounds = Self.bounds(of: [nearest.country]) else { return }
        // Room around it, so the neighbours give it away less than a
        // close-up of its outline would hide them.
        let side = max(bounds.width, bounds.height, 0.12) * 3
        cardOnLeadingSide = false
        fit = MapFit(rect: CGRect(x: bounds.midX - side * 0.35, y: bounds.midY - side / 2, width: side, height: side),
                     token: (fit?.token ?? 0) + 1)
        ask(nearest)
    }
}

/// One question: what's asked, four big answers (each can be read aloud),
/// then the verdict and a Next button.
private struct QuestionCard: View {
    let country: AtlasCountry
    let question: QuizPlayView.ActiveQuestion
    let isLastForCountry: Bool
    let speaker: CardSpeaker
    let onPick: (String) -> Void
    let onNext: () -> Void

    private var prompt: String {
        switch question.kind {
        case .name: "Which country is this?"
        case .capital: "What is the capital of \(country.name)?"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    if question.kind == .capital, let flag = country.flagAsset {
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
                    Spacer(minLength: 4)
                    SpeakButton(label: "Read the question") {
                        speaker.say([prompt] + question.choices.map { $0 + "." })
                    }
                }

                ForEach(question.choices, id: \.self) { choice in
                    HStack(spacing: 10) {
                        Button {
                            onPick(choice)
                        } label: {
                            ChoiceLabel(text: choice, state: state(of: choice))
                        }
                        .buttonStyle(.plain)
                        // Not .disabled: that would grey out the green and
                        // red verdict colours.
                        .allowsHitTesting(question.picked == nil)
                        SpeakButton(label: "Read \(choice)") { speaker.say([choice]) }
                    }
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
        .frame(maxWidth: 400)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func state(of choice: String) -> ChoiceLabel.State {
        guard let picked = question.picked else { return .open }
        if choice == question.correct { return .right }
        return choice == picked ? .wrong : .faded
    }

    @ViewBuilder
    private func verdict(_ picked: String) -> some View {
        let right = picked == question.correct
        HStack(spacing: 10) {
            Image(systemName: right ? "checkmark.circle.fill" : "lightbulb.fill")
                .font(.title2)
                .foregroundStyle(right ? .green : .orange)
            if right {
                Text(question.earned > 0 ? "Yes! +\(question.earned)" : "Yes!")
                    .font(.title3.bold())
            } else {
                Text("It's \(question.correct).")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
        case .right: Color(red: 0.16, green: 0.60, blue: 0.26)
        case .wrong: Color(red: 0.80, green: 0.22, blue: 0.18)
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

/// The end of a sitting: stars, how many were right, points earned.
private struct QuizSummary: View {
    let quizTitle: String
    let attemptNumber: Int
    let correct: Int
    let total: Int
    let points: Int
    let onDone: () -> Void

    private var stars: Int { Int(quizStars(correct: UInt32(correct), total: UInt32(total))) }

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
            Text("\(correct) of \(total) right")
                .font(.largeTitle.bold())
            Label("+\(points) points", systemImage: "star.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
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
    }
}

/// What a sitting is worth, in words (the numbers are the Rust core's:
/// full, half, a quarter, then practice only; requirements §3.4).
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
        case ...1: "First try today: full points."
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

    @Environment(\.modelContext) private var context
    @Query(FetchDescriptor<QuizSet>(predicate: #Predicate { $0.removedAt == nil })) private var quizzes: [QuizSet]
    @Query private var records: [QueueRecord]
    @Query private var attempts: [QuizAttempt]
    @State private var playing: QuizSet?

    init(profile: Profile, prominent: Bool = true) {
        self.profile = profile
        self.prominent = prominent
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
            Button {
                playing = today
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(unfinished ? "Keep going" : finished == 0 ? "Today's quiz" : "Play again")
                            .font(.headline)
                        Text(unfinished ? today.title : QuizWorth.short(forAttempt: finished + 1))
                            .font(.caption.weight(.semibold))
                            .opacity(0.85)
                            .lineLimit(1)
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
            content.buttonStyle(.borderedProminent).tint(.orange)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
