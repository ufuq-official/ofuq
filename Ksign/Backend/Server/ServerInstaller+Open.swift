//
//  ServerInstaller+Open.swift
//  Ofuq
//
//  Opens the iOS install prompt straight from the app, for both Fully Local and Semi Local.
//  Semi Local used to show the install page in a Safari sheet first; that page is now only a fallback.
//

import UIKit
import OSLog

extension ServerInstaller {
	/// When on, Semi Local shows the old Safari install page instead of opening the prompt directly.
	static let semiLocalUsesSafariKey = "Ofuq.semiLocalUsesSafari"

	static var semiLocalUsesSafari: Bool {
		UserDefaults.standard.bool(forKey: semiLocalUsesSafariKey)
	}

	/// True only when the local server actually bound a port and reported no start error.
	var isServerUp: Bool {
		startError == nil && port != 0
	}

	/// Shows the system "Install <app>?" prompt.
	/// - Parameter showSafariPage: called on the main queue for Semi Local when Safari is preferred or
	///   iOS refuses the link, so the caller can present `pageEndpoint` in a Safari sheet as before.
	func openInstallPrompt(showSafariPage: @escaping () -> Void) {
		let isSemiLocal = serverMethod == Self.semiLocal
		// Always an HTTPS manifest: Fully Local serves its own, Semi Local takes it from the external generator.
		let link = iTunesLink
		let useSafari = isSemiLocal && Self.semiLocalUsesSafari

		// The local server must be up before iOS fetches the manifest/payload, otherwise the install
		// fails silently. A dead server (no bound port / start error) goes straight to the Safari fallback.
		guard isServerUp else {
			Logger.misc.error("Install prompt requested but the local server is not up")
			DispatchQueue.main.async {
				if isSemiLocal { showSafariPage() }
			}
			return
		}

		// Give the local server a moment to answer before firing the link. For Fully Local this also checks what
		// iOS will need: that local.backloop.dev leads back to this iPhone and that its HTTPS certificate is accepted.
		verifyLocalServerReady(
			timeout: isSemiLocal ? 2.0 : 5.0,
			requestTimeout: isSemiLocal ? 0.6 : 2.5
		) { [weak self] ready in
			guard let self else { return }

			if !ready && !isSemiLocal {
				// iOS would fail the same way: install through Semi Local instead of failing silently.
				DispatchQueue.main.async {
					if self.fallBackToSemiLocal() {
						self.openInstallPrompt(showSafariPage: showSafariPage)
					} else {
						let error = self.startError ?? ServerInstallerError.serverFailedToStart
						self.viewModel.status = .broken(error)
						UIAlertController.showAlertWithOk(title: .localized("Install"), message: error.localizedDescription)
					}
				}
				return
			}

			if !ready {
				Logger.misc.warning("Local server did not confirm readiness; opening the install link anyway")
			}

			// Semi Local: iOS reads the manifest from the external generator. When that service refuses the
			// request (403, ...), iOS fails without saying why, so tell the user instead of opening the link.
			self.verifyExternalManifest(isSemiLocal: isSemiLocal) { [weak self] refusedStatus in
				DispatchQueue.main.async {
					guard let self else { return }

					if let refusedStatus {
						let error = ServerInstallerError.manifestRefused(refusedStatus)
						Logger.misc.error("External manifest refused with HTTP \(refusedStatus)")
						self.viewModel.status = .broken(error)
						UIAlertController.showAlertWithOk(title: .localized("Install"), message: error.localizedDescription)
						return
					}

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
	}

	/// Semi Local only: asks the external generator for the manifest once, the way iOS will.
	/// Calls back with the HTTP status when it refused (not 2xx), or nil when it answered fine, could not be
	/// reached (best effort, the link is opened anyway) or when this installer serves its own manifest.
	func verifyExternalManifest(isSemiLocal: Bool, completion: @escaping (Int?) -> Void) {
		guard isSemiLocal, let url = URL(string: externalManifestURL) else {
			completion(nil)
			return
		}

		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 5
		config.waitsForConnectivity = false
		config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		let session = URLSession(configuration: config)

		session.dataTask(with: url) { _, response, _ in
			session.finishTasksAndInvalidate()
			guard let http = response as? HTTPURLResponse else {
				completion(nil)
				return
			}
			completion((200...299).contains(http.statusCode) ? nil : http.statusCode)
		}.resume()
	}

	/// Best-effort readiness check: pings the local `/install` route until it answers or the timeout passes.
	/// Any HTTP response (even 404) means the server is alive. Never blocks a server that is actually up —
	/// on timeout it still calls back so the caller proceeds.
	func verifyLocalServerReady(
		timeout: TimeInterval = 2.0,
		requestTimeout: TimeInterval = 0.6,
		completion: @escaping (Bool) -> Void
	) {
		let probeURL = pageEndpoint
		let deadline = Date().addingTimeInterval(timeout)

		let config = URLSessionConfiguration.ephemeral
		// Fully Local needs room for a DNS lookup of local.backloop.dev and a TLS handshake.
		config.timeoutIntervalForRequest = requestTimeout
		config.waitsForConnectivity = false
		config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		let session = URLSession(configuration: config)

		var finished = false
		func finish(_ value: Bool) {
			guard !finished else { return }
			finished = true
			session.finishTasksAndInvalidate()
			completion(value)
		}

		func attempt() {
			var request = URLRequest(url: probeURL)
			request.httpMethod = "GET"
			session.dataTask(with: request) { _, response, _ in
				if response is HTTPURLResponse {
					finish(true)
					return
				}
				if Date() < deadline {
					DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { attempt() }
				} else {
					finish(false)
				}
			}.resume()
		}

		attempt()
	}
}
