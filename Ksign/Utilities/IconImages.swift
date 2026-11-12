//
//  IconImages.swift
//  Ofuq
//
//  App and source icons in the store are often 1024 px files. Decoded at full size, a few dozen of them
//  filled the memory cache, so icons were downloaded and decoded again while scrolling. They are now made
//  as small as they are shown (in three sizes, so the same icon shown in several places is decoded once),
//  kept on disk at that size, and the icons are fetched ahead of time: the first ones of the store and of
//  every source, and while scrolling, the ones of the next rows.
//

import Foundation
import Nuke

extension ImageRequest {
	/// The request for an icon shown `size` points wide.
	static func icon(_ url: URL, size: CGFloat) -> ImageRequest {
		let side: CGFloat
		switch size {
		case ...64:  side = 64
		case ...160: side = 160
		default:     side = 320
		}
		return ImageRequest(
			url: url,
			processors: [ImageProcessors.Resize(size: CGSize(width: side, height: side))]
		)
	}
}

/// Gets icons ready before they are on screen. Everything here runs at low priority, so the icons that are
/// on screen are always loaded first. All functions must be called on the main queue.
enum IconPrefetcher {
	/// Downloads only (no decoding): for icons that may be shown later.
	private static let _disk = ImagePrefetcher(
		pipeline: .shared,
		destination: .diskCache,
		maxConcurrentRequestCount: 4
	)
	/// Downloads, makes small and decodes into memory: for icons about to be shown, which then appear at once.
	/// The small icon is also kept on disk (see the pipeline in FeatherApp.swift), so it stays fast later.
	private static let _ready = ImagePrefetcher(
		pipeline: .shared,
		destination: .memoryCache,
		maxConcurrentRequestCount: 4
	)
	private static var _downloaded = Set<URL>()
	private static var _prepared = Set<URL>()

	/// Icons already asked for are not asked again.
	static func prefetch(_ urls: [URL]) {
		let new = urls.filter { !_prepared.contains($0) && _downloaded.insert($0).inserted }
		guard !new.isEmpty else { return }
		_disk.startPrefetching(with: new)
	}

	/// Icons shown at most 64 points wide (app rows, source rows) about to be on screen.
	static func prepare(_ urls: [URL]) {
		let new = urls.filter { _prepared.insert($0).inserted }
		guard !new.isEmpty else { return }
		_ready.startPrefetching(with: new.map { ImageRequest.icon($0, size: 60) })
	}

	/// For a row that just appeared at `index` of `list`: the next rows' icons are made ready and the
	/// ones after them downloaded, so scrolling down finds them already there.
	static func prefetch<T>(after index: Int, in list: [T], icon: (T) -> URL?) {
		guard index >= 0, index < list.count else { return }
		let next = index + 1
		prepare(list[next..<min(list.count, next + 12)].compactMap(icon))
		let later = next + 12
		if later < list.count {
			prefetch(list[later..<min(list.count, later + 28)].compactMap(icon))
		}
	}
}
