import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button(model.perScreen ? "Общее видео… (\(model.sharedVideoName ?? "нет"))" : "Выбрать видео…") {
            model.chooseVideo(forDisplay: nil)
        }
        if !model.perScreen, let name = model.sharedVideoName {
            Text(name)
        }
        Toggle("Своё видео на каждый экран", isOn: $model.perScreen)
        if model.perScreen {
            ForEach(model.screens) { screen in
                Menu("\(screen.name): \(model.ownVideo(forDisplay: screen.id) ?? "общее")") {
                    Button("Выбрать видео…") { model.chooseVideo(forDisplay: screen.id) }
                    Button("Как общее") { model.useSharedVideo(forDisplay: screen.id) }
                        .disabled(model.ownVideo(forDisplay: screen.id) == nil)
                }
            }
        }
        Button("Убрать видео") { model.removeVideos() }
            .disabled(model.assignments.isEmpty)
        Divider()
        Toggle("Пауза", isOn: $model.userPaused)
        Toggle("Пауза от батареи", isOn: $model.pauseOnBattery)
        Divider()
        Toggle("Кадр из видео — обои системы", isOn: $model.syncSystemWallpaper)
        Button("Вернуть прежние обои") { model.restoreSystemWallpaper() }
            .disabled(!model.canRestoreWallpaper)
        Divider()
        Toggle("Запускать при входе", isOn: $model.launchAtLogin)
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
