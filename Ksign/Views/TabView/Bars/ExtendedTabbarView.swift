//
//  TabbarController.swift
//  feather
//
//  Created by samara on 5/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//
//  Ofuq: the store layout, Today, Apps, Games and Library with Search on its own,
//  which iOS 26 shows as a floating glass tab bar with a separate search button.
//

import SwiftUI

@available(iOS 18, *)
struct ExtendedTabbarView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@State private var _selection: StoreTab = .today

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		TabView(selection: $_selection) {
			ForEach(StoreTab.mainTabs, id: \.self) { tab in
				Tab(tab.title, systemImage: tab.icon, value: tab) {
					tab.view
				}
			}

			Tab(value: StoreTab.search, role: .search) {
				StoreTab.search.view
			}

			TabSection("More") {
				ForEach(StoreTab.moreTabs, id: \.self) { tab in
					Tab(tab.title, systemImage: tab.icon, value: tab) {
						tab.view
					}
				}
			}
			.defaultVisibility(.hidden, for: .tabBar)
			.hidden(horizontalSizeClass == .compact)
		}
		.tabViewStyle(.sidebarAdaptable)
		.modifier(StoreTabBarBehavior())
		.modifier(StoreRootModifier(sources: _sources))
	}
}
