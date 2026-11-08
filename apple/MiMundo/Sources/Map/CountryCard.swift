import SwiftUI

/// Big, low-text card about a tapped country: flag, name, capital,
/// population and languages (requirements §3.1).
struct CountryCard: View {
    let country: AtlasCountry
    let onClose: () -> Void

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
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
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

            Text(country.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)

            if let facts = country.facts {
                VStack(alignment: .leading, spacing: 14) {
                    if !facts.capitals.isEmpty {
                        FactRow(symbol: "building.columns.fill", color: .purple,
                                label: facts.capitals.count > 1 ? "Capitals" : "Capital",
                                value: facts.capitals.formatted(.list(type: .and)))
                    }
                    if let population = facts.population {
                        FactRow(symbol: "person.3.fill", color: .blue,
                                label: "People", value: Self.friendly(population))
                    }
                    if !facts.languages.isEmpty {
                        FactRow(symbol: "bubble.left.and.bubble.right.fill", color: .green,
                                label: facts.languages.count > 1 ? "Languages" : "Language",
                                value: facts.languages.formatted(.list(type: .and)))
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
}

private struct FactRow: View {
    let symbol: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.headline).foregroundStyle(Color(uiColor: .secondaryLabel))
                Text(value).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
