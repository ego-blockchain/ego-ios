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
        GlassPage {
            PageTitle("Governance", subtitle: "Holders decide what changes in Ego")
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            HStack(spacing: 10) {
                shortcut("Staking", "lock.circle.fill", StakingPage())
                shortcut("Theft holds", "hand.raised.fill", HoldsPage())
            }
            if let limits, !limits.active {
                NoteCard(text: "DAO voting isn't on the chain yet.", icon: "clock.fill", tint: Brand.warning)
            }
            if let limits, limits.active { newProposalCard(limits) }
            GlassSegments(selection: $showActive, options: [true, false]) { $0 ? "Open" : "Ended" }
            if proposals == nil && problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 30)
            } else if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: showActive ? "checkmark.seal" : "archivebox")
                        .font(.system(size: 30, weight: .semibold)).foregroundStyle(Brand.muted)
                    Text(showActive ? "No open proposals right now." : "No ended proposals yet.")
                        .font(.subheadline).foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            ForEach(shown) { p in
                NavigationLink(value: ProposalPage(id: p.id)) { ProposalRow(proposal: p, mine: p.creator == app.address) }
                    .buttonStyle(.plain)
            }
            NoteCard(text: "A stake vote counts your staked EGOC. A knowledge vote counts how well you answer the proposal's questions; your answers stay hidden until voting ends, and this iPhone reveals them for you.")
        }
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

    private func shortcut<V: Hashable>(_ title: String, _ icon: String, _ value: V) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(Brand.lime)
                Text(title).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Brand.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.muted)
            }
            .padding(14)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func newProposalCard(_ limits: Dao.Limits) -> some View {
        Button { creating = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 46, height: 46)
                    .background(Brand.glow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New proposal").font(.system(.headline, design: .rounded)).foregroundStyle(Brand.text)
                    Text(limits.banned ? "Staked holders reported this wallet, so it can't propose for now."
                         : "\(limits.left) of \(limits.max) left this month")
                        .font(.caption).foregroundStyle(limits.banned ? Brand.warning : Brand.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Brand.lime.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(limits.left == 0 || limits.banned)
        .opacity(limits.left == 0 || limits.banned ? 0.5 : 1)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Tag(text: proposal.kindLabel, tint: Brand.sky)
                if proposal.hasKnowledgeTest { Tag(text: "Knowledge test", tint: Brand.violet) }
                if mine { Tag(text: "Yours", tint: Brand.amber) }
                Spacer(minLength: 0)
                if proposal.hasVoted {
                    Label("Voted", systemImage: "checkmark.circle.fill")
                        .font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Brand.lime)
                }
            }
            Text(proposal.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Brand.text)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(proposal.isActive ? "Ends \(relative(proposal.endsAt))" : proposal.status.capitalized,
                      systemImage: proposal.isActive ? "clock" : "flag.checkered")
                Label("\(proposal.stakeVoteCount + proposal.knowledgeVoteCount)", systemImage: "person.3.fill")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(Brand.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.1)))
    }

    private func relative(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named))
    }
}

/// A small coloured label on a card.
struct Tag: View {
    let text: String
    var tint: Color = Brand.lime

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
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
        GlassPage {
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            if let p = detail?.proposal {
                header(p)
                if p.isActive && !p.hasVoted {
                    vote(p)
                } else if p.hasVoted {
                    yourVote(p)
                }
                if let r = detail?.results { results(p, r) }
                creatorSection(p)
            } else if problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
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

    private func header(_ p: Dao.Proposal) -> some View {
        GlassCard {
            HStack(spacing: 6) {
                Tag(text: p.kindLabel, tint: Brand.sky)
                Tag(text: p.isActive ? "Open" : p.status.capitalized, tint: p.isActive ? Brand.lime : Brand.muted)
                if p.hasKnowledgeTest { Tag(text: "Knowledge test", tint: Brand.violet) }
            }
            Text(p.title)
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Brand.text)
            if p.isArbiterVote, let target = p.target, !target.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.kind == "arbiter_add" ? "Address that would become a P2P arbiter" : "Arbiter address that would be removed")
                        .font(.caption).foregroundStyle(Brand.muted)
                    Text(target)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.text)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(p.description).font(.subheadline).foregroundStyle(Brand.text.opacity(0.85))
            HStack(spacing: 14) {
                Label(p.isActive ? "Ends \(date(p.endsAt))" : "Ended \(date(p.endsAt))", systemImage: "clock")
                Label(shortAddress(p.creator), systemImage: "person.crop.circle")
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
    }

    @ViewBuilder
    private func vote(_ p: Dao.Proposal) -> some View {
        GlassCard {
            SectionLabel(text: "Your choice")
            ForEach(p.options.indices, id: \.self) { i in
                choice(p.options[i], on: option == i) { option = i }
            }
            Button("Vote with my stake") {
                if let option { Task { await run("Voted. Your stake stays locked until voting ends.") { try await app.stakeVote(p, option: option) } } }
            }
            .buttonStyle(GlowButtonStyle())
            .disabled(busy || option == nil)
        }
        if let questions = p.questions, !questions.isEmpty {
            GlassCard {
                SectionLabel(text: "Or vote by knowledge")
                Text("Pick your choice above, then answer the questions. Your answers stay hidden until voting ends.")
                    .font(.caption).foregroundStyle(Brand.muted)
                ForEach(questions.indices, id: \.self) { qi in
                    let q = questions[qi]
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(qi + 1). \(q.question)")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Brand.text)
                        ForEach(q.options.indices, id: \.self) { oi in
                            let binding = answerBinding(qi, count: questions.count)
                            choice(q.options[oi], on: binding.wrappedValue == oi, compact: true) { binding.wrappedValue = oi }
                        }
                    }
                    .padding(.top, 4)
                }
                Button("Vote with my answers") {
                    if let option { Task { await knowledgeVote(p, option: option) } }
                }
                .buttonStyle(OutlineButtonStyle(tint: Brand.violet))
                .disabled(busy || option == nil || answers.count != questions.count || answers.contains(where: { $0 == nil }))
            }
        }
    }

    private func choice(_ text: String, on: Bool, compact: Bool = false, _ pick: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.snappy) { pick() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: compact ? 16 : 20, weight: .semibold))
                    .foregroundStyle(on ? Brand.lime : Brand.muted)
                Text(text)
                    .font(compact ? .footnote : .system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 10 : 14)
            .background((on ? Brand.lime : Color.white).opacity(on ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Brand.lime.opacity(0.6) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func yourVote(_ p: Dao.Proposal) -> some View {
        GlassCard(tint: Brand.lime) {
            Label("You voted", systemImage: "checkmark.seal.fill")
                .font(.system(.headline, design: .rounded)).foregroundStyle(Brand.lime)
            if let o = p.myStakeVote, o < p.options.count { Text("With your stake: \(p.options[o])").font(.subheadline).foregroundStyle(Brand.text) }
            if let o = p.myKnowledgeVote, o < p.options.count { Text("By knowledge: \(p.options[o])").font(.subheadline).foregroundStyle(Brand.text) }
            if let score = p.myTestScore {
                Text("Your test score: \(score.formatted(.percent.precision(.fractionLength(0))))").font(.subheadline).foregroundStyle(Brand.text)
            } else if p.myKnowledgeVote != nil {
                Text(p.answersRevealed ? "This iPhone reveals your answers next time you open Governance." : "Your answers stay hidden until the creator reveals the right ones after voting ends.")
                    .font(.caption).foregroundStyle(Brand.muted)
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

    private func results(_ p: Dao.Proposal, _ r: Dao.Results) -> some View {
        GlassCard {
            SectionLabel(text: p.isActive ? "Results so far" : "Results")
            let total = max(r.options.map(\.combinedPower).reduce(0, +), .leastNonzeroMagnitude)
            ForEach(r.options.indices, id: \.self) { i in
                let o = r.options[i]
                let share = o.combinedPower / total
                let wins = r.winningOptionIndex == i
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(o.option).font(.system(.subheadline, design: .rounded, weight: wins ? .bold : .medium)).foregroundStyle(Brand.text)
                        if wins { Image(systemName: "crown.fill").font(.caption).foregroundStyle(Brand.lime) }
                        Spacer()
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(wins ? Brand.lime : Brand.muted)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(wins ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Brand.muted.opacity(0.5)))
                                .frame(width: geo.size.width * share)
                        }
                    }
                    .frame(height: 8)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(label: "Stake votes", value: "\(r.totalStakeVoters)", icon: "lock.fill")
                StatTile(label: "Knowledge votes", value: "\(r.totalKnowledgeVoters)", icon: "brain.head.profile")
            }
            Label(r.quorumReached ? "Enough stake has voted for the result to count. \(Amount.format(r.totalStakedInVotes)) EGOC voted."
                  : "Not enough stake has voted yet for the result to count. \(Amount.format(r.totalStakedInVotes)) EGOC so far.",
                  systemImage: r.quorumReached ? "checkmark.circle.fill" : "hourglass")
                .font(.caption).foregroundStyle(r.quorumReached ? Brand.muted : Brand.warning)
        }
    }

    @ViewBuilder
    private func creatorSection(_ p: Dao.Proposal) -> some View {
        if p.creator == app.address {
            if p.isActive {
                Button("Withdraw proposal") { confirmingWithdraw = true }
                    .buttonStyle(OutlineButtonStyle(tint: Brand.danger)).disabled(busy)
            }
        } else {
            GlassCard {
                SectionLabel(text: "Proposer")
                if let ban {
                    Text(ban.banned ? "Reported by enough staked holders; can't create proposals for now."
                         : "\(ban.voteCount) of \(ban.threshold) reports needed to stop this proposer.")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
                if ban?.myVote == true {
                    Label("You reported this proposer.", systemImage: "flag.fill").font(.caption).foregroundStyle(Brand.text)
                } else {
                    Button { confirmingReport = true } label: { Label("Report as spam", systemImage: "flag") }
                        .buttonStyle(OutlineButtonStyle(tint: Brand.danger)).disabled(busy)
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
        GlassPage {
            GlassCard {
                SectionLabel(text: "Proposal")
                field("Title") { TextField("A short name for the change", text: $title).glassInput() }
                field("Description") {
                    TextField("What should change, and why", text: $description, axis: .vertical).lineLimit(4...10).glassInput()
                }
                field("Kind") { ChipPicker(selection: $kind, options: limits.kinds) }
                HStack {
                    Text("Voting lasts").font(.subheadline).foregroundStyle(Brand.muted)
                    Spacer()
                    Text("\(days) day\(days == 1 ? "" : "s")").font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Brand.text)
                    Stepper("", value: $days, in: limits.minDays...limits.maxDays).labelsHidden()
                }
            }
            GlassCard {
                SectionLabel(text: "Options")
                ForEach(options.indices, id: \.self) { i in
                    TextField("Option \(i + 1)", text: $options[i]).glassInput()
                }
                HStack {
                    if options.count < limits.maxOptions {
                        Button { options.append("") } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    if options.count > 2 {
                        Button { options.removeLast() } label: { Label("Remove", systemImage: "minus") }
                            .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                    }
                }
            }
            GlassCard {
                SectionLabel(text: "Knowledge test (optional)")
                Text("Tick the right answer of each question. It stays on this iPhone until voting ends; open Governance in the week after, so it can reveal the answers. If it doesn't, knowledge votes on this proposal don't count.")
                    .font(.caption).foregroundStyle(Brand.muted)
                ForEach($questions) { $q in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Question", text: $q.question).glassInput()
                        ForEach(q.options.indices, id: \.self) { i in
                            HStack(spacing: 10) {
                                Button { q.right = i } label: {
                                    Image(systemName: q.right == i ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20)).foregroundStyle(q.right == i ? Brand.lime : Brand.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Right answer")
                                TextField("Answer \(i + 1)", text: $q.options[i]).glassInput()
                            }
                        }
                        if q.options.count < limits.maxQuestionOptions {
                            Button { q.options.append("") } label: { Label("Add answer", systemImage: "plus") }
                                .font(.system(.footnote, design: .rounded, weight: .bold)).foregroundStyle(Brand.lime)
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                HStack {
                    if questions.count < limits.maxQuestions {
                        Button { questions.append(Draft()) } label: { Label("Add a question", systemImage: "plus") }
                            .buttonStyle(OutlineButtonStyle(tint: Brand.violet))
                    }
                    if !questions.isEmpty {
                        Button { questions.removeLast() } label: { Label("Remove", systemImage: "minus") }
                            .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                    }
                }
            }
            if let problem { ProblemBanner(text: problem) }
            Button(busy ? "Sending…" : "Create proposal") { Task { await create() } }
                .buttonStyle(GlowButtonStyle())
                .disabled(busy)
        }
        .closesKeyboardOnTapOutside()
        .navigationTitle("New proposal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Brand.muted)
            content()
        }
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
