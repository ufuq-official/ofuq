//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
    @AppStorage(InstalledApps.settingKey) private var _uniqueBundleIdentifiers: Bool = true
    @State private var _showMethodChangedAlert = false

    private let _installationMethods: [String] = [
        .localized("Server"),
        .localized("idevice")
    ]
    
    // MARK: Body
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
                    ForEach(_installationMethods.indices, id: \.description) { index in
                        Text(_installationMethods[index]).tag(index)
                    }
                }
            } footer: {
                Text("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer.")
            }
            
            Section {
                Toggle(.localized("Never Replace Installed Apps"), systemImage: "plus.square.on.square", isOn: $_uniqueBundleIdentifiers)
            } footer: {
                Text(.localized("Apps installed from the store or shared to Ofuq get a bundle ID that is not on your iPhone yet: the original one, or the original with a number added (1, 2, 3…), so each install is a new copy. Turn this off to update an app that is already installed. Needs a certificate that allows any app ID (*)."))
            }

            if _installationMethod == 0 {
                ServerView()
            } else if _installationMethod == 1 {
                TunnelView()
            }
        }
        .onChange(of: _installationMethod) { newValue in
            guard newValue == 1 else { return }
            _showMethodChangedAlert = true
        }
        .alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
            Button(.localized("Switch Back"), role: .destructive) {
                _installationMethod = 0
            }
            Button(.localized("OK"), role: .cancel) {}
        } message: {
            Text(.localized("idevice warning"))
        }


        .animation(.default, value: _installationMethod)
    }
}

