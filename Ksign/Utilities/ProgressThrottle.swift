//
//  ProgressThrottle.swift
//  Ofuq
//
//  Zipping and unzipping report their progress once per file. A game can have tens of thousands of files,
//  and sending each of those to the main queue keeps the screen busy for nothing and slows the work down.
//  This lets through about ten a second, and always the last one.
//

import Foundation

final class ProgressThrottle: @unchecked Sendable {
	private let _interval: TimeInterval
	private let _lock = NSLock()
	private var _last = Date.distantPast

	init(interval: TimeInterval = 0.1) {
		self._interval = interval
	}

	/// True when `progress` should be shown.
	func allows(_ progress: Double) -> Bool {
		let now = Date()
		_lock.lock()
		defer { _lock.unlock() }
		guard progress >= 1 || now.timeIntervalSince(_last) >= _interval else { return false }
		_last = now
		return true
	}
}
