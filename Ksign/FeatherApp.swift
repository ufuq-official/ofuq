//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import UIKit
import CoreData
import Nuke
import OSLog
import IDeviceSwift

@main
struct FeatherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	let heartbeat = HeartbeatManager.shared
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var accentColorManager = AccentColorManager.shared
    @StateObject var extractManager = ExtractManager.shared
	@StateObject var logsManager = LogsManager.shared
	let storage = Storage.shared

	var body: some Scene {
		WindowGroup {
			VStack {
                ExtractHeaderView(extractManager: extractManager)
                    .transition(.move(edge: .top).combined(with: .opacity))
				DownloadHeaderView(downloadManager: downloadManager)
					.transition(.move(edge: .top).combined(with: .opacity))
				VariedTabbarView()
					.environment(\.managedObjectContext, storage.context)
					.onOpenURL(perform: _handleURL)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
			.animation(.smooth, value: downloadManager.manualDownloads.description)
            .animation(.smooth, value: extractManager.extractItems.description)
			.onReceive(accentColorManager.objectWillChange) { _ in
				accentColorManager.updateGlobalTintColor()
			}
			.onAppear {
				accentColorManager.updateGlobalTintColor()
				if logsManager.isCapturing { logsManager.startCapture() }
					_applyInterfaceStyle()
			}
		}
	}
	
	/// Applies the appearance picked in Settings (dark by default, like the store design) when the app opens.
	/// Before, it was only applied when changed in Settings.
	private func _applyInterfaceStyle() {
		let raw = UserDefaults.standard.integer(forKey: "Feather.userInterfaceStyle")
		guard let style = UIUserInterfaceStyle(rawValue: raw) else { return }
		for scene in UIApplication.shared.connectedScenes {
			guard let windowScene = scene as? UIWindowScene else { continue }
			for window in windowScene.windows {
				window.overrideUserInterfaceStyle = style
			}
		}
	}

	private func _handleURL(_ url: URL) {
		// Ofuq only registers "ofuq://", so it never competes with the original Ksign for "ksign://" links
		// when both apps are installed. A "ksign://" link that still reaches Ofuq is handled the same way.
		if url.scheme == "ofuq" || url.scheme == "ksign" {
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				_ = DownloadManager.shared.startDownload(from: downloadURL, id: "FeatherManualDownload_\(UUID().uuidString)")
				// The app goes to the Library: show it there.
				StoreInstaller.shared.showLibrary()
			}
		} else {
			let fileExtension = url.pathExtension.lowercased()
			if fileExtension == "ipa" || fileExtension == "tipa" {
				// Shared from Files, Telegram, AirDrop, ...: the Library opens and shows the import, the app is
				// signed with the selected certificate, then the install prompt opens — like Install in the store.
				StoreInstaller.shared.installFile(url)
				return
			}
			
            if url.pathExtension == "ksign" {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Ksign certificate file (.ksign) is now unsupported from v1.5.1, please refer to use .p12 and .mobileprovision instead."))
            }
		}
	}

}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        // Ofuq: dark appearance by default; Settings > Appearance still changes it.
        UserDefaults.standard.register(defaults: [
            "Feather.userInterfaceStyle": UIUserInterfaceStyle.dark.rawValue
        ])

        _createPipeline()
        _createSourcesDirectory()
        _removeRetiredBuiltInSources()
        // Ofuq: every launch, not only the first one: a built-in source that could not be added
        // before (slow network, server down) is added now. The ones the user removed stay removed.
        _initializeBuiltInSources()
        // Ofuq: sources added or removed on GitHub (sources/ folder of the repository).
        RemoteSources.sync()

        _clean()
        
        _copyServerCertificates()
        _addDefaultCertificates()

#if SERVER
        // fallback just in case xd
        _downloadSSLCertificates()
#endif
        return true
    }
    
    private func _initializeBuiltInSources() {
        Storage.shared.addBuiltInSources()
    }

    /// Ofuq: built-in sources that went offline (removed from `addBuiltInSources` on 2026-11-11).
    /// Built-in sources are only added on the first launch, so apps installed earlier may still have them:
    /// they are taken out once. Added again by hand later, they stay.
    private func _removeRetiredBuiltInSources() {
        let key = "ofuq.retiredBuiltInSources.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let retired: Set<String> = [
            "https://qnblackcat.github.io/AltStore/apps.json",
            "https://ipa.kenhtao.net/kenhtao.json",
        ]
        for source in Storage.shared.getSources() {
            guard let url = source.sourceURL, retired.contains(url.absoluteString) else { continue }
            Storage.shared.deleteSource(for: source)
            SourceCache.remove(for: url)
        }
        UserDefaults.standard.set(true, forKey: key)
    }
    
    private func _createPipeline() {
        DataLoader.sharedUrlCache.diskCapacity = 0
        
        let pipeline = ImagePipeline {
            let dataLoader: DataLoader = {
                let config = URLSessionConfiguration.default
                config.urlCache = nil
                // A slow icon server gives up after 15 s instead of a minute, so it no longer
                // holds a loading slot while the other icons wait.
                config.timeoutIntervalForRequest = 15
                config.httpMaximumConnectionsPerHost = 8
                return DataLoader(configuration: config)
            }()
            let dataCache = try? DataCache(name: "thewonderofyou.Feather.datacache") // disk cache
            let imageCache = Nuke.ImageCache() // memory cache
            dataCache?.sizeLimit = 500 * 1024 * 1024
            imageCache.costLimit = 100 * 1024 * 1024
            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = dataLoader
            // Icons are shown resized (see IconImages.swift): keep both the original file and the
            // small icon on disk, so the next launch reads the small one straight away.
            $0.dataCachePolicy = .storeAll
            $0.isStoringPreviewsInMemoryCache = false
            // Store lists show many icons at once: load 12 at a time instead of 6.
            $0.dataLoadingQueue.maxConcurrentOperationCount = 12
            $0.imageDecodingQueue.maxConcurrentOperationCount = 2
            $0.imageProcessingQueue.maxConcurrentOperationCount = 3
        }
        
        ImagePipeline.shared = pipeline
    }
    
    private func _createSourcesDirectory() {
        let fileManager = FileManager.default
        
        let appDirectory = URL.documentsDirectory.appendingPathComponent("App")
        try? fileManager.createDirectoryIfNeeded(at: appDirectory)
        
        let directories = ["Signed", "Unsigned", "Archives", "Server", "Tweaks"].map {
            appDirectory.appendingPathComponent($0)
        }
        
        for url in directories {
            try? fileManager.createDirectoryIfNeeded(at: url)
        }
    }
    
    private func _clean() {
        let fileManager = FileManager.default
        let tmpDirectory = fileManager.temporaryDirectory
        
        if let files = try? fileManager.contentsOfDirectory(atPath: tmpDirectory.path()) {
            for file in files {
                try? fileManager.removeItem(atPath: tmpDirectory.appendingPathComponent(file).path())
            }
        }
    }
    
    private func _copyServerCertificates() {
        let fileManager = FileManager.default
        let serverDirectory = URL.documentsDirectory.appendingPathComponent("App/Server")
        
        try? fileManager.createDirectoryIfNeeded(at: serverDirectory)
        
        let filesToCopy = ["server.crt", "server.pem", "commonName.txt"]
        
        for fileName in filesToCopy {
            guard let bundleURL = Bundle.main.url(forResource: fileName.components(separatedBy: ".").first!, withExtension: fileName.components(separatedBy: ".").last!) else {
                print("File \(fileName) not found in app bundle")
                continue
            }

            // A failed build-time download leaves an HTML "404 Not Found" page here; never install that.
            if fileName != "commonName.txt" && !_isPEM(bundleURL) {
                print("Bundled \(fileName) is not a PEM file, skipping")
                continue
            }

            let destinationURL = serverDirectory.appendingPathComponent(fileName)

            // Keep certificates that were already downloaded; only replace missing or broken ones.
            if fileManager.fileExists(atPath: destinationURL.path) {
                if fileName == "commonName.txt" || _isPEM(destinationURL) {
                    continue
                }
                try? fileManager.removeItem(at: destinationURL)
            }

            do {
                try fileManager.copyItem(at: bundleURL, to: destinationURL)
            } catch {
                print("Error copying \(fileName): \(error)")
            }
        }
    }

    private func _isPEM(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("-----BEGIN ")
    }
    
    private func _addDefaultCertificates() {
            guard
                UserDefaults.standard.bool(forKey: "feather.didImportDefaultCertificates") == false,
                let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
            else {
                return
            }
            
            do {
                let folderContents = try FileManager.default.contentsOfDirectory(
                    at: signingAssetsURL,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                )
                
                for folderURL in folderContents {
                    guard folderURL.hasDirectoryPath else { continue }
                    
                    let certName = folderURL.lastPathComponent
                    
                    let p12Url = folderURL.appendingPathComponent("cert.p12")
                    let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
                    let passwordUrl = folderURL.appendingPathComponent("cert.txt")
                    
                    guard
                        FileManager.default.fileExists(atPath: p12Url.path),
                        FileManager.default.fileExists(atPath: provisionUrl.path),
                        FileManager.default.fileExists(atPath: passwordUrl.path)
                    else {
                        Logger.misc.warning("Skipping \(certName): missing required files")
                        continue
                    }
                    
                    let password = try String(contentsOf: passwordUrl, encoding: .utf8)
                    
                    FR.handleCertificateFiles(
                        p12URL: p12Url,
                        provisionURL: provisionUrl,
                        p12Password: password,
                        certificateName: certName,
                    ) { _ in
                        
                    }
                }
                UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
            } catch {
                Logger.misc.error("Failed to list signing-assets: \(error)")
            }
        }

#if SERVER
    private func _downloadSSLCertificates() {
        let serverURL = "https://backloop.dev/pack.json"
        
        FR.downloadSSLCertificates(from: serverURL) { success in
            if success {
                print("SSL certificates downloaded successfully")
            } else {
                print("Failed to download SSL certificates")
            }
        }
    }
#endif
}
