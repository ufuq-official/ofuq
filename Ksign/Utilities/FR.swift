//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(file: ipa, download: download)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
                
                                try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			if !options.onlyModify {
				handler.appCertificate = certificate
			}
			handler.appIcon = icon
			
			do {
				try await handler.copy()
				try await handler.modify()
                try? await handler.clean()
				
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func checkPasswordForCertificateData(
		p12Data: Data,
		provisionData: Data,
		password: String
	) -> Bool {
		let tempDir = FileManager.default.temporaryDirectory
		let tempP12 = tempDir.appendingPathComponent("temp_cert.p12")
		let tempProvision = tempDir.appendingPathComponent("temp_provision.mobileprovision")
		
		defer {
			try? FileManager.default.removeItem(at: tempP12)
			try? FileManager.default.removeItem(at: tempProvision)
		}
		
		do {
			try p12Data.write(to: tempP12)
			try provisionData.write(to: tempProvision)
			
			return checkPasswordForCertificate(for: tempP12, with: password, using: tempProvision)
		} catch {
			print("Error creating temporary files for password check: \(error)")
			return false
		}
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")

		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	#if SERVER
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					let serverDir = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server")
					let pemURL = serverDir.appendingPathComponent("server.pem")
					let crtURL = serverDir.appendingPathComponent("server.crt")
					let commonNameURL = serverDir.appendingPathComponent("commonName.txt")
					
					try FileManager.default.createDirectoryIfNeeded(at: serverDir)
					try pack.key.write(to: pemURL, atomically: true, encoding: .utf8)
					try pack.cert.write(to: crtURL, atomically: true, encoding: .utf8)
					try pack.info.domains.commonName.write(to: commonNameURL, atomically: true, encoding: .utf8)
					
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	#endif
	
	/// Adds the source at `urlString`. `competion` runs on the main queue once it was added.
	///
	/// Ofuq: the downloaded JSON goes straight into the source cache, so the store shows the new source
	/// without downloading it a second time, and the database is only touched on the main queue.
	/// - Parameters:
	///   - silent: no alert on failure (the built-in and GitHub sources are added in the background).
	///   - onDuplicate: called on the main queue instead of the "already added" alert.
	static func handleSource(
		_ urlString: String,
		silent: Bool = false,
		onDuplicate: (() -> Void)? = nil,
		competion: @escaping () -> Void
	) {
		var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		// "example.com/repo.json" typed without the scheme.
		if !trimmed.isEmpty, !trimmed.contains("://") {
			trimmed = "https://" + trimmed
		}
		guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
			if !silent {
				UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("This link is not valid."))
			}
			return
		}

		Task.detached(priority: .userInitiated) {
			let result = await SourceCache.fetch(url: url, conditional: false)

			await MainActor.run {
				switch result {
				case .updated(let repository):
					let id = repository.id ?? url.absoluteString

					if Storage.shared.sourceExists(id) {
						if let onDuplicate {
							onDuplicate()
						} else if !silent {
							UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
						}
					} else {
						Storage.shared.addSource(url, repository: repository, id: id) { _ in
							competion()
						}
					}
				case .notModified:
					// Not asked for (the request is not conditional).
					break
				case .failed(let error):
					if !silent {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					}
				}
			}
		}
	}
}

private enum CertificateHandlerError: Error {
	case invalidCertificate
}
