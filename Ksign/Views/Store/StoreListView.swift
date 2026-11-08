//
//  StoreListView.swift
//  Ofuq
//
//  The Apps and Games tabs: a large title, a filter menu and one row per app.
//

import SwiftUI
import CoreData

struct StoreListView: View {
	enum Kind {
		case apps
		case games

		var title: String {
			switch self {
			case .apps:  return .localized("Apps")
			case .games: return .localized("Games")
			}
		}
	}

	enum Sort: String, CaseIterable, Identifiable {
		case newest
		case name

		var id: String { rawValue }

		var title: String {
			switch self {
			case .newest: return .localized("Newest")
			case .name:   return .localized("Name")
			}
		}
	}

	let kind: Kind

	@ObservedObject private var _catalog = StoreCatalog.shared
	@State private var _destination: StoreDestination?
	@State private var _query = ""
	@State private var _category: StoreCategory?
	@State private var _sourceName: String?
	@State private var _sort: Sort = .newest

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	private var _baseItems: [StoreApp] {
		kind == .games ? _catalog.games : _catalog.nonGames
	}

	private var _categories: [StoreCategory] {
		let present = Set(_baseItems.map(\.category))
		return StoreCategory.allCases.filter { present.contains($0) }
	}

	private var _items: [StoreApp] {
		var items = _baseItems
		if let category = _category {
			items = items.filter { $0.category == category }
		}
		if let sourceName = _sourceName {
			items = items.filter { $0.source.name == sourceName }
		}
		if !_query.isEmpty {
			items = items.filter { $0.matches(_query) }
		}
		if _sort == .name {
			items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		}
		return items
	}

	private var _isFiltering: Bool {
		_category != nil || _sourceName != nil || _sort != .newest
	}

	var body: some View {
		NavigationStack {
			List {
				ForEach(_items) { item in
					StoreAppRow(item: item)
						.background(
							NavigationLink(value: item) { EmptyView() }
								.opacity(0)
						)
				}
			}
			.listStyle(.plain)
			.overlay {
				if _items.isEmpty {
					_emptyState
				}
			}
			.navigationTitle(kind.title)
			.navigationBarTitleDisplayMode(.large)
			.searchable(text: $_query, prompt: Text(String.localized("Search")))
			.refreshable {
				await _catalog.refresh(_sources)
			}
			.toolbar {
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					_filterMenu
					StoreAccountButton(destination: $_destination)
				}
			}
			.navigationDestination(for: StoreApp.self) { item in
				StoreAppDetailView(item: item)
			}
			.navigationDestination(for: StoreCollection.self) { collection in
				StoreCollectionView(collection: collection)
			}
		}
		.storeDestinationSheet($_destination)
	}

	// MARK: Filter

	private var _filterMenu: some View {
		Menu {
			Picker(String.localized("Sort"), selection: $_sort) {
				ForEach(Sort.allCases) { sort in
					Text(sort.title).tag(sort)
				}
			}

			if kind == .apps, _categories.count > 1 {
				Picker(String.localized("Category"), selection: $_category) {
					Text(String.localized("All")).tag(StoreCategory?.none)
					ForEach(_categories) { category in
						Label(category.title, systemImage: category.symbol)
							.tag(StoreCategory?.some(category))
					}
				}
			}

			if _catalog.sourceNames.count > 1 {
				Picker(String.localized("Source"), selection: $_sourceName) {
					Text(String.localized("All")).tag(String?.none)
					ForEach(_catalog.sourceNames, id: \.self) { name in
						Text(name).tag(String?.some(name))
					}
				}
			}

			if _isFiltering {
				Divider()
				Button(role: .destructive) {
					_category = nil
					_sourceName = nil
					_sort = .newest
				} label: {
					Label(String.localized("Reset"), systemImage: "arrow.counterclockwise")
				}
			}
		} label: {
			Image(systemName: _isFiltering
				? "line.3.horizontal.decrease.circle.fill"
				: "line.3.horizontal.decrease.circle")
				.font(.system(size: 22))
		}
	}

	// MARK: Empty

	@ViewBuilder
	private var _emptyState: some View {
		if _catalog.apps.isEmpty {
			if _sources.isEmpty {
				StoreEmptyState(
					symbol: "globe.desk",
					title: .localized("No Sources"),
					message: .localized("Add a source to fill the store with apps.")
				)
			} else {
				VStack(spacing: 14) {
					ProgressView()
					Text(String.localized("Loading apps… Pull down to try again."))
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.padding(32)
			}
		} else {
			StoreEmptyState(
				symbol: "magnifyingglass",
				title: .localized("No Results"),
				message: .localized("Try another name or clear the filters.")
			)
		}
	}
}

// MARK: - Collection
/// A plain list of apps with a large title, opened from a Browse tile or a section header.
struct StoreCollectionView: View {
	let collection: StoreCollection

	@ObservedObject private var _catalog = StoreCatalog.shared

	var body: some View {
		let items = _catalog.items(for: collection)

		List {
			ForEach(items) { item in
				StoreAppRow(item: item)
					.background(
						NavigationLink(value: item) { EmptyView() }
							.opacity(0)
					)
			}
		}
		.listStyle(.plain)
		.overlay {
			if items.isEmpty {
				StoreEmptyState(
					symbol: collection.symbol,
					title: .localized("No Apps"),
					message: .localized("There is nothing here yet.")
				)
			}
		}
		.navigationTitle(collection.title)
		.navigationBarTitleDisplayMode(.large)
		.toolbar(.visible, for: .navigationBar)
	}
}
