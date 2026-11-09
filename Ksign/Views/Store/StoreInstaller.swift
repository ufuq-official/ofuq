//
//  StoreInstaller.swift
//  Ofuq
//
//  One tap install from the store: download the app, sign it with the selected certificate
//  and the saved signing options, then open the install sheet. The same steps as the Library,
//  without having to go through it.
//
//  The install sheet (and so the itms-services link) only opens for an app that was really signed
//  with the certificate the user picked when tapping Install: no certificate, a failed signature or
//  a missing signature all stop here with a message, before anything is sent to iOS.
//

import SwiftUI
import Combine
import CoreData
import AltSourceKit

extension Notification.Name {
	/// Posted on the main queue when a downloaded package was imported. `object` is the download id.
	static let ofuqPackageImported = Notification.Name("ofuq.packageImported")
	/// Posted on the main queue when a downloaded package could not be imported. `object` is the download id,
	/// `userInfo["error"]` the error.
	static let ofuqPackageImportFailed = Notification.Name("ofuq.packageImportFailed")
}

final class StoreInstaller: ObservableObject {
	static let shared = StoreInstaller()

	enum Phase: Equatable {
		case downloading
		case signing
	}

	/// What each app is doing, keyed by `ASRepository.App.currentUniqueId`.
	@Published private(set) var phases: [String: Phase] = [:]
	/// The signed app waiting for its install sheet.
	@Published var installTarget: AnyApp?

	private struct Pending {
		let bundleID: String?
		/// The certificate confirmed when Install was tapped. Signing uses exactly this one, even if the
		/// selection in Settings changes while the app downloads.
		let certificateUUID: String
		let started: Date
	}

	private var _pending: [String: Pending] = [:]
	private var _claimedImports = Set<String>()
	private var _cancellables = Set<AnyCancellable>()

	private init() {
		// Both notifications are posted on the main queue, and are handled right away so the
		// phase changes to signing before the finished download leaves the list.
		NotificationCenter.default.publisher(for: .ofuqPackageImported)
			.sink { [weak self] notification in
				guard let id = notification.object as? String else { return }
				self?._didImport(id)
			}
			.store(in: &_cancellables)

		NotificationCenter.default.publisher(for: .ofuqPackageImportFailed)
			.sink { [weak self] notification in
				guard let self, let id = notification.object as? String, self._pending[id] != nil else { return }
				let error = notification.userInfo?["error"] as? Error
				self._finish(id)
				let message = error?.localizedDescription
					?? String.localized("The downloaded file could not be opened.")
				self._alert(title: .localized("Install"), message: message)
			}
			.store(in: &_cancellables)

		// A download that was cancelled or failed leaves the list without an import.
		DownloadManager.shared.$downloads
			.sink { [weak self] downloads in
				guard let self else { return }
				let active = Set(downloads.map(\.id))
				let lost = self.phases.filter { $0.value == .downloading && !active.contains($0.key) }.map(\.key)
				guard !lost.isEmpty else { return }
				DispatchQueue.main.async { [weak self] in
					guard let self else { return }
					for id in lost where self.phases[id] == .downloading && DownloadManager.shared.getDownload(by: id) == nil {
						self._finish(id)
					}
				}
			}
			.store(in: &_cancellables)
	}

	// MARK: Public

	func phase(for app: ASRepository.App) -> Phase? {
		phases[app.currentUniqueId]
	}

	/// Whether the store started this download and will show its own messages for it.
	func handles(_ downloadID: String) -> Bool {
		_pending[downloadID] != nil
	}

	/// Downloads, signs and installs `app`.
	func install(_ app: ASRepository.App) {
		let id = app.currentUniqueId
		guard phases[id] == nil, DownloadManager.shared.getDownload(by: id) == nil else { return }

		guard let url = app.currentDownloadUrl else {
			_alert(title: .localized("Install"), message: .localized("This app has no download link."))
			return
		}

		// Installing needs an app signed with a real certificate: iOS refuses an unsigned or ad-hoc app
		// ("integrity could not be verified"). So the store always signs with the selected certificate,
		// even when "Only modify" or "Adhoc Signing" is turned on in the signing options.
		guard let certificate = Self.selectedCertificate(), let certificateUUID = certificate.uuid else {
			_alert(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate")
			)
			return
		}

		let bundleID = app.id
		CertificateCheck.confirm(certificate) { [weak self] in
			self?._startDownload(id: id, url: url, bundleID: bundleID, certificateUUID: certificateUUID)
		}
	}

	/// Only downloads `app` into the Library, like before.
	func download(_ app: ASRepository.App) {
		guard
			let url = app.currentDownloadUrl,
			DownloadManager.shared.getDownload(by: app.currentUniqueId) == nil
		else {
			return
		}
		_ = DownloadManager.shared.startDownload(from: url, id: app.currentUniqueId)
	}

	/// The certificate picked in Settings, the same way the signing screen reads it.
	static func selectedCertificate() -> CertificatePair? {
		let request = NSFetchRequest<CertificatePair>(entityName: "CertificatePair")
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		guard let certificates = try? Storage.shared.context.fetch(request) else { return nil }
		let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		return certificates.indices.contains(index) ? certificates[index] : nil
	}

	// MARK: Steps

	private func _startDownload(id: String, url: URL, bundleID: String?, certificateUUID: String) {
		// The app may have been started meanwhile (for example a second tap while the alert was shown).
		guard phases[id] == nil, DownloadManager.shared.getDownload(by: id) == nil else { return }

		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		_pending[id] = Pending(bundleID: bundleID, certificateUUID: certificateUUID, started: Date())
		phases[id] = .downloading
		_ = DownloadManager.shared.startDownload(from: url, id: id)
	}

	private func _didImport(_ id: String, attempt: Int = 0) {
		guard let pending = _pending[id] else { return }
		phases[id] = .signing

		guard let imported = _latestImported(since: pending.started, bundleID: pending.bundleID) else {
			// The database can take a moment to show the new app.
			if attempt < 5 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
					self?._didImport(id, attempt: attempt + 1)
				}
			} else {
				_finish(id)
				_alert(title: .localized("Install"), message: .localized("The downloaded app was not found in the Library."))
			}
			return
		}

		if let uuid = imported.uuid {
			_claimedImports.insert(uuid)
		}
		_sign(imported, id: id, certificateUUID: pending.certificateUUID)
	}

	private func _sign(_ imported: Imported, id: String, certificateUUID: String) {
		// Signing is mandatory: without the confirmed certificate nothing is signed and nothing is installed.
		guard let certificate = Self._certificate(uuid: certificateUUID) else {
			_finish(id)
			_alert(
				title: .localized("No Certificate"),
				message: .localized("The certificate selected for this install was removed. Please choose a certificate in Settings and try again.")
			)
			return
		}

		let saved = OptionsManager.shared.options
		var options = saved
		// Always a real signature for an install (see `install(_:)`); these two would skip it.
		options.onlyModify = false
		options.doAdhocSigning = false

		// The same adjustments the signing screen makes when it opens.
		if
			saved.ppqProtection,
			let identifier = imported.identifier,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(saved.ppqString)"
		}

		if
			let identifier = imported.identifier,
			let newIdentifier = options.identifiers[identifier]
		{
			options.appIdentifier = newIdentifier
		}

		if
			let name = imported.name,
			let newName = options.displayNames[name]
		{
			options.appName = newName
		}

		if saved.prefix != nil || saved.suffix != nil {
			var name = imported.name ?? ""
			if let dictionaryName = options.displayNames[name] {
				name = dictionaryName
			}
			if let prefix = saved.prefix {
				name = prefix + name
			}
			if let suffix = saved.suffix {
				name = name + suffix
			}
			options.appName = name
		}

		let finalOptions = options

		// Same steps as `FR.signPackageFile`, but with the handler kept here so the exact signed app
		// (its UUID) is known: the install sheet opens for this app and no other.
		let handler = SigningHandler(app: imported, options: finalOptions)
		handler.appCertificate = certificate
		handler.appIcon = nil
		let signedUUID = handler.uuid

		Task.detached { [weak self] in
			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()

				await MainActor.run {
					guard let self else { return }
					self._finish(id)
					if finalOptions.removeApp {
						Storage.shared.deleteApp(for: imported)
					}
					self._presentInstall(signedUUID: signedUUID)
				}
			} catch {
				try? await handler.clean()

				await MainActor.run {
					guard let self else { return }
					self._finish(id)
					self._alert(title: .localized("Signing"), message: error.localizedDescription)
				}
			}
		}
	}

	private func _presentInstall(signedUUID: String, attempt: Int = 0) {
		guard let signed = _signed(uuid: signedUUID) else {
			// The database can take a moment to show the new app.
			if attempt < 5 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
					self?._presentInstall(signedUUID: signedUUID, attempt: attempt + 1)
				}
			} else {
				_alert(title: .localized("Install"), message: .localized("The signed app was not found. Please try again."))
			}
			return
		}

		// Last check before the install link exists: the app must carry the certificate's signature.
		guard Self._isSignedWithCertificate(signed) else {
			_alert(
				title: .localized("Signing"),
				message: .localized("The app was not signed with the certificate, so it was not sent for installation. Check the certificate in Settings > Certificates and try again.")
			)
			return
		}

		installTarget = AnyApp(base: signed)
	}

	private func _finish(_ id: String) {
		_pending[id] = nil
		phases[id] = nil
	}

	// MARK: Signature check

	/// True when the signed app is linked to a certificate and zsign left its signature in the bundle:
	/// the embedded provisioning profile and the code signature of the main app.
	private static func _isSignedWithCertificate(_ signed: Signed) -> Bool {
		guard
			signed.certificate != nil,
			let appURL = Storage.shared.getAppDirectory(for: signed)
		else {
			return false
		}

		let fileManager = FileManager.default
		let profile = appURL.appendingPathComponent("embedded.mobileprovision")
		let codeResources = appURL
			.appendingPathComponent("_CodeSignature")
			.appendingPathComponent("CodeResources")

		return fileManager.fileExists(atPath: profile.path)
			&& fileManager.fileExists(atPath: codeResources.path)
	}

	// MARK: Database

	private static func _certificate(uuid: String) -> CertificatePair? {
		let request = NSFetchRequest<CertificatePair>(entityName: "CertificatePair")
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1
		return (try? Storage.shared.context.fetch(request))?.first
	}

	private func _latestImported(since date: Date, bundleID: String?) -> Imported? {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		request.predicate = NSPredicate(format: "date >= %@", date.addingTimeInterval(-2) as NSDate)

		guard let results = try? Storage.shared.context.fetch(request) else { return nil }
		let unclaimed = results.filter { app in
			guard let uuid = app.uuid else { return true }
			return !_claimedImports.contains(uuid)
		}

		if let bundleID, let match = unclaimed.first(where: { $0.identifier == bundleID }) {
			return match
		}
		return unclaimed.first
	}

	private func _signed(uuid: String) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1
		return (try? Storage.shared.context.fetch(request))?.first
	}

	// MARK: Alerts

	private func _alert(title: String, message: String) {
		Task { @MainActor in
			UIAlertController.showAlertWithOk(title: title, message: message)
		}
	}
}
