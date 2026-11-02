import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// Chooses which of a meal's dishes to copy and which days to copy them to. Cancel leaves the trip unchanged.
struct RepeatMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let meal: MenuMeal
    let onRepeat: ([MenuDish], [Int]) throws -> Void
    @State private var chosenDishes: Set<PersistentIdentifier>
    @State private var chosenDays: Set<Int> = []
    @State private var failure: String?

    init(trip: Trip, meal: MenuMeal, onRepeat: @escaping ([MenuDish], [Int]) throws -> Void) {
        self.trip = trip
        self.meal = meal
        self.onRepeat = onRepeat
        _chosenDishes = State(initialValue: Set(meal.dishes.map(\.persistentModelID)))
    }

    var body: some View {
        let dishes = meal.dishes
        let days = trip.menuDays.filter { $0.offset != meal.day }
        NavigationStack {
            Form {
                // One dish needs no choosing; it stays selected.
                if dishes.count > 1 {
                    Section("Dishes") {
                        ForEach(dishes) { dish in
                            Toggle(dish.name, isOn: binding(for: dish.persistentModelID))
                                .accessibilityIdentifier("repeatDish-\(dish.name)")
                        }
                    }
                }
                Section {
                    Toggle("All days", isOn: allDays(days))
                        .accessibilityIdentifier("repeatAllDays")
                    ForEach(days) { day in
                        Toggle(trip.menuTitle(for: day), isOn: binding(for: day.offset))
                            .accessibilityIdentifier("repeatDay-\(day.number)")
                    }
                } header: {
                    Text(dishes.count == 1 ? "Repeat “\(dishes[0].name)” on" : "Days")
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else {
                        Text("Each day gets its own copy with notes and ingredients, without the photo. Days that already have a dish with the same name are left as they are.")
                    }
                }
            }
            .navigationTitle("Repeat \(meal.title)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repeat") {
                        do {
                            try onRepeat(dishes.filter { chosenDishes.contains($0.persistentModelID) }, chosenDays.sorted())
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                    .disabled(chosenDishes.isEmpty || chosenDays.isEmpty)
                }
            }
        }
    }

    private func binding(for dish: PersistentIdentifier) -> Binding<Bool> {
        Binding(get: { chosenDishes.contains(dish) },
                set: { if $0 { chosenDishes.insert(dish) } else { chosenDishes.remove(dish) } })
    }

    private func binding(for offset: Int) -> Binding<Bool> {
        Binding(get: { chosenDays.contains(offset) },
                set: { if $0 { chosenDays.insert(offset) } else { chosenDays.remove(offset) } })
    }

    private func allDays(_ days: [MenuDay]) -> Binding<Bool> {
        let offsets = Set(days.map(\.offset))
        return Binding(get: { !offsets.isEmpty && chosenDays.isSuperset(of: offsets) },
                       set: { chosenDays = $0 ? offsets : [] })
    }
}
