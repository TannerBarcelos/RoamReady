import SwiftUI
import SwiftData
import PhotosUI
import CampCore
import CampPersistence

struct MenuDishRow: View {
    let dish: MenuDish
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if dish.photoData != nil {
                    LocalPhoto(data: dish.photoData, maximumDimension: 192)
                } else {
                    ZStack {
                        Color(.tertiarySystemGroupedBackground)
                        Image(systemName: "fork.knife").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(dish.name)
                let count = dish.sortedItems.count
                Text(count == 0 ? "No recipe items yet" : count == 1 ? "1 item" : "\(count) items")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dish with its notes, photo, and recipe items. Items are edited in place; the dish's own details
/// go through an editor sheet so Cancel discards them.
struct MenuDishView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let dish: MenuDish
    @State private var editing = EditMode.inactive
    @State private var editingDetails = false
    @State private var addingItem = false
    @State private var editedItem: DishItem?
    @State private var removing = false

    var body: some View {
        let items = dish.sortedItems
        List {
            Section {
                if dish.photoData != nil {
                    Color.clear
                        .frame(height: 200)
                        .overlay { LocalPhoto(data: dish.photoData, maximumDimension: 1024, allowsRetry: true) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Photo of \(dish.name)")
                        .accessibilityAddTraits(.isImage)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(dish.name).font(.headline)
                    if !dish.notes.isEmpty { Text(dish.notes).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
                Button("Edit dish", systemImage: "pencil") { editingDetails = true }
                    .accessibilityIdentifier("editMenuDish")
                SaveStatus()
            }
            Section {
                ForEach(items) { item in
                    Button { editedItem = item } label: {
                        LabeledContent {
                            Text(item.quantity)
                        } label: {
                            Text(item.name).foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier("dishItem-\(item.name)")
                }
                .onMove { offsets, destination in
                    var ordered = items; ordered.move(fromOffsets: offsets, toOffset: destination)
                    dish.reorderItems(ordered); library.save()
                }
                .onDelete { offsets in dish.removeItems(offsets.map { items[$0] }); library.save() }
                Button("Add item", systemImage: "plus") { addingItem = true }
                    .accessibilityIdentifier("addDishItem")
            } header: {
                Text("Recipe · \(items.count)")
            } footer: {
                Text(items.isEmpty
                     ? "List each part of the dish and how much to bring, like “Ribeye, 2 lb”."
                     : "Tap an item to edit it. Use Edit to reorder or remove items.")
            }
            Section {
                Button("Remove dish", systemImage: "trash", role: .destructive) { removing = true }
                    .tint(.red)
            }
        }
        .navigationTitle(dish.name)
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .environment(\.editMode, $editing)
        .sheet(isPresented: $editingDetails) {
            MenuDishEditor(title: "Edit dish", dish: dish.draft, photo: dish.photoData) { draft, photo in
                try dish.update(draft, photo: photo); library.save()
            }
        }
        .sheet(isPresented: $addingItem) {
            DishItemEditor(item: DishItemDraft(), addsAnother: true) { draft in
                try dish.addItem(draft); library.save()
            }
        }
        .sheet(item: $editedItem) { item in
            DishItemEditor(item: item.draft) { draft in try item.update(draft); library.save() }
        }
        .confirmationDialog("Remove “\(dish.name)”?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove dish", role: .destructive) { dismiss(); context.delete(dish); library.save() }
        } message: {
            Text("Its notes, photo, and recipe items are removed too.")
        }
    }
}

/// Edits a copy of a dish and its photo, so Cancel discards the changes.
struct MenuDishEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var dish: MenuDishDraft
    @State var photo: Data?
    let onSave: (MenuDishDraft, Data?) throws -> Void
    @State private var importing = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Dish, like steak with brussels sprouts", text: $dish.name, axis: .vertical)
                        .accessibilityIdentifier("menuDishName")
                    TextField("Notes", text: $dish.notes, axis: .vertical).lineLimit(2...8)
                        .accessibilityIdentifier("menuDishNotes")
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                    else { Text("A dish is the whole plate. List its parts as recipe items after you save.") }
                }
                DishPhotoSection(data: $photo, importing: $importing)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(dish, photo); dismiss() } catch { failure = error.localizedDescription }
                    }
                    .disabled(!dish.hasName || importing)
                }
            }
        }
    }
}

/// Edits one recipe item. When adding, "Save & add another" keeps the sheet open for the next item.
struct DishItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: DishItemDraft
    var addsAnother = false
    let onSave: (DishItemDraft) throws -> Void
    @State private var failure: String?
    @State private var added = 0
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item, like ribeye", text: $item.name)
                        .focused($nameFocused)
                        .accessibilityIdentifier("dishItemName")
                    TextField("Amount, like 2 lb", text: $item.quantity)
                        .accessibilityIdentifier("dishItemQuantity")
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                    else if added > 0 { Text(added == 1 ? "1 item added" : "\(added) items added") }
                }
                if addsAnother {
                    Section {
                        Button("Save & add another", systemImage: "plus") {
                            if save() { item = DishItemDraft(); added += 1; nameFocused = true }
                        }
                        .disabled(!item.hasName)
                        .accessibilityIdentifier("saveAndAddDishItem")
                    }
                }
            }
            .navigationTitle(addsAnother ? "New item" : "Recipe item").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(added > 0 ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save() { dismiss() } }.disabled(!item.hasName)
                }
            }
            .onAppear { if addsAnother { nameFocused = true } }
        }
    }

    private func save() -> Bool {
        do { try onSave(item); failure = nil; return true } catch { failure = error.localizedDescription; return false }
    }
}

/// Holds an imported dish photo in the editor's draft until Save, so Cancel leaves the dish unchanged.
struct DishPhotoSection: View {
    @Binding var data: Data?
    @Binding var importing: Bool
    @State private var selection: PhotosPickerItem?
    @State private var failure: String?

    var body: some View {
        Section {
            if let data {
                Color.clear
                    .frame(height: 160)
                    .overlay { LocalPhoto(data: data) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Dish photo")
            }
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label(data == nil ? "Add a photo" : "Change photo", systemImage: "photo.badge.plus")
            }
            .disabled(importing)
            .accessibilityIdentifier("menuDishPhotoPicker")
            if data != nil {
                Button("Remove photo", role: .destructive) { data = nil; selection = nil }
                    .disabled(importing)
            }
            if importing { ProgressView("Preparing photo…") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Photo (optional)")
        }
        .task(id: selection) {
            guard let selection else { return }
            importing = true
            failure = nil
            defer { importing = false }
            do {
                let jpeg = try await PhotoImport.jpeg(from: selection)
                try Task.checkCancellation()
                data = jpeg
            } catch is CancellationError {
                // Dismissing the editor discards the pending import.
            } catch { failure = "The photo couldn’t be added. \(error.localizedDescription)" }
        }
    }
}
