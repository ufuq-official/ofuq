//
//  StoreCatalog.swift
//  Ofuq
//
//  Collects the apps of every added source into one catalog for the store screens
//  (Today, Apps, Games and Search): one entry per app, newest first, with a category.
//

import SwiftUI
import Combine
import AltSourceKit

// MARK: - StoreApp
/// One app from one source, as shown in the store.
struct StoreApp: Identifiable, Hashable {
	let source: ASRepository
	let app: ASRepository.App
	let category: StoreCategory
	let isFeatured: Bool

	var id: String { app.currentUniqueId }
	var name: String { app.currentName }
	var date: Date? { app.currentDate?.date }

	/// The colour used behind the app's cards.
	var tint: Color {
		app.tintColor ?? source.tintColor ?? category.colors[0]
	}

	/// "version • category", the line under the app's name.
	var detailLine: String {
		var parts: [String] = []
		if let version = app.currentVersion, !version.isEmpty {
			parts.append(version)
		}
		parts.append(category.title)
		return parts.joined(separator: " • ")
	}

	/// The big title of a Today card.
	var headline: String {
		if let subtitle = app.subtitle, !subtitle.isEmpty {
			return subtitle
		}
		return name
	}

	/// Updated in the last two weeks.
	var isRecent: Bool {
		guard let date else { return false }
		return Date().timeIntervalSince(date) < 14 * 24 * 60 * 60
	}

	func matches(_ query: String) -> Bool {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return true }
		return name.localizedCaseInsensitiveContains(query)
			|| (app.developer?.localizedCaseInsensitiveContains(query) ?? false)
			|| (app.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
			|| (app.id?.localizedCaseInsensitiveContains(query) ?? false)
			|| (source.name?.localizedCaseInsensitiveContains(query) ?? false)
			|| category.title.localizedCaseInsensitiveContains(query)
	}

	static func == (lhs: StoreApp, rhs: StoreApp) -> Bool {
		lhs.id == rhs.id
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

// MARK: - StoreCategory
enum StoreCategory: String, CaseIterable, Identifiable, Hashable {
	case games
	case entertainment
	case social
	case photoVideo
	case utilities
	case developer
	case lifestyle
	case other

	var id: String { rawValue }

	var title: String {
		switch self {
		case .games:         return .localized("Games")
		case .entertainment: return .localized("Entertainment")
		case .social:        return .localized("Social")
		case .photoVideo:    return .localized("Photo & Video")
		case .utilities:     return .localized("Utilities")
		case .developer:     return .localized("Developer Tools")
		case .lifestyle:     return .localized("Lifestyle")
		case .other:         return .localized("Other")
		}
	}

	var symbol: String {
		switch self {
		case .games:         return "gamecontroller.fill"
		case .entertainment: return "play.tv.fill"
		case .social:        return "bubble.left.and.bubble.right.fill"
		case .photoVideo:    return "camera.fill"
		case .utilities:     return "wrench.and.screwdriver.fill"
		case .developer:     return "hammer.fill"
		case .lifestyle:     return "heart.fill"
		case .other:         return "square.grid.2x2.fill"
		}
	}

	/// Gradient of the category's Browse tile.
	var colors: [Color] {
		switch self {
		case .games:         return [Color(red: 0.42, green: 0.27, blue: 0.95), Color(red: 0.20, green: 0.12, blue: 0.55)]
		case .entertainment: return [Color(red: 0.96, green: 0.27, blue: 0.38), Color(red: 0.62, green: 0.08, blue: 0.30)]
		case .social:        return [Color(red: 0.13, green: 0.60, blue: 0.98), Color(red: 0.05, green: 0.30, blue: 0.70)]
		case .photoVideo:    return [Color(red: 1.00, green: 0.62, blue: 0.18), Color(red: 0.86, green: 0.33, blue: 0.10)]
		case .utilities:     return [Color(red: 0.16, green: 0.74, blue: 0.62), Color(red: 0.05, green: 0.42, blue: 0.40)]
		case .developer:     return [Color(red: 0.40, green: 0.44, blue: 0.52), Color(red: 0.14, green: 0.15, blue: 0.20)]
		case .lifestyle:     return [Color(red: 0.95, green: 0.42, blue: 0.68), Color(red: 0.70, green: 0.20, blue: 0.48)]
		case .other:         return [Color(red: 0.55, green: 0.38, blue: 0.25), Color(red: 0.25, green: 0.16, blue: 0.10)]
		}
	}

	/// Uses the category the source gives, and guesses from the app's name when it gives none.
	static func resolve(_ app: ASRepository.App) -> StoreCategory {
		if let raw = app.category?.lowercased() {
			let key = raw
				.replacingOccurrences(of: "_", with: "-")
				.replacingOccurrences(of: " ", with: "-")
			switch key {
			case "games", "game", "gaming", "emulator", "emulators", "emulation":
				return .games
			case "entertainment", "music", "video", "media", "streaming", "movies", "tv":
				return .entertainment
			case "social", "social-networking", "communication", "messaging", "chat":
				return .social
			case "photo-video", "photo-&-video", "photo", "photography", "camera":
				return .photoVideo
			case "developer", "developer-tools", "development", "developers":
				return .developer
			case "utilities", "utility", "tools", "productivity", "system":
				return .utilities
			case "lifestyle", "education", "books", "news", "health", "reference":
				return .lifestyle
			default:
				break
			}
		}

		let text = [app.name, app.subtitle, app.id]
			.compactMap { $0?.lowercased() }
			.joined(separator: " ")

		func has(_ words: [String]) -> Bool {
			words.contains { text.contains($0) }
		}

		if has(["emulator", "emu ", "game", "nintendo", "gameboy", "game boy", "playstation", "psp", "retro", "arcade", "minecraft", "doom", "console"]) {
			return .games
		}
		if has(["video", "music", "player", "stream", "youtube", "movie", "anime", "manga", "podcast", "radio", " tv"]) {
			return .entertainment
		}
		if has(["chat", "social", "messag", "twitter", "discord", "reddit", "telegram", "mastodon"]) {
			return .social
		}
		if has(["photo", "camera", "image", "gallery"]) {
			return .photoVideo
		}
		if has(["terminal", "ssh", "jit", "developer", "debug", "virtual machine", "shell", "code", "container", "sideload"]) {
			return .developer
		}
		if app.category?.lowercased() == "other" {
			return .other
		}
		return .utilities
	}
}

// MARK: - StoreCollection
/// A list of apps that a Browse tile or a section opens.
enum StoreCollection: Hashable, Identifiable {
	case newest
	case featured
	case suggested
	case category(StoreCategory)

	var id: String {
		switch self {
		case .newest:                return "newest"
		case .featured:              return "featured"
		case .suggested:             return "suggested"
		case .category(let category): return "category.\(category.rawValue)"
		}
	}

	var title: String {
		switch self {
		case .newest:                return .localized("Newest")
		case .featured:              return .localized("Featured")
		case .suggested:             return .localized("Suggested")
		case .category(let category): return category.title
		}
	}

	var symbol: String {
		switch self {
		case .newest:                return "sparkles"
		case .featured:              return "star.fill"
		case .suggested:             return "hand.thumbsup.fill"
		case .category(let category): return category.symbol
		}
	}

	var colors: [Color] {
		switch self {
		case .newest:
			return [Color(red: 0.79, green: 0.64, blue: 0.49), Color(red: 0.42, green: 0.27, blue: 0.16)]
		case .featured:
			return [Color(red: 0.98, green: 0.76, blue: 0.25), Color(red: 0.80, green: 0.45, blue: 0.08)]
		case .suggested:
			return [Color(red: 0.36, green: 0.80, blue: 0.95), Color(red: 0.16, green: 0.42, blue: 0.85)]
		case .category(let category):
			return category.colors
		}
	}
}

// MARK: - StoreCatalog
final class StoreCatalog: ObservableObject {
	static let shared = StoreCatalog()

	/// Every app, newest first.
	@Published private(set) var apps: [StoreApp] = []

	private(set) var games: [StoreApp] = []
	private(set) var nonGames: [StoreApp] = []
	private(set) var featured: [StoreApp] = []
	private(set) var suggestions: [StoreApp] = []
	private(set) var sourceNames: [String] = []

	private var _isRefreshing = false
	private var _cancellable: AnyCancellable?

	private init() {
		_cancellable = SourcesViewModel.shared.$sources
			.receive(on: DispatchQueue.main)
			.sink { [weak self] sources in
				guard let self, !self._isRefreshing else { return }
				self._rebuild(from: sources)
			}
	}

	// MARK: Lists

	/// The stories of the Today tab: featured apps first, then the latest updates.
	var todayStories: [StoreApp] {
		var seen = Set<String>()
		var result: [StoreApp] = []
		let candidates: [StoreApp] = Array(featured.prefix(4)) + apps
		for item in candidates where !seen.contains(item.id) {
			seen.insert(item.id)
			result.append(item)
			if result.count == 10 { break }
		}
		return result
	}

	/// The Browse tiles of the Search tab, only for lists that have apps.
	var browseCollections: [StoreCollection] {
		guard !apps.isEmpty else { return [] }
		var result: [StoreCollection] = [.newest]
		if !featured.isEmpty {
			result.append(.featured)
		}
		for category in StoreCategory.allCases where apps.contains(where: { $0.category == category }) {
			result.append(.category(category))
		}
		return result
	}

	func items(for collection: StoreCollection) -> [StoreApp] {
		switch collection {
		case .newest:                return apps
		case .featured:              return featured.isEmpty ? Array(apps.prefix(20)) : featured
		case .suggested:             return suggestions
		case .category(let category): return apps.filter { $0.category == category }
		}
	}

	func search(_ query: String) -> [StoreApp] {
		apps.filter { $0.matches(query) }
	}

	// MARK: Loading

	/// Pull to refresh: reloads every source and rebuilds the catalog once, so the lists
	/// do not empty out while the sources come back one by one.
	func refresh(_ sources: FetchedResults<AltSource>) async {
		await MainActor.run { self._isRefreshing = true }
		await SourcesViewModel.shared.fetchSources(sources, refresh: true)
		await MainActor.run {
			self._isRefreshing = false
			self._rebuild(from: SourcesViewModel.shared.sources)
		}
	}

	private func _rebuild(from sources: [AltSource: ASRepository]) {
		var byKey: [String: StoreApp] = [:]
		var names = Set<String>()

		for repository in sources.values {
			if let name = repository.name, !name.isEmpty {
				names.insert(name)
			}
			let featuredIDs = Set((repository.featuredApps ?? []).compactMap { $0 })

			for app in repository.apps where app.currentDownloadUrl != nil {
				let isFeatured = app.id.map { featuredIDs.contains($0) } ?? false
				let item = StoreApp(
					source: repository,
					app: app,
					category: StoreCategory.resolve(app),
					isFeatured: isFeatured
				)
				// The same app can be listed by several sources: keep its newest release.
				let key = app.id ?? item.id
				if let existing = byKey[key] {
					let newer = (item.date ?? .distantPast) > (existing.date ?? .distantPast)
					let keep = newer ? item : existing
					byKey[key] = StoreApp(
						source: keep.source,
						app: keep.app,
						category: keep.category,
						isFeatured: existing.isFeatured || isFeatured
					)
				} else {
					byKey[key] = item
				}
			}
		}

		let sorted = byKey.values.sorted { lhs, rhs in
			let left = lhs.date ?? .distantPast
			let right = rhs.date ?? .distantPast
			if left != right {
				return left > right
			}
			return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
		}

		games = sorted.filter { $0.category == .games }
		nonGames = sorted.filter { $0.category != .games }
		featured = sorted.filter { $0.isFeatured }
		suggestions = Array(sorted.shuffled().prefix(15))
		sourceNames = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		apps = sorted
	}
}
