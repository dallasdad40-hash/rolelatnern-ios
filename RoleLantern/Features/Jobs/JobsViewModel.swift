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
    @Published var nearMe = false
    @Published var radiusMiles = 50.0
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
    }

    // Saved state
    @Published var savedJobIds: Set<UUID> = []
    @Published var appliedJobIds: Set<UUID> = []

    private let data = DataService()

    var hasActiveFilters: Bool {
        functionTag != nil || therapeuticArea != nil || remoteOnly || !location.isEmpty
            || nearMe || country != nil || state != nil
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
            jobs = try await data.fetchJobs(
                search: search,
                functionTag: functionTag,
                therapeuticArea: therapeuticArea,
                remoteOnly: remoteOnly,
                location: location,
                country: country,
                state: state,
                nearLat: nearMe ? locationService.latitude : nil,
                nearLng: nearMe ? locationService.longitude : nil,
                radiusMiles: radiusMiles
            )
        } catch {
            errorMessage = "Could not load jobs. Check your connection and try again."
        }
    }

    func loadCandidateState(candidateId: UUID) async {
        if let saved = try? await data.fetchSavedJobs(candidateId: candidateId) {
            savedJobIds = Set(saved.map(\.jobId))
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
        nearMe = false
        search = ""
        country = nil
        state = nil
    }
}
