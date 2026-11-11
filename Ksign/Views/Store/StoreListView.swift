//
//  StoreListView.swift
//  Ofuq
//
//  The Apps and Games tabs: a large title, a row of category chips, a filter menu
//  and one row per app.
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

		var symbol: String {
			switch self {
			case .apps:  return "square.stack.3d.up.fill"
			case .games: return "gamecontroller.fill"
			}
		}

		var categories: [StoreCategory] {
			switch self {
			case .apps:  return StoreCategory.appCategories
			case .games: return StoreCategory.gameCategories
			}
		}
	}

	enum Sort: String, CaseIterable, Identifiable {
		case newest
		case downloads
		case name

		var id: String { rawValue }

		var title: String {
			switch self {
			case .newest:    return .localized("Newest")
			case .downloads: return .localized("Most Downloaded")
			case .name:      return .localized("Name")
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

	/// "Most Downloaded" is only offered when the sources give download counts.
	private var _sorts: [Sort] {
		_catalog.hasDownloadCounts ? Sort.allCases : [.newest, .name]
	}

	private var _items: [StoreApp] {
		var items = _baseItems
		if let category = _category {
			// Precomputed with the catalog; a game's categories are only game genres, so this list
			// already belongs to the right tab.
			items = (_catalog.byCategory[category] ?? []).filter { $0.isGame == (kind == .games) }
		}
		if let sourceName = _sourceName {
			items = items.filter { $0.source.name == sourceName }
		}
		let query = StoreApp.fold(_query.trimmingCharacters(in: .whitespacesAndNewlines))
		if !query.isEmpty {
			items = items.filter { $0.matches(folded: query) }
		}
		switch _sort {
		case .newest:
			break
		case .downloads:
			items = items.enumerated()
				.sorted { lhs, rhs in
					let left = lhs.element.downloads ?? -1
					let right = rhs.element.downloads ?? -1
					if left != right {
						return left > right
					}
					return lhs.offset < rhs.offset
				}
				.map { $0.element }
		case .name:
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
				if !_catalog.apps.isEmpty {
					_categoryBar
						.listRowInsets(EdgeInsets())
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
				}

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
						.padding(.top, _catalog.apps.isEmpty ? 0 : 60)
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

	// MARK: Category chips

	private var _categoryBar: some View {
		ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					_chip(
						title: String.localized("All"),
						symbol: kind.symbol,
						isSelected: _category == nil
					) {
						_select(nil)
					}
					.id("all")

					ForEach(kind.categories) { category in
						_chip(
							title: category.title,
							symbol: category.symbol,
							isSelected: _category == category
						) {
							_select(_category == category ? nil : category)
						}
						.id(category.rawValue)
					}
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 8)
			}
			.onChange(of: _category) { category in
				withAnimation(.easeInOut(duration: 0.25)) {
					proxy.scrollTo(category?.rawValue ?? "all", anchor: .center)
				}
			}
		}
	}

	private func _chip(
		title: String,
		symbol: String,
		isSelected: Bool,
		action: @escaping () -> Void
	) -> some View {
		let textStyle: AnyShapeStyle = isSelected
			? AnyShapeStyle(Color.white)
			: AnyShapeStyle(HierarchicalShapeStyle.primary)
		let fillStyle: AnyShapeStyle = isSelected
			? AnyShapeStyle(TintShapeStyle.tint)
			: AnyShapeStyle(Color(uiColor: .tertiarySystemFill))

		return Button(action: action) {
			Label(title, systemImage: symbol)
				.font(.subheadline.weight(.semibold))
				.lineLimit(1)
				.fixedSize()
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
				.foregroundStyle(textStyle)
				.background(fillStyle, in: Capsule())
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
	}

	private func _select(_ category: StoreCategory?) {
		withAnimation(.easeInOut(duration: 0.2)) {
			_category = category
		}
	}

	// MARK: Filter

	private var _filterMenu: some View {
		Menu {
			Picker(String.localized("Category"), selection: $_category) {
				Label(String.localized("All"), systemImage: kind.symbol)
					.tag(StoreCategory?.none)
				ForEach(kind.categories) { category in
					Label(category.title, systemImage: category.symbol)
						.tag(StoreCategory?.some(category))
				}
			}

			Divider()

			Picker(String.localized("Sort"), selection: $_sort) {
				ForEach(_sorts) { sort in
					Text(sort.title).tag(sort)
				}
			}
			.pickerStyle(.menu)

			if _catalog.sourceNames.count > 1 {
				Picker(String.localized("Source"), selection: $_sourceName) {
					Text(String.localized("All")).tag(String?.none)
					ForEach(_catalog.sourceNames, id: \.self) { name in
						Text(name).tag(String?.some(name))
					}
				}
				.pickerStyle(.menu)
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
		} else if let category = _category, _query.isEmpty, _sourceName == nil {
			StoreEmptyState(
				symbol: category.symbol,
				title: .localized("No Apps"),
				message: .localized("There is nothing here yet.")
			)
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
