//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//
//  Ofuq: sources are cached on disk, so the store opens instantly and keeps working offline.
//  On refresh the list is never emptied out — each source is updated in place as it returns, and a
//  source whose network refresh fails keeps its last cached copy instead of disappearing.
//

import Foundation
import AltSourceKit
import SwiftUI

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]

	// MARK: Disk cache

	/// Where each source's last good JSON is kept (instant open + offline).
	private static var _cacheDir: URL {
		let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("OfuqSourceCache", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private static func _cacheURL(forKey key: String) -> URL {
		let safe = key.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
		return _cacheDir.appendingPathComponent(String(safe.prefix(120)) + ".json")
	}

	// MARK: Fetch

	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 4) async {
		guard isFinished else { return }

		// check if sources to be fetched are the same as before, if yes, return
		// also skip check if refresh is true
		if !refresh, sources.allSatisfy({ self.sources[$0] != nil }) { return }

		// isFinished is used to prevent multiple fetches at the same time
		isFinished = false
		defer { isFinished = true }

		// Managed objects aren't safe off their queue, so read what we need on the main actor up front.
		let items: [(source: AltSource, url: URL, cacheKey: String)] = await MainActor.run {
			Array(sources).compactMap { src in
				guard let url = src.sourceURL else { return nil }
				let key = src.identifier ?? url.absoluteString
				return (src, url, key)
			}
		}

		// Drop sources the user removed, but keep the rest visible (no blanking on refresh).
		await MainActor.run {
			let current = Set(items.map { $0.source })
			self.sources = self.sources.filter { current.contains($0.key) }
		}

		// 1) Show cached copies right away.
		await _loadFromCache(items)

		// 2) Refresh from the network in batches, updating each source as it returns.
		for startIndex in stride(from: 0, to: items.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, items.count)
			let batch = items[startIndex..<endIndex]

			let batchResults = await withTaskGroup(of: (AltSource, ASRepository?).self, returning: [AltSource: ASRepository].self) { group in
				for item in batch {
					group.addTask {
						let repo = await Self._fetchAndCache(url: item.url, cacheKey: item.cacheKey)
						return (item.source, repo)
					}
				}

				var results = [AltSource: ASRepository]()
				for await (source, repo) in group {
					if let repo {
						results[source] = repo
					}
				}
				return results
			}

			await MainActor.run {
				// A failed refresh keeps the cached copy already in `sources`.
				for (source, repo) in batchResults {
					self.sources[source] = repo
				}
			}
		}
	}

	/// Loads any not-yet-shown source from its cached JSON, decoded off the main thread.
	private func _loadFromCache(_ items: [(source: AltSource, url: URL, cacheKey: String)]) async {
		let decoded: [(AltSource, ASRepository)] = await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				var out: [(AltSource, ASRepository)] = []
				for item in items {
					let url = Self._cacheURL(forKey: item.cacheKey)
					guard
						let data = try? Data(contentsOf: url),
						let repo = try? JSONDecoder().decode(ASRepository.self, from: data)
					else {
						continue
					}
					out.append((item.source, repo))
				}
				continuation.resume(returning: out)
			}
		}

		guard !decoded.isEmpty else { return }
		await MainActor.run {
			for (source, repo) in decoded where self.sources[source] == nil {
				self.sources[source] = repo
			}
		}
	}

	/// Downloads a source, writes its JSON to the cache, and returns the decoded repository.
	private static func _fetchAndCache(url: URL, cacheKey: String) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			let task = URLSession.shared.dataTask(with: url) { data, _, _ in
				guard
					let data,
					let repo = try? JSONDecoder().decode(ASRepository.self, from: data)
				else {
					continuation.resume(returning: nil)
					return
				}
				try? data.write(to: _cacheURL(forKey: cacheKey), options: .atomic)
				continuation.resume(returning: repo)
			}
			task.resume()
		}
	}
}
