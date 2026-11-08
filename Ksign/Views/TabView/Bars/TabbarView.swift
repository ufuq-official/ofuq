//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//
//  Ofuq: the store layout for iOS 16 and 17.
//

import SwiftUI

struct TabbarView: View {
	@State private var _selection: StoreTab = .today

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		TabView(selection: $_selection) {
			ForEach(StoreTab.mainTabs + [.search], id: \.self) { tab in
				tab.view
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
		.modifier(StoreRootModifier(sources: _sources))
	}
}
