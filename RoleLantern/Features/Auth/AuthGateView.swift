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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image("LanternLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 130, height: 130)
                    Wordmark(font: .title.weight(.medium))
                    Text("See roles more clearly")
                        .font(.subheadline)
                        .foregroundColor(Brand.slate)
                }
                .padding(.top, 40)

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

                if mode == .signIn {
                    Button("Forgot password?") { showForgot = true }
                        .font(.subheadline)
                        .foregroundColor(Brand.teal)
                }

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

                Button {
                    Task { await auth.sendMagicLink(email: email) }
                } label: {
                    Label("Email me a magic link", systemImage: "envelope")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(email.isEmpty)
            }
            .padding(24)
        }
        .background(Color.white.ignoresSafeArea())
        .sheet(isPresented: $showForgot) { ForgotPasswordSheet(email: email) }
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

struct ForgotPasswordSheet: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State var email: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("We'll email you a link to reset your password.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .foregroundColor(Brand.navy)
                    .padding(14)
                    .background(Brand.surface)
                    .cornerRadius(12)
                Button("Send reset link") {
                    Task {
                        await auth.sendPasswordReset(email: email)
                        dismiss()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(email.isEmpty)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
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
