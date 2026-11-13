import MiMundoCore
import SwiftData
import SwiftUI

/// Parent home: manage kids and see their attendance. Grows into the full
/// parent mode (point values, rewards, stats) later.
struct ParentHomeView: View {
    let parent: Profile
    let onSwitchPlayer: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var addingKid = false
    @State private var editingKid: Profile?
    @State private var kidToDelete: Profile?
    @State private var showDiagnostics = false

    private var kids: [Profile] { profiles.filter { !$0.isParent && !$0.isArchived } }
    private var archivedKids: [Profile] { profiles.filter { !$0.isParent && $0.isArchived } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ParentMapView(parent: parent)
                    } label: {
                        Label("Explore the world map", systemImage: "globe.americas.fill")
                    }
                }

                QuizOfTheDaySection(parent: parent)

                Section("Kids") {
                    if kids.isEmpty {
                        Text("No kids yet. Add one to get started.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(kids) { kid in
                        Button {
                            editingKid = kid
                        } label: {
                            KidRow(kid: kid)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Archive", systemImage: "archivebox") { archive(kid) }
                                .tint(.orange)
                            Button("Edit", systemImage: "pencil") { editingKid = kid }
                                .tint(.blue)
                        }
                    }
                    Button {
                        addingKid = true
                    } label: {
                        Label("Add a kid", systemImage: "plus.circle.fill")
                    }
                }

                if !archivedKids.isEmpty {
                    Section {
                        ForEach(archivedKids) { kid in
                            HStack(spacing: 16) {
                                ProfileAvatar(emoji: kid.emoji, size: 40)
                                Text(kid.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { restore(kid) }
                                    .buttonStyle(.bordered)
                            }
                            .swipeActions {
                                Button("Delete forever", systemImage: "trash", role: .destructive) {
                                    kidToDelete = kid
                                }
                            }
                        }
                    } header: {
                        Text("Archived")
                    } footer: {
                        Text("Archived kids are hidden from \u{201C}Who's playing?\u{201D} but keep all their progress. Swipe to delete one forever.")
                    }
                }

                Section("About") {
                    LabeledContent("New days start at", value: "10 pm US Eastern")
                    NavigationLink("Credits") { CreditsView() }
                    DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                        LabeledContent("Today's game day", value: gameDayLabel(day: Attendance.today()))
                        LabeledContent("Rust core", value: coreVersion())
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hi, \(parent.name)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onSwitchPlayer) {
                        Label("Switch player", systemImage: "person.2.fill")
                    }
                }
            }
            .sheet(isPresented: $addingKid) {
                KidEditor(title: "Add a kid", saveTitle: "Add") { name, emoji in
                    context.insert(Profile(name: name, emoji: emoji, role: .child))
                    context.saveOrRollback("add kid")
                }
            }
            .sheet(item: $editingKid) { kid in
                KidEditor(title: "Edit \(kid.name)", saveTitle: "Save", name: kid.name, emoji: kid.emoji) { name, emoji in
                    kid.name = name
                    kid.emoji = emoji
                    context.saveOrRollback("edit kid")
                }
            }
            .confirmationDialog(
                "Delete \(kidToDelete?.name ?? "") forever?",
                isPresented: Binding(
                    get: { kidToDelete != nil },
                    set: { if !$0 { kidToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete forever", role: .destructive) {
                    if let kidToDelete { deleteForever(kidToDelete) }
                }
            } message: {
                Text("This permanently deletes their profile, attendance and history on this iPad. It can't be undone.")
            }
        }
    }

    private func archive(_ kid: Profile) {
        kid.archivedAt = .now
        context.saveOrRollback("archive kid")
    }

    private func restore(_ kid: Profile) {
        kid.archivedAt = nil
        context.saveOrRollback("restore kid")
    }

    /// All-or-nothing: if anything fails, nothing is deleted.
    private func deleteForever(_ kid: Profile) {
        let kidID = kid.id
        do {
            try context.delete(model: Visit.self, where: #Predicate { $0.childID == kidID })
            try context.delete(model: Session.self, where: #Predicate { $0.profileID == kidID })
            context.delete(kid)
            try context.save()
        } catch {
            dataLog.error("Delete kid failed: \(error, privacy: .public)")
            context.rollback()
        }
        kidToDelete = nil
    }
}

private struct KidRow: View {
    let kid: Profile

    var body: some View {
        HStack(spacing: 16) {
            ProfileAvatar(emoji: kid.emoji, size: 48)
            WithAttendance(childID: kid.id) { summary in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kid.name).font(.headline)
                    Text("Played \(summary.daysPlayedLast7) of the last 7 days · streak \(summary.streak)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AttendanceGauge(summary: summary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// Name + avatar editor for adding or editing a kid.
private struct KidEditor: View {
    let title: String
    let saveTitle: String
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String

    init(
        title: String,
        saveTitle: String,
        name: String = "",
        emoji: String = Profile.emojiChoices[0],
        onSave: @escaping (String, String) -> Void
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.onSave = onSave
        _name = State(initialValue: name)
        _emoji = State(initialValue: emoji)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                ProfileDetailsForm(name: $name, emoji: $emoji, namePrompt: "Kid's name")
                    .padding(32)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        onSave(trimmedName, emoji)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

/// Licenses and credits for the bundled map data and flags (the flag-icons
/// MIT notice must ship with the app). Shows THIRD_PARTY_NOTICES.md.
private struct CreditsView: View {
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "Credits are missing from this build." }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
