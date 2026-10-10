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

