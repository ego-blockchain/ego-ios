import AVFoundation
import EgoKit
import ImageIO
import SwiftUI
import UIKit

/// Ego Storage on this iPhone: the plan, the sealed file library, and each
/// file's encrypted blocks while they wait to go to the network.
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
    }

    private var planChosenKey: String { "storage.planChosen.\(owner)" }

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
            subscription = EgoStorage.subscription(in: h, of: owner)
            subscriptionChecked = true
            if subscription != nil && !planChosen { chooseFree() }
        }
        problem = (c == nil && h == nil) ? "Couldn't reach the Ego network. Your files on this iPhone still open." : nil
        if c != nil {
            await retryDeletes()
            await uploadWaiting()
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

    // MARK: Plan

    var now: Int64 { Int64(Date().timeIntervalSince1970) }
    var quota: UInt64 { EgoStorage.quotaBytes(subscription, now: now) }
    var used: UInt64 { files.reduce(0) { $0 + UInt64($1.size) } }

    var currentPlan: EgoStorage.Plan {
        guard let s = subscription, s.confirmed, s.active(now: now) || s.inGrace(now: now) else { return EgoStorage.plans[0] }
        return s.plan
    }

    func price(_ plan: EgoStorage.Plan, _ billing: EgoStorage.Billing) -> UInt64? {
        priceMicroUsd.flatMap { EgoStorage.priceUegoc(usd: plan.priceUsd(billing), priceMicroUsd: $0) }
    }

    /// Whether the network has room for a plan, as Ego Desktop checks before selling one.
    func networkHasRoom(for plan: EgoStorage.Plan) -> Bool {
        plan.isFree || (capacity.map { $0.freeBytes >= plan.bytes } ?? false)
    }

    func subscribe(_ plan: EgoStorage.Plan, billing: EgoStorage.Billing) async throws -> String {
        guard let app else { throw WalletError.locked }
        guard let amount = price(plan, billing) else { throw StorePlanError.noPrice }
        let hash = try await app.payStoragePlan(plan, billing: billing, amount: amount)
        chooseFree()
        await refresh()
        return hash
    }

    enum StorePlanError: LocalizedError {
        case noPrice, full, locked

        var errorDescription: String? {
            switch self {
            case .noPrice: return "The EGOC price isn't available right now. Try again in a moment."
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
        for entry in file.manifest.blocks where !FileManager.default.fileExists(atPath: blocksDir.appendingPathComponent(entry.blockCid).path) {
            working = "Downloading \(file.name)…"
            defer { working = nil }
            _ = try await fetchBlock(entry.blockCid)
        }
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

    /// Removes the file from this wallet: its key, its name and its blocks on this iPhone,
    /// and asks the network to drop it.
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
