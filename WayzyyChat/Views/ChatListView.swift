// Conversation list.

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var store: ChatStore
    @State private var search = ""
    @State private var showNewChat = false
    @State private var openConversationID: UUID? = nil
    @State private var didRunLaunchProbe = false

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return store.conversations }
        let q = search.lowercased()
        return store.conversations.filter {
            $0.name.lowercased().contains(q) || $0.propertyName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WZ.bg.ignoresSafeArea()

                WZHeaderBloom()
                    .frame(height: 430)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 32,
                            bottomTrailingRadius: 32,
                            style: .continuous
                        )
                    )
                    .ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(spacing: 0) {
                        headerBlock
                        conversationList
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showNewChat) {
                NewChatSheet { name, property, isHost, trust, stage in
                    let id = store.startConversation(
                        name: name, property: property,
                        isHost: isHost, trust: trust, stage: stage
                    )
                    showNewChat = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        openConversationID = id
                    }
                }
            }
            .navigationDestination(item: $openConversationID) { id in
                ChatView(conversationID: id).environmentObject(store)
            }
            .onAppear(perform: runLaunchProbeIfRequested)
        }
    }

    private func runLaunchProbeIfRequested() {
        #if DEBUG
        guard !didRunLaunchProbe else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-wzProbeNewChat") {
            didRunLaunchProbe = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showNewChat = true }
        } else if args.contains("-wzProbeCreateChat") {
            didRunLaunchProbe = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let id = store.startConversation(
                    name: "Probe Guest", property: "Beach House, Morjim",
                    isHost: false, trust: .fresh, stage: .inquiry
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    openConversationID = id
                }
            }
        }
        #endif
    }

    private var headerBlock: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WZ.textTertiary)
                        TextField(
                            "",
                            text: $search,
                            prompt: Text("Search...").foregroundColor(WZ.textTertiary)
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(WZ.textPrimary)
                        .tint(WZ.orange)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .wzGlassPill()
                    .frame(width: 196)

                    Spacer()

                    Menu {
                        Button(role: .destructive) {
                            store.resetToSeed()
                        } label: {
                            Label("Reset conversations", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WZ.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.9))
                    }
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: -6) {
                    Text("Stay Connected,")
                        .font(.system(size: 33, weight: .bold))
                    HStack(spacing: 0) {
                        Text("Stay ")
                            .font(.system(size: 33, weight: .bold))
                        Text("Protected")
                            .font(.system(size: 33, weight: .bold, design: .serif))
                            .italic()
                            .foregroundStyle(WZ.orange)
                    }
                }
                .foregroundStyle(WZ.textPrimary)
                .padding(.top, 26)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        addBubble
                        ForEach(store.conversations.prefix(5)) { convo in
                            VStack(spacing: 6) {
                                WZAvatar(
                                    initials: convo.initials,
                                    size: 56,
                                    isHost: convo.isHost,
                                    ring: convo.isOnline
                                )
                                Text(convo.name.split(separator: " ").first.map(String.init) ?? "")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(WZ.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 300, alignment: .top)
    }

    private var addBubble: some View {
        Button { showNewChat = true } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(WZ.orange.opacity(0.14))
                    Circle().strokeBorder(WZ.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(WZ.orange)
                }
                .frame(width: 56, height: 56)
                Text("New")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WZ.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 26))
                        .foregroundStyle(WZ.textTertiary)
                    Text(search.isEmpty ? "No conversations yet" : "No matches")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WZ.textSecondary)
                    if search.isEmpty {
                        Text("Tap New to start one.")
                            .font(.system(size: 12))
                            .foregroundStyle(WZ.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 46)
            }

            ForEach(filtered) { convo in
                NavigationLink {
                    ChatView(conversationID: convo.id).environmentObject(store)
                } label: {
                    ConversationRow(convo: convo)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        store.deleteConversation(convo.id)
                    } label: {
                        Label("Delete conversation", systemImage: "trash")
                    }
                }

                Divider()
                    .overlay(WZ.hairline)
                    .padding(.leading, 78)
            }
        }
        .padding(.top, 6)
        .frame(minHeight: 420, alignment: .top)
        .background(WZ.bg)
    }
}

struct ConversationRow: View {
    let convo: Conversation

    var body: some View {
        HStack(spacing: 13) {
            WZAvatar(initials: convo.initials, size: 50, isHost: convo.isHost)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(convo.name)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(WZ.textPrimary)
                    if convo.trust == .trusted {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(WZ.orange)
                    }
                }

                HStack(spacing: 5) {
                    if convo.lastMessage?.wasModerated == true {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(WZ.orange)
                    }
                    Text(previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(WZ.textSecondary)
                        .lineLimit(1)
                }

                Text(convo.propertyName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                Text(convo.lastMessage?.timestamp.wzListLabel ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textTertiary)

                if convo.unread > 0 {
                    Text("\(convo.unread)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(WZ.orange))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var previewText: String {
        guard let last = convo.lastMessage else { return "No messages yet" }
        if last.wasModerated, let v = last.verdict {
            switch v.action {
            case .warn, .block: return "Message withheld · contact details"
            case .review:       return "Under review"
            default:            return v.maskedText
            }
        }
        return last.text
    }
}
