//
//  AppIconView.swift
//  Ksign
//
//  Created by Nagata Asami on 6/28/25.
//

import SwiftUI
import NimbleViews

// MARK: - Models
struct AppIconOption {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String
    let alternateIconName: String?
}

// MARK: - View
struct AppIconView: View {
    @State private var selectedIcon: String? = UIApplication.shared.alternateIconName
    
    private let appIcons: [AppIconOption] = [
        AppIconOption(
            id: "primary",
            title: .localized("Default"),
            subtitle: "Ofuq",
            iconName: "AppIcon",
            alternateIconName: nil
        ),

        AppIconOption(id: "ofuq_dark", title: .localized("Night"), subtitle: "Ofuq", iconName: "ofuq_dark", alternateIconName: "ofuq_dark"),
        AppIconOption(id: "ofuq_brown", title: .localized("Brown"), subtitle: "Ofuq", iconName: "ofuq_brown", alternateIconName: "ofuq_brown"),
        AppIconOption(id: "ofuq_white", title: .localized("White"), subtitle: "Ofuq", iconName: "ofuq_white", alternateIconName: "ofuq_white"),
    ]
    
    // MARK: Body
    var body: some View {
        NBList(.localized("App Icon")) {
            NBSection(.localized("Available Icons")) {
                ForEach(appIcons, id: \.id) { iconOption in
                    _iconCell(for: iconOption)
                }
            }
        }
        .onAppear {
            selectedIcon = UIApplication.shared.alternateIconName
        }
    }
}

// MARK: - View extension
extension AppIconView {
    @ViewBuilder
    private func _iconCell(for iconOption: AppIconOption) -> some View {
        Button {
            _changeAppIcon(to: iconOption)
        } label: {
            HStack(spacing: 12) {
                if let image = UIImage(named: iconOption.iconName) ?? UIImage(named: Bundle.main.iconFileName ?? "") {
                    Image(uiImage: image)
                        .appIconStyle(size: 60)
                } else {
                    Image("App_Unknown")
                        .appIconStyle(size: 60)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(iconOption.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(iconOption.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if selectedIcon == iconOption.alternateIconName {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.headline)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
    
    private func _changeAppIcon(to iconOption: AppIconOption) {
        guard selectedIcon != iconOption.alternateIconName else { return }
        
//        guard UIApplication.shared.supportsAlternateIcons else {
//            print("Alternate icons are not supported on this device")
//            return
//        }
        
        UIApplication.shared.setAlternateIconName(iconOption.alternateIconName) { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to change app icon: \(error.localizedDescription)")
                } else {
                    self.selectedIcon = iconOption.alternateIconName
                    print("Successfully changed app icon to: \(iconOption.alternateIconName ?? "primary")")
                }
            }
        }
    }
} 
