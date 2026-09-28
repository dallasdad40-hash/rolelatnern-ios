import SwiftUI

/// "My Jobs": Saved, Applied and Invites in one place (like Indeed's My Jobs).
struct MyJobsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case saved = "Saved", applied = "Applied", invites = "Invites"
        var id: String { rawValue }
    }

    @EnvironmentObject var auth: AuthViewModel
    @EnvironmentObject var router: AppRouter
    @StateObject private var jobsVM = JobsViewModel()
    @StateObject private var invitesVM = InvitesViewModel()
    @State private var section: Section = .saved

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases) { s in
                        if s == .invites, invitesVM.openCount > 0 {
                            Text("Invites (\(invitesVM.openCount))").tag(s)
                        } else {
                            Text(s.rawValue).tag(s)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Text(section == .invites
                     ? "Swipe left on an invite to mark it Not interested or remove it."
                     : section == .applied
                        ? "Swipe left on a role to remove it from your tracker."
                        : "Tap the bookmark to remove a saved job.")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                switch section {
                case .saved: SavedJobsList(jobsVM: jobsVM)
                case .applied: ApplicationsView(declaresDestination: false)
                case .invites: InvitesView(vm: invitesVM, declaresDestination: false)
                }
            }
            .background(Brand.surface.ignoresSafeArea())
            .navigationTitle("My Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BoardJob.self) { job in
                JobDetailView(job: job, jobsVM: jobsVM)
            }
            .navigationDestination(for: UUID.self) { jobId in
                JobDetailLoader(jobId: jobId)
            }
            .navigationDestination(for: CandidateInvite.self) { invite in
                InviteDetailView(invite: invite, vm: invitesVM)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ProfileMenuButton() }
            }
            .task { await invitesVM.refresh() }
        }
    }
}

struct SavedJobsList: View {
    @EnvironmentObject var auth: AuthViewModel
    @ObservedObject var jobsVM: JobsViewModel
    @State private var savedJobs: [BoardJob] = []
    @State private var isLoading = true

    private let data = DataService()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if savedJobs.isEmpty {
                EmptyStateView(
                    title: "No saved jobs yet",
                    message: "Tap the bookmark on any role to keep it here."
                )
            } else {
                List {
                    ForEach(savedJobs) { job in
                        NavigationLink(value: job) {
                            JobRowView(
                                job: job,
                                isSaved: true,
                                onToggleSave: { Task { await unsave(job) } }
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let profile = auth.profile else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        do {
            let saved = try await data.fetchSavedJobs(candidateId: profile.id)
            jobsVM.savedJobIds = Set(saved.map(\.jobId))
            var jobs: [BoardJob] = []
            for record in saved {
                if let job = try? await data.fetchJob(id: record.jobId) {
                    jobs.append(job)
                }
            }
            savedJobs = jobs
            await jobsVM.loadCandidateState(candidateId: profile.id)
        } catch {
            savedJobs = []
        }
    }

    private func unsave(_ job: BoardJob) async {
        guard let profile = auth.profile else { return }
        withAnimation { savedJobs.removeAll { $0.id == job.id } }
        jobsVM.savedJobIds.remove(job.id)
        try? await data.unsaveJob(candidateId: profile.id, jobId: job.id)
    }
}
