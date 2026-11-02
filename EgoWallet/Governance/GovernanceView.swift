import EgoKit
import SwiftUI

/// DAO voting: proposals, stake votes, knowledge votes, results, new proposals and
/// reports against spam proposers.
struct GovernanceView: View {
    @EnvironmentObject private var app: AppModel
    @State private var proposals: [Dao.Proposal]?
    @State private var limits: Dao.Limits?
    @State private var showActive = true
    @State private var creating = false
    @State private var problem: String?
    @State private var note: String?

    private var shown: [Dao.Proposal] {
        (proposals ?? []).filter { showActive ? $0.isActive : !$0.isActive }
    }

    var body: some View {
        Form {
            PageTitle("Governance")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                Text("Holders decide on changes to Ego. A stake vote counts your staked EGOC. A knowledge vote counts how well you answer the proposal's questions; your answers stay hidden until voting ends, and this iPhone reveals them for you.")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
                NavigationLink(value: StakingPage()) { Label("Staking", systemImage: "lock.circle") }
            }
            if let limits, !limits.active {
                Section { Text("DAO voting isn't on the chain yet.").font(.footnote) }
            }
            Section {
                Picker("Show", selection: $showActive) {
                    Text("Open").tag(true)
                    Text("Ended").tag(false)
                }
                .pickerStyle(.segmented)
                if proposals == nil && problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if shown.isEmpty {
                    Text(showActive ? "No open proposals." : "No ended proposals.").font(.footnote).foregroundStyle(Brand.muted)
                }
                ForEach(shown) { p in
                    NavigationLink(value: ProposalPage(id: p.id)) { ProposalRow(proposal: p, mine: p.creator == app.address) }
                }
            }
            if let limits, limits.active {
                Section {
                    Button { creating = true } label: { Label("New proposal", systemImage: "plus.circle") }
                        .disabled(limits.left == 0 || limits.banned)
                    Text(limits.banned ? "Staked holders reported this wallet, so it can't create proposals for now."
                         : "\(limits.left) of \(limits.max) proposals left this month.")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
            }
            if let note {
                Section { Text(note).font(.footnote) }
            }
            if let problem {
                Section { Text(problem).font(.footnote).foregroundStyle(Brand.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $creating) {
            if let limits {
                NavigationStack {
                    NewProposalView(limits: limits) { id in
                        creating = false
                        note = "Proposal sent. It appears here once the next block includes it (\(id))."
                        Task { await load() }
                    }
                }
            }
        }
    }

    private func load() async {
        if await app.sendDueDaoReveals() > 0 {
            note = "Voting ended on a proposal, so this iPhone revealed your hidden answers."
        }
        do {
            async let list = app.daoProposals()
            async let l = app.daoLimits()
            let (fetched, fetchedLimits) = try await (list, l)
            proposals = fetched
            limits = fetchedLimits
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }
}

struct ProposalPage: Hashable {
    let id: String
}

private struct ProposalRow: View {
    let proposal: Dao.Proposal
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(proposal.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            HStack(spacing: 8) {
                Text(proposal.kind.capitalized)
                Text(proposal.isActive ? "Ends \(relative(proposal.endsAt))" : proposal.status.capitalized)
                if mine { Text("Yours") }
                if proposal.hasVoted { Text("Voted").foregroundStyle(Brand.lime) }
            }
            .font(.caption)
            .foregroundStyle(Brand.muted)
        }
        .padding(.vertical, 2)
    }

    private func relative(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named))
    }
}

/// One proposal: what it asks, your vote, the results, and reporting its creator.
struct ProposalView: View {
    @EnvironmentObject private var app: AppModel
    let id: String
    @State private var detail: Dao.Detail?
    @State private var ban: Dao.BanStatus?
    @State private var option: Int?
    @State private var answers: [Int?] = []
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false
    @State private var confirmingReport = false
    @State private var confirmingWithdraw = false

    var body: some View {
        Form {
            if let p = detail?.proposal {
                Section {
                    Text(p.title).font(.headline)
                    Text(p.description).font(.footnote)
                    HStack {
                        Text(p.kind.capitalized)
                        Spacer()
                        Text(p.isActive ? "Voting ends \(date(p.endsAt))" : "Ended \(date(p.endsAt))")
                    }
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                    Text("By \(shortAddress(p.creator))").font(.caption).foregroundStyle(Brand.muted)
                }
                if p.isActive && !p.hasVoted {
                    vote(p)
                } else if p.hasVoted {
                    Section("Your vote") {
                        if let o = p.myStakeVote, o < p.options.count { Text("Stake vote: \(p.options[o])").font(.footnote) }
                        if let o = p.myKnowledgeVote, o < p.options.count { Text("Knowledge vote: \(p.options[o])").font(.footnote) }
                        if let score = p.myTestScore {
                            Text("Your test score: \(score.formatted(.percent.precision(.fractionLength(0))))").font(.footnote)
                        } else if p.myKnowledgeVote != nil {
                            Text(p.answersRevealed ? "This iPhone reveals your answers next time you open Governance." : "Your answers stay hidden until the creator reveals the right ones after voting ends.")
                                .font(.caption).foregroundStyle(Brand.muted)
                        }
                    }
                }
                if let r = detail?.results { results(p, r) }
                creatorSection(p)
            } else if problem == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let note {
                Section { Text(note).font(.footnote) }
            }
            if let problem {
                Section { Text(problem).font(.footnote).foregroundStyle(Brand.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Proposal")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Report this proposer for spam?", isPresented: $confirmingReport, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                if let p = detail?.proposal { Task { await run("Reported.") { try await app.reportProposer(p.creator) } } }
            }
        } message: {
            Text("Your stake stays locked for 30 days. Enough reports from staked holders stop this address creating proposals.")
        }
        .confirmationDialog("Withdraw your proposal?", isPresented: $confirmingWithdraw, titleVisibility: .visible) {
            Button("Withdraw", role: .destructive) {
                if let p = detail?.proposal { Task { await run("Withdrawn.") { try await app.withdrawProposal(p) } } }
            }
        }
    }

    @ViewBuilder
    private func vote(_ p: Dao.Proposal) -> some View {
        Section("Your choice") {
            Picker("Option", selection: $option) {
                Text("Choose").tag(Int?.none)
                ForEach(p.options.indices, id: \.self) { i in Text(p.options[i]).tag(Int?.some(i)) }
            }
            Button("Vote with my stake") {
                if let option { Task { await run("Voted. Your stake stays locked until voting ends.") { try await app.stakeVote(p, option: option) } } }
            }
            .disabled(busy || option == nil)
        }
        if let questions = p.questions, !questions.isEmpty {
            Section("Knowledge vote") {
                Text("Answer the questions to vote by knowledge. Your answers are hidden until voting ends.")
                    .font(.caption).foregroundStyle(Brand.muted)
                ForEach(questions.indices, id: \.self) { qi in
                    let q = questions[qi]
                    Picker(q.question, selection: answerBinding(qi, count: questions.count)) {
                        Text("Choose").tag(Int?.none)
                        ForEach(q.options.indices, id: \.self) { oi in Text(q.options[oi]).tag(Int?.some(oi)) }
                    }
                    .pickerStyle(.navigationLink)
                }
                Button("Vote with my answers") {
                    if let option { Task { await knowledgeVote(p, option: option) } }
                }
                .disabled(busy || option == nil || answers.count != questions.count || answers.contains(where: { $0 == nil }))
            }
        }
    }

    private func answerBinding(_ i: Int, count: Int) -> Binding<Int?> {
        Binding(
            get: { answers.indices.contains(i) ? answers[i] : nil },
            set: { value in
                if answers.count != count { answers = Array(repeating: nil, count: count) }
                answers[i] = value
            }
        )
    }

    @ViewBuilder
    private func results(_ p: Dao.Proposal, _ r: Dao.Results) -> some View {
        Section("Results") {
            let total = max(r.options.map(\.combinedPower).reduce(0, +), .leastNonzeroMagnitude)
            ForEach(r.options.indices, id: \.self) { i in
                let o = r.options[i]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(o.option).font(.footnote.weight(r.winningOptionIndex == i ? .bold : .regular))
                        Spacer()
                        Text((o.combinedPower / total).formatted(.percent.precision(.fractionLength(0)))).font(.footnote)
                    }
                    ProgressView(value: o.combinedPower / total).tint(r.winningOptionIndex == i ? Brand.lime : Brand.muted)
                }
            }
            Text("\(r.totalStakeVoters) stake votes · \(r.totalKnowledgeVoters) knowledge votes · \(Amount.format(r.totalStakedInVotes)) EGOC staked in votes")
                .font(.caption).foregroundStyle(Brand.muted)
            Text(r.quorumReached ? "Enough stake has voted for the result to count." : "Not enough stake has voted yet for the result to count.")
                .font(.caption).foregroundStyle(r.quorumReached ? Brand.muted : Brand.warning)
        }
    }

    @ViewBuilder
    private func creatorSection(_ p: Dao.Proposal) -> some View {
        if p.creator == app.address {
            if p.isActive {
                Section { Button("Withdraw proposal", role: .destructive) { confirmingWithdraw = true }.disabled(busy) }
            }
        } else {
            Section("Proposer") {
                if let ban {
                    Text(ban.banned ? "Reported by enough staked holders; can't create proposals for now."
                         : "\(ban.voteCount) of \(ban.threshold) reports needed to stop this proposer.")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
                if ban?.myVote == true {
                    Text("You reported this proposer.").font(.caption)
                } else {
                    Button("Report as spam", role: .destructive) { confirmingReport = true }.disabled(busy)
                }
            }
        }
    }

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func knowledgeVote(_ p: Dao.Proposal, option: Int) async {
        let picked = answers.compactMap { $0 }
        guard picked.count == p.questionCount else { return }
        await run("Voted. This iPhone keeps your answers and reveals them after voting ends; open Governance then.") {
            try await app.knowledgeVote(p, option: option, answers: picked)
        }
    }

    private func load() async {
        do {
            let d = try await app.daoProposal(id)
            detail = d
            if d.proposal.creator != app.address { ban = try? await app.daoBanStatus(of: d.proposal.creator) }
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }

    private func run(_ success: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            note = success
            problem = nil
            await load()
        } catch {
            problem = app.message(for: error)
        }
    }
}

/// A new proposal, with an optional knowledge test whose right answers stay on this
/// iPhone until voting ends.
struct NewProposalView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let limits: Dao.Limits
    let done: (String) -> Void
    @State private var title = ""
    @State private var description = ""
    @State private var kind = "feature"
    @State private var options = ["Yes", "No"]
    @State private var days = 7
    @State private var questions: [Draft] = []
    @State private var problem: String?
    @State private var busy = false

    struct Draft: Identifiable {
        let id = UUID()
        var question = ""
        var options = ["", ""]
        var right = 0
    }

    var body: some View {
        Form {
            Section("Proposal") {
                TextField("Title", text: $title)
                TextField("What should change, and why", text: $description, axis: .vertical).lineLimit(4...10)
                Picker("Kind", selection: $kind) {
                    ForEach(limits.kinds, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Stepper("Voting lasts \(days) day\(days == 1 ? "" : "s")", value: $days, in: limits.minDays...limits.maxDays)
            }
            Section("Options") {
                ForEach(options.indices, id: \.self) { i in
                    TextField("Option \(i + 1)", text: $options[i])
                }
                if options.count < limits.maxOptions {
                    Button("Add option") { options.append("") }
                }
                if options.count > 2 {
                    Button("Remove last option", role: .destructive) { options.removeLast() }
                }
            }
            Section {
                ForEach($questions) { $q in
                    VStack(alignment: .leading) {
                        TextField("Question", text: $q.question)
                        ForEach(q.options.indices, id: \.self) { i in
                            HStack {
                                TextField("Answer \(i + 1)", text: $q.options[i])
                                Button { q.right = i } label: {
                                    Image(systemName: q.right == i ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if q.options.count < limits.maxQuestionOptions {
                            Button("Add answer") { q.options.append("") }.buttonStyle(.borderless)
                        }
                    }
                }
                if questions.count < limits.maxQuestions {
                    Button("Add a question") { questions.append(Draft()) }
                }
                if !questions.isEmpty {
                    Button("Remove last question", role: .destructive) { questions.removeLast() }
                }
            } header: {
                Text("Knowledge test (optional)")
            } footer: {
                Text("Tick the right answer of each question. It stays on this iPhone until voting ends; open Governance in the week after, so it can reveal the answers. If it doesn't, knowledge votes on this proposal don't count.")
            }
            if let problem {
                Section { Text(problem).font(.footnote).foregroundStyle(Brand.danger) }
            }
            Section {
                Button(busy ? "Sending…" : "Create proposal") { Task { await create() } }.disabled(busy)
            }
        }
        .navigationTitle("New proposal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func check() -> String? {
        let opts = options.map(trimmed)
        if trimmed(title).isEmpty || title.utf8.count > limits.maxTitleBytes { return "Give it a title of up to \(limits.maxTitleBytes) characters." }
        if trimmed(description).isEmpty || description.utf8.count > limits.maxDescriptionBytes { return "Describe it in up to \(limits.maxDescriptionBytes) characters." }
        if opts.contains(where: { $0.isEmpty || $0.utf8.count > limits.maxOptionBytes }) { return "Fill in every option, up to \(limits.maxOptionBytes) characters each." }
        if Set(opts).count != opts.count { return "Each option has to be different." }
        for q in questions {
            if trimmed(q.question).isEmpty || q.question.utf8.count > limits.maxQuestionBytes { return "Fill in every question, up to \(limits.maxQuestionBytes) characters." }
            if q.options.map(trimmed).contains(where: \.isEmpty) { return "Fill in every answer of every question." }
        }
        return nil
    }

    private func create() async {
        if let problem = check() {
            self.problem = problem
            return
        }
        busy = true
        defer { busy = false }
        do {
            let id = try await app.createProposal(
                title: trimmed(title), description: description, kind: kind, options: options.map(trimmed), days: UInt32(days),
                questions: questions.map { Dao.Question(question: trimmed($0.question), options: $0.options.map(trimmed)) },
                rightAnswers: questions.map(\.right))
            done(id)
        } catch {
            problem = app.message(for: error)
        }
    }
}
