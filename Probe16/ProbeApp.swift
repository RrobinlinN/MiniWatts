import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    @StateObject private var model = ProbeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var note = ""
    @Published var seconds = 30
    @Published var running = false
    @Published var status = "未采集"
    @Published var summary = ""
    @Published var fileURL: URL?
    @Published var preview = ""
    private(set) var text = ""

    /// Created once: a second HID client in the same process reads NaN.
    private let probe = Probe()

    func start() {
        guard !running else { return }
        running = true
        fileURL = nil
        // A two-minute run would otherwise be cut short by auto-lock.
        UIApplication.shared.isIdleTimerDisabled = true
        let note = self.note
        let seconds = self.seconds
        let probe = self.probe
        Probe.queue.async {
            let result = probe.collect(note: note, seconds: seconds) { message in
                DispatchQueue.main.async { self.status = message }
            }
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
                ?? Data("{\"error\": \"JSONSerialization failed\"}".utf8)
            DispatchQueue.main.async { self.finish(result, data: data, note: note) }
        }
    }

    private func finish(_ result: [String: Any], data: Data, note: String) {
        UIApplication.shared.isIdleTimerDisabled = false
        running = false

        let device = result["device"] as? [String: Any]
        let model = device?["model"] as? String ?? "unknown"
        let stamp = Self.stampFormatter.string(from: Date())
        let label = String(note.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(30))
        let name = ["MiniWattsProbe", model, stamp, label].filter { !$0.isEmpty }.joined(separator: "-") + ".json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            fileURL = url
            status = "完成：\(name)"
        } catch {
            status = "写文件失败：\(error.localizedDescription)，可用“复制全部文本”"
            fileURL = nil
        }

        text = String(decoding: data, as: UTF8.self)
        preview = String(text.prefix(3000))

        let inventory = (result["hidInventory"] as? [Any])?.count ?? 0
        let sensors = (result["sensors"] as? [Any])?.count ?? 0
        let registry = result["registry"] as? [String: Any]
        let battery = (registry?["IOPMPowerSource"] as? [String: Any])?["entries"] as? [[String: Any]]
        let batteryKeys = battery?.first?["keyCount"] as? Int ?? 0
        let sandboxed = device?["sandboxed"] as? Bool ?? true
        summary = """
        \(model) · \(device?["os"] as? String ?? "?")
        \(sandboxed ? "沙盒内" : "无沙盒")
        HID 服务 \(inventory) 个，其中传感器 \(sensors) 个
        IOPMPowerSource 属性 \(batteryKeys) 个
        文件 \(data.count / 1024) KB
        """
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct ContentView: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("备注，例如 USB-C 20W 45%", text: $model.note)
                    Picker("采样时长", selection: $model.seconds) {
                        Text("10 秒").tag(10)
                        Text("30 秒").tag(30)
                        Text("120 秒").tag(120)
                    }
                } header: {
                    Text("场景")
                } footer: {
                    Text("每次采集写一个 JSON 文件。序列号一类的字段已替换为 <redacted>。")
                }

                Section {
                    Button(model.running ? "采集中…" : "开始采集") { model.start() }
                        .disabled(model.running)
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let url = model.fileURL {
                    Section("结果") {
                        Text(model.summary).font(.footnote)
                        ShareLink(item: url) {
                            Label("分享 JSON 文件", systemImage: "square.and.arrow.up")
                        }
                        Button("复制全部文本") { UIPasteboard.general.string = model.text }
                    }
                    Section("预览（前 3000 字）") {
                        Text(model.preview)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("MiniWatts Probe")
        }
    }
}
