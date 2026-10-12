import EgoKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Storage opens on the plans, as Ego Desktop's does, then shows the library.
struct StorageView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var store = StorageStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.planChosen {
                    LibraryView()
                } else {
                    PlansPage(firstTime: true)
                }
            }
            .navigationTitle("Storage")
        }
        .environmentObject(store)
        .onAppear { store.attach(app) }
        .onChange(of: app.phase) { _, _ in store.attach(app) }
        .task {
            store.clearOpenedCopies()
            while !Task.isCancelled {
                store.attach(app)
                await store.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// MARK: - Plans

struct PlansPage: View {
    let firstTime: Bool
    @EnvironmentObject private var store: StorageStore
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var billing = EgoStorage.Billing.monthly
    @State private var selected = "pro"
    @State private var busy = false
    @State private var problem: String?
    @State private var paidHash: String?
    @State private var converting = false

    private var plan: EgoStorage.Plan { EgoStorage.plans.first { $0.id == selected } ?? EgoStorage.plans[0] }
    private var cost: UInt64 { plan.credits(billing) }
    private var affordable: Bool { cost <= (app.spendableCredits ?? 0) }
    private var isCurrent: Bool { !plan.isFree && store.currentPlan.id == plan.id && store.subscription?.billing == billing }

    var body: some View {
        GlassPage {
            if let paidHash {
                SuccessBurst(title: "\(plan.name) plan paid", subtitle: "Your space grows to \(sizeLabel(plan.gb)) as soon as the network confirms the payment, usually within seconds.")
                HashCard(hash: paidHash)
                Button("Open my storage") { finish() }.buttonStyle(GlowButtonStyle())
            } else {
                header.reveal(0)
                StorageTestingNote().reveal(0.02)
                GlassSegments(selection: $billing, options: EgoStorage.Billing.allCases) { $0 == .annual ? "Yearly · 2 months free" : "Monthly" }
                    .reveal(0.04)
                ForEach(Array(EgoStorage.plans.enumerated()), id: \.element.id) { i, p in
                    planCard(p).reveal(0.06 + Double(i) * 0.04)
                }
                capacityLine
                features
                if let problem { ProblemBanner(text: problem) }
                action
            }
        }
        .toolbar {
            if !firstTime {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.muted)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            GlowingMark(size: 54)
                .frame(height: 110)
            Text(firstTime ? "Your private cloud on Ego" : "Change your plan")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.text)
                .multilineTextAlignment(.center)
            Text("Photos, videos and documents, encrypted on this iPhone and spread across Ego Desktop computers. Only you hold the key.")
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func planCard(_ p: EgoStorage.Plan) -> some View {
        let on = p.id == selected
        let current = store.planChosen && store.currentPlan.id == p.id
        let room = store.networkHasRoom(for: p)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = p.id }
            Haptics.tap()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(on ? Brand.lime : Color.white.opacity(0.2), lineWidth: 2).frame(width: 22, height: 22)
                    if on { Circle().fill(Brand.glow).frame(width: 12, height: 12) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.system(.headline, design: .rounded, weight: .heavy)).foregroundStyle(Brand.text)
                        if current {
                            tag("Current", Brand.mint)
                        } else if p.highlight {
                            tag("Most popular", Brand.lime)
                        }
                    }
                    Text(sizeLabel(p.gb)).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
                    if !room {
                        Text("Waiting for network space").font(.caption).foregroundStyle(Brand.warning)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if p.isFree {
                        Text("Free").font(.system(.title3, design: .rounded, weight: .heavy)).foregroundStyle(Brand.text)
                    } else {
                        Text(String(format: "$%.2f", billing == .annual ? p.annualUsd / 12 : p.monthlyUsd))
                            .font(.system(.title3, design: .rounded, weight: .heavy))
                            .foregroundStyle(on ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Brand.text))
                        Text(billing == .annual ? "a month, billed yearly" : "a month")
                            .font(.caption2).foregroundStyle(Brand.muted)
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(on ? 0.75 : 0.45), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(on ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(0.08)), lineWidth: on ? 1.5 : 1)
            )
            .shadow(color: on ? Brand.lime.opacity(0.18) : .clear, radius: 14)
            .opacity(room ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private var capacityLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below.fill").foregroundStyle(Brand.mint)
            if let c = store.capacity {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: c.freeBytes), countStyle: .decimal)) free on \(c.providers) Ego Desktop computer\(c.providers == 1 ? "" : "s")")
            } else {
                Text("Checking network space…")
            }
        }
        .font(.footnote)
        .foregroundStyle(Brand.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var features: some View {
        GlassField(label: "Every plan", icon: "checkmark.seal.fill") {
            ForEach([
                ("lock.fill", "Encrypted on this iPhone with AES-256 before it leaves"),
                ("eye.slash.fill", "File names stay private: the network sees only IDs"),
                ("point.3.connected.trianglepath.dotted", "Spread across Ego Desktop computers, no central server"),
                ("paperplane.fill", "Send any file with a link only the recipient opens"),
                ("trash.fill", "Delete anything, any time"),
            ], id: \.1) { item in
                Label(item.1, systemImage: item.0)
                    .font(.footnote)
                    .foregroundStyle(Brand.text)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if plan.isFree {
            Button(store.planChosen ? "Stay on Free" : "Start with Free 5 GB") { finishFree() }
                .buttonStyle(GlowButtonStyle())
        } else if isCurrent {
            NoteCard(text: "You're on this plan. It runs until \(expiry).", icon: "checkmark.circle.fill", tint: Brand.mint)
        } else if !store.networkHasRoom(for: plan) {
            NoteCard(text: "The network doesn't have \(sizeLabel(plan.gb)) free yet, so this plan can't be bought. It opens as more Ego Desktop computers share space.", icon: "hourglass", tint: Brand.warning)
        } else {
            VStack(spacing: 8) {
                HoldToConfirm(title: "Hold to pay \(EGUSD.format(cost)) EGUSD", busyTitle: "Paying…", busy: busy, enabled: affordable) {
                    Task { await pay() }
                }
                if affordable {
                    Text("\(EGUSD.format(cost)) for \(billing == .annual ? "a year" : "a month"), paid in EGUSD, so the price never moves with EGOC.")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Plans are paid in EGUSD. You have \(EGUSD.format(app.spendableCredits ?? 0)).")
                        .font(.caption)
                        .foregroundStyle(Brand.warning)
                    Button {
                        converting = true
                    } label: {
                        Label("Convert EGOC to EGUSD", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            .sheet(isPresented: $converting) {
                ConvertToEGUSDView()
            }
        }
        if !firstTime {
            Button("Close") { dismiss() }.buttonStyle(GhostButtonStyle())
        }
    }

    private var expiry: String {
        store.subscription.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)).formatted(date: .abbreviated, time: .omitted) } ?? ""
    }

    private func pay() async {
        busy = true
        problem = nil
        do {
            let hash = try await store.subscribe(plan, billing: billing)
            withAnimation(.spring) { paidHash = hash }
        } catch {
            Haptics.warning()
            problem = app.message(for: error)
        }
        busy = false
    }

    private func finishFree() {
        store.chooseFree()
        Haptics.success()
        if !firstTime { dismiss() }
    }

    private func finish() {
        if firstTime { store.chooseFree() } else { dismiss() }
    }
}

/// Storage runs on the test network: plans are paid with test coins, and they still work for real.
struct StorageTestingNote: View {
    var body: some View {
        NoteCard(text: "Ego Storage is still in testing. Plans are paid with testnet EGUSD, and your plan works for real while it runs: upload, open, send and delete your files any time. Keep your own copy of anything important until the main network launches.",
                 icon: "flask.fill", tint: Brand.warning)
    }
}

func sizeLabel(_ gb: UInt64) -> String { gb >= 1024 ? "\(gb / 1024) TB" : "\(gb) GB" }

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject private var store: StorageStore
    @State private var filter: LibraryFile.Kind?
    @State private var showingPlans = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var opened: LibraryFile?

    private var shown: [LibraryFile] { store.files(of: filter) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                usageCard
                filters
                if let working = store.working {
                    HStack(spacing: 10) {
                        ProgressView().tint(Brand.lime)
                        Text(working).font(.subheadline).foregroundStyle(Brand.text)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.lime.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let problem = store.problem { ProblemBanner(text: problem) }
                waitingNote
                if shown.isEmpty {
                    empty
                } else {
                    if filter != .document {
                        mediaGrid(shown.filter { $0.kind != .document })
                    }
                    if filter == nil || filter == .document {
                        documentList(shown.filter { $0.kind == .document })
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await store.refresh() }
        .background(AuroraBackground(intensity: 0.45))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { pickingPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.lime)
                }
                .accessibilityLabel("Add files")
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await addFiles(urls) } }
        }
        .sheet(isPresented: $showingPlans) {
            NavigationStack { PlansPage(firstTime: false) }
                .presentationBackground(Brand.ink)
        }
        .sheet(item: $opened) { FileDetailView(file: $0) }
    }

    private var usageCard: some View {
        let fraction = store.quota > 0 ? min(1, Double(store.used) / Double(store.quota)) : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(store.currentPlan.name) plan")
                            .font(.system(.headline, design: .rounded, weight: .heavy))
                            .foregroundStyle(Brand.text)
                        Text("TESTNET")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(Brand.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.warning.opacity(0.15), in: Capsule())
                    }
                    Text(planStatus).font(.caption).foregroundStyle(Brand.muted)
                }
                Spacer()
                Button(store.currentPlan.id == "max" ? "Manage" : "Upgrade") { showingPlans = true }
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Brand.glow, in: Capsule())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(fraction > 0.9 ? AnyShapeStyle(Brand.warning) : AnyShapeStyle(Brand.glow))
                        .frame(width: max(8, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(bytes(store.used)) of \(bytes(store.quota)) used")
                Spacer()
                ForEach(LibraryFile.Kind.allCases, id: \.self) { kind in
                    let n = store.files(of: kind).count
                    if n > 0 {
                        Label("\(n)", systemImage: icon(kind)).labelStyle(.titleAndIcon)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Brand.muted)
            Divider().overlay(Color.white.opacity(0.06))
            Toggle(isOn: $store.optimize) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optimize iPhone Storage")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Brand.text)
                    Text(store.optimize
                         ? "Files live on the Ego network and download when you open them. \(bytes(store.onDeviceBytes)) on this iPhone now."
                         : "Every file also stays on this iPhone. \(bytes(store.onDeviceBytes)) on this iPhone now.")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                }
            }
            .tint(Brand.mint)
        }
        .card()
    }

    private var planStatus: String {
        guard let s = store.subscription else { return "5 GB, no charge" }
        let date = Date(timeIntervalSince1970: TimeInterval(s.expiresAt)).formatted(date: .abbreviated, time: .omitted)
        if !s.confirmed { return "\(s.plan.name) payment confirming…" }
        if s.active(now: store.now) { return "\(sizeLabel(s.plan.gb)) · runs until \(date)" }
        if s.inGrace(now: store.now) { return "Ended \(date) · space kept for 30 days" }
        return "\(s.plan.name) ended \(date)"
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All", "square.grid.2x2.fill", store.files.count)
                chip(.photo, "Photos", icon(.photo), store.files(of: .photo).count)
                chip(.video, "Videos", icon(.video), store.files(of: .video).count)
                chip(.document, "Documents", icon(.document), store.files(of: .document).count)
            }
        }
    }

    private func chip(_ kind: LibraryFile.Kind?, _ title: String, _ symbol: String, _ count: Int) -> some View {
        let on = filter == kind
        return Button {
            withAnimation(.spring(response: 0.3)) { filter = kind }
            Haptics.tap()
        } label: {
            Label("\(title) \(count)", systemImage: symbol)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(on ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
                .overlay(Capsule().stroke(on ? Color.clear : Color.white.opacity(0.1)))
                .foregroundStyle(on ? Brand.ink : Brand.text)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var waitingNote: some View {
        let waiting = store.files.filter { $0.state == .waiting }.count
        if waiting > 0 {
            NoteCard(text: store.uploadNote ?? "\(waiting) file\(waiting == 1 ? " is" : "s are") encrypted on this iPhone and going to the Ego network as soon as a gateway takes \(waiting == 1 ? "it" : "them"). They open, send and delete normally meanwhile.",
                     icon: "icloud.and.arrow.up", tint: Brand.mint)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: filter.map(icon) ?? "lock.icloud.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Brand.glow)
                .padding(.top, 30)
            Text(filter == nil ? "Nothing stored yet" : "No \(title(filter!)) yet")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Brand.text)
            Text("Add photos, videos or documents. They're encrypted on this iPhone before anything leaves it.")
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { pickingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(OutlineButtonStyle())
                Button { importing = true } label: { Label("Files", systemImage: "folder") }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    private func mediaGrid(_ items: [LibraryFile]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(items) { file in
                Button { opened = file } label: { MediaTile(file: file) }
                    .buttonStyle(.plain)
                    .contextMenu { FileActions(file: file) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private func documentList(_ items: [LibraryFile]) -> some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, file in
                    Button { opened = file } label: { DocumentRow(file: file) }
                        .buttonStyle(.plain)
                        .contextMenu { FileActions(file: file) }
                    if i < items.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                }
            }
            .card()
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var picked: [(name: String, data: Data)] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let stem = (type?.conforms(to: .movie) ?? false) ? "Video" : "Photo"
            let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            picked.append(("\(stem) \(stamp)\(items.count > 1 ? " \(i + 1)" : "").\(ext)", data))
        }
        await store.add(picked)
    }

    private func addFiles(_ urls: [URL]) async {
        var picked: [(name: String, data: Data)] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { picked.append((url.lastPathComponent, data)) }
        }
        await store.add(picked)
    }

    private func title(_ kind: LibraryFile.Kind) -> String {
        switch kind { case .photo: "photos"; case .video: "videos"; case .document: "documents" }
    }
}

func icon(_ kind: LibraryFile.Kind) -> String {
    switch kind { case .photo: "photo.fill"; case .video: "video.fill"; case .document: "doc.fill" }
}

func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

/// Where a file is, as a small badge: uploading, downloading, or only on the network.
struct CloudBadge: View {
    let file: LibraryFile
    var onImage = true
    @EnvironmentObject private var store: StorageStore

    var body: some View {
        Group {
            if let progress = store.downloads[file.cid] {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.04, progress))
                        .stroke(Brand.mint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
            } else if file.state == .waiting {
                Image(systemName: "icloud.and.arrow.up").accessibilityLabel("Waiting to upload")
            } else if !store.onDevice.contains(file.cid) {
                Image(systemName: "icloud.and.arrow.down").accessibilityLabel("On the Ego network, tap to download")
            } else if store.kept.contains(file.cid) {
                Image(systemName: "arrow.down.circle.fill").accessibilityLabel("Kept on this iPhone")
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(onImage ? Color.white : Brand.muted)
        .padding(onImage ? 5 : 0)
        .background(onImage ? Color.black.opacity(0.45) : Color.clear, in: Circle())
    }
}

struct MediaTile: View {
    let file: LibraryFile

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let data = file.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Brand.raised
                        Image(systemName: icon(file.kind)).font(.title2).foregroundStyle(Brand.muted)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if file.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                CloudBadge(file: file).padding(5)
            }
            .accessibilityLabel(file.name)
    }
}

struct DocumentRow: View {
    let file: LibraryFile

    var body: some View {
        HStack(spacing: 12) {
            Text((file.name as NSString).pathExtension.uppercased().prefix(4))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.ink)
                .frame(width: 40, height: 46)
                .background(Brand.glow, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text).lineLimit(1)
                Text("\(bytes(file.size)) · \(relativeTime(file.addedAt))").font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer()
            CloudBadge(file: file, onImage: false)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted.opacity(0.6))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Send, copy link and delete, for a long press on a file.
struct FileActions: View {
    let file: LibraryFile
    @EnvironmentObject private var store: StorageStore

    var body: some View {
        if file.state == .stored {
            if store.onDevice.contains(file.cid) {
                if !store.kept.contains(file.cid) {
                    Button { store.setKept(file, true) } label: { Label("Keep on iPhone", systemImage: "arrow.down.circle") }
                }
                Button { store.removeDownload(file) } label: { Label("Remove Download", systemImage: "icloud.and.arrow.up") }
            } else {
                Button {
                    Task { try? await store.download(file) }
                } label: { Label("Download Now", systemImage: "icloud.and.arrow.down") }
                Button { store.setKept(file, true) } label: { Label("Keep on iPhone", systemImage: "arrow.down.circle") }
            }
            Button {
                UIPasteboard.general.string = store.shareLink(for: file)
                Haptics.tap()
            } label: { Label("Copy Ego link", systemImage: "link") }
        }
        Button(role: .destructive) { store.delete(file) } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - One file

struct FileDetailView: View {
    let file: LibraryFile
    @EnvironmentObject private var store: StorageStore
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var problem: String?
    @State private var previewing: URL?
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var copied = false
    @State private var opening = false

    var body: some View {
        FlowSheet(icon: icon(file.kind), title: file.name, subtitle: "\(bytes(file.size)) · added \(relativeTime(file.addedAt))") {
            preview
            if let problem { ProblemBanner(text: problem) }
            SummaryCard(rows: [
                .init(label: "Kind", value: file.kind.rawValue.capitalized),
                .init(label: "Status", value: status),
                .init(label: "Encryption", value: "AES-256-GCM, \(file.manifest.blocks.count) block\(file.manifest.blocks.count == 1 ? "" : "s")"),
                .init(label: "Network ID", value: String(file.cid.prefix(18)) + "…", mono: true),
            ])
            if file.state == .stored {
                GlassField(label: "On this iPhone", icon: "iphone") {
                    Toggle(isOn: Binding(get: { store.kept.contains(file.cid) }, set: { store.setKept(file, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep on this iPhone")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(Brand.text)
                            Text("Opens instantly, even offline. Otherwise it lives on the Ego network and downloads when you open it.")
                                .font(.caption)
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    .tint(Brand.mint)
                    if store.onDevice.contains(file.cid) {
                        Button {
                            store.removeDownload(file)
                            url = nil
                            Haptics.tap()
                        } label: {
                            Label("Remove Download · frees \(bytes(file.size))", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            NoteCard(text: "An Ego link lets anyone who has it open this file, so send it only to the person it's for.", icon: "link")
        } footer: {
            if let url {
                SwiftUI.ShareLink(item: url) { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(GlowButtonStyle())
            } else {
                Button {} label: { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(GlowButtonStyle()).disabled(true)
            }
            HStack(spacing: 10) {
                FileActionTile(title: copied ? "Copied" : "Copy link", icon: copied ? "checkmark" : "link", tint: Brand.mint) {
                    UIPasteboard.general.string = store.shareLink(for: file)
                    withAnimation(.spring(response: 0.3)) { copied = true }
                    Haptics.tap()
                }
                .disabled(file.state != .stored)
                FileActionTile(title: "Rename", icon: "pencil", tint: Brand.sky) {
                    newName = file.name
                    renaming = true
                }
                FileActionTile(title: "Delete", icon: "trash", tint: Brand.danger) {
                    Haptics.warning()
                    confirmDelete = true
                }
            }
        }
        .task { await open() }
        .quickLookPreview($previewing)
        .confirmationDialog("Delete \(file.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(file)
                dismiss()
            }
        } message: {
            Text(file.state == .stored
                 ? "It's removed from this iPhone and from every Ego node that keeps a copy, and no node will store it again. Copies you already sent to people stay with them."
                 : "It's removed from this iPhone. It never reached the network.")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(file, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var status: String {
        if file.state == .waiting { return "On this iPhone, waiting to upload" }
        if store.downloads[file.cid] != nil { return "Downloading from the Ego network" }
        return store.onDevice.contains(file.cid) ? "On the Ego network and this iPhone" : "On the Ego network"
    }

    @ViewBuilder private var preview: some View {
        Button {
            if let url {
                previewing = url
            } else if !opening {
                Task { await open() }
            }
        } label: {
            ZStack {
                if let data = file.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 280)
                        .clipped()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: icon(file.kind)).font(.system(size: 44)).foregroundStyle(Brand.glow)
                        Text((file.name as NSString).pathExtension.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Brand.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(Brand.raised)
                }
                if let progress = store.downloads[file.cid] {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 4)
                            Circle().trim(from: 0, to: max(0.03, progress))
                                .stroke(Brand.glow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "icloud.and.arrow.down").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        }
                        .frame(width: 54, height: 54)
                        Text("Downloading \(Int(progress * 100))%")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if url == nil && opening {
                    ProgressView().tint(Brand.lime).padding(10).background(.ultraThinMaterial, in: Circle())
                } else if url == nil {
                    Label("Tap to download", systemImage: "icloud.and.arrow.down")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.45), in: Capsule())
                } else {
                    Image(systemName: file.kind == .video ? "play.fill" : "eye.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(url == nil ? "Download \(file.name)" : "Open \(file.name)")
    }

    private func open() async {
        opening = true
        problem = nil
        defer { opening = false }
        do {
            url = try await store.openedCopy(of: file)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A square action under a file: an icon in a tinted well with its name beneath.
struct FileActionTile: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: Circle())
                Text(title)
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .foregroundStyle(tint == Brand.danger ? Brand.danger : Brand.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.25)))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(TilePressStyle())
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
