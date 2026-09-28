import SwiftUI

/// Native Help Center: searchable answers plus a way to reach support.
struct HelpCenterView: View {
    @Environment(\.openURL) private var openURL
    @State private var search = ""

    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let items: [(q: String, a: String)]
    }

    private let topics: [Topic] = [
        Topic(title: "Getting started", icon: "flag", items: [
            ("How do I get started?",
             "Upload your CV from the Profile tab, run a Lantern AI CV Review to see your areas of need, then browse jobs. Jobs near you show first, plus remote roles."),
            ("Is RoleLantern free for candidates?",
             "Yes. Searching, saving, applying and messaging employers are free for candidates."),
        ]),
        Topic(title: "Jobs and applying", icon: "briefcase", items: [
            ("How do I save a job?",
             "Tap the bookmark on any job. Saved jobs are in My Jobs > Saved."),
            ("How do I stop seeing a job?",
             "Tap the thumbs-down on the job. It's hidden from your list, and you can tap Undo right after if it was a mistake."),
            ("Why do I see jobs near me first?",
             "RoleLantern uses your location to show local roles, plus remote roles. Change the distance with \"Change\" at the top of the Jobs screen."),
            ("Where can I see what I applied to?",
             "My Jobs > Applied shows every application and its latest status."),
            ("How do I clear roles I'm not interested in?",
             "In My Jobs, swipe left on an application or invite. Removing an unanswered invite also tells the employer you're not interested. Removing an application only clears it from your list."),
            ("What is an invite to apply?",
             "An employer thinks you fit a role and invited you to apply. Accept or decline it in My Jobs > Invites. Your identity stays hidden until you accept."),
        ]),
        Topic(title: "Your CV and Lantern AI", icon: "sparkles", items: [
            ("What does the Lantern AI CV Review do?",
             "It reads your CV like a life-science recruiter and shows a score, your areas of need, missing keywords, and suggested rewrites. You get 3 reviews a day."),
            ("Is my CV used to train AI?",
             "No. Your CV is sent securely to our AI provider only to produce your review, and it is not used to train AI models."),
            ("Which file types can I upload?",
             "PDF or Word (.docx), up to 10 MB. PDFs give the best results."),
        ]),
        Topic(title: "Privacy and your employer", icon: "hand.raised", items: [
            ("Can my current employer see me?",
             "No. Add your current employer in the Privacy Center and they can never see your profile, including their parent and sister companies."),
            ("Who can see my CV?",
             "Your CV stays private until you choose to apply. You control this in the Privacy Center."),
            ("How do I delete my account?",
             "Profile > Account settings > Delete my account. This permanently removes your account, CV, applications and messages."),
        ]),
        Topic(title: "Messages", icon: "envelope", items: [
            ("How do I delete a conversation?",
             "Swipe the conversation to the left and tap Delete. It's removed from your list only. If the employer writes again, it comes back."),
            ("Are my messages private?",
             "Yes. Messages are encrypted and only you and the employer in the conversation can read them."),
        ]),
        Topic(title: "Account and sign-in", icon: "person.crop.circle", items: [
            ("I can't sign in with Google.",
             "Make sure you pick the same Google account you used before. If you used Sign in with Apple with \"Hide my email\", that is a separate account."),
            ("How do I turn on Face ID?",
             "Menu > Settings > Security > Require Face ID to open."),
        ]),
    ]

    private var filtered: [Topic] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return topics }
        return topics.compactMap { t in
            let items = t.items.filter { $0.q.lowercased().contains(q) || $0.a.lowercased().contains(q) }
            return items.isEmpty ? nil : Topic(title: t.title, icon: t.icon, items: items)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { topic in
                Section {
                    ForEach(Array(topic.items.enumerated()), id: \.offset) { _, item in
                        DisclosureGroup {
                            Text(item.a)
                                .font(.subheadline)
                                .foregroundColor(Brand.slate)
                                .padding(.vertical, 4)
                        } label: {
                            Text(item.q)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.navy)
                        }
                    }
                } header: {
                    Label(topic.title, systemImage: topic.icon)
                }
            }

            if filtered.isEmpty {
                Text("No answers match \"\(search)\". Try another word, or contact us below.")
                    .font(.subheadline)
                    .foregroundColor(Brand.slate)
            }

            Section("Still need help?") {
                Button {
                    if let url = URL(string: "mailto:support@rolelantern.com?subject=RoleLantern%20app%20help") {
                        openURL(url)
                    }
                } label: {
                    Label("Email support@rolelantern.com", systemImage: "envelope.badge")
                }
                Button {
                    openURL(AppConfig.webBaseURL.appendingPathComponent("help"))
                } label: {
                    Label("Full Help Center on the web", systemImage: "safari")
                }
            }
        }
        .searchable(text: $search, prompt: "Search help")
        .navigationTitle("Help Center")
        .navigationBarTitleDisplayMode(.inline)
    }
}
