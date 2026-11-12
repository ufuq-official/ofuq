//
//  CertificateCellView.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?
	
	@ObservedObject var cert: CertificatePair
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 6) {
			
			NBTitleWithSubtitleView(
				title: cert.nickname ?? data?.Name ?? .localized("Unknown"),
				subtitle: data?.AppIDName ?? .localized("Unknown")
			)
			
			_certInfoPill(data: cert)
		}
		.frame(height: 80)
		.contentTransition(.opacity)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear {
			withAnimation {
				data = Storage.shared.getProvisionFileDecoded(for: cert)
//                Storage.shared.revokagedCertificate(for: cert)
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
	@ViewBuilder
	private func _certInfoPill(data: CertificatePair) -> some View {
		let pillItems = _buildPills(from: data)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
		}
	}
	
	/// Read from the profile already decoded for this cell (see `CertificateCheck.explicitAppID`).
	private var _allowsOneAppOnly: Bool {
		guard let appID = data?.Entitlements?["application-identifier"]?.value as? String else { return false }
		let identifier = appID.split(separator: ".").dropFirst().joined(separator: ".")
		return !identifier.isEmpty && !identifier.contains("*")
	}

	private func _buildPills(from cert: CertificatePair) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		
		if cert.ppQCheck == true {
			pills.append(NBPillItem(title: "PPQCheck", icon: "checkmark.shield", color: .red))
		}
        
        if cert.revoked {
            pills.append(NBPillItem(title: "Revoked", icon: "xmark.octagon", color: .red))
        }
        else {
            pills.append(NBPillItem(title: "Valid", icon: "checkmark.circle", color: .green))
        }

		// Ofuq: a profile for one app ID only signs one app, so every app signed with it has the same
		// bundle ID and replaces the previous one on the iPhone.
		if _allowsOneAppOnly {
			pills.append(NBPillItem(title: .localized("One App Only"), icon: "1.square", color: .orange))
		}
		
		if let info = cert.expiration?.expirationInfo() {
			pills.append(NBPillItem(
				title: info.formatted,
				icon: info.icon,
				color: info.color
			))
		}
		
		return pills
	}
}
