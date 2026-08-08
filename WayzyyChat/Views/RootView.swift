// Root tab container.

import SwiftUI

struct RootView: View {
    @StateObject private var store = ChatStore()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ChatListView()
                .environmentObject(store)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)

            LabView()
                .environmentObject(store)
                .tabItem { Label("Lab", systemImage: "shield.lefthalf.filled.badge.checkmark") }
                .tag(1)

            OpsView()
                .environmentObject(store)
                .tabItem { Label("Ops", systemImage: "chart.bar.doc.horizontal.fill") }
                .tag(2)
                .badge(store.queue.filter { $0.resolution == nil }.count)
        }
        .tint(WZ.orange)
        .preferredColorScheme(.dark)
    }
}
