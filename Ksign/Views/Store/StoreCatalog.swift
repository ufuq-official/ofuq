//
//  StoreCatalog.swift
//  Ofuq
//
//  Collects the apps of every added source into one catalog for the store screens
//  (Today, Apps, Games and Search): one entry per app, newest first, sorted into
//  app and game categories.
//

import SwiftUI
import Combine
import AltSourceKit

// MARK: - StoreApp
/// One app from one source, as shown in the store.
struct StoreApp: Identifiable, Hashable {
	let source: ASRepository
	let app: ASRepository.App
	/// Shown in the Games tab instead of the Apps tab.
	let isGame: Bool
	/// Every category the app belongs to, the main one first.
	let categories: [StoreCategory]
	var isFeatured: Bool

	init(source: ASRepository, app: ASRepository.App, isFeatured: Bool) {
		self.source = source
		self.app = app
		self.isFeatured = isFeatured
		let classification = StoreCategory.classify(app)
		self.isGame = classification.isGame
		self.categories = classification.categories
	}

	var id: String { app.currentUniqueId }
	var name: String { app.currentName }
	var date: Date? { app.currentDate?.date }
	var downloads: Int? { app.downloads }

	/// The colour used behind the app's cards.
	var tint: Color {
		if let color = app.tintColor {
			return color
		}
		if let color = source.tintColor {
			return color
		}
		if let category = categories.first {
			return category.colors[0]
		}
		return Color.accentColor
	}

	/// "version • category", the line under the app's name.
	var detailLine: String {
		var parts: [String] = []
		if let version = app.currentVersion, !version.isEmpty {
			parts.append(version)
		}
		if let category = categories.first {
			parts.append(category.title)
		} else {
			parts.append(isGame ? String.localized("Games") : String.localized("Apps"))
		}
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
		let twoWeeks: TimeInterval = 1_209_600 // 14 days in seconds
		return Date().timeIntervalSince(date) < twoWeeks
	}

	func belongs(to category: StoreCategory) -> Bool {
		categories.contains(category)
	}

	func matches(_ query: String) -> Bool {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		if query.isEmpty {
			return true
		}
		// One field at a time: a single long `||`/`??` chain is slow for the compiler to check.
		let fields: [String?] = [name, app.developer, app.subtitle, app.id, source.name]
		for field in fields {
			if let field, field.localizedCaseInsensitiveContains(query) {
				return true
			}
		}
		for category in categories where category.title.localizedCaseInsensitiveContains(query) {
			return true
		}
		return false
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
	// Apps
	case social
	case entertainment
	case design
	case productivity
	case business
	case research
	case ai
	case islamic
	case gps
	case utilities
	case developer
	case jailbreak
	case lifestyle

	// Games
	case emulators
	case action
	case sports
	case racing
	case puzzle
	case adventure
	case strategy
	case billiards

	var id: String { rawValue }

	var isGame: Bool {
		switch self {
		case .emulators, .action, .sports, .racing, .puzzle, .adventure, .strategy, .billiards:
			return true
		default:
			return false
		}
	}

	static var appCategories: [StoreCategory] { allCases.filter { !$0.isGame } }
	static var gameCategories: [StoreCategory] { allCases.filter { $0.isGame } }

	/// Short name, for the filter menu and the line under an app's name.
	var title: String {
		switch self {
		case .social:        return .localized("Social")
		case .entertainment: return .localized("Entertainment")
		case .design:        return .localized("Design")
		case .productivity:  return .localized("Productivity")
		case .business:      return .localized("Enterprise")
		case .research:      return .localized("Research & Digital Services")
		case .ai:            return .localized("Artificial Intelligence")
		case .islamic:       return .localized("Islamic")
		case .gps:           return .localized("GPS & Location")
		case .utilities:     return .localized("Utilities")
		case .developer:     return .localized("Developer Tools")
		case .jailbreak:     return .localized("Jailbreak")
		case .lifestyle:     return .localized("Lifestyle")
		case .emulators:     return .localized("Emulators")
		case .action:        return .localized("Action Games")
		case .sports:        return .localized("Sports Games")
		case .racing:        return .localized("Racing Games")
		case .puzzle:        return .localized("Puzzle Games")
		case .adventure:     return .localized("Adventure Games")
		case .strategy:      return .localized("Strategy Games")
		case .billiards:     return .localized("Billiards")
		}
	}

	/// Longer name, for the Browse tiles and the list they open.
	var browseTitle: String {
		switch self {
		case .social:        return .localized("Social Apps")
		case .entertainment: return .localized("Entertainment Apps")
		case .design:        return .localized("Design Apps")
		case .productivity:  return .localized("Productivity Apps")
		case .business:      return .localized("Enterprise Apps")
		case .research:      return .localized("Research & Digital Services")
		case .ai:            return .localized("AI Apps")
		case .islamic:       return .localized("Islamic Apps")
		case .gps:           return .localized("GPS & Location Apps")
		case .utilities:     return .localized("Utility Apps")
		case .developer:     return .localized("Developer Tools")
		case .jailbreak:     return .localized("Jailbreak Tools")
		case .lifestyle:     return .localized("Lifestyle Apps")
		case .billiards:     return .localized("Billiards Games")
		default:             return title
		}
	}

	var symbol: String {
		switch self {
		case .social:        return "bubble.left.and.bubble.right.fill"
		case .entertainment: return "play.tv.fill"
		case .design:        return "paintbrush.pointed.fill"
		case .productivity:  return "checklist"
		case .business:      return "building.2.fill"
		case .research:      return "books.vertical.fill"
		case .ai:            return "brain.head.profile"
		case .islamic:       return "moon.stars.fill"
		case .gps:           return "location.fill"
		case .utilities:     return "wrench.and.screwdriver.fill"
		case .developer:     return "hammer.fill"
		case .jailbreak:     return "lock.open.fill"
		case .lifestyle:     return "heart.fill"
		case .emulators:     return "gamecontroller.fill"
		case .action:        return "flame.fill"
		case .sports:        return "sportscourt.fill"
		case .racing:        return "car.fill"
		case .puzzle:        return "puzzlepiece.fill"
		case .adventure:     return "map.fill"
		case .strategy:      return "crown.fill"
		case .billiards:     return "8.circle.fill"
		}
	}

	/// Gradient of the category's Browse tile.
	var colors: [Color] {
		func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
			Color(red: red, green: green, blue: blue)
		}
		switch self {
		case .social:        return [rgb(0.13, 0.60, 0.98), rgb(0.05, 0.30, 0.70)]
		case .entertainment: return [rgb(0.96, 0.27, 0.38), rgb(0.62, 0.08, 0.30)]
		case .design:        return [rgb(1.00, 0.62, 0.18), rgb(0.86, 0.33, 0.10)]
		case .productivity:  return [rgb(0.20, 0.78, 0.45), rgb(0.06, 0.45, 0.28)]
		case .business:      return [rgb(0.30, 0.42, 0.62), rgb(0.12, 0.18, 0.32)]
		case .research:      return [rgb(0.55, 0.45, 0.95), rgb(0.28, 0.18, 0.62)]
		case .ai:            return [rgb(0.62, 0.36, 0.98), rgb(0.20, 0.42, 0.95)]
		case .islamic:       return [rgb(0.10, 0.62, 0.48), rgb(0.03, 0.32, 0.26)]
		case .gps:           return [rgb(0.18, 0.80, 0.86), rgb(0.06, 0.45, 0.62)]
		case .utilities:     return [rgb(0.16, 0.74, 0.62), rgb(0.05, 0.42, 0.40)]
		case .developer:     return [rgb(0.40, 0.44, 0.52), rgb(0.14, 0.15, 0.20)]
		case .jailbreak:     return [rgb(0.98, 0.35, 0.25), rgb(0.55, 0.10, 0.20)]
		case .lifestyle:     return [rgb(0.95, 0.42, 0.68), rgb(0.70, 0.20, 0.48)]
		case .emulators:     return [rgb(0.42, 0.27, 0.95), rgb(0.20, 0.12, 0.55)]
		case .action:        return [rgb(0.95, 0.30, 0.16), rgb(0.58, 0.10, 0.06)]
		case .sports:        return [rgb(0.25, 0.75, 0.30), rgb(0.08, 0.42, 0.18)]
		case .racing:        return [rgb(0.98, 0.72, 0.15), rgb(0.85, 0.35, 0.08)]
		case .puzzle:        return [rgb(0.30, 0.62, 0.98), rgb(0.40, 0.22, 0.85)]
		case .adventure:     return [rgb(0.62, 0.48, 0.28), rgb(0.30, 0.20, 0.10)]
		case .strategy:      return [rgb(0.80, 0.62, 0.20), rgb(0.42, 0.25, 0.08)]
		case .billiards:     return [rgb(0.08, 0.55, 0.30), rgb(0.02, 0.25, 0.14)]
		}
	}

	// MARK: Sorting apps into categories

	/// Uses the category the source gives (any of the names below, several can be separated
	/// by commas), then adds categories guessed from the app's name, subtitle and identifier.
	static func classify(_ app: ASRepository.App) -> (isGame: Bool, categories: [StoreCategory]) {
		var result: [StoreCategory] = []
		var isGame = false

		func add(_ category: StoreCategory) {
			if !result.contains(category) {
				result.append(category)
			}
		}

		// 1. The source's own category.
		let separators: Set<Character> = [",", "/", "|"]
		let pieces: [Substring] = (app.category ?? "").lowercased().split(whereSeparator: { separators.contains($0) })
		var rawValues: [String] = []
		for piece in pieces {
			var raw = piece.trimmingCharacters(in: .whitespaces)
			raw = raw.replacingOccurrences(of: "_", with: "-")
			raw = raw.replacingOccurrences(of: " ", with: "-")
			rawValues.append(raw)
		}

		for raw in rawValues {
			if let category = _sourceCategories[raw] {
				add(category)
				if category.isGame { isGame = true }
			} else if _gameWords.contains(raw) {
				isGame = true
			}
		}

		// 2. Guesses from the text.
		let textParts: [String?] = [app.name, app.subtitle, app.id]
		let text: String = textParts.compactMap { $0?.lowercased() }.joined(separator: " ")
		let tokens: [String] = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
		let words: Set<String> = Set(tokens.filter { !$0.isEmpty })

		func matches(_ keywords: Keywords) -> Bool {
			if !keywords.words.isDisjoint(with: words) {
				return true
			}
			return keywords.parts.contains { text.contains($0) }
		}

		if !isGame, matches(_gameHints) {
			isGame = true
		}

		let candidates = isGame ? gameCategories : appCategories
		for category in candidates where !result.contains(category) {
			if let keywords = _keywords[category], matches(keywords) {
				add(category)
			}
		}

		// 3. Apps that fit nowhere go to Utilities; games without a genre stay in Games only.
		if !isGame, !result.contains(where: { !$0.isGame }) {
			add(.utilities)
		}

		// A game's categories are only game genres, an app's only app categories.
		result = result.filter { $0.isGame == isGame }
		if !isGame, result.isEmpty {
			result = [.utilities]
		}
		return (isGame, result)
	}

	private struct Keywords {
		/// Matched as whole words.
		var words: Set<String> = []
		/// Matched anywhere in the text.
		var parts: [String] = []
	}

	/// Category names that sources can use.
	private static let _sourceCategories: [String: StoreCategory] = [
		"social": .social, "social-networking": .social, "communication": .social,
		"messaging": .social, "chat": .social,
		"entertainment": .entertainment, "music": .entertainment, "video": .entertainment,
		"media": .entertainment, "streaming": .entertainment, "movies": .entertainment, "tv": .entertainment,
		"design": .design, "photo-video": .design, "photo-&-video": .design, "photo": .design,
		"photography": .design, "graphics": .design, "graphics-design": .design, "camera": .design,
		"productivity": .productivity, "office": .productivity,
		"business": .business, "enterprise": .business, "finance": .business,
		"research": .research, "education": .research, "reference": .research, "books": .research,
		"news": .research, "services": .research, "digital-services": .research, "science": .research,
		"ai": .ai, "artificial-intelligence": .ai,
		"islamic": .islamic, "islam": .islamic, "religion": .islamic, "religious": .islamic, "quran": .islamic,
		"gps": .gps, "location": .gps, "navigation": .gps, "maps": .gps,
		"utilities": .utilities, "utility": .utilities, "tools": .utilities, "system": .utilities,
		"developer": .developer, "developer-tools": .developer, "development": .developer, "developers": .developer,
		"jailbreak": .jailbreak,
		"lifestyle": .lifestyle, "health": .lifestyle, "health-&-fitness": .lifestyle, "fitness": .lifestyle,
		"emulator": .emulators, "emulators": .emulators, "emulation": .emulators,
		"action": .action, "shooter": .action, "fighting": .action, "arcade": .action,
		"sports": .sports, "sport": .sports,
		"racing": .racing, "race": .racing,
		"puzzle": .puzzle, "puzzles": .puzzle, "board": .puzzle, "card": .puzzle, "casual": .puzzle, "word": .puzzle,
		"adventure": .adventure, "rpg": .adventure, "role-playing": .adventure, "simulation": .adventure,
		"strategy": .strategy,
		"billiards": .billiards, "billiard": .billiards, "pool": .billiards, "snooker": .billiards
	]

	/// Source categories that only say "game".
	private static let _gameWords: Set<String> = ["games", "game", "gaming"]

	/// Words that make an app a game when the source does not say so.
	private static let _gameHints = Keywords(
		words: ["game", "games", "gaming", "arcade", "console", "nintendo", "playstation", "xbox",
				"gameboy", "emulator", "emulators"],
		parts: ["لعبة", "ألعاب", "العاب"]
	)

	private static let _keywords: [StoreCategory: Keywords] = [
		.social: Keywords(
			words: ["chat", "social", "messenger", "telegram", "whatsapp", "discord", "reddit", "twitter",
					"mastodon", "bluesky", "signal", "matrix", "irc", "threads"],
			parts: ["messag", "تواصل", "دردشة", "محادثة"]
		),
		.entertainment: Keywords(
			words: ["video", "music", "player", "stream", "streaming", "youtube", "movie", "movies", "anime",
					"manga", "podcast", "podcasts", "radio", "tv", "iptv", "media", "comics", "jellyfin", "plex", "kodi"],
			parts: ["ترفيه", "أفلام", "موسيقى", "مسلسلات"]
		),
		.design: Keywords(
			words: ["photo", "photos", "camera", "image", "images", "gallery", "design", "draw", "drawing",
					"paint", "sketch", "wallpaper", "wallpapers", "font", "fonts", "collage"],
			parts: ["photo editor", "video editor", "تصميم", "خلفيات", "رسم"]
		),
		.productivity: Keywords(
			words: ["productivity", "notes", "note", "calendar", "todo", "tasks", "task", "reminder", "reminders",
					"office", "pdf", "document", "documents", "docs", "spreadsheet", "planner", "markdown"],
			parts: ["to-do", "إنتاجية", "ملاحظات", "مهام"]
		),
		.business: Keywords(
			words: ["business", "enterprise", "crm", "erp", "invoice", "invoices", "workspace", "mdm",
					"finance", "accounting", "inventory"],
			parts: ["مؤسس", "شركات", "أعمال"]
		),
		.research: Keywords(
			words: ["research", "science", "education", "learn", "learning", "dictionary", "wiki", "wikipedia",
					"encyclopedia", "library", "reference", "study", "academic", "papers", "news"],
			parts: ["أبحاث", "بحث علمي", "تعليم", "قاموس", "مكتبة"]
		),
		.ai: Keywords(
			words: ["ai", "gpt", "chatgpt", "llm", "llama", "openai", "gemini", "claude", "copilot", "deepseek",
					"mistral", "ollama", "diffusion", "whisper"],
			parts: ["artificial intelligence", "ذكاء اصطناعي", "الذكاء الاصطناعي"]
		),
		.islamic: Keywords(
			words: ["quran", "koran", "islam", "islamic", "muslim", "prayer", "prayers", "salah", "salat", "adhan",
					"azan", "athan", "hadith", "qibla", "dua", "duaa", "ramadan", "tasbih", "dhikr", "azkar", "adhkar"],
			parts: ["قرآن", "إسلام", "اسلام", "صلاة", "أذان", "اذان", "أذكار", "اذكار", "حديث", "قبلة",
					"رمضان", "دعاء", "تسبيح"]
		),
		.gps: Keywords(
			words: ["gps", "location", "locations", "map", "maps", "navigation", "navigator", "geo", "compass"],
			parts: ["خرائط", "الموقع", "ملاحة"]
		),
		.developer: Keywords(
			words: ["terminal", "ssh", "jit", "debug", "debugger", "shell", "code", "coding", "ide", "git",
					"developer", "devtools", "sideload", "sideloading", "container", "vm", "xcode", "python", "compiler"],
			parts: ["virtual machine", "مطور", "برمجة"]
		),
		.jailbreak: Keywords(
			words: ["jailbreak", "jailbroken", "dopamine", "palera1n", "unc0ver", "taurine", "odyssey", "chimera",
					"electra", "serotonin", "trollstore", "sileo", "zebra", "cydia", "ellekit", "roothide", "rootless"],
			parts: ["جلبريك", "جيلبريك"]
		),
		.emulators: Keywords(
			words: ["emulator", "emulators", "emu", "retroarch", "delta", "provenance", "ppsspp", "dolphin",
					"melonds", "citra", "nes", "snes", "gba", "gbc", "nds", "n64", "psp", "ps1", "ps2", "psx",
					"gamecube", "gameboy", "sega", "mame", "dosbox", "flycast"],
			parts: ["emulat", "محاكي"]
		),
		.action: Keywords(
			words: ["action", "shooter", "fps", "fight", "fighting", "combat", "battle", "war", "gun", "guns",
					"zombie", "zombies", "ninja", "sniper", "shooting", "brawl", "doom", "quake"],
			parts: ["أكشن", "اكشن", "قتال", "حرب"]
		),
		.sports: Keywords(
			words: ["sport", "sports", "football", "soccer", "basketball", "tennis", "golf", "nba", "cricket",
					"baseball", "hockey", "boxing", "volleyball", "bowling"],
			parts: ["رياض", "كرة قدم"]
		),
		.racing: Keywords(
			words: ["race", "racing", "racer", "drift", "kart", "moto", "motorcycle", "asphalt", "nascar", "rally"],
			parts: ["سباق", "سيارات", "تفحيط"]
		),
		.puzzle: Keywords(
			words: ["puzzle", "puzzles", "sudoku", "chess", "tetris", "crossword", "2048", "minesweeper", "trivia",
					"quiz", "logic", "jigsaw", "solitaire", "mahjong"],
			parts: ["ألغاز", "الغاز", "لغز", "شطرنج"]
		),
		.adventure: Keywords(
			words: ["adventure", "rpg", "quest", "exploration", "platformer", "minecraft", "survival", "dungeon",
					"sandbox"],
			parts: ["open world", "مغامر"]
		),
		.strategy: Keywords(
			words: ["strategy", "tower", "defense", "civilization", "tactics", "tactical", "rts", "empire",
					"kingdom", "tycoon"],
			parts: ["استراتيج", "إستراتيج"]
		),
		.billiards: Keywords(
			words: ["pool", "billiard", "billiards", "snooker", "8ball"],
			parts: ["8 ball", "بلياردو", "سنوكر"]
		)
	]
}

// MARK: - StoreCollection
/// A list of apps that a Browse tile or a section opens.
enum StoreCollection: Hashable, Identifiable {
	case topApps
	case topGames
	case newest
	case suggested
	case category(StoreCategory)

	var id: String {
		switch self {
		case .topApps:                return "topApps"
		case .topGames:               return "topGames"
		case .newest:                 return "newest"
		case .suggested:              return "suggested"
		case .category(let category): return "category.\(category.rawValue)"
		}
	}

	/// "Most Downloaded" is only claimed when the sources give download counts;
	/// without them the same lists are the sources' featured picks.
	var title: String {
		let hasCounts = StoreCatalog.shared.hasDownloadCounts
		switch self {
		case .topApps:
			return hasCounts ? String.localized("Most Downloaded Apps") : String.localized("Featured Apps")
		case .topGames:
			return hasCounts ? String.localized("Most Downloaded Games") : String.localized("Featured Games")
		case .newest:
			return .localized("Newest")
		case .suggested:
			return .localized("Suggested")
		case .category(let category):
			return category.browseTitle
		}
	}

	var symbol: String {
		switch self {
		case .topApps:                return "chart.bar.fill"
		case .topGames:               return "trophy.fill"
		case .newest:                 return "sparkles"
		case .suggested:              return "hand.thumbsup.fill"
		case .category(let category): return category.symbol
		}
	}

	var colors: [Color] {
		switch self {
		case .topApps:
			return [Color(red: 0.79, green: 0.64, blue: 0.49), Color(red: 0.42, green: 0.27, blue: 0.16)]
		case .topGames:
			return [Color(red: 0.98, green: 0.76, blue: 0.25), Color(red: 0.80, green: 0.45, blue: 0.08)]
		case .newest:
			return [Color(red: 0.36, green: 0.80, blue: 0.95), Color(red: 0.16, green: 0.42, blue: 0.85)]
		case .suggested:
			return [Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.60, green: 0.18, blue: 0.45)]
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
	/// At least one source gives download counts, so "Most Downloaded" can be shown truthfully.
	private(set) var hasDownloadCounts = false

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

	/// The Browse tiles of the Search tab: the top lists, then every app and game category.
	var browseCollections: [StoreCollection] {
		guard !apps.isEmpty else { return [] }
		var result: [StoreCollection] = [.topApps, .topGames, .newest]
		result += StoreCategory.appCategories.map { StoreCollection.category($0) }
		result += StoreCategory.gameCategories.map { StoreCollection.category($0) }
		return result
	}

	func items(for collection: StoreCollection) -> [StoreApp] {
		switch collection {
		case .topApps:                return _top(nonGames)
		case .topGames:               return _top(games)
		case .newest:                 return apps
		case .suggested:              return suggestions
		case .category(let category): return apps.filter { $0.belongs(to: category) }
		}
	}

	func count(in category: StoreCategory) -> Int {
		apps.reduce(0) { $0 + ($1.belongs(to: category) ? 1 : 0) }
	}

	func search(_ query: String) -> [StoreApp] {
		apps.filter { $0.matches(query) }
	}

	/// By download count when the sources give it, otherwise featured apps first.
	private func _top(_ list: [StoreApp]) -> [StoreApp] {
		if hasDownloadCounts {
			return list.enumerated()
				.sorted { lhs, rhs in
					let left = lhs.element.downloads ?? -1
					let right = rhs.element.downloads ?? -1
					if left != right {
						return left > right
					}
					return lhs.offset < rhs.offset
				}
				.map { $0.element }
		}
		return list.filter { $0.isFeatured } + list.filter { !$0.isFeatured }
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
				let item = StoreApp(source: repository, app: app, isFeatured: isFeatured)
				// The same app can be listed by several sources: keep its newest release.
				let key = app.id ?? item.id
				if let existing = byKey[key] {
					let newer = (item.date ?? .distantPast) > (existing.date ?? .distantPast)
					var keep = newer ? item : existing
					keep.isFeatured = existing.isFeatured || isFeatured
					byKey[key] = keep
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

		games = sorted.filter { $0.isGame }
		nonGames = sorted.filter { !$0.isGame }
		featured = sorted.filter { $0.isFeatured }
		suggestions = Array(sorted.shuffled().prefix(15))
		sourceNames = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		hasDownloadCounts = sorted.contains { $0.downloads != nil }
		apps = sorted
	}
}
