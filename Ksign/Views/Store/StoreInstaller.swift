//
//  StoreInstaller.swift
//  Ofuq
//
//  One tap install from the store: download the app, sign it with the selected certificate
//  and the saved signing options, then open the install sheet. The same steps as the Library,
//  without having to go through it.
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

		let options = OptionsManager.shared.options
		let certificate = Self.selectedCertificate()
		guard certificate != nil || options.doAdhocSigning || options.onlyModify else {
			_alert(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate")
			)
			return
		}

		// Ad-hoc signing and "only modify" do not use the certificate, so there is nothing to check.
		let usesCertificate = !(options.doAdhocSigning || options.onlyModify)
		let bundleID = app.id
		CertificateCheck.confirm(usesCertificate ? certificate : nil) { [weak self] in
			self?._startDownload(id: id, url: url, bundleID: bundleID)
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

	private func _startDownload(id: String, url: URL, bundleID: String?) {
		// The app may have been started meanwhile (for example a second tap while the alert was shown).
		guard phases[id] == nil, DownloadManager.shared.getDownload(by: id) == nil else { return }

		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		_pending[id] = Pending(bundleID: bundleID, started: Date())
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
		_sign(imported, id: id)
	}

	private func _sign(_ imported: Imported, id: String) {
		let certificate = Self.selectedCertificate()
		let saved = OptionsManager.shared.options
		var options = saved

		// The same adjustments the signing screen makes when it opens.
		if
			saved.ppqProtection,
			let identifier = imported.identifier,
			let certificate,
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

		let signingStarted = Date()
		let finalOptions = options

		FR.signPackageFile(
			imported,
			using: finalOptions,
			icon: nil,
			certificate: certificate
		) { [weak self] error in
			guard let self else { return }
			self._finish(id)

			if let error {
				self._alert(title: .localized("Signing"), message: error.localizedDescription)
				return
			}

			if finalOptions.removeApp {
				Storage.shared.deleteApp(for: imported)
			}

			self._presentInstall(since: signingStarted)
		}
	}

	private func _presentInstall(since date: Date, attempt: Int = 0) {
		if let signed = _latestSigned(since: date) {
			installTarget = AnyApp(base: signed)
		} else if attempt < 5 {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
				self?._presentInstall(since: date, attempt: attempt + 1)
			}
		}
	}

	private func _finish(_ id: String) {
		_pending[id] = nil
		phases[id] = nil
	}

	// MARK: Database

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

	private func _latestSigned(since date: Date) -> Signed? {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
		request.predicate = NSPredicate(format: "date >= %@", date.addingTimeInterval(-2) as NSDate)
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
