//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	private var _scheme: String {
		serverMethod == Self.semiLocal ? "http" : "https"
	}

	private func _endpoint(_ path: String) -> URL {
		var comps = URLComponents()
		comps.scheme = _scheme
		comps.host = host
		comps.path = path
		comps.port = port
		return comps.url!
	}

	var plistEndpoint: URL {
		_endpoint("/\(id).plist")
	}

	var payloadEndpoint: URL {
		_endpoint("/\(id).ipa")
	}

	var pageEndpoint: URL {
		_endpoint("/install")
	}

	// Values used in the manifest; never force-unwrapped (a missing name/version used to crash the app).
	var manifestIdentifier: String { app.identifier ?? "" }
	var manifestName: String { app.name?.isEmpty == false ? app.name! : (app.identifier ?? "App") }
	var manifestVersion: String { app.version?.isEmpty == false ? app.version! : "1.0" }

	/// Unreserved URL characters only (RFC 3986). `.urlQueryAllowed` keeps "&", "=", "+" and "?",
	/// which broke the manifest link for app names such as "Tom & Jerry" or "C++".
	private static let _queryValueAllowed = CharacterSet(
		charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
	)

	private static func _encode(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: _queryValueAllowed) ?? value
	}

	/// The HTTPS manifest Semi Local hands to iOS, generated outside from the app's details.
	var externalManifestURL: String {
		"https://api.palera.in/genPlist"
			+ "?bundleid=\(Self._encode(manifestIdentifier))"
			+ "&name=\(Self._encode(manifestName))"
			+ "&version=\(Self._encode(manifestVersion))"
			+ "&fetchurl=\(Self._encode(payloadEndpoint.absoluteString))"
	}

	var externalServerLink: String {
		// Encode once more because the whole link is itself the value of itms-services' "url" parameter.
		Self._encode(externalManifestURL)
	}

	/// The install link for this installer. iOS only accepts install manifests served over HTTPS:
	/// Fully Local serves its own manifest over HTTPS, while Semi Local's local server is plain HTTP,
	/// so its manifest always comes from the HTTPS generator instead. No path can produce an HTTP manifest link.
	var iTunesLink: String {
		if serverMethod == Self.semiLocal || plistEndpoint.scheme != "https" {
			return iTunesLinkExternal
		}
		return _iTunesLink(with: plistEndpoint.absoluteString)
	}

	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}

	private func _iTunesLink(with url: String) -> String {
		return "itms-services://?action=download-manifest&url=\(url)"
	}

	var displayImageSmallEndpoint: URL {
		_endpoint("/app57x57.png")
	}

	var displayImageLargeEndpoint: URL {
		_endpoint("/app512x512.png")
	}

	var displayImageSmallData: Data {
		_createIcon(57)
	}

	var displayImageLargeData: Data {
		_createIcon(512)
	}

	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.accent.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData()!
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLink)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					// Served by this local server, so the prompt never depends on an outside link.
					"kind": "display-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": manifestIdentifier,
				"bundle-version": manifestVersion,
				"kind": "software",
				"title": manifestName,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
