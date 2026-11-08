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
    @Query private var visits: [Visit]
    @State private var addingChild = false
    @State private var childToDelete: Profile?

    private var children: [Profile] { profiles.filter { !$0.isParent } }

    var body: some View {
        NavigationStack {
            List {
                Section("Kids") {
                    if children.isEmpty {
                        Text("No kids yet. Add one to get started.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(children) { child in
                        ChildRow(child: child, attendance: Attendance.summary(for: child.id, visits: visits))
                            .swipeActions {
                                Button("Remove", role: .destructive) { childToDelete = child }
                            }
                    }
                    Button {
                        addingChild = true
                    } label: {
                        Label("Add a kid", systemImage: "plus.circle.fill")
                    }
                }

                Section("About") {
                    LabeledContent("Today's game day", value: gameDayLabel(day: Attendance.today()))
                    LabeledContent("Days start at", value: "10 pm US Eastern")
                    LabeledContent("Rust core", value: coreVersion())
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
            .sheet(isPresented: $addingChild) {
                AddChildView { name, emoji in
                    context.insert(Profile(name: name, emoji: emoji, role: .child))
                    try? context.save()
                }
            }
            .confirmationDialog(
                "Remove \(childToDelete?.name ?? "")?",
                isPresented: Binding(
                    get: { childToDelete != nil },
                    set: { if !$0 { childToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let childToDelete { remove(childToDelete) }
                }
            } message: {
                Text("This deletes their profile and attendance on this iPad. It can't be undone.")
            }
        }
    }

    private func remove(_ child: Profile) {
        let childID = child.id
        try? context.delete(model: Visit.self, where: #Predicate { $0.childID == childID })
        context.delete(child)
        try? context.save()
        childToDelete = nil
    }
}

private struct ChildRow: View {
    let child: Profile
    let attendance: AttendanceSummary

    var body: some View {
        HStack(spacing: 16) {
            ProfileAvatar(emoji: child.emoji, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(child.name).font(.headline)
                Text("Played \(attendance.daysPlayedLast7) of the last 7 days · streak \(attendance.streak)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            AttendanceGauge(level: attendance.level, maxLevel: attendance.maxLevel)
        }
        .padding(.vertical, 4)
    }
}

private struct AddChildView: View {
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = Profile.emojiChoices[0]

    var body: some View {
        NavigationStack {
            ScrollView {
                ProfileDetailsForm(name: $name, emoji: $emoji, namePrompt: "Kid's name")
                    .padding(32)
            }
            .navigationTitle("Add a kid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name.trimmingCharacters(in: .whitespaces), emoji)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
