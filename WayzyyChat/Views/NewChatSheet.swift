// Sheet for starting a conversation with a chosen trust tier and booking stage.

import SwiftUI

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var property = ""
    @State private var isHost = true
    @State private var trust: TrustTier = .standard
    @State private var stage: BookingStage = .inquiry

    let onCreate: (String, String, Bool, TrustTier, BookingStage) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        WZAvatar(initials: initials, size: 54, isHost: isHost)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? "New contact" : name)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(WZ.textPrimary)
                            Text(property.isEmpty ? "Unassigned listing" : property)
                                .font(.system(size: 12))
                                .foregroundStyle(WZ.textSecondary)
                        }
                        Spacer()
                    }

                    WZCard {
                        VStack(alignment: .leading, spacing: 12) {
                            field("NAME", placeholder: "e.g. Rahul Desai", text: $name)
                            Divider().overlay(WZ.hairline)
                            field("LISTING", placeholder: "e.g. Beach House, Morjim", text: $property)
                        }
                    }

                    WZCard {
                        VStack(alignment: .leading, spacing: 12) {
                            label("THEIR ROLE")
                            Picker("", selection: $isHost) {
                                Text("Host").tag(true)
                                Text("Guest").tag(false)
                            }
                            .pickerStyle(.segmented)

                            label("TRUST TIER")
                            Picker("", selection: $trust) {
                                ForEach(TrustTier.allCases) { Text($0.display).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            label("BOOKING STAGE")
                            Picker("", selection: $stage) {
                                ForEach(BookingStage.allCases) { Text($0.display).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    let thresholds = Policy.thresholds(for: ActorContext(trust: trust, stage: stage))
                    WZCard {
                        VStack(alignment: .leading, spacing: 8) {
                            label("RESULTING THRESHOLDS")
                            thresholdRow("Hint", thresholds.hint, WZ.allow)
                            thresholdRow("Mask", thresholds.mask, WZ.mask)
                            thresholdRow("Withhold", thresholds.withhold, WZ.block)
                            Text("A new unverified account needs less evidence before we act; a trusted host at check-in needs more. Same detector, different operating point.")
                                .font(.system(size: 10))
                                .foregroundStyle(WZ.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        onCreate(name, property, isHost, trust, stage)
                    } label: {
                        Text("Start chat")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(WZ.brandGradient))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 12)
                }
                .padding(18)
            }
            .background(WZ.bg)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(WZ.surface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(WZ.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var initials: String {
        let parts = name.split(separator: " ").compactMap(\.first)
        if parts.isEmpty { return "?" }
        if parts.count == 1 { return String(parts[0]).uppercased() }
        return String([parts[0], parts[1]]).uppercased()
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(WZ.textTertiary)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(title)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(WZ.textTertiary))
                .font(.system(size: 15))
                .foregroundStyle(WZ.textPrimary)
                .tint(WZ.orange)
                .textInputAutocapitalization(.words)
        }
    }

    private func thresholdRow(_ title: String, _ value: Double, _ tint: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(WZ.textSecondary)
            Spacer()
            Text(String(format: "%.2f", value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }
}
