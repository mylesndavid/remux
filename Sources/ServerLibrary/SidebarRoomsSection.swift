import SwiftUI

/// Collapsible **Rooms** section pinned at the bottom-left of the workspace
/// sidebar (VS Code-style stacked panel), above the footer buttons. Collapsed by
/// default so it stays out of the way; expands to the full Rooms panel (server
/// picker, presence, create/join/share). Lives OUTSIDE the workspace `LazyVStack`
/// (it's in the footer), so holding an observable store here is safe — it does
/// not trip the sidebar row-snapshot CPU rule.
struct SidebarRoomsSection: View {
    @AppStorage("sidebarRoomsCollapsed") private var collapsed = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "rectangle.3.group").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("ROOMS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Shared rooms on your servers")

            if !collapsed {
                RoomsSidebarPanel()
                    .frame(height: 260)
            }
        }
    }
}
