//
//  IconImages.swift
//  Ofuq
//
//  App and source icons in the store are often 1024 px files. Decoded at full size, a few dozen of them
//  filled the memory cache, so icons were downloaded and decoded again while scrolling. They are now made
//  as small as they are shown (in three sizes, so the same icon shown in several places is decoded once),
//  kept on disk at that size, and the first icons of the store are fetched ahead of time.
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

/// Fetches icons into the disk cache before they are on screen.
enum IconPrefetcher {
	private static let _prefetcher = ImagePrefetcher(
		pipeline: .shared,
		destination: .diskCache,
		maxConcurrentRequestCount: 4
	)
	private static var _requested = Set<URL>()

	/// Must be called on the main queue. Icons already asked for are not asked again.
	static func prefetch(_ urls: [URL]) {
		let new = urls.filter { _requested.insert($0).inserted }
		guard !new.isEmpty else { return }
		_prefetcher.startPrefetching(with: new)
	}
}
