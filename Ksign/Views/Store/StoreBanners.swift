//
//  StoreBanners.swift
//  Ofuq
//
//  The pictures at the top of the Today tab, shown one after the other. They are managed from GitHub:
//  the `banners/` folder of the Ofuq repository, listed by a GitHub Action in `banners/index.json`
//  (see banners/README.md). The last list is kept on the iPhone, so the pictures show at once and
//  offline. It is read again when the Today tab opens (at most every few minutes) and when it is pulled
//  down. Without pictures in the folder, nothing is shown.
//

import SwiftUI
import Nuke
import NukeUI

struct StoreBanner: Hashable, Identifiable {
	let image: URL
	/// Opened when the picture is tapped (banners/links.txt), if any.
	let link: URL?

	var id: URL { image }
}

final class StoreBanners: ObservableObject {
	static let shared = StoreBanners()

	@Published private(set) var items: [StoreBanner] = []

	private struct _Index: Decodable {
		struct Entry: Decodable {
			let image: String?
			let link: String?
		}

		let banners: [Entry]
	}

	private static let _file: URL = FileManager.default
		.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("OfuqBanners.json")

	private static let _prefetcher = ImagePrefetcher(
		pipeline: .shared,
		destination: .diskCache,
		maxConcurrentRequestCount: 2
	)

	/// A list read less than this long ago is not read again when the tab opens.
	private static let _freshness: TimeInterval = 5 * 60

	private var _isRefreshing = false
	private var _lastRefresh: Date?

	private init() {
		if let data = try? Data(contentsOf: Self._file), let items = Self._parse(data) {
			self.items = items
		}
	}

	/// The request for a banner picture: at most 1280 pixels wide, enough for any iPhone, so a very
	/// large upload does not fill the memory.
	static func request(for url: URL) -> ImageRequest {
		ImageRequest(url: url, processors: [ImageProcessors.Resize(width: 1280, unit: .pixels)])
	}

	/// Reads the list on GitHub. A failure (no network) keeps the pictures already shown.
	@MainActor
	func refresh(force: Bool = false) async {
		if !force, let last = _lastRefresh, Date().timeIntervalSince(last) < Self._freshness {
			return
		}
		guard !_isRefreshing, let url = URL(string: Ofuq.bannersIndex) else { return }
		_isRefreshing = true
		defer { _isRefreshing = false }

		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		guard
			let reply = try? await URLSession.shared.data(for: request),
			(reply.1 as? HTTPURLResponse)?.statusCode == 200,
			let items = Self._parse(reply.0)
		else {
			return
		}

		_lastRefresh = Date()
		try? reply.0.write(to: Self._file, options: .atomic)
		Self._prefetcher.startPrefetching(with: items.map { Self.request(for: $0.image) })

		if items != self.items {
			withAnimation(.easeInOut(duration: 0.3)) {
				self.items = items
			}
		}
	}

	private static func _parse(_ data: Data) -> [StoreBanner]? {
		guard let index = try? JSONDecoder().decode(_Index.self, from: data) else { return nil }
		var seen = Set<URL>()
		return index.banners.compactMap { entry in
			guard
				let image = entry.image.flatMap({ URL(string: $0) }),
				let scheme = image.scheme?.lowercased(),
				scheme == "https" || scheme == "http",
				seen.insert(image).inserted
			else {
				return nil
			}
			let link = entry.link.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
			return StoreBanner(image: image, link: link)
		}
	}
}

// MARK: - View

/// The banners, one at a time: they turn by themselves every few seconds and can be swiped.
struct StoreBannerCarousel: View {
	@ObservedObject private var _banners = StoreBanners.shared
	@State private var _selection = 0
	/// After the user swipes, the pictures stop turning by themselves for a moment.
	@State private var _pausedUntil = Date.distantPast
	@State private var _isTurningByItself = false

	private static let _interval: UInt64 = 5_000_000_000

	var body: some View {
		let items = _banners.items

		if !items.isEmpty {
			TabView(selection: $_selection) {
				ForEach(Array(items.enumerated()), id: \.element.id) { index, banner in
					_page(banner)
						.tag(index)
				}
			}
			.tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
			.aspectRatio(16 / 9, contentMode: .fit)
			.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
			.onChange(of: _selection) { _ in
				if _isTurningByItself {
					_isTurningByItself = false
				} else {
					_pausedUntil = Date().addingTimeInterval(8)
				}
			}
			.onChange(of: items.count) { count in
				if _selection >= count {
					_selection = 0
				}
			}
			// Runs only while the Today tab is on screen.
			.task(id: items.count) {
				while !Task.isCancelled {
					try? await Task.sleep(nanoseconds: Self._interval)
					guard !Task.isCancelled else { return }
					_turn(count: items.count)
				}
			}
		}
	}

	@ViewBuilder
	private func _page(_ banner: StoreBanner) -> some View {
		let picture = LazyImage(request: StoreBanners.request(for: banner.image)) { state in
			if let image = state.image {
				image
					.resizable()
					.scaledToFill()
			} else {
				Rectangle()
					.fill(Color(uiColor: .secondarySystemFill))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipped()
		.contentShape(Rectangle())

		if let link = banner.link {
			Button {
				UIApplication.open(link)
			} label: {
				picture
			}
			.buttonStyle(.plain)
		} else {
			picture
		}
	}

	private func _turn(count: Int) {
		guard count > 1, Date() >= _pausedUntil else { return }
		_isTurningByItself = true
		withAnimation(.easeInOut(duration: 0.45)) {
			_selection = (_selection + 1) % count
		}
	}
}
