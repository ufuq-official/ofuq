//
//  AccentColorManager.swift
//  Ksign
//
//  Created by Nagata Asami on 6/30/25.
//

import SwiftUI
import UIKit

// MARK: - Accent Color Manager
class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()
    
    @AppStorage("Feather.accentColor") private var _selectedAccentColor: Int = 0 {
        didSet {
            objectWillChange.send()
        }
    }
    
    /// Ofuq brand brown: a deep brown on light backgrounds and a lighter, warm brown on dark ones,
    /// so tinted text and buttons stay readable in both appearances.
    static let ofuqBrownUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xC9/255, green: 0xA2/255, blue: 0x7C/255, alpha: 1.0) // #C9A27C
            : UIColor(red: 0x6B/255, green: 0x44/255, blue: 0x29/255, alpha: 1.0) // #6B4429
    }
    static let ofuqBrown = Color(uiColor: ofuqBrownUIColor)

    private let _accentColors: [(color: Color, uiColor: UIColor)] = [
        (AccentColorManager.ofuqBrown, AccentColorManager.ofuqBrownUIColor), // Default (Ofuq brown)
        (Color(red: 0x53/255, green: 0x94/255, blue: 0xF7/255), UIColor(red: 0x53/255, green: 0x94/255, blue: 0xF7/255, alpha: 1.0)), // Ksign blue
        (Color(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255), UIColor(red: 0xFF/255, green: 0x8B/255, blue: 0x92/255, alpha: 1.0)), //rgb(255, 139, 146)
        (.red, .systemRed),
        (.orange, .systemOrange),
        (.yellow, .systemYellow),
        (.green, .systemGreen),
        (.blue, .systemBlue),
        (.purple, .systemPurple),
        (.pink, .systemPink),
        (.indigo, .systemIndigo),
        (.mint, .systemMint),
        (.cyan, .systemCyan),
        (.teal, .systemTeal)
    ]
    
    var currentAccentColor: Color {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].color
        }
        return _accentColors[_selectedAccentColor].color
    }
    
    var currentUIColor: UIColor {
        guard _selectedAccentColor < _accentColors.count else {
            return _accentColors[0].uiColor
        }
        return _accentColors[_selectedAccentColor].uiColor
    }
    
    /// Updates the global app tint color
    func updateGlobalTintColor() {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { window in
                    window.tintColor = self.currentUIColor
                }
        }
    }
} 