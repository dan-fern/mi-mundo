import AVFoundation
import SwiftUI
import UIKit

/// Big, low-text card about a tapped country: flag, name, capital,
/// population (as a picture scale too), languages and famous places, with a
/// button that reads it all aloud for kids who can't read yet
/// (requirements §3.1).
struct CountryCard: View {
    let country: AtlasCountry
    let onClose: () -> Void

    @State private var speaker = CardSpeaker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Scrolls rather than clipping at the largest text sizes; text is
        // capped at accessibility-2 so the card can't outgrow the iPad mini.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onDisappear { speaker.stop() }
        // The card can stay up while the app is in the background (the kid
        // grace period), so onDisappear alone wouldn't stop the voice.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speaker.stop() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                if let flag = country.flagAsset {
                    Image(flag)
                        .resizable()
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(width: 160)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.15)))
                        .accessibilityLabel("Flag of \(country.name)")
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            // Read aloud sits by the name, well away from Close, and is the
            // biggest target on the card: pre-readers rely on it.
            HStack(alignment: .center, spacing: 12) {
                Text(country.name)
                    .font(.largeTitle.bold())
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    speaker.toggle(Self.spokenSentences(for: country))
                } label: {
                    Image(systemName: speaker.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(minWidth: 64, minHeight: 64)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speaker.isSpeaking ? "Stop reading" : "Read aloud")
            }

            if let facts = country.facts {
                VStack(alignment: .leading, spacing: 14) {
                    if !facts.capitals.isEmpty {
                        FactRow(label: facts.capitals.count > 1 ? "Capitals" : "Capital",
                                value: facts.capitals.formatted(.list(type: .and))) {
                            CapitalStarIcon() // the same star as on the map
                        }
                    }
                    if let population = facts.population {
                        FactRow(label: "People", value: Self.friendly(population)) {
                            SymbolIcon(name: "person.3.fill", color: .blue)
                        } extra: {
                            PopulationScale(population: population)
                        }
                    }
                    if !facts.languages.isEmpty {
                        FactRow(label: facts.languages.count > 1 ? "Languages" : "Language",
                                value: facts.languages.formatted(.list(type: .and))) {
                            SymbolIcon(name: "bubble.left.and.bubble.right.fill", color: .green)
                        }
                    }
                    if !facts.landmarks.isEmpty {
                        FactRow(label: "Famous places",
                                value: facts.landmarks.map(\.name).joined(separator: "\n")) {
                            LandmarkPinIcon() // the same pin as on the map
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "About 68 million" — kids don't need every digit.
    static func friendly(_ population: Int) -> String {
        func rounded(_ value: Double) -> String {
            value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
                .replacingOccurrences(of: ".0", with: "")
        }
        switch population {
        case 1_000_000_000...: return "About \(rounded(Double(population) / 1e9)) billion"
        case 1_000_000...: return "About \(rounded(Double(population) / 1e6)) million"
        case 10_000...: return "About \(rounded(Double(population) / 1e3)) thousand"
        default: return population.formatted()
        }
    }

    /// What the read-aloud button says: short, complete sentences, spoken
    /// one at a time with a pause between.
    static func spokenSentences(for country: AtlasCountry) -> [String] {
        var sentences = [country.name + "."]
        if let facts = country.facts {
            switch facts.capitals.count {
            case 0: break
            case 1: sentences.append("The capital is \(facts.capitals[0]).")
            default: sentences.append("The capitals are \(facts.capitals.formatted(.list(type: .and))).")
            }
            if let population = facts.population {
                sentences.append("\(friendly(population)) people live here.")
            }
            if !facts.languages.isEmpty {
                sentences.append("People speak \(facts.languages.formatted(.list(type: .and))).")
            }
            if !facts.landmarks.isEmpty {
                let names = facts.landmarks.map { speakable($0.name) }
                sentences.append("Famous places: \(names.formatted(.list(type: .and))).")
            }
        }
        return sentences
    }

    /// "Volcanoes National Park (mountain gorillas)" reads as "Volcanoes
    /// National Park, mountain gorillas": brackets aren't spoken well.
    static func speakable(_ name: String) -> String {
        name.replacingOccurrences(of: " (", with: ", ").replacingOccurrences(of: ")", with: "")
    }
}

/// One to five people, so "how many" is visible before a kid can read
/// numbers: each extra person means ten times more people (under a
/// million, millions, tens of millions, hundreds of millions, over a
/// billion: only China and India get five).
struct PopulationScale: View {
    let population: Int

    static func people(for population: Int) -> Int {
        switch population {
        case ..<1_000_000: 1
        case ..<10_000_000: 2
        case ..<100_000_000: 3
        case ..<1_000_000_000: 4
        default: 5
        }
    }

    var body: some View {
        let count = Self.people(for: population)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: "figure.stand")
                    .font(.title2)
                    .foregroundStyle(i < count ? Color.blue : Color.blue.opacity(0.15))
            }
        }
        // The row already says "About 68 million"; the picture is for eyes.
        .accessibilityHidden(true)
    }
}

/// An SF Symbol sized to sit in a fact row's icon column.
private struct SymbolIcon: View {
    let name: String
    let color: Color
    var body: some View {
        Image(systemName: name).font(.title2).foregroundStyle(color)
    }
}

private struct FactRow<Icon: View, Extra: View>: View {
    let label: String
    let value: String
    let icon: Icon
    let extra: Extra

    init(label: String, value: String,
         @ViewBuilder icon: () -> Icon,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.label = label
        self.value = value
        self.icon = icon()
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            icon
                .frame(width: 36)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.headline).foregroundStyle(Color(uiColor: .secondaryLabel))
                extra
                Text(value).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reads the card aloud, one sentence at a time; tapping again stops it.
///
/// - Speaks even with the silent switch on (a pre-reader tapping the
///   speaker must hear something): `.playback` / `.spokenAudio`, ducking
///   other audio, released when done.
/// - Uses the device's language and the user's chosen voice settings.
/// - Only callbacks for the utterance in progress count, so a late
///   "cancelled" from a reading that was stopped can't flip the button
///   back while a new reading plays.
/// - An interruption (Siri, an alarm) ends the reading rather than leaving
///   it paused with a "stop" button showing.
@MainActor
@Observable
final class CardSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    /// Made on first use: the card view is rebuilt often (every pan frame
    /// while it's open), and SwiftUI discards all but the first instance.
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var lastUtterance: ObjectIdentifier?

    func toggle(_ sentences: [String]) {
        if isSpeaking {
            stop()
            return
        }
        let synthesizer = self.synthesizer ?? {
            let s = AVSpeechSynthesizer()
            s.delegate = self
            self.synthesizer = s
            return s
        }()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        var last: AVSpeechUtterance?
        for (i, sentence) in sentences.enumerated() {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.prefersAssistiveTechnologySettings = true
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9 // a touch slower for kids
            utterance.postUtteranceDelay = 0.3
            // Let VoiceOver finish announcing the button first.
            if i == 0, UIAccessibility.isVoiceOverRunning { utterance.preUtteranceDelay = 1.0 }
            synthesizer.speak(utterance)
            last = utterance
        }
        lastUtterance = last.map(ObjectIdentifier.init)
        isSpeaking = last != nil
    }

    /// Speaks this now, replacing anything being read (quiz buttons: each
    /// tap reads its own thing; there is no "tap again to stop").
    func say(_ sentences: [String]) {
        stop()
        toggle(sentences)
    }

    func stop() {
        lastUtterance = nil
        synthesizer?.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        guard isSpeaking else { return }
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if self.lastUtterance == id {
                self.lastUtterance = nil
                self.finish()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in self.stop() }
    }
}
