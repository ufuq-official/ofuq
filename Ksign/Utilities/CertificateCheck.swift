//
//  CertificateCheck.swift
//  Ofuq
//
//  iOS refuses apps signed with a revoked or expired certificate with "This app cannot be installed
//  because its integrity could not be verified", but only after the app was downloaded and signed.
//  This tells the user before any of that happens, using what Ofuq already knows about the certificate:
//  its expiration date, and the "revoked" flag set when the Certificates screen checked it with Apple.
//  No extra network request is made here.
//

import UIKit

enum CertificateCheck {
	enum Problem {
		case expired(Date)
		case revoked
	}

	static func problem(with certificate: CertificatePair) -> Problem? {
		if let expiration = certificate.expiration, expiration < Date() {
			return .expired(expiration)
		}
		if certificate.revoked {
			return .revoked
		}
		return nil
	}

	/// The single app ID the certificate's provisioning profile allows (without the team prefix), or nil when
	/// the profile is a wildcard ("TEAMID.*"). iOS refuses an app whose bundle ID is not covered by its embedded
	/// profile with the same "integrity could not be verified" message as a revoked certificate, so apps signed
	/// with such a profile must use exactly this bundle ID.
	static func explicitAppID(for certificate: CertificatePair) -> String? {
		guard
			let decoded = Storage.shared.getProvisionFileDecoded(for: certificate),
			let entitlements = decoded.Entitlements,
			let appID = entitlements["application-identifier"]?.value as? String
		else {
			return nil
		}
		let identifier = appID.split(separator: ".").dropFirst().joined(separator: ".")
		guard !identifier.isEmpty, !identifier.contains("*") else {
			return nil
		}
		return identifier
	}

	/// False when the certificate's provisioning profile cannot sign an app with this bundle ID:
	/// an explicit profile ("TEAMID.com.example.app") allows only that ID, a partial wildcard
	/// ("TEAMID.com.example.*") only IDs that start with it. True for "TEAMID.*" or an unreadable profile.
	static func allows(_ bundleID: String, for certificate: CertificatePair) -> Bool {
		pattern(appIDPattern(for: certificate), allows: bundleID)
	}

	/// The app ID of the certificate's provisioning profile without the team prefix ("*", "com.example.*",
	/// "com.example.app"), or nil when the profile cannot be read. Reads the profile file: keep the result
	/// instead of asking again for every bundle ID.
	static func appIDPattern(for certificate: CertificatePair) -> String? {
		guard
			let decoded = Storage.shared.getProvisionFileDecoded(for: certificate),
			let entitlements = decoded.Entitlements,
			let appID = entitlements["application-identifier"]?.value as? String
		else {
			return nil
		}
		return appID.split(separator: ".").dropFirst().joined(separator: ".")
	}

	/// See `allows(_:for:)`. A nil or empty pattern (unreadable profile) allows everything.
	static func pattern(_ pattern: String?, allows bundleID: String) -> Bool {
		guard let pattern, !pattern.isEmpty, pattern != "*" else {
			return true
		}
		if pattern.hasSuffix("*") {
			return bundleID.hasPrefix(String(pattern.dropLast()))
		}
		return bundleID == pattern
	}

	/// Runs `proceed` right away when the certificate looks fine (or when no certificate is used).
	/// Otherwise explains the problem and runs `proceed` only if the user taps "Continue Anyway".
	/// Must be called on the main queue.
	static func confirm(_ certificate: CertificatePair?, proceed: @escaping () -> Void) {
		guard let certificate, let problem = problem(with: certificate) else {
			proceed()
			return
		}

		let message: String
		switch problem {
		case .expired(let date):
			message = .localized(
				"This certificate expired on %@. iOS will refuse apps signed with it. Import a valid certificate in Settings > Certificates.",
				arguments: date.formatted(date: .abbreviated, time: .omitted)
			)
		case .revoked:
			message = .localized("Apple has revoked this certificate. iOS will refuse apps signed with it and show \"integrity could not be verified\". Import a valid certificate in Settings > Certificates.")
		}

		UIAlertController.showAlert(
			title: .localized("Certificate Problem"),
			message: message,
			actions: [
				UIAlertAction(title: .localized("Cancel"), style: .cancel),
				UIAlertAction(title: .localized("Continue Anyway"), style: .default) { _ in
					proceed()
				}
			]
		)
	}
}
