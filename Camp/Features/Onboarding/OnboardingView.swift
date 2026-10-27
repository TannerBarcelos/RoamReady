import SwiftUI
import PhotosUI
import SwiftData
import CampCore
import CampPersistence

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @State private var step = 0
    @State private var name = ""
    @State private var experience = Experience.new
    @State private var draft = RigDraft()
    /// Created when the owner continues past the rig step, so documents can attach to it. A rig left
    /// by an onboarding that didn't finish is picked up again.
    @State private var rig: Rig?
    @State private var failure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stageTitle: String {
        ["Your kind of camping", "Meet your rig", "Ready for what’s next"][step]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        if step == 0 { welcomeArtwork }
                        Text(stageTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text(step == 0 ? "A little preparation. A lot more camping. Choose your setup and we’ll make it feel like yours."
                             : step == 1 ? "A few details now, a smoother arrival later. We’ll tailor your starting checklists to your setup."
                             : "Your first rig is ready. Add a personal touch, then make room for your next adventure.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if step == 0 {
                    Section {
                        ForEach(RigType.allCases) { type in
                            Button {
                                guard draft.type != type else { return }
                                draft.type = type
                                draft.resetDetailsForType()
                            } label: {
                                HStack(spacing: 16) {
                                    Text(type.defaultEmoji).font(.title).accessibilityHidden(true)
                                        .frame(width: 48, height: 48)
                                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                    Text(type.title).font(.headline).foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    Image(systemName: draft.type == type ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(draft.type == type ? Color.blue : Color.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(draft.type == type ? [.isSelected] : [])
                        }
                    } header: { Text("What do you camp in?") }
                    Section {
                        Label("No account. No signal required.", systemImage: "wifi.slash")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.listRowBackground(Color.clear)
                } else if step == 1 {
                    RigFormSections(rig: $draft)
                } else {
                    Section {
                        HStack(spacing: 16) {
                            RigImage(type: draft.type, emoji: draft.emoji, photo: draft.photo, size: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(draft.displayName).font(.headline)
                                Label("Setup & teardown lists prepared", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                    Section {
                        TextField("First name (optional)", text: $name).textContentType(.givenName)
                            .textInputAutocapitalization(.words).submitLabel(.done)
                        Picker("Camping experience", selection: $experience) {
                            ForEach(Experience.allCases) { Text($0.title).tag($0) }
                        }
                    } header: { Text("Make yourself at home") } footer: {
                        Text("Just for you. You can change these details in Profile anytime.")
                    }
                    if let rig {
                        DocumentVaultSection(owner: .rig(rig), header: "Manuals & paperwork (optional)",
                                             footer: "Add a manual, registration, or insurance now, or add it later in Profile.")
                    }
                    if library.iCloud.configured { ICloudSection() }
                    Section {
                        Label("Ready for your next trip", systemImage: "mountain.2")
                            .font(.headline)
                        Text("Keep your trips, checklists, photos, and notes together.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("No account needed. Manage iCloud in Settings.")
                    }
                }
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            }
            .id(step)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("RoamReady")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { changeStep(to: step - 1) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(step + 1) of 3").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Step \(step + 1) of 3")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    ProgressView(value: Double(step + 1), total: 3)
                        .accessibilityLabel("Setup progress")
                    Button(action: advance) {
                        HStack {
                            Spacer()
                            Text(step == 0 ? "Set up my \(draft.type.title.lowercased())" : step == 1 ? "Looks like home" : "Let’s go camping")
                            Image(systemName: step == 2 ? "checkmark" : "arrow.right")
                            Spacer()
                        }.padding(.vertical, 6)
                    }
                    .disabled(step == 1 && !draft.hasRequiredDetails)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if step == 1 && !draft.hasRequiredDetails {
                        // Only a VIN or plate problem replaces the usual hint; it's the one left to fix.
                        Text(draft.detailsProblem == draft.registrationProblem ? draft.registrationProblem ?? ""
                             : "Add year, make, model, and length to continue.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding().frame(maxWidth: 640).frame(maxWidth: .infinity).background(.bar)
            }
            .onAppear {
                if rig == nil, let unfinished = rigs.active.first { rig = unfinished; draft = unfinished.draft }
            }
        }
    }

    private var welcomeArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(.blue.opacity(0.08))
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 100)).foregroundStyle(.blue.opacity(0.16))
                .offset(x: 35, y: 12)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 32)).foregroundStyle(.orange).offset(x: 78, y: -42)
            Image(systemName: "tent.2.fill")
                .font(.system(size: 64)).foregroundStyle(.blue).offset(x: -32, y: 28)
        }
        .frame(height: 180).clipped().accessibilityHidden(true)
    }

    private func changeStep(to value: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { step = value }
    }

    private func advance() {
        do {
            switch step {
            case 0: changeStep(to: 1)
            case 1:
                if let rig { try rig.update(draft, regenerateDefaults: true) } else { rig = try Rig.add(draft, to: context) }
                try context.save(); changeStep(to: 2)
            default:
                let camper = CamperProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), experience: experience)
                context.insert(camper)
                do { try context.save() }
                catch {
                    context.delete(camper)
                    throw error
                }
            }
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

struct RigFormSections: View {
    @Binding var rig: RigDraft
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
                        TextField("2024", text: Binding(get: { rig.yearText }, set: { rig.year = RigDraft.parseYear($0) }))
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
                        TextField("19.5", text: Binding(get: { rig.lengthText }, set: { rig.lengthFeet = RigDraft.parseLength($0) }))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("Name") {
                        TextField("Optional", text: $rig.model).multilineTextAlignment(.trailing)
                    }
                }
            } header: { Text("Rig details") } footer: {
                if rig.type.isRV {
                    // A VIN or plate problem shows under Registration instead.
                    if let problem = rig.visibleDetailsProblem, problem != rig.registrationProblem {
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
                        ForEach(1...RigDraft.slideRange.upperBound, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                    if rig.type.isTowable {
                        Picker("Axles", selection: $rig.axleCount) {
                            Text("Not specified").tag(Int?.none)
                            ForEach(Array(RigDraft.axleRange), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
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
            if rig.type.hasRegistration {
                Section {
                    LabeledContent("VIN") {
                        TextField("17 characters", text: $rig.vin)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .monospaced().multilineTextAlignment(.trailing)
                    }
                    LabeledContent("License plate") {
                        TextField("Optional", text: $rig.licensePlate)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("State or province") {
                        TextField("Optional", text: $rig.plateRegion)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: { Text("Registration (optional)") } footer: {
                    if let problem = rig.registrationProblem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Handy at check-in and for gate passes. The VIN is on your registration, title, or a plate near the hitch or driver’s door. You can also keep the registration card itself in your rig’s Manuals & paperwork.")
                    }
                }
            }
            Section {
                HStack(spacing: 16) {
                    RigImage(type: rig.type, emoji: rig.emoji, photo: rig.photo, size: 72)
                    VStack(alignment: .leading, spacing: 10) {
                        // The picker's label closure is Sendable; capture a value, not the binding.
                        let photoTitle = rig.photo == nil ? "Add a photo" : "Change photo"
                        PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                            Label(photoTitle, systemImage: "photo")
                        }.disabled(importing)
                        if importing { ProgressView("Saving photo…") }
                        if rig.photo != nil {
                            Button("Use emoji instead") { rig.photo = nil }
                        }
                    }
                }
                if rig.photo == nil {
                    LabeledContent("Emoji") {
                        TextField("🚐", text: $rig.emoji).multilineTextAlignment(.trailing)
                            .onChange(of: rig.emoji) { _, value in if value.count > 2 { rig.emoji = String(value.prefix(2)) } }
                    }
                }
                if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            } header: { Text("Make it recognizable") } footer: {
                Text("Choose a photo that makes your rig easy to recognize.")
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
                    rig.photo = try await PhotoImport.jpeg(from: selection)
                    photoError = nil
                } catch { photoError = error.localizedDescription }
            }
        }
    }
}
