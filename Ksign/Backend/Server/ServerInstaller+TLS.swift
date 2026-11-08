//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	private static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	static func setupApp(port: Int, host: String, tls: TLSConfiguration?) -> Application {
		let app = Application(env)
		app.threadPool = .init(numberOfThreads: 1)

		if let tls {
			app.http.server.configuration.tlsConfiguration = tls
		}

		// When every URL points at 127.0.0.1 there is no reason to expose the signed IPA to the whole Wi-Fi network.
		let bindAddress = host == localhost ? localhost : "0.0.0.0"

		app.http.server.configuration.hostname = host
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname(bindAddress, port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false

		return app
	}

	// MARK: Files/IP
	static let localhost = "127.0.0.1"

	/// Computed for every install (not cached for the whole app session), so a Wi-Fi/cellular change
	/// or a change in Settings takes effect without restarting the app.
	static func resolveHost(for method: Int) -> String {
		if method == semiLocal {
			return getIPFix()
			? localhost
			: (getLocalAddress() ?? localhost)
		} else {
			return readCommonName() ?? localhost
		}
	}

	/// Returns nil when no certificate files exist. Throws when they exist but are unusable
	/// (not PEM, e.g. a saved "404 Not Found" page) or when the certificate is expired / not yet valid.
	static func tls() throws -> TLSConfiguration? {
		guard
			let crt = getUrl("server", ext: "crt"),
			let pem = getUrl("server", ext: "pem")
		else {
			return nil
		}

		let chain = try NIOSSLCertificate.fromPEMFile(crt.path)

		guard let leaf = chain.first else {
			throw NIOSSLError.failedToLoadCertificate
		}

		try validateDates(of: leaf)

		return try TLSConfiguration.makeServerConfiguration(
			certificateChain: chain.map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: pem.path, format: .pem)
			)
		)
	}

	static func validateDates(of certificate: NIOSSLCertificate, now: Date = Date()) throws {
		let notBefore = Date(timeIntervalSince1970: TimeInterval(certificate.notValidBefore))
		let notAfter = Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter))

		if now > notAfter {
			throw ServerInstallerError.certificateExpired(notAfter)
		}

		if now < notBefore {
			throw ServerInstallerError.certificateNotYetValid(notBefore)
		}
	}

	/// Why Fully Local cannot be used right now, or nil when it can.
	static func fullyLocalUnavailableReason() -> String? {
		do {
			guard try tls() != nil else {
				return .localized("No SSL certificate is installed.")
			}
			return nil
		} catch {
			return error.localizedDescription
		}
	}

	static func readCommonName() -> String? {
		guard let url = getUrl("commonName", ext: "txt") else {
			return nil
		}

		guard let name = try? String(contentsOf: url, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines),
			  !name.isEmpty,
			  !name.contains("<") // a saved HTML error page is not a host name
		else {
			return nil
		}

		// The certificate is a wildcard ("*.backloop.dev"); "*" is not a valid DNS label,
		// so use a concrete sub-domain covered by it (every *.backloop.dev resolves to 127.0.0.1).
		if name.hasPrefix("*.") {
			return "local." + name.dropFirst(2)
		}

		return name
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default
		
		let serverURL = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: serverURL.path) {
			return serverURL
		}
		
		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}
		
		let oldServerURL = URL.documentsDirectory.appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: oldServerURL.path) {
			return oldServerURL
		}
		
		return Bundle.main.url(forResource: name, withExtension: ext)
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
									   &hostname, socklen_t(hostname.count),
									   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
