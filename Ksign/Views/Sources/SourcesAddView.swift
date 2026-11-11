//
//  SourcesAddView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//
//  Ofuq: "Import" used to read the clipboard only, and kept spinning forever when it held no link.
//  It now offers the clipboard (links, KravaSign/MapleSign and ESign codes) or a file: an AltStore /
//  ESign source JSON (kept in the app and added as a source) or a list of links. Every path ends with
//  a result or a clear message.
//

import SwiftUI
import NimbleViews
import AltSourceKit
import UniformTypeIdentifiers

// MARK: - View
struct SourcesAddView: View {
	@Environment(\.dismiss) var dismiss

	typealias RepositoryDataHandler = Result<ASRepository, Error>

	@State private var _isImporting = false
	@State private var _isFilePickerPresenting = false
	@State private var _sourceURL = ""

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Add Source"), displayMode: .inline) {
			Form {
				Section {
					TextField(.localized("Source Repo URL"), text: $_sourceURL)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} footer: {
					Text(.localized("Enter a URL to start validation."))
				}

				Section {
					Button(.localized("Import from Clipboard"), systemImage: "doc.on.clipboard") {
						_importFromClipboard()
					}
					.disabled(_isImporting)

					Button(.localized("Import a JSON File"), systemImage: "doc.badge.plus") {
						_isFilePickerPresenting = true
					}
					.disabled(_isImporting)

					Button(.localized("Export"), systemImage: "square.and.arrow.up") {
						UIPasteboard.general.string = Storage.shared.getSources()
							.compactMap { $0.sourceURL?.absoluteString }
							.filter { !$0.hasPrefix("file:") }
							.joined(separator: "\n")
						UINotificationFeedbackGenerator().notificationOccurred(.success)
						UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("All sources copied to clipboard."))
					}
				} footer: {
					Text(.localized("Import source links, KravaSign/MapleSign and ESign codes, or an AltStore / ESign source file (.json)."))
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)

				if !_isImporting {
					NBToolbarButton(
						.localized("Save"),
						style: .text,
						placement: .confirmationAction,
						isDisabled: _sourceURL.isEmpty
					) {
						FR.handleSource(_sourceURL) {
							dismiss()
						}
					}
				} else {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.json, .plainText, .text],
					allowsMultipleSelection: false,
					onDocumentsPicked: { urls in
						guard let url = urls.first else { return }
						_importFile(url)
					}
				)
				.ignoresSafeArea()
			}
		}
	}
}

// MARK: - Extension: import
extension SourcesAddView {
	private func _importFromClipboard() {
		guard
			let text = UIPasteboard.general.string,
			!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("Import"),
				message: .localized("The clipboard is empty. Copy source links or an ESign code first, then try again.")
			)
			return
		}
		_importLinks(Self._links(in: text))
	}

	/// The picker hands over a copy of the file, so it can be read without any special access.
	private func _importFile(_ url: URL) {
		guard let data = try? Data(contentsOf: url) else {
			UIAlertController.showAlertWithOk(title: .localized("Import"), message: SourceCache.Failure.unreadableFile.localizedDescription)
			return
		}

		let json = try? JSONSerialization.jsonObject(with: data)

		// A source file: kept in the app and added like any other source.
		if let dictionary = json as? [String: Any], dictionary["apps"] != nil {
			_addSourceFile(data)
			return
		}

		// A list of links: ["https://…", …] or {"sources": ["https://…", …]}.
		if let list = json as? [Any] {
			_importLinks(Self._links(in: list.compactMap { $0 as? String }.joined(separator: "\n")))
			return
		}
		if let dictionary = json as? [String: Any], let list = dictionary["sources"] as? [Any] {
			_importLinks(Self._links(in: list.compactMap { $0 as? String }.joined(separator: "\n")))
			return
		}

		// Plain text: links, or an ESign / KravaSign code.
		if json == nil, let text = String(data: data, encoding: .utf8) {
			_importLinks(Self._links(in: text))
			return
		}

		UIAlertController.showAlertWithOk(title: .localized("Import"), message: SourceCache.Failure.invalidSource.localizedDescription)
	}

	private func _addSourceFile(_ data: Data) {
		let repository: ASRepository
		do {
			repository = try JSONDecoder().decode(ASRepository.self, from: data)
		} catch {
			UIAlertController.showAlertWithOk(
				title: .localized("Import"),
				message: SourceCache.Failure.invalidSource.localizedDescription + "\n\n" + error.localizedDescription
			)
			return
		}

		let fileURL = SourceCache.localSourcesDirectory.appendingPathComponent("\(UUID().uuidString).json")
		let id = repository.id ?? fileURL.absoluteString

		guard !Storage.shared.sourceExists(id) else {
			UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
			return
		}

		do {
			try data.write(to: fileURL, options: .atomic)
		} catch {
			UIAlertController.showAlertWithOk(title: .localized("Import"), message: error.localizedDescription)
			return
		}
		SourceCache.store(data, for: fileURL)

		Storage.shared.addSource(fileURL, repository: repository, id: id) { error in
			if let error {
				UIAlertController.showAlertWithOk(title: .localized("Import"), message: error.localizedDescription)
				return
			}
			UINotificationFeedbackGenerator().notificationOccurred(.success)
			dismiss()
		}
	}

	private func _importLinks(_ links: [URL]) {
		guard !links.isEmpty else {
			UIAlertController.showAlertWithOk(
				title: .localized("Import"),
				message: .localized("No source links were found. Copy source links (one per line) or an ESign code, then try again.")
			)
			return
		}

		_isImporting = true

		Task {
			var repositories: [URL: ASRepository] = [:]
			var failed = 0

			await withTaskGroup(of: (URL, ASRepository?).self) { group in
				for link in links {
					group.addTask {
						// Also fills the source cache, so the store does not download them again.
						if case .updated(let repository) = await SourceCache.fetch(url: link, conditional: false) {
							return (link, repository)
						}
						return (link, nil)
					}
				}

				for await (link, repository) in group {
					if let repository {
						repositories[link] = repository
					} else {
						failed += 1
					}
				}
			}

			// Captured by the main-queue block below, which cannot use the variables filled above.
			let loaded = repositories
			let failedCount = failed

			await MainActor.run {
				_isImporting = false

				guard !loaded.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Import"),
						message: .localized("None of these sources could be loaded. Check the links and your connection, then try again.")
					)
					return
				}

				// Sources that are already in the app are not added a second time.
				let newSources = loaded.filter { entry in
					!Storage.shared.sourceExists(entry.value.id ?? entry.key.absoluteString)
				}
				guard !newSources.isEmpty else {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
					return
				}

				Storage.shared.addSources(repos: newSources) { _ in }
				UINotificationFeedbackGenerator().notificationOccurred(.success)
				dismiss()

				if failedCount > 0 {
					// After this sheet is gone: an alert shown on it would close with it.
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
						UIAlertController.showAlertWithOk(
							title: .localized("Import"),
							message: .localized(
								"%@ sources were added. %@ could not be loaded.",
								arguments: String(newSources.count), String(failedCount)
							)
						)
					}
				}
			}
		}
	}

	/// Web links in `text`, decoding KravaSign/MapleSign and ESign codes first. Each one only once.
	private static func _links(in text: String) -> [URL] {
		var seen = Set<String>()
		return ASDeobfuscator(with: text).decode().compactMap { line in
			let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\",")))
			guard
				let url = URL(string: candidate),
				let scheme = url.scheme?.lowercased(),
				scheme == "https" || scheme == "http",
				url.host != nil,
				seen.insert(url.absoluteString).inserted
			else {
				return nil
			}
			return url
		}
	}
}
