//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleJSON
import NimbleViews

struct ServerView: View {
	// Defaults must match ServerInstaller.getServerMethod()/getIPFix(), otherwise the picker
	// shows one method while the installer silently uses another.
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = true
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = ServerInstaller.defaultServerMethod
	@State private var _fullyLocalIssue: String?

	private let _serverMethods: [String] = [
		.localized("Fully Local"),
		.localized("Semi Local")
	]

	private let _dataService = NBFetchService()
	private let _serverPackUrl = "https://backloop.dev/pack.json"

	var body: some View {
		Group {
			Section {
				Picker(.localized("Installation Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.self) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != ServerInstaller.semiLocal)
			} footer: {
				if _serverMethod == ServerInstaller.fullyLocal, let _fullyLocalIssue {
					Text(String.localized("Fully Local cannot be used right now: %@ Apps will be installed with Semi Local instead.", arguments: _fullyLocalIssue))
						.foregroundStyle(.orange)
				}
			}

			Section {
				Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
					FR.downloadSSLCertificates(from: _serverPackUrl) { success in
						DispatchQueue.main.async {
							if !success {
								UIAlertController.showAlertWithOk(
									title: .localized("SSL Certificates"),
									message: .localized("Failed to download, check your internet connection and try again.")
								)
							}
							_refreshFullyLocalStatus()
						}
					}
				}
			}
		}
		.onAppear(perform: _refreshFullyLocalStatus)
		.onChange(of: _serverMethod) { _ in
			_refreshFullyLocalStatus()
		}
	}

	private func _refreshFullyLocalStatus() {
		_fullyLocalIssue = ServerInstaller.fullyLocalUnavailableReason()
	}
}
