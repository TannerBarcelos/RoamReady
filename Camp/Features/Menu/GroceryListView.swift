import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// The trip-level Grocery list row on Trip details and the Menu: progress through what's left to get.
struct GroceryEntryLabel: View {
    let list: GroceryList
    var body: some View {
        LabeledContent {
            Text(list.progressText)
        } label: {
            Label("Grocery list", systemImage: "cart")
        }
    }
}

/// A trip's Grocery list, built from its menu every time it is shown. Tapping a row moves it between
/// Need and Have; the amount a row shows can be changed here without changing the menu.
struct GroceryListView: View {
    @Environment(LibraryController.self) private var library
    let trip: Trip
    @State private var changingAmount: GroceryList.Row?

    var body: some View {
        let list = trip.groceryList
        List {
            if list.isEmpty {
                ContentUnavailableView("No ingredients yet", systemImage: "cart",
                                       description: Text("List the ingredients of your dishes and they’ll show up here."))
            } else {
                Section {
                    Label(list.progressText, systemImage: "cart")
                        .accessibilityIdentifier("groceryProgress")
                    SaveStatus()
                } footer: {
                    Text("Tap an ingredient once you have it, whether you bought it or already had it. Swipe to change how much to buy.")
                }
                if list.needsNothing {
                    Section {
                        Label("You have everything", systemImage: "checkmark.circle")
                            .accessibilityIdentifier("groceryAllHave")
                    }
                } else {
                    ForEach(list.needSections) { section in
                        Section(section.category.title) { ForEach(section.rows) { rowView($0) } }
                    }
                }
                if !list.have.isEmpty {
                    Section("Have") { ForEach(list.have) { rowView($0) } }
                }
            }
        }
        .accessibilityIdentifier("groceryList")
        .navigationTitle("Grocery list")
        .toolbar {
            if !list.need.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: list.shareText(campground: trip.campgroundName), subject: Text("Grocery list"))
                        .accessibilityIdentifier("shareGroceryList")
                }
            }
        }
        .sheet(item: $changingAmount) { row in
            GroceryAmountEditor(row: row) { amount in
                trip.setGroceryAmount(amount, forKey: row.key); library.save()
            } onReset: {
                trip.resetGroceryAmount(forKey: row.key); library.save()
            }
        }
    }

    private func rowView(_ row: GroceryList.Row) -> some View {
        Button { setHave(!row.isHave, row) } label: { GroceryRow(row: row) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("groceryRow-\(row.name)")
            .swipeActions {
                Button("Change amount", systemImage: "scalemass") { changingAmount = row }
                    .tint(.orange)
            }
            .contextMenu {
                Button(row.isHave ? "Move to Need" : "Move to Have", systemImage: row.isHave ? "circle" : "checkmark.circle") {
                    setHave(!row.isHave, row)
                }
                Button("Change amount", systemImage: "scalemass") { changingAmount = row }
                if row.override != nil {
                    Button("Reset amount", systemImage: "arrow.uturn.backward") {
                        trip.resetGroceryAmount(forKey: row.key); library.save()
                    }
                }
            }
    }

    private func setHave(_ have: Bool, _ row: GroceryList.Row) {
        trip.setHave(have, forGroceryKey: row.key); library.save()
    }
}

/// A row laid out like a checklist step: a circle that fills when it's Have, then the name with its
/// amount under it. VoiceOver reads it as one selectable button.
private struct GroceryRow: View {
    let row: GroceryList.Row

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: row.isHave ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(row.isHave ? Color.blue : .secondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).foregroundStyle(row.isHave ? .secondary : .primary)
                if !row.amountText.isEmpty {
                    Text(row.amountText).font(.subheadline).foregroundStyle(.secondary)
                }
                if let menuLine = row.menuLine {
                    Text(menuLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isHave ? "Have" : "Need")
        .accessibilityHint(row.isHave ? "Moves it to Need" : "Moves it to Have")
        .accessibilityAddTraits(row.isHave ? .isSelected : [])
    }
}

/// Changes the amount one row shows, for when the store sells a different size than the menu adds up to.
/// Cancel discards the change. Reset goes back to the menu's total.
struct GroceryAmountEditor: View {
    @Environment(\.dismiss) private var dismiss
    let row: GroceryList.Row
    let onSave: (IngredientAmount?) -> Void
    let onReset: () -> Void
    @State private var amount: Double?
    @State private var unit: IngredientUnit?

    init(row: GroceryList.Row, onSave: @escaping (IngredientAmount?) -> Void, onReset: @escaping () -> Void) {
        self.row = row; self.onSave = onSave; self.onReset = onReset
        _amount = State(initialValue: row.editableAmount?.value)
        _unit = State(initialValue: row.editableAmount?.unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IngredientAmountPickers(amount: $amount, unit: $unit, identifierPrefix: "grocery")
                } header: {
                    Text(row.name)
                } footer: {
                    Text(row.menuAmountText.isEmpty
                         ? "Your menu doesn’t give an amount for this."
                         : "Your menu adds up to \(row.menuAmountText). Changing the amount here doesn’t change your menu.")
                }
                if row.override != nil {
                    Section {
                        DestructiveButton("Reset to menu total", systemImage: "arrow.uturn.backward") {
                            onReset(); dismiss()
                        }
                        .accessibilityIdentifier("groceryResetAmount")
                    }
                }
            }
            .navigationTitle("Change amount").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(amount.flatMap { IngredientAmount($0, unit: unit) }); dismiss()
                    }
                    .accessibilityIdentifier("groceryAmountSave")
                }
            }
        }
    }
}
