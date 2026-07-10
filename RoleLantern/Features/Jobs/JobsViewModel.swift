import Foundation
import SwiftUI

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

    // Saved state
    @Published var savedJobIds: Set<UUID> = []
    @Published var appliedJobIds: Set<UUID> = []

    private let data = DataService()

    var hasActiveFilters: Bool {
        functionTag != nil || therapeuticArea != nil || remoteOnly || !location.isEmpty
    }

    /// Filter options derived from live data (tags on currently loaded jobs).
    var availableFunctions: [String] {
        Array(Set(jobs.flatMap(\.functionTags))).sorted()
    }
    var availableTherapeuticAreas: [String] {
        Array(Set(jobs.flatMap(\.therapeuticAreaTags))).sorted()
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
                location: location
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

    func toggleSave(candidateId: UUID, jobId: UUID) async {
        do {
            if savedJobIds.contains(jobId) {
                try await data.unsaveJob(candidateId: candidateId, jobId: jobId)
                savedJobIds.remove(jobId)
            } else {
                try await data.saveJob(candidateId: candidateId, jobId: jobId)
                savedJobIds.insert(jobId)
            }
        } catch {
            errorMessage = "Could not update saved jobs."
        }
    }

    func clearFilters() {
        functionTag = nil
        therapeuticArea = nil
        remoteOnly = false
        location = ""
    }
}
