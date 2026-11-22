import AppKit
import SwiftUI

// MARK: - Design system and orb views
let ink = Color(red: 0.12, green: 0.20, blue: 0.28)
let muted = Color(red: 0.40, green: 0.51, blue: 0.60)
let ice = Color(red: 0.85, green: 0.92, blue: 0.97)

struct WaterOrb: View {
    var status: String = "idle"
    var size: CGFloat = 58
    var animated = true
    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
                    let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / breathPeriod) + 1) / 2
                    orb(phase: phase)
                }
            } else {
                orb(phase: 0.5)
            }
        }
        .accessibilityLabel("Dewy 蓝色水珠")
    }
    private func orb(phase: Double) -> some View {
        let scale = animated ? minimumScale + (maximumScale - minimumScale) * phase : 1
        return ZStack {
            Circle().fill(RadialGradient(colors: [.clear, Color(red: 0.43, green: 0.70, blue: 0.84).opacity(0.05), Color(red: 0.28, green: 0.56, blue: 0.73).opacity(0.24), .white.opacity(0.48)], center: .center, startRadius: size * 0.32, endRadius: size * 0.5))
            Circle().stroke(AngularGradient(colors: [.white.opacity(0.85), ice.opacity(0.55), Color.blue.opacity(0.5), .white.opacity(0.75)], center: .center), lineWidth: 1.2).padding(1)
            Circle().stroke(.white.opacity(animated ? 0.25 + 0.16 * phase : 0.33), lineWidth: 1).padding(size * 0.07)
            Ellipse().fill(.white.opacity(animated ? 0.52 + 0.18 * phase : 0.61)).frame(width: size * 0.17, height: size * 0.075).rotationEffect(.degrees(-38)).blur(radius: 1).offset(x: -size * 0.21, y: -size * 0.28)
            Circle().fill(.white.opacity(0.7)).frame(width: 2, height: 2).offset(x: size * 0.19, y: -size * 0.25)
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .offset(y: animated ? sin(phase * .pi * 2) * (status == "focus" ? 0.25 : 0.8) : 0)
    }
    private var breathPeriod: Double { status == "hydration" ? 1.45 : (status == "focus" ? 5.5 : (status == "sleepy" ? 6.2 : 4.8)) }
    private var minimumScale: CGFloat { status == "hydration" ? 0.955 : (status == "focus" ? 0.992 : (status == "sleepy" ? 0.986 : 0.968)) }
    private var maximumScale: CGFloat { status == "hydration" ? 1.05 : (status == "focus" ? 1.008 : (status == "sleepy" ? 1.014 : 1.032)) }
}

struct OrbView: View {
    @EnvironmentObject var store: DewyStore
    var onClick: () -> Void
    var body: some View {
        Button(action: onClick) {
            WaterOrb(status: store.status, size: 60, animated: !store.orbIsDragging)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("输入请求") { onClick() }
            Button("查看今日安排") { store.send("今日总结") ; onClick() }
            Button("开始专注") { store.appendMessage(ChatLine(role: .assistant, text: store.startFocus())); onClick() }
            Button("记录喝水") { store.appendMessage(ChatLine(role: .assistant, text: store.addWater(store.data.settings.cupMilliliters))); onClick() }
            Divider()
            Button("打开设置") { store.settingsRequested = true; onClick() }
            Divider()
            Button("退出 Dewy") { NSApp.terminate(nil) }
        }
    }
}

struct HoverCardView: View {
    @EnvironmentObject var store: DewyStore
    var onEnter: () -> Void
    var onLeave: () -> Void
    var openChat: () -> Void
    var focusInput: () -> Void
    var endFocus: () -> Void
    @State private var text = ""
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.proactiveNotice == nil ? headerText : "DEWY · 提醒")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(muted)
                Spacer()
                if store.focusIsRunning {
                    Button("结束") { endFocus() }.buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(muted)
                } else {
                    Button("OPEN") { openChat() }.buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(muted)
                }
            }
            if let notice = store.proactiveNotice {
                Text(notice.text).font(.system(size: 12)).foregroundStyle(ink).lineLimit(3)
            } else if store.focusIsRunning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("我会安静陪你专注，完成后再休息。")
                        .font(.system(size: 12)).foregroundStyle(ink).lineLimit(1)
                    Text(focusTaskText)
                        .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }
            } else {
                Text(careText).font(.system(size: 12)).foregroundStyle(ink).lineLimit(2)
            }
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .light)).foregroundStyle(muted)
                TextField("输入指令或内容...", text: $text, onCommit: submit).focused($inputFocused).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(ink)
                Button("记下", action: recordNote).buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(muted).help("保存为今天的工作记录")
                Button("SEND", action: submit).buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(muted)
            }
            .padding(.horizontal, 10).frame(height: 34).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 0.7))
        }
        .padding(14).frame(width: 330, height: 156)
        .background(.ultraThinMaterial.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.82), lineWidth: 0.8))
        .onHover { $0 ? onEnter() : onLeave() }
        .onChange(of: inputFocused) { focused in
            if focused { focusInput() }
        }
    }
    var statusTitle: String {
        switch store.status { case "focus": "FOCUS"; case "hydration": "HYDRATION REMINDED"; case "sleepy": "SLEEPY"; default: "GENTLE & IDLE" }
    }
    var headerText: String {
        store.focusIsRunning
            ? "FOCUS · \(store.formatDuration(store.focusSeconds))"
            : "STATUS: \(statusTitle)"
    }
    var focusTaskText: String {
        guard let session = store.data.focus.last(where: { $0.endedAt == nil }),
              !session.task.isEmpty,
              session.task != "未关联任务" else {
            return "专注进行中，暂未关联待办。"
        }
        return "正在推进：\(session.task)"
    }
    var careText: String {
        switch store.status { case "focus": "我会安静陪你专注，完成后再休息。"; case "hydration": "两个小时了，喝点水吧？"; case "sleepy": "夜深啦，眼睛该休息啦，明天再继续？"; default: "今天忙碌之余，也记得给自己一点休息时间。" }
    }
    func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        store.send(value)
    }
    func recordNote() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        store.appendMessage(ChatLine(role: .user, text: "随手记：\(value)"))
        store.appendMessage(ChatLine(role: .assistant, text: store.addWork(value)))
    }
}
