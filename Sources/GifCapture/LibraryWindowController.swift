import AppKit
import Quartz
import UniformTypeIdentifiers

/// Finder-like browser for ~/Desktop/GifCaptures with two view modes:
/// a thumbnail grid, and Miller columns (folders open side by side, so GIFs can
/// be dragged between levels). Right-click empty space to create folders;
/// right-click items for Preview / Trim / Copy / Reveal / Trash. Space = Quick Look.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private enum ViewMode: Int { case grid = 0, columns = 1 }

    // Grid state
    private var currentFolder: URL = GifConverter.outputDirectory
    private var items: [URL] = []

    // Columns state
    private var columnFolders: [URL] = [GifConverter.outputDirectory]
    private var columnViews: [LibraryColumn] = []
    private var focusedColumn = 0
    private var isRebuildingColumns = false

    private var previewItems: [URL] = []
    private var trimController: TrimWindowController?
    private var folderWatcher: DispatchSourceFileSystemObject?

    private var collectionView: KeyHandlingCollectionView!
    private var gridScroll: NSScrollView!
    private var columnsScroll: NSScrollView!
    private var columnsStack: NSStackView!
    private var contentContainer: NSView!
    private var backButton: NSButton!
    private var pathLabel: NSTextField!
    private var modeControl: NSSegmentedControl!
    private var gridMenu: NSMenu!

    /// Set by menuWillOpen so the context-menu actions know their target.
    private var menuContext: (urls: [URL], folder: URL) = ([], GifConverter.outputDirectory)

    private var mode: ViewMode = .grid {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "libraryViewMode")
            applyMode()
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "📚 Library"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        self.init(window: window)
        window.delegate = self
        mode = ViewMode(rawValue: UserDefaults.standard.integer(forKey: "libraryViewMode")) ?? .grid
        buildUI()
        applyMode()
    }

    func show() {
        navigate(to: GifConverter.outputDirectory)
        setColumnFolders([GifConverter.outputDirectory], rebuildFrom: 0)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopWatching()
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    private func currentSelection() -> [URL] {
        switch mode {
        case .grid:
            return collectionView.selectionIndexPaths.compactMap {
                items.indices.contains($0.item) ? items[$0.item] : nil
            }
        case .columns:
            guard columnViews.indices.contains(focusedColumn) else { return [] }
            return columnViews[focusedColumn].selectedURLs
        }
    }

    fileprivate func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let gifs = currentSelection().filter { !isFolder($0) }
        guard !gifs.isEmpty else { return }
        previewItems = gifs
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    private func refreshPreviewIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        let gifs = currentSelection().filter { !isFolder($0) }
        guard !gifs.isEmpty else { return }
        previewItems = gifs
        panel.reloadData()
    }

    // MARK: - UI

    private func buildUI() {
        backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self, action: #selector(goBack)
        )
        backButton.bezelStyle = .texturedRounded
        backButton.isEnabled = false

        pathLabel = NSTextField(labelWithString: "GifCaptures")
        pathLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingHead

        modeControl = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!,
                NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!,
            ],
            trackingMode: .selectOne,
            target: self, action: #selector(modeChanged)
        )
        modeControl.selectedSegment = mode.rawValue

        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealCurrent))
        revealButton.bezelStyle = .texturedRounded

        let topBar = NSStackView(views: [backButton, pathLabel, NSView(), modeControl, revealButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        buildGrid()
        buildColumns()

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(topBar)
        content.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    private func buildGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 130, height: 130)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)

        collectionView = KeyHandlingCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(LibraryCell.self, forItemWithIdentifier: LibraryCell.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.onSpaceKey = { [weak self] in self?.togglePreview() }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(doubleClick)

        gridMenu = NSMenu()
        gridMenu.delegate = self
        collectionView.menu = gridMenu

        gridScroll = NSScrollView()
        gridScroll.documentView = collectionView
        gridScroll.hasVerticalScroller = true
        gridScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildColumns() {
        columnsStack = NSStackView()
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 0
        columnsStack.translatesAutoresizingMaskIntoConstraints = false

        columnsScroll = NSScrollView()
        columnsScroll.documentView = columnsStack
        columnsScroll.hasHorizontalScroller = true
        columnsScroll.hasVerticalScroller = false
        columnsScroll.translatesAutoresizingMaskIntoConstraints = false

        columnsStack.topAnchor.constraint(equalTo: columnsScroll.contentView.topAnchor).isActive = true
        columnsStack.leadingAnchor.constraint(equalTo: columnsScroll.contentView.leadingAnchor).isActive = true
        columnsStack.heightAnchor.constraint(equalTo: columnsScroll.contentView.heightAnchor).isActive = true
    }

    private func applyMode() {
        guard let contentContainer, let gridScroll, let columnsScroll else { return }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let active: NSView = mode == .grid ? gridScroll : columnsScroll
        contentContainer.addSubview(active)
        NSLayoutConstraint.activate([
            active.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            active.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            active.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            active.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        backButton?.isHidden = mode == .columns
        if mode == .columns {
            pathLabel?.stringValue = "GifCaptures"
        } else {
            updateGridPathLabel()
        }
    }

    // MARK: - Data

    private func contents(of folder: URL) -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        let folders = all
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let gifs = all
            .filter { $0.pathExtension.lowercased() == "gif" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
        return folders + gifs
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func navigate(to folder: URL) {
        currentFolder = folder
        reloadGrid()
        watch(folder: folder)
        updateGridPathLabel()
    }

    private func updateGridPathLabel() {
        guard mode == .grid else { return }
        let base = GifConverter.outputDirectory.path
        let relative = currentFolder.path.replacingOccurrences(of: base, with: "GifCaptures")
        pathLabel.stringValue = relative.replacingOccurrences(of: "/", with: " › ")
        backButton.isEnabled = currentFolder.standardizedFileURL != GifConverter.outputDirectory.standardizedFileURL
    }

    private func reloadGrid() {
        items = contents(of: currentFolder)
        collectionView.reloadData()
    }

    private func setColumnFolders(_ folders: [URL], rebuildFrom: Int) {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }

        columnFolders = folders
        while columnViews.count > rebuildFrom {
            let column = columnViews.removeLast()
            columnsStack.removeArrangedSubview(column)
            column.removeFromSuperview()
        }
        while columnViews.count < columnFolders.count {
            let index = columnViews.count
            let column = LibraryColumn(index: index, folder: columnFolders[index])
            configureColumn(column)
            column.setItems(contents(of: columnFolders[index]))
            columnsStack.addArrangedSubview(column)
            column.widthAnchor.constraint(equalToConstant: 220).isActive = true
            column.heightAnchor.constraint(equalTo: columnsStack.heightAnchor).isActive = true
            columnViews.append(column)
        }
        focusedColumn = min(focusedColumn, columnViews.count - 1)
        window?.layoutIfNeeded()
        if let last = columnViews.last {
            columnsScroll.contentView.scrollToVisible(last.frame)
        }
    }

    private func configureColumn(_ column: LibraryColumn) {
        column.isFolderCheck = { [weak self] in self?.isFolder($0) ?? false }
        column.onSelectionChange = { [weak self] column in
            guard let self, !self.isRebuildingColumns else { return }
            self.focusedColumn = column.index
            self.refreshPreviewIfVisible()
            let selected = column.selectedURLs
            if selected.count == 1, let url = selected.first, self.isFolder(url) {
                self.setColumnFolders(
                    Array(self.columnFolders.prefix(column.index + 1)) + [url],
                    rebuildFrom: column.index + 1
                )
            } else if self.columnFolders.count > column.index + 1 {
                self.setColumnFolders(
                    Array(self.columnFolders.prefix(column.index + 1)),
                    rebuildFrom: column.index + 1
                )
            }
        }
        column.onDoubleClick = { [weak self] url in
            guard let self, !self.isFolder(url) else { return }
            NSWorkspace.shared.open(url)
        }
        column.onMove = { [weak self] urls, destination in
            self?.moveURLs(urls, into: destination)
        }
        column.onSpace = { [weak self] in self?.togglePreview() }

        let menu = NSMenu()
        menu.delegate = self
        column.tableView.menu = menu
    }

    private func moveURLs(_ urls: [URL], into destination: URL) {
        for url in urls
        where url.standardizedFileURL != destination.standardizedFileURL
            && url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: target)
        }
        reloadAll()
    }

    private func reloadAll() {
        reloadGrid()
        var valid: [URL] = []
        for folder in columnFolders {
            guard FileManager.default.fileExists(atPath: folder.path) else { break }
            valid.append(folder)
        }
        if valid.isEmpty { valid = [GifConverter.outputDirectory] }
        columnFolders = valid
        isRebuildingColumns = true
        while columnViews.count > columnFolders.count {
            let column = columnViews.removeLast()
            columnsStack.removeArrangedSubview(column)
            column.removeFromSuperview()
        }
        for (index, column) in columnViews.enumerated() {
            column.setItems(contents(of: columnFolders[index]))
        }
        isRebuildingColumns = false
    }

    /// Live-refresh when recordings land or files change while the window is open.
    private func watch(folder: URL) {
        stopWatching()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reloadAll() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        folderWatcher = source
    }

    private func stopWatching() {
        folderWatcher?.cancel()
        folderWatcher = nil
    }

    // MARK: - Toolbar actions

    @objc private func goBack() {
        navigate(to: currentFolder.deletingLastPathComponent())
    }

    @objc private func modeChanged() {
        mode = ViewMode(rawValue: modeControl.selectedSegment) ?? .grid
        if mode == .columns {
            reloadAll()
        } else {
            reloadGrid()
        }
    }

    @objc private func revealCurrent() {
        NSWorkspace.shared.open(mode == .grid ? currentFolder : columnFolders.last ?? currentFolder)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              items.indices.contains(indexPath.item) else { return }
        let url = items[indexPath.item]
        if isFolder(url) {
            navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Context menu actions

    @objc private func contextNewFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name the new folder:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "New Folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var target = menuContext.folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = menuContext.folder.appendingPathComponent("\(name) \(counter)")
            counter += 1
        }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        reloadAll()
    }

    @objc private func contextPreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        let gifs = menuContext.urls.filter { !isFolder($0) }
        guard !gifs.isEmpty else { return }
        previewItems = gifs
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    @objc private func contextTrim() {
        let gifs = menuContext.urls.filter { !isFolder($0) }
        guard let gif = gifs.first else { return }

        Task {
            do {
                let (movURL, width) = try await Task.detached {
                    try GifImporter.makeVideo(from: gif)
                }.value
                await MainActor.run {
                    let folder = gif.deletingLastPathComponent()
                    let base = gif.deletingPathExtension().lastPathComponent
                    var target = folder.appendingPathComponent("\(base) trimmed.gif")
                    var counter = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent("\(base) trimmed \(counter).gif")
                        counter += 1
                    }
                    let controller = TrimWindowController(
                        videoURL: movURL, pointWidth: width, outputGifURL: target
                    ) { [weak self] result in
                        self?.trimController = nil
                        if case .failed(let error) = result {
                            self?.showError("Couldn't trim GIF", error)
                        }
                        self?.reloadAll()
                    }
                    self.trimController = controller
                    controller.show()
                }
            } catch {
                await MainActor.run { self.showError("Couldn't trim GIF", error) }
            }
        }
    }

    @objc private func contextCopy() {
        guard !menuContext.urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(menuContext.urls as [NSURL])
    }

    @objc private func contextReveal() {
        NSWorkspace.shared.activateFileViewerSelecting(menuContext.urls)
    }

    @objc private func contextTrash() {
        for url in menuContext.urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        reloadAll()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Context menus (built per click: empty space vs items)

extension LibraryWindowController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        var clickedURLs: [URL] = []
        var targetFolder = currentFolder

        if menu === gridMenu {
            targetFolder = currentFolder
            if let event = NSApp.currentEvent {
                let point = collectionView.convert(event.locationInWindow, from: nil)
                if let indexPath = collectionView.indexPathForItem(at: point) {
                    if !collectionView.selectionIndexPaths.contains(indexPath) {
                        collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                        collectionView.selectItems(at: [indexPath], scrollPosition: [])
                    }
                    clickedURLs = currentSelection()
                }
            }
        } else if let column = columnViews.first(where: { $0.tableView.menu === menu }) {
            targetFolder = column.folder
            let row = column.tableView.clickedRow
            if row >= 0, column.items.indices.contains(row) {
                if !column.tableView.selectedRowIndexes.contains(row) {
                    column.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                clickedURLs = column.selectedURLs
            }
        }

        menuContext = (clickedURLs, targetFolder)
        menu.removeAllItems()

        if clickedURLs.isEmpty {
            menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
        } else {
            let gifs = clickedURLs.filter { !isFolder($0) }
            let preview = menu.addItem(withTitle: "Preview", action: #selector(contextPreview), keyEquivalent: "")
            preview.isEnabled = !gifs.isEmpty
            let trim = menu.addItem(withTitle: "Trim…", action: #selector(contextTrim), keyEquivalent: "")
            trim.isEnabled = gifs.count == 1 && clickedURLs.count == 1
            menu.addItem(withTitle: "Copy to Clipboard", action: #selector(contextCopy), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Show in Finder", action: #selector(contextReveal), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(contextTrash), keyEquivalent: "")
        }
        menu.autoenablesItems = false
        for item in menu.items { item.target = self }
    }
}

// MARK: - Quick Look data source / delegate

extension LibraryWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems.indices.contains(index) ? previewItems[index] as NSURL : nil
    }
}

// MARK: - Grid data source / delegate

extension LibraryWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: LibraryCell.identifier, for: indexPath)
        guard let libraryCell = cell as? LibraryCell, items.indices.contains(indexPath.item) else { return cell }
        libraryCell.configure(with: items[indexPath.item], isFolder: isFolder(items[indexPath.item]))
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        refreshPreviewIfVisible()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        refreshPreviewIfVisible()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item] as NSURL : nil
    }

    private func draggedFileURLs(_ draggingInfo: NSDraggingInfo) -> [URL] {
        draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private func gridDropDestination(indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> URL? {
        if dropOperation == .on {
            guard items.indices.contains(indexPath.item), isFolder(items[indexPath.item]) else { return nil }
            return items[indexPath.item]
        }
        return currentFolder
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard let destination = gridDropDestination(
            indexPath: proposedIndexPath.pointee as IndexPath,
            dropOperation: dropOperation.pointee
        ) else { return [] }
        let movable = draggedFileURLs(draggingInfo).contains {
            $0.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL
                && $0.standardizedFileURL != destination.standardizedFileURL
        }
        return movable ? .move : []
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let destination = gridDropDestination(indexPath: indexPath, dropOperation: dropOperation) else {
            return false
        }
        moveURLs(draggedFileURLs(draggingInfo), into: destination)
        return true
    }
}

// MARK: - Miller column

final class LibraryColumn: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let index: Int
    let folder: URL
    private(set) var items: [URL] = []
    let tableView = ColumnTableView()

    var isFolderCheck: ((URL) -> Bool) = { _ in false }
    var onSelectionChange: ((LibraryColumn) -> Void)?
    var onDoubleClick: ((URL) -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onSpace: (() -> Void)? {
        didSet { tableView.onSpaceKey = onSpace }
    }

    var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    init(index: Int, folder: URL) {
        self.index = index
        self.folder = folder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.style = .plain

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(separator)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setItems(_ newItems: [URL]) {
        items = newItems
        tableView.reloadData()
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onDoubleClick?(items[row])
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let url = items[row]
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = url.lastPathComponent
        cell.imageView?.image = isFolderCheck(url)
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(forFile: url.path)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(self)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items.indices.contains(row) ? items[row] as NSURL : nil
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }

        var destination = folder
        if dropOperation == .on, items.indices.contains(row), isFolderCheck(items[row]) {
            destination = items[row]
        } else {
            tableView.setDropRow(-1, dropOperation: .on) // highlight the whole column
        }
        let movable = urls.contains {
            $0.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL
                && $0.standardizedFileURL != destination.standardizedFileURL
        }
        return movable ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        var destination = folder
        if dropOperation == .on, items.indices.contains(row), isFolderCheck(items[row]) {
            destination = items[row]
        }
        onMove?(urls, destination)
        return true
    }
}

/// Table that forwards Space to Quick Look.
final class ColumnTableView: NSTableView {
    var onSpaceKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onSpaceKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Space-key handling (grid)

final class KeyHandlingCollectionView: NSCollectionView {
    var onSpaceKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onSpaceKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Grid cell

final class LibraryCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryCell")

    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.unregisterDraggedTypes() // let the collection view own drag & drop

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(thumbView)
        root.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 96),
            thumbView.heightAnchor.constraint(equalToConstant: 88),
            nameLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
        ])
        view = root
    }

    func configure(with url: URL, isFolder: Bool) {
        nameLabel.stringValue = url.lastPathComponent
        if isFolder {
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 84, height: 78)
            thumbView.image = icon
        } else {
            thumbView.image = NSWorkspace.shared.icon(forFile: url.path)
            let itemURL = url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let image = NSImage(contentsOf: itemURL) else { return }
                DispatchQueue.main.async {
                    guard self?.nameLabel.stringValue == itemURL.lastPathComponent else { return }
                    self?.thumbView.image = image
                }
            }
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }
}
