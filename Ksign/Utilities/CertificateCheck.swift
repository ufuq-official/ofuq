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
