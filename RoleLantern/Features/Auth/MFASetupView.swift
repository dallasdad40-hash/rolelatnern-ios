import SwiftUI
import CoreImage.CIFilterBuiltins
import Supabase

/// TOTP enrollment: shows a QR (rendered locally with CoreImage) + manual secret,
/// then verifies the first code. Mirrors the web MfaSetup component.
struct MFASetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var factorId: String?
    @State private var otpauthURI: String?
    @State private var secret: String?
    @State private var code = ""
    @State private var status: String?
    @State private var enrolledFactors: [Factor] = []
    @State private var busy = false

    private let client = Supa.client

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !enrolledFactors.isEmpty {
                        enrolledSection
                    } else if let otpauthURI {
                        enrollSection(uri: otpauthURI)
                    } else {
                        ProgressView("Preparing setup…")
                            .padding(.top, 60)
                    }

                    if let status {
                        Text(status)
                            .font(.subheadline)
                            .foregroundColor(Brand.slate)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Two-factor authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private var enrolledSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundColor(Brand.teal)
            Text("Two-factor authentication is on")
                .font(.headline)
                .foregroundColor(Brand.navy)
            Text("You'll be asked for a code from your authenticator app when you sign in.")
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)
            Button("Turn off 2FA", role: .destructive) {
                Task { await unenroll() }
            }
            .padding(.top, 8)
        }
    }

    private func enrollSection(uri: String) -> some View {
        VStack(spacing: 16) {
            // On the phone itself you can't scan the QR — tap instead.
            if let otpURL = URL(string: uri) {
                Button {
                    UIApplication.shared.open(otpURL)
                } label: {
                    Label("Set up on this iPhone", systemImage: "key.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Opens your authenticator (or the iPhone's built-in Passwords codes). Come back here afterwards to enter the first 6-digit code.")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                    .multilineTextAlignment(.center)
            }

            Text("Using a second device? Scan this QR code with its authenticator app instead.")
                .font(.subheadline)
                .foregroundColor(Brand.slate)
                .multilineTextAlignment(.center)

            if let qr = qrImage(from: uri) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(Color.white)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.slate.opacity(0.2)))
            }

            if let secret {
                VStack(spacing: 6) {
                    Text("Or enter this key manually in any authenticator:")
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                    Text(secret)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Brand.surface)
                        .cornerRadius(8)
                    Button {
                        UIPasteboard.general.string = secret
                        status = "Key copied."
                    } label: {
                        Label("Copy key", systemImage: "doc.on.doc")
                    }
                    .font(.footnote)
                    .foregroundColor(Brand.teal)
                }
            }

            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Brand.surface)
                .cornerRadius(12)
                .frame(maxWidth: 200)

            Button {
                Task { await verify() }
            } label: {
                if busy { ProgressView().tint(.white) } else { Text("Verify and enable") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(code.count != 6 || busy)
        }
    }

    private func load() async {
        do {
            let factors = try await client.auth.mfa.listFactors()
            let verified = factors.totp.filter { $0.status == .verified }
            if !verified.isEmpty {
                enrolledFactors = verified
                return
            }
            let response = try await client.auth.mfa.enroll(params: .totp(issuer: "RoleLantern"))
            factorId = response.id
            otpauthURI = response.totp?.uri
            secret = response.totp?.secret
        } catch {
            status = "Could not start 2FA setup: \(error.localizedDescription)"
        }
    }

    private func verify() async {
        guard let factorId else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factorId, code: code)
            )
            status = "Two-factor authentication enabled."
            let factors = try await client.auth.mfa.listFactors()
            enrolledFactors = factors.totp.filter { $0.status == .verified }
        } catch {
            status = "That code didn't work — try the next one from your app."
        }
    }

    private func unenroll() async {
        do {
            for factor in enrolledFactors {
                try await client.auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factor.id))
            }
            enrolledFactors = []
            status = "Two-factor authentication turned off."
            await load()
        } catch {
            status = "Could not turn off 2FA: \(error.localizedDescription)"
        }
    }

    private func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
