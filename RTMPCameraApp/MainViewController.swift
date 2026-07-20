import UIKit
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

enum VideoSourceType: Int {
    case realCamera = 0
    case rtmpStream = 1
    case localVideo = 2
}

class MainViewController: UIViewController {

    // UI
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let statusCard = UIView()
    private let statusIndicator = UIView()
    private let statusTitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let versionLabel = UILabel()

    private let sourceCard = UIView()
    private let sourceTitleLabel = UILabel()
    let realCameraBtn = UIButton(type: .system)
    let rtmpBtn = UIButton(type: .system)
    let localVideoBtn = UIButton(type: .system)
    private var sourceButtons: [UIButton] { [realCameraBtn, rtmpBtn, localVideoBtn] }

    private let rtmpCard = UIView()
    private let rtmpURLLabel = UILabel()
    private let rtmpCopyButton = UIButton(type: .system)
    private let rtmpHintLabel = UILabel()

    private let localVideoCard = UIView()
    private let loopSwitch = UISwitch()
    private let selectVideoButton = UIButton(type: .system)
    private let localVideoPathLabel = UILabel()

    private let injectionCard = UIView()
    private let videoInjectionSwitch = UISwitch()
    private let audioInjectionSwitch = UISwitch()

    private let logCard = UIView()
    private let logTextView = UITextView()
    private let clearLogBtn = UIButton(type: .system)

    private let floatBtn = UIButton(type: .system)
    private let previewView = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureSession: AVCaptureSession?
    private let applyButton = UIButton(type: .system)

    // State
    private var currentSource: VideoSourceType = .realCamera
    private var rtmpURL: String = ""
    private var localVideoPath: String = ""
    private var videoInjectionOn: Bool = true
    private var audioInjectionOn: Bool = false
    private var loopEnabled: Bool = true
    private var phoneIP: String = ""
    private var logLines: [String] = []
    private var logPollTimer: Timer?
    private let sharedFrameQueue = DispatchQueue(label: "com.rtmpcamera.app")
    private let defaultRTMPPort = 1935
    private let appVersion = "1.0.2"

    override func viewDidLoad() {
        super.viewDidLoad()
        detectLocalIP()
        setupUI()
        loadSavedConfig()
        startCameraPreview()
        startLogPolling()
        addLog("App 启动 v\(appVersion)")
    }

    deinit {
        logPollTimer?.invalidate()
        captureSession?.stopRunning()
    }

    // MARK: - IP
    private func detectLocalIP() {
        var addr = "192.168.1.100"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var ptr = first
            while ptr.pointee.ifa_next != nil {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" || name == "pdp_ip0" {
                    let sa = ptr.pointee.ifa_addr.pointee
                    if sa.sa_family == UInt8(AF_INET) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: host)
                            if ip != "127.0.0.1" && (ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")) {
                                addr = ip
                                if name == "en0" { break }
                            }
                        }
                    }
                }
                ptr = ptr.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        phoneIP = addr
        rtmpURL = "rtmp://\(addr):\(defaultRTMPPort)/live/stream"
    }

    // MARK: - Log
    private func addLog(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)"
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        DispatchQueue.main.async {
            self.logTextView.text = self.logLines.joined(separator: "\n")
            let bottom = NSMakeRange((self.logTextView.text as NSString).length - 1, 1)
            if bottom.location < (self.logTextView.text as NSString).length {
                self.logTextView.scrollRangeToVisible(bottom)
            }
        }
    }

    private func startLogPolling() {
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollLogFromDaemon()
        }
    }

    private func pollLogFromDaemon() {
        sharedFrameQueue.async { [weak self] in
            guard let self = self else { return }
            let fd = shm_open(LOG_MEMORY_NAME, O_RDONLY, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            let size = MemoryLayout<SharedLogBuffer>.size
            let ptr = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
            guard ptr != MAP_FAILED else { return }
            defer { munmap(ptr, size) }

            let logBuf = ptr!.bindMemory(to: SharedLogBuffer.self, capacity: 1)
            let total = Int(logBuf.pointee.totalCount)
            let start = max(0, total - 20)
            for i in start..<total {
                let idx = i % Int(MAX_LOG_ENTRIES)
                // Access entries array via raw pointer (C fixed-size array → Swift tuple)
                let srcRaw = withUnsafeBytes(of: logBuf.pointee.entries) { raw -> UInt32 in
                    let entryOffset = idx * MemoryLayout<SharedLogBuffer.LogEntry>.stride
                    return raw.load(fromByteOffset: entryOffset + 8, as: UInt32.self)
                }
                let msgPtr = withUnsafeBytes(of: logBuf.pointee.entries) { raw -> UnsafePointer<CChar> in
                    let entryOffset = idx * MemoryLayout<SharedLogBuffer.LogEntry>.stride
                    return raw.baseAddress!.advanced(by: entryOffset + 12).assumingMemoryBound(to: CChar.self)
                }
                let msg = String(cString: msgPtr)
                if !msg.isEmpty {
                    let src = ["Daemon","Tweak","App"][Int(srcRaw) % 3]
                    DispatchQueue.main.async { self.addLog("[\(src)] \(msg)") }
                }
            }
        }
    }

    @objc private func clearLog() {
        logLines.removeAll()
        logTextView.text = ""
        addLog("日志已清空")
    }

    // MARK: - UI
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "虚拟摄像头"
        navigationController?.navigationBar.prefersLargeTitles = false

        let resetBtn = UIBarButtonItem(title: "还原", style: .plain, target: self, action: #selector(resetAllSettings))
        navigationItem.rightBarButtonItem = resetBtn

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0)
        scrollView.addSubview(contentView)

        var y: CGFloat = 12
        let w = view.bounds.width - 32

        // Version
        versionLabel.frame = CGRect(x: 20, y: y, width: w, height: 16)
        versionLabel.text = "RTMPCamera v\(appVersion)"
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabel
        versionLabel.textAlignment = .center
        contentView.addSubview(versionLabel)
        y += 20

        // Status card
        setupCard(statusCard, at: &y, w: w, h: 64)
        contentView.addSubview(statusCard)
        statusIndicator.frame = CGRect(x: 14, y: 14, width: 12, height: 12)
        statusIndicator.layer.cornerRadius = 6
        statusIndicator.backgroundColor = .systemGreen
        statusCard.addSubview(statusIndicator)
        statusTitleLabel.frame = CGRect(x: 34, y: 10, width: 200, height: 18)
        statusTitleLabel.text = "虚拟摄像头状态"
        statusTitleLabel.font = .boldSystemFont(ofSize: 14)
        statusCard.addSubview(statusTitleLabel)
        statusLabel.frame = CGRect(x: 14, y: 34, width: w - 28, height: 18)
        statusLabel.text = "当前: 真实摄像头 | 守护进程: 等待中"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusCard.addSubview(statusLabel)

        // Source selection
        setupCard(sourceCard, at: &y, w: w, h: 100)
        contentView.addSubview(sourceCard)
        sourceTitleLabel.frame = CGRect(x: 14, y: 8, width: w - 28, height: 18)
        sourceTitleLabel.text = "视频源选择"
        sourceTitleLabel.font = .boldSystemFont(ofSize: 14)
        sourceCard.addSubview(sourceTitleLabel)
        let btnW = (w - 48) / 3
        let btns: [(UIButton, String, String, VideoSourceType)] = [
            (realCameraBtn, "🎥", "真实摄像头", .realCamera),
            (rtmpBtn, "📡", "RTMP推流", .rtmpStream),
            (localVideoBtn, "📁", "本地视频", .localVideo),
        ]
        for (i, (btn, icon, title, _)) in btns.enumerated() {
            btn.frame = CGRect(x: CGFloat(14 + Int(btnW + 10) * i), y: 34, width: btnW, height: 54)
            btn.setTitle("\(icon)\n\(title)", for: .normal)
            btn.titleLabel?.numberOfLines = 2
            btn.titleLabel?.textAlignment = .center
            btn.titleLabel?.font = .systemFont(ofSize: 11)
            btn.backgroundColor = .systemGray6
            btn.layer.cornerRadius = 10
            btn.addTarget(self, action: #selector(sourceBtnTapped(_:)), for: .touchUpInside)
            sourceCard.addSubview(btn)
        }

        // RTMP card
        setupCard(rtmpCard, at: &y, w: w, h: 100)
        contentView.addSubview(rtmpCard)
        let rl = UILabel(frame: CGRect(x: 14, y: 8, width: w-28, height: 18))
        rl.text = "📡 RTMP 推流接收"
        rl.font = .boldSystemFont(ofSize: 14); rtmpCard.addSubview(rl)
        rtmpURLLabel.frame = CGRect(x: 14, y: 32, width: w - 80, height: 20)
        rtmpURLLabel.text = rtmpURL
        rtmpURLLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rtmpURLLabel.textColor = .systemBlue
        rtmpURLLabel.adjustsFontSizeToFitWidth = true; rtmpCard.addSubview(rtmpURLLabel)
        rtmpCopyButton.frame = CGRect(x: w - 62, y: 29, width: 52, height: 26)
        rtmpCopyButton.setTitle("复制", for: .normal)
        rtmpCopyButton.backgroundColor = .systemBlue
        rtmpCopyButton.setTitleColor(.white, for: .normal)
        rtmpCopyButton.layer.cornerRadius = 7
        rtmpCopyButton.titleLabel?.font = .systemFont(ofSize: 12)
        rtmpCopyButton.addTarget(self, action: #selector(copyRTMPURL), for: .touchUpInside)
        rtmpCard.addSubview(rtmpCopyButton)
        rtmpHintLabel.frame = CGRect(x: 14, y: 58, width: w - 28, height: 32)
        rtmpHintLabel.text = "将此地址填入 OBS「推流」→ 自定义服务器"
        rtmpHintLabel.font = .systemFont(ofSize: 11)
        rtmpHintLabel.textColor = .secondaryLabel; rtmpHintLabel.numberOfLines = 2
        rtmpCard.addSubview(rtmpHintLabel)

        // Local video card
        setupCard(localVideoCard, at: &y, w: w, h: 120)
        contentView.addSubview(localVideoCard)
        let ll = UILabel(frame: CGRect(x: 14, y: 8, width: 100, height: 18))
        ll.text = "循环播放"; ll.font = .boldSystemFont(ofSize: 14)
        localVideoCard.addSubview(ll)
        loopSwitch.frame = CGRect(x: w - 65, y: 6, width: 51, height: 31)
        loopSwitch.isOn = loopEnabled
        loopSwitch.addTarget(self, action: #selector(loopToggled), for: .valueChanged)
        localVideoCard.addSubview(loopSwitch)
        let sep = UIView(frame: CGRect(x: 14, y: 38, width: w-28, height: 1))
        sep.backgroundColor = .separator; localVideoCard.addSubview(sep)
        let lv = UILabel(frame: CGRect(x: 14, y: 44, width: 100, height: 18))
        lv.text = "选择视频"; lv.font = .boldSystemFont(ofSize: 14)
        localVideoCard.addSubview(lv)
        selectVideoButton.frame = CGRect(x: w - 110, y: 40, width: 96, height: 30)
        selectVideoButton.setTitle("选择 MP4", for: .normal)
        selectVideoButton.backgroundColor = .systemIndigo
        selectVideoButton.setTitleColor(.white, for: .normal)
        selectVideoButton.layer.cornerRadius = 7
        selectVideoButton.titleLabel?.font = .systemFont(ofSize: 12)
        selectVideoButton.addTarget(self, action: #selector(selectLocalVideo), for: .touchUpInside)
        localVideoCard.addSubview(selectVideoButton)
        localVideoPathLabel.frame = CGRect(x: 14, y: 78, width: w-28, height: 32)
        localVideoPathLabel.text = "未选择（仅 MP4）"
        localVideoPathLabel.font = .systemFont(ofSize: 12)
        localVideoPathLabel.textColor = .secondaryLabel; localVideoPathLabel.numberOfLines = 2
        localVideoCard.addSubview(localVideoPathLabel)

        // Injection card
        setupCard(injectionCard, at: &y, w: w, h: 68)
        contentView.addSubview(injectionCard)
        let il = UILabel(frame: CGRect(x: 14, y: 8, width: 200, height: 18))
        il.text = "注入控制"; il.font = .boldSystemFont(ofSize: 14)
        injectionCard.addSubview(il)
        let vl = UILabel(frame: CGRect(x: 14, y: 36, width: 80, height: 22))
        vl.text = "注入视频"; vl.font = .systemFont(ofSize: 13)
        injectionCard.addSubview(vl)
        videoInjectionSwitch.frame = CGRect(x: w - 65, y: 33, width: 51, height: 31)
        videoInjectionSwitch.isOn = videoInjectionOn
        videoInjectionSwitch.addTarget(self, action: #selector(injectionToggled), for: .valueChanged)
        injectionCard.addSubview(videoInjectionSwitch)
        let al = UILabel(frame: CGRect(x: 140, y: 36, width: 80, height: 22))
        al.text = "注入音频"; al.font = .systemFont(ofSize: 13)
        injectionCard.addSubview(al)
        audioInjectionSwitch.frame = CGRect(x: w - 170, y: 33, width: 51, height: 31)
        audioInjectionSwitch.isOn = audioInjectionOn
        audioInjectionSwitch.addTarget(self, action: #selector(injectionToggled), for: .valueChanged)
        injectionCard.addSubview(audioInjectionSwitch)

        // Preview
        setupCard(previewView, at: &y, w: w, h: 140)
        previewView.clipsToBounds = true; previewView.backgroundColor = .black
        contentView.addSubview(previewView)
        let ph = UILabel(frame: CGRect(x: 10, y: previewView.bounds.height - 20, width: w-20, height: 14))
        ph.text = "预览"; ph.font = .systemFont(ofSize: 10)
        ph.textColor = .white.withAlphaComponent(0.5)
        ph.autoresizingMask = [.flexibleTopMargin, .flexibleWidth]
        previewView.addSubview(ph)

        // Buttons row
        y += 4
        floatBtn.frame = CGRect(x: 14, y: y, width: (w - 24) / 2, height: 40)
        floatBtn.setTitle("⚪ 悬浮窗", for: .normal)
        floatBtn.backgroundColor = .systemGray
        floatBtn.setTitleColor(.white, for: .normal)
        floatBtn.layer.cornerRadius = 9
        floatBtn.titleLabel?.font = .boldSystemFont(ofSize: 13)
        floatBtn.addTarget(self, action: #selector(toggleFloatingWindow), for: .touchUpInside)
        contentView.addSubview(floatBtn)
        applyButton.frame = CGRect(x: (w - 24) / 2 + 22, y: y, width: (w - 24) / 2, height: 40)
        applyButton.setTitle("应用设置", for: .normal)
        applyButton.backgroundColor = .systemBlue
        applyButton.setTitleColor(.white, for: .normal)
        applyButton.layer.cornerRadius = 9
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 13)
        applyButton.addTarget(self, action: #selector(applySettings), for: .touchUpInside)
        contentView.addSubview(applyButton)
        y += 50

        // Log panel
        setupCard(logCard, at: &y, w: w, h: 180)
        contentView.addSubview(logCard)
        let logTitle = UILabel(frame: CGRect(x: 14, y: 6, width: 100, height: 18))
        logTitle.text = "📋 运行日志"; logTitle.font = .boldSystemFont(ofSize: 14)
        logCard.addSubview(logTitle)
        clearLogBtn.frame = CGRect(x: w - 60, y: 4, width: 50, height: 22)
        clearLogBtn.setTitle("清空", for: .normal)
        clearLogBtn.titleLabel?.font = .systemFont(ofSize: 11)
        clearLogBtn.addTarget(self, action: #selector(clearLog), for: .touchUpInside)
        logCard.addSubview(clearLogBtn)
        logTextView.frame = CGRect(x: 10, y: 26, width: w - 20, height: 146)
        logTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .label
        logTextView.backgroundColor = .systemGray6
        logTextView.isEditable = false
        logTextView.layer.cornerRadius = 6
        logCard.addSubview(logTextView)

        y += 16
        contentView.frame.size.height = y
        scrollView.contentSize = contentView.frame.size

        updateCardVisibility()
        updateSourceButtons()
    }

    private func setupCard(_ card: UIView, at y: inout CGFloat, w: CGFloat, h: CGFloat) {
        card.frame = CGRect(x: 16, y: y, width: w, height: h)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 11
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.04
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 5
        y += h + 10
    }

    private func startCameraPreview() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .medium
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              let session = captureSession, session.canAddInput(input) else { return }
        session.addInput(input)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]; layer.frame = previewView.bounds
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func updateCardVisibility() {
        rtmpCard.isHidden = (currentSource != .rtmpStream)
        localVideoCard.isHidden = (currentSource != .localVideo)
    }

    private func updateSourceButtons() {
        for btn in sourceButtons { btn.backgroundColor = .systemGray6; btn.setTitleColor(.label, for: .normal) }
        switch currentSource {
        case .realCamera: realCameraBtn.backgroundColor = .systemBlue; realCameraBtn.setTitleColor(.white, for: .normal)
        case .rtmpStream: rtmpBtn.backgroundColor = .systemBlue; rtmpBtn.setTitleColor(.white, for: .normal)
        case .localVideo: localVideoBtn.backgroundColor = .systemBlue; localVideoBtn.setTitleColor(.white, for: .normal)
        }
    }

    @objc private func sourceBtnTapped(_ sender: UIButton) {
        if sender == realCameraBtn { currentSource = .realCamera }
        else if sender == rtmpBtn { currentSource = .rtmpStream }
        else if sender == localVideoBtn { currentSource = .localVideo }
        updateCardVisibility(); updateSourceButtons()
        addLog("切换视频源: \(["真实摄像头","RTMP推流","本地视频"][currentSource.rawValue])")
    }

    @objc private func resetAllSettings() {
        let alert = UIAlertController(title: "还原所有设置", message: "恢复到系统默认配置", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定还原", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.currentSource = .realCamera; self.localVideoPath = ""
            self.videoInjectionOn = true; self.audioInjectionOn = false; self.loopEnabled = true
            self.videoInjectionSwitch.isOn = true; self.audioInjectionSwitch.isOn = false
            self.loopSwitch.isOn = true
            self.localVideoPathLabel.text = "未选择（仅 MP4）"; self.localVideoPathLabel.textColor = .secondaryLabel
            self.statusLabel.text = "当前: 真实摄像头 | 守护进程: 等待中"; self.statusIndicator.backgroundColor = .systemGreen
            self.updateCardVisibility(); self.updateSourceButtons()
            ["videoSource","rtmpURL","localVideoPath","videoInjection","audioInjection","loopEnabled"].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
            UserDefaults.standard.synchronize()
            self.sendControlCommand()
            self.addLog("设置已还原为默认值")
        })
        present(alert, animated: true)
    }

    @objc private func copyRTMPURL() {
        UIPasteboard.general.string = rtmpURL
        addLog("RTMP 地址已复制: \(rtmpURL)")
        let a = UIAlertController(title: "已复制", message: rtmpURL, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default))
        present(a, animated: true)
    }

    @objc private func selectLocalVideo() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mpeg4Movie])
        picker.delegate = self; picker.allowsMultipleSelection = false
        present(picker, animated: true)
        addLog("打开文件选择器 (MP4)")
    }

    @objc private func loopToggled() {
        loopEnabled = loopSwitch.isOn
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
        addLog("循环播放: \(loopEnabled ? "开" : "关")")
    }

    @objc private func injectionToggled() {
        videoInjectionOn = videoInjectionSwitch.isOn; audioInjectionOn = audioInjectionSwitch.isOn
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        sendControlCommand()
        addLog("注入开关: 视频=\(videoInjectionOn ? "开" : "关") 音频=\(audioInjectionOn ? "开" : "关")")
    }

    @objc private func toggleFloatingWindow() {
        if FloatingWindowManager.shared.isShowingWindow {
            FloatingWindowManager.shared.hide()
            floatBtn.setTitle("⚪ 悬浮窗", for: .normal); floatBtn.backgroundColor = .systemGray
            addLog("悬浮窗: 隐藏")
        } else {
            FloatingWindowManager.shared.show(with: self)
            floatBtn.setTitle("🔵 悬浮窗", for: .normal); floatBtn.backgroundColor = .systemGreen
            addLog("悬浮窗: 显示")
        }
    }

    @objc func applySettings() {
        switch currentSource {
        case .realCamera: statusLabel.text = "当前: 真实摄像头 | 守护进程: 运行中"; statusIndicator.backgroundColor = .systemGreen
        case .rtmpStream: statusLabel.text = "当前: RTMP流 | 守护进程: 运行中"; statusIndicator.backgroundColor = .systemBlue
        case .localVideo:
            let n = localVideoPath.isEmpty ? "未选择" : (localVideoPath as NSString).lastPathComponent
            statusLabel.text = "当前: 本地视频 (\(n)) | 守护进程: 运行中"; statusIndicator.backgroundColor = .systemOrange
        }
        sendControlCommand()
        ["videoSource","rtmpURL","localVideoPath","videoInjection","audioInjection","loopEnabled"].forEach { k in
            UserDefaults.standard.set(self.value(forKey: k), forKey: k)
        }
        UserDefaults.standard.synchronize()
        addLog("设置已应用: \(["真实摄像头","RTMP推流","本地视频"][currentSource.rawValue])")
    }

    private func sendControlCommand() {
        sharedFrameQueue.async { [weak self] in
            guard let self = self else { return }
            let controlFD = shm_open(CONTROL_MEMORY_NAME, O_RDWR, 0)
            guard controlFD >= 0 else { DispatchQueue.main.async { self.addLog("⚠ 控制内存未创建") }; return }
            defer { close(controlFD) }
            let size = MemoryLayout<SharedControlData>.size
            let ptr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, controlFD, 0)
            guard ptr != MAP_FAILED else { return }
            defer { munmap(ptr, size) }
            let ctrl = ptr!.bindMemory(to: SharedControlData.self, capacity: 1)
            ctrl.pointee.command = 1
            ctrl.pointee.sourceType = UInt32(self.currentSource.rawValue)
            ctrl.pointee.videoInjectionEnabled = self.videoInjectionOn ? 1 : 0
            ctrl.pointee.audioInjectionEnabled = self.audioInjectionOn ? 1 : 0
            ctrl.pointee.loopEnabled = self.loopEnabled ? 1 : 0
            let url = self.rtmpURL.utf8CString
            withUnsafeMutablePointer(to: &ctrl.pointee.rtmpURL) { d in
                _ = url.withUnsafeBytes { s in memcpy(d, s.baseAddress!, min(s.count, Int(MAX_RTMP_URL_LENGTH-1))) }
                UnsafeMutableRawPointer(d).assumingMemoryBound(to: CChar.self).advanced(by: Int(MAX_RTMP_URL_LENGTH)-1).pointee = 0
            }
        }
    }

    private func loadSavedConfig() {
        if let s = UserDefaults.standard.object(forKey: "videoSource") as? Int, s >= 0 && s <= 2 {
            currentSource = VideoSourceType(rawValue: s) ?? .realCamera
        }
        if let u = UserDefaults.standard.string(forKey: "rtmpURL"), !u.isEmpty { rtmpURL = u }
        if let p = UserDefaults.standard.string(forKey: "localVideoPath") { localVideoPath = p; localVideoPathLabel.text = (p as NSString).lastPathComponent; localVideoPathLabel.textColor = .label }
        videoInjectionOn = UserDefaults.standard.object(forKey: "videoInjection") as? Bool ?? true
        audioInjectionOn = UserDefaults.standard.bool(forKey: "audioInjection")
        loopEnabled = UserDefaults.standard.object(forKey: "loopEnabled") as? Bool ?? true
        videoInjectionSwitch.isOn = videoInjectionOn; audioInjectionSwitch.isOn = audioInjectionOn; loopSwitch.isOn = loopEnabled
        updateCardVisibility(); updateSourceButtons()
    }
}

extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let a = url.startAccessingSecurityScopedResource()
        defer { if a { url.stopAccessingSecurityScopedResource() } }
        localVideoPath = url.path
        localVideoPathLabel.text = "✅ \((url.path as NSString).lastPathComponent)"
        localVideoPathLabel.textColor = .label
        addLog("已选择视频: \((url.path as NSString).lastPathComponent)")
    }
}

class FloatingWindowManager: NSObject {
    static let shared = FloatingWindowManager()
    private var floatWindow: UIWindow?
    private var isShowing = false
    private weak var parentVC: MainViewController?
    override private init() { super.init() }
    var isShowingWindow: Bool { isShowing }

    func show(with vc: MainViewController) {
        guard !isShowing else { return }
        parentVC = vc; isShowing = true
        let size: CGFloat = 76
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        floatWindow = scene != nil ? UIWindow(windowScene: scene!) : UIWindow(frame: UIScreen.main.bounds)
        floatWindow?.frame = CGRect(x: UIScreen.main.bounds.width - size - 14, y: 180, width: size, height: size)
        floatWindow?.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.88)
        floatWindow?.layer.cornerRadius = size/2
        floatWindow?.layer.shadowColor = UIColor.black.cgColor
        floatWindow?.layer.shadowOpacity = 0.3
        floatWindow?.layer.shadowOffset = CGSize(width: 0, height: 2)
        floatWindow?.layer.shadowRadius = 8
        floatWindow?.windowLevel = .alert + 1
        let btn = UIButton(frame: floatWindow!.bounds)
        btn.setTitle("📷", for: .normal); btn.titleLabel?.font = .systemFont(ofSize: 30)
        btn.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
        floatWindow?.addSubview(btn)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatPanned(_:)))
        floatWindow?.addGestureRecognizer(pan)
        floatWindow?.isHidden = false
    }

    func hide() { floatWindow?.isHidden = true; floatWindow = nil; isShowing = false }

    @objc private func floatTapped() {
        guard let vc = parentVC else { return }
        let alert = UIAlertController(title: "快速切换", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "真实摄像头", style: .default) { _ in vc.realCameraBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "RTMP推流", style: .default) { _ in vc.rtmpBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "本地视频", style: .default) { _ in vc.localVideoBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "隐藏悬浮窗", style: .destructive) { [weak self] _ in self?.hide() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.present(alert, animated: true)
    }

    @objc private func floatPanned(_ pan: UIPanGestureRecognizer) {
        guard let w = floatWindow else { return }
        let t = pan.translation(in: nil)
        w.center = CGPoint(x: w.center.x + t.x, y: w.center.y + t.y)
        pan.setTranslation(.zero, in: nil)
    }
}
