import SwiftUI
import PhotosUI
import CampCore

struct OnboardingView: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @State private var step = 0
    @State private var profile = CamperProfile()
    var body: some View {
        OnlineFeatureGate(feature: "Initial onboarding") { onboardingContent }
    }
    private var onboardingContent: some View {
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
                    if store.sync.configured { CloudSyncSection() }
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
                        Text("Once setup is complete, your planned trips, checklists, photos, and notes work without an internet connection.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("You’re signed in with Apple. Onboarding, profile and account changes, and Camp Finder require a connection. Optional iCloud sync can be managed from Profile.")
                    }
                }
            }
            .navigationTitle(step == 0 ? "Welcome to RoamReady" : step == 1 ? "Your rig" : "Make it yours")
            .navigationBarTitleDisplayMode(step == 0 ? .inline : .large)
            .toolbar {
                if step > 0 { ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left") { step -= 1 } } }
                ToolbarItem(placement: .topBarTrailing) { Text("\(step + 1) of 3").font(.caption).foregroundStyle(.secondary) }
            }
            .safeAreaInset(edge: .bottom) {
                Button(step < 2 ? "Continue" : "Start camping") {
                    guard connectivity.isOnline, step != 1 || profile.rig.hasRequiredDetails else { return }
                    if step < 2 { step += 1 } else { store.finishOnboarding(profile) }
                }
                .disabled(step == 1 && !profile.rig.hasRequiredDetails)
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .padding().background(.bar)
            }
        }
    }
}

struct RigFormSections: View {
    @Environment(CampStore.self) private var store
    @Binding var rig: Rig
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false
    @State private var photoError: String?

    var body: some View {
        Group {
            Section {
                Picker("Type", selection: $rig.type) {
                    ForEach(RigType.allCases) { Text($0.title).tag($0) }
                }.onChange(of: rig.type) { _, _ in rig.resetDetailsForType() }
                if rig.type.isRV {
                    LabeledContent("Year") {
                        TextField("2024", text: Binding(get: { rig.yearText }, set: { rig.year = Rig.parseYear($0) }))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Make") {
                        TextField("Forest River", text: $rig.make)
                            .textInputAutocapitalization(.words).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Model") {
                        TextField("No Boundaries NB19.5", text: $rig.model)
                            .textInputAutocapitalization(.words).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Length (ft)") {
                        TextField("19.5", text: Binding(get: { rig.lengthText }, set: { rig.lengthFeet = Rig.parseLength($0) }))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("Name") {
                        TextField("Optional", text: $rig.model).multilineTextAlignment(.trailing)
                    }
                }
            } header: { Text("Rig details") } footer: {
                if rig.type.isRV {
                    if let problem = rig.visibleDetailsProblem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Year, make, model, and length are required. Use the overall length from your owner’s documents; Camp Finder can match it against site limits.")
                    }
                }
            }
            if rig.type.isRV {
                Section {
                    Picker("Slide-outs", selection: Binding(get: { rig.slideCount }, set: { rig.setSlideCount($0) })) {
                        Text("Not specified").tag(Int?.none)
                        Text("None").tag(Int?.some(0))
                        ForEach(1...Rig.slideRange.upperBound, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                    if rig.type.isTowable {
                        Picker("Axles", selection: $rig.axleCount) {
                            Text("Not specified").tag(Int?.none)
                            ForEach(Array(Rig.axleRange), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                        }
                    }
                    Toggle("Bunkhouse", isOn: Binding(get: { rig.hasBunkhouse ?? false }, set: { rig.hasBunkhouse = $0 }))
                    LabeledContent("Floorplan or trim") {
                        TextField("Optional", text: $rig.floorplan).multilineTextAlignment(.trailing)
                    }
                } header: { Text("Optional details") } footer: {
                    Text("Choosing a slide-out count adds or removes slide-out steps in your starting checklists.")
                }
            }
            Section {
                HStack(spacing: 16) {
                    RigImage(rig: rig, size: 72)
                    VStack(alignment: .leading, spacing: 10) {
                        // The picker's label closure is Sendable; capture a value, not the binding.
                        let photoTitle = rig.photoFilename == nil ? "Add a photo" : "Change photo"
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label(photoTitle, systemImage: "photo")
                        }.disabled(importing)
                        if importing { ProgressView("Saving photo…") }
                        if rig.photoFilename != nil {
                            Button("Use emoji instead") { rig.photoFilename = nil }
                        }
                    }
                }
                if rig.photoFilename == nil {
                    LabeledContent("Emoji") {
                        TextField("🚐", text: $rig.emoji).multilineTextAlignment(.trailing)
                            .onChange(of: rig.emoji) { _, value in if value.count > 2 { rig.emoji = String(value.prefix(2)) } }
                    }
                }
                if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            } header: { Text("Make it recognizable") } footer: {
                Text("Your rig photo is saved on this iPhone and included in iCloud sync when you turn it on.")
            }
            if rig.type.isRV {
                Section {
                    Toggle("Shore power", isOn: $rig.equipment.shorePower)
                    Toggle("Fresh water connection", isOn: $rig.equipment.freshWater)
                    Toggle("Waste holding tanks", isOn: $rig.equipment.sewer)
                    Toggle("Propane system", isOn: $rig.equipment.propane)
                } header: { Text("Confirm your equipment") } footer: {
                    Text("Options and modifications vary. These answers tailor your starting checklists; always follow your equipment manuals.")
                }
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
