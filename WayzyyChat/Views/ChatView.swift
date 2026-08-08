// Message thread with composer, live hints and delivery status.

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    let conversationID: UUID

    @State private var draft = ""
    @State private var liveHint: Verdict? = nil
    @State private var inspecting: (text: String, verdict: Verdict)? = nil
    @State private var showRelaySheet = false
    @State private var showContextSheet = false
    @FocusState private var composerFocused: Bool

    private var convo: Conversation? {
        store.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                messageList
            }
            .background(
                WZMeshCanvas()
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 34,
                            bottomTrailingRadius: 34,
                            style: .continuous
                        )
                    )
                    .ignoresSafeArea(edges: .top)
            )

            composerStrip
        }
        .background(WZ.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(conversationID: conversationID) }
        .sheet(isPresented: $showRelaySheet) { RelayCallSheet(convo: convo) }
        .sheet(isPresented: $showContextSheet) {
            if let convo { ContextSheet(convo: convo).environmentObject(store) }
        }
        .sheet(item: $inspecting) { payload in
            InspectorView(text: payload.text, verdict: payload.verdict)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(WZ.textPrimary)
            }
            .buttonStyle(.plain)

            WZAvatar(
                initials: convo?.initials ?? "–",
                size: 46,
                isHost: convo?.isHost ?? false
            )

            Text(convo?.name ?? "Unknown")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(WZ.textPrimary)
                .lineLimit(2)
                .lineSpacing(-3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            WZGlassCircleButton(systemName: "phone.fill", size: 42, iconSize: 14) {
                showRelaySheet = true
            }
            WZGlassCircleButton(systemName: "slider.horizontal.3", size: 42, iconSize: 14) {
                showContextSheet = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var messageList: some View {
        let msgs = convo?.messages ?? []

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if msgs.isEmpty { emptyState }
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { idx, message in
                        Group {
                            if message.isSystemNotice {
                                SystemNoticeRow(text: message.text)
                            } else {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: Self.isLastInGroup(at: idx, in: msgs),
                                    onInspect: {
                                        if let v = message.verdict {
                                            inspecting = (message.text, v)
                                        }
                                    },
                                    onReveal: {
                                        store.toggleReveal(messageID: message.id, in: conversationID)
                                    }
                                )
                            }
                        }
                        .padding(.top, Self.isFirstInGroup(at: idx, in: msgs) ? 14 : 4)
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: convo?.messages.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    if let last = convo?.messages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = convo?.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 30))
                .foregroundStyle(WZ.orange.opacity(0.85))

            Text("Every message is checked before it sends")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(WZ.textPrimary)
                .multilineTextAlignment(.center)

            Text("Contact details get removed, not the conversation. Tap any flagged bubble to see exactly why.")
                .font(.system(size: 12))
                .foregroundStyle(WZ.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("TRY ONE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(WZ.textTertiary)
                ForEach(Self.emptyStatePrompts, id: \.self) { prompt in
                    Text("“\(prompt)”")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(WZ.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .padding(.top, 80)
        .padding(.bottom, 20)
    }

    private static let emptyStatePrompts = [
        "847 zero sattar assi 34",
        "my insta is akshay_villa_goa",
        "akshay at gmail dot com",
        "pay me on akshay@ybl, cheaper direct"
    ]

    static func isLastInGroup(at idx: Int, in msgs: [ChatMessage]) -> Bool {
        guard idx >= 0, idx < msgs.count else { return true }
        guard let next = msgs[safe: idx + 1] else { return true }
        if next.isSystemNotice { return true }
        return next.isOutgoing != msgs[idx].isOutgoing
    }

    static func isFirstInGroup(at idx: Int, in msgs: [ChatMessage]) -> Bool {
        guard idx > 0 else { return true }
        guard let previous = msgs[safe: idx - 1] else { return true }
        if previous.isSystemNotice || msgs[idx].isSystemNotice { return true }
        return previous.isOutgoing != msgs[idx].isOutgoing
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var composerStrip: some View {
        VStack(spacing: 10) {
            if let hint = liveHint {
                PreSendHint(verdict: hint)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $draft,
                    prompt: Text("Your Message...").foregroundColor(WZ.textTertiary),
                    axis: .vertical
                )
                .font(.system(size: 15))
                .foregroundStyle(WZ.textPrimary)
                .tint(WZ.orange)
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(.leading, 16)
                .onChange(of: draft) { _, newValue in
                    withAnimation(.easeOut(duration: 0.18)) {
                        liveHint = store.hint(newValue, in: conversationID)
                    }
                }

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            hasDraft
                                ? Color(hex: 0x0A0A0C)
                                : Color.white.opacity(0.92)
                        )
                        .frame(width: 72, height: 42)
                        .background(
                            Capsule().fill(
                                hasDraft
                                    ? AnyShapeStyle(WZ.brandGradient)
                                    : AnyShapeStyle(WZ.orangeDeep.opacity(0.55))
                            )
                        )
                        .animation(.easeOut(duration: 0.15), value: hasDraft)
                }
                .buttonStyle(.plain)
                .disabled(!hasDraft)
            }
            .padding(5)
            .frame(minHeight: 54)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 16)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(WZ.bg)
    }

    private func submit() {
        let verdict = store.send(draft, in: conversationID)
        if let verdict, verdict.action.withholdsMessage {
        } else {
            draft = ""
        }
        liveHint = nil
    }
}

struct PreSendHint: View {
    let verdict: Verdict

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WZ.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WZ.textPrimary)
                Text("Off-platform bookings aren't covered by Wayzyy Protection.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textSecondary)
            }

            Spacer(minLength: 0)

            Text(String(format: "%.2f ms", verdict.latencyMs))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WZ.orange.opacity(0.85))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(WZ.orange.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(WZ.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var headline: String {
        let cats = verdict.contactCategories
        if let first = cats.first {
            return "Looks like you're sharing a \(first.display.lowercased())"
        }
        if verdict.categories.contains(.scam) {
            return "This looks like an off-platform request"
        }
        return "This message may break our community rules"
    }
}

struct RelayCallSheet: View {
    let convo: Conversation?

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
                .padding(.top, 10)

            WZAvatar(initials: convo?.initials ?? "–", size: 72, isHost: convo?.isHost ?? false)

            VStack(spacing: 5) {
                Text("Call \(convo?.name ?? "")")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(WZ.textPrimary)
                Text("Connected through a Wayzyy relay number")
                    .font(.system(size: 13))
                    .foregroundStyle(WZ.textSecondary)
            }

            WZCard {
                VStack(alignment: .leading, spacing: 10) {
                    row("phone.arrow.right.fill", "Relay number", "+91 80 4718 0022")
                    Divider().overlay(WZ.hairline)
                    row("eye.slash.fill", "Real numbers", "Hidden from both sides")
                    Divider().overlay(WZ.hairline)
                    row("clock.fill", "Expires", "At checkout, automatically")
                }
            }
            .padding(.horizontal, 18)

            Text("Giving people a sanctioned way to reach each other removes most of the reason to evade moderation at all. Detection handles the adversarial remainder.")
                .font(.system(size: 11.5))
                .foregroundStyle(WZ.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(spacing: 8) {
                Text("Not implemented")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WZ.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(WZ.warn)
                        .padding(.top, 1)
                    Text("Voice is an open gap: a broker can read a number aloud and nothing inspects it. Plan is relay audio through on-device transcription into the same engine — spoken digits are already the engine's strongest family.")
                        .font(.system(size: 10))
                        .foregroundStyle(WZ.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WZ.bg)
        .presentationDetents([.height(560)])
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WZ.orange)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(WZ.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WZ.textPrimary)
        }
    }
}

struct ContextSheet: View {
    @EnvironmentObject var store: ChatStore
    let convo: Conversation

    var body: some View {
        let thresholds = Policy.thresholds(for: convo.actorContext(senderID: "me"))

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Actor risk context")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WZ.textPrimary)

                Text("One global threshold is why legacy moderation over-blocks good users and under-blocks determined ones. Change these, resend the same message, and watch the verdict move.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(WZ.textSecondary)

                WZCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TRUST TIER")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(WZ.textTertiary)
                        Picker("", selection: Binding(
                            get: { convo.trust },
                            set: { store.updateContext(conversationID: convo.id, trust: $0) }
                        )) {
                            ForEach(TrustTier.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        Text("BOOKING STAGE")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(WZ.textTertiary)
                            .padding(.top, 4)
                        Picker("", selection: Binding(
                            get: { convo.stage },
                            set: { store.updateContext(conversationID: convo.id, stage: $0) }
                        )) {
                            ForEach(BookingStage.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                WZCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("EFFECTIVE THRESHOLDS")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(WZ.textTertiary)
                        thresholdRow("Hint", thresholds.hint, WZ.allow)
                        thresholdRow("Mask", thresholds.mask, WZ.mask)
                        thresholdRow("Withhold", thresholds.withhold, WZ.block)
                        Text("Prior violations: \(convo.priorViolations)")
                            .font(.system(size: 11))
                            .foregroundStyle(WZ.textTertiary)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 10)
            }
            .padding(18)
        }
        .background(WZ.bg)
    }

    private func thresholdRow(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(WZ.textSecondary)
            Spacer()
            Text(String(format: "%.2f", value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }
}

private struct InspectPayload: Identifiable {
    let id = UUID()
    let text: String
    let verdict: Verdict
}

extension View {
    func sheet<Content: View>(
        item: Binding<(text: String, verdict: Verdict)?>,
        @ViewBuilder content: @escaping ((text: String, verdict: Verdict)) -> Content
    ) -> some View {
        let bound = Binding<InspectPayload?>(
            get: {
                guard let v = item.wrappedValue else { return nil }
                return InspectPayload(text: v.text, verdict: v.verdict)
            },
            set: { newValue in
                if newValue == nil { item.wrappedValue = nil }
            }
        )
        return sheet(item: bound) { payload in
            content((text: payload.text, verdict: payload.verdict))
        }
    }
}
