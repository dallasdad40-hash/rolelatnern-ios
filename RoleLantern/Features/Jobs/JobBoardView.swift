import SwiftUI

struct JobBoardView: View {

    /// "Near McKinney, TX · 50 mi" with quick controls, or "All locations".
    private var nearbyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: vm.isShowingNearby ? "location.fill" : "globe.americas")
                .foregroundColor(Brand.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text(nearbyTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.navy)
                    .lineLimit(1)
                if vm.nearMe && vm.locationService.denied {
                    Text("Location is off. Turn it on in Settings to see local jobs.")
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                } else if vm.isShowingNearby {
                    Text("Plus remote roles")
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer()
            Menu {
                ForEach([25.0, 50.0, 100.0, 250.0], id: \.self) { miles in
                    Button {
                        vm.setNearMe(true, radius: miles)
                    } label: {
                        if vm.nearMe && vm.radiusMiles == miles {
                            Label("Within \(Int(miles)) miles", systemImage: "checkmark")
                        } else {
                            Text("Within \(Int(miles)) miles")
                        }
                    }
                }
                Divider()
                Button {
                    vm.setNearMe(false)
                } label: {
                    if vm.nearMe { Text("All locations") } else { Label("All locations", systemImage: "checkmark") }
                }
            } label: {
                Text("Change")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.teal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var nearbyTitle: String {
        guard vm.nearMe, !vm.locationService.denied else { return "Jobs in all locations" }
        guard vm.locationService.latitude != nil else { return "Finding jobs near you…" }
        let place = vm.locationService.placeName ?? "you"
        return "Near \(place) · \(Int(vm.radiusMiles)) mi"
    }

    @EnvironmentObject var auth: AuthViewModel
    @EnvironmentObject var router: AppRouter
    @StateObject private var vm = JobsViewModel()
    @StateObject private var tasksVM = HomeTasksViewModel()
    @State private var showFilters = false
    @State private var showReview = false

    private var locationOff: Bool { !vm.nearMe || vm.locationService.denied }

    private func handle(_ task: HomeTask) {
        switch task.kind {
        case .uploadCV, .updateCV: router.tab = .profile
        case .runReview: showReview = true
        case .protectEmployer: router.tab = .profile
        case .turnOnLocation: vm.setNearMe(true)
        }
    }

    private func refreshTasks() async {
        await tasksVM.refresh(candidateId: auth.profile?.id, locationOff: locationOff)
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.jobs.isEmpty {
                    ProgressView("Lighting the way…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.jobs.isEmpty && tasksVM.tasks.isEmpty {
                    EmptyStateView(
                        title: "No roles found",
                        message: vm.isShowingNearby
                            ? "No roles within \(Int(vm.radiusMiles)) miles yet. Try a wider distance or search everywhere."
                            : vm.hasActiveFilters
                                ? "Try broadening your filters."
                                : "New life-science roles are added daily. Check back soon."
                    )
                } else {
                    List {
                        if !tasksVM.tasks.isEmpty {
                            TasksCard(tasks: tasksVM.tasks, onAction: handle, onDismiss: { tasksVM.dismissForThirtyDays() })
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        }
                        if !vm.jobs.isEmpty {
                            Text(vm.isShowingNearby ? "Jobs near you" : "Latest life-science jobs")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(Brand.navy)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .padding(.top, 6)
                        }
                        ForEach(vm.jobs) { job in
                            NavigationLink(value: job) {
                                JobRowView(
                                    job: job,
                                    isSaved: vm.savedJobIds.contains(job.id),
                                    onToggleSave: {
                                        Task { await vm.toggleSave(candidateId: auth.profile?.id, jobId: job.id) }
                                    },
                                    onNotInterested: {
                                        Task { await vm.notInterested(job, candidateId: auth.profile?.id) }
                                    }
                                )
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Brand.surface)
                    .refreshable {
                        await vm.load()
                        await refreshTasks()
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { nearbyBar }
            .overlay(alignment: .bottom) {
                if vm.recentlyDismissed != nil {
                    HStack {
                        Label("Job hidden", systemImage: "hand.thumbsdown.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Button("Undo") {
                            Task { await vm.undoNotInterested(candidateId: auth.profile?.id) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.gold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Brand.navy, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showReview, onDismiss: { Task { await refreshTasks() } }) {
                NavigationStack { CVReviewView() }
            }
            .onChange(of: router.tab) { tab in
                if tab == .jobs { Task { await refreshTasks() } }
            }
            .onChange(of: vm.locationService.denied) { _ in Task { await refreshTasks() } }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BoardJob.self) { job in
                JobDetailView(job: job, jobsVM: vm)
            }
            .searchable(text: $vm.search, prompt: "Search title, company…")
            .onSubmit(of: .search) { Task { await vm.load() } }
            .onChange(of: vm.search) { newValue in
                if newValue.isEmpty { Task { await vm.load() } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        LanternMark(size: 32)
                        Text("RoleLantern")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("RoleLantern")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: vm.hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.title3)
                            .foregroundColor(Brand.navy)
                    }
                    .accessibilityLabel("Filters")
                    ProfileMenuButton()
                }
            }
            .sheet(isPresented: $showFilters) {
                JobFiltersSheet(vm: vm)
            }
            .alert("Something went wrong", isPresented: .init(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .task {
                await vm.load()
                await vm.loadFilterOptions()
                if auth.profile == nil { await auth.loadOrCreateProfile() }
                if let profile = auth.profile {
                    await vm.loadCandidateState(candidateId: profile.id)
                }
                await refreshTasks()
            }
        }
    }
}

struct JobRowView: View {
    let job: BoardJob
    let isSaved: Bool
    var onToggleSave: (() -> Void)? = nil
    var onNotInterested: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CompanyAvatar(name: job.companyName)
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if job.isBoosted { BoostedBadge() }
                FreshnessBadge(status: job.jobFreshnessStatus)
                Spacer()
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
                if let workMode = job.workModeLabel {
                    Label(workMode, systemImage: "laptopcomputer")
                }
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
            if onToggleSave != nil || onNotInterested != nil {
                VStack(spacing: 18) {
                    if let onToggleSave {
                        Button(action: onToggleSave) {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                .font(.title3)
                                .foregroundColor(isSaved ? Brand.teal : Brand.navy)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(isSaved ? "Remove from saved" : "Save job")
                    }
                    if let onNotInterested {
                        Button(action: onNotInterested) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.title3)
                                .foregroundColor(Brand.navy)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Not interested")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.navy.opacity(0.08)))
        .shadow(color: Brand.navy.opacity(0.04), radius: 6, y: 2)
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
                    Picker("Country", selection: $vm.country) {
                        Text("Anywhere").tag(String?.none)
                        ForEach(vm.availableCountries, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .onChange(of: vm.country) { _ in vm.state = nil }
                    if vm.country != nil, !vm.availableStates.isEmpty {
                        Picker("State / region", selection: $vm.state) {
                            Text("All").tag(String?.none)
                            ForEach(vm.availableStates, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    Toggle("Remote only", isOn: $vm.remoteOnly)
                    Toggle("Near me", isOn: $vm.nearMe)
                        .onChange(of: vm.nearMe) { isOn in
                            if isOn { vm.locationService.request() }
                        }
                    if vm.nearMe {
                        Picker("Within", selection: $vm.radiusMiles) {
                            Text("25 miles").tag(25.0)
                            Text("50 miles").tag(50.0)
                            Text("100 miles").tag(100.0)
                            Text("250 miles").tag(250.0)
                        }
                        if vm.locationService.denied {
                            Text("Location is off for RoleLantern — enable it in Settings to use Near me.")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                Section {
                    Button("Clear all filters", role: .destructive) {
                        vm.clearFilters()
                        dismiss()
                        Task { await vm.load() }
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
