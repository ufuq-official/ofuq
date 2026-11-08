//
//  StoreTodayView.swift
//  Ofuq
//
//  The Today tab: the date, a large title and tall image cards, with a few list cards in between.
//

import SwiftUI
import CoreData

struct StoreTodayView: View {
	@ObservedObject private var _catalog = StoreCatalog.shared
	@State private var _destination: StoreDestination?

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	private static let _dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
		return formatter
	}()

	var body: some View {
		NavigationStack {
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 26) {
					_header
					_content
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 32)
				.frame(maxWidth: 720)
				.frame(maxWidth: .infinity)
			}
			.refreshable {
				await _catalog.refresh(_sources)
			}
			.toolbar(.hidden, for: .navigationBar)
			.navigationDestination(for: StoreApp.self) { item in
				StoreAppDetailView(item: item)
			}
			.navigationDestination(for: StoreCollection.self) { collection in
				StoreCollectionView(collection: collection)
			}
		}
		.storeDestinationSheet($_destination)
	}

	// MARK: Header

	private var _header: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading, spacing: 2) {
				Text(Self._dateFormatter.string(from: Date()))
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
					.textCase(.uppercase)
				Text(String.localized("Today"))
					.font(.largeTitle.weight(.bold))
			}
			Spacer()
			StoreAccountButton(destination: $_destination)
		}
		.padding(.top, 14)
	}

	// MARK: Content

	@ViewBuilder
	private var _content: some View {
		let stories = _catalog.todayStories

		if stories.isEmpty {
			_placeholder
		} else {
			ForEach(Array(stories.enumerated()), id: \.element.id) { index, item in
				NavigationLink(value: item) {
					StoreFeatureCard(item: item)
				}
				.buttonStyle(StoreCardButtonStyle())

				if index == 1 {
					_listCard(
						caption: .localized("Fresh from your sources"),
						title: .localized("Latest Updates"),
						collection: .newest,
						items: Array(_catalog.apps.prefix(4))
					)
				}

				if index == 4, !_catalog.games.isEmpty {
					_listCard(
						caption: .localized("Emulators and games"),
						title: .localized("Games"),
						collection: .category(.games),
						items: Array(_catalog.games.prefix(4))
					)
				}
			}
		}
	}

	private func _listCard(
		caption: String,
		title: String,
		collection: StoreCollection,
		items: [StoreApp]
	) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			NavigationLink(value: collection) {
				HStack(alignment: .center) {
					VStack(alignment: .leading, spacing: 2) {
						Text(caption)
							.font(.caption.weight(.bold))
							.foregroundStyle(.secondary)
							.textCase(.uppercase)
						Text(title)
							.font(.title2.weight(.bold))
							.foregroundStyle(.primary)
					}
					Spacer()
					Image(systemName: "chevron.forward")
						.font(.body.weight(.semibold))
						.foregroundStyle(.secondary)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			ForEach(items) { item in
				NavigationLink(value: item) {
					StoreAppRow(item: item, iconSize: 54)
				}
				.buttonStyle(.plain)

				if item.id != items.last?.id {
					Divider()
						.padding(.leading, 68)
				}
			}
		}
		.padding(18)
		.background(
			Color(uiColor: .secondarySystemBackground),
			in: RoundedRectangle(cornerRadius: 28, style: .continuous)
		)
	}

	@ViewBuilder
	private var _placeholder: some View {
		if _sources.isEmpty {
			VStack(spacing: 16) {
				StoreEmptyState(
					symbol: "globe.desk",
					title: .localized("No Sources"),
					message: .localized("Add a source to fill the store with apps.")
				)
				Button {
					_destination = .sources
				} label: {
					Text(String.localized("Add Source"))
						.font(.headline)
						.padding(.horizontal, 12)
				}
				.buttonStyle(.borderedProminent)
			}
			.frame(maxWidth: .infinity)
			.padding(.top, 60)
		} else {
			VStack(spacing: 14) {
				ProgressView()
				Text(String.localized("Loading apps… Pull down to try again."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
			.frame(maxWidth: .infinity)
			.padding(.top, 90)
		}
	}
}

// MARK: - Card press effect
struct StoreCardButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.97 : 1)
			.animation(.easeOut(duration: 0.2), value: configuration.isPressed)
	}
}

// MARK: - Detail
struct StoreAppDetailView: View {
	let item: StoreApp

	var body: some View {
		SourceAppsDetailView(source: item.source, app: item.app)
			.toolbar(.visible, for: .navigationBar)
			.navigationBarTitleDisplayMode(.inline)
	}
}
