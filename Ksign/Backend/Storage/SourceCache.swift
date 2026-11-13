//
//  SourceCache.swift
//  Ofuq
//
//  Keeps the last good JSON of every source on disk, in Application Support (iOS never purges it,
//  unlike the Caches folder), so the store opens instantly and keeps working offline.
//
//  Sources are downloaded with conditional requests: the ETag / Last-Modified of the cached copy are
//  sent along, and a source that did not change answers "304 Not Modified" — nothing is downloaded or
//  decoded again. Some sources are tens of megabytes, so this is what makes refreshing cheap.
//

import Foundation
import CryptoKit
import AltSourceKit

enum SourceCache {
	enum FetchResult {
		/// New content, already written to the cache.
		case updated(ASRepository)
		/// The server says the cached copy is still current.
		case notModified
		case failed(Error)
	}

	enum Failure: LocalizedError {
		case http(Int)
		case invalidSource
		case unreadableFile

		var errorDescription: String? {
			switch self {
			case .http(let code):
				return .localized("The source answered with error %@.", arguments: String(code))
			case .invalidSource:
				return .localized("This is not a valid source. A source is an AltStore / ESign JSON file with a list of apps.")
			case .unreadableFile:
				return .localized("The source file could not be read.")
			}
		}
	}

	private struct Meta: Codable {
		var etag: String?
		var lastModified: String?
		var fetchedAt: Date
	}

	// MARK: Paths

	private static let _directory: URL = {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		var directory = base.appendingPathComponent("OfuqSourceCache", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try? directory.setResourceValues(values)
		return directory
	}()

	/// Source files imported from the device (Sources > + > Import a JSON file).
	static let localSourcesDirectory: URL = {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		let directory = base.appendingPathComponent("OfuqLocalSources", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}()

	private static func _key(for url: URL) -> String {
		Insecure.SHA1.hash(data: Data(url.absoluteString.utf8))
			.map { String(format: "%02x", $0) }
			.joined()
	}

	private static func _dataURL(for url: URL) -> URL {
		_directory.appendingPathComponent(_key(for: url) + ".json")
	}

	private static func _metaURL(for url: URL) -> URL {
		_directory.appendingPathComponent(_key(for: url) + ".meta")
	}

	/// Where the first Ofuq versions kept the cache (Caches folder, named after the source identifier).
	private static func _legacyURL(forKey key: String) -> URL {
		let safe = key.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
		return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("OfuqSourceCache", isDirectory: true)
			.appendingPathComponent(String(safe.prefix(120)) + ".json")
	}

	/// The app's data folder can move between installs, so a local source is found by its file name.
	static func resolveLocalFile(_ url: URL) -> URL {
		if FileManager.default.fileExists(atPath: url.path) {
			return url
		}
		return localSourcesDirectory.appendingPathComponent(url.lastPathComponent)
	}

	// MARK: Read

	/// The cached repository, decoded where it is called: call it off the main thread.
	static func load(url: URL, legacyKey: String?) -> ASRepository? {
		if let data = try? Data(contentsOf: _dataURL(for: url)), let repository = decode(data) {
			return repository
		}
		// Move a copy from the old cache to the durable place.
		if
			let legacyKey,
			let data = try? Data(contentsOf: _legacyURL(forKey: legacyKey)),
			let repository = decode(data)
		{
			try? data.write(to: _dataURL(for: url), options: .atomic)
			try? FileManager.default.removeItem(at: _legacyURL(forKey: legacyKey))
			return repository
		}
		return nil
	}

	/// True when the cached copy was checked with the server less than `maxAge` seconds ago.
	static func isFresh(url: URL, maxAge: TimeInterval) -> Bool {
		guard
			FileManager.default.fileExists(atPath: _dataURL(for: url).path),
			let meta = _meta(for: url)
		else {
			return false
		}
		return Date().timeIntervalSince(meta.fetchedAt) < maxAge
	}

	/// Sources at least this big are decoded one at a time.
	private static let _largeSourceSize = 8 * 1024 * 1024
	private static let _largeSourceLock = NSLock()

	static func decode(_ data: Data) -> ASRepository? {
		// Decoding takes several times the file's size in memory: two or three huge sources (one has 17,000
		// apps, 23 MB) decoded together could make iOS close the app. Small sources never wait.
		guard data.count >= _largeSourceSize else {
			return try? JSONDecoder().decode(ASRepository.self, from: data)
		}
		_largeSourceLock.lock()
		defer { _largeSourceLock.unlock() }
		return try? JSONDecoder().decode(ASRepository.self, from: data)
	}

	// MARK: Write

	static func store(_ data: Data, for url: URL, etag: String? = nil, lastModified: String? = nil) {
		try? data.write(to: _dataURL(for: url), options: .atomic)
		_writeMeta(Meta(etag: etag, lastModified: lastModified, fetchedAt: Date()), for: url)
	}

	static func remove(for url: URL) {
		try? FileManager.default.removeItem(at: _dataURL(for: url))
		try? FileManager.default.removeItem(at: _metaURL(for: url))
	}

	private static func _meta(for url: URL) -> Meta? {
		guard let data = try? Data(contentsOf: _metaURL(for: url)) else { return nil }
		return try? JSONDecoder().decode(Meta.self, from: data)
	}

	private static func _writeMeta(_ meta: Meta, for url: URL) {
		guard let data = try? JSONEncoder().encode(meta) else { return }
		try? data.write(to: _metaURL(for: url), options: .atomic)
	}

	// MARK: Network

	private static let _session: URLSession = {
		let configuration = URLSessionConfiguration.default
		// A slow or dead source gives up instead of holding the others back.
		configuration.timeoutIntervalForRequest = 30
		configuration.timeoutIntervalForResource = 240
		configuration.waitsForConnectivity = false
		// The conditional headers below replace the URL cache, which skips files this large anyway.
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		configuration.httpMaximumConnectionsPerHost = 4
		return URLSession(configuration: configuration)
	}()

	/// Downloads and decodes a source, then caches it. With `conditional`, the cached copy's ETag /
	/// Last-Modified are sent so an unchanged source answers `.notModified` for a few bytes.
	/// Call it off the main thread (decoding a large source takes a moment).
	static func fetch(url: URL, conditional: Bool) async -> FetchResult {
		if url.isFileURL {
			let file = resolveLocalFile(url)
			guard let data = try? Data(contentsOf: file) else { return .failed(Failure.unreadableFile) }
			guard let repository = decode(data) else { return .failed(Failure.invalidSource) }
			store(data, for: url)
			return .updated(repository)
		}

		var request = URLRequest(url: url)
		request.setValue("application/json, */*", forHTTPHeaderField: "Accept")

		let meta = conditional ? _meta(for: url) : nil
		if let meta, FileManager.default.fileExists(atPath: _dataURL(for: url).path) {
			if let etag = meta.etag {
				request.setValue(etag, forHTTPHeaderField: "If-None-Match")
			}
			if let lastModified = meta.lastModified {
				request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
			}
		}

		do {
			let (data, response) = try await _session.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				return .failed(Failure.invalidSource)
			}

			if http.statusCode == 304 {
				_writeMeta(
					Meta(etag: meta?.etag, lastModified: meta?.lastModified, fetchedAt: Date()),
					for: url
				)
				return .notModified
			}

			guard (200...299).contains(http.statusCode) else {
				return .failed(Failure.http(http.statusCode))
			}

			guard let repository = decode(data) else {
				return .failed(Failure.invalidSource)
			}

			store(
				data,
				for: url,
				etag: http.value(forHTTPHeaderField: "ETag"),
				lastModified: http.value(forHTTPHeaderField: "Last-Modified")
			)
			return .updated(repository)
		} catch {
			return .failed(error)
		}
	}
}
