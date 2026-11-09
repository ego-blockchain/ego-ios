import AVFoundation
import EgoKit
import PhotosUI
import SwiftUI
import VisionKit

struct AvatarImage: View {
    let dataURL: String
    let name: String
    let address: String
    var size: CGFloat = 46

    var body: some View {
        if let image = MessengerStore.image(fromDataURL: dataURL) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2)))
                .accessibilityHidden(true)
        } else {
            ProfilePicture(link: "", fallback: name, address: address, size: size)
        }
    }
}

struct RequestRow: View {
    let request: PhoneContact
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MessengerStore.shared
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            ProfilePicture(link: "", fallback: request.name, address: request.address, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name.isEmpty ? shortAddress(request.address) : request.name)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
                Text("Wants to connect with you").font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().tint(Brand.sky)
            } else {
                Button {
                    busy = true
                    Task { await store.decline(request, app: app); busy = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Brand.text)
                        .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Decline")
                Button {
                    busy = true
                    Task { await store.approve(request, app: app); busy = false }
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Brand.ink)
                        .frame(width: 34, height: 34).background(Brand.lime, in: Circle())
                }
                .accessibilityLabel("Approve")
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Brand.lime.opacity(0.35)))
    }
}

struct AddContactSheet: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MessengerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var card = ""
    @State private var problem: String?
    @State private var busy = false
    @State private var scanning = false

    private var scannerReady: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Asks for the camera the first time; the scanner reports itself unavailable until access is granted.
    private func startScanning() async {
        problem = nil
        guard DataScannerViewController.isSupported else {
            problem = "This iPhone can't scan codes. Paste the card instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                problem = "Ego Wallet needs the camera to scan a card. You can allow it in Settings, or paste the card instead."
                return
            }
        case .denied, .restricted:
            problem = "Camera access is off for Ego Wallet. Turn it on in Settings › Ego Wallet › Camera, or paste the card instead."
            return
        default:
            break
        }
        if scannerReady { scanning = true } else { problem = "The camera isn't available right now. Paste the card instead." }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Paste or scan the other person's contact card. They see your request and approve it.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                    TextField("egocontact1:…", text: $card, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack(spacing: 10) {
                        Button {
                            card = UIPasteboard.general.string ?? card
                        } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                            .buttonStyle(OutlineButtonStyle())
                        Button {
                            Task { await startScanning() }
                        } label: { Label("Scan QR", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    if let problem {
                        ProblemBanner(text: problem)
                    }
                    Button {
                        busy = true
                        Task {
                            problem = await store.addContact(card, app: app)
                            busy = false
                            if problem == nil { dismiss() }
                        }
                    } label: {
                        if busy { ProgressView().tint(Brand.ink) } else { Text("Send request") }
                    }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(busy || card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .navigationTitle("Add a contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    card = text
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onFound(text)
                    return
                }
            }
        }
    }
}

struct MyCardSheet: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MessengerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var name = ""
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        AvatarImage(dataURL: store.myAvatar, name: store.displayedName, address: app.address, size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Button { picking = true } label: {
                                Label(store.myAvatar.isEmpty ? "Add a picture" : "Change picture", systemImage: "photo")
                            }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(busy)
                            Text("Your contacts see it.").font(.caption).foregroundStyle(Brand.muted)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Your name")
                        TextField("Name", text: $name)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onSubmit { store.setName(name, app: app) }
                        Text("Your contacts and your Ego Desktop get it too.").font(.caption).foregroundStyle(Brand.muted)
                    }
                    let card = store.myCard(app)
                    GlassCard {
                        SectionLabel(text: "Your contact card")
                        if let image = QRCode.image(for: card) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                                .padding(10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .frame(maxWidth: .infinity)
                        }
                        Text(card)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Brand.text)
                            .lineLimit(4)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = card
                                Haptics.success()
                                copied = true
                            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(OutlineButtonStyle())
                            ShareLink(item: card) { Label("Share", systemImage: "square.and.arrow.up") }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        Text(store.cardFromDesktop
                             ? "This is your Ego Desktop's card. People who add it reach both your Ego Desktop and this iPhone."
                             : "Give this card to people so they can add you. Their request shows here.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                    }
                    if store.cardFromDesktop {
                        Button {
                            Task { await store.askForHistory(app) }
                        } label: { Label("Get older messages from Ego Desktop", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(OutlineButtonStyle())
                        Text("Your Ego Desktop sends its recent conversations and pictures the next time it is online.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Your card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.setName(name, app: app)
                        dismiss()
                    }
                }
            }
            .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 1, matching: .images)
            .onChange(of: picked) { _, items in
                guard let item = items.first else { return }
                picked = []
                busy = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await store.setAvatar(image, app: app)
                    }
                    busy = false
                }
            }
            .onAppear { name = store.displayedName }
        }
    }
}
