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
	static let defaultServerMethod = semiLocal

	let id = UUID()
	/// The port the server actually listens on (chosen at start, retried on collisions).
	private(set) var port: Int = 0
	/// The server method this installer really uses. It can differ from the user's setting:
	/// Fully Local silently falls back to Semi Local when the SSL certificate is missing, broken or expired.
	let serverMethod: Int
	/// Host used in every URL served by this installer (computed per install, never cached across network changes).
	let host: String
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
		var lastError: Error?

		// A random port can already be in use; try a few before giving up.
		for _ in 0..<5 {
			let candidate = Int.random(in: 4000...8000)
			let server = Self.setupApp(port: candidate, host: host, tls: tls)
			_configureRoutes(on: server)

			do {
				try server.server.start()
				port = candidate
				_server = server
				_needsShutdown = true
				return
			} catch {
				lastError = error
				server.shutdown()
			}
		}

		startError = lastError ?? ServerInstallerError.serverFailedToStart
		Logger.misc.error("Install server failed to start: \(String(describing: self.startError))")
	}

	private func _configureRoutes(on server: Application) {
		server.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: installManifestData))
			case displayImageSmallEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageSmallData))
			case displayImageLargeEndpoint.path:
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "image/png",
				], body: .init(data: displayImageLargeData))
			case payloadEndpoint.path:
				guard let packageUrl = packageUrl else {
					return Response(status: .notFound)
				}

				self._updateStatus(.sendingPayload)

				return req.fileio.streamFile(
					at: packageUrl.path
				) { result in
                    switch result {
                    case .success:
                        self._updateStatus(.installing)
                    case .failure(let error):
                        self._updateStatus(.broken(error))
                    }
				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
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

	var errorDescription: String? {
		switch self {
		case .serverFailedToStart:
			return .localized("Could not start the local install server. Please close the app completely and try again.")
		case .certificateExpired(let date):
			return .localized("The SSL certificate expired on %@.", arguments: date.formatted(date: .abbreviated, time: .omitted))
		case .certificateNotYetValid(let date):
			return .localized("The SSL certificate is not valid until %@.", arguments: date.formatted(date: .abbreviated, time: .omitted))
		}
	}
}
