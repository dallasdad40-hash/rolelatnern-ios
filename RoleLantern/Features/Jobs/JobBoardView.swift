import SwiftUI

struct JobBoardView: View {
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var vm = JobsViewModel()
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.jobs.isEmpty {
                    ProgressView("Lighting the way…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.jobs.isEmpty {
                    EmptyStateView(
                        title: "No roles found",
                        message: vm.hasActiveFilters
                            ? "Try broadening your filters."
                            : "New life-science roles are added daily — check back soon."
                    )
                } else {
                    List(vm.jobs) { job in
                        NavigationLink(value: job) {
                            JobRowView(job: job, isSaved: vm.savedJobIds.contains(job.id))
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Jobs")
            .navigationDestination(for: BoardJob.self) { job in
                JobDetailView(job: job, jobsVM: vm)
            }
            .searchable(text: $vm.search, prompt: "Search title, company…")
            .onSubmit(of: .search) { Task { await vm.load() } }
            .onChange(of: vm.search) { newValue in
                if newValue.isEmpty { Task { await vm.load() } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: vm.hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                JobFiltersSheet(vm: vm)
            }
            .task {
                await vm.load()
                if let profile = auth.profile {
                    await vm.loadCandidateState(candidateId: profile.id)
                }
            }
        }
    }
}

struct JobRowView: View {
    let job: BoardJob
    let isSaved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if job.isBoosted { BoostedBadge() }
                FreshnessBadge(status: job.jobFreshnessStatus)
                Spacer()
                if isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundColor(Brand.teal)
                }
            }
            Text(job.jobTitle)
                .font(.body.weight(.medium))
                .foregroundColor(Brand.navy)
            Text(job.companyName)
                .font(.subheadline)
                .foregroundColor(Brand.slate)
            HStack(spacing: 6) {
                if let location = job.locationText, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                Label(job.remoteStatus.replacingOccurrences(of: "_", with: " ").capitalized,
                      systemImage: "laptopcomputer")
            }
            .font(.caption)
            .foregroundColor(Brand.slate)

            if !job.functionTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(job.functionTags.prefix(3), id: \.self) { TagChip(text: $0) }
                        ForEach(job.therapeuticAreaTags.prefix(2), id: \.self) {
                            TagChip(text: $0, color: Brand.navy)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Brand.surface.opacity(0.6))
        .cornerRadius(14)
    }
}

struct JobFiltersSheet: View {
    @ObservedObject var vm: JobsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Function") {
                    Picker("Function", selection: $vm.functionTag) {
                        Text("Any").tag(String?.none)
                        ForEach(vm.availableFunctions, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Section("Therapeutic area") {
                    Picker("Therapeutic area", selection: $vm.therapeuticArea) {
                        Text("Any").tag(String?.none)
                        ForEach(vm.availableTherapeuticAreas, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Section("Location") {
                    TextField("City, state, or country", text: $vm.location)
                    Toggle("Remote only", isOn: $vm.remoteOnly)
                }
                Section {
                    Button("Clear filters", role: .destructive) {
                        vm.clearFilters()
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        dismiss()
                        Task { await vm.load() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
