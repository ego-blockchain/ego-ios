import EgoKit
import SwiftUI

enum Legal {
    static let terms = URL(string: "https://egoblockchain.com/terms")!
    static let privacy = URL(string: "https://egoblockchain.com/privacy")!
}

struct OnboardingView: View {
    @AppStorage("ego.legal.accepted") private var accepted = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                Spacer()
                EgoMark(size: 64)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ego Wallet")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(Brand.text)
                    Text("Hold EGOC, store files on Ego Desktop computers, chat with the community and trade peer to peer. Your keys never leave this iPhone.")
                        .font(.body)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
                VStack(spacing: 12) {
                    agreement
                    NavigationLink("Create a new wallet") { CreateWalletView() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!accepted)
                        .opacity(accepted ? 1 : 0.4)
                    NavigationLink("I already have a wallet") { ImportWalletView() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!accepted)
                        .opacity(accepted ? 1 : 0.4)
                }
            }
            .padding(24)
            .screenBackground()
        }
    }
}

extension OnboardingView {
    private var agreement: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                accepted.toggle()
            } label: {
                Image(systemName: accepted ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(accepted ? Brand.lime : Brand.muted)
            }
            .accessibilityLabel("I agree to the Terms of Service and Privacy Policy")
            .accessibilityValue(accepted ? "Checked" : "Not checked")
            Text("I agree to the [Terms of Service](https://egoblockchain.com/terms) and [Privacy Policy](https://egoblockchain.com/privacy).")
                .font(.footnote)
                .foregroundStyle(Brand.muted)
                .tint(Brand.lime)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }
}

struct CreateWalletView: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = EgoKey.generate()
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Write down these 24 words")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.text)
                Text("They are the only way to get your wallet back if you lose this iPhone. Write them on paper in this order and keep them somewhere safe. Anyone who sees them can take your coins.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                PhraseGrid(words: key.phrase)
                Button("I wrote them down") { confirming = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
        }
        .screenBackground()
        .navigationTitle("New wallet")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $confirming) {
            ConfirmPhraseView(key: key)
        }
    }
}

struct PhraseGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.muted)
                        .frame(width: 18, alignment: .trailing)
                    Text(word)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Brand.text)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(Brand.raised)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .privacySensitive()
    }
}

struct ConfirmPhraseView: View {
    @EnvironmentObject private var model: AppModel
    let key: EgoKey
    @State private var positions: [Int] = Array((0..<24).shuffled().prefix(3)).sorted()
    @State private var answers: [String] = ["", "", ""]
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Text("Type these words from your paper to make sure you have them right.")
                    .foregroundStyle(Brand.muted)
            }
            Section {
                ForEach(0..<3, id: \.self) { i in
                    TextField("Word \(positions[i] + 1)", text: $answers[i])
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(Brand.danger) }
            }
            Section {
                Button("Finish") { finish() }
                    .disabled(answers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Check your words")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func finish() {
        let phrase = key.phrase
        for (i, position) in positions.enumerated() where answers[i].trimmingCharacters(in: .whitespaces).lowercased() != phrase[position] {
            problem = "Word \(position + 1) doesn't match. Check your paper and try again."
            return
        }
        do {
            try model.finishSetup(with: key)
        } catch {
            problem = model.message(for: error)
        }
    }
}

struct ImportWalletView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Recovery phrase or raw seed")
            } footer: {
                Text("Your 24 words, separated by spaces, or the Raw Seed (hex) from Ego Desktop's recovery screen: 64 characters, with or without the spaces.")
            }
            if let problem {
                Section { Text(problem).foregroundStyle(Brand.danger) }
            }
            Section {
                Button("Restore wallet") { restore() }
                    .disabled(!RecoveryInput.looksComplete(text))
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore() {
        let key: EgoKey
        switch RecoveryInput.seed(from: text) {
        case .success(let seed):
            guard let made = try? EgoKey(seed: seed) else {
                problem = "That seed can't be used. Check it against Ego Desktop."
                return
            }
            key = made
        case .failure(.unknownWord(let unknown)):
            problem = "\"\(unknown)\" isn't one of the recovery words. Check the spelling."
            return
        case .failure(.invalidPhrase):
            problem = "These words don't form a valid phrase. Check the order and spelling."
            return
        case .failure(.invalidSeed):
            problem = "A raw seed is 64 characters, 0–9 and a–f. Check it against Ego Desktop."
            return
        }
        do {
            try model.finishSetup(with: key)
        } catch {
            problem = model.message(for: error)
        }
    }
}
