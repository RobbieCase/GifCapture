import AppKit
import Quartz
import UniformTypeIdentifiers

/// Finder-like browser for ~/Desktop/GifCaptures: thumbnail grid of GIFs and
/// folders, folder navigation, New Folder, drag GIFs onto folders to move them,
/// drag out to other apps, Quick Look on Space, and a context menu with
/// Preview / Trim / Copy.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private var currentFolder: URL = GifConverter.outputDirectory
    private var items: [URL] = []
    private var previewItems: [URL] = []
    private var trimController: TrimWindowController?

    private var collectionView: KeyHandlingCollectionView!
    private var backButton: NSButton!
    private var pathLabel: NSTextField!
    private var folderWatcher: DispatchSourceFileSystemObject?

    private var previewMenuItem: NSMenuItem!
    private var trimMenuItem: NSMenuItem!
    private var copyMenuItem: NSMenuItem!
    private var revealMenuItem: NSMenuItem!
    private var trashMenuItem: NSMenuItem!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GifCapture Library"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func show() {
        navigate(to: GifConverter.outputDirectory)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopWatching()
    }

    // MARK: - Quick Look plumbing

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    fileprivate func togglePreview() {
        let gifs = selectedURLs().filter { !isFolder($0) }
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !gifs.isEmpty else { return }
        previewItems = gifs
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    private func refreshPreviewIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        let gifs = selectedURLs().filter { !isFolder($0) }
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

        let newFolderButton = NSButton(title: "New Folder", target: self, action: #selector(newFolder))
        newFolderButton.bezelStyle = .texturedRounded

        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealCurrent))
        revealButton.bezelStyle = .texturedRounded

        let topBar = NSStackView(views: [backButton, pathLabel, NSView(), newFolderButton, revealButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        topBar.translatesAutoresizingMaskIntoConstraints = false

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

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(topBar)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        previewMenuItem = menu.addItem(withTitle: "Preview", action: #selector(contextPreview), keyEquivalent: "")
        trimMenuItem = menu.addItem(withTitle: "Trim…", action: #selector(contextTrim), keyEquivalent: "")
        copyMenuItem = menu.addItem(withTitle: "Copy to Clipboard", action: #selector(contextCopy), keyEquivalent: "")
        menu.addItem(.separator())
        revealMenuItem = menu.addItem(withTitle: "Show in Finder", action: #selector(contextReveal), keyEquivalent: "")
        menu.addItem(.separator())
        trashMenuItem = menu.addItem(withTitle: "Move to Trash", action: #selector(contextTrash), keyEquivalent: "")
        for item in menu.items { item.target = self }
        collectionView.menu = menu
    }

    // MARK: - Data

    private func navigate(to folder: URL) {
        currentFolder = folder
        reload()
        watch(folder: folder)

        let base = GifConverter.outputDirectory.path
        let relative = folder.path.replacingOccurrences(of: base, with: "GifCaptures")
        pathLabel.stringValue = relative.replacingOccurrences(of: "/", with: " › ")
        backButton.isEnabled = folder.standardizedFileURL != GifConverter.outputDirectory.standardizedFileURL
    }

    private func reload() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: currentFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let folders = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let gifs = contents
            .filter { $0.pathExtension.lowercased() == "gif" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
        items = folders + gifs
        collectionView.reloadData()
    }

    /// Live-refresh when recordings land or files change while the window is open.
    private func watch(folder: URL) {
        stopWatching()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        folderWatcher = source
    }

    private func stopWatching() {
        folderWatcher?.cancel()
        folderWatcher = nil
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Parent ("⬆ Back") pseudo-item

    /// Inside a subfolder, item 0 is a "Back" tile: double-click navigates up,
    /// and dropping GIFs on it moves them to the enclosing folder.
    private var showParentItem: Bool {
        currentFolder.standardizedFileURL != GifConverter.outputDirectory.standardizedFileURL
    }

    private var parentOffset: Int { showParentItem ? 1 : 0 }

    private func isParentItem(_ indexPath: IndexPath) -> Bool {
        showParentItem && indexPath.item == 0
    }

    private func url(at indexPath: IndexPath) -> URL? {
        let index = indexPath.item - parentOffset
        return items.indices.contains(index) ? items[index] : nil
    }

    private func selectedURLs() -> [URL] {
        collectionView.selectionIndexPaths
            .filter { !isParentItem($0) }
            .compactMap { url(at: $0) }
    }

    // MARK: - Toolbar actions

    @objc private func goBack() {
        navigate(to: currentFolder.deletingLastPathComponent())
    }

    @objc private func newFolder() {
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
        var target = currentFolder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = currentFolder.appendingPathComponent("\(name) \(counter)")
            counter += 1
        }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        reload()
    }

    @objc private func revealCurrent() {
        NSWorkspace.shared.open(currentFolder)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        if isParentItem(indexPath) {
            goBack()
            return
        }
        guard let url = url(at: indexPath) else { return }
        if isFolder(url) {
            navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Context menu actions

    @objc private func contextPreview() {
        togglePreview()
    }

    @objc private func contextTrim() {
        let gifs = selectedURLs().filter { !isFolder($0) }
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
                        self?.reload()
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
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @objc private func contextReveal() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedURLs())
    }

    @objc private func contextTrash() {
        for url in selectedURLs() {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        reload()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Menu delegate (right-click selects the item under the cursor)

extension LibraryWindowController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let event = NSApp.currentEvent {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            if let indexPath = collectionView.indexPathForItem(at: point),
               !isParentItem(indexPath),
               !collectionView.selectionIndexPaths.contains(indexPath) {
                collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                collectionView.selectItems(at: [indexPath], scrollPosition: [])
            }
        }
        let urls = selectedURLs()
        let gifs = urls.filter { !isFolder($0) }
        previewMenuItem.isEnabled = !gifs.isEmpty
        trimMenuItem.isEnabled = gifs.count == 1 && urls.count == 1
        copyMenuItem.isEnabled = !urls.isEmpty
        revealMenuItem.isEnabled = !urls.isEmpty
        trashMenuItem.isEnabled = !urls.isEmpty
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

// MARK: - Collection view data source / delegate

extension LibraryWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count + parentOffset
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: LibraryCell.identifier, for: indexPath)
        guard let libraryCell = cell as? LibraryCell else { return cell }
        if isParentItem(indexPath) {
            libraryCell.configureAsParent()
        } else if let url = url(at: indexPath) {
            libraryCell.configure(with: url, isFolder: isFolder(url))
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        refreshPreviewIfVisible()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        refreshPreviewIfVisible()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !isParentItem(indexPath) else { return nil } // the Back tile isn't draggable
        return url(at: indexPath) as NSURL?
    }

    private func draggedFileURLs(_ draggingInfo: NSDraggingInfo) -> [URL] {
        draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    /// Destination folder for a proposed drop, or nil if the drop is invalid:
    /// onto a folder tile or the Back tile moves there; a drop on the grid
    /// background moves into the current folder (for drags from Finder or
    /// from another folder).
    private func dropDestination(indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> URL? {
        if dropOperation == .on {
            if isParentItem(indexPath) {
                return currentFolder.deletingLastPathComponent()
            }
            if let target = url(at: indexPath), isFolder(target) {
                return target
            }
            return nil
        }
        return currentFolder
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard let destination = dropDestination(
            indexPath: proposedIndexPath.pointee as IndexPath,
            dropOperation: dropOperation.pointee
        ) else { return [] }
        // Only allow when at least one dragged file would actually move.
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
        guard let destination = dropDestination(indexPath: indexPath, dropOperation: dropOperation) else {
            return false
        }
        var moved = false
        for url in draggedFileURLs(draggingInfo)
        where url.standardizedFileURL != destination.standardizedFileURL
            && url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                moved = true
            }
        }
        reload()
        return moved
    }
}

// MARK: - Space-key handling

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

    func configureAsParent() {
        nameLabel.stringValue = "⬆ Back"
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 84, height: 78)
        thumbView.image = icon
        thumbView.alphaValue = 0.55
    }

    func configure(with url: URL, isFolder: Bool) {
        thumbView.alphaValue = 1
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
