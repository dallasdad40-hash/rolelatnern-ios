import SwiftUI

/// "You have 3 tasks to complete": short checklist that raises profile completion.
struct HomeTask: Identifiable, Equatable {
    enum Kind { case uploadCV, runReview, protectEmployer, turnOnLocation }
    let kind: Kind
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .uploadCV: return "Upload your CV"
        case .runReview: return "Run your Lantern AI CV Review"
        case .protectEmployer: return "Protect your current employer"
        case .turnOnLocation: return "Turn on location"
        }
    }
    var detail: String {
        switch kind {
        case .uploadCV: return "Get matched to roles and apply in one tap."
        case .runReview: return "See your areas of need and missing keywords."
        case .protectEmployer: return "Make sure your employer can never see you."
        case .turnOnLocation: return "See life-science jobs near you first."
        }
    }
    var button: String {
        switch kind {
        case .uploadCV: return "Upload CV"
        case .runReview: return "Review my CV"
        case .protectEmployer: return "Add employer"
        case .turnOnLocation: return "Turn on"
        }
    }
    var icon: String {
        switch kind {
        case .uploadCV: return "doc.badge.plus"
        case .runReview: return "sparkles"
        case .protectEmployer: return "hand.raised.fill"
        case .turnOnLocation: return "location.fill"
        }
    }
}

@MainActor
final class HomeTasksViewModel: ObservableObject {
    @Published var tasks: [HomeTask] = []

    func refresh(candidateId: UUID?, locationOff: Bool) async {
        var list: [HomeTask] = []
        if let candidateId {
            let cv = try? await DataService().fetchActiveCV(candidateId: candidateId)
            if cv == nil {
                list.append(HomeTask(kind: .uploadCV))
            } else if let latest = try? await CVReviewAPI().latest(), latest.0 == nil {
                list.append(HomeTask(kind: .runReview))
            }
            if let privacy = try? await CandidateAPI().privacy(), privacy.blockedEmployers.isEmpty {
                list.append(HomeTask(kind: .protectEmployer))
            }
        }
        if locationOff { list.append(HomeTask(kind: .turnOnLocation)) }
        tasks = list
    }
}

struct TasksCard: View {
    let tasks: [HomeTask]
    let onAction: (HomeTask) -> Void

    @State private var index = 0
    @AppStorage("homeTasksExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("You have")
                    Text("\(tasks.count)")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(Brand.teal))
                    Text(tasks.count == 1 ? "task to complete" : "tasks to complete")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .font(.title3.weight(.medium))
                .foregroundColor(Brand.navy)
            }
            .buttonStyle(.plain)

            if expanded, let task = tasks[safe: min(index, tasks.count - 1)] {
                VStack(alignment: .leading, spacing: 10) {
                    Label(task.title, systemImage: task.icon)
                        .font(.headline)
                        .foregroundColor(Brand.teal)
                    Text(task.detail)
                        .font(.subheadline)
                        .foregroundColor(Brand.navy)
                    Button(task.button) { onAction(task) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 4)
                }
                .padding(16)
                .background(Color.white)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.navy.opacity(0.08)))

                if tasks.count > 1 {
                    HStack {
                        Spacer()
                        Text("\(min(index, tasks.count - 1) + 1)/\(tasks.count)")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.navy)
                        Spacer()
                        Button { index = max(0, index - 1) } label: { Image(systemName: "arrow.left") }
                            .disabled(index == 0)
                            .accessibilityLabel("Previous task")
                        Button { index = min(tasks.count - 1, index + 1) } label: { Image(systemName: "arrow.right") }
                            .disabled(index >= tasks.count - 1)
                            .accessibilityLabel("Next task")
                            .padding(.leading, 20)
                    }
                    .font(.title3)
                    .foregroundColor(Brand.navy)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Brand.teal.opacity(0.14), Brand.gold.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(20)
        .onChange(of: tasks) { _ in index = 0 }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
