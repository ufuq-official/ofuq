//
//  StoreSearchView.swift
//  Ofuq
//
//  The Search tab: suggestions in pages of three rows and colourful Browse tiles,
//  or the results while typing.
//

import SwiftUI
import CoreData

struct StoreSearchView: View {
	@ObservedObject private var _catalog = StoreCatalog.shared
	@State private var _destination: StoreDestination?
	@State private var _query = ""
	/// Ofuq: the results are found off the main thread, a moment after typing stops (see `_search`).
	@State private var _found: [StoreApp] = []
	/// The query `_found` is for.
	@State private var _foundQuery = ""

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	private var _trimmedQuery: String {
		_query.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var body: some View {
		NavigationStack {
			Group {
				if _trimmedQuery.isEmpty {
					_browse
				} else {
					_results
				}
			}
			.navigationTitle(String.localized("Search"))
			.navigationBarTitleDisplayMode(.large)
			.searchable(text: $_query, prompt: Text(String.localized("Apps, games and developers")))
			// Again when the query changes or the catalog does (a source finished loading).
			.task(id: "\(_trimmedQuery)\u{1}\(_catalog.apps.count)") {
				await _search()
			}
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
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

	// MARK: Browse

	private var _browse: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 28) {
				if _catalog.apps.isEmpty {
					_loading
				} else {
					_suggestions
					_tiles
				}
			}
			.padding(.top, 8)
			.padding(.bottom, 32)
			.frame(maxWidth: 820)
			.frame(maxWidth: .infinity)
		}
		.refreshable {
			await _catalog.refresh(_sources)
		}
	}

	private var _suggestions: some View {
		let items: [StoreApp] = Array(_catalog.suggestions.prefix(15))
		let screenWidth: CGFloat = UIScreen.main.bounds.width
		let pageWidth: CGFloat = min(screenWidth - 64, 380)

		return VStack(alignment: .leading, spacing: 12) {
			StoreSectionHeader(title: .localized("Suggested"), value: .suggested)

			ScrollView(.horizontal, showsIndicators: false) {
				LazyHGrid(
					rows: Array(repeating: GridItem(.fixed(68), spacing: 10), count: 3),
					spacing: 18
				) {
					ForEach(items) { item in
						NavigationLink(value: item) {
							StoreAppRow(item: item, iconSize: 56)
								.frame(width: pageWidth)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 20)
				.compatScrollTargetLayout()
			}
			.compatScrollTargetBehavior()
			.frame(height: 224) // three rows of 68 and two gaps of 10
		}
	}

	private var _tiles: some View {
		VStack(alignment: .leading, spacing: 12) {
			StoreSectionHeader(title: .localized("Browse"))

			LazyVGrid(
				columns: [
					GridItem(.flexible(), spacing: 12),
					GridItem(.flexible(), spacing: 12)
				],
				spacing: 12
			) {
				ForEach(_catalog.browseCollections) { collection in
					NavigationLink(value: collection) {
						StoreCategoryTile(
							collection: collection,
							lead: _catalog.items(for: collection).first
						)
					}
					.buttonStyle(StoreCardButtonStyle())
				}
			}
			.padding(.horizontal, 20)
		}
	}

	@ViewBuilder
	private var _loading: some View {
		if _sources.isEmpty {
			StoreEmptyState(
				symbol: "globe.desk",
				title: .localized("No Sources"),
				message: .localized("Add a source to fill the store with apps.")
			)
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

	// MARK: Results

	private func _search() async {
		let query = _trimmedQuery
		guard !query.isEmpty else {
			_found = []
			_foundQuery = ""
			return
		}
		// Waits while typing: each letter cancels the search of the previous one.
		if _foundQuery != "" {
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		guard !Task.isCancelled else { return }

		let apps = _catalog.apps
		let results = await Task.detached(priority: .userInitiated) {
			StoreCatalog.search(query, in: apps)
		}.value
		guard !Task.isCancelled else { return }
		_found = results
		_foundQuery = query
	}

	private var _results: some View {
		let results = _found
		let isCurrent = _foundQuery == _trimmedQuery

		return List {
			ForEach(results) { item in
				StoreAppRow(item: item)
					.background(
						NavigationLink(value: item) { EmptyView() }
							.opacity(0)
					)
			}
		}
		.listStyle(.plain)
		.overlay {
			if results.isEmpty, !isCurrent {
				ProgressView()
			} else if results.isEmpty {
				StoreEmptyState(
					symbol: "magnifyingglass",
					title: .localized("No Results"),
					message: .localized("Try another name.")
				)
			}
		}
	}
}
