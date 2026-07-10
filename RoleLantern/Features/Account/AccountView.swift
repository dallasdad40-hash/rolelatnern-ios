import SwiftUI

struct AccountView: View {
    @EnvironmentObject var auth: AuthViewModel
    @EnvironmentObject var lock: BiometricLockManager
    @Environment(\.openURL) private var openURL

    @State private var showMFASetup = false
    @State private var showPasswordSheet = false
    @State private var showDeleteConfirm = false
    @State private var deleteText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Signed in as") {
                    Label(auth.userEmail ?? "—", systemImage: "envelope")
                        .foregroundColor(Brand.navy)
                    if let anonId = auth.profile?.anonymousDisplayId {
                        Label("Anonymous ID: \(anonId)", systemImage: "theatermasks")
                            .foregroundColor(Brand.slate)
                    }
                }

                Section("Security") {
                    if lock.isAvailable {
                        Toggle(isOn: Binding(
                            get: { lock.isEnabled },
                            set: { wantsOn in
                                if wantsOn {
                                    Task { await lock.enable() }
                                } else {
                                    lock.disable()
                                }
                            }
                        )) {
                            Label("Require \(lock.biometryLabel) to open", systemImage: "faceid")
                        }
                    }
                    Button {
                        showPasswordSheet = true
                    } label: {
                        Label("Change password", systemImage: "key")
                    }
                    Button {
                        showMFASetup = true
                    } label: {
                        Label("Two-factor authentication", systemImage: "lock.shield")
                    }
                    Button {
                        Task { await auth.signOut(everywhere: true) }
                    } label: {
                        Label("Sign out everywhere", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section("Privacy") {
                    Button {
                        openURL(AppConfig.webBaseURL.appendingPathComponent("candidate/privacy-center"))
                    } label: {
                        Label("Privacy Center (web)", systemImage: "hand.raised")
                    }
                    Button {
                        openURL(AppConfig.webBaseURL.appendingPathComponent("privacy"))
                    } label: {
                        Label("Privacy policy", systemImage: "doc.text")
                    }
                    Button {
                        openURL(AppConfig.webBaseURL.appendingPathComponent("terms"))
                    } label: {
                        Label("Terms of service", systemImage: "doc.text")
                    }
                }

                Section {
                    Button("Sign out") {
                        Task { await auth.signOut() }
                    }
                    .foregroundColor(Brand.navy)
                }

                Section {
                    Button("Delete my name & CV", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } footer: {
                    Text("Deletion scrubs your name, contact details, and CV from RoleLantern. This cannot be undone. To pause instead, set availability to \"Not looking\" on the dashboard.")
                }
            }
            .navigationTitle("Account")
            .sheet(isPresented: $showMFASetup) { MFASetupView() }
            .sheet(isPresented: $showPasswordSheet) { ChangePasswordSheet() }
            .alert("Delete your data?", isPresented: $showDeleteConfirm) {
                TextField("Type DELETE to confirm", text: $deleteText)
                Button("Cancel", role: .cancel) { deleteText = "" }
                Button("Delete", role: .destructive) {
                    if deleteText == "DELETE" {
                        Task { await auth.deleteAccount() }
                    }
                    deleteText = ""
                }
            } message: {
                Text("Your name, contact details, and CV will be permanently removed and you'll be signed out everywhere.")
            }
        }
    }
}

struct ChangePasswordSheet: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var busy = false

    private var valid: Bool {
        newPassword.count >= 8 && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text("At least 8 characters.")
                }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") {
                        Task {
                            busy = true
                            await auth.updatePassword(newPassword)
                            busy = false
                            dismiss()
                        }
                    }
                    .disabled(!valid || busy)
                }
            }
        }
    }
}
