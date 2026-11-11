//
//  StoreTab.swift
//  Ofuq
//
//  The tabs of the store layout: Today, Apps, Sources, Games and Search.
//  The other screens (Library, Downloads, Files, Certificates, Settings) open from the
//  account button, and show in the sidebar on iPad.
//

import SwiftUI
import CoreData

enum StoreTab: String, Hashable, CaseIterable {
	case today
	case apps
	case sources
	case games
	case search

	case library
	case downloads
	case files
	case certificates
	case settings

	/// The tabs of the tab bar, before Search.
	static let mainTabs: [StoreTab] = [.today, .apps, .sources, .games]
	/// The tabs only shown in the iPad sidebar.
	static let moreTabs: [StoreTab] = [.library, .downloads, .files, .certificates, .settings]

	var title: String {
		switch self {
		case .today:        return .localized("Today")
		case .apps:         return .localized("Apps")
		case .games:        return .localized("Games")
		case .library:      return TabEnum.library.title
		case .search:       return .localized("Search")
		case .sources:      return TabEnum.sources.title
		case .downloads:    return TabEnum.downloader.title
		case .files:        return TabEnum.files.title
		case .certificates: return TabEnum.certificates.title
		case .settings:     return TabEnum.settings.title
		}
	}

	var icon: String {
		switch self {
		case .today:        return "doc.text.image"
		case .apps:         return "square.stack.3d.up.fill"
		case .games:        return "gamecontroller.fill"
		case .library:      return "square.grid.2x2.fill"
		case .search:       return "magnifyingglass"
		case .sources:      return "globe"
		case .downloads:    return TabEnum.downloader.icon
		case .files:        return TabEnum.files.icon
		case .certificates: return TabEnum.certificates.icon
		case .settings:     return TabEnum.settings.icon
		}
	}

	@ViewBuilder
	var view: some View {
		switch self {
		case .today:        StoreTodayView()
		case .apps:         StoreListView(kind: .apps)
		case .games:        StoreListView(kind: .games)
		case .library:      LibraryView()
		case .search:       StoreSearchView()
		case .sources:      TabEnum.view(for: .sources)
		case .downloads:    TabEnum.view(for: .downloader)
		case .files:        TabEnum.view(for: .files)
		case .certificates: TabEnum.view(for: .certificates)
		case .settings:     TabEnum.view(for: .settings)
		}
	}
}

// MARK: - Root
/// Loads the sources once for every tab, and shows the install sheet of a one tap install.
struct StoreRootModifier: ViewModifier {
	let sources: FetchedResults<AltSource>

	@ObservedObject private var _installer = StoreInstaller.shared

	func body(content: Content) -> some View {
		content
			.task(id: Array(sources)) {
				await SourcesViewModel.shared.fetchSources(sources)
			}
			.sheet(item: $_installer.installTarget, onDismiss: {
				// Clone: the next copy gets its install sheet.
				_installer.installSheetDidClose()
			}) { app in
				InstallPreviewView(app: app.base, closesWhenInstalled: _installer.hasQueuedInstalls)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
	}
}

/// On iOS 26 the floating tab bar shrinks while scrolling down, like the App Store.
struct StoreTabBarBehavior: ViewModifier {
	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			content.tabBarMinimizeBehavior(.onScrollDown)
		} else {
			content
		}
	}
}
