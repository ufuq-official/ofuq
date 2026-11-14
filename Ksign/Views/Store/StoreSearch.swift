//
//  StoreSearch.swift
//  Ofuq
//
//  How the store finds apps. Before, an app was listed when the query appeared anywhere in its name,
//  developer, subtitle, bundle ID or source name, newest first: searching "clash" listed VPN tools and apps
//  whose bundle ID happened to contain those letters, and Clash of Clans came last. Now:
//  - every word of the query must start a word ("clash" finds "Clash of Clans" and "Castle Clashers",
//    not "Video Web" whose bundle ID is com.theclashsoft…); inside a name it may also be found as a part
//    ("rocket" finds "InstagramRocket");
//  - results are ranked: the name equal to the query, then names starting with it, then names with a word
//    starting with it, then the developer, the subtitle, the category and the source. Among equals,
//    well-known apps come first, then the list's own order (newest first);
//  - common Arabic spellings of well-known names find them ("كلاش" finds Clash, "يوتيوب" YouTube);
//  - a bundle ID is only searched when the query looks like one ("com.supercell").
//

import Foundation
import AltSourceKit

enum StoreSearch {
	// MARK: Text

	/// Lowercased, without accents or Arabic diacritics, and with the Arabic letters that are often typed
	/// one for another made the same: أ إ آ ٱ → ا, ة → ه, ى → ي, and the Persian / Kurdish ک ی → ك ي.
	static func fold(_ text: String) -> String {
		let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
		guard folded.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else {
			return folded
		}
		var scalars = String.UnicodeScalarView()
		for scalar in folded.unicodeScalars {
			switch scalar.value {
			case 0x0622, 0x0623, 0x0625, 0x0671:
				scalars.append(Unicode.Scalar(UInt32(0x0627))!) // alef
			case 0x0629:
				scalars.append(Unicode.Scalar(UInt32(0x0647))!) // heh
			case 0x0649, 0x06CC:
				scalars.append(Unicode.Scalar(UInt32(0x064A))!) // yeh
			case 0x06A9:
				scalars.append(Unicode.Scalar(UInt32(0x0643))!) // kaf
			case 0x0640, 0x064B...0x065F, 0x0670:
				continue // tatweel and short vowels
			default:
				scalars.append(scalar)
			}
		}
		return String(scalars)
	}

	/// The words of folded text: letters and digits; anything else separates them.
	static func words(_ folded: String) -> [String] {
		folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
	}

	/// The name that tells apps apart in the store. "Clash of Clans (1737658856)" is the same app as
	/// "Clash of Clans" (a trailing group without letters is an upload number or a date), while
	/// "YouTube (YP)" and "YouTube (LRD)" stay two apps.
	static func normalizedName(_ name: String) -> String {
		var name = fold(name).trimmingCharacters(in: .whitespacesAndNewlines)
		while
			let last = name.last, last == ")" || last == "]",
			let open = name.lastIndex(where: { $0 == "(" || $0 == "[" }),
			!name[open...].contains(where: \.isLetter)
		{
			name = String(name[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return words(name).joined(separator: " ")
	}

	// MARK: Apps

	/// What the search looks at in one app, folded once (when the catalog is built, off the main thread).
	struct Fields: Sendable {
		/// The words of the name, joined with a space: "clash of clans".
		let name: String
		/// The words of the name, joined: "instagramrocket".
		let compactName: String
		let nameWords: [String]
		let developerWords: [String]
		let subtitleWords: [String]
		let categoryWords: [String]
		let sourceWords: [String]
		let bundleID: String
		/// One of the apps most people look for (see `wellKnown`): first among equal results.
		let isWellKnown: Bool

		init(app: ASRepository.App, source: ASRepository, categories: [String] = []) {
			let nameWords = StoreSearch.words(StoreSearch.fold(app.currentName))
			self.nameWords = nameWords
			self.name = nameWords.joined(separator: " ")
			self.compactName = nameWords.joined()
			self.developerWords = StoreSearch.words(StoreSearch.fold(app.developer ?? ""))
			self.subtitleWords = StoreSearch.words(StoreSearch.fold(app.subtitle ?? ""))
			self.categoryWords = categories.flatMap { StoreSearch.words(StoreSearch.fold($0)) }
			self.sourceWords = StoreSearch.words(StoreSearch.fold(source.name ?? ""))
			self.bundleID = StoreSearch.fold(app.id ?? "")
			let name = self.name
			self.isWellKnown = !name.isEmpty && StoreSearch._wellKnown.contains { known in
				name.hasPrefix(known) || (known.hasPrefix(name) && name.count >= known.count - 2)
			}
		}
	}

	// MARK: Query

	struct Query: Sendable {
		fileprivate struct Form: Sendable {
			let text: String
			let compact: String
			let words: [String]

			init(words: [String]) {
				self.words = words
				self.text = words.joined(separator: " ")
				self.compact = words.joined()
			}
		}

		/// The query as typed, then its English forms when it is an Arabic spelling of a known name.
		fileprivate let forms: [Form]
		/// Set when the query looks like a bundle ID ("com.supercell"), which is then searched too.
		fileprivate let bundleID: String?

		/// Nil when the query has no letters or digits.
		init?(_ raw: String) {
			let folded = StoreSearch.fold(raw.trimmingCharacters(in: .whitespacesAndNewlines))
			let words = StoreSearch.words(folded)
			guard !words.isEmpty else { return nil }

			var forms = [Form(words: words)]
			for alias in StoreSearch._aliases(for: words) where !forms.contains(where: { $0.words == alias }) {
				forms.append(Form(words: alias))
			}
			self.forms = forms
			self.bundleID = folded.contains(".") && !folded.contains(" ") ? folded : nil
		}
	}

	/// How well `app` matches `query`: 0 when it does not match, up to 1000 for the exact name.
	static func score(_ query: Query, _ app: Fields) -> Int {
		var best = 0
		for form in query.forms {
			best = max(best, _score(form, app))
			if best >= 1000 { break }
		}
		if best == 0, let bundleID = query.bundleID, app.bundleID.contains(bundleID) {
			best = 100
		}
		return best
	}

	private static func _score(_ query: Query.Form, _ app: Fields) -> Int {
		if app.name == query.text { return 1000 }
		if app.name.hasPrefix(query.text) { return 900 }
		if _allFound(query.words, in: [app.nameWords]) { return 700 }
		if query.compact.count >= 3, app.compactName.contains(query.compact) { return 500 }
		if _allFound(query.words, in: [app.developerWords]) { return 300 }
		if query.words.count > 1, _allFound(query.words, in: [app.nameWords, app.developerWords, app.subtitleWords]) {
			return 250
		}
		if _allFound(query.words, in: [app.subtitleWords]) { return 200 }
		if _allFound(query.words, in: [app.categoryWords]) { return 150 }
		if _allFound(query.words, in: [app.sourceWords]) { return 100 }
		return 0
	}

	/// Every query word starts a word of one of `fields`.
	private static func _allFound(_ queryWords: [String], in fields: [[String]]) -> Bool {
		queryWords.allSatisfy { queryWord in
			fields.contains { words in
				words.contains { word in
					word.hasPrefix(queryWord) || _missesLastLetter(word, of: queryWord)
				}
			}
		}
	}

	/// "royal" for "royale": a word written without the query word's last letter.
	private static func _missesLastLetter(_ word: String, of queryWord: String) -> Bool {
		word.count >= 4 && queryWord.count == word.count + 1 && queryWord.hasPrefix(word)
	}

	// MARK: Ranking

	/// The items that match `query`, best first; equal ones keep the order of `items`.
	static func rank<T>(_ items: [T], by query: Query, fields: (T) -> Fields) -> [T] {
		var scored: [(score: Int, wellKnown: Bool, index: Int)] = []
		for (index, item) in items.enumerated() {
			let itemFields = fields(item)
			let value = score(query, itemFields)
			if value > 0 {
				scored.append((value, itemFields.isWellKnown, index))
			}
		}
		scored.sort { lhs, rhs in
			if lhs.score != rhs.score { return lhs.score > rhs.score }
			if lhs.wellKnown != rhs.wellKnown { return lhs.wellKnown }
			return lhs.index < rhs.index
		}
		return scored.map { items[$0.index] }
	}

	// MARK: Names

	/// The English forms of an Arabic query: the whole query when it is a known spelling, otherwise each
	/// known word replaced ("كلاش رويال" → "clash royale"), and while typing a single word of three letters
	/// or more, the names it starts ("يوتي" → "youtube").
	private static func _aliases(for words: [String]) -> [[String]] {
		guard words.contains(where: { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }) else {
			return []
		}
		let text = words.joined(separator: " ")
		var result: [[String]] = []

		if let names = _aliasTable[text] {
			result += names
		} else if words.count > 1 {
			var replaced: [String] = []
			var changed = false
			for word in words {
				if let name = _aliasTable[word]?.first {
					replaced += name
					changed = true
				} else {
					replaced.append(word)
				}
			}
			if changed {
				result.append(replaced)
			}
		} else if text.count >= 3 {
			for (spelling, names) in _aliasTable where spelling.hasPrefix(text) && !spelling.contains(" ") {
				result += names
				if result.count >= 4 { break }
			}
		}
		return result
	}

	/// Arabic spellings (folded) → the words of the names they stand for.
	private static let _aliasTable: [String: [[String]]] = {
		let spellings: [(String, [String])] = [
			("كلاش", ["clash"]), ("كلاش اوف كلانس", ["clash of clans"]), ("كلاش اوف كلانز", ["clash of clans"]),
			("كلانس", ["clans"]), ("كلانز", ["clans"]), ("كلاش رويال", ["clash royale"]), ("رويال", ["royale"]),
			("اوف", ["of"]),
			("يوتيوب", ["youtube"]), ("يوتيوب ميوزك", ["youtube music"]), ("ميوزك", ["music"]),
			("انستا", ["instagram"]), ("انستغرام", ["instagram"]), ("انستقرام", ["instagram"]),
			("انستكرام", ["instagram"]), ("انستجرام", ["instagram"]),
			("تيك توك", ["tiktok", "tik tok"]), ("تيكتوك", ["tiktok"]),
			("سناب", ["snapchat"]), ("سناب شات", ["snapchat"]), ("سنابشات", ["snapchat"]),
			("واتساب", ["whatsapp"]), ("واتس", ["whatsapp"]), ("واتس اب", ["whatsapp"]), ("وتساب", ["whatsapp"]),
			("تلكرام", ["telegram"]), ("تليكرام", ["telegram"]), ("تلغرام", ["telegram"]),
			("تيليجرام", ["telegram"]), ("تليجرام", ["telegram"]), ("تيليكرام", ["telegram"]),
			("فيسبوك", ["facebook"]), ("فيس بوك", ["facebook"]), ("ماسنجر", ["messenger"]),
			("تويتر", ["twitter"]), ("سبوتيفاي", ["spotify"]), ("سبوتفاي", ["spotify"]),
			("نتفلكس", ["netflix"]), ("نتفليكس", ["netflix"]), ("شاهد", ["shahid"]),
			("ديسكورد", ["discord"]), ("ريديت", ["reddit"]), ("تويتش", ["twitch"]),
			("ساوند كلاود", ["soundcloud"]), ("انغامي", ["anghami"]),
			("ببجي", ["pubg"]), ("بوبجي", ["pubg"]), ("فري فاير", ["free fire"]), ("فري", ["free"]), ("فاير", ["fire"]),
			("ماين كرافت", ["minecraft"]), ("ماينكرافت", ["minecraft"]), ("روبلوكس", ["roblox"]),
			("فورتنايت", ["fortnite"]), ("كول اوف ديوتي", ["call of duty"]),
			("براول ستارز", ["brawl stars"]), ("براول", ["brawl"]), ("ستارز", ["stars"]),
			("هاي داي", ["hay day"]), ("سب واي", ["subway surfers"]), ("صب واي", ["subway surfers"]),
			("كاندي كراش", ["candy crush"]), ("جاتا", ["gta"]), ("جيتا", ["gta"]),
			("بيس", ["efootball", "pes"]), ("ايفوتبول", ["efootball"]), ("فيفا", ["fifa", "fc mobile"]),
			("امونج اس", ["among us"]), ("امنق اس", ["among us"]), ("جيومتري داش", ["geometry dash"]),
			("كاب كات", ["capcut"]), ("كابكات", ["capcut"]), ("لايت روم", ["lightroom"]),
			("بيكس ارت", ["picsart"]), ("بيكسارت", ["picsart"]),
			("شات جي بي تي", ["chatgpt"]), ("جات جي بي تي", ["chatgpt"]),
			("دلتا", ["delta"]), ("محاكي", ["emulator"]),
		]
		var table: [String: [[String]]] = [:]
		for (spelling, names) in spellings {
			let key = StoreSearch.words(StoreSearch.fold(spelling)).joined(separator: " ")
			table[key, default: []] += names.map { StoreSearch.words(StoreSearch.fold($0)) }
		}
		return table
	}()

	/// Apps most people look for: first among results that match equally ("clash" lists Clash of Clans
	/// and Clash Royale before other names starting with Clash).
	private static let _wellKnown: [String] = [
		"clash of clans", "clash royale", "brawl stars", "hay day", "pubg", "free fire", "minecraft", "roblox",
		"fortnite", "call of duty", "subway surfers", "candy crush", "among us", "geometry dash", "efootball",
		"youtube", "instagram", "tiktok", "snapchat", "whatsapp", "telegram", "facebook", "messenger", "twitter",
		"spotify", "netflix", "discord", "capcut", "chatgpt",
	]
}
