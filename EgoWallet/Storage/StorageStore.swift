import AVFoundation
import EgoKit
import ImageIO
import SwiftUI
import UIKit

/// Ego Storage on this iPhone: the plan, the sealed file library, and each
/// file's encrypted blocks while they wait to go to the network.
///
/// Like iCloud, a file lives on the network once it's there: with Optimize iPhone
/// Storage on, its blocks leave this iPhone and only the thumbnail stays. Opening it
/// downloads it again; files kept on the iPhone, or opened in the last few days, stay.
@MainActor
final class StorageStore: ObservableObject {
    @Published private(set) var files: [LibraryFile] = []
    @Published private(set) var subscription: EgoStorage.Subscription?
    @Published private(set) var subscriptionChecked = false
    @Published private(set) var capacity: StorageCapacity?
    @Published private(set) var priceMicroUsd: UInt64?
    @Published var problem: String?
    /// What's being done right now, such as "Encrypting 3 files…".
    @Published private(set) var working: String?
    /// The owner picked a plan here, even Free; until then Storage opens on the plans.
    @Published private(set) var planChosen = false
    /// Why waiting files haven't gone out yet, when it isn't simply being offline.
    @Published private(set) var uploadNote: String?

    /// Files coming down from the network, and how far along each is (0 to 1).
    @Published private(set) var downloads: [String: Double] = [:]
    /// Files whose every block is on this iPhone.
    @Published private(set) var onDevice: Set<String> = []
    /// Files the owner asked to keep on this iPhone.
    @Published private(set) var kept: Set<String> = []
    /// Free up space by keeping uploaded files on the network only. On unless turned off.
    @Published var optimize = true {
        didSet {
            UserDefaults.standard.set(optimize, forKey: optimizeKey)
            if optimize { Task { await freeUpSpace() } }
        }
    }

    /// A downloaded file that isn't kept leaves the iPhone after this long unopened.
    static let keepOpenedSeconds: TimeInterval = 3 * 86_400

    private var uploading = false

    private var library: FileLibrary?
    private weak var app: AppModel?
    private var owner = ""
    private let support: URL
    private let blocksDir: URL
    private let openedDir: URL

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        blocksDir = support.appendingPathComponent("StorageBlocks", isDirectory: true)
        openedDir = FileManager.default.temporaryDirectory.appendingPathComponent("Opened", isDirectory: true)
        try? FileManager.default.createDirectory(at: blocksDir, withIntermediateDirectories: true)
    }

    // MARK: Setup

    func attach(_ app: AppModel) {
        self.app = app
        guard let key = app.key, key.address != owner || library == nil else { return }
        owner = key.address
        let lib = FileLibrary(url: support.appendingPathComponent("storage-library-\(key.address).sealed"), seed: key.seed)
        files = lib.files
        library = lib
        planChosen = UserDefaults.standard.bool(forKey: planChosenKey) || !files.isEmpty
        kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        optimize = UserDefaults.standard.object(forKey: optimizeKey) as? Bool ?? true
        scanDevice()
    }

    private var planChosenKey: String { "storage.planChosen.\(owner)" }
    private var keptKey: String { "storage.kept.\(owner)" }
    private var optimizeKey: String { "storage.optimize.\(owner)" }
    private var openedAtKey: String { "storage.openedAt.\(owner)" }

    private var openedAt: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: openedAtKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: openedAtKey) }
    }

    private func blockURL(_ cid: String) -> URL { blocksDir.appendingPathComponent(cid) }

    /// Notes which files are wholly on this iPhone.
    private func scanDevice() {
        onDevice = Set(files.filter { f in
            f.manifest.blocks.allSatisfy { FileManager.default.fileExists(atPath: blockURL($0.blockCid).path) }
        }.map(\.cid))
    }

    /// Bytes of files kept on this iPhone right now.
    var onDeviceBytes: UInt64 {
        files.filter { onDevice.contains($0.cid) }.reduce(0) { $0 + UInt64($1.size) }
    }

    func chooseFree() {
        UserDefaults.standard.set(true, forKey: planChosenKey)
        planChosen = true
    }

    func refresh() async {
        guard let app else { return }
        async let cap = try? app.perform { try await $0.storageCapacity() }
        async let price = try? app.egocPriceMicroUsd()
        async let history = try? app.longHistory()
        let (c, p, h) = await (cap, price, history)
        if let c { capacity = c }
        if let p { priceMicroUsd = p }
        if let h {
            subscription = EgoStorage.subscription(in: h, of: owner, egocPriceMicroUsd: p ?? priceMicroUsd)
            subscriptionChecked = true
            if subscription != nil && !planChosen { chooseFree() }
        }
        problem = (c == nil && h == nil) ? "Couldn't reach the Ego network. Your files on this iPhone still open." : nil
        if c != nil {
            await retryDeletes()
            await uploadWaiting()
            await freeUpSpace()
        }
    }

    // MARK: Network

    /// Sends files that wait on this iPhone to a gateway, oldest first.
    func uploadWaiting() async {
        guard let app, let key = app.key, !uploading else { return }
        let waiting = files.filter { $0.state == .waiting }.reversed()
        guard !waiting.isEmpty else { return }
        uploading = true
        defer { uploading = false; if working?.hasPrefix("Uploading") == true { working = nil } }
        for file in waiting {
            working = "Uploading \(file.name)…"
            do {
                try await send(file, key: key)
                uploadNote = nil
            } catch GatewayError.rpc(AppModel.notHere, _) {
                uploadNote = "Uploads start once a gateway runs the latest Ego Desktop. Your files stay encrypted on this iPhone until then."
                return
            } catch where AppModel.isUnreachable(error) {
                return
            } catch {
                problem = app.message(for: error)
                return
            }
        }
    }

    /// Sends one file's blocks and manifest to a gateway, and marks it stored.
    private func send(_ file: LibraryFile, key: EgoKey) async throws {
        guard let app else { throw StorePlanError.locked }
        let blocksDir = self.blocksDir
        try await app.perform { client in
            for (i, entry) in file.manifest.blocks.enumerated() {
                let sealed = try Data(contentsOf: blocksDir.appendingPathComponent(entry.blockCid))
                try await client.putBlock(cid: entry.blockCid, sealed: sealed, key: key)
                if file.manifest.blocks.count > 4 {
                    await MainActor.run { self.working = "Uploading \(file.name)… \(Int(Double(i + 1) / Double(file.manifest.blocks.count) * 100))%" }
                }
            }
            let missing = try await client.putManifest(file.manifest, key: key)
            if !missing.isEmpty { throw GatewayError.rpc(-32011, "The gateway lost part of this file. It'll be sent again.") }
        }
        if var entry = files.first(where: { $0.cid == file.cid }) {
            entry.state = .stored
            try? library?.update(entry)
            files = library?.files ?? []
        }
    }

    private var pendingDeletesKey: String { "storage.pendingDeletes.\(owner)" }

    private var pendingDeletes: [String] {
        get { UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: pendingDeletesKey) }
    }

    /// Tells gateways about files deleted while none could be reached.
    private func retryDeletes() async {
        guard let app, let key = app.key else { return }
        for cid in pendingDeletes {
            if (try? await app.perform({ try await $0.deleteFile(cid: cid, key: key) })) != nil {
                pendingDeletes.removeAll { $0 == cid }
            }
        }
    }

    /// A block from this iPhone, or from the network through a gateway.
    private func fetchBlock(_ cid: String) async throws -> Data {
        if let local = try? Data(contentsOf: blocksDir.appendingPathComponent(cid)) { return local }
        guard let app else { throw StorageError.missingBlock(cid) }
        for attempt in 0..<8 {
            if let data = try await app.perform({ try await $0.getBlock(cid: cid) }) {
                try? data.write(to: blocksDir.appendingPathComponent(cid), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return data
            }
            try await Task.sleep(for: .seconds(attempt < 3 ? 1 : 3))
        }
        throw StorageError.missingBlock(cid)
    }

    // MARK: On this iPhone

    /// Brings a file's blocks down from the network, showing progress, without opening it.
    func download(_ file: LibraryFile) async throws {
        let missing = file.manifest.blocks.map(\.blockCid).filter { !FileManager.default.fileExists(atPath: blockURL($0).path) }
        guard !missing.isEmpty else { onDevice.insert(file.cid); return }
        let total = Double(file.manifest.blocks.count)
        var have = total - Double(missing.count)
        downloads[file.cid] = have / total
        defer { downloads[file.cid] = nil }
        for cid in missing {
            _ = try await fetchBlock(cid)
            have += 1
            withAnimation(.easeOut(duration: 0.2)) { downloads[file.cid] = have / total }
        }
        onDevice.insert(file.cid)
    }

    /// Frees the space a file takes on this iPhone. It stays on the network and downloads again when opened.
    func removeDownload(_ file: LibraryFile) {
        guard file.state == .stored else { return }
        for entry in file.manifest.blocks {
            try? FileManager.default.removeItem(at: blockURL(entry.blockCid))
        }
        try? FileManager.default.removeItem(at: openedDir.appendingPathComponent(file.cid))
        onDevice.remove(file.cid)
        setKept(file, false, download: false)
    }

    /// Keeps a file on this iPhone even with Optimize iPhone Storage on, downloading it if needed.
    func setKept(_ file: LibraryFile, _ keep: Bool, download fetch: Bool = true) {
        if keep { kept.insert(file.cid) } else { kept.remove(file.cid) }
        UserDefaults.standard.set(Array(kept), forKey: keptKey)
        if keep && fetch && !onDevice.contains(file.cid) {
            Task {
                do { try await download(file) } catch { problem = app?.message(for: error) ?? error.localizedDescription }
            }
        }
    }

    /// With Optimize iPhone Storage on, lets go of uploaded files that aren't kept or recently opened,
    /// but only those a gateway confirms the network holds.
    func freeUpSpace() async {
        guard optimize, let app else { return }
        let now = Date().timeIntervalSince1970
        let opened = openedAt
        let candidates = files.filter {
            $0.state == .stored && onDevice.contains($0.cid) && !kept.contains($0.cid)
                && now - (opened[$0.cid] ?? 0) > Self.keepOpenedSeconds
                && downloads[$0.cid] == nil
        }
        guard !candidates.isEmpty else { return }
        let owner = self.owner
        guard let held = try? await app.perform({ try await $0.storedFiles(owner: owner) }) else { return }
        for file in candidates where held.contains(file.cid) {
            removeDownload(file)
        }
    }

    // MARK: Plan

    var now: Int64 { Int64(Date().timeIntervalSince1970) }
    var quota: UInt64 { EgoStorage.quotaBytes(subscription, now: now) }
    var used: UInt64 { files.reduce(0) { $0 + UInt64($1.size) } }

    var currentPlan: EgoStorage.Plan {
        guard let s = subscription, s.confirmed, s.active(now: now) || s.inGrace(now: now) else { return EgoStorage.plans[0] }
        return s.plan
    }

    /// Whether the network has room for a plan, as Ego Desktop checks before selling one.
    func networkHasRoom(for plan: EgoStorage.Plan) -> Bool {
        plan.isFree || (capacity.map { $0.freeBytes >= plan.bytes } ?? false)
    }

    func subscribe(_ plan: EgoStorage.Plan, billing: EgoStorage.Billing) async throws -> String {
        guard let app else { throw WalletError.locked }
        let hash = try await app.payStoragePlan(plan, billing: billing)
        chooseFree()
        await refresh()
        return hash
    }

    enum StorePlanError: LocalizedError {
        case full, locked

        var errorDescription: String? {
            switch self {
            case .full: return "That's more than your plan's space. Choose a bigger plan or delete some files."
            case .locked: return "Unlock your wallet first."
            }
        }
    }

    // MARK: Files

    func files(of kind: LibraryFile.Kind?) -> [LibraryFile] {
        kind.map { k in files.filter { $0.kind == k } } ?? files
    }

    /// Encrypts each file on this iPhone, keeps its blocks here, and adds it to the library.
    func add(_ items: [(name: String, data: Data)]) async {
        guard library != nil else { problem = StorePlanError.locked.errorDescription; return }
        let total = items.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        guard used + total <= quota else { problem = StorePlanError.full.errorDescription; return }
        problem = nil
        for (i, item) in items.enumerated() {
            working = items.count > 1 ? "Encrypting \(i + 1) of \(items.count)…" : "Encrypting \(item.name)…"
            do {
                let data = item.data
                let blocksDir = self.blocksDir
                let file = try await Task.detached(priority: .userInitiated) { () throws -> EncryptedFile in
                    let file = try FileCrypto.encrypt(data)
                    for block in file.blocks {
                        try block.sealed.write(to: blocksDir.appendingPathComponent(block.cid), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }
                    return file
                }.value
                var entry = LibraryFile(file: file, name: item.name)
                entry.thumbnail = await Thumbnail.make(for: entry.kind, data: data)
                try library?.add(entry)
                files = library?.files ?? []
                onDevice.insert(entry.cid)
                Haptics.success()
            } catch {
                problem = app?.message(for: error) ?? error.localizedDescription
            }
        }
        working = nil
        await uploadWaiting()
    }

    /// The file's contents, from the blocks kept on this iPhone, fetching any it doesn't have.
    func contents(of file: LibraryFile) async throws -> Data {
        try await download(file)
        var stamps = openedAt
        stamps[file.cid] = Date().timeIntervalSince1970
        openedAt = stamps
        let blocksDir = self.blocksDir
        return try await Task.detached(priority: .userInitiated) {
            try FileCrypto.decrypt(file.manifest, key: file.key) { cid in
                try? Data(contentsOf: blocksDir.appendingPathComponent(cid))
            }
        }.value
    }

    /// A decrypted copy under its own name, for previewing, saving or sending. Removed on the next launch.
    func openedCopy(of file: LibraryFile) async throws -> URL {
        let folder = openedDir.appendingPathComponent(file.cid, isDirectory: true)
        let url = folder.appendingPathComponent(file.name.isEmpty ? "file" : file.name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await contents(of: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: Sharing

    /// The biggest photo, video or GIF the chat takes.
    static let maxShareBytes = 25_000_000

    /// Encrypts one file, uploads it right away and adds it to the library, for sharing a link
    /// to it (in the chat, or as a profile picture). Fails rather than waits when no gateway takes it.
    func uploadForSharing(name: String, data: Data) async throws -> EgoShareLink {
        guard library != nil, let key = app?.key else { throw StorePlanError.locked }
        guard data.count <= Self.maxShareBytes else { throw ShareError.tooBig }
        guard used + UInt64(data.count) <= quota else { throw StorePlanError.full }
        let blocksDir = self.blocksDir
        let file = try await Task.detached(priority: .userInitiated) { () throws -> EncryptedFile in
            let file = try FileCrypto.encrypt(data)
            for block in file.blocks {
                try block.sealed.write(to: blocksDir.appendingPathComponent(block.cid), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return file
        }.value
        var entry = LibraryFile(file: file, name: name)
        entry.thumbnail = await Thumbnail.make(for: entry.kind, data: data)
        try library?.add(entry)
        files = library?.files ?? []
        onDevice.insert(entry.cid)
        try await send(entry, key: key)
        try? sharedCopy(for: entry.cid, name: name).map { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return EgoShareLink(cid: entry.cid, key: entry.key, name: name, from: owner)
    }

    enum ShareError: LocalizedError {
        case tooBig, notFound

        var errorDescription: String? {
            switch self {
            case .tooBig: return "That's too big to share here. The limit is 25 MB."
            case .notFound: return "The network couldn't find that file. It may have been deleted."
            }
        }
    }

    private let sharedDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SharedFiles", isDirectory: true)

    private func sharedCopy(for cid: String, name: String) -> URL? {
        let safe = (name as NSString).lastPathComponent.isEmpty ? "file" : (name as NSString).lastPathComponent
        return sharedDir.appendingPathComponent(cid, isDirectory: true).appendingPathComponent(safe)
    }

    private var openingShared: [String: Task<URL, Error>] = [:]

    /// Opens a file someone shared as an Ego link: from the cache, the library, or the network.
    /// The link's key decrypts it, and its blocks are checked against the IDs in the manifest.
    func openShared(_ link: EgoShareLink) async throws -> URL {
        guard let url = sharedCopy(for: link.cid, name: link.name) else { throw ShareError.notFound }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = openingShared[link.cid] { return try await running.value }
        let task = Task { () throws -> URL in
            let data: Data
            if let mine = files.first(where: { $0.cid == link.cid }) {
                data = try await contents(of: mine)
            } else {
                data = try await fetchShared(link)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }
        openingShared[link.cid] = task
        defer { openingShared[link.cid] = nil }
        return try await task.value
    }

    /// Asks each gateway in turn until one has the answer: an older Ego Desktop may not know
    /// the call, and a file may sit on one gateway before the network spreads it.
    private func fromAnyGateway<T>(_ work: (GatewayClient) async throws -> T?) async throws -> T? {
        guard let app else { return nil }
        var lastError: Error?
        for client in await app.gatewayCandidates() {
            do {
                if let answer = try await work(client) { return answer }
            } catch {
                lastError = error
            }
        }
        if let lastError, AppModel.isUnreachable(lastError) { throw lastError }
        return nil
    }

    private func fetchShared(_ link: EgoShareLink) async throws -> Data {
        var manifest: StorageManifest?
        for attempt in 0..<6 where manifest == nil {
            manifest = try await fromAnyGateway { try await $0.getManifest(cid: link.cid) }
            if manifest == nil { try await Task.sleep(for: .seconds(attempt < 2 ? 1 : 3)) }
        }
        guard let manifest else { throw ShareError.notFound }
        var blocks: [String: Data] = [:]
        for entry in manifest.blocks {
            var found: Data?
            for attempt in 0..<6 where found == nil {
                found = try await fromAnyGateway { try await $0.getBlock(cid: entry.blockCid) }
                if found == nil { try await Task.sleep(for: .seconds(attempt < 2 ? 1 : 3)) }
            }
            guard let data = found, StorageBlock.cid(for: data) == entry.blockCid else { throw ShareError.notFound }
            blocks[entry.blockCid] = data
        }
        let key = link.key
        return try await Task.detached(priority: .userInitiated) {
            try FileCrypto.decrypt(manifest, key: key) { blocks[$0] }
        }.value
    }

    func shareLink(for file: LibraryFile) -> String {
        EgoShareLink(cid: file.cid, key: file.key, name: file.name, from: owner).text
    }

    func rename(_ file: LibraryFile, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var entry = files.first(where: { $0.cid == file.cid }) else { return }
        entry.name = clean
        try? library?.update(entry)
        files = library?.files ?? []
        try? FileManager.default.removeItem(at: openedDir.appendingPathComponent(file.cid))
    }

    /// Removes the file from this wallet: its key, its name and its blocks on this iPhone.
    /// A gateway passes the signed delete to every node that keeps a copy.
    func delete(_ file: LibraryFile) {
        if file.state == .stored, let app, let key = app.key {
            pendingDeletes.append(file.cid)
            Task {
                if (try? await app.perform({ try await $0.deleteFile(cid: file.cid, key: key) })) != nil {
                    pendingDeletes.removeAll { $0 == file.cid }
                }
            }
        }
        for entry in file.manifest.blocks {
            try? FileManager.default.removeItem(at: blocksDir.appendingPathComponent(entry.blockCid))
        }
        try? FileManager.default.removeItem(at: openedDir.appendingPathComponent(file.cid))
        try? library?.remove(file.cid)
        files = library?.files ?? []
        onDevice.remove(file.cid)
        if kept.remove(file.cid) != nil { UserDefaults.standard.set(Array(kept), forKey: keptKey) }
        Haptics.tap()
    }

    func clearOpenedCopies() {
        try? FileManager.default.removeItem(at: openedDir)
    }
}

/// Small previews for the library grid.
enum Thumbnail {
    static func make(for kind: LibraryFile.Kind, data: Data) async -> Data? {
        switch kind {
        case .photo:
            return await Task.detached {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 360,
                      ] as CFDictionary)
                else { return nil }
                return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
            }.value
        case .video:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            guard (try? data.write(to: url, options: .completeFileProtection)) != nil else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            guard let (cg, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
        case .document:
            return nil
        }
    }
}
