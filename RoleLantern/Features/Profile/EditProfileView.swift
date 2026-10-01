import SwiftUI

/// Edit the candidate's details through the website's profile API, so the same
/// rules apply as on rolelantern.com. Employers never see these before you agree.
struct EditProfileView: View {
    var onSaved: (MobileProfile) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: MobileProfile?
    @State private var form = MobileAPI.ProfilePatch(
        fullName: "", currentTitle: "", seniorityLevel: "", yearsExperience: nil,
        desiredLocation: "", remotePreference: "", linkedinUrl: "",
        currentCompanyActual: "", contactPhone: ""
    )
    @State private var yearsText = ""
    @State private var saving = false
    @State private var errorText: String?

    private let api = MobileAPI()

    var body: some View {
        Group {
            if let loaded {
                editor(loaded)
            } else if errorText == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(title: "Couldn't load your profile", message: "Pull down to try again.")
            }
        }
        .navigationTitle("Your details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { Task { await save() } }.disabled(loaded == nil)
                }
            }
        }
        .task { await load() }
        .alert("Your details", isPresented: .init(
            get: { errorText != nil && loaded != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func editor(_ p: MobileProfile) -> some View {
        Form {
            if let strength = p.strength {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Profile strength").foregroundColor(Brand.navy)
                            Spacer()
                            Text("\(strength.percent)%").fontWeight(.semibold).foregroundColor(Brand.teal)
                        }
                        ProgressView(value: Double(strength.percent), total: 100).tint(Brand.teal)
                        if !strength.missing.isEmpty {
                            Text("Add: " + strength.missing.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(Brand.slate)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                TextField("Full name", text: $form.fullName)
                    .textContentType(.name)
                TextField("Current job title", text: $form.currentTitle)
                    .textContentType(.jobTitle)
                Picker("Seniority", selection: $form.seniorityLevel) {
                    Text("Not set").tag("")
                    ForEach(p.options?.seniorityLevel ?? [], id: \.self) { Text($0).tag($0) }
                }
                TextField("Years of experience", text: $yearsText)
                    .keyboardType(.numberPad)
            } header: {
                Text("About you")
            } footer: {
                Text("Employers see your title and experience on your anonymous card. Your name stays hidden until you agree to share it.")
            }

            Section {
                TextField("Where you want to work (city, state)", text: $form.desiredLocation)
                Picker("Work style", selection: $form.remotePreference) {
                    Text("Not set").tag("")
                    ForEach(p.options?.remotePreference ?? ["On-site", "Hybrid", "Remote", "Flexible"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("What you're looking for")
            }

            Section {
                TextField("LinkedIn URL", text: $form.linkedinUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone", text: $form.contactPhone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("Current employer", text: $form.currentCompanyActual)
                    .textContentType(.organizationName)
            } header: {
                Text("Private details")
            } footer: {
                Text("Never shown on your anonymous card. Your current employer is used to keep you hidden from them.")
            }
        }
    }

    private func load() async {
        do {
            let p = try await api.profile()
            apply(p)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func apply(_ p: MobileProfile) {
        loaded = p
        form = MobileAPI.ProfilePatch(
            fullName: p.fullName ?? "",
            currentTitle: p.currentTitle ?? "",
            seniorityLevel: p.seniorityLevel ?? "",
            yearsExperience: p.yearsExperience,
            desiredLocation: p.desiredLocation ?? "",
            remotePreference: p.remotePreference ?? "",
            linkedinUrl: p.linkedinUrl ?? "",
            currentCompanyActual: p.currentCompanyActual ?? "",
            contactPhone: p.contactPhone ?? ""
        )
        yearsText = p.yearsExperience.map { String(Int($0)) } ?? ""
    }

    private func save() async {
        let trimmedYears = yearsText.trimmingCharacters(in: .whitespaces)
        if trimmedYears.isEmpty {
            form.yearsExperience = nil
        } else if let years = Double(trimmedYears), (0...80).contains(years) {
            form.yearsExperience = years
        } else {
            errorText = "Years of experience must be a number from 0 to 80."
            return
        }
        var patch = form
        patch.fullName = patch.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        patch.linkedinUrl = patch.linkedinUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !patch.linkedinUrl.isEmpty && !patch.linkedinUrl.lowercased().hasPrefix("http") {
            patch.linkedinUrl = "https://" + patch.linkedinUrl
        }
        saving = true
        defer { saving = false }
        do {
            let updated = try await api.updateProfile(patch)
            apply(updated)
            onSaved(updated)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
