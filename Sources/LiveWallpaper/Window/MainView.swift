import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperEngineKit

enum MainTab: String, CaseIterable, Identifiable {
    case library = "Библиотека"
    case screens = "Экраны"
    case settings = "Настройки"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .screens: "display.2"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails
    let pick: (PickKind) -> Void
    @State var tab: MainTab

    init(model: AppModel, thumbnails: Thumbnails, tab: MainTab = .library, pick: @escaping (PickKind) -> Void) {
        self.model = model
        self.thumbnails = thumbnails
        self.pick = pick
        _tab = State(initialValue: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, tab: $tab)
            Divider()
            Group {
                switch tab {
                case .library: LibraryView(model: model, thumbnails: thumbnails, pick: pick)
                case .screens: ScreensView(model: model, thumbnails: thumbnails)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.text), dismissButton: .default(Text("OK")))
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel
    @Binding var tab: MainTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.tint)
                Text("Live Wallpaper").font(.headline)
            }
            .padding(.bottom, 14)
            ForEach(MainTab.allCases) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(tab == item ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusLine).font(.callout).foregroundStyle(.secondary)
                Toggle("Пауза", isOn: $model.userPaused).toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: Library

private struct LibraryView: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails
    let pick: (PickKind) -> Void
    @State private var selected: String?
    @State private var addingAddress = false
    @State private var address = ""
    @State private var confirmRemoval: SavedWallpaper?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Библиотека").font(.title2.bold())
                Spacer()
                Menu {
                    Button("Видео…") { pick(.video) }
                    Button("GIF…") { pick(.gif) }
                    Button("Веб-страница: папка или файл…") { pick(.webPage) }
                    Button("Wallpaper Engine: папка, .pkg или project.json…") { pick(.engine) }
                    Button("Веб-страница по адресу…") { address = ""; addingAddress = true }
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 12)
            if model.library.items.isEmpty {
                EmptyLibrary(pick: pick, addAddress: { address = ""; addingAddress = true })
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.library.items) { item in
                            Card(model: model, thumbnails: thumbnails, item: item, isSelected: selected == item.id)
                                .onTapGesture(count: 2) { model.apply(item, to: .all) }
                                .onTapGesture { selected = item.id }
                                .contextMenu { applyMenu(item) }
                        }
                    }
                    .padding(20)
                }
                if let item = selected.flatMap({ model.library.item(id: $0) }) {
                    Divider()
                    ActionBar(model: model, item: item, remove: { confirmRemoval = item })
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await addDropped(url) }
                }
            }
            return true
        }
        .sheet(isPresented: $addingAddress) {
            AddressSheet(address: $address) { text in
                Task { if await model.addWebAddress(text) { addingAddress = false } }
            } cancel: { addingAddress = false }
        }
        .confirmationDialog(
            "Убрать «\(confirmRemoval?.title ?? "")» из библиотеки?", isPresented: .constant(confirmRemoval != nil), titleVisibility: .visible
        ) {
            Button("Убрать из библиотеки", role: .destructive) {
                if let item = confirmRemoval {
                    model.removeFromLibrary(item)
                    thumbnails.forget(item.id)
                    if selected == item.id { selected = nil }
                }
                confirmRemoval = nil
            }
            Button("Отмена", role: .cancel) { confirmRemoval = nil }
        } message: {
            Text("Файл остаётся на диске. Если эти обои сейчас на экране, они продолжат играть.")
        }
    }

    @ViewBuilder private func applyMenu(_ item: SavedWallpaper) -> some View {
        Button("На все экраны") { model.apply(item, to: .all) }
        ForEach(model.screens) { screen in
            Button("На экран «\(screen.name)»") { model.apply(item, to: .display(screen.id)) }
        }
        Divider()
        Button("Убрать из библиотеки", role: .destructive) { confirmRemoval = item }
    }

    private func addDropped(_ url: URL) async {
        let kind = WallpaperSource.Kind.detect(url: url)
        await model.addToLibrary(WallpaperSource(kind: kind, location: url.path, bookmark: try? url.bookmarkData()))
    }
}

private struct Card: View {
    let model: AppModel
    let thumbnails: Thumbnails
    let item: SavedWallpaper
    let isSelected: Bool
    /// nil until worked out off the main thread.
    @State private var sceneCheck: SceneAssets.Check?

    var body: some View {
        let shownOn = model.screenNames(showing: item)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Thumbnail(image: thumbnails.images[item.id], kind: item.source.kind)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 4) {
                    Badge(text: item.source.kind.badge)
                    if item.source.engine == .scene, let check = sceneCheck {
                        if !check.drawable {
                            Badge(text: "сцена: пока превью")
                        } else if !check.omissions.isEmpty {
                            Badge(text: "упрощено")
                                .help("Не рисуется: " + check.omissions.parts.joined(separator: ", "))
                        }
                    }
                    if isMissing { Badge(text: "Нет файла", warning: true) }
                }
                .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: isSelected ? 3 : 0))
            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(shownOn.isEmpty ? " " : "На экране: " + shownOn.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: item.id) { await thumbnails.load(item) }
        .task(id: item.source.location) {
            guard item.source.engine == .scene else { return }
            let source = item.source
            sceneCheck = await Task.detached(priority: .utility) { EngineSupport.sceneCheck(source) }.value
        }
    }

    private var isMissing: Bool {
        !item.source.isRemote && !FileManager.default.fileExists(atPath: item.source.resolvedURL.path)
    }
}

private struct Thumbnail: View {
    let image: NSImage?
    let kind: WallpaperSource.Kind

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: kind.symbol).font(.system(size: 34)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Badge: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(warning ? Color.red.opacity(0.85) : Color.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct ActionBar: View {
    let model: AppModel
    let item: SavedWallpaper
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(item.title).font(.headline).lineLimit(1)
            Spacer()
            Button("На все экраны") { model.apply(item, to: .all) }
                .buttonStyle(.borderedProminent)
            if model.screens.count > 1 {
                Menu("На экран") {
                    ForEach(model.screens) { screen in
                        Button(screen.name) { model.apply(item, to: .display(screen.id)) }
                    }
                }
                .fixedSize()
            }
            Button(role: .destructive, action: remove) { Label("Убрать", systemImage: "trash") }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct EmptyLibrary: View {
    let pick: (PickKind) -> Void
    let addAddress: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("В библиотеке пока пусто").font(.title3.weight(.semibold))
            Text("Добавьте видео, GIF, папку с веб-страницей, проект Wallpaper Engine или адрес. Файлы можно перетащить прямо в окно.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack {
                Button("Видео…") { pick(.video) }.buttonStyle(.borderedProminent)
                Button("GIF…") { pick(.gif) }
                Button("Веб-страница…") { pick(.webPage) }
                Button("Wallpaper Engine…") { pick(.engine) }
                Button("По адресу…", action: addAddress)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AddressSheet: View {
    @Binding var address: String
    let add: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Адрес веб-страницы").font(.headline)
            Text("Страница откроется на рабочем столе. Нужен адрес http или https.").foregroundStyle(.secondary)
            TextField("https://example.com/wallpaper/", text: $address)
                .textFieldStyle(.roundedBorder).frame(width: 380)
                .onSubmit { add(address) }
            HStack {
                Spacer()
                Button("Отмена", action: cancel).keyboardShortcut(.cancelAction)
                Button("Добавить") { add(address) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: Screens

private struct ScreensView: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Экраны").font(.title2.bold())
                Toggle("Своё на каждый экран", isOn: $model.perScreen)
                Text(model.perScreen
                    ? "Каждому экрану можно поставить свои обои; без своих он показывает общие."
                    : "Все экраны показывают одни обои. Включите переключатель, чтобы выбрать для каждого свои.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.screens.isEmpty {
                    Text("Нет подключённых экранов").foregroundStyle(.secondary)
                }
                ForEach(model.screens) { screen in
                    ScreenRow(model: model, thumbnails: thumbnails, screen: screen)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ScreenRow: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails
    let screen: ScreenStatus

    var body: some View {
        let item = screen.source.flatMap { model.library.item(for: $0) }
        HStack(spacing: 14) {
            Thumbnail(image: item.flatMap { thumbnails.images[$0.id] }, kind: screen.source?.kind ?? .video)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(width: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(screen.source == nil ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name).font(.headline)
                Text(screen.source.map { item?.title ?? $0.title } ?? "Обои не выбраны").foregroundStyle(.secondary).lineLimit(1)
                Text(state).font(.caption).foregroundStyle(screen.playing ? Color.green : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Menu("Поставить из библиотеки") {
                    ForEach(model.library.items) { item in
                        Button(item.title) { model.apply(item, to: model.perScreen ? .display(screen.id) : .all) }
                    }
                    if model.library.items.isEmpty { Text("Библиотека пуста") }
                }
                .fixedSize()
                if model.perScreen {
                    Picker("Масштаб", selection: $model.scaling.perScreen[screen.id]) {
                        Text("Как общий").tag(WallpaperScaling?.none)
                        ForEach(WallpaperScaling.allCases, id: \.self) { Text($0.title).tag(WallpaperScaling?.some($0)) }
                    }
                    .fixedSize()
                    .disabled(!model.assignments.scalingApplies(forDisplay: screen.id))
                    Button("Как общие") { model.useShared(forDisplay: screen.id) }
                        .disabled(model.ownSource(forDisplay: screen.id) == nil)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var state: String {
        if screen.source == nil { return "—" }
        if screen.playing { return "Играет" }
        return "Пауза: " + (screen.reasons.min { $0.priority < $1.priority }?.title ?? "загрузка")
    }
}

// MARK: Settings

private struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Настройки").font(.title2.bold())
                Group {
                    Panel("Видео") {
                        HStack {
                            Text("Масштаб")
                            Picker("Масштаб", selection: $model.scaling.shared) {
                                ForEach(WallpaperScaling.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                        }
                        .disabled(!model.assignments.scalingApplies(forDisplay: nil))
                        Hint("«Заполнить» обрезает края, «По размеру» оставляет полосы, «Растянуть» не сохраняет пропорции. Свой масштаб для каждого экрана — на вкладке «Экраны».")
                        Hint("Звук не воспроизводится: обои играют без звуковой дорожки.")
                    }
                    Panel("Сцены и веб-обои") {
                        HStack {
                            Text("Частота кадров")
                            Picker("Частота кадров", selection: $model.webFrameRate) {
                                ForEach(RenderQuality.frameRates, id: \.self) { Text("\($0) кадров/с").tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                        }
                        HStack {
                            Text("Качество сцен")
                            Picker("Качество сцен", selection: $model.renderQuality) {
                                ForEach(RenderQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                        }
                        Hint("«Экономное» рисует в разрешении точек экрана, картинки сцены вдвое меньше, видео не крупнее холста. «По экрану» рисует во всех пикселях экрана, видео не крупнее холста. «Максимальное» ничего не уменьшает. Смена качества перезагружает сцену на экране. Видео-обои, GIF и частота кадров видео от этих настроек не зависят.")
                        Toggle("Мышь доходит до страницы", isOn: $model.webInteractive)
                    }
                    Panel("Пауза") {
                        Toggle("Пауза вручную", isOn: $model.userPaused)
                        Toggle("Ставить на паузу при питании от батареи", isOn: $model.pauseOnBattery)
                        Hint("Сами ставятся на паузу: когда обои закрыты окнами, при блокировке экрана и сне, в режиме энергосбережения (Low Power Mode).")
                    }
                    Panel("Обои системы") {
                        Toggle("Первый кадр видео или GIF — обои системы", isOn: $model.syncSystemWallpaper)
                        Button("Вернуть прежние обои") { model.restoreSystemWallpaper() }
                            .disabled(!model.canRestoreWallpaper)
                        Hint("Кадр виден в Mission Control, на экране входа и до запуска приложения. «Вернуть прежние обои» ставит ваши картинки обратно и выключает этот переключатель.")
                    }
                    Panel("Запуск") {
                        Toggle("Запускать при входе", isOn: $model.launchAtLogin)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension WallpaperSource.Kind {
    var badge: String {
        switch self {
        case .video: "Видео"
        case .gif: "GIF"
        case .web: "Веб"
        case .wallpaperEngine: "WE"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .gif: "photo.stack"
        case .web: "globe"
        case .wallpaperEngine: "square.stack.3d.up"
        }
    }
}

extension RenderQuality {
    var title: String {
        switch self {
        case .economy: "Экономное"
        case .screen: "По экрану"
        case .maximum: "Максимальное"
        }
    }
}
