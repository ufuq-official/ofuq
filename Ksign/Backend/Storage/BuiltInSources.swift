//
//  BuiltInSources.swift
//  Ofuq
//
//  The built-in sources (the list in Storage+Sources.swift) are checked every time the app opens:
//
//  - a built-in source missing from the app is added again, so a source that could not be downloaded
//    on the first launch (slow network, a server that was down) no longer stays missing for good;
//  - a built-in source the user removed is not added again;
//  - a source with a known identifier is added straight away, without waiting to download its whole
//    file: its apps and icon load like those of every other source, from the cache and then the network.
//

import Foundation

enum BuiltInSources {
	/// Built-in links that were in the app at some point. One missing now was removed by the user.
	private static let _seenKey = "ofuq.builtInSources.seen"

	/// Identifier and name as each source file gives them (checked 2026-11-13). A link that is not here,
	/// for example one added to the list later, is downloaded first, as before.
	private static let _known: [String: (id: String, name: String)] = [
		"https://raw.githubusercontent.com/M1noa/Sideload-Tools/main/merged-apps-original-links-no-pal.json":
			("com.m1noa.sideload-tools.merged", "Minoa's Combined"),
		"https://raw.githubusercontent.com/drphe/KhoIPA/main/upload/ipaomtk.json":
			("com.ipaomtk.repo", "IPAOMTK Apps"),
		"https://delvek.net/repo.json":
			("DELvEK.NET", "DELvEK.NET"),
		"https://ipa.cypwn.xyz/cypwn.json":
			("xyz.cypwn.ipalibrary", "CyPwn IPA Library"),
		"https://raw.githubusercontent.com/apptesters-org/AppTesters_Repo/main/apps.json":
			("org.apptesters.repo", "AppTesters IPA Repo"),
		"https://apps.altstore.io":
			("com.rileytestut.AltStore", "AltStore"),
		"https://fastsign.dev/repo.json":
			("dev.fastsign.repo", "Alan's Gigantic Repo"),
		"https://apps.sidestore.io":
			("com.SideStore.SideStore", "SideStore Official"),
		"https://community-apps.sidestore.io/sidecommunity.json":
			("com.sidestoreapps.community", "SideStore Team Picks"),
		"https://alt.getutm.app":
			("com.utmapp.repos.UTM", "UTM Repository"),
		"https://provenance-emu.com/apps.json":
			("com.provenance-emu.provenance.altstore", "Provenance Emulator"),
		"https://xitrix.github.io/iTorrent/AltStore.json":
			("com.xitrix.itorrent", "iTorrent Source"),
		"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json":
			("com.livecontainer.source", "LiveContainer"),
	]

	/// Main queue only (called from the app delegate when the app opens).
	static func ensure(_ links: [String]) {
		let defaults = UserDefaults.standard
		var seen = Set(defaults.stringArray(forKey: _seenKey) ?? [])
		let sources = Storage.shared.getSources()
		let inApp = Set(sources.compactMap { $0.sourceURL.map { _key($0.absoluteString) } })
		var added = false

		for raw in links {
			guard let url = _url(raw) else { continue }
			let link = url.absoluteString
			let known = _known[link]

			let isInApp = inApp.contains(_key(link)) || (known.map { Storage.shared.sourceExists($0.id) } ?? false)
			if isInApp {
				seen.insert(link)
				continue
			}
			// It was in the app and is not any more: the user removed it.
			guard !seen.contains(link) else { continue }

			if let known {
				Storage.shared.addSource(url, name: known.name, identifier: known.id, deferSave: true, isBuiltIn: true) { _ in }
				seen.insert(link)
				added = true
			} else {
				FR.handleSource(
					link,
					silent: true,
					onDuplicate: { _remember(link) },
					competion: { _remember(link) }
				)
			}
		}

		defaults.set(Array(seen), forKey: _seenKey)
		if added {
			Storage.shared.saveContext()
		}
	}

	private static func _url(_ raw: String) -> URL? {
		var link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if !link.isEmpty, !link.contains("://") {
			link = "https://" + link
		}
		guard let url = URL(string: link), url.host != nil else { return nil }
		return url
	}

	/// "https://Example.com/repo.json/" and "https://example.com/repo.json" are the same source.
	private static func _key(_ link: String) -> String {
		var key = link.lowercased()
		while key.hasSuffix("/") {
			key.removeLast()
		}
		return key
	}

	private static func _remember(_ link: String) {
		var values = Set(UserDefaults.standard.stringArray(forKey: _seenKey) ?? [])
		values.insert(link)
		UserDefaults.standard.set(Array(values), forKey: _seenKey)
	}
}
