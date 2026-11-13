//
//  Ofuq.swift
//  Ofuq
//
//  Ofuq identity: developer and community links in one place.
//  Ofuq is based on Ksign (Nagata Asami) and Feather (khcrysalis), licensed under GPL-3.0.
//

import Foundation

enum Ofuq {
	static let developer = "Abbas Mousawi"

	static let telegramChannel = "https://t.me/ofuq_store"
	static let ipaChannel = "https://t.me/ufuq_ipa"
	/// Ofuq's official Instagram.
	static let instagram = "https://www.instagram.com/_cpj41"
	/// The developer's personal Instagram.
	static let developerInstagram = "https://www.instagram.com/wm3h"

	/// The sources managed from GitHub: the `sources/` folder of the Ofuq repository. A GitHub Action
	/// lists its JSON files and the links of `sources/links.txt` in this file (see sources/README.md).
	static let remoteSourcesIndex = "https://raw.githubusercontent.com/ufuq-official/ofuq/main/sources/index.json"

	/// The pictures at the top of the Today tab: the `banners/` folder of the Ofuq repository, listed by
	/// a GitHub Action in this file (see banners/README.md).
	static let bannersIndex = "https://raw.githubusercontent.com/ufuq-official/ofuq/main/banners/index.json"
}
