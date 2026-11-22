import AppKit
import SwiftUI

// MARK: - Floating desktop panels

final class DewyChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class DewyOrbPanel: NSPanel {
    var onOrbClick: (() -> Void)?
    var onFrameChanged: ((NSPoint) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingOrb = false
    private var hoverTrackingArea: NSTrackingArea?
    private let dragThreshold: CGFloat = 4

    func installHoverTrackingArea() {
        guard let contentView, hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: NSRect(x: 8, y: 8, width: 60, height: 60),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where isInsideOrb(event):
            mouseDownLocation = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
            isDraggingOrb = false
            return
        case .leftMouseDragged:
            guard let mouseDownLocation, let dragStartOrigin else {
                super.sendEvent(event)
                return
            }
            let currentLocation = NSEvent.mouseLocation
            let dx = currentLocation.x - mouseDownLocation.x
            let dy = currentLocation.y - mouseDownLocation.y
            if !isDraggingOrb && hypot(dx, dy) >= dragThreshold {
                isDraggingOrb = true
                onDragStateChanged?(true)
            }
            if isDraggingOrb {
                setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
                onFrameChanged?(frame.origin)
            }
            return
        case .leftMouseUp where mouseDownLocation != nil:
            let wasDragging = isDraggingOrb
            mouseDownLocation = nil
            dragStartOrigin = nil
            isDraggingOrb = false
            if wasDragging {
                onDragStateChanged?(false)
                onDragEnded?()
            } else {
                onOrbClick?()
            }
            return
        default:
            super.sendEvent(event)
        }
    }

    private func isInsideOrb(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds
        let radius = min(bounds.width, bounds.height) / 2 - 8
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        return dx * dx + dy * dy <= radius * radius
    }
}

@MainActor
final class DewyAppDelegate: NSObject, NSApplicationDelegate {
    let store = DewyStore()
    var orbPanel: NSPanel!
    var hoverPanel: NSPanel!
    var chatPanel: NSPanel!
    var hideWork: DispatchWorkItem?
    var proactiveDismissWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let otherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.dewy.private-agent")
            .first(where: { $0.processIdentifier != currentPID }) {
            _ = otherInstance.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        buildPanels()
        positionPanels()
        store.onProactiveMessage = { [weak self] notice in self?.presentProactiveMessage(notice) }
        store.startMonitoring()
        orbPanel.orderFrontRegardless()
        NSApp.mainMenu = makeMenu()
    }

    func buildPanels() {
        let orb = DewyOrbPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 76, height: 76)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        orbPanel = orb
        configurePanel(orb, view: OrbView(onClick: { [weak self] in self?.showChat() }))
        orb.installHoverTrackingArea()
        orb.onOrbClick = { [weak self] in self?.showChat() }
        orb.onHoverChanged = { [weak self] inside in self?.orbHover(inside) }
        orb.onFrameChanged = { [weak self] origin in self?.setOrbOrigin(origin) }
        orb.onDragStateChanged = { [weak self] dragging in self?.store.orbIsDragging = dragging }
        orb.onDragEnded = { [weak self] in self?.finishOrbDrag() }
        hoverPanel = panel(size: NSSize(width: 330, height: 156), view: HoverCardView(onEnter: { [weak self] in
            self?.cancelHide()
            self?.cancelProactiveDismiss()
        }, onLeave: { [weak self] in self?.scheduleHide() }, openChat: { [weak self] in self?.showChat() }, focusInput: { [weak self] in self?.focusHoverInput() }, endFocus: { [weak self] in
            guard let self else { return }
            self.store.appendMessage(ChatLine(role: .assistant, text: self.store.stopFocus()))
        }), acceptsKeyboardInput: true)
        chatPanel = panel(size: NSSize(width: 420, height: 420), view: ChatWindowView(minimize: { [weak self] in self?.hideChat() }), acceptsKeyboardInput: true)
    }

    func panel<Content: View>(size: NSSize, view: Content, acceptsKeyboardInput: Bool = false) -> NSPanel {
        let result: NSPanel
        if acceptsKeyboardInput {
            result = DewyChatPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        } else {
            result = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
        configurePanel(result, view: view)
        return result
    }

    private func configurePanel<Content: View>(_ result: NSPanel, view: Content) {
        result.isFloatingPanel = true; result.level = .floating; result.backgroundColor = .clear; result.isOpaque = false; result.hasShadow = false
        result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        result.isReleasedWhenClosed = false
        result.contentView = NSHostingView(rootView: view.environmentObject(store))
    }

    func positionPanels() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let savedX = UserDefaults.standard.object(forKey: "dewy.orbOriginX") as? CGFloat
        let savedY = UserDefaults.standard.object(forKey: "dewy.orbOriginY") as? CGFloat
        let origin = NSPoint(x: savedX ?? frame.maxX - 90, y: savedY ?? frame.minY + 24)
        setOrbOrigin(origin)
        chatPanel.setFrameOrigin(NSPoint(x: frame.maxX - 444, y: frame.minY + 106))
    }

    private func setOrbOrigin(_ origin: NSPoint) {
        let size = orbPanel.frame.size
        let proposedCenter = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.contains(proposedCenter) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        orbPanel.setFrameOrigin(NSPoint(x: x, y: y))
        positionHoverPanel()
    }

    private func positionHoverPanel(avoidingChat: Bool = false) {
        guard orbPanel != nil, hoverPanel != nil else { return }
        let orbFrame = orbPanel.frame
        let center = NSPoint(x: orbFrame.midX, y: orbFrame.midY)
        let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hoverSize = hoverPanel.frame.size
        let gap: CGFloat = 12
        if avoidingChat, chatPanel.isVisible {
            let chat = chatPanel.frame
            let centeredY = min(max(orbFrame.midY - hoverSize.height / 2, visibleFrame.minY), visibleFrame.maxY - hoverSize.height)
            let candidates = [
                NSPoint(x: chat.minX - hoverSize.width - gap, y: centeredY),
                NSPoint(x: chat.maxX + gap, y: centeredY),
                NSPoint(x: orbFrame.midX - hoverSize.width / 2, y: chat.maxY + gap),
                NSPoint(x: orbFrame.midX - hoverSize.width / 2, y: chat.minY - hoverSize.height - gap)
            ].map { candidate in
                NSPoint(
                    x: min(max(candidate.x, visibleFrame.minX), visibleFrame.maxX - hoverSize.width),
                    y: min(max(candidate.y, visibleFrame.minY), visibleFrame.maxY - hoverSize.height)
                )
            }
            let best = candidates.min { overlapArea(for: $0, size: hoverSize, with: chat) < overlapArea(for: $1, size: hoverSize, with: chat) } ?? candidates[0]
            hoverPanel.setFrameOrigin(best)
            return
        }
        let aboveY = orbFrame.maxY + gap
        let preferredY = aboveY + hoverSize.height <= visibleFrame.maxY
            ? aboveY
            : orbFrame.minY - hoverSize.height - gap
        let x = min(max(orbFrame.midX - hoverSize.width / 2, visibleFrame.minX), visibleFrame.maxX - hoverSize.width)
        let y = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - hoverSize.height)
        hoverPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func overlapArea(for origin: NSPoint, size: NSSize, with frame: NSRect) -> CGFloat {
        let overlapWidth = max(0, min(origin.x + size.width, frame.maxX) - max(origin.x, frame.minX))
        let overlapHeight = max(0, min(origin.y + size.height, frame.maxY) - max(origin.y, frame.minY))
        return overlapWidth * overlapHeight
    }

    private func finishOrbDrag() {
        store.orbIsDragging = false
        UserDefaults.standard.set(orbPanel.frame.origin.x, forKey: "dewy.orbOriginX")
        UserDefaults.standard.set(orbPanel.frame.origin.y, forKey: "dewy.orbOriginY")
    }

    func orbHover(_ inside: Bool) {
        if inside {
            cancelHide()
            guard !chatPanel.isVisible || store.proactiveNotice != nil else { hoverPanel.orderOut(nil); return }
            positionHoverPanel(avoidingChat: chatPanel.isVisible)
            hoverPanel.orderFrontRegardless()
        }
        else { scheduleHide() }
    }
    func scheduleHide() {
        hideWork?.cancel()
        let noticeID = store.proactiveNotice?.id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverPanel.orderOut(nil)
            if let noticeID { self.store.clearProactiveNotice(id: noticeID) }
        }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func cancelHide() { hideWork?.cancel(); hideWork = nil }
    func cancelProactiveDismiss() { proactiveDismissWork?.cancel(); proactiveDismissWork = nil }
    func presentProactiveMessage(_ notice: DewyProactiveNotice) {
        cancelHide()
        cancelProactiveDismiss()
        positionHoverPanel(avoidingChat: chatPanel.isVisible)
        hoverPanel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.store.proactiveNotice?.id == notice.id else { return }
            let mouse = NSEvent.mouseLocation
            if self.orbPanel.frame.contains(mouse) { return }
            self.hoverPanel.orderOut(nil)
            self.store.clearProactiveNotice(id: notice.id)
        }
        proactiveDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }
    func focusHoverInput() {
        NSApp.activate(ignoringOtherApps: true)
        hoverPanel.makeKeyAndOrderFront(nil)
    }
    func showChat() {
        cancelHide()
        cancelProactiveDismiss()
        hoverPanel.orderOut(nil)
        if let noticeID = store.proactiveNotice?.id { store.clearProactiveNotice(id: noticeID) }
        NSApp.activate(ignoringOtherApps: true)
        chatPanel.makeKeyAndOrderFront(nil)
    }
    func hideChat() {
        chatPanel.orderOut(nil)
        orbPanel.orderFrontRegardless()
        if orbPanel.frame.contains(NSEvent.mouseLocation) { orbHover(true) }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 Dewy", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Dewy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
            store.save()
        }

    @objc func openFromMenu() { showChat() }
}

@main
struct DewyMain {
    @MainActor private static var retainedDelegate: DewyAppDelegate?
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = DewyAppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
