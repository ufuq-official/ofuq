//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//
//  Ofuq: the sources open from the cache first (see SourceCache), so the store fills in right away,
//  even offline. The network is only asked for sources that are not cached yet or whose copy is older
//  than `freshness`; pulling to refresh asks for all of them, and unchanged sources answer "not modified".
//
//  Every source is shown as soon as it is ready instead of waiting for the slowest one, a failed refresh
//  keeps the cached copy on screen, and loads never overlap: a request made while one runs is queued
//  and runs right after, so a source added meanwhile is never left out.
//

import Foundation
import AltSourceKit
import SwiftUI

// MARK: - Class
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	/// False while sources are loading.
	@Published private(set) var isFinished = true
	@Published var sources: [AltSource: ASRepository] = [:]
	/// Why a source that is not on screen could not be loaded (its last download failed).
	@Published private(set) var failures: [AltSource: String] = [:]

	/// When the app opens, a source checked with its server less than this long ago is only read from the cache.
	static let freshness: TimeInterval = 30 * 60
	/// Sources downloaded at the same time.
	private static let _maxDownloads = 6
	/// Cached sources decoded at the same time (a big source takes a lot of memory while it decodes).
	private static let _maxCacheReads = 3

	private struct Request {
		var list: [AltSource]
		var refresh: Bool
	}

	private struct Item {
		let source: AltSource
		let url: URL
		let legacyKey: String?
	}

	private struct Job {
		let item: Item
		let conditional: Bool
	}

	// Only touched on the main queue.
	private var _isRunning = false
	private var _pending: Request?
	private var _waiters: [CheckedContinuation<Void, Never>] = []

	// MARK: Fetch

	/// Loads `sources` (the cache first, then the network when needed) and returns once they are done.
	func fetchSources(_ sources: FetchedResults<AltSource>, refresh: Bool = false, batchSize: Int = 6) async {
		let list: [AltSource] = await MainActor.run { Array(sources) }
		await fetch(list, refresh: refresh)
	}

	func fetch(_ list: [AltSource], refresh: Bool = false) async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			DispatchQueue.main.async {
				self._enqueue(Request(list: list, refresh: refresh), continuation: continuation)
			}
		}
	}

	/// Main queue only.
	private func _enqueue(_ request: Request, continuation: CheckedContinuation<Void, Never>) {
		if _isRunning {
			// Runs right after the current load, with the newest list.
			_pending = Request(list: request.list, refresh: request.refresh || (_pending?.refresh ?? false))
			_waiters.append(continuation)
			return
		}

		// Nothing to do: every source is on screen and no refresh was asked for.
		if !request.refresh, request.list.allSatisfy({ sources[$0] != nil }) {
			continuation.resume()
			return
		}

		_isRunning = true
		isFinished = false
		_waiters.append(continuation)

		// Detached on purpose: SwiftUI cancels a view's task when the source list changes, and that
		// must never cancel downloads that are already running.
		Task.detached(priority: .userInitiated) {
			await self._loop(request)
		}
	}

	private func _loop(_ first: Request) async {
		var next: Request? = first

		while let request = next {
			await _run(request)

			next = await MainActor.run { () -> Request? in
				if let pending = self._pending {
					self._pending = nil
					return pending
				}

				self._isRunning = false
				self.isFinished = true
				let waiters = self._waiters
				self._waiters.removeAll()
				waiters.forEach { $0.resume() }
				return nil
			}
		}
	}

	private func _run(_ request: Request) async {
		// Managed objects are only read on the main queue.
		let items: [Item] = await MainActor.run {
			request.list.compactMap { source in
				guard
					!source.isDeleted,
					source.managedObjectContext != nil,
					let url = source.sourceURL
				else {
					return nil
				}
				return Item(source: source, url: url, legacyKey: source.identifier)
			}
		}

		// Removed sources disappear; the others stay on screen while they refresh.
		let notShown: [Item] = await MainActor.run {
			let current = Set(items.map(\.source))
			let kept = self.sources.filter { current.contains($0.key) }
			if kept.count != self.sources.count {
				self.sources = kept
			}
			if self.failures.keys.contains(where: { !current.contains($0) }) {
				self.failures = self.failures.filter { current.contains($0.key) }
			}
			return items.filter { self.sources[$0.source] == nil }
		}

		// 1. The cache, each source shown as soon as it is read.
		await Self._forEach(notShown, maxConcurrent: Self._maxCacheReads) { item in
			guard let repository = SourceCache.load(url: item.url, legacyKey: item.legacyKey) else { return }
			await MainActor.run {
				if self.sources[item.source] == nil {
					self.sources[item.source] = repository
					self.failures[item.source] = nil
					Self._fillDetails(of: item.source, from: repository)
					Self._prefetchFirstIcons(of: repository)
				}
			}
		}

		// 2. The network: sources still missing, or whose copy is old (all of them on a refresh).
		let shown: Set<AltSource> = await MainActor.run { Set(self.sources.keys) }
		let jobs: [Job] = items.compactMap { item in
			let isShown = shown.contains(item.source)
			if !request.refresh, isShown, SourceCache.isFresh(url: item.url, maxAge: Self.freshness) {
				return nil
			}
			// Ask "has it changed?" only when a copy is on screen to fall back on.
			return Job(item: item, conditional: isShown)
		}

		await Self._forEach(jobs, maxConcurrent: Self._maxDownloads) { job in
			let result = await SourceCache.fetch(url: job.item.url, conditional: job.conditional)
			guard case .updated(let repository) = result else {
				// Not modified, or failed: whatever is on screen (the cached copy) stays.
				if case .failed(let error) = result {
					await MainActor.run {
						if self.sources[job.item.source] == nil {
							self.failures[job.item.source] = error.localizedDescription
						}
					}
				}
				return
			}
			await MainActor.run {
				// The source may have been removed while it downloaded.
				guard !job.item.source.isDeleted, job.item.source.managedObjectContext != nil else { return }
				self.sources[job.item.source] = repository
				self.failures[job.item.source] = nil
				Self._fillDetails(of: job.item.source, from: repository)
				Self._prefetchFirstIcons(of: repository)
			}
		}
	}

	/// Built-in sources are added before their file is downloaded (see BuiltInSources.swift): their icon,
	/// and their name if they have none, come from the file. Also keeps a source's icon up to date.
	@MainActor
	private static func _fillDetails(of source: AltSource, from repository: ASRepository) {
		guard !source.isDeleted, source.managedObjectContext != nil else { return }
		var changed = false

		if let icon = repository.currentIconURL, source.iconURL != icon {
			source.iconURL = icon
			changed = true
		}
		if let name = repository.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
			let current = source.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			if current.isEmpty || current == "Unknown" {
				source.name = name
				changed = true
			}
		}
		if changed {
			Storage.shared.saveContext()
		}
	}

	/// The source's icon and the icons of its first apps (the rows on screen when it opens) are made ready,
	/// so opening a source shows them at once.
	@MainActor
	private static func _prefetchFirstIcons(of repository: ASRepository) {
		let ascending = UserDefaults.standard.object(forKey: "Feather.sortAscending") as? Bool ?? true
		let first = ascending ? Array(repository.apps.prefix(10)) : Array(repository.apps.suffix(10).reversed())
		IconPrefetcher.prepare([repository.currentIconURL].compactMap { $0 } + first.compactMap(\.iconURL))
	}

	/// Runs `body` for every element, at most `maxConcurrent` at a time.
	private static func _forEach<T>(
		_ elements: [T],
		maxConcurrent: Int,
		_ body: @escaping (T) async -> Void
	) async {
		guard !elements.isEmpty else { return }

		await withTaskGroup(of: Void.self) { group in
			var iterator = elements.makeIterator()

			for _ in 0..<max(1, maxConcurrent) {
				guard let element = iterator.next() else { break }
				group.addTask { await body(element) }
			}

			while await group.next() != nil {
				if let element = iterator.next() {
					group.addTask { await body(element) }
				}
			}
		}
	}
}
