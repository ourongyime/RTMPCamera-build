import UIKit
import AVFoundation

enum VideoSourceType: Int { case realCamera = 0; case rtmpStream = 1; case localVideo = 2 }

class MainViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let statusCard = UIView()
    private let statusIndicator = UIView()
    private let statusTitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let versionLabel = UILabel()
    private let sourceCard = UIView()
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
    private let copyLogBtn = UIButton(type: .system)
    private let floatBtn = UIButton(type: .system)
    private let previewView = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoPlayerLayer: AVPlayerLayer?
    private var videoPlayer: AVPlayer?
    private var captureSession: AVCaptureSession?
    private let applyButton = UIButton(type: .system)
    private var currentSource: VideoSourceType = .realCamera
    private var rtmpURL = ""
    private var localVideoPath = ""
    private var videoInjectionOn = true
    private var audioInjectionOn = false
    private var loopEnabled = true
    private var phoneIP = ""
    private var logLines: [String] = []
    private let defaultRTMPPort = 1935
    private let appVersion = "1.0.53"
    private let tweakDir = "/var/mobile/Documents/rtmpcamera"
    private let tweakCfgFile = "/var/mobile/Documents/rtmpcamera/config.plist"
    private let tweakVideoFile = "/var/mobile/Documents/rtmpcamera/current_video.mp4"
    private let tweakLoadedFile = "/var/mobile/Documents/rtmpcamera/tweak_loaded"
    private let tweakLogFile = "/var/mobile/Documents/rtmpcamera/tweak.log"

    override func viewDidLoad() {
        super.viewDidLoad()
        detectLocalIP()
        setupUI()
        loadSavedConfig()
        startCameraPreview()
        logDetailedStatus()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshTweakLog()
        }
    }

    private func refreshTweakLog() {
        if let tl = try? String(contentsOfFile: tweakLogFile, encoding: .utf8) {
            let lines = tl.components(separatedBy: "\n")
            let last = lines.suffix(30).joined(separator: "\n")
            DispatchQueue.main.async {
                self.logTextView.text = self.logLines.joined(separator: "\n") + "\n\n--- tweak.log ---\n" + last
            }
        }
    }

    deinit {
        captureSession?.stopRunning()
        videoPlayer?.pause()
    }

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
                            if ip != "127.0.0.1" && (ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")) { addr = ip; if name == "en0" { break } }
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

    private func addLog(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)"
        if logLines.last == line { return }
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        DispatchQueue.main.async {
            self.logTextView.text = self.logLines.joined(separator: "\n")
            let r = NSMakeRange((self.logTextView.text as NSString).length - 1, 1)
            if r.location < (self.logTextView.text as NSString).length { self.logTextView.scrollRangeToVisible(r) }
        }
    }

    private func addResult(_ label: String, _ ok: Bool, _ detail: String = "") {
        addLog("\(ok ? "[OK]" : "[FAIL]") \(label)\(detail.isEmpty ? "" : " - \(detail)")")
    }

    private func logDetailedStatus() {
        addLog("======== RTMPCamera v\(appVersion) ========")
        addResult("App Sandbox", true, NSHomeDirectory())
        let tweakLoaded = FileManager.default.fileExists(atPath: tweakLoadedFile)
        addResult("Tweak 注入", tweakLoaded, tweakLoaded ? "tweak_loaded 已发现" : "未注入，请Respring!")
        addResult("配置目录", FileManager.default.fileExists(atPath: tweakDir))
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tweakDir) {
            addLog("  目录权限: \(attrs[.posixPermissions] ?? 0) owner: \(attrs[.ownerAccountName] ?? "?")")
        }
        addResult("配置文件", FileManager.default.fileExists(atPath: tweakCfgFile))
        addResult("Tweak 日志", FileManager.default.fileExists(atPath: tweakLogFile))
        if let tl = try? String(contentsOfFile: tweakLogFile, encoding: .utf8) {
            let lines = tl.components(separatedBy: "\n").filter { !$0.isEmpty }
            addLog("  Tweak 日志 (最后5行):")
            for l in lines.suffix(5) { addLog("  \(l)") }
        }
        addResult("相机权限", AVCaptureDevice.authorizationStatus(for: .video).rawValue == 3, "code=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        if !localVideoPath.isEmpty {
            addResult("已选视频", FileManager.default.fileExists(atPath: localVideoPath), localVideoPath)
        }
        addResult("Tweak视频文件", FileManager.default.fileExists(atPath: tweakVideoFile), tweakVideoFile)
        addLog("当前视频源: \(sourceName())")
        addLog("注入状态: 视频=\(videoInjectionOn ? "开" : "关") 音频=\(audioInjectionOn ? "开" : "关") 循环=\(loopEnabled ? "开" : "关")")
        addLog("==========================================")
    }

    private func sourceName() -> String {
        switch currentSource {
        case .realCamera: return "真实摄像头"
        case .rtmpStream: return "RTMP流"
        case .localVideo: return "本地视频"
        }
    }

    private func startCameraPreview() {
        captureSession = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            addLog("相机启动失败")
            return
        }
        captureSession?.addInput(input)
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
        previewLayer?.frame = previewView.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(previewLayer!)
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession?.startRunning() }
        addLog("[OK] 相机预览已启动")
    }

    private func stopCameraPreview() {
        captureSession?.stopRunning()
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        captureSession = nil
    }

    private func playLocalVideo(_ path: String) {
        stopLocalVideo()
        let url = URL(fileURLWithPath: path)
        let asset = AVAsset(url: url)
        let videoTracks = asset.tracks(withMediaType: .video)
        if videoTracks.isEmpty {
            addLog("[FAIL] 视频无有效视频轨道: \(path)")
            return
        }
        videoPlayer = AVPlayer(url: url)
        videoPlayerLayer = AVPlayerLayer(player: videoPlayer)
        videoPlayerLayer?.frame = previewView.bounds
        videoPlayerLayer?.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(videoPlayerLayer!)
        videoPlayer?.play()
        addLog("[OK] 视频预览 - \(url.lastPathComponent)")
        if loopEnabled {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: videoPlayer?.currentItem, queue: .main) { [weak self] _ in
                self?.videoPlayer?.seek(to: CMTime.zero)
                self?.videoPlayer?.play()
            }
        }
    }

    private func stopLocalVideo() {
        videoPlayer?.pause()
        videoPlayerLayer?.removeFromSuperlayer()
        videoPlayerLayer = nil
        videoPlayer = nil
    }

    private func loadSavedConfig() {
        guard let cfg = NSDictionary(contentsOfFile: tweakCfgFile) else { return }
        videoInjectionOn = (cfg["videoInjectionEnabled"] as? Bool) ?? true
        audioInjectionOn = (cfg["audioInjectionEnabled"] as? Bool) ?? false
        loopEnabled = (cfg["loopEnabled"] as? Bool) ?? true
        if let src = cfg["sourceType"] as? Int, let st = VideoSourceType(rawValue: src) { currentSource = st }
        if let url = cfg["rtmpURL"] as? String { rtmpURL = url }
        if let path = cfg["localVideoPath"] as? String, !path.isEmpty { localVideoPath = path }
        videoInjectionSwitch.isOn = videoInjectionOn
        audioInjectionSwitch.isOn = audioInjectionOn
        loopSwitch.isOn = loopEnabled
    }

    private func validateAndCopyVideo() -> Bool {
        guard !localVideoPath.isEmpty else {
            addLog("[FAIL] 未选择视频文件")
            return false
        }
        let asset = AVAsset(url: URL(fileURLWithPath: localVideoPath))
        let videoTracks = asset.tracks(withMediaType: .video)
        if videoTracks.isEmpty {
            addLog("[FAIL] 视频无有效视频轨道，请选择正确的MP4文件")
            return false
        }
        addLog("视频轨道: \(videoTracks.count)条, 时长: \(asset.duration.seconds)秒")
        let fm = FileManager.default
        try? fm.removeItem(atPath: tweakDir)
        try? fm.createDirectory(atPath: tweakDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        addResult("目录创建", fm.fileExists(atPath: tweakDir), tweakDir)
        if fm.fileExists(atPath: tweakVideoFile) { try? fm.removeItem(atPath: tweakVideoFile) }
        do {
            try fm.copyItem(atPath: localVideoPath, toPath: tweakVideoFile)
            addResult("视频复制", true, tweakVideoFile)
            return true
        } catch {
            addResult("视频复制", false, error.localizedDescription)
            return false
        }
    }

    private func saveConfig() -> Bool {
        let cfg: [String: Any] = [
            "sourceType": currentSource.rawValue,
            "videoInjectionEnabled": videoInjectionOn,
            "audioInjectionEnabled": audioInjectionOn,
            "loopEnabled": loopEnabled,
            "rtmpURL": rtmpURL,
            "localVideoPath": localVideoPath
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: cfg, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: tweakCfgFile))
            addResult("配置写入", true, tweakCfgFile)
            return true
        } catch {
            addResult("配置写入", false, error.localizedDescription)
            return false
        }
    }

    @objc func applySettings() {
        addLog("应用设置: \(sourceName()) 注入视频=\(videoInjectionOn ? "开" : "关") 注入音频=\(audioInjectionOn ? "开" : "关") 循环=\(loopEnabled ? "开" : "关")")
        stopLocalVideo()
        switch currentSource {
        case .realCamera:
            startCameraPreview()
            addLog("已切换到真实摄像头")
        case .rtmpStream:
            startCameraPreview()
            addLog("RTMP流模式（待守护进程支持）")
        case .localVideo:
            if validateAndCopyVideo() {
                playLocalVideo(tweakVideoFile)
                saveConfig()
                addLog("设置已应用: \(sourceName())")
            } else {
                startCameraPreview()
            }
        }
        if currentSource != .localVideo {
            saveConfig()
            addLog("设置已应用: \(sourceName())")
        }
    }

    @objc private func resetAllSettings() {
        currentSource = .realCamera
        videoInjectionOn = true
        audioInjectionOn = false
        loopEnabled = true
        rtmpURL = "rtmp://\(phoneIP):\(defaultRTMPPort)/live/stream"
        localVideoPath = ""
        videoInjectionSwitch.isOn = true
        audioInjectionSwitch.isOn = false
        loopSwitch.isOn = true
        localVideoPathLabel.text = "未选择视频"
        localVideoPathLabel.textColor = .secondaryLabel
        updateSourceButtons()
        updateCardVisibility()
        stopLocalVideo()
        startCameraPreview()
        saveConfig()
        addLog("已还原默认设置")
    }

    @objc private func copyLog() {
        let appLog = logLines.joined(separator: "\n")
        var fullLog = appLog
        if let tl = try? String(contentsOfFile: tweakLogFile, encoding: .utf8) {
            fullLog += "\n\n--- tweak.log ---\n" + tl
        }
        UIPasteboard.general.string = fullLog
        addLog("日志已复制 (共\(fullLog.count)字符)")
    }

    @objc private func clearLog() {
        logLines.removeAll()
        logTextView.text = ""
        addLog("日志已清除")
    }

    @objc private func selectVideoTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func floatButtonTapped() {
        if FloatingWindowManager.shared.isShowingWindow {
            FloatingWindowManager.shared.hide()
            floatBtn.setTitle("悬浮窗口", for: .normal)
            addLog("悬浮窗口已隐藏")
        } else {
            FloatingWindowManager.shared.show(with: self)
            floatBtn.setTitle("关闭悬浮", for: .normal)
            addLog("悬浮窗口已显示")
        }
    }

    @objc private func sourceBtnTapped(_ sender: UIButton) {
        let idx = sourceButtons.firstIndex(of: sender) ?? 0
        currentSource = VideoSourceType(rawValue: idx) ?? .realCamera
        updateSourceButtons()
        updateCardVisibility()
        switch currentSource {
        case .realCamera:
            stopLocalVideo()
            startCameraPreview()
        case .rtmpStream:
            stopLocalVideo()
            startCameraPreview()
        case .localVideo:
            stopCameraPreview()
            if !localVideoPath.isEmpty {
                let fm = FileManager.default
                let videoCopyExists = fm.fileExists(atPath: tweakVideoFile)
                if videoCopyExists {
                    playLocalVideo(tweakVideoFile)
                } else {
                    validateAndCopyVideo()
                    if fm.fileExists(atPath: tweakVideoFile) { playLocalVideo(tweakVideoFile) }
                    else { startCameraPreview() }
                }
            }
        }
    }

    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "RTMPCamera"
        navigationController?.navigationBar.prefersLargeTitles = false
        let resetBtn = UIBarButtonItem(title: "还原设置", style: .plain, target: self, action: #selector(resetAllSettings))
        navigationItem.rightBarButtonItem = resetBtn

        let w = view.bounds.width
        scrollView.frame = view.bounds
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        contentView.frame = CGRect(x: 0, y: 0, width: w, height: 0)
        scrollView.addSubview(contentView)

        var y: CGFloat = 10
        let cw = w - 32

        setupCard(statusCard, at: &y, w: cw, h: 160)
        setupCard(sourceCard, at: &y, w: cw, h: 110)
        setupCard(localVideoCard, at: &y, w: cw, h: 110)
        setupCard(rtmpCard, at: &y, w: cw, h: 100)
        setupCard(injectionCard, at: &y, w: cw, h: 110)
        setupCard(logCard, at: &y, w: cw, h: 210)

        y += 10
        contentView.frame.size.height = y
        scrollView.contentSize = contentView.frame.size

        setupStatusCard()
        setupSourceCard()
        setupLocalVideoCard()
        setupRTMPCard()
        setupInjectionCard()
        setupLogCard()

        updateSourceButtons()
        updateCardVisibility()
    }

    private func setupStatusCard() {
        let w = statusCard.bounds.width
        statusIndicator.frame = CGRect(x: 12, y: 12, width: 10, height: 10)
        statusIndicator.backgroundColor = .systemGreen
        statusIndicator.layer.cornerRadius = 5
        statusCard.addSubview(statusIndicator)
        statusTitleLabel.frame = CGRect(x: 28, y: 8, width: w - 80, height: 22)
        statusTitleLabel.text = "运行状态"
        statusTitleLabel.font = .boldSystemFont(ofSize: 15)
        statusCard.addSubview(statusTitleLabel)
        versionLabel.frame = CGRect(x: w - 60, y: 8, width: 52, height: 22)
        versionLabel.text = "v\(appVersion)"
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .right
        statusCard.addSubview(versionLabel)
        statusLabel.frame = CGRect(x: 28, y: 32, width: w - 40, height: 18)
        statusLabel.text = "Tweak注入中..."
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusCard.addSubview(statusLabel)
        let pv = previewView
        pv.frame = CGRect(x: 12, y: 54, width: w - 24, height: 100)
        pv.backgroundColor = .black
        pv.layer.cornerRadius = 4
        pv.clipsToBounds = true
        statusCard.addSubview(pv)
    }

    private func setupSourceCard() {
        let w = sourceCard.bounds.width
        let titleLabel = UILabel(frame: CGRect(x: 12, y: 8, width: w - 24, height: 22))
        titleLabel.text = "视频源选择"
        titleLabel.font = .boldSystemFont(ofSize: 15)
        sourceCard.addSubview(titleLabel)
        let btns = sourceButtons
        let titles = ["真实摄像头", "RTMP流", "本地视频"]
        let btnW = (w - 36) / 3
        for (i, btn) in btns.enumerated() {
            btn.frame = CGRect(x: 12 + CGFloat(i) * (btnW + 6), y: 36, width: btnW, height: 36)
            btn.setTitle(titles[i], for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 13)
            btn.addTarget(self, action: #selector(sourceBtnTapped(_:)), for: .touchUpInside)
            sourceCard.addSubview(btn)
        }
        applyButton.frame = CGRect(x: 12, y: 78, width: w - 24, height: 26)
        applyButton.setTitle("应用设置", for: .normal)
        applyButton.backgroundColor = .systemBlue
        applyButton.setTitleColor(.white, for: .normal)
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 13)
        applyButton.layer.cornerRadius = 6
        applyButton.addTarget(self, action: #selector(applySettings), for: .touchUpInside)
        sourceCard.addSubview(applyButton)
    }

    private func setupLocalVideoCard() {
        let w = localVideoCard.bounds.width
        let titleLabel = UILabel(frame: CGRect(x: 12, y: 8, width: w - 24, height: 22))
        titleLabel.text = "本地视频"
        titleLabel.font = .boldSystemFont(ofSize: 15)
        localVideoCard.addSubview(titleLabel)
        loopSwitch.frame = CGRect(x: w - 62, y: 6, width: 51, height: 28)
        localVideoCard.addSubview(loopSwitch)
        let loopLabel = UILabel(frame: CGRect(x: w - 110, y: 10, width: 46, height: 20))
        loopLabel.text = "循环"
        loopLabel.font = .systemFont(ofSize: 12)
        loopLabel.textColor = .secondaryLabel
        loopLabel.textAlignment = .right
        localVideoCard.addSubview(loopLabel)
        selectVideoButton.frame = CGRect(x: 12, y: 36, width: w - 24, height: 32)
        selectVideoButton.setTitle("选择视频 (MP4)...", for: .normal)
        selectVideoButton.titleLabel?.font = .systemFont(ofSize: 13)
        selectVideoButton.backgroundColor = .systemBlue.withAlphaComponent(0.1)
        selectVideoButton.setTitleColor(.systemBlue, for: .normal)
        selectVideoButton.layer.cornerRadius = 6
        selectVideoButton.addTarget(self, action: #selector(selectVideoTapped), for: .touchUpInside)
        localVideoCard.addSubview(selectVideoButton)
        localVideoPathLabel.frame = CGRect(x: 12, y: 72, width: w - 24, height: 20)
        localVideoPathLabel.text = "未选择视频"
        localVideoPathLabel.font = .systemFont(ofSize: 11)
        localVideoPathLabel.textColor = .secondaryLabel
        localVideoCard.addSubview(localVideoPathLabel)
    }

    private func setupRTMPCard() {
        let w = rtmpCard.bounds.width
        let titleLabel = UILabel(frame: CGRect(x: 12, y: 8, width: w - 24, height: 22))
        titleLabel.text = "RTMP 接收地址"
        titleLabel.font = .boldSystemFont(ofSize: 15)
        rtmpCard.addSubview(titleLabel)
        rtmpURLLabel.frame = CGRect(x: 12, y: 34, width: w - 80, height: 22)
        rtmpURLLabel.text = rtmpURL
        rtmpURLLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rtmpURLLabel.textColor = .label
        rtmpURLLabel.adjustsFontSizeToFitWidth = true
        rtmpCard.addSubview(rtmpURLLabel)
        rtmpCopyButton.frame = CGRect(x: w - 62, y: 34, width: 50, height: 22)
        rtmpCopyButton.setTitle("复制", for: .normal)
        rtmpCopyButton.titleLabel?.font = .boldSystemFont(ofSize: 11)
        rtmpCopyButton.setTitleColor(.systemBlue, for: .normal)
        rtmpCopyButton.addTarget(self, action: #selector(copyRTMP), for: .touchUpInside)
        rtmpCard.addSubview(rtmpCopyButton)
        rtmpHintLabel.frame = CGRect(x: 12, y: 58, width: w - 24, height: 30)
        rtmpHintLabel.text = "OBS推流到此地址，手机端自动接收。端口: \(defaultRTMPPort)"
        rtmpHintLabel.font = .systemFont(ofSize: 10)
        rtmpHintLabel.textColor = .secondaryLabel
        rtmpHintLabel.numberOfLines = 2
        rtmpCard.addSubview(rtmpHintLabel)
        rtmpCopyButton.addTarget(self, action: #selector(copyRTMP), for: .touchUpInside)
    }

    private func setupInjectionCard() {
        let w = injectionCard.bounds.width
        let titleLabel = UILabel(frame: CGRect(x: 12, y: 8, width: w - 24, height: 22))
        titleLabel.text = "注入控制"
        titleLabel.font = .boldSystemFont(ofSize: 15)
        injectionCard.addSubview(titleLabel)
        let videoLabel = UILabel(frame: CGRect(x: 12, y: 42, width: 80, height: 24))
        videoLabel.text = "注入视频"
        videoLabel.font = .systemFont(ofSize: 13)
        injectionCard.addSubview(videoLabel)
        videoInjectionSwitch.frame = CGRect(x: 100, y: 40, width: 51, height: 28)
        videoInjectionSwitch.isOn = true
        injectionCard.addSubview(videoInjectionSwitch)
        let audioLabel = UILabel(frame: CGRect(x: 170, y: 42, width: 80, height: 24))
        audioLabel.text = "注入音频"
        audioLabel.font = .systemFont(ofSize: 13)
        injectionCard.addSubview(audioLabel)
        audioInjectionSwitch.frame = CGRect(x: 250, y: 40, width: 51, height: 28)
        audioInjectionSwitch.isOn = false
        injectionCard.addSubview(audioInjectionSwitch)
        floatBtn.frame = CGRect(x: 12, y: 76, width: w - 24, height: 26)
        floatBtn.setTitle("悬浮窗口", for: .normal)
        floatBtn.backgroundColor = .systemGray.withAlphaComponent(0.15)
        floatBtn.setTitleColor(.label, for: .normal)
        floatBtn.titleLabel?.font = .systemFont(ofSize: 13)
        floatBtn.layer.cornerRadius = 6
        floatBtn.addTarget(self, action: #selector(floatButtonTapped), for: .touchUpInside)
        injectionCard.addSubview(floatBtn)
        videoInjectionSwitch.addTarget(self, action: #selector(injectionSwitchChanged), for: .valueChanged)
        audioInjectionSwitch.addTarget(self, action: #selector(injectionSwitchChanged), for: .valueChanged)
    }

    @objc private func injectionSwitchChanged() {
        videoInjectionOn = videoInjectionSwitch.isOn
        audioInjectionOn = audioInjectionSwitch.isOn
    }

    private func setupLogCard() {
        let w = logCard.bounds.width
        let titleLabel = UILabel(frame: CGRect(x: 12, y: 4, width: 100, height: 22))
        titleLabel.text = "运行日志"
        titleLabel.font = .boldSystemFont(ofSize: 13)
        logCard.addSubview(titleLabel)
        clearLogBtn.frame = CGRect(x: w - 120, y: 4, width: 50, height: 22)
        clearLogBtn.setTitle("清除", for: .normal)
        clearLogBtn.titleLabel?.font = .boldSystemFont(ofSize: 11)
        clearLogBtn.setTitleColor(.systemRed, for: .normal)
        clearLogBtn.addTarget(self, action: #selector(clearLog), for: .touchUpInside)
        logCard.addSubview(clearLogBtn)
        copyLogBtn.frame = CGRect(x: w - 60, y: 4, width: 50, height: 22)
        copyLogBtn.setTitle("复制", for: .normal)
        copyLogBtn.titleLabel?.font = .boldSystemFont(ofSize: 11)
        copyLogBtn.setTitleColor(.systemBlue, for: .normal)
        copyLogBtn.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        logCard.addSubview(copyLogBtn)
        logTextView.frame = CGRect(x: 6, y: 26, width: w - 12, height: 180)
        logTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .label
        logTextView.backgroundColor = .secondarySystemBackground
        logTextView.isEditable = false
        logTextView.layer.cornerRadius = 6
        logCard.addSubview(logTextView)
    }

    private func setupCard(_ card: UIView, at y: inout CGFloat, w: CGFloat, h: CGFloat) {
        card.frame = CGRect(x: 16, y: y, width: w, height: h)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 11
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.04
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 5; contentView.addSubview(card)
        y += h + 10
    }

    @objc private func copyRTMP() {
        UIPasteboard.general.string = rtmpURL
        addLog("RTMP地址已复制")
    }

    private func updateSourceButtons() {
        for (i, btn) in sourceButtons.enumerated() {
            btn.isSelected = i == currentSource.rawValue
            btn.backgroundColor = btn.isSelected ? .systemBlue.withAlphaComponent(0.15) : .clear
            btn.setTitleColor(btn.isSelected ? .systemBlue : .secondaryLabel, for: .normal)
            btn.layer.cornerRadius = 4
        }
    }

    private func updateCardVisibility() {
        rtmpCard.isHidden = currentSource != .rtmpStream
        localVideoCard.isHidden = currentSource != .localVideo
        rtmpURLLabel.text = rtmpURL
    }
}

extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let a = url.startAccessingSecurityScopedResource()
        defer { if a { url.stopAccessingSecurityScopedResource() } }
        localVideoPath = url.path
        localVideoPathLabel.text = "✅ \(url.lastPathComponent)"
        localVideoPathLabel.textColor = .label
        addLog("已选择: \(url.lastPathComponent)")
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
        parentVC = vc
        isShowing = true
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
        btn.setTitle("📷", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 30)
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