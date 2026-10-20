import Foundation
import AppKit
import CryptoKit
import Darwin

public enum GameProvider: String, Codable, CaseIterable, Sendable {
    case steam = "Steam", epic = "Epic", gog = "GOG", ea = "EA", battleNet = "Battle.net"
}

public struct ManagedGame: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: GameProvider
    public let installURL: URL
    public let manifestURL: URL
    public let uninstallURL: URL?
    public var estimatedBytes: Int64? = nil
    public var manifestIdentity: FileIdentity? = nil
    public var manifestDigest: Data? = nil
    public var canUninstall: Bool { uninstallURL != nil }
    public var explanation: String {
        if provider == .epic {
            return "Epic Games Launcher va s’ouvrir. Dans Bibliothèque, retrouvez « \(name) », ouvrez son menu ⋯, puis choisissez Désinstaller et confirmez dans Epic. StorageScope vérifie ensuite le manifeste local. Les sauvegardes et composants partagés ne sont jamais nettoyés par StorageScope. Vérifiez aussi les options du launcher."
        }
        return canUninstall
            ? "Le moteur officiel demandera confirmation. StorageScope vérifiera ensuite le manifeste local. Les sauvegardes, mods et composants partagés ne sont pas nettoyés."
            : "Ce launcher ne fournit pas de méthode intégrée vérifiable pour cette installation. Utilisez sa désinstallation officielle ; aucun dossier de jeu ne sera supprimé directement."
    }
}

public protocol GameLibraryAdapter: Sendable {
    func detect() async -> [ManagedGame]
    func prepare(_ game: ManagedGame) async -> Bool
    func execute(_ game: ManagedGame) async -> Bool
    func verify(_ game: ManagedGame) async -> Bool
}

public actor LocalGameLibraryAdapter: GameLibraryAdapter {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func detect() -> [ManagedGame] {
        var games = steamGames()
        for root in [
            home.appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"),
            URL(fileURLWithPath: "/Users/Shared/Epic Games/EpicGamesLauncher/Data/Manifests")
        ] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for file in files where file.pathExtension == "item" {
                guard let data = try? safeData(file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = object["AppName"] as? String,
                      let name = object["DisplayName"] as? String,
                      let path = object["InstallLocation"] as? String,
                      path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { continue }
                let size = (object["InstallSize"] as? NSNumber)?.int64Value
                if let main = object["MainGameAppName"] as? String, !main.isEmpty, main != id { continue }
                if object["bIsApplication"] as? Bool == false { continue }
                guard let identity = manifestIdentity(file), (try? safeData(file)) == data else { continue }
                games.append(ManagedGame(id: "epic:" + id, name: name, provider: .epic, installURL: URL(fileURLWithPath: path), manifestURL: file, uninstallURL: URL(string: "com.epicgames.launcher://"), estimatedBytes: size.flatMap { $0 >= 0 ? $0 : nil }, manifestIdentity: identity, manifestDigest: Data(SHA256.hash(data: data))))
            }
        }
        // These launchers have no supported universal unattended uninstall API on macOS.
        // Identify installed metadata, but leave removal to their official engine.
        let knownRoots: [(GameProvider, String)] = [(.battleNet, "/Applications/World of Warcraft"), (.battleNet, "/Applications/Diablo III"), (.battleNet, "/Applications/StarCraft II")]
        for (provider, path) in knownRoots {
            let root = URL(fileURLWithPath: path)
            let manifest = root.appendingPathComponent(".build.info")
            if (try? safeData(manifest)) != nil {
                games.append(ManagedGame(id: provider.rawValue + ":" + path, name: root.lastPathComponent, provider: provider, installURL: root, manifestURL: manifest, uninstallURL: nil))
            }
        }
        var seen: Set<String> = []
        return games.filter { seen.insert($0.installURL.standardizedFileURL.path).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func unavailabilityReason(_ game: ManagedGame) async -> String? {
        guard detect().contains(game), game.canUninstall else { return "L’installation a changé ou sa méthode n’est pas disponible. Actualisez la liste." }
        if game.provider == .epic, let url = game.uninstallURL {
            let installed = await MainActor.run { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }
            if !installed { return "Epic Games Launcher est absent. Réinstallez le launcher officiel pour désinstaller ce jeu ; aucun fichier n’a été supprimé." }
        }
        return nil
    }

    public func prepare(_ game: ManagedGame) async -> Bool {
        await unavailabilityReason(game) == nil
    }

    public func verify(_ game: ManagedGame) -> Bool {
        // Only the disappearance of the original registration is accepted as evidence.
        guard let files = try? FileManager.default.contentsOfDirectory(at: game.manifestURL.deletingLastPathComponent(), includingPropertiesForKeys: nil),
              !files.contains(game.manifestURL) else { return false }
        if game.provider == .epic {
            for file in files where file.pathExtension == "item" {
                guard let data = try? safeData(file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                if "epic:" + (object["AppName"] as? String ?? "") == game.id,
                   let path = object["InstallLocation"] as? String,
                   URL(fileURLWithPath: path).standardizedFileURL == game.installURL.standardizedFileURL { return false }
            }
        }
        return true
    }

    public func execute(_ game: ManagedGame) async -> Bool {
        guard await prepare(game), let url = game.uninstallURL else { return false }
        return await MainActor.run { NSWorkspace.shared.open(url) }
    }

    private func steamGames() -> [ManagedGame] {
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam]
        let file = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let data = try? safeData(file), let text = String(data: data, encoding: .utf8) {
            libraries += captures("\"path\"\\s+\"([^\"]+)\"", in: text).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        var result: [ManagedGame] = []
        for library in libraries {
            let apps = library.appendingPathComponent("steamapps")
            guard let files = try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let data = try? safeData(file), let text = String(data: data, encoding: .utf8),
                      let id = captures("\"appid\"\\s+\"([0-9]+)\"", in: text).first,
                      file.lastPathComponent == "appmanifest_\(id).acf",
                      let name = captures("\"name\"\\s+\"([^\"]+)\"", in: text).first,
                      let directory = captures("\"installdir\"\\s+\"([^\"]+)\"", in: text).first,
                      !directory.contains("/"), !directory.contains("\\"), directory != ".", directory != ".." else { continue }
                result.append(ManagedGame(id: "steam:" + id, name: name, provider: .steam,
                    installURL: apps.appendingPathComponent("common").appendingPathComponent(directory),
                    manifestURL: file, uninstallURL: URL(string: "steam://uninstall/" + id),
                    estimatedBytes: captures("\"SizeOnDisk\"\\s+\"([0-9]+)\"", in: text).first.flatMap(Int64.init)))
            }
        }
        return result
    }

    private func safeData(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, let size = values.fileSize, size <= 2_000_000 else { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: file)
    }

    private func manifestIdentity(_ file: URL) -> FileIdentity? {
        var information = stat()
        let result = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &information)
        }
        guard result == 0, information.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(deviceID: FileIdentity.deviceID(fromRawValue: information.st_dev), inode: UInt64(information.st_ino), fileType: UInt16(information.st_mode & S_IFMT))
    }
    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { result in Range(result.range(at: 1), in: text).map { String(text[$0]) } }
    }
}
