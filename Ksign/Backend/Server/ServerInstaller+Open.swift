//
//  ServerInstaller+Open.swift
//  Ofuq
//
//  Opens the iOS install prompt straight from the app, for both Fully Local and Semi Local.
//  Semi Local used to show the install page in a Safari sheet first; that page is now only a fallback.
//

import UIKit

extension ServerInstaller {
	/// When on, Semi Local shows the old Safari install page instead of opening the prompt directly.
	static let semiLocalUsesSafariKey = "Ofuq.semiLocalUsesSafari"

	static var semiLocalUsesSafari: Bool {
		UserDefaults.standard.bool(forKey: semiLocalUsesSafariKey)
	}

	/// Shows the system "Install <app>?" prompt.
	/// - Parameter showSafariPage: called on the main queue for Semi Local when Safari is preferred or
	///   iOS refuses the link, so the caller can present `pageEndpoint` in a Safari sheet as before.
	func openInstallPrompt(showSafariPage: @escaping () -> Void) {
		let isSemiLocal = serverMethod == Self.semiLocal
		// Fully Local serves its own manifest over HTTPS; Semi Local takes it from the external generator.
		let link = isSemiLocal ? iTunesLinkExternal : iTunesLink
		let useSafari = isSemiLocal && Self.semiLocalUsesSafari

		DispatchQueue.main.async {
			if useSafari {
				showSafariPage()
				return
			}

			guard let url = URL(string: link) else {
				if isSemiLocal { showSafariPage() }
				return
			}

			UIApplication.shared.open(url, options: [:]) { opened in
				if !opened && isSemiLocal {
					DispatchQueue.main.async { showSafariPage() }
				}
			}
		}
	}
}
