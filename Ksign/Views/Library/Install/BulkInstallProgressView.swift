//
//  BulkInstallProgressView.swift
//  Ksign
//
//  Created by Nagata Asami on 27/1/26.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

struct BulkInstallProgressView: View {
    var app: AppInfoPresentable
    @StateObject var viewModel = InstallerStatusViewModel()
    
    @AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
    @StateObject var installer: ServerInstaller
    @State private var _isWebviewPresenting = false
    @State private var progressTask: Task<Void, Never>?
    
    init(app: AppInfoPresentable) {
        self.app = app
        let method = UserDefaults.standard.integer(forKey: "Feather.installationMethod")
        let viewModel = InstallerStatusViewModel(isIdevice: method == 1)
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
    }

    /// The method the installer actually runs with (it may have fallen back from Fully Local).
    private var _serverMethod: Int {
        installer.serverMethod
    }
    
    var body: some View {
        VStack {
            InstallProgressView(app: app, viewModel: viewModel)
        }
        .sheet(isPresented: $_isWebviewPresenting) {
            SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
        }
        .onReceive(viewModel.$status) { newStatus in
            if case .ready = newStatus {
                // Both methods open the install prompt directly; Safari is only a Semi Local fallback.
                installer.openInstallPrompt {
                    _isWebviewPresenting = true
                }
            }
            
            if case .installing = newStatus {
                if progressTask == nil {
                    progressTask = startInstallProgressPolling(
                        bundleID: app.identifier!,
                        viewModel: viewModel
                    )
                }
            }
            
            if case .sendingPayload = newStatus, _serverMethod == 1 {
                _isWebviewPresenting = false
            }
            
            switch newStatus {
            case .completed, .broken(_):
                progressTask?.cancel()
                progressTask = nil
                BackgroundAudioManager.shared.stop()
            default:
                break
            }
        }
        .onAppear(perform: _install)
        .onAppear {
            BackgroundAudioManager.shared.start()
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
            BackgroundAudioManager.shared.stop()
        }
    }
    
    private func _install() {
        Task.detached {
            do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                try await handler.move()
                
                let packageUrl = try await handler.archive(forInstall: true)
                
                if await _installationMethod == 0 {
                    if let startError = await installer.startError {
                        throw startError
                    }

                    await MainActor.run {
                        installer.packageUrl = packageUrl
                        viewModel.status = .ready
                    }
                    
                    if case .installing = await viewModel.status {
                        let task = await startInstallProgressPolling(
                            bundleID: app.identifier!,
                            viewModel: viewModel
                        )

                        await MainActor.run {
                            progressTask = task
                        }
                    }
                } else if await _installationMethod == 1 {
                    let proxy = await InstallationProxy(viewModel: viewModel)
                    try await proxy.install(at: packageUrl, suspend: app.identifier == Bundle.main.bundleIdentifier!)
                }
                
            } catch {
                await MainActor.run {
                    // Show the failure on this row instead of leaving it stuck on "Packaging".
                    viewModel.status = .broken(error)
                    HeartbeatManager.shared.start(true)
                }
            }
        }
    }
    
    private func startInstallProgressPolling(
        bundleID: String,
        viewModel: InstallerStatusViewModel
    ) -> Task<Void, Never> {

        Task.detached(priority: .background) {
            var hasStarted = false

            while !Task.isCancelled {
                let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

                if rawProgress > 0 {
                    hasStarted = true
                }

                let progress = await hasStarted
                    ? _normalizeInstallProgress(rawProgress)
                    : 0.0

                Logger.misc.info("Install progress for \(bundleID): \(progress) - \(rawProgress) - \(viewModel.installProgress)")

                await MainActor.run {
                    viewModel.installProgress = progress
                }

                if hasStarted && rawProgress == 0 {
                    await MainActor.run {
                        viewModel.installProgress = 1.0
                        viewModel.status = .completed(.success(()))
                        print(viewModel.installProgress)
                    }
                    break
                }

                // Poll twice a second; 1 ms kept the CPU busy and flooded the main thread with UI updates.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
        min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
    }
}
