import SwiftUI

/// Shared so the tab badge stays in sync with the inbox.
@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var threads: [MessageThread] = []
    @Published var unreadByThread: [UUID: Int] = [:]
    /// Per-thread display info (company + job), keyed by thread id.
    @Published var companyByThread: [UUID: String] = [:]
    @Published var jobByThread: [UUID: String] = [:]
    @Published var isLoading = false

    private let data = DataService()

    var totalUnread: Int { unreadByThread.values.reduce(0, +) }

    func company(for thread: MessageThread) -> String {
        companyByThread[thread.id] ?? "Employer"
    }
    func jobTitle(for thread: MessageThread) -> String? {
        jobByThread[thread.id]
    }

    func refresh(candidateId: UUID?) async {
        guard let candidateId else { return }
        isLoading = threads.isEmpty
        defer { isLoading = false }
        do {
            let fetched = try await data.fetchThreads(candidateId: candidateId)
            threads = fetched
            unreadByThread = try await data.fetchUnreadCounts(threadIds: fetched.map(\.id))
            for thread in fetched where companyByThread[thread.id] == nil {
                if let jobId = thread.jobId, let job = try? await data.fetchJob(id: jobId) {
                    companyByThread[thread.id] = job.companyName
                    jobByThread[thread.id] = job.jobTitle
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
                        NavigationLink(value: thread) {
                            ThreadRow(
                                thread: thread,
                                company: vm.company(for: thread),
                                jobTitle: vm.jobTitle(for: thread),
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
            .navigationDestination(for: MessageThread.self) { thread in
                ConversationView(
                    thread: thread,
                    company: vm.company(for: thread),
                    jobTitle: vm.jobTitle(for: thread)
                )
                .onDisappear { Task { await vm.refresh(candidateId: auth.profile?.id) } }
            }
            .task { await vm.refresh(candidateId: auth.profile?.id) }
        }
    }
}

/// Native conversation: decrypted bubbles + reply, via the edge function.
struct ConversationView: View {
    let thread: MessageThread
    let company: String
    let jobTitle: String?

    @State private var messages: [DecryptedMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var sending = false
    @State private var errorText: String?

    private let data = DataService()

    var body: some View {
        VStack(spacing: 0) {
            // Who this conversation is with, and about which role.
            HStack(spacing: 10) {
                CompanyAvatar(name: company, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(company)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Brand.navy)
                    if let jobTitle {
                        Text("Re: \(jobTitle)")
                            .font(.caption)
                            .foregroundColor(Brand.slate)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Brand.surface.opacity(0.5))
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                EmptyStateView(title: "No messages yet",
                               message: "Say hello — your reply goes straight to the employer.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg).id(msg.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear {
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .foregroundColor(Brand.navy)
                    .padding(10)
                    .background(Brand.surface)
                    .cornerRadius(18)
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Brand.slate : Brand.teal)
                    }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Message problem", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await data.fetchMessages(threadId: thread.id)
        } catch {
            errorText = "Couldn't load this conversation: \(error.localizedDescription)"
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await data.sendMessage(threadId: thread.id, text: text)
            draft = ""
            messages = try await data.fetchMessages(threadId: thread.id)
        } catch {
            errorText = "Couldn't send: \(error.localizedDescription)"
        }
    }
}

struct MessageBubble: View {
    let message: DecryptedMessage

    var body: some View {
        HStack {
            if message.isFromCandidate { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.body ?? "(unreadable)")
                    .font(.subheadline)
                    .foregroundColor(message.isFromCandidate ? .white : Brand.navy)
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(message.isFromCandidate ? .white.opacity(0.7) : Brand.slate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isFromCandidate ? Brand.teal : Brand.surface)
            .cornerRadius(16)
            if !message.isFromCandidate { Spacer(minLength: 40) }
        }
    }
}

struct ThreadRow: View {
    let thread: MessageThread
    let company: String
    let jobTitle: String?
    let unread: Int

    var body: some View {
        HStack(spacing: 12) {
            CompanyAvatar(name: company, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(company)
                    .font(.subheadline.weight(unread > 0 ? .semibold : .medium))
                    .foregroundColor(Brand.navy)
                    .lineLimit(1)
                if let jobTitle {
                    Text("Re: \(jobTitle)")
                        .font(.caption)
                        .foregroundColor(Brand.teal)
                        .lineLimit(1)
                }
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
