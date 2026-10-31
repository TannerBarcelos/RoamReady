import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// A trip's menu: each day of the stay with its meals. Meals open to their dishes, and dishes to their recipe.
struct TripMenuView: View {
    @Environment(LibraryController.self) private var library
    let trip: Trip
    @State private var addingMealTo: MenuDay?
    @State private var removing: MenuMeal?

    var body: some View {
        let days = trip.menuDays
        let outside = trip.mealsOutsideDates
        List {
            Section {
                MenuEntryLabel(summary: trip.menuSummary)
                SaveStatus()
            } footer: {
                Text("Plan the dishes for each meal, then list what goes into each one.")
            }
            if days.isEmpty {
                ContentUnavailableView("Check this trip’s dates", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("Edit the trip so departure is on or after arrival to plan its menu."))
            }
            ForEach(days) { day in
                Section {
                    ForEach(trip.menu(on: day.offset)) { meal in mealLink(meal) }
                    Button("Add a meal", systemImage: "plus") { addingMealTo = day }
                        .accessibilityIdentifier("addMeal-\(day.number)")
                } header: {
                    Text(trip.menuTitle(for: day))
                } footer: {
                    if day.offset == MenuPolicy.maxDays - 1, trip.menuIsTruncated {
                        Text("Menus cover the first \(MenuPolicy.maxDays) days of a trip.")
                    }
                }
            }
            if !outside.isEmpty {
                Section {
                    ForEach(outside) { meal in mealLink(meal, caption: "Planned for day \(meal.day + 1)") }
                } header: { Text("Outside trip dates") } footer: {
                    Text("These meals are on days that are no longer part of this trip. Open one to move it to another day, or swipe to remove it.")
                }
            }
        }
        .accessibilityIdentifier("tripMenuList")
        .navigationTitle("Menu")
        .sheet(item: $addingMealTo) { day in
            MealNameEditor(title: "New meal", meal: MealDraft()) { draft in
                try trip.addMeal(draft, day: day.offset); library.save()
            }
        }
        .confirmationDialog(removing.map(removalTitle) ?? "", isPresented: isRemoving, titleVisibility: .visible,
                            presenting: removing) { meal in
            Button(meal.isStandard ? "Clear \(meal.title)" : "Remove \(meal.title)", role: .destructive) {
                trip.removeMeal(meal); library.save()
            }
        } message: { meal in
            Text(meal.dishes.isEmpty ? "This meal has no dishes yet." : "Its dishes, notes, photos, and recipe items are removed too.")
        }
    }

    private func mealLink(_ meal: MenuMeal, caption: String? = nil) -> some View {
        NavigationLink { MealView(trip: trip, mealID: meal.id) } label: { MenuMealRow(meal: meal, caption: caption) }
            .accessibilityIdentifier("menuMeal-\(meal.day + 1)-\(meal.isStandard ? meal.kind.rawValue : meal.title)")
            .swipeActions {
                if !meal.isStandard || !meal.dishes.isEmpty {
                    Button(meal.isStandard ? "Clear" : "Remove", systemImage: "trash", role: .destructive) { removing = meal }
                }
            }
    }

    private func removalTitle(_ meal: MenuMeal) -> String {
        let dishes = meal.dishes.count
        let count = dishes == 1 ? "1 dish" : "\(dishes) dishes"
        return meal.isStandard ? "Clear \(count) from \(meal.title)?" : "Remove “\(meal.title)”?"
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

/// A meal laid out like a checklist step: its name, then its dishes in secondary text.
struct MenuMealRow: View {
    @ScaledMetric(relativeTo: .body) private var iconWidth = 28
    let meal: MenuMeal
    var caption: String?

    var body: some View {
        let dishes = meal.dishes
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: meal.kind.systemImage)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.title).font(.headline)
                Text(dishes.isEmpty ? "Nothing planned" : dishes.map(\.name).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The trip-level menu row on Trip details and Home.
struct MenuEntryLabel: View {
    let summary: MenuSummary
    var body: some View {
        LabeledContent {
            if let detail = summary.detail { Text(detail) }
        } label: {
            Label(summary.title, systemImage: "fork.knife")
        }
    }
}

/// One meal's dishes. The meal is looked up by identity on every update, so a dish added on another
/// device, or a standard meal stored by its first dish, appears here without reopening it.
struct MealView: View {
    @Environment(LibraryController.self) private var library
    let trip: Trip
    @State private var mealID: MenuMeal.ID
    @State private var editing = EditMode.inactive
    @State private var addingDish = false
    @State private var renaming = false

    init(trip: Trip, mealID: MenuMeal.ID) {
        self.trip = trip
        _mealID = State(initialValue: mealID)
    }

    var body: some View {
        let meal = trip.menuMeal(mealID)
        List {
            if let meal {
                let dishes = meal.dishes
                Section {
                    ForEach(dishes) { dish in
                        NavigationLink { MenuDishView(dish: dish) } label: { MenuDishRow(dish: dish) }
                            .accessibilityIdentifier("menuDish-\(dish.name)")
                    }
                    .onMove { offsets, destination in
                        var ordered = dishes; ordered.move(fromOffsets: offsets, toOffset: destination)
                        meal.reorderDishes(ordered); library.save()
                    }
                    .onDelete { offsets in meal.removeDishes(offsets.map { dishes[$0] }); library.save() }
                    Button("Add a dish", systemImage: "plus") { addingDish = true }
                        .accessibilityIdentifier("addDish")
                } header: {
                    Text(dayTitle(meal.day))
                } footer: {
                    if dishes.isEmpty {
                        Text("Add each dish you plan to make, like steak with brussels sprouts and sourdough.")
                    } else {
                        Text("Use Edit to reorder or remove dishes.")
                    }
                }
                let days = trip.menuDays
                if !meal.isStandard || !days.contains(where: { $0.offset == meal.day }) {
                    Section {
                        if !meal.isStandard {
                            Button("Rename meal", systemImage: "pencil") { renaming = true }
                        }
                        if !days.isEmpty {
                            Menu {
                                ForEach(days) { day in
                                    Button(trip.menuTitle(for: day)) { move(meal, to: day) }
                                        .disabled(day.offset == meal.day)
                                }
                            } label: { Label("Move to another day", systemImage: "calendar") }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Meal removed", systemImage: "fork.knife",
                                       description: Text("This meal isn’t on the trip anymore. It may have been removed on another device."))
            }
        }
        .navigationTitle(meal?.title ?? "Meal")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .environment(\.editMode, $editing)
        .sheet(isPresented: $addingDish) {
            MenuDishEditor(title: "New dish", dish: MenuDishDraft(), photo: nil) { draft, photo in
                try trip.addDish(draft, photo: photo, to: mealID); library.save()
            }
        }
        .sheet(isPresented: $renaming) {
            MealNameEditor(title: "Rename meal", meal: MealDraft(title: meal?.records.first?.title ?? "")) { draft in
                try meal?.records.first?.rename(draft); library.save()
            }
        }
    }

    private func dayTitle(_ offset: Int) -> String {
        trip.menuDays.first { $0.offset == offset }.map(trip.menuTitle(for:)) ?? "Day \(offset + 1) · Outside trip dates"
    }

    /// A standard meal is identified by its day, so the view follows it to the new one.
    private func move(_ meal: MenuMeal, to day: MenuDay) {
        trip.moveMeal(meal, toDay: day.offset)
        library.save()
        if meal.isStandard { mealID = .standard(day: day.offset, kind: meal.kind) }
    }
}

/// Edits a meal's name, so Cancel leaves it unchanged.
struct MealNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var meal: MealDraft
    let onSave: (MealDraft) throws -> Void
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like second breakfast", text: $meal.title)
                        .accessibilityIdentifier("menuMealName")
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(meal); dismiss() } catch { failure = error.localizedDescription }
                    }.disabled(!meal.hasTitle)
                }
            }
        }
    }
}
