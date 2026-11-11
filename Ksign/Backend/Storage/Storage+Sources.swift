//
//  Storage+Sources.swift
//  Feather
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	func addSource(
		_ url: URL,
		name: String? = "Unknown",
		identifier: String,
		iconURL: URL? = nil,
		deferSave: Bool = false,
		isBuiltIn: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		if sourceExists(identifier) {
			completion(nil)
			print("ignoring \(identifier)")
			return
		}
		
		let new = AltSource(context: context)
		new.name = name
		new.date = Date()
		new.identifier = identifier
		new.sourceURL = url
		new.iconURL = iconURL
		new.setValue(isBuiltIn, forKey: "isBuiltIn")
		
		do {
			if !deferSave {
				try context.save()
			}
			completion(nil)
		} catch {
			completion(error)
		}
	}
	
	func addSource(
		_ url: URL,
		repository: ASRepository,
		id: String = "",
		deferSave: Bool = false,
		isBuiltIn: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		addSource(
			url,
			name: repository.name,
			identifier: !id.isEmpty
						? id
						: (repository.id ?? url.absoluteString),
			iconURL: repository.currentIconURL,
			deferSave: deferSave,
			isBuiltIn: isBuiltIn,
			completion: completion
		)
	}

	func addSources(
		repos: [URL: ASRepository],
		completion: @escaping (Error?) -> Void
	) {
		for (url, repo) in repos {
			addSource(
				url,
				repository: repo,
				deferSave: true,
				completion: { error in
					if let error {
						completion(error)
					}
				}
			)
		}
		
        saveContext()
        completion(nil)
	}


	func addBuiltInSources() {
		// Official and custom sources added (checked 2026-11-08).
		let builtInSourceURLs = [
			// المصادر التي أرسلتها:
			"https://raw.githubusercontent.com/M1noa/Sideload-Tools/main/merged-apps-original-links-no-pal.json",
			"https://raw.githubusercontent.com/drphe/KhoIPA/main/upload/ipaomtk.json",
			"https://delvek.net/repo.json",
			"https://ipa.cypwn.xyz/cypwn.json",
			"https://raw.githubusercontent.com/apptesters-org/AppTesters_Repo/main/apps.json",
			"https://apps.altstore.io",
			"https://fastsign.dev/repo.json",
			
			// المصادر الأصلية والمضافة مسبقاً:
			"https://apps.sidestore.io",
			"https://community-apps.sidestore.io/sidecommunity.json",
			"https://alt.getutm.app",
			"https://provenance-emu.com/apps.json",
			"https://xitrix.github.io/iTorrent/AltStore.json",
			"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json",
			
			// مصادر إضافية ممتازة ومشهورة لتطبيقات الـ IPA والبلس:
			"https://qnblackcat.github.io/AltStore/apps.json", // مصادر يوتيوب بلس وتطبيقات معدلة شهيرة
			"https://ipa.kenhtao.net/kenhtao.json"             // مستودع مميز لتطبيقات الألسن والبلس
		]
		
		for urlString in builtInSourceURLs {
			FR.handleSource(urlString) { }
		}
	}

	func deleteSource(for source: AltSource) {
		context.delete(source)
		saveContext()
	}

	func sourceExists(_ identifier: String) -> Bool {
		let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

		do {
			let count = try context.count(for: fetchRequest)
			return count > 0
		} catch {
			print("Error checking if repository exists: \(error)")
			return false
		}
	}
}
