//
//  SegmentedTransfer.swift
//  Ofuq
//
//  Big files are downloaded over several connections at once: each connection asks the server for its own
//  part of the file (an HTTP range request) and writes it at its place in the file. Many hosts limit the
//  speed of each connection, so this is often much faster. Measured on 2026-11-14 on app hosts used by the
//  built-in sources, one connection against four: 0.9 → 2.1 MB/s, 3.0 → 5.8 MB/s, 5.1 → 6.1 MB/s and
//  4.8 → 5.5 MB/s (GitHub).
//
//  - Each part has its own URLSession, so it gets its own connection: inside one session, HTTP/2 would
//    send all the parts over a single connection.
//  - Every part asks the original link, so a host that redirects to a short-lived signed link (GitHub)
//    gives each connection its own.
//  - A part that fails is asked again from where it stopped.
//  - A connection that finishes early takes over half of the part with the most left, so one slow
//    connection does not hold the whole download back.
//  - A server that does not allow parts, a small file, or a part that keeps failing: the download goes
//    the usual way, over one connection (see DownloadManager).
//

import Foundation

final class SegmentedTransfer: NSObject {
	struct Plan {
		let total: Int64
		let suggestedFileName: String?
	}

	enum Failure: Error {
		/// The server sent the whole file, or another part, instead of the part asked for.
		case partsRefused
		/// The server refused a part (404, ...).
		case httpStatus(Int)
		/// A part kept failing, or the file could not be made.
		case incomplete
	}

	/// Files smaller than this are downloaded over one connection.
	static let minimumSize: Int64 = 16 * 1024 * 1024
	/// Connections at the same time.
	private static let _connections = 4
	/// Parts at most, counting the ones made for connections that finished early.
	private static let _maxParts = 12
	/// A part is shared with a free connection only when at least this much is left of it.
	private static let _minimumShare: Int64 = 8 * 1024 * 1024
	/// Tries in a row without receiving anything, for one part.
	private static let _maxRetries = 5

	private final class Part {
		let start: Int64
		/// Last byte of the part (included). Lowered when another connection takes over the rest.
		var end: Int64
		var received: Int64 = 0
		var retries = 0
		/// Last byte asked for by the running request.
		var requestedEnd: Int64 = 0
		/// Status of a refused answer, until its request ends.
		var refusedStatus: Int?
		var isDone = false
		var session: URLSession?

		init(start: Int64, end: Int64) {
			self.start = start
			self.end = end
		}

		var remaining: Int64 { end - start + 1 - received }
		var offset: Int64 { start + received }
	}

	let url: URL
	let plan: Plan

	/// Called on a background queue, a few times a second at most.
	var onProgress: ((_ received: Int64, _ total: Int64) -> Void)?
	/// Called once on a background queue: the downloaded file, or why it failed. Not called after `cancel()`.
	var onFinish: ((Result<URL, Error>) -> Void)?

	private let _userAgent: String?
	private let _file: URL
	private let _queue: OperationQueue = {
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		queue.qualityOfService = .userInitiated
		return queue
	}()

	// Only touched on `_queue`.
	private var _handle: FileHandle?
	private var _parts: [Part] = []
	private var _partByTask: [ObjectIdentifier: Part] = [:]
	private var _isFinished = false
	private var _lastProgress = Date.distantPast

	init(url: URL, plan: Plan, userAgent: String?) {
		self.url = url
		self.plan = plan
		self._userAgent = userAgent
		self._file = FileManager.default.temporaryDirectory
			.appendingPathComponent("OfuqParts_\(UUID().uuidString).download")
		super.init()
	}

	// MARK: Probe

	private static let _probeSession: URLSession = {
		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 15
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		return URLSession(configuration: configuration)
	}()

	/// Asks for the first byte of the file. A server that answers with that byte alone ("206 Partial Content")
	/// and the size of the file allows downloading it in parts. Nil: download it over one connection.
	static func probe(_ url: URL, userAgent: String?) async -> Plan? {
		var request = URLRequest(url: url)
		request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
		request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
		if let userAgent {
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		}

		// Only the headers are read: a server that ignores the range would otherwise send the whole file here.
		let reply: (URLSession.AsyncBytes, URLResponse)
		do {
			reply = try await _probeSession.bytes(for: request)
		} catch {
			return nil
		}
		reply.0.task.cancel()

		guard
			let http = reply.1 as? HTTPURLResponse,
			http.statusCode == 206,
			let range = http.value(forHTTPHeaderField: "Content-Range"),
			_rangeStart(range) == 0,
			let total = _rangeTotal(range),
			total >= minimumSize
		else {
			return nil
		}
		return Plan(total: total, suggestedFileName: http.suggestedFilename)
	}

	/// "bytes 1000-1999/123456" → 1000
	private static func _rangeStart(_ header: String) -> Int64? {
		guard
			let range = header.split(separator: " ").last?.split(separator: "/").first,
			let start = range.split(separator: "-").first
		else {
			return nil
		}
		return Int64(start)
	}

	/// "bytes 1000-1999/123456" → 123456
	private static func _rangeTotal(_ header: String) -> Int64? {
		guard let total = header.split(separator: "/").last else { return nil }
		return Int64(total.trimmingCharacters(in: .whitespaces))
	}

	// MARK: Start / cancel

	func start() {
		_queue.addOperation { [self] in
			guard !_isFinished else { return }
			do {
				guard FileManager.default.createFile(atPath: _file.path, contents: nil) else {
					throw Failure.incomplete
				}
				let handle = try FileHandle(forWritingTo: _file)
				try handle.truncate(atOffset: UInt64(plan.total))
				_handle = handle
			} catch {
				_finish(.failure(error))
				return
			}

			let size = (plan.total + Int64(Self._connections) - 1) / Int64(Self._connections)
			var start: Int64 = 0
			while start < plan.total {
				let end = min(start + size, plan.total) - 1
				let part = Part(start: start, end: end)
				_parts.append(part)
				_launch(part)
				start = end + 1
			}
		}
	}

	/// Stops everything and deletes the partial file. `onFinish` is not called.
	func cancel() {
		_queue.addOperation { [self] in
			guard !_isFinished else { return }
			_isFinished = true
			onFinish = nil
			onProgress = nil
			_cleanUp(keepFile: false)
		}
	}

	// MARK: Parts

	private func _makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = .shared
		configuration.waitsForConnectivity = true
		// No data for a minute: that part fails and is asked again from where it stopped.
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 60 * 60 * 3
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		return URLSession(configuration: configuration, delegate: self, delegateQueue: _queue)
	}

	/// Asks the server for what is left of `part`. On `_queue`.
	private func _launch(_ part: Part) {
		guard _handle != nil, !_isFinished, !part.isDone, part.remaining > 0 else { return }

		var request = URLRequest(url: url)
		request.setValue("bytes=\(part.offset)-\(part.end)", forHTTPHeaderField: "Range")
		request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
		if let _userAgent {
			request.setValue(_userAgent, forHTTPHeaderField: "User-Agent")
		}

		let session = part.session ?? _makeSession()
		part.session = session
		let task = session.dataTask(with: request)
		part.requestedEnd = part.end
		part.refusedStatus = nil
		_partByTask[ObjectIdentifier(task)] = part
		task.resume()
	}

	/// A part is complete. On `_queue`.
	private func _partDone(_ part: Part) {
		part.isDone = true
		// Lets its connection close; the session keeps this object until then.
		part.session?.finishTasksAndInvalidate()
		part.session = nil

		if _parts.allSatisfy({ $0.isDone }) {
			onProgress?(plan.total, plan.total)
			_cleanUp(keepFile: true)
			_finish(.success(_file))
			return
		}
		_shareLargestPart()
	}

	/// A connection is free: it takes over the second half of the part with the most left.
	private func _shareLargestPart() {
		guard
			_parts.count < Self._maxParts,
			let largest = _parts.filter({ !$0.isDone }).max(by: { $0.remaining < $1.remaining }),
			largest.remaining >= Self._minimumShare
		else {
			return
		}

		let half = largest.remaining / 2
		let newStart = largest.end - half + 1
		let newPart = Part(start: newStart, end: largest.end)
		largest.end = newStart - 1
		_parts.append(newPart)
		_launch(newPart)
	}

	/// Asks for `part` again after a short wait, or gives up. On `_queue`.
	private func _retry(_ part: Part, error: Error) {
		part.retries += 1
		guard part.retries <= Self._maxRetries else {
			_finish(.failure(error))
			return
		}

		let delay = min(pow(2.0, Double(part.retries - 1)), 8) // 1, 2, 4, 8, 8 seconds
		DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self else { return }
			self._queue.addOperation {
				self._launch(part)
			}
		}
	}

	// MARK: End

	private func _reportProgress() {
		let now = Date()
		guard now.timeIntervalSince(_lastProgress) >= 0.2 else { return }
		_lastProgress = now
		onProgress?(_parts.reduce(0) { $0 + $1.received }, plan.total)
	}

	private func _cleanUp(keepFile: Bool) {
		try? _handle?.close()
		_handle = nil
		_partByTask.removeAll()
		for part in _parts {
			// A session keeps its delegate (this object) until it is invalidated.
			part.session?.invalidateAndCancel()
			part.session = nil
		}
		if !keepFile {
			try? FileManager.default.removeItem(at: _file)
		}
	}

	private func _finish(_ result: Result<URL, Error>) {
		guard !_isFinished else { return }
		_isFinished = true
		if case .failure = result {
			_cleanUp(keepFile: false)
		}
		let onFinish = self.onFinish
		self.onFinish = nil
		self.onProgress = nil
		onFinish?(result)
	}

	private static func _isRetryable(status: Int) -> Bool {
		// 401/403/410: usually an expired signed link, the original link gives a fresh one.
		[401, 403, 408, 410, 429].contains(status) || status >= 500
	}
}

// MARK: - URLSessionDataDelegate

extension SegmentedTransfer: URLSessionDataDelegate {
	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
	) {
		guard !_isFinished, let part = _partByTask[ObjectIdentifier(dataTask)] else {
			completionHandler(.cancel)
			return
		}

		let http = response as? HTTPURLResponse
		let status = http?.statusCode ?? 0

		if
			status == 206,
			let range = http?.value(forHTTPHeaderField: "Content-Range"),
			Self._rangeStart(range) == part.offset
		{
			completionHandler(.allow)
			return
		}

		completionHandler(.cancel)
		if status == 200 || status == 206 {
			// The whole file, or another part: parts are not possible after all.
			_finish(.failure(Failure.partsRefused))
		} else {
			// Handled when the request ends, in didCompleteWithError.
			part.refusedStatus = status
		}
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		guard
			!_isFinished,
			let part = _partByTask[ObjectIdentifier(dataTask)],
			!part.isDone,
			let handle = _handle
		else {
			return
		}

		// A part that was shared stops at its new end: the rest comes from another connection.
		let usable = Int(min(Int64(data.count), part.remaining))
		guard usable > 0 else { return }

		do {
			try handle.seek(toOffset: UInt64(part.offset))
			try handle.write(contentsOf: usable == data.count ? data : data.prefix(usable))
		} catch {
			// No space left, ...
			_finish(.failure(error))
			return
		}

		part.received += Int64(usable)
		part.retries = 0
		_reportProgress()

		if part.remaining == 0 {
			_partByTask[ObjectIdentifier(dataTask)] = nil
			if part.requestedEnd > part.end {
				dataTask.cancel()
			}
			_partDone(part)
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			!_isFinished,
			let part = _partByTask.removeValue(forKey: ObjectIdentifier(task)),
			!part.isDone
		else {
			return
		}

		if let status = part.refusedStatus {
			part.refusedStatus = nil
			if Self._isRetryable(status: status) {
				_retry(part, error: Failure.httpStatus(status))
			} else {
				_finish(.failure(Failure.httpStatus(status)))
			}
			return
		}

		// Dropped or slow connection, or the answer ended early.
		_retry(part, error: error ?? Failure.incomplete)
	}
}
