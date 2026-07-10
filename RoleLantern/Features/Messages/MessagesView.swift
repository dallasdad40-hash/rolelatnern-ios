import SwiftUI

/// Shared so the tab badge stays in sync with the inbox.
@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var threads: [MessageThread] = []
    @Published var unreadByThread: [UUID: Int] = [:]
    @Published var jobTitles: [UUID: String] = [:]
    @Published var isLoading = false

    private let data = DataService()

    var totalUnread: Int { unreadByThread.values.reduce(0, +) }

    func refresh(candidateId: UUID?) async {
        guard let candidateId else { return }
        isLoading = threads.isEmpty
        defer { isLoading = false }
        do {
            let fetched = try await data.fetchThreads(candidateId: candidateId)
            threads = fetched
            unreadByThread = try await data.fetchUnreadCounts(threadIds: fetched.map(\.id))
            for thread in fetched {
                if let jobId = thread.jobId, jobTitles[jobId] == nil {
                    if let job = try? await data.fetchJob(id: jobId) {
                        jobTitles[jobId] = "\(job.jobTitle) · \(job.companyName)"
                    }
                }
            }
        } catch {
            // Keep whatever we had; the badge just won't update this cycle.
        }
    }
}

/// Inbox: threads + unread counts live natively. Message bodies are encrypted
/// server-side, so reading/replying opens the secure web conversation.
struct MessagesView: View {
    @EnvironmentObject var auth: AuthViewModel
    @ObservedObject var vm: MessagesViewModel
    @State private var openThread: MessageThread?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.threads.isEmpty {
                    EmptyStateView(
                        title: "No messages yet",
                        message: "When an employer messages you about a role, the conversation shows up here."
                    )
                } else {
                    List(vm.threads) { thread in
                        Button {
                            openThread = thread
                        } label: {
                            ThreadRow(
                                thread: thread,
                                title: thread.jobId.flatMap { vm.jobTitles[$0] } ?? "Employer conversation",
                                unread: vm.unreadByThread[thread.id] ?? 0
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.refresh(candidateId: auth.profile?.id) }
                }
            }
            .navigationTitle("Messages")
            .sheet(item: $openThread, onDismiss: {
                Task { await vm.refresh(candidateId: auth.profile?.id) }
            }) { _ in
                SafariView(url: AppConfig.webBaseURL.appendingPathComponent("candidate/messages"))
                    .ignoresSafeArea()
            }
            .task { await vm.refresh(candidateId: auth.profile?.id) }
        }
    }
}

struct ThreadRow: View {
    let thread: MessageThread
    let title: String
    let unread: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(unread > 0 ? Brand.teal.opacity(0.15) : Brand.surface)
                    .frame(width: 44, height: 44)
                Image(systemName: "envelope.fill")
                    .foregroundColor(unread > 0 ? Brand.teal : Brand.slate)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(unread > 0 ? .medium : .regular))
                    .foregroundColor(Brand.navy)
                    .lineLimit(1)
                Text(thread.readablePreview ?? (unread > 0 ? "New message — tap to read" : "Tap to view conversation"))
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(thread.lastMessageAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundColor(Brand.slate)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Brand.teal)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(Brand.surface.opacity(unread > 0 ? 0.8 : 0.4))
        .cornerRadius(14)
    }
}
