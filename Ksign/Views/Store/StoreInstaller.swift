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
	/// The signed app waiting for its install sheet, shown over the tabs.
	@Published var installTarget: AnyApp?
	/// The signed app waiting for its install sheet, shown by the Library when one is on screen
	/// (a sheet cannot open from the tabs while the Library sheet covers them).
	@Published var libraryInstallTarget: AnyApp?
	/// Apps being signed for an install; the Library lists them while it waits.
	@Published private(set) var signingApps: [SigningApp] = []

	struct SigningApp: Identifiable, Equatable {
		let id: String
		let name: String
	}

	/// The Library screens on screen (a sheet, or the iPad sidebar), one token each: an appear reported
	/// twice by SwiftUI is not counted twice.
	private var _visibleLibraries = Set<UUID>()
	/// An install waiting for the Library to open, see `_presentInstall`.
	private var _waitingForLibrary: AnyApp?

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

	/// An .ipa opened with Ofuq from Share, Files, Telegram, AirDrop…: the Library opens and shows the
	/// import, the app is signed with the selected certificate, then the install prompt opens — the same
	/// steps as Install in the store. Without a certificate it is only imported, so it can be signed later.
	func installFile(_ url: URL) {
		let id = "OfuqShared_\(UUID().uuidString)"

		guard let certificate = Self.selectedCertificate(), let certificateUUID = certificate.uuid else {
			_importFile(url, id: id, certificateUUID: nil)
			return
		}

		CertificateCheck.confirm(certificate) { [weak self] in
			self?._importFile(url, id: id, certificateUUID: certificateUUID)
		}
	}

	private func _importFile(_ url: URL, id: String, certificateUUID: String?) {
		if let certificateUUID {
			_pending[id] = Pending(bundleID: nil, certificateUUID: certificateUUID, started: Date())
		}
		let download = DownloadManager.shared.startArchive(from: url, id: id)
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		showLibrary()

		// The installer lives as long as the app (`shared`), so it is captured strongly.
		Task.detached(priority: .userInitiated) {
			let local: URL
			do {
				local = try StoreInstaller._readableCopy(of: url)
			} catch {
				await MainActor.run {
					if let index = DownloadManager.shared.getDownloadIndex(by: id) {
						DownloadManager.shared.downloads.remove(at: index)
					}
					self._finish(id)
					self._alert(
						title: .localized("Import"),
						message: .localized("Ofuq could not read this file. Save it to the Files app first, then open it with Ofuq again.")
					)
				}
				return
			}

			await MainActor.run {
				DownloadManager.shared.handlePachageFile(url: local, dl: download) { error in
					StoreInstaller._cleanUp(local, original: url)
					// With a certificate, the import notifications lead to signing (or to an error message).
					guard certificateUUID == nil else { return }
					if let error {
						UIAlertController.showAlertWithOk(title: .localized("Import"), message: error.localizedDescription)
					} else {
						UIAlertController.showAlertWithOk(
							title: .localized("No Certificate"),
							message: .localized("The app was added to your Library. Import a certificate in Settings > Certificates to sign and install it.")
						)
					}
				}
			}
		}
	}

	/// Files iOS copied into Ofuq (Documents/Inbox) are read where they are. Files that live in another app's
	/// storage (iCloud Drive, a file provider) are only readable while access is open, so they are copied first.
	private static func _readableCopy(of url: URL) throws -> URL {
		let container = URL.documentsDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
		if url.resolvingSymlinksInPath().path.hasPrefix(container) {
			return url
		}

		let isAccessing = url.startAccessingSecurityScopedResource()
		defer {
			if isAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}

		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("OfuqShared_\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent(url.lastPathComponent)
		try FileManager.default.copyItem(at: url, to: destination)
		return destination
	}

	/// Removes the temporary copy, and the copy iOS left in Documents/Inbox (the app is in the Library now).
	private static func _cleanUp(_ local: URL, original: URL) {
		let fileManager = FileManager.default
		if local != original {
			try? fileManager.removeItem(at: local.deletingLastPathComponent())
		}
		let inbox = URL.documentsDirectory.appendingPathComponent("Inbox").resolvingSymlinksInPath().path
		if original.resolvingSymlinksInPath().path.hasPrefix(inbox) {
			try? fileManager.removeItem(at: original)
		}
	}

	// MARK: Library

	/// Shows the Library over whatever is on screen, unless a Library is already visible.
	/// Must be called on the main queue.
	func showLibrary(attempt: Int = 0) {
		guard _visibleLibraries.isEmpty else { return }

		guard
			let top = UIApplication.topViewController(),
			top.viewIfLoaded?.window != nil,
			!(top is UIAlertController),
			!top.isBeingPresented,
			!top.isBeingDismissed
		else {
			// Still launching, or an alert is on screen (or leaving it): try again shortly.
			if attempt < 40 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
					self?.showLibrary(attempt: attempt + 1)
				}
			} else if let waiting = _waitingForLibrary {
				// The Library could not open: show the install over the tabs instead.
				_waitingForLibrary = nil
				installTarget = waiting
			}
			return
		}

		let library = LibraryView()
			.environment(\.managedObjectContext, Storage.shared.context)
		let host = UIHostingController(rootView: library)
		host.sheetPresentationController?.prefersGrabberVisible = true
		top.present(host, animated: true)
	}

	func libraryDidAppear(_ token: UUID) {
		_visibleLibraries.insert(token)
		guard let waiting = _waitingForLibrary else { return }
		_waitingForLibrary = nil
		// A sheet can only open from the Library once it has finished appearing.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
			self?.libraryInstallTarget = waiting
		}
	}

	func libraryDidDisappear(_ token: UUID) {
		_visibleLibraries.remove(token)
	}

	/// The Library had another sheet open, so the install sheet could not open: it closed that sheet,
	/// and the install sheet is shown again once it is gone.
	func retryLibraryInstall() {
		guard let target = libraryInstallTarget else { return }
		libraryInstallTarget = nil
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
			self?.libraryInstallTarget = target
		}
	}

	/// True when something (an account menu screen, an alert…) is presented over the tabs, so a sheet from
	/// the tabs cannot open.
	private static func _tabsAreCovered() -> Bool {
		UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.flatMap(\.windows)
			.first(where: \.isKeyWindow)?
			.rootViewController?
			.presentedViewController != nil
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

		var finalOptions = Self.installOptions(for: imported, certificate: certificate)
		// Never replace an app that is on the iPhone: the bundle ID gets the next free number.
		// Not possible with a certificate that allows one app ID only (iOS refuses any other ID).
		if
			InstalledApps.isEnabled,
			CertificateCheck.explicitAppID(for: certificate) == nil,
			let identifier = finalOptions.appIdentifier ?? imported.identifier
		{
			let unique = InstalledApps.uniqueIdentifier(for: identifier)
			if unique != identifier {
				finalOptions.appIdentifier = unique
			}
		}
		signingApps.append(SigningApp(id: id, name: imported.name ?? .localized("Unknown")))

		Self.signForInstall(imported, options: finalOptions, certificate: certificate) { [weak self] result in
			guard let self else { return }
			self._finish(id)
			switch result {
			case .success(let signedUUID):
				if finalOptions.removeApp {
					Storage.shared.deleteApp(for: imported)
				}
				self._presentInstall(signedUUID: signedUUID)
			case .failure(let error):
				self._alert(title: .localized("Signing"), message: error.localizedDescription)
			}
		}
	}

	/// The saved signing options, with what an install needs forced on, and the same adjustments the signing
	/// screen makes when it opens (PPQ protection, saved identifiers and names, prefix/suffix).
	/// With a certificate that allows one app ID only, the app always gets that ID (any other is refused by iOS).
	static func installOptions(for app: AppInfoPresentable, certificate: CertificatePair) -> Options {
		let saved = OptionsManager.shared.options
		var options = saved
		// Always a real signature for an install (see `install(_:)`); these two would skip it.
		options.onlyModify = false
		options.doAdhocSigning = false
		// The provisioning profile must be inside the app: it is what lets iOS install and open an app
		// signed with this certificate. "Remove Provisioning" is on by default in the signing options,
		// and it left installs without it ("the app was not signed with the certificate").
		options.removeProvisioning = false

		if
			saved.ppqProtection,
			let identifier = app.identifier,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(saved.ppqString)"
		}

		if
			let identifier = app.identifier,
			let newIdentifier = options.identifiers[identifier]
		{
			options.appIdentifier = newIdentifier
		}

		if
			let name = app.name,
			let newName = options.displayNames[name]
		{
			options.appName = newName
		}

		if saved.prefix != nil || saved.suffix != nil {
			var name = app.name ?? ""
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

		if let appID = CertificateCheck.explicitAppID(for: certificate) {
			options.appIdentifier = appID
		}

		return options
	}

	/// Same steps as `FR.signPackageFile`, but the handler is kept so the exact signed app (its UUID) is known,
	/// and the signature is checked before anything is reported as signed. `completion` runs on the main queue.
	static func signForInstall(
		_ app: AppInfoPresentable,
		options: Options,
		certificate: CertificatePair,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		let handler = SigningHandler(app: app, options: options)
		handler.appCertificate = certificate
		handler.appIcon = nil
		let signedUUID = handler.uuid

		Task.detached(priority: .userInitiated) {
			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				await MainActor.run {
					completion(.success(signedUUID))
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(.failure(error))
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
		guard Self.isSignedWithCertificate(signed) else {
			_alert(
				title: .localized("Signing"),
				message: .localized("The app was not signed with the certificate, so it was not sent for installation. Check the certificate in Settings > Certificates and try again.")
			)
			return
		}

		let target = AnyApp(base: signed)
		if !_visibleLibraries.isEmpty {
			libraryInstallTarget = target
		} else if Self._tabsAreCovered() {
			// The tabs cannot show a sheet now: the Library opens on top and shows the install.
			_waitingForLibrary = target
			showLibrary()
		} else {
			installTarget = target
		}
	}

	private func _finish(_ id: String) {
		_pending[id] = nil
		phases[id] = nil
		signingApps.removeAll { $0.id == id }
	}

	// MARK: Signature check

	/// True when the signed app is linked to a certificate and zsign left its signature in the bundle:
	/// the embedded provisioning profile and the code signature of the main app.
	/// (Installs always keep the profile, see `installOptions(for:certificate:)`.)
	static func isSignedWithCertificate(_ signed: Signed) -> Bool {
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
