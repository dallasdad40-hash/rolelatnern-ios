import SwiftUI
import UniformTypeIdentifiers

/// CV upload card (lives on the Dashboard). Evidence match runs from job detail.
struct CVCard: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var cv: CVFile?
    @State private var isLoading = true
    @State private var showImporter = false
    @State private var uploadBusy = false
    @State private var statusMessage: String?
    @State private var cvPreviewURL: URL?

    private let data = DataService()

    var body: some View {
        cvCard
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf, UTType(filenameExtension: "docx") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result) }
            }
            .sheet(item: $cvPreviewURL) { url in
                SafariView(url: url).ignoresSafeArea()
            }
            .alert("Update", isPresented: .init(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(statusMessage ?? "")
            }
            .task { await load() }
    }

    private var cvCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your CV")
                .font(.headline)
                .foregroundColor(Brand.navy)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let cv {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundColor(Brand.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cv.fileName ?? "CV")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.navy)
                            .lineLimit(1)
                        Text("Uploaded \(cv.uploadedAt.formatted(date: .abbreviated, time: .omitted)) · \(parsedLabel(cv.parsedStatus))")
                            .font(.caption)
                            .foregroundColor(Brand.slate)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button("View") { Task { await preview() } }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Replace") { showImporter = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button(role: .destructive) {
                        Task { await removeCV() }
                    } label: {
                        Text("Remove").frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                }
            } else {
                Text("Upload your CV (PDF or DOCX) to unlock evidence-based match insights and one-tap partner applications.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
                Button {
                    showImporter = true
                } label: {
                    if uploadBusy { ProgressView().tint(.white) } else { Label("Upload CV", systemImage: "arrow.up.doc") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(uploadBusy)
                Text("This opens your iPhone's file browser — pick your CV and you'll come right back here.")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
            }

            Label("Private by default — your CV is stored in a private, access-controlled bucket and never shown to your current employer.",
                  systemImage: "lock.fill")
                .font(.caption)
                .foregroundColor(Brand.slate)
        }
        .padding(16)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Evidence, not black-box AI")
                .font(.headline)
                .foregroundColor(Brand.navy)
            step(icon: "1.circle.fill", text: "Upload your CV once — it's parsed securely on our servers.")
            step(icon: "2.circle.fill", text: "Open any job and run an evidence match.")
            step(icon: "3.circle.fill", text: "See exactly why you match, what's missing, and what to confirm — no opaque scores.")
        }
        .padding(16)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }

    private func step(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(Brand.gold)
            Text(text).font(.subheadline).foregroundColor(Brand.navy)
        }
    }

    private func parsedLabel(_ status: String) -> String {
        switch status {
        case "parsed", "completed", "done": return "Parsed"
        case "pending", "processing": return "Parsing…"
        case "failed", "error": return "Parse failed"
        default: return status.capitalized
        }
    }

    private func load() async {
        guard let profile = auth.profile else {
            isLoading = false
            return
        }
        isLoading = true
        cv = try? await data.fetchActiveCV(candidateId: profile.id)
        isLoading = false
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let url = urls.first,
              let profile = auth.profile, let userId = auth.userId else { return }
        uploadBusy = true
        defer { uploadBusy = false }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let fileData = try Data(contentsOf: url)
            guard fileData.count <= 10 * 1024 * 1024 else {
                statusMessage = "CVs must be 10 MB or smaller."
                return
            }
            let contentType = url.pathExtension.lowercased() == "pdf"
                ? "application/pdf"
                : "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            cv = try await data.uploadCV(
                candidateId: profile.id, userId: userId,
                data: fileData, fileName: url.lastPathComponent, contentType: contentType
            )
            statusMessage = "CV uploaded. Parsing runs in the background."
        } catch {
            statusMessage = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func preview() async {
        guard let cv else { return }
        cvPreviewURL = try? await data.signedCVURL(path: cv.fileUrl)
    }

    private func removeCV() async {
        guard let cv else { return }
        do {
            try await data.softDeleteCV(id: cv.id)
            self.cv = nil
            statusMessage = "CV removed."
        } catch {
            statusMessage = "Could not remove the CV."
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
