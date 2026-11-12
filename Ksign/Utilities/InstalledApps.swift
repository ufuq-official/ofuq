//
//  InstalledApps.swift
//  Ofuq
//
//  Installing an app whose bundle ID is already on the iPhone replaces that app (or fails when the
//  installed one came from someone else). So an install from the store, or an .ipa shared to Ofuq, gets a
//  bundle ID that is not on the iPhone yet: the original one when it is free, otherwise the original with
//  1, 2, 3… added (WhatsApp, WhatsApp1, WhatsApp2…). A number is never given twice.
//
//  What is on the iPhone comes from iOS (LSApplicationWorkspace) when iOS answers for other apps, and
//  always from the list of bundle IDs Ofuq sent for installation itself.
//

import Foundation
import OSLog

enum InstalledApps {
	/// Settings > Installation. On by default.
	static let settingKey = "ofuq.uniqueBundleIdentifiers"

	static var isEnabled: Bool {
		UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
	}

	private static let _historyKey = "ofuq.installedBundleIdentifiers"
	/// Given to an app that is still being signed or installed (two installs of the same app at once).
	private static var _reserved = Set<String>()

	// MARK: Unique identifier

	/// `identifier` when no app has it, otherwise `identifier` followed by the first free number.
	/// The result is reserved, so a second call never returns it again. Main queue only.
	static func uniqueIdentifier(for identifier: String) -> String {
		var candidate = identifier
		var number = 0
		while _isTaken(candidate) && number < 100_000 {
			number += 1
			candidate = "\(identifier)\(number)"
		}
		_reserved.insert(candidate)
		Logger.misc.info("Bundle ID for install: \(identifier) -> \(candidate)")
		return candidate
	}

	/// Remembers a bundle ID sent for installation. Main queue only.
	static func didSendForInstall(_ identifier: String?) {
		guard let identifier, !identifier.isEmpty else { return }
		var history = UserDefaults.standard.stringArray(forKey: _historyKey) ?? []
		guard !history.contains(identifier) else { return }
		history.append(identifier)
		UserDefaults.standard.set(history, forKey: _historyKey)
	}

	private static func _isTaken(_ identifier: String) -> Bool {
		if _reserved.contains(identifier) {
			return true
		}
		if (UserDefaults.standard.stringArray(forKey: _historyKey) ?? []).contains(identifier) {
			return true
		}
		return _systemAnswers && _systemIsInstalled(identifier) == true
	}

	// MARK: iOS

	private typealias _IsInstalled = @convention(c) (AnyObject, Selector, NSString) -> Bool
	private static let _isInstalledSelector = NSSelectorFromString("applicationIsInstalled:")

	private static let _workspace: NSObject? = {
		guard
			let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
			workspace.responds(to: _isInstalledSelector)
		else {
			return nil
		}
		return workspace
	}()

	/// Whether iOS tells Ofuq about other apps: Ofuq itself and Settings must be found, a made-up ID not.
	/// When it does not, only the list of apps Ofuq installed is used.
	private static let _systemAnswers: Bool = {
		guard
			let own = Bundle.main.bundleIdentifier,
			_systemIsInstalled(own) == true,
			_systemIsInstalled("com.apple.Preferences") == true,
			_systemIsInstalled("ofuq.check.\(UUID().uuidString.lowercased())") == false
		else {
			Logger.misc.info("iOS does not report installed apps; using the apps Ofuq installed")
			return false
		}
		return true
	}()

	private static func _systemIsInstalled(_ identifier: String) -> Bool? {
		guard let workspace = _workspace else { return nil }
		// The method returns a BOOL, not an object, so it is called through its implementation.
		let implementation = workspace.method(for: _isInstalledSelector)
		let isInstalled = unsafeBitCast(implementation, to: _IsInstalled.self)
		return isInstalled(workspace, _isInstalledSelector, identifier as NSString)
	}
}
