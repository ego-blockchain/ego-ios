import EgoKit
import SwiftUI

struct DesktopFilesSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var account = AccountStore.shared
    @State private var sending: AccountRecord.File?
    @State private var showAll = false

    private static let firstShown = 6

    var body: some View {
        Group {
            if !account.files.isEmpty {
                GlassCard {
                    SectionLabel(text: "On your Ego Desktop")
                    ForEach(showAll ? account.files : Array(account.files.prefix(Self.firstShown))) { file in
                        HStack(spacing: 12) {
                            Image(systemName: file.isPicture ? "photo" : "doc")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Brand.sky)
                                .frame(width: 36, height: 36)
                                .background(Brand.sky.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name.isEmpty ? "File" : file.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Brand.text)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(Brand.muted)
                            }
                            Spacer(minLength: 0)
                            Button { sending = file } label: {
                                Label("Send", systemImage: "paperplane.fill")
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(Brand.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Brand.lime, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(account.contacts.isEmpty)
                        }
                    }
                    if account.files.count > Self.firstShown {
                        Button(showAll ? "Show fewer" : "Show all \(account.files.count)") { showAll.toggle() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.sky)
                    }
                    if account.contacts.isEmpty {
                        Text("Add a contact in Ego Desktop's Messenger to send files from here.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                    }
                }
            }
        }
        .task { await account.refresh(app) }
        .sheet(item: $sending) { file in
            SendToContactSheet(file: file)
                .presentationDetents([.medium, .large])
                .presentationBackground(Brand.ink)
        }
    }
}

struct SendToContactSheet: View {
    let file: AccountRecord.File
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy: String?
    @State private var problem: String?
    @State private var sentTo: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(file.name.isEmpty ? "File" : file.name)
                        .font(.subheadline.weight(.semibold))
                } header: { Text("Send") }
                Section {
                    ForEach(account.contacts) { contact in
                        Button {
                            Task { await send(to: contact) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(contact)).font(.body.weight(.semibold))
                                    Text(contact.address).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if busy == contact.address { ProgressView() }
                                if sentTo == contact.address { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.lime) }
                            }
                        }
                        .disabled(busy != nil)
                    }
                } header: { Text("To") } footer: {
                    Text("Your Ego Desktop's contacts. The file stays where it is stored; only a link that opens it is sent, and it shows in Messenger on your Ego Desktop too.")
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(Brand.danger) }
                }
            }
            .navigationTitle("Send file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func send(to contact: AccountRecord.Contact) async {
        busy = contact.address
        problem = nil
        defer { busy = nil }
        do {
            try await account.send(file, to: contact, app: app)
            Haptics.success()
            sentTo = contact.address
        } catch {
            problem = app.message(for: error)
        }
    }
}
