//
//  SettingsDonationCellView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//  Reworked for Ofuq: the donation card became the Ofuq community card.
//

import SwiftUI
import NimbleViews

struct SettingsCommunityCellView: View {
	var body: some View {
		Section {
			VStack(spacing: 14) {
				_title()

				_benefit(
					.localized("Join the Ofuq Community"),
					.localized("Follow our channels for news, updates and new apps."),
					systemName: "person.2.fill"
				)

				Button() {
					UIApplication.open(Ofuq.telegramChannel)
				} label: {
					_sheetButton(.localized("Join on Telegram"))
				}
				.frame(height: 45)
			}
			.padding(.vertical, 12)
			.buttonStyle(.plain)
		}
	}

	@ViewBuilder
	private func _title() -> some View {
		VStack(alignment: .center, spacing: 8) {
			if let icon = UIImage(named: Bundle.main.iconFileName ?? "") {
				Image(uiImage: icon)
					.appIconStyle(size: 64)
			}

			Text(Bundle.main.name)
				.font(.title)
				.bold()

			Text(verbatim: Ofuq.developer)
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
	}

	@ViewBuilder
	private func _benefit(
		_ title: String,
		_ desc: String,
		systemName: String
	) -> some View {
		HStack(alignment: .center, spacing: 14) {
			Image(systemName: systemName)
				.font(.system(size: 28))
				.foregroundStyle(.tint)
				.frame(width: 39, alignment: .center)

			NBTitleWithSubtitleView(
				title: title,
				subtitle: desc
			)
		}
	}

	@ViewBuilder
	private func _sheetButton(_ title: String) -> some View {
		Text(title)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Color.accentColor)
			// The accent is a light brown in dark mode, so the label switches to black there.
			.foregroundColor(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white }))
			.clipShape(
				RoundedRectangle(cornerRadius: 12, style: .continuous)
			)
			.bold()
	}
}
