import AVFoundation
import SwiftUI

/// Big, low-text card about a tapped country: flag, name, capital,
/// population (as a picture scale too), languages and famous places, with a
/// button that reads it all aloud for kids who can't read yet
/// (requirements §3.1).
struct CountryCard: View {
    let country: AtlasCountry
    let onClose: () -> Void

    @State private var speaker = CardSpeaker()

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
                Button {
                    speaker.toggle(Self.spokenText(for: country))
                } label: {
                    Image(systemName: speaker.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speaker.isSpeaking ? "Stop reading" : "Read aloud")
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

            Text(country.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)

            if let facts = country.facts {
                VStack(alignment: .leading, spacing: 14) {
                    if !facts.capitals.isEmpty {
                        FactRow(symbol: "star.fill", color: .orange, // matches the capital star on the map
                                label: facts.capitals.count > 1 ? "Capitals" : "Capital",
                                value: facts.capitals.formatted(.list(type: .and)))
                    }
                    if let population = facts.population {
                        FactRow(symbol: "person.3.fill", color: .blue,
                                label: "People", value: Self.friendly(population)) {
                            PopulationScale(population: population)
                        }
                    }
                    if !facts.languages.isEmpty {
                        FactRow(symbol: "bubble.left.and.bubble.right.fill", color: .green,
                                label: facts.languages.count > 1 ? "Languages" : "Language",
                                value: facts.languages.formatted(.list(type: .and)))
                    }
                    if !facts.landmarks.isEmpty {
                        FactRow(symbol: "mappin.circle.fill", color: .red, // matches the landmark pins
                                label: "Famous places",
                                value: facts.landmarks.map(\.name).joined(separator: "\n"))
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

    /// What the read-aloud button says: short, complete sentences.
    static func spokenText(for country: AtlasCountry) -> String {
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
                sentences.append("Famous places: \(facts.landmarks.map(\.name).formatted(.list(type: .and))).")
            }
        }
        return sentences.joined(separator: " ")
    }
}

/// One to five people, so "how many" is visible before a kid can read
/// numbers: each extra person is roughly ten times more people.
struct PopulationScale: View {
    let population: Int

    static func people(for population: Int) -> Int {
        switch population {
        case ..<1_000_000: 1
        case ..<10_000_000: 2
        case ..<50_000_000: 3
        case ..<200_000_000: 4
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
        .accessibilityElement()
        .accessibilityLabel("\(count) of 5 people")
    }
}

private struct FactRow<Extra: View>: View {
    let symbol: String
    let color: Color
    let label: String
    let value: String
    let extra: Extra

    init(symbol: String, color: Color, label: String, value: String,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.symbol = symbol
        self.color = color
        self.label = label
        self.value = value
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
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

/// Reads the card aloud with the system voice; tapping again stops it.
@MainActor
@Observable
final class CardSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if isSpeaking {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9 // a touch slower for kids
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
