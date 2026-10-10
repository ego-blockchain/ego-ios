import EgoKit
import SwiftUI

/// Shielded EGOC on the Wallet screen, as in Ego Desktop.
struct ShieldedCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Brand.lime.opacity(0.15))
                    .foregroundStyle(Brand.lime)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shielded").font(.headline).foregroundStyle(Brand.text)
                    Text(model.shieldedScanning ? "Looking for your notes…" : "\(Amount.format(model.shieldedBalance)) EGOC, private")
                        .font(.footnote).foregroundStyle(Brand.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted.opacity(0.6))
            }
            .card()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { ShieldedView() }
    }
}

struct ShieldedView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shielding = false
    @State private var unshielding = false

    private var unspent: [Shielded.Note] { model.shieldedNotes.filter { !$0.spent }.sorted { $0.value > $1.value } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Amount.format(model.shieldedBalance)) EGOC")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Brand.text)
                        Text("Shielded EGOC sits in the pool as fixed-size notes. Taking it out to an address doesn't show which notes were yours.")
                            .font(.footnote).foregroundStyle(Brand.muted)
                    }
                    HStack(spacing: 12) {
                        Button { shielding = true } label: { Label("Shield", systemImage: "lock.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { unshielding = true } label: { Label("Unshield", systemImage: "lock.open.fill") }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(unspent.isEmpty)
                    }
                    .listRowSeparator(.hidden)
                }
                if let problem = model.shieldedProblem {
                    Section { Text(problem).foregroundStyle(Brand.danger) }
                }
                Section("Your notes") {
                    if model.shieldedScanning && model.shieldedNotes.isEmpty {
                        HStack { ProgressView(); Text("Looking in the pool…").foregroundStyle(Brand.muted) }
                    } else if model.shieldedNotes.isEmpty {
                        Text("No shielded notes yet.").foregroundStyle(Brand.muted)
                    }
                    ForEach(model.shieldedNotes.sorted { ($0.spent ? 1 : 0, $1.value) < ($1.spent ? 1 : 0, $0.value) }) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Amount.format(note.value)) EGOC").font(.subheadline.weight(.semibold))
                                Text("Made on \(note.domain == "ios" ? "iPhone" : note.domain == "ext" ? "the browser extension" : "Ego Desktop")")
                                    .font(.caption).foregroundStyle(Brand.muted)
                            }
                            Spacer()
                            Text(note.spent ? "Spent" : "Ready").font(.caption.weight(.semibold))
                                .foregroundStyle(note.spent ? Brand.muted : Brand.mint)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Shielded")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await model.refreshShielded() }
            .task { await model.refreshShielded() }
            .sheet(isPresented: $shielding) { ShieldSheet() }
            .sheet(isPresented: $unshielding) { UnshieldSheet(notes: unspent) }
        }
    }
}

struct ShieldSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var fee: UInt64?
    @State private var busy = false
    @State private var problem: String?
    @State private var hashes: [String]?

    private var amount: UInt64? { Amount.parse(amountText) }
    private var plan: (notes: [UInt64], remainder: UInt64) { Shielded.denominate(amount ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                if let hashes {
                    Section {
                        Label("Shielding", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.mint)
                        Text("\(hashes.count) deposit\(hashes.count == 1 ? "" : "s") sent. The notes show once the network confirms them.")
                            .foregroundStyle(Brand.muted)
                    }
                    Section { Button("Done") { dismiss() } }
                } else {
                    Section {
                        TextField("0.00", text: $amountText).keyboardType(.decimalPad)
                    } header: {
                        Text("EGOC to shield")
                    } footer: {
                        Text("Notes come in 1, 10, 100, 1,000 and 10,000 EGOC. Each note is its own deposit and pays the network fee.")
                    }
                    if !plan.notes.isEmpty {
                        Section("This makes") {
                            ForEach(Array(Dictionary(grouping: plan.notes, by: { $0 }).sorted { $0.key > $1.key }), id: \.key) { value, list in
                                LabeledContent("\(list.count) × \(Amount.format(value)) EGOC", value: "")
                            }
                            if plan.remainder > 0 {
                                LabeledContent("Stays unshielded", value: "\(Amount.format(plan.remainder)) EGOC")
                            }
                            if let fee {
                                LabeledContent("Network fees", value: "\(Amount.format(fee * UInt64(plan.notes.count))) EGOC")
                            }
                        }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Shielding…" : "Shield \(Amount.format(plan.notes.reduce(0, +))) EGOC") { Task { await shield() } }
                            .disabled(plan.notes.isEmpty || busy)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Shield")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { fee = await model.networkFee() }
        }
    }

    private func shield() async {
        busy = true
        problem = nil
        do {
            hashes = try await model.shield(amount: plan.notes.reduce(0, +))
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}

struct UnshieldSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let notes: [Shielded.Note]
    @State private var chosen: Set<String> = []
    @State private var toOther = false
    @State private var recipient = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var result: (hash: String, payout: UInt64)?

    private var selected: [Shielded.Note] { notes.filter { chosen.contains($0.id) } }
    private var to: String { toOther ? recipient.trimmingCharacters(in: .whitespaces) : model.address }

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section {
                        Label("Withdrawal sent", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.mint)
                        LabeledContent("Pays out", value: "\(Amount.format(result.payout)) EGOC")
                        Text(result.hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Section { Button("Done") { dismiss() } }
                } else {
                    Section {
                        ForEach(notes) { note in
                            Button {
                                if chosen.contains(note.id) { chosen.remove(note.id) } else if chosen.count < Shielded.maxSpends { chosen.insert(note.id) }
                            } label: {
                                HStack {
                                    Image(systemName: chosen.contains(note.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(note.id) ? Brand.lime : Brand.muted)
                                    Text("\(Amount.format(note.value)) EGOC").foregroundStyle(Brand.text)
                                }
                            }
                        }
                    } header: {
                        Text("Notes to spend")
                    } footer: {
                        Text("Up to \(Shielded.maxSpends) notes at once.")
                    }
                    Section("Send to") {
                        Toggle("Another address", isOn: $toOther)
                        if toOther {
                            TextField("egot1…", text: $recipient)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !recipient.isEmpty && !EgoAddress.isValid(to) {
                                Text("That isn't an Ego address.").font(.caption).foregroundStyle(Brand.danger)
                            }
                        } else {
                            Text(shortAddress(model.address)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Brand.muted)
                        }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Proving on this iPhone…" : "Unshield \(Amount.format(selected.map(\.value).reduce(0, +))) EGOC") { Task { await unshield() } }
                            .disabled(selected.isEmpty || !EgoAddress.isValid(to) || busy)
                    } footer: {
                        Text("The phone makes a zero-knowledge proof for each note, which can take a little while. The network fee comes out of the notes.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Unshield")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
    }

    private func unshield() async {
        busy = true
        problem = nil
        do {
            result = try await model.unshield(selected, to: to)
            Task { await model.refreshShielded(); await model.refresh() }
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}
