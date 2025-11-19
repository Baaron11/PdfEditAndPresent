//
//  RecentFilesManager.swift
//  PdfEditAndPresent
//
//  Created by Claude on 2025-11-19.
//

import SwiftUI

struct RecentFile: Codable, Hashable {
    var urlBookmarkData: Data        // security-scoped if outside sandbox
    var displayName: String
    var lastOpened: Date
}

final class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    @Published private(set) var items: [RecentFile] = []

    private let storageKey = "recent.files.v2"

    init() { load() }

    // Add or bump existing:
    func addOrBump(url: URL, displayName: String? = nil) {
        let name = displayName ?? (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        let rf = RecentFile(urlBookmarkData: bookmark, displayName: name, lastOpened: Date())
        if let idx = items.firstIndex(where: { $0.displayName == name }) {
            items[idx] = rf
        } else if let idx = indexOf(url: url) {
            items[idx] = rf
        } else {
            items.insert(rf, at: 0)
        }
        // Keep only 10 most recent
        if items.count > 10 {
            items = Array(items.prefix(10))
        }
        persist()
    }

    // When Save As or rename occurs:
    func updateAfterSaveAsOrRename(from oldURL: URL?, to newURL: URL) {
        let name = (try? newURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? newURL.lastPathComponent
        let bookmark = (try? newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()

        if let oldURL, let oldIdx = indexOf(url: oldURL) {
            items.remove(at: oldIdx)
        }
        let rf = RecentFile(urlBookmarkData: bookmark, displayName: name, lastOpened: Date())
        if let existingIdx = indexOf(url: newURL) {
            items[existingIdx] = rf
        } else {
            items.insert(rf, at: 0)
        }
        // Keep only 10 most recent
        if items.count > 10 {
            items = Array(items.prefix(10))
        }
        persist()
    }

    // Resolve a recent file to its URL
    func resolveURL(for item: RecentFile) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: item.urlBookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        return url
    }

    // Remove a recent file
    func remove(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        items.remove(at: index)
        persist()
    }

    // Helpers
    private func indexOf(url: URL) -> Int? {
        for (i, item) in items.enumerated() {
            var isStale = false
            if let u = try? URL(resolvingBookmarkData: item.urlBookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if u.standardizedFileURL == url.standardizedFileURL { return i }
            }
        }
        return nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        items = decoded
    }
}
