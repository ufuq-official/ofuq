//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//
//  Ofuq: downloads are retried on slow or dropped connections (resuming where they stopped when the
//  server allows it), "http://" links are upgraded to "https://", and server errors (404, 500, ...)
//  are reported clearly instead of being opened as a broken package.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import SwiftUI // For ByteCountFormatter
import UserNotifications

// Import the error handlers module
@_exported import class UIKit.UIImpactFeedbackGenerator

class Download: Identifiable, @unchecked Sendable, ObservableObject {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0

	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var formattedFileSize: String {
		return totalBytes.formattedByteCount
	}

	var progressText: String {
		if unpackageProgress > 0 {
			return "\(Int(unpackageProgress * 100))%"
		}
		let downloadedStr = bytesDownloaded.formattedByteCount
		let totalStr = totalBytes.formattedByteCount
		return "\(downloadedStr) / \(totalStr) (\(Int(progress * 100))%)"
	}
    var task: URLSessionDownloadTask?
    var resumeData: Data?
	/// How many times this download was retried after a network or server error.
	var retries: Int = 0
	/// Set once the download was started again from its original link after the server refused it (403, ...).
	var restartedFresh = false
	/// Sends a Safari user agent: some hosts refuse (403) downloads that do not look like a browser.
	var usesBrowserUserAgent = false

	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool

    init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false
	) {
		self.id = id
        self.url = url
		self.onlyArchiving = onlyArchiving
        self.fileName = url.lastPathComponent
    }
}

/// Errors the download itself reports (network errors keep their own `URLError` description).
enum DownloadError: LocalizedError {
	case httpStatus(Int)

	var errorDescription: String? {
		switch self {
		case .httpStatus(let code):
			return .localized(
				"The server answered with error %@. The download link may be broken or temporarily unavailable.",
				arguments: String(code)
			)
		}
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	/// Retries after a network or server error, waiting 2, 4 then 8 seconds.
	static let maxRetries = 3

    @Published var downloads: [Download] = []

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

    private var _session: URLSession!

    private func _updateBackgroundAudioState() {
        if #unavailable(iOS 26.0){
            if !downloads.isEmpty {
                BackgroundAudioManager.shared.start()
            } else  {
                BackgroundAudioManager.shared.stop()
            }
        }
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
		// When there is no network at all, wait for it instead of failing straight away.
		configuration.waitsForConnectivity = true
		// No data for a minute counts as a stalled connection; it fails and is then retried.
		configuration.timeoutIntervalForRequest = 60
		// Large games on slow connections can take a long time; this is the limit for the whole download.
		configuration.timeoutIntervalForResource = 60 * 60 * 3
        _session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

	// MARK: HTTPS

	/// App Transport Security blocks plain HTTP downloads, so "http://" links from sources are
	/// upgraded to "https://". Local and IP addresses are left as they are (they are not covered by ATS).
	static func secureURL(_ url: URL) -> URL {
		guard
			url.scheme?.lowercased() == "http",
			let host = url.host?.lowercased(),
			!_isLocalHost(host),
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else {
			return url
		}

		components.scheme = "https"
		if components.port == 80 {
			components.port = nil
		}
		return components.url ?? url
	}

	private static func _isLocalHost(_ host: String) -> Bool {
		if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
			return true
		}
		// IPv6, or an IPv4 address such as 192.168.1.10
		if host.contains(":") {
			return true
		}
		return host.allSatisfy { $0.isNumber || $0 == "." }
	}

	// MARK: Start / stop

    func startDownload(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let url = Self.secureURL(url)

        if let existingDownload = downloads.first(where: { $0.url == url }) {
            resumeDownload(existingDownload)
            return existingDownload
        }
		let download = Download(id: id, url: url)

        let task = _session.downloadTask(with: url)
        download.task = task
        task.resume()

        downloads.append(download)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
        return download
    }

	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		_updateBackgroundAudioState()
		return download
	}

    func resumeDownload(_ download: Download) {
		// Already downloading (for example a second tap on the same app): a new task would download it twice.
		if download.task?.state == .running {
			return
		}
		_restart(download)
		_updateBackgroundAudioState()
    }

	static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

	/// Starts the download again, from where it stopped when the server sent resume data.
	private func _restart(_ download: Download) {
		let task: URLSessionDownloadTask
		if let resumeData = download.resumeData {
			task = _session.downloadTask(withResumeData: resumeData)
		} else {
			var request = URLRequest(url: download.url)
			if download.usesBrowserUserAgent {
				request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
			}
			task = _session.downloadTask(with: request)
		}
		download.resumeData = nil
		download.task = task
		task.resume()
	}

    func cancelDownload(_ download: Download) {
		// Leave the list first, so the "cancelled" error that follows is not taken for a network error.
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads.remove(at: index)
            _updateBackgroundAudioState()
            if #available(iOS 26.0, *) {
                BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
            }
        }
        download.task?.cancel()
    }

	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}

	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}

	// MARK: Retry / failure

	/// Errors worth another try: a slow, dropped or not yet available connection.
	private static func _isRetryable(_ error: NSError) -> Bool {
		guard error.domain == NSURLErrorDomain else { return false }
		switch error.code {
		case NSURLErrorTimedOut,
			 NSURLErrorNetworkConnectionLost,
			 NSURLErrorNotConnectedToInternet,
			 NSURLErrorCannotConnectToHost,
			 NSURLErrorCannotFindHost,
			 NSURLErrorDNSLookupFailed,
			 NSURLErrorSecureConnectionFailed,
			 NSURLErrorCallIsActive,
			 NSURLErrorResourceUnavailable:
			return true
		default:
			return false
		}
	}

	private static func _isRetryable(statusCode: Int) -> Bool {
		statusCode == 408 || statusCode == 429 || statusCode >= 500
	}

	/// Answers that usually mean the temporary link expired, not that the app is gone: GitHub and most CDNs
	/// redirect to a signed link valid for about an hour, and a resumed or retried download goes back to that
	/// expired link and gets 403. Asking the original link again gives a fresh one.
	private static func _needsFreshLink(statusCode: Int) -> Bool {
		statusCode == 401 || statusCode == 403 || statusCode == 410 || statusCode == 416
	}

	/// Retries `download` after a short wait, or reports `error` once the retries are used up.
	/// Must be called on the main queue.
	private func _retryOrFail(_ download: Download, error: Error, retryable: Bool) {
		guard retryable, download.retries < Self.maxRetries else {
			_fail(download, error: error)
			return
		}

		download.retries += 1
		let delay = pow(2.0, Double(download.retries)) // 2, 4, 8 seconds
		print("Download \(download.id) failed (\(error.localizedDescription)), retry \(download.retries) of \(Self.maxRetries) in \(Int(delay)) s")

		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			// Cancelled by the user meanwhile?
			guard let self, self.getDownload(by: download.id) === download else { return }
			self._restart(download)
		}
	}

	/// Removes a download that could not finish and tells the user why. Must be called on the main queue.
	private func _fail(_ download: Download, error: Error) {
		// The store shows its own message for the apps it installs.
		let handledByStore = StoreInstaller.shared.handles(download.id)

		NotificationCenter.default.post(
			name: .ofuqPackageImportFailed,
			object: download.id,
			userInfo: ["error": error]
		)

		if let index = getDownloadIndex(by: download.id) {
			downloads.remove(at: index)
		}
		_updateBackgroundAudioState()
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
		}

		UINotificationFeedbackGenerator().notificationOccurred(.error)
		if !handledByStore {
			UIAlertController.showAlertWithOk(
				title: .localized("Download Failed"),
				message: "\(download.fileName)\n\n\(error.localizedDescription)"
			)
		}
	}
}

extension DownloadManager: URLSessionDownloadDelegate {

	func handlePachageFile(
		url: URL,
		dl: Download?,
		completion: @escaping (Error?) -> Void
	) {
		FR.handlePackageFile(url, download: dl) { err in
			if let error = err {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
				print("Package handling error: \(error.localizedDescription)")
				if let nsError = error as? NSError {
					if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
						print("No space left on device")
					} else if nsError.domain == NSCocoaErrorDomain {
						print("Cocoa error: \(nsError.localizedDescription)")
					}
				}
				let errorString = String(describing: error)
				if errorString.contains("notEnoughDiskSpace") {
					print("Not enough disk space for extraction")
				} else if errorString.contains("payloadNotFound") {
					print("Payload folder not found in archive")
				}
			}
			DispatchQueue.main.async {
				// Ofuq: lets the store sign and install the app as soon as it is imported.
				// Posted before the download leaves the list, see StoreInstaller.
				if let dl = dl {
					var info: [AnyHashable: Any]? = nil
					if let err {
						info = ["error": err]
					}
					NotificationCenter.default.post(
						name: err == nil ? .ofuqPackageImported : .ofuqPackageImportFailed,
						object: dl.id,
						userInfo: info
					)
				}
				if let dl = dl, let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
				}
				if err == nil {
					self._notifyDownloadCompleted(fileName: url.lastPathComponent)
				}
				completion(err)
			}
		}
	}

	func handlePachageFile(url: URL, dl: Download?) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			self.handlePachageFile(url: url, dl: dl) { err in
				if let error = err {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		// A 404 or 500 page is "downloaded" like any file; do not open it as a package.
		if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			let status = http.statusCode
			DispatchQueue.main.async {
				guard self.getDownload(by: download.id) === download else { return }
				download.resumeData = nil

				// Once: start over from the original link (a fresh signed redirect), looking like Safari.
				if Self._needsFreshLink(statusCode: status), !download.restartedFresh {
					download.restartedFresh = true
					download.usesBrowserUserAgent = true
					print("Download \(download.id) refused with \(status), starting again from the original link")
					self._restart(download)
					return
				}

				self._retryOrFail(
					download,
					error: DownloadError.httpStatus(status),
					retryable: Self._isRetryable(statusCode: status)
				)
			}
			return
		}

		var downloadDir: URL
		if !OptionsManager.shared.options.saveAppStoreDownloadsToDownloadsFolder {
			let tempDirectory = FileManager.default.temporaryDirectory
			downloadDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
		} else {
			downloadDir = URL.documentsDirectory.appendingPathComponent("Downloads")
		}

		do {
			try FileManager.default.createDirectoryIfNeeded(at: downloadDir)
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = downloadDir.appendingPathComponent(suggestedFileName)
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			self.handlePachageFile(url: destinationURL, dl: download) { err in
				if let error = err {
					print("Error handling downloaded file: \(error.localizedDescription)")
				}
			}
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
			DispatchQueue.main.async {
				guard self.getDownload(by: download.id) === download else { return }
				self._fail(download, error: error)
			}
		}
	}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let download = getDownloadTask(by: downloadTask) else { return }

        DispatchQueue.main.async {
            download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
            download.bytesDownloaded = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
            if #available(iOS 26.0, *) {
                BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask
		else {
			return
		}

		DispatchQueue.main.async {
			// A download cancelled by the user has already left the list; a retried one has a new task.
			guard let download = self.getDownloadTask(by: downloadTask) else { return }

			let nsError = error as NSError
			// Lets the next try continue from where this one stopped, when the server supports it.
			download.resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
			self._retryOrFail(download, error: error, retryable: Self._isRetryable(nsError))
		}
    }


    private func _notifyDownloadCompleted(fileName: String) {
        guard OptionsManager.shared.options.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = String.localized("Download Completed")
        content.body = fileName
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download.\(fileName)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Failed to schedule notification: \(error.localizedDescription)") }
        }
    }
}
