import Foundation
import SwiftUI
import Combine

@MainActor
final class JobsViewModel: ObservableObject {
    @Published var jobs: [BoardJob] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Filters
    @Published var search = ""
    @Published var functionTag: String?
    @Published var therapeuticArea: String?
    @Published var remoteOnly = false
    @Published var location = ""
    /// Local jobs by default; the choice is remembered on this device.
    @Published var nearMe = UserDefaults.standard.object(forKey: "prefNearMe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nearMe, forKey: "prefNearMe") }
    }
    @Published var radiusMiles = UserDefaults.standard.object(forKey: "prefRadiusMiles") as? Double ?? 50.0 {
        didSet { UserDefaults.standard.set(radiusMiles, forKey: "prefRadiusMiles") }
    }
    @Published var country: String?
    @Published var state: String?

    // Complete option lists (fetched once from helper views).
    @Published var allFunctions: [String] = []
    @Published var allTherapeuticAreas: [String] = []
    @Published var locationRows: [DataService.JobLocation] = []

    let locationService = LocationService()
    private var bag = Set<AnyCancellable>()

    init() {
        // Reload once coordinates arrive after the user enables "Near me".
        locationService.$latitude
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.nearMe else { return }
                Task { await self.load() }
            }
            .store(in: &bag)
        // Ask for location right away when "near me" is the default.
        if nearMe { locationService.request() }
        // If location is refused, fall back to all jobs instead of an empty board.
        locationService.$denied
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.nearMe else { return }
                Task { await self.load() }
            }
            .store(in: &bag)
    }

    /// True when results are actually limited to the user's area.
    var isShowingNearby: Bool {
        nearMe && !locationService.denied && locationService.latitude != nil
    }

    func setNearMe(_ on: Bool, radius: Double? = nil) {
        if let radius { radiusMiles = radius }
        nearMe = on
        if on { locationService.request() }
        Task { await load() }
    }

    // Saved state
    @Published var savedJobIds: Set<UUID> = []
    @Published var appliedJobIds: Set<UUID> = []
    @Published var dismissedJobIds: Set<UUID> = []
    /// Last job marked "Not interested", kept briefly for Undo.
    @Published var recentlyDismissed: BoardJob?
    private var dismissedIndex = 0

    private let data = DataService()

    var hasActiveFilters: Bool {
        functionTag != nil || therapeuticArea != nil || remoteOnly || !location.isEmpty
            || country != nil || state != nil
    }

    /// Complete lists, with a fallback derived from loaded jobs.
    var availableFunctions: [String] {
        allFunctions.isEmpty ? Array(Set(jobs.flatMap(\.functionTags))).sorted() : allFunctions
    }
    var availableTherapeuticAreas: [String] {
        allTherapeuticAreas.isEmpty ? Array(Set(jobs.flatMap(\.therapeuticAreaTags))).sorted() : allTherapeuticAreas
    }

    /// Countries by job volume; states alphabetical within the chosen country.
    var availableCountries: [String] {
        Dictionary(grouping: locationRows, by: \.locCountry)
            .map { (country: $0.key, count: $0.value.reduce(0) { $0 + $1.jobCount }) }
            .sorted { $0.count > $1.count }
            .map(\.country)
    }
    var availableStates: [String] {
        guard let country else { return [] }
        return locationRows
            .filter { $0.locCountry == country }
            .compactMap(\.locState)
            .filter { !$0.isEmpty }
            .sorted()
    }

    func loadFilterOptions() async {
        guard allFunctions.isEmpty else { return }
        if let tags = try? await data.fetchFilterTags() {
            allFunctions = tags.filter { $0.kind == "function" }.map(\.value).sorted()
            allTherapeuticAreas = tags.filter { $0.kind == "therapeutic_area" }.map(\.value).sorted()
        }
        if let rows = try? await data.fetchJobLocations() {
            locationRows = rows
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let lat = nearMe ? locationService.latitude : nil
            let lng = nearMe ? locationService.longitude : nil
            if let lat, let lng, !remoteOnly {
                // Near me: local roles (nearest first) plus a short list of remote roles.
                // Two queries, so nationwide remote jobs can't crowd out the local ones.
                async let local = data.fetchJobs(
                    search: search, functionTag: functionTag, therapeuticArea: therapeuticArea,
                    remoteOnly: false, location: location, country: country, state: state,
                    nearLat: lat, nearLng: lng, radiusMiles: radiusMiles,
                    includeRemoteWhenNear: false)
                async let remote = data.fetchJobs(
                    search: search, functionTag: functionTag, therapeuticArea: therapeuticArea,
                    remoteOnly: true, location: location, country: country, state: state)
                let (localJobs, remoteJobs) = try await (local, remote)
                let localIds = Set(localJobs.map(\.id))
                jobs = localJobs + remoteJobs.filter { !localIds.contains($0.id) }.prefix(30)
            } else {
                jobs = try await data.fetchJobs(
                    search: search,
                    functionTag: functionTag,
                    therapeuticArea: therapeuticArea,
                    remoteOnly: remoteOnly,
                    location: location,
                    country: country,
                    state: state,
                    nearLat: lat,
                    nearLng: lng,
                    radiusMiles: radiusMiles
                )
            }
            jobs.removeAll { dismissedJobIds.contains($0.id) }
        } catch {
            errorMessage = "Could not load jobs. Check your connection and try again."
        }
    }

    func notInterested(_ job: BoardJob, candidateId: UUID?) async {
        guard let candidateId else {
            errorMessage = "Your profile hasn't loaded yet. Open the Dashboard tab once, then try again."
            return
        }
        dismissedIndex = jobs.firstIndex(of: job) ?? 0
        withAnimation { jobs.removeAll { $0.id == job.id } }
        dismissedJobIds.insert(job.id)
        recentlyDismissed = job
        do {
            try await data.dismissJob(candidateId: candidateId, jobId: job.id)
        } catch {
            dismissedJobIds.remove(job.id)
            withAnimation { jobs.insert(job, at: min(dismissedIndex, jobs.count)) }
            recentlyDismissed = nil
            errorMessage = "Could not hide that job. Please try again."
            return
        }
        try? await Task.sleep(for: .seconds(5))
        if recentlyDismissed?.id == job.id { withAnimation { recentlyDismissed = nil } }
    }

    func undoNotInterested(candidateId: UUID?) async {
        guard let job = recentlyDismissed, let candidateId else { return }
        withAnimation {
            recentlyDismissed = nil
            jobs.insert(job, at: min(dismissedIndex, jobs.count))
        }
        dismissedJobIds.remove(job.id)
        try? await data.undismissJob(candidateId: candidateId, jobId: job.id)
    }

    func loadCandidateState(candidateId: UUID) async {
        if let saved = try? await data.fetchSavedJobs(candidateId: candidateId) {
            savedJobIds = Set(saved.map(\.jobId))
        }
        if let dismissed = try? await data.fetchDismissedJobIds(candidateId: candidateId) {
            dismissedJobIds = dismissed
            jobs.removeAll { dismissed.contains($0.id) }
        }
        if let apps = try? await data.fetchApplications(candidateId: candidateId) {
            appliedJobIds = Set(apps.filter { $0.applicationType == "platform_application" }.map(\.jobId))
        }
    }

    func toggleSave(candidateId: UUID?, jobId: UUID) async {
        guard let candidateId else {
            errorMessage = "Your profile hasn't loaded yet — open the Dashboard tab once, then try again."
            return
        }
        do {
            if savedJobIds.contains(jobId) {
                try await data.unsaveJob(candidateId: candidateId, jobId: jobId)
                savedJobIds.remove(jobId)
            } else {
                try await data.saveJob(candidateId: candidateId, jobId: jobId)
                savedJobIds.insert(jobId)
            }
        } catch {
            errorMessage = "Could not update saved jobs: \(error.localizedDescription)"
        }
    }

    func clearFilters() {
        functionTag = nil
        therapeuticArea = nil
        remoteOnly = false
        location = ""
        // "Near me" is a preference, not a filter; clearing filters keeps it.
        search = ""
        country = nil
        state = nil
    }
}
