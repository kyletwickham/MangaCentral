import SwiftUI
import UIKit

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match Device"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/// Accent colors. Each has a brighter shade for dark backgrounds and a deeper one for white.
enum AccentChoice: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, gray
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    private var hexes: (dark: UInt32, light: UInt32) {
        switch self {
        case .red: return (0xFF5C5C, 0xD93636)
        case .orange: return (0xFF8A3D, 0xEF7426)
        case .yellow: return (0xF5C518, 0xB88A00)
        case .green: return (0x4CD07D, 0x1F9A52)
        case .teal: return (0x2EC4C4, 0x0F8F93)
        case .blue: return (0x4D9BFF, 0x2563EB)
        case .purple: return (0xA77BFF, 0x7C4DDB)
        case .pink: return (0xFF6FB5, 0xE0407F)
        case .brown: return (0xC8925E, 0x8B5A2B)
        case .gray: return (0xA3A8B8, 0x5F6472)
        }
    }

    /// Adapts automatically when the app switches between light and dark.
    var color: Color {
        let h = hexes
        return Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? h.dark : h.light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

@MainActor
@Observable
final class AppSettings {
    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }
    }

    init() {
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark
        accent = AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .orange
    }
}

/// A stable hash (Swift's built-in hashValue changes every launch).
enum StableHash {
    static func of(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return h
    }

    static func hue(_ s: String) -> Double {
        Double(of(s) % 360) / 360
    }
}

/// Colored circle or tile with initials, used for sites and friends.
struct Monogram: View {
    let text: String
    var size: CGFloat = 36
    var circle = false

    private var initials: String {
        let cleaned = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let words = String(cleaned).split(separator: " ")
        if words.count > 1, let a = words[0].first, let b = words[1].first { return "\(a)\(b)".uppercased() }
        return String(String(cleaned).replacingOccurrences(of: " ", with: "").prefix(2)).uppercased()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: StableHash.hue(text), saturation: 0.45, brightness: 0.55),
                        in: RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Light gives the app white menus and backgrounds. The reader always keeps a black background around pages so the art stands out.")
                }

                Section("Accent Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                settings.accent = choice
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(choice.color)
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if settings.accent == choice {
                                                Circle().strokeBorder(Color.primary, lineWidth: 2.5).padding(-5)
                                            }
                                        }
                                    Text(choice.label)
                                        .font(.caption)
                                        .foregroundStyle(settings.accent == choice ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                            .accessibilityAddTraits(settings.accent == choice ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("About") {
                    LabeledContent("App", value: "MangaCentral")
                    LabeledContent("Version", value: "0.4")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(settings.accent.color)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

/// Gear button that opens Settings. Drop into any toolbar.
struct SettingsButton: View {
    @Environment(AppSettings.self) private var settings
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
            .sheet(isPresented: $showing) {
                SettingsView().environment(settings)
            }
    }
}
