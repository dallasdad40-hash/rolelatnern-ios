import SwiftUI
import AuthenticationServices

/// Sign in / sign up / forgot password / magic link, matching the web auth surface.
struct AuthGateView: View {
    @EnvironmentObject var auth: AuthViewModel

    enum Mode: String, CaseIterable {
        case signIn = "Sign in"
        case signUp = "Create account"
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var showForgot = false
    @State private var sendingCode = false

    @State private var contentVisible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OfficeHeroView()
                    .frame(maxWidth: .infinity)

                VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to RoleLantern")
                        .font(.title3.weight(.medium))
                        .foregroundColor(Brand.navy)
                    Text("Sign in to upload your CV, save jobs, and get matched — privately.")
                        .font(.footnote)
                        .foregroundColor(Brand.slate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(Brand.navy)
                        .padding(14)
                        .background(Brand.surface)
                        .cornerRadius(12)

                    SecureField("Password", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                        .foregroundColor(Brand.navy)
                        .padding(14)
                        .background(Brand.surface)
                        .cornerRadius(12)
                }

                Button {
                    Task {
                        busy = true
                        if mode == .signIn {
                            await auth.signIn(email: email, password: password)
                        } else {
                            await auth.signUp(email: email, password: password)
                        }
                        busy = false
                    }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text(mode.rawValue) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || email.isEmpty || password.isEmpty)

                HStack(spacing: 16) {
                    Button {
                        if email.trimmingCharacters(in: .whitespaces).isEmpty {
                            auth.errorMessage = "Type your email address in the field above first, then tap this again."
                        } else {
                            Task {
                                sendingCode = true
                                await auth.sendMagicLink(email: email)
                                sendingCode = false
                            }
                        }
                    } label: {
                        if sendingCode {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Sending code…")
                            }
                        } else {
                            Text("No password? Email me a sign-in code")
                        }
                    }
                    Spacer()
                    if mode == .signIn {
                        Button("Forgot password?") { showForgot = true }
                    }
                }
                .font(.footnote)
                .foregroundColor(Brand.teal)

                HStack {
                    Rectangle().fill(Brand.slate.opacity(0.2)).frame(height: 1)
                    Text("or").font(.caption).foregroundColor(Brand.slate)
                    Rectangle().fill(Brand.slate.opacity(0.2)).frame(height: 1)
                }

                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task { await auth.handleAppleCompletion(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .cornerRadius(12)

                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    Label("Continue with Google", systemImage: "globe")
                }
                .buttonStyle(SecondaryButtonStyle())

                VStack(spacing: 6) {
                    Text("By continuing, you agree to our [Terms of service](https://rolelantern.com/legal/terms) and [Privacy notice](https://rolelantern.com/legal/privacy).")
                    Text("Your profile is private by default. We never sell your CV or show you to your current employer. [Your privacy choices](https://rolelantern.com/legal/your-privacy-choices)")
                }
                .font(.caption2)
                .foregroundColor(Brand.slate)
                .tint(Brand.teal)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                Text("Build 2.8")
                    .font(.caption2)
                    .foregroundColor(Brand.slate.opacity(0.5))
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .opacity(contentVisible ? 1 : 0.2)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.white.ignoresSafeArea())
        .onAppear {
            // Returning users never retype their email.
            if email.isEmpty, let remembered = auth.rememberedEmail {
                email = remembered
            }
            withAnimation(.easeOut(duration: 1.0).delay(1.2)) {
                contentVisible = true
            }
        }
        .sheet(isPresented: $showForgot) {
            ForgotPasswordSheet(email: email.isEmpty ? (auth.rememberedEmail ?? "") : email)
        }
        .sheet(isPresented: .init(
            get: { auth.pendingCodeEmail != nil },
            set: { if !$0 { auth.pendingCodeEmail = nil } }
        )) {
            EmailCodeSheet()
        }
        .alert("Something went wrong", isPresented: .init(
            get: { auth.errorMessage != nil },
            set: { if !$0 { auth.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.errorMessage ?? "")
        }
        .alert("Done", isPresented: .init(
            get: { auth.infoMessage != nil },
            set: { if !$0 { auth.infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.infoMessage ?? "")
        }
    }
}

/// Entry for the one-time code the backend emails (sign-in and account confirmation).
struct EmailCodeSheet: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var resendCooldown = 15
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 40))
                    .foregroundColor(Brand.teal)
                Text("Enter your code")
                    .font(.title3.weight(.medium))
                    .foregroundColor(Brand.navy)
                Text("We emailed a code to \(auth.pendingCodeEmail ?? "you"). It may take a minute to arrive.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
                    .multilineTextAlignment(.center)
                Text("Use the code from the newest email — older codes stop working.")
                    .font(.caption)
                    .foregroundColor(Brand.gold)
                    .multilineTextAlignment(.center)

                TextField("Enter code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundColor(Brand.navy)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(Brand.surface)
                    .cornerRadius(12)
                    .frame(maxWidth: 260)

                Button {
                    Task {
                        busy = true
                        await auth.verifyEmailCode(code)
                        busy = false
                    }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text("Verify") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(code.count < 6 || busy)

                if resendCooldown > 0 {
                    Text("Didn't get it? You can resend in \(resendCooldown)s")
                        .font(.footnote)
                        .foregroundColor(Brand.slate)
                } else {
                    Button("Resend code") {
                        Task {
                            let email = auth.pendingCodeEmail ?? ""
                            await auth.sendMagicLink(email: email, force: true)
                            code = ""
                            resendCooldown = 15
                        }
                    }
                    .font(.footnote)
                    .foregroundColor(Brand.teal)
                }

                Spacer()
            }
            .padding(28)
            .onAppear { code = "" }
            .onReceive(timer) { _ in
                if resendCooldown > 0 { resendCooldown -= 1 }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("Something went wrong", isPresented: .init(
            get: { auth.errorMessage != nil },
            set: { if !$0 { auth.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }
}

/// One-screen in-app password reset: the code is emailed automatically the
/// moment this opens; the user types code + new password together. No steps.
struct ForgotPasswordSheet: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var busy = false
    @State private var codeSent = false
    @State private var resendCooldown = 15
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canSubmit: Bool {
        code.count >= 6 && newPassword.count >= 8 && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if codeSent {
                        Label("For your security we just emailed a code to \(email) — it proves it's really you. Enter it with your new password.", systemImage: "envelope.badge")
                            .font(.footnote)
                            .foregroundColor(Brand.teal)
                            .multilineTextAlignment(.leading)
                    } else {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .foregroundColor(Brand.navy)
                            .padding(14)
                            .background(Brand.surface)
                            .cornerRadius(12)
                    }

                    TextField("Code from the newest email", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundColor(Brand.navy)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(Brand.surface)
                        .cornerRadius(12)

                    SecureField("New password (8+ characters)", text: $newPassword)
                        .textContentType(.newPassword)
                        .foregroundColor(Brand.navy)
                        .padding(14)
                        .background(Brand.surface)
                        .cornerRadius(12)

                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .foregroundColor(Brand.navy)
                        .padding(14)
                        .background(Brand.surface)
                        .cornerRadius(12)

                    Button {
                        Task {
                            busy = true
                            if await auth.resetPassword(email: email, code: code, newPassword: newPassword) {
                                dismiss()
                            }
                            busy = false
                        }
                    } label: {
                        if busy { ProgressView().tint(.white) } else { Text("Reset password") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit || busy)

                    if !codeSent {
                        Button("Email me the code") {
                            Task {
                                if !email.isEmpty, await auth.sendPasswordReset(email: email) {
                                    codeSent = true
                                    resendCooldown = 15
                                }
                            }
                        }
                        .font(.footnote)
                        .foregroundColor(Brand.teal)
                        .disabled(email.isEmpty)
                    } else if resendCooldown > 0 {
                        Text("No email? Check spam — or resend in \(resendCooldown)s")
                            .font(.footnote)
                            .foregroundColor(Brand.slate)
                    } else {
                        Button("Resend code") {
                            Task {
                                _ = await auth.sendPasswordReset(email: email, force: true)
                                code = ""
                                resendCooldown = 15
                            }
                        }
                        .font(.footnote)
                        .foregroundColor(Brand.teal)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Fire the email immediately — nothing to wait for before typing.
                if !email.isEmpty {
                    codeSent = true
                    Task { _ = await auth.sendPasswordReset(email: email) }
                }
            }
            .onReceive(timer) { _ in
                if resendCooldown > 0 { resendCooldown -= 1 }
            }
        }
    }
}

/// Shown right after a verified password-reset code: the user is signed in
/// and sets their new password without ever leaving the app.
struct SetNewPasswordSheet: View {
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
            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 40))
                    .foregroundColor(Brand.teal)
                Text("Code verified — you're in. Now choose a new password.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
                    .multilineTextAlignment(.center)
                SecureField("New password (8+ characters)", text: $newPassword)
                    .textContentType(.newPassword)
                    .foregroundColor(Brand.navy)
                    .padding(14)
                    .background(Brand.surface)
                    .cornerRadius(12)
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .foregroundColor(Brand.navy)
                    .padding(14)
                    .background(Brand.surface)
                    .cornerRadius(12)
                Button {
                    Task {
                        busy = true
                        await auth.updatePassword(newPassword)
                        busy = false
                        auth.resetStage = nil
                        dismiss()
                    }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text("Save new password") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!valid || busy)
                Button("Skip for now") {
                    auth.resetStage = nil
                    dismiss()
                }
                .font(.footnote)
                .foregroundColor(Brand.slate)
                Spacer()
            }
            .padding(24)
            .navigationTitle("New password")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}

/// Six-digit TOTP challenge shown when the account requires AAL2.
struct MFAChallengeView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 24) {
            LanternMark(size: 72)
            Text("Two-factor authentication")
                .font(.title2.weight(.medium))
                .foregroundColor(Brand.navy)
            Text("Enter the 6-digit code from your authenticator app.")
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .foregroundColor(Brand.navy)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(Brand.surface)
                .cornerRadius(12)
                .frame(maxWidth: 220)

            Button {
                Task {
                    busy = true
                    await auth.verifyMFACode(code)
                    busy = false
                }
            } label: {
                if busy { ProgressView().tint(.white) } else { Text("Verify") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(code.count != 6 || busy)

            Button("Sign out") { Task { await auth.signOut() } }
                .font(.subheadline)
                .foregroundColor(Brand.slate)
        }
        .padding(32)
        .alert("Something went wrong", isPresented: .init(
            get: { auth.errorMessage != nil },
            set: { if !$0 { auth.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }
}
