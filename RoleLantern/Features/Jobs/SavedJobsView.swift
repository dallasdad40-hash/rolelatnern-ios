import SwiftUI

struct SavedJobsView: View {
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var jobsVM = JobsViewModel()
    @State private var savedJobs: [BoardJob] = []
    @State private var isLoading = true

    private let data = DataService()

    var body: some View {
        NavigationStack {
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
                                JobRowView(job: job, isSaved: true)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .onDelete { indexSet in
                            Task { await unsave(at: indexSet) }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Saved")
            .navigationDestination(for: BoardJob.self) { job in
                JobDetailView(job: job, jobsVM: jobsVM)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let profile = auth.profile else {
            isLoading = false
            return
        }
        isLoading = true
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

    private func unsave(at indexSet: IndexSet) async {
        guard let profile = auth.profile else { return }
        for index in indexSet {
            let job = savedJobs[index]
            try? await data.unsaveJob(candidateId: profile.id, jobId: job.id)
        }
        savedJobs.remove(atOffsets: indexSet)
    }
}
