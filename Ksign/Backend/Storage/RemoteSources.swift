//
//  RemoteSources.swift
//  Ofuq
//
//  Sources managed from GitHub. The `sources/` folder of the Ofuq repository holds JSON source files
//  and a `links.txt` file of source links; a GitHub Action lists all of them in `sources/index.json`.
//  Every time the app opens (and on pull to refresh in Sources) it reads that list:
//
//  - a source added on GitHub is added to the app, without the user doing anything;
//  - a source taken off the list on GitHub is removed from the app, but only if this sync added it;
//  - a source the user removed by hand is not added again;
//  - sources the user added by hand are never touched.
//

import Foundation

enum RemoteSources {
	private struct Index: Decodable {
		let sources: [String]
	}

	/// Links this sync added to the app.
	private static let _addedKey = "ofuq.remoteSources.added"
	/// Links this sync added that the user removed since: not added again.
	private static let _dismissedKey = "ofuq.remoteSources.dismissed"

	private static var _isSyncing = false

	/// Reads the list on GitHub and updates the app's sources. Quiet: a failure only means trying again later.
	static func sync() {
		guard let url = URL(string: Ofuq.remoteSourcesIndex) else { return }

		DispatchQueue.main.async {
			guard !_isSyncing else { return }
			_isSyncing = true

			Task.detached(priority: .utility) {
				let listed = await _fetchList(from: url)
				await MainActor.run {
					if let listed {
						_apply(listed)
					}
					_isSyncing = false
				}
			}
		}
	}

	private static func _fetchList(from url: URL) async -> [String]? {
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		let reply = try? await URLSession.shared.data(for: request)
		guard
			let reply,
			(reply.1 as? HTTPURLResponse)?.statusCode == 200,
			let index = try? JSONDecoder().decode(Index.self, from: reply.0)
		else {
			return nil
		}

		var seen = Set<String>()
		return index.sources.compactMap { raw in
			let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard
				let parsed = URL(string: link),
				let scheme = parsed.scheme?.lowercased(),
				scheme == "https" || scheme == "http",
				seen.insert(parsed.absoluteString).inserted
			else {
				return nil
			}
			return parsed.absoluteString
		}
	}

	/// Main queue only.
	private static func _apply(_ listed: [String]) {
		let defaults = UserDefaults.standard
		var added = Set(defaults.stringArray(forKey: _addedKey) ?? [])
		var dismissed = Set(defaults.stringArray(forKey: _dismissedKey) ?? [])
		let listedSet = Set(listed)
		var existing = Set<String>()

		for source in Storage.shared.getSources() {
			guard let url = source.sourceURL else { continue }
			let link = url.absoluteString

			if added.contains(link), !listedSet.contains(link) {
				// Taken off the list on GitHub: taken out of the app too.
				Storage.shared.deleteSource(for: source)
				SourceCache.remove(for: url)
				added.remove(link)
				continue
			}
			existing.insert(link)
		}

		// Added by an earlier sync and no longer in the app: the user removed it.
		for link in added where !existing.contains(link) {
			dismissed.insert(link)
		}
		added.formIntersection(existing)
		// Forget dismissed links that are no longer listed, so listing them again later adds them again.
		dismissed.formIntersection(listedSet)

		defaults.set(Array(added), forKey: _addedKey)
		defaults.set(Array(dismissed), forKey: _dismissedKey)

		for link in listed where !existing.contains(link) && !dismissed.contains(link) {
			FR.handleSource(
				link,
				silent: true,
				onDuplicate: {
					// The same source is already in the app under another link: do not download it every launch.
					_remember(link, in: _dismissedKey)
				},
				competion: {
					_remember(link, in: _addedKey)
				}
			)
		}
	}

	private static func _remember(_ link: String, in key: String) {
		var values = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
		values.insert(link)
		UserDefaults.standard.set(Array(values), forKey: key)
	}
}
