//
//  AboutNyaView.swift
//  Ksign
//
//  Created by Nagata Asami on 23/5/25.
//  Reworked for Ofuq (Abbas Mousawi); the credits to Ksign and Feather are kept as required by GPL-3.0.
//

import SwiftUI
import NimbleViews
import NimbleJSON

// MARK: - View
struct AboutNyaView: View {
	private let _dataService = NBFetchService()

	@State private var shouldShowPatchNotes = false

	private var _patchNotesKey: String { "Ofuq.patchNotesShown.\(Bundle.main.version)" }

	// MARK: Body
	var body: some View {
		NBList(.localized("About")) {
            Section {
                VStack {
                    if let icon = UIImage(named: Bundle.main.iconFileName ?? "") {
                        Image(uiImage: icon)
                            .appIconStyle(size: 72)
                    }

                    Text(Bundle.main.name)
                        .font(.largeTitle)
                        .bold()
                        .foregroundStyle(.accent)

                    HStack(spacing: 4) {
                        Text("Version")
                        Text(Bundle.main.version)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button {
                        _showPatchNotes()
                    } label: {
                        Text("Show patch notes").bg()
                    }
                    .font(.footnote)
                    .padding(.top, 4)
                    .tint(.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(EmptyView())

			NBSection(.localized("Developer")) {
				_link(
					title: Ofuq.developer,
					subtitle: .localized("Developer of Ofuq"),
					systemImage: "person.crop.circle.fill",
					url: Ofuq.instagram
				)
			}

			NBSection(.localized("Community")) {
				_link(
					title: .localized("Telegram Channel"),
					subtitle: "@ofuq_store",
					systemImage: "paperplane.fill",
					url: Ofuq.telegramChannel
				)
				_link(
					title: .localized("IPA Channel"),
					subtitle: "@ufuq_ipa",
					systemImage: "arrow.down.app.fill",
					url: Ofuq.ipaChannel
				)
				_link(
					title: .localized("Instagram"),
					subtitle: "@_cpj41",
					systemImage: "camera.fill",
					url: Ofuq.instagram
				)
			}

			NBSection(.localized("Based on")) {
				_credit(name: "Nyasami", desc: String.localized("Ksign developer"), github: "nyasami")
				NavigationLink(destination: AboutView()) {
					HStack {
						Text("About the original Feather")
						Spacer()
					}
				}
			} footer: {
				Text(.localized("Ofuq is built on the open-source Ksign and Feather projects and is distributed under the GPL-3.0 license. Thank you to their developers! ❤️"))
			}

			NBSection(.localized("Source Code")) {
				_link(
					title: "ufuq-official/ofuq",
					subtitle: "GitHub",
					systemImage: "chevron.left.forwardslash.chevron.right",
					url: Ofuq.sourceCode
				)
			} footer: {
				Text(Bundle.main.bundleIdentifier ?? "")
			}
		}
		.onAppear {
			// Show the patch notes once per version.
			if !UserDefaults.standard.bool(forKey: _patchNotesKey) {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
					_showPatchNotes()
					UserDefaults.standard.set(true, forKey: _patchNotesKey)
				}
			}
		}
	}

	private func _showPatchNotes() {
		UIAlertController.showAlertWithOk(
			title: String.localized("What's new in Ofuq %@", arguments: Bundle.main.version),
			message: .localized("This version introduces:\n\n- The new Ofuq identity: icon, brown colors and launch screen\n- Installing through the local server works again, and falls back to Semi Local automatically when it cannot be used\n- Semi Local opens the iOS install prompt directly, without going through Safari\n- Clear error messages instead of an install that never responds\n- Updated built-in app sources"),
			isCancel: true,
			thankYou: true
		)
	}
}

// MARK: - Extension: view
extension AboutNyaView {
	@ViewBuilder
	private func _link(
		title: String,
		subtitle: String,
		systemImage: String,
		url: String
	) -> some View {
		Button {
			UIApplication.open(url)
		} label: {
			HStack(spacing: 12) {
				Image(systemName: systemImage)
					.font(.title2)
					.foregroundStyle(.tint)
					.frame(width: 36)

				VStack(alignment: .leading, spacing: 2) {
					Text(verbatim: title)
						.foregroundStyle(.primary)
					Text(verbatim: subtitle)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

				Spacer()

				Image(systemName: "arrow.up.right")
					.foregroundStyle(.secondary)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private func _credit(
		name: String?,
		desc: String?,
		github: String
	) -> some View {
		FRIconCellView(
			title: name ?? github,
			subtitle: desc ?? "",
			iconUrl: URL(string: "https://github.com/\(github).png")!,
			trailing: AnyView(
				Image(systemName: "arrow.up.right")
					.foregroundStyle(.secondary)
			)
		)
		.onTapGesture {
			if let url = URL(string: "https://github.com/\(github)") {
				UIApplication.shared.open(url)
			}
		}
	}
}
