import SwiftUI
import PhotosUI
import CampCore

struct OnboardingView: View {
    @Environment(CampStore.self) private var store
    @State private var step = 0
    @State private var profile = CamperProfile()
    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "tent.2").font(.system(size: 44)).foregroundStyle(.blue)
                            Text("A little preparation.\nA lot more camping.").font(.largeTitle.bold())
                            Text("Your setup, your trips, and your memories—ready when reception isn’t.")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical)
                    }
                    Section("What do you camp in?") {
                        ForEach(RigType.allCases) { type in
                            Button {
                                profile.rig.type = type
                                profile.rig.emoji = type.defaultEmoji
                                profile.rig.equipment = type.isRV ? Equipment() : .none
                            } label: {
                                HStack {
                                    Text(type.defaultEmoji)
                                    Text(type.title).foregroundStyle(.primary)
                                    Spacer()
                                    if profile.rig.type == type { Image(systemName: "checkmark").foregroundStyle(.blue) }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                } else if step == 1 {
                    RigFormSections(rig: $profile.rig)
                } else {
                    Section("A little about you") {
                        TextField("First name (optional)", text: $profile.name).textContentType(.givenName)
                        Picker("Camping experience", selection: $profile.experience) {
                            ForEach(Experience.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline)
                    }
                    Section {
                        Label("Your trips stay on this iPhone", systemImage: "iphone")
                        Text("You can plan, check off steps, and save photos without an account or internet connection.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("This development build stores data locally. iCloud sync and account services are not yet enabled.")
                    }
                }
            }
            .navigationTitle(step == 0 ? "Welcome to Camp" : step == 1 ? "Your rig" : "Make it yours")
            .navigationBarTitleDisplayMode(step == 0 ? .inline : .large)
            .toolbar {
                if step > 0 { ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left") { step -= 1 } } }
                ToolbarItem(placement: .topBarTrailing) { Text("\(step + 1) of 3").font(.caption).foregroundStyle(.secondary) }
            }
            .safeAreaInset(edge: .bottom) {
                Button(step < 2 ? "Continue" : "Start camping") {
                    if step < 2 { step += 1 } else { store.finishOnboarding(profile) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .padding().background(.bar)
            }
        }
    }
}

struct RigFormSections: View {
    @Environment(CampStore.self) private var store
    @Binding var rig: Rig
    @State private var showCatalog = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false
    @State private var photoError: String?

    var body: some View {
        Group {
            Section("Rig details") {
                Picker("Type", selection: $rig.type) {
                    ForEach(RigType.allCases) { Text($0.title).tag($0) }
                }.onChange(of: rig.type) { _, type in
                    rig.equipment = type.isRV ? Equipment() : .none
                    rig.emoji = type.defaultEmoji
                    rig.make = ""; rig.model = ""; rig.floorplan = ""; rig.year = nil
                }
                Button("Choose from catalog", systemImage: "books.vertical") { showCatalog = true }
                TextField("Make (optional)", text: $rig.make)
                TextField("Model or your rig’s name", text: $rig.model)
                TextField("Floorplan / trim (optional)", text: $rig.floorplan)
                TextField("Model year (optional)", text: Binding(
                    get: { rig.year.map(String.init) ?? "" },
                    set: { value in rig.year = Int(value.prefix(4)) }
                )).keyboardType(.numberPad)
            }
            Section {
                HStack(spacing: 16) {
                    RigImage(rig: rig, size: 72)
                    VStack(alignment: .leading, spacing: 10) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label(importing ? "Saving photo…" : "Choose a photo", systemImage: "photo")
                        }.disabled(importing)
                        if rig.photoFilename != nil {
                            Button("Use emoji instead") { rig.photoFilename = nil }
                        }
                    }
                }
                TextField("Emoji", text: $rig.emoji)
                    .onChange(of: rig.emoji) { _, value in if value.count > 2 { rig.emoji = String(value.prefix(2)) } }
                if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            } header: { Text("Make it recognizable") } footer: {
                Text("Personal photos are saved on this iPhone. Official rig images will appear when licensed images are available.")
            }
            if rig.type.isRV {
                Section {
                    Toggle("Shore power", isOn: $rig.equipment.shorePower)
                    Toggle("Fresh water connection", isOn: $rig.equipment.freshWater)
                    Toggle("Waste holding tanks", isOn: $rig.equipment.sewer)
                    Toggle("Slide-outs", isOn: $rig.equipment.slideOuts)
                    Toggle("Propane system", isOn: $rig.equipment.propane)
                } header: { Text("Confirm your equipment") } footer: {
                    Text("Options and modifications vary. These answers tailor your starting checklists; always follow your equipment manuals.")
                }
            }
        }
        .sheet(isPresented: $showCatalog) {
            RigCatalogView(type: rig.type) { record in
                rig.make = record.make; rig.model = record.model; rig.year = record.year
                rig.floorplan = record.floorplan ?? ""
            }
        }
        .onChange(of: selectedPhoto) { _, selection in
            guard let selection, !importing else { return }
            Task {
                importing = true
                defer { importing = false; selectedPhoto = nil }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw CampUIError.unreadablePhoto }
                    rig.photoFilename = try await store.media.importPhoto(data)
                    photoError = nil
                } catch { photoError = error.localizedDescription }
            }
        }
    }
}

struct RigCatalogView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let type: RigType
    let onSelect: (RigCatalogRecord) -> Void
    @State private var query = ""
    @State private var make = "All makes"
    var records: [RigCatalogRecord] { store.catalog.filter { $0.rigType == type } }
    var makes: [String] { Array(Set(records.map(\.make))).sorted() }
    var results: [RigCatalogRecord] {
        records.filter {
            (make == "All makes" || $0.make == make) &&
            (query.isEmpty || "\($0.make) \($0.model) \($0.year) \($0.floorplan ?? "")".localizedCaseInsensitiveContains(query))
        }.sorted { ($0.make, $0.model, -$0.year, $0.floorplan ?? "") < ($1.make, $1.model, -$1.year, $1.floorplan ?? "") }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Make", selection: $make) {
                        Text("All makes").tag("All makes")
                        ForEach(makes, id: \.self) { Text($0).tag($0) }
                    }
                } footer: { Text(store.catalogNotice) }
                ForEach(results) { record in
                    Button {
                        onSelect(record); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.make) \(record.model)").foregroundStyle(.primary)
                            Text("\(String(record.year)) · \(record.floorplan ?? "Model series")").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if results.isEmpty {
                    ContentUnavailableView("No matching rigs", systemImage: "car.side", description: Text("Try another search or enter your rig manually."))
                }
                Button("My rig isn’t listed — enter manually") { dismiss() }
            }
            .searchable(text: $query, prompt: "Model, year, or floorplan")
            .navigationTitle("Rig catalog")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
