//
//  CloneAppView.swift
//  Ofuq
//
//  Clone: several copies of one app side by side on the iPhone, like zSign. Each copy gets its own
//  bundle ID (iOS keeps apps apart by it, so each copy has its own data) and its own name, is signed
//  with the selected certificate, then installed one after another (iOS shows one install prompt at a time).
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - View
struct CloneAppView: View {
	@Environment(\.dismiss) private var dismiss

	let app: AppInfoPresentable

	static let maxCopies = 10

	@State private var _count = 2
	@State private var _baseName = ""
	@State private var _baseIdentifier = ""
	@State private var _installAfterSigning = true
	@State private var _isWorking = false
	@State private var _signedCount = 0
	@State private var _didPrepare = false
	// Read once when the screen opens (the profile is a file): the certificate cannot change meanwhile.
	@State private var _hasCertificate = false
	@State private var _explicitAppID: String?
	@State private var _profilePattern: String?

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Clone"), displayMode: .inline) {
			Form {
				Section {
					HStack(spacing: 12) {
						FRAppIconView(app: app, size: 50)
						VStack(alignment: .leading, spacing: 2) {
							Text(verbatim: app.name ?? String.localized("Unknown"))
								.font(.headline)
							Text(verbatim: app.identifier ?? "")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				} footer: {
					Text(.localized("Each copy is a separate app on your iPhone, with its own name, icon on the Home Screen and data."))
				}

				Section {
					Stepper(value: $_count, in: 1...Self.maxCopies) {
						HStack {
							Text(.localized("Number of Copies"))
							Spacer()
							Text("\(_count)")
								.font(.body.monospacedDigit().weight(.semibold))
								.foregroundStyle(.secondary)
						}
					}
				}
				.disabled(_isWorking)

				Section {
					TextField(.localized("Name"), text: $_baseName)
						.autocorrectionDisabled()
				} header: {
					Text(.localized("Name"))
				} footer: {
					Text(.localized("A number is added after the name of each copy."))
				}
				.disabled(_isWorking)

				Section {
					TextField(.localized("Bundle ID"), text: $_baseIdentifier)
						.keyboardType(.asciiCapable)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} header: {
					Text(.localized("Bundle ID"))
				} footer: {
					Text(.localized("Each copy needs its own bundle ID, so a number is added at the end. Only letters, numbers, dots and hyphens are kept."))
				}
				.disabled(_isWorking)

				Section {
					ForEach(_copies, id: \.identifier) { copy in
						VStack(alignment: .leading, spacing: 2) {
							Text(verbatim: copy.name)
							Text(verbatim: copy.identifier)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				} header: {
					Text(.localized("Copies"))
				}

				Section {
					Toggle(.localized("Install After Signing"), isOn: $_installAfterSigning)
				} footer: {
					Text(.localized("The copies are signed with the certificate selected in Settings, then installed one after another. Signed copies also appear in Library > Signed Apps."))
				}
				.disabled(_isWorking)

				if let problem = _problem {
					Section {
						Label(problem, systemImage: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
					}
				}

				if _isWorking {
					Section {
						VStack(alignment: .leading, spacing: 8) {
							Text(verbatim: String.localized(
								"Signing copy %@ of %@…",
								arguments: String(min(_signedCount + 1, _count)), String(_count)
							))
							ProgressView(value: Double(_signedCount), total: Double(max(_count, 1)))
						}
					}
				}
			}
			.toolbar {
				if !_isWorking {
					NBToolbarButton(role: .cancel)

					NBToolbarButton(
						.localized("Clone"),
						style: .text,
						placement: .confirmationAction,
						isDisabled: _problem != nil
					) {
						_start()
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
		}
		.interactiveDismissDisabled(_isWorking)
		.onAppear {
			guard !_didPrepare else { return }
			_didPrepare = true
			_baseName = app.name ?? ""
			_baseIdentifier = (app.identifier ?? "app") + ".clone"

			if let certificate = StoreInstaller.selectedCertificate() {
				_hasCertificate = true
				_explicitAppID = CertificateCheck.explicitAppID(for: certificate)
				_profilePattern = CertificateCheck.appIDPattern(for: certificate)
			}
		}
	}

	// MARK: Copies

	private var _copies: [StoreInstaller.CloneCopy] {
		let typedName = _baseName.trimmingCharacters(in: .whitespacesAndNewlines)
		let name = typedName.isEmpty ? (app.name ?? .localized("Unknown")) : typedName
		let identifier = Self.cleanIdentifier(_baseIdentifier)

		return (1..._count).map { number in
			StoreInstaller.CloneCopy(name: "\(name) \(number)", identifier: "\(identifier)\(number)")
		}
	}

	/// Keeps what a bundle ID may contain (letters, numbers, dots, hyphens), without empty parts.
	static func cleanIdentifier(_ text: String) -> String {
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
		let kept = String(text.filter { allowed.contains($0) })
		let parts = kept.split(separator: ".", omittingEmptySubsequences: true)
		var cleaned = parts.joined(separator: ".")
		// "com.app." keeps its trailing dot, so the copies become "com.app.1", "com.app.2", ...
		if kept.hasSuffix("."), !cleaned.isEmpty {
			cleaned += "."
		}
		return cleaned
	}

	/// Why cloning cannot start, or nil.
	private var _problem: String? {
		guard _didPrepare else { return nil }
		guard _hasCertificate else {
			return .localized("No certificate is selected. Import a certificate in Settings > Certificates to sign the copies.")
		}
		if let appID = _explicitAppID {
			return .localized("This certificate only allows one app (%@), so it cannot sign copies with other bundle IDs. Use a certificate with a wildcard (*) profile.", arguments: appID)
		}
		guard !Self.cleanIdentifier(_baseIdentifier).isEmpty else {
			return .localized("Enter a bundle ID.")
		}
		let pattern = _profilePattern
		if let blocked = _copies.first(where: { !CertificateCheck.pattern(pattern, allows: $0.identifier) }) {
			return .localized("This certificate does not allow the bundle ID %@. Change the bundle ID.", arguments: blocked.identifier)
		}
		return nil
	}

	// MARK: Signing

	private func _start() {
		guard _problem == nil, let certificate = StoreInstaller.selectedCertificate() else { return }
		let copies = _copies
		let install = _installAfterSigning

		CertificateCheck.confirm(certificate) {
			UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
			_signedCount = 0
			_isWorking = true

			Task { @MainActor in
				let result = await StoreInstaller.signClones(
					of: app,
					copies: copies,
					certificate: certificate
				) { done in
					_signedCount = done
				}
				_isWorking = false
				_finish(result, install: install)
			}
		}
	}

	private func _finish(_ result: StoreInstaller.CloneResult, install: Bool) {
		let total = result.signed.count + result.failures.count
		UINotificationFeedbackGenerator().notificationOccurred(result.failures.isEmpty ? .success : .warning)

		let failureList = result.failures
			.map { "• \($0.copy.name): \($0.reason)" }
			.joined(separator: "\n")

		let message: String?
		if result.signed.isEmpty {
			message = .localized("None of the copies could be signed.\n\n%@", arguments: failureList)
		} else if !result.failures.isEmpty {
			message = .localized(
				"%@ of %@ copies were signed. These could not be signed:\n\n%@",
				arguments: String(result.signed.count), String(total), failureList
			)
		} else if !install {
			message = .localized("%@ copies were signed. You can find them in Library > Signed Apps.", arguments: String(result.signed.count))
		} else {
			message = nil
		}

		let signed = result.signed
		dismiss()

		// The install sheet opens from the main screen, so this sheet has to be gone first.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
			let queue = {
				if install {
					StoreInstaller.shared.queueInstalls(signed)
				}
			}
			if let message {
				UIAlertController.showAlertWithOk(title: .localized("Clone"), message: message, action: queue)
			} else {
				queue()
			}
		}
	}
}

// MARK: - Clone signing
extension StoreInstaller {
	struct CloneCopy: Hashable {
		let name: String
		let identifier: String
	}

	struct CloneResult {
		/// Signed apps (UUIDs) that carry the certificate's signature, in the order of the copies.
		var signed: [String] = []
		var failures: [(copy: CloneCopy, reason: String)] = []
	}

	/// Signs the app once per copy, one after another, with the same options as an install from the store
	/// plus the copy's name and bundle ID. Copies that do not carry the certificate's signature afterwards
	/// are removed again and reported as failed. `progress` gets the number of copies done so far.
	@MainActor
	static func signClones(
		of app: AppInfoPresentable,
		copies: [CloneCopy],
		certificate: CertificatePair,
		progress: @escaping (Int) -> Void
	) async -> CloneResult {
		var result = CloneResult()

		for (index, copy) in copies.enumerated() {
			var options = installOptions(for: app, certificate: certificate)
			options.appIdentifier = copy.identifier
			options.appName = copy.name
			// The original is signed again for every copy, so it must stay in the Library.
			options.removeApp = false

			let outcome: Result<String, Error> = await withCheckedContinuation { continuation in
				signForInstall(app, options: options, certificate: certificate) { outcome in
					continuation.resume(returning: outcome)
				}
			}

			switch outcome {
			case .success(let uuid):
				if let signed = await _signedApp(uuid: uuid) {
					if isSignedWithCertificate(signed) {
						result.signed.append(uuid)
					} else {
						Storage.shared.deleteApp(for: signed)
						result.failures.append((copy: copy, reason: String.localized("It was not signed with the certificate.")))
					}
				} else {
					result.failures.append((copy: copy, reason: String.localized("The signed copy was not found.")))
				}
			case .failure(let error):
				result.failures.append((copy: copy, reason: error.localizedDescription))
			}

			progress(index + 1)
		}

		return result
	}

	/// The signed app, waiting briefly for the database to show it.
	@MainActor
	private static func _signedApp(uuid: String) async -> Signed? {
		for attempt in 0..<6 {
			let request = NSFetchRequest<Signed>(entityName: "Signed")
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			if let signed = (try? Storage.shared.context.fetch(request))?.first {
				return signed
			}
			if attempt < 5 {
				try? await Task.sleep(nanoseconds: 300_000_000)
			}
		}
		return nil
	}
}
