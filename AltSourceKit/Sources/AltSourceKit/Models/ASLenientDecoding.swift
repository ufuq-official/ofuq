//
//  ASLenientDecoding.swift
//  AltSourceKit
//
//  Ofuq: one bad entry no longer rejects a whole source. Before, a single app with a date written in an
//  unusual way ("-5:00"), a link with a space (refused by iOS 16) or a news item with a typo made the
//  decoder throw, and every app of that source disappeared. Now that entry is left out (or only the
//  bad field is), and the rest of the source loads.
//

import Foundation

/// An array that keeps the elements that decode and skips the others.
struct ASLossyArray<Element: Decodable>: Decodable {
	var elements: [Element] = []
	/// Why each skipped element could not be decoded.
	var errors: [Error] = []

	init(from decoder: any Decoder) throws {
		var container = try decoder.unkeyedContainer()
		while !container.isAtEnd {
			do {
				elements.append(try container.decode(Element.self))
			} catch {
				errors.append(error)
				// A failed decode does not move to the next element: step over it.
				if (try? container.decode(_Skipped.self)) == nil {
					break
				}
			}
		}
	}

	/// Decodes to nothing, whatever the value is.
	private struct _Skipped: Decodable {
		init(from decoder: any Decoder) throws {}
	}
}

extension KeyedDecodingContainer {
	/// Text, or nil when the key is missing or holds something else (a number, a list…).
	func lenientString(forKey key: Key) -> String? {
		try? decodeIfPresent(String.self, forKey: key)
	}

	/// A link written as text, or nil when the key is missing or the link cannot be used.
	func lenientURL(forKey key: Key) -> URL? {
		lenientString(forKey: key).flatMap(URL.asLenient)
	}

	/// Any decodable value, or nil when it is missing or malformed.
	func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
		try? decodeIfPresent(type, forKey: key)
	}

	/// The elements of a list that decode; nil when the key is missing or is not a list.
	func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
		lenient(ASLossyArray<T>.self, forKey: key)?.elements
	}
}

extension URL {
	/// `URL(string:)`, but surrounding spaces are removed and characters iOS 16 refuses (spaces, Arabic
	/// letters…) are percent-encoded, as iOS 17 does by itself.
	static func asLenient(_ string: String) -> URL? {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if let url = URL(string: trimmed) {
			return url
		}
		let allowed = CharacterSet.urlQueryAllowed
			.union(.urlPathAllowed)
			.union(CharacterSet(charactersIn: "%#"))
		return trimmed.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
	}
}
