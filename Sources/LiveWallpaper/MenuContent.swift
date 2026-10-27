import AppKit
import SwiftUI
import WallpaperCore

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(model.statusLine)
        Divider()
        Text(model.perScreen ? "Общие обои: \(model.sharedTitle ?? "нет")" : "Обои: \(model.sharedTitle ?? "нет")")
        SourceButtons(model: model, display: nil)
        Picker("Масштаб", selection: $model.scaling.shared) {
            ForEach(WallpaperScaling.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .disabled(!model.assignments.scalingApplies(forDisplay: nil))
        Toggle("Своё на каждый экран", isOn: $model.perScreen)
        if model.perScreen {
            ForEach(model.screens) { screen in
                Menu("\(screen.name): \(model.ownSource(forDisplay: screen.id) ?? "общие")") {
                    SourceButtons(model: model, display: screen.id)
                    // A screen without its own choice follows the shared one, like its source.
                    Picker("Масштаб", selection: $model.scaling.perScreen[screen.id]) {
                        Text("Как общий").tag(WallpaperScaling?.none)
                        ForEach(WallpaperScaling.allCases, id: \.self) { Text($0.title).tag(WallpaperScaling?.some($0)) }
                    }
                    .disabled(!model.assignments.scalingApplies(forDisplay: screen.id))
                    Divider()
                    Button("Как общие") { model.useShared(forDisplay: screen.id) }
                        .disabled(model.ownSource(forDisplay: screen.id) == nil)
                }
            }
        }
        Button("Убрать обои") { model.removeAll() }
            .disabled(model.assignments.isEmpty)
        Divider()
        Toggle("Пауза", isOn: $model.userPaused)
        Toggle("Пауза от батареи", isOn: $model.pauseOnBattery)
        Divider()
        Menu("Веб-обои") {
            Toggle("Мышь доходит до страницы", isOn: $model.webInteractive)
            Picker("Частота кадров", selection: $model.webFrameRate) {
                Text("30 кадров/с").tag(30)
                Text("60 кадров/с").tag(60)
            }
            .pickerStyle(.inline)
        }
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

private struct SourceButtons: View {
    let model: AppModel
    let display: String?

    var body: some View {
        Button("Видео…") { model.chooseVideo(forDisplay: display) }
        Button("Веб-страница: папка или файл…") { model.chooseWebFolder(forDisplay: display) }
        Button("Веб-страница по адресу…") { model.enterWebAddress(forDisplay: display) }
    }
}
