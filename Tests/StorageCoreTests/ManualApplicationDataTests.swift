import Foundation
import StorageCore

func testManualApplicationDataPolicy() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let support = home.appendingPathComponent("Library/Application Support")
    let tabnine = support.appendingPathComponent("TabNine")
    let item = FileSystemItem(url: tabnine, logicalSize: 100, allocatedSize: 100,
        isDirectory: true, category: .applicationData, safety: .system)
    try expect(DeletionSafetyPolicy.requiresApplicationDataReview(tabnine), "TabNine doit être examinable manuellement")
    try expect(item.canRequestTrash, "Un ancien index classé système ne doit pas bloquer le parcours explicite TabNine")
    try expect(!item.isTrashable, "Les données d’applications ne doivent jamais devenir des temporaires sélectionnables automatiquement")
    try expect(DeletionSafetyPolicy.safety(for: tabnine, isDirectory: true) == .review, "Les données tierces ne sont pas des fichiers système")
    let implicit = await TrashService().preflight([item])
    try expect(!implicit[0].isReady, "La corbeille ordinaire ne doit pas contourner l’avertissement")

    let blocked = [home, home.appendingPathComponent("Library"), support,
        support.appendingPathComponent("com.apple.TCC"), support.appendingPathComponent("Apple/Accounts"),
        support.appendingPathComponent("CloudDocs"), support.appendingPathComponent("StorageScope/DirectoryIndexes"),
        support.appendingPathComponent("TabNine/OneDrive/file"), support.appendingPathComponent("TabNine/steamapps/game"),
        support.appendingPathComponent("TabNine/Photos.photoslibrary"), support.appendingPathComponent("TabNine/Tool.app"),
        URL(fileURLWithPath: "/Library/Application Support/TabNine"),
        URL(fileURLWithPath: "/Users/other-account/Library/Application Support/TabNine"),
        support.appendingPathComponent("../Keychains/login.keychain-db")]
    for url in blocked {
        try expect(!DeletionSafetyPolicy.requiresApplicationDataReview(url), "Exception trop large : \(url.path)")
        let value = FileSystemItem(url: url, logicalSize: 1, allocatedSize: 1, isDirectory: true)
        let result = await TrashService().preflight([value], authorization: .manualApplicationData)
        try expect(!result[0].isReady, "L’autorisation manuelle doit être revérifiée : \(url.path)")
    }
    let linked = FileSystemItem(url: tabnine, logicalSize: 1, allocatedSize: 1, isDirectory: true, isSymbolicLink: true)
    try expect(!linked.canRequestTrash, "Les liens ne doivent pas être proposés")
}

func testTrashInventoryStates() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/fixture")
    let unknown = TrashInventoryItem(url: url, trashRoot: url.deletingLastPathComponent(),
        identity: FileIdentity(deviceID: 1, inode: 2, fileType: 0), allocatedBytesUpperBound: 0,
        isDirectory: true, sizeIsComplete: false)
    let denied = TrashInventoryIssue.from(CocoaError(.fileReadNoPermission), path: url.path)
    try expect(denied.kind == .accessDenied, "Un refus de lecture doit donner accès au réglage adéquat")
    let partial = TrashInventory(items: [unknown], issues: [denied])
    try expect(partial.items.count == 1 && partial.isPartial && partial.requiresAccess, "L’entrée doit rester visible même sans taille")
    try expect(!partial.hasMeasuredSize, "Une taille inconnue n’est pas zéro octet")
    let empty = TrashInventory(items: [], issues: [])
    try expect(empty.hasMeasuredSize && !empty.isPartial && !empty.requiresAccess, "Une corbeille vide accessible doit afficher zéro")
    let unavailable = TrashInventory(items: [], issues: [denied])
    try expect(!unavailable.hasMeasuredSize && unavailable.requiresAccess, "Une corbeille inaccessible ne doit pas être présentée comme vide")
}
