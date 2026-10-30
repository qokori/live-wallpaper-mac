import AppKit
import SwiftUI
import WallpaperCore

/// Quick actions. Choosing files, screens and settings are in the main window; nothing here opens a panel or a modal.
struct MenuContent: View {
    @Bindable var model: AppModel
    let openWindow: () -> Void

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button("Открыть Live Wallpaper…", action: openWindow)
        if !model.library.items.isEmpty {
            Menu("Поставить на все экраны") {
                ForEach(model.library.items) { item in
                    Button(item.title) { model.apply(item, to: .all) }
                }
            }
        }
        Button("Убрать обои") { model.removeAll() }
            .disabled(model.assignments.isEmpty)
        Divider()
        Toggle("Пауза", isOn: $model.userPaused)
        Toggle("Пауза от батареи", isOn: $model.pauseOnBattery)
        Divider()
        Button("Вернуть прежние обои") { model.restoreSystemWallpaper() }
            .disabled(!model.canRestoreWallpaper)
        Toggle("Запускать при входе", isOn: $model.launchAtLogin)
        Divider()
        if model.updates.isEnabled { updateItems }
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var updateItems: some View {
        let updates = model.updates
        Button("Проверить обновления…") { updates.checkNow() }
            .disabled(!updates.canCheck)
        Toggle("Обновлять автоматически", isOn: Bindable(updates).autoUpdate)
        Divider()
    }
}
