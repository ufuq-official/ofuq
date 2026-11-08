//
//  StoreComponents.swift
//  Ofuq
//
//  The pieces the store screens are built from.
//

import SwiftUI
import AltSourceKit
import NukeUI

// MARK: - Icon
struct StoreAppIcon: View {
	let url: URL?
	var size: CGFloat = 60

	var body: some View {
		Group {
			if let url {
				LazyImage(url: url) { state in
					if let image = state.image {
						image.appIconStyle(size: size)
					} else {
						_placeholder
					}
				}
			} else {
				_placeholder
			}
		}
		.frame(width: size, height: size)
	}

	private var _placeholder: some View {
		RoundedRectangle(cornerRadius: size * 0.2337, style: .continuous)
			.fill(Color(uiColor: .tertiarySystemFill))
			.frame(width: size, height: size)
	}
}

// MARK: - Screenshot
struct StoreScreenshot: View {
	let url: URL
	var width: CGFloat = 150

	var body: some View {
		Color.black.opacity(0.25)
			.frame(width: width, height: width * 2.05)
			.overlay {
				LazyImage(url: url) { state in
					if let image = state.image {
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
					}
				}
			}
			.clipShape(RoundedRectangle(cornerRadius: width * 0.14, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: width * 0.14, style: .continuous)
					.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
			}
			.shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 12)
	}
}

// MARK: - Install button
struct StoreInstallButton: View {
	enum Style {
		/// Tinted text on a grey capsule, for lists.
		case standard
		/// White text on frosted glass, for the image cards.
		case glass
	}

	let app: ASRepository.App
	var style: Style = .standard

	@ObservedObject private var _downloads = DownloadManager.shared
	@ObservedObject private var _installer = StoreInstaller.shared

	var body: some View {
		let id = app.currentUniqueId
		let download = _downloads.getDownload(by: id)
		let phase = _installer.phases[id]

		Group {
			if let download {
				StoreDownloadRing(download: download, style: style)
					.onTapGesture {
						_downloads.cancelDownload(download)
					}
			} else if phase == .signing {
				Group {
					if style == .glass {
						ProgressView().tint(.white)
					} else {
						ProgressView()
					}
				}
				.frame(width: 30, height: 30)
			} else {
				Button {
					_installer.install(app)
				} label: {
					_label
				}
				.buttonStyle(.borderless)
				.contextMenu {
					Button {
						_installer.install(app)
					} label: {
						Label(String.localized("Install"), systemImage: "arrow.down.app")
					}
					Button {
						_installer.download(app)
					} label: {
						Label(String.localized("Download Only"), systemImage: "arrow.down.circle")
					}
				}
			}
		}
		.animation(.easeInOut(duration: 0.2), value: download != nil)
		.animation(.easeInOut(duration: 0.2), value: phase)
	}

	private var _label: some View {
		Text(String.localized("Install"))
			.font(.subheadline.weight(.bold))
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, 18)
			.padding(.vertical, 6)
			.foregroundStyle(_textStyle)
			.background(_fillStyle, in: Capsule())
			.contentShape(Capsule())
	}

	private var _textStyle: AnyShapeStyle {
		if style == .glass {
			return AnyShapeStyle(Color.white)
		}
		return AnyShapeStyle(TintShapeStyle.tint)
	}

	private var _fillStyle: AnyShapeStyle {
		if style == .glass {
			return AnyShapeStyle(Material.ultraThinMaterial)
		}
		return AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
	}
}

// MARK: - Download ring
struct StoreDownloadRing: View {
	@ObservedObject var download: Download
	var style: StoreInstallButton.Style = .standard

	private var _tint: AnyShapeStyle {
		if style == .glass {
			return AnyShapeStyle(Color.white)
		}
		return AnyShapeStyle(TintShapeStyle.tint)
	}

	var body: some View {
		let progress: Double = min(max(download.overallProgress, 0.03), 1.0)
		let tint: AnyShapeStyle = _tint

		ZStack {
			Circle()
				.stroke(Color.secondary.opacity(0.3), lineWidth: 3)
			Circle()
				.trim(from: 0, to: progress)
				.stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
				.rotationEffect(.degrees(-90))
			Image(systemName: download.unpackageProgress > 0 ? "archivebox.fill" : "stop.fill")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(tint)
		}
		.frame(width: 30, height: 30)
		.contentShape(Circle())
		.animation(.linear(duration: 0.2), value: progress)
	}
}

// MARK: - Row
struct StoreAppRow: View {
	let item: StoreApp
	var iconSize: CGFloat = 60

	var body: some View {
		HStack(spacing: 14) {
			StoreAppIcon(url: item.app.iconURL, size: iconSize)

			VStack(alignment: .leading, spacing: 3) {
				Text(item.name)
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(item.detailLine)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			StoreInstallButton(app: item.app)
		}
		.padding(.vertical, 4)
		.contentShape(Rectangle())
	}
}

// MARK: - Today card
struct StoreFeatureCard: View {
	let item: StoreApp
	var height: CGFloat = 440

	private var _badge: String {
		if item.isFeatured {
			return .localized("Featured")
		}
		if item.isRecent {
			return .localized("New Update")
		}
		return .localized("Available Now")
	}

	var body: some View {
		ZStack(alignment: .bottom) {
			_artwork

			LinearGradient(
				colors: [.clear, .black.opacity(0.45), .black.opacity(0.92)],
				startPoint: .top,
				endPoint: .bottom
			)
			.frame(height: height * 0.62)
			.frame(maxHeight: .infinity, alignment: .bottom)

			_caption
		}
		.frame(maxWidth: .infinity)
		.frame(height: height)
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
		.environment(\.colorScheme, .dark)
	}

	private var _artwork: some View {
		let shots = Array((item.app.allScreenshotURLs ?? []).prefix(2))

		return ZStack {
			LinearGradient(
				colors: [item.tint, item.tint.opacity(0.55), .black],
				startPoint: .topLeading,
				endPoint: .bottomTrailing
			)

			StoreAppIcon(url: item.app.iconURL, size: 280)
				.blur(radius: 60)
				.opacity(0.5)

			if shots.isEmpty {
				StoreAppIcon(url: item.app.iconURL, size: 150)
					.rotationEffect(.degrees(-8))
					.shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 14)
					.offset(y: -height * 0.17)
			} else {
				ZStack {
					if shots.count > 1 {
						StoreScreenshot(url: shots[1])
							.rotationEffect(.degrees(8))
							.offset(x: 62, y: 12)
					}
					StoreScreenshot(url: shots[0])
						.rotationEffect(.degrees(-6))
						.offset(x: shots.count > 1 ? -52 : 0)
				}
				.offset(y: -height * 0.2)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipped()
	}

	private var _caption: some View {
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text(_badge)
					.font(.caption.weight(.bold))
					.foregroundStyle(.white.opacity(0.72))
					.textCase(.uppercase)
				Text(item.headline)
					.font(.title2.weight(.bold))
					.foregroundStyle(.white)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			HStack(spacing: 12) {
				StoreAppIcon(url: item.app.iconURL, size: 46)

				VStack(alignment: .leading, spacing: 2) {
					Text(item.name)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(item.detailLine)
						.font(.caption)
						.foregroundStyle(.white.opacity(0.7))
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				StoreInstallButton(app: item.app, style: .glass)
			}
		}
		.padding(18)
	}
}

// MARK: - Browse tile
struct StoreCategoryTile: View {
	let collection: StoreCollection
	let lead: StoreApp?

	var body: some View {
		LinearGradient(
			colors: collection.colors,
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)
		.frame(height: 116)
		.overlay(alignment: .topLeading) {
			Text(collection.title)
				.font(.headline.weight(.bold))
				.foregroundStyle(.white)
				.lineLimit(2)
				.multilineTextAlignment(.leading)
				.padding(14)
		}
		.overlay(alignment: .bottomTrailing) {
			Group {
				if let lead {
					StoreAppIcon(url: lead.app.iconURL, size: 62)
				} else {
					Image(systemName: collection.symbol)
						.font(.system(size: 40, weight: .bold))
						.foregroundStyle(.white.opacity(0.85))
				}
			}
			.rotationEffect(.degrees(16))
			.shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
			.padding(.trailing, -6)
			.padding(.bottom, -10)
		}
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
		.contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
	}
}

// MARK: - Section header
struct StoreSectionHeader: View {
	let title: String
	/// The list the header opens, when it shows a chevron.
	var value: StoreCollection? = nil

	var body: some View {
		HStack(spacing: 6) {
			if let value {
				NavigationLink(value: value) {
					_title(showsChevron: true)
				}
				.buttonStyle(.plain)
			} else {
				_title(showsChevron: false)
			}
			Spacer()
		}
		.padding(.horizontal, 20)
	}

	private func _title(showsChevron: Bool) -> some View {
		HStack(spacing: 6) {
			Text(title)
				.font(.title2.weight(.bold))
				.foregroundStyle(.primary)
			if showsChevron {
				Image(systemName: "chevron.forward")
					.font(.title3.weight(.semibold))
					.foregroundStyle(.secondary)
			}
		}
	}
}

// MARK: - Empty state
struct StoreEmptyState: View {
	let symbol: String
	let title: String
	let message: String

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: symbol)
				.font(.system(size: 44, weight: .semibold))
				.foregroundStyle(.secondary)
			Text(title)
				.font(.title3.weight(.semibold))
			Text(message)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.padding(32)
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Account menu
/// The screens that used to be tabs, now opened from the account button of the store.
enum StoreDestination: String, Identifiable, CaseIterable {
	case library
	case downloads
	case files
	case certificates
	case settings
	/// Its own tab now; only opened from the "Add Source" button of an empty store.
	case sources

	var id: String { rawValue }

	/// What the account menu lists.
	static let menuItems: [StoreDestination] = [.library, .downloads, .files, .certificates, .settings]

	var tab: TabEnum {
		switch self {
		case .library:      return .library
		case .sources:      return .sources
		case .downloads:    return .downloader
		case .files:        return .files
		case .certificates: return .certificates
		case .settings:     return .settings
		}
	}
}

struct StoreAccountButton: View {
	@Binding var destination: StoreDestination?

	var body: some View {
		Menu {
			ForEach(StoreDestination.menuItems) { item in
				Button {
					destination = item
				} label: {
					Label(item.tab.title, systemImage: item.tab.icon)
				}
			}
		} label: {
			Image(systemName: "person.crop.circle.fill")
				.font(.system(size: 28))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(.tint)
				.accessibilityLabel(Text(String.localized("Account")))
		}
	}
}

extension View {
	/// Presents the screen picked in the account menu.
	func storeDestinationSheet(_ destination: Binding<StoreDestination?>) -> some View {
		sheet(item: destination) { item in
			TabEnum.view(for: item.tab)
				.environment(\.managedObjectContext, Storage.shared.context)
				.presentationDragIndicator(.visible)
		}
	}
}
