//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift
import OSLog

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	/// 0 = Fully Local (HTTPS with the backloop.dev certificate), 1 = Semi Local (HTTP + external manifest).
	static let fullyLocal = 0
	static let semiLocal = 1
	// Ofuq default: Fully Local (self-contained HTTPS install, no external manifest service).
	// It automatically falls back to Semi Local when the SSL certificate is missing or invalid.
	static let defaultServerMethod = fullyLocal

	let id = UUID()
	/// The port the server actually listens on (chosen at start, retried on collisions).
	private(set) var port: Int = 0
	/// The server method this installer really uses. It can differ from the user's setting:
	/// Fully Local silently falls back to Semi Local when the SSL certificate is missing, broken or expired,
	/// and also when a Fully Local (HTTPS) server cannot bind any port (see `_start`).
	private(set) var serverMethod: Int
	/// Host used in every URL served by this installer (computed per install, never cached across network changes).
	private(set) var host: String
	/// Set when the local server could not be started; the install views show it instead of crashing.
	private(set) var startError: Error?
	private var _needsShutdown = false

	var packageUrl: URL?
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel

		var method = Self.getServerMethod()
		var tls: TLSConfiguration?

		if method == Self.fullyLocal {
			do {
				tls = try Self.tls()
			} catch {
				Logger.misc.error("Fully Local unavailable, falling back to Semi Local: \(error.localizedDescription)")
				tls = nil
			}

			if tls == nil {
				method = Self.semiLocal
			}
		}

		self.serverMethod = method
		self.host = Self.resolveHost(for: method)

		_start(tls: tls)
	}

	deinit {
		_shutdownServer()
	}

	private func _start(tls: TLSConfiguration?) {
		// Try the chosen method first.
		if _tryStart(tls: tls) { return }

		// Fallback server: a Fully Local (HTTPS) server that cannot bind any port must not block the
		// install. Downgrade to Semi Local (plain HTTP, manifest from the external generator) and retry,
		// exactly like the backup install servers in tools such as ESign.
		if tls != nil {
			Logger.misc.error("Fully Local could not bind a port; falling back to Semi Local")
			serverMethod = Self.semiLocal
			host = Self.resolveHost(for: Self.semiLocal)
			if _tryStart(tls: nil) { return }
		}

		// startError holds the last bind error from _tryStart.
		if startError == nil { startError = ServerInstallerError.serverFailedToStart }
		Logger.misc.error("Install server failed to start: \(String(describing: self.startError))")
	}

	/// Sweeps a set of candidate ports for the current host/method and returns true once one binds.
	/// Clears `startError` on success, sets it to the last bind error on failure.
	private func _tryStart(tls: TLSConfiguration?) -> Bool {
		var lastError: Error?

		for attempt in 0..<Self._portAttempts {
			let candidate = Self._candidatePort(attempt: attempt)
			let server = Self.setupApp(port: candidate, host: host, tls: tls)
			_configureRoutes(on: server)

			do {
				try server.server.start()
				port = candidate
				_server = server
				_needsShutdown = true
				startError = nil
				return true
			} catch {
				lastError = error
				server.shutdown()
			}
		}

		startError = lastError ?? ServerInstallerError.serverFailedToStart
		return false
	}

	private static let _portAttempts = 12

	/// A few stable fallback ports first (like ESign's 8080/8081), then random ones to dodge collisions.
	private static func _candidatePort(attempt: Int) -> Int {
		let preferred = [8080, 8081, 8888, 7000]
		if attempt < preferred.count { return preferred[attempt] }
		return Int.random(in: 4000...8000)
	}

	private func _configureRoutes(on server: Application) {
		server.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			// iOS asks for exactly the URLs in the manifest; comparing without case also covers a proxy
			// that changes the case of the UUID.
			switch req.url.path.lowercased() {
			case plistEndpoint.path.lowercased():
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml; charset=utf-8",
					"Cache-Control": "no-store",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path.lowercased():
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path.lowercased():
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path.lowercased():
				// The signed IPA must exist and be readable before iOS starts the install.
				guard
					let packageUrl = packageUrl,
					FileManager.default.isReadableFile(atPath: packageUrl.path)
				else {
					Logger.misc.error("Install payload requested but the signed IPA is not available")
					return Response(status: .notFound)
				}

				self._updateStatus(.sendingPayload)

				let response: Response = req.fileio.streamFile(
					at: packageUrl.path,
					mediaType: HTTPMediaType(type: "application", subType: "octet-stream")
				) { result in
                    switch result {
                    case .success:
                        self._updateStatus(.installing)
                    case .failure(let error):
                        self._updateStatus(.broken(error))
                    }
				}
				response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
				return response
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html; charset=utf-8")
				headers.add(name: .cacheControl, value: "no-store")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			default:
				return Response(status: .notFound)
			}
		}
	}

	private func _shutdownServer() {
		guard _needsShutdown, let server = _server else { return }

		_needsShutdown = false
		server.server.shutdown()
		server.shutdown()
		_server = nil
	}

	/// Restarts this installer's server as Semi Local: plain HTTP on this iPhone, manifest from the HTTPS generator.
	///
	/// Fully Local reaches its own HTTPS server through `local.backloop.dev`, a public name that has to point
	/// back to this iPhone. Some networks, routers and DNS profiles block such names, and iOS then fails the
	/// install with a connection error and no explanation. Semi Local does not depend on that name.
	/// Must be called on the main queue. Returns true when the Semi Local server is up.
	@discardableResult
	func fallBackToSemiLocal() -> Bool {
		guard serverMethod != Self.semiLocal else { return startError == nil && port != 0 }

		Logger.misc.warning("Fully Local is not reachable on this network; switching this install to Semi Local")
		_shutdownServer()
		serverMethod = Self.semiLocal
		host = Self.resolveHost(for: Self.semiLocal)
		port = 0
		startError = nil
		_start(tls: nil)
		return startError == nil && port != 0
	}

    private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}

	/// The user's chosen method. Defaults to Semi Local when nothing was saved yet,
	/// so the Settings picker and the installer always agree.
	static func getServerMethod() -> Int {
		UserDefaults.standard.object(forKey: "Feather.serverMethod") as? Int ?? defaultServerMethod
	}

	static func getIPFix() -> Bool {
		UserDefaults.standard.object(forKey: "Feather.ipFix") as? Bool ?? true
	}

	static func setServerMethod(_ method: Int) {
		UserDefaults.standard.set(method, forKey: "Feather.serverMethod")
	}

	static func setIPFix(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: "Feather.ipFix")
	}
}

enum ServerInstallerError: LocalizedError {
	case serverFailedToStart
	case certificateExpired(Date)
	case certificateNotYetValid(Date)
	/// The external manifest generator used by Semi Local refused the request (for example 403).
	case manifestRefused(Int)

	var errorDescription: String? {
		switch self {
		case .serverFailedToStart:
			return .localized("Could not start the local install server. Please close the app completely and try again.")
		case .manifestRefused(let code):
			return .localized(
				"The install manifest service answered with error %@. Switch the server to Fully Local in Settings > Installation, then try again.",
				arguments: String(code)
			)
		case .certificateExpired(let date):
			return .localized("The SSL certificate expired on %@.", arguments: date.formatted(date: .abbreviated, time: .omitted))
		case .certificateNotYetValid(let date):
			return .localized("The SSL certificate is not valid until %@.", arguments: date.formatted(date: .abbreviated, time: .omitted))
		}
	}
}
