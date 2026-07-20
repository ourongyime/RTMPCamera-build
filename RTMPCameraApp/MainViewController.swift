import UIKit
import AVFoundation

enum VideoSourceType: Int {
    case realCamera = 0
    case rtmpStream = 1
    case localVideo = 2
}

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
    private var rtmpURL: String = ""
    private var localVideoPath: String = ""
    private var videoInjectionOn: Bool = true
    private var audioInjectionOn: Bool = false
    private var loopEnabled: Bool = true
    private var phoneIP: String = ""
    private var logLines: [String] = []
    private let defaultRTMPPort = 1935
    private let appVersion = "1.0.32"

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
    }

    deinit {
        captureSession?.stopRunning()
        videoPlayer?.pause()
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
                                addr = ip; if name == "en0" { break }
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

    // MARK: - Logging
    private func addLog(_ msg: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
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
        let mark = ok ? "[OK]" : "[FAIL]"
        addLog("\(mark) \(label)\(detail.isEmpty ? "" : " - \(detail)")")
    }

    private func logDetailedStatus() {
        addLog("======== RTMPCamera v\(appVersion) ========")
        addResult("App Sandbox", true, NSHomeDirectory())

        // Tweak loaded?
        let loaded = FileManager.default.fileExists(atPath: tweakLoadedFile)
        addResult("Tweak Injection", loaded, loaded ? "tweak_loaded found" : "tweak_loaded NOT found - tweak may not be injected")

        // Config dir
        let dirExists = FileManager.default.fileExists(atPath: tweakDir)
        addResult("Config Dir", dirExists, tweakDir)
        if dirExists {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tweakDir) {
                addLog("  Dir permissions: \(attrs[.posixPermissions] ?? "?") owner: \(attrs[.ownerAccountName] ?? "?")")
            }
        }

        // Config file
        let cfgExists = FileManager.default.fileExists(atPath: tweakCfgFile)
        addResult("Config File", cfgExists, tweakCfgFile)

        // Tweak log
        let tlogExists = FileManager.default.fileExists(atPath: tweakLogFile)
        addResult("Tweak Log", tlogExists, tweakLogFile)
        if tlogExists {
            if let tl = try? String(contentsOfFile: tweakLogFile, encoding: .utf8) {
                let lastLines = tl.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
                if !lastLines.isEmpty { addLog("  Last tweak log:\n\(lastLines)") }
            }
        }

        // Camera permission
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        addResult("Camera Permission", auth == .authorized, "\(auth.rawValue)")

        // Video file
        if !localVideoPath.isEmpty {
            let vExists = FileManager.default.fileExists(atPath: localVideoPath)
            addResult("Selected Video", vExists, localVideoPath)
            let tweakVExists = FileManager.default.fileExists(atPath: tweakVideoFile)
            addResult("Tweak Video Copy", tweakVExists, tweakVideoFile)
        }

        addLog("Current Source: \(["Real","RTMP","Local"][currentSource.rawValue])")
        addLog("Injection: Video=\(videoInjectionOn ? "ON":"OFF") Audio=\(audioInjectionOn ? "ON":"OFF") Loop=\(loopEnabled ? "ON":"OFF")")
        addLog("==========================================")
    }

    @objc private func clearLog() { logLines.removeAll(); logTextView.text = "" }

    @objc private func copyLog() {
        UIPasteboard.general.string = logLines.joined(separator: "\n")
        addLog("Log copied to clipboard")
    }

    // MARK: - Camera Preview
    private func startCameraPreview() {
        if captureSession != nil { return }
        let session = AVCaptureSession(); session.sessionPreset = .medium
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            addResult("Camera Init", false, "No device or permission denied")
            return
        }
        session.addInput(input)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        previewView.layer.addSublayer(layer)
        previewLayer = layer; captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        addResult("Camera Preview", true, "Started")
    }

    // MARK: - Video Preview
    private func startVideoPreview() {
        guard currentSource == .localVideo, !localVideoPath.isEmpty else { return }
        stopVideoPreview()
        let url = URL(fileURLWithPath: localVideoPath)
        let player = AVPlayer(url: url); player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        previewView.layer.addSublayer(layer)
        videoPlayerLayer = layer; videoPlayer = player
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            if self?.loopEnabled == true { player.seek(to: .zero); player.play() }
        }
        player.play()
        addResult("Video Preview", true, (localVideoPath as NSString).lastPathComponent)
    }

    private func stopVideoPreview() {
        videoPlayer?.pause(); videoPlayer = nil
        videoPlayerLayer?.removeFromSuperlayer(); videoPlayerLayer = nil
    }

    private func showCameraPreview() {
        stopVideoPreview()
        previewLayer?.isHidden = false
    }

    // MARK: - Actions
    @objc func sourceSelected(_ sender: UIButton) {
        if sender == realCameraBtn { currentSource = .realCamera }
        else if sender == rtmpBtn { currentSource = .rtmpStream }
        else { currentSource = .localVideo }
        updateSourceButtons(); updateCardVisibility()
    }

    @objc func injectionToggled() {
        videoInjectionOn = videoInjectionSwitch.isOn
        audioInjectionOn = audioInjectionSwitch.isOn
    }

    @objc func selectVideo() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mpeg4Movie, .movie, .video])
        picker.delegate = self; picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc func toggleFloatingWindow() {
        if FloatingWindowManager.shared.isShowingWindow {
            FloatingWindowManager.shared.hide()
            floatBtn.setTitle("Float: OFF", for: .normal)
        } else {
            FloatingWindowManager.shared.show(with: self)
            floatBtn.setTitle("Float: ON", for: .normal)
        }
    }

    @objc func resetAll() {
        currentSource = .realCamera; rtmpURL = "rtmp://\(phoneIP):\(defaultRTMPPort)/live/stream"
        localVideoPath = ""; videoInjectionOn = true; audioInjectionOn = false; loopEnabled = true
        videoInjectionSwitch.isOn = true; audioInjectionSwitch.isOn = false; loopSwitch.isOn = true
        localVideoPathLabel.text = "Not selected"; localVideoPathLabel.textColor = .secondaryLabel
        updateSourceButtons(); updateCardVisibility(); showCameraPreview(); applySettings()
        addLog("All settings reset to default")
    }

    @objc func applySettings() {
        switch currentSource {
        case .realCamera: statusLabel.text = "Current: Real Camera"; statusIndicator.backgroundColor = .systemGreen; showCameraPreview()
        case .rtmpStream: statusLabel.text = "Current: RTMP Stream"; statusIndicator.backgroundColor = .systemBlue; showCameraPreview()
        case .localVideo:
            let n = localVideoPath.isEmpty ? "None" : (localVideoPath as NSString).lastPathComponent
            statusLabel.text = "Current: Local Video (\(n))"; statusIndicator.backgroundColor = .systemOrange
            if !localVideoPath.isEmpty { startVideoPreview() }
        }
        sendControlCommand()
        UserDefaults.standard.set(currentSource.rawValue, forKey: "videoSource")
        UserDefaults.standard.set(rtmpURL, forKey: "rtmpURL")
        UserDefaults.standard.set(localVideoPath, forKey: "localVideoPath")
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
        UserDefaults.standard.synchronize()
        addLog("Settings applied: \(["Real","RTMP","Local"][currentSource.rawValue])")
    }

    // MARK: - Tweak config
    private func sendControlCommand() {
        let names = ["Real Camera", "RTMP Stream", "Local Video"]
        addLog("Config: \(names[currentSource.rawValue]) Video=\(videoInjectionOn ? "ON":"OFF") Audio=\(audioInjectionOn ? "ON":"OFF") Loop=\(loopEnabled ? "ON":"OFF")")
        applyConfigToTweak()
    }

    private func applyConfigToTweak() {
        // Force recreate directory with proper permissions
        if FileManager.default.fileExists(atPath: tweakDir) {
            try? FileManager.default.removeItem(atPath: tweakDir)
            addLog("Removed old tweak dir to fix permissions")
        }
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o777]
        do {
            try FileManager.default.createDirectory(atPath: tweakDir, withIntermediateDirectories: true, attributes: attrs)
            addResult("Tweak Dir Created", true, tweakDir)
        } catch {
            addResult("Tweak Dir Created", false, error.localizedDescription)
        }

        // Copy video
        if currentSource == .localVideo && !localVideoPath.isEmpty {
            if FileManager.default.fileExists(atPath: tweakVideoFile) {
                try? FileManager.default.removeItem(atPath: tweakVideoFile)
            }
            do {
                try FileManager.default.copyItem(atPath: localVideoPath, toPath: tweakVideoFile)
                // Set permissions on video file
                try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tweakVideoFile)
                addResult("Video Copy", true, tweakVideoFile)
            } catch {
                addResult("Video Copy", false, error.localizedDescription)
            }
        }

        // Write config
        let cfg: [String: Any] = [
            "sourceType": currentSource.rawValue,
            "videoInjectionEnabled": videoInjectionOn,
            "audioInjectionEnabled": audioInjectionOn,
            "loopEnabled": loopEnabled,
            "rtmpURL": rtmpURL,
            "localVideoPath": tweakVideoFile,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: cfg, format: .xml, options: 0) {
            do {
                try data.write(to: URL(fileURLWithPath: tweakCfgFile), options: .atomic)
                addResult("Config Write", true, tweakCfgFile)
            } catch {
                addResult("Config Write", false, error.localizedDescription)
            }
        }
    }

    private func loadSavedConfig() {
        if let s = UserDefaults.standard.object(forKey: "videoSource") as? Int, s >= 0 && s <= 2 {
            currentSource = VideoSourceType(rawValue: s) ?? .realCamera
        }
        if let u = UserDefaults.standard.string(forKey: "rtmpURL"), !u.isEmpty { rtmpURL = u }
        if let p = UserDefaults.standard.string(forKey: "localVideoPath") {
            localVideoPath = p
            localVideoPathLabel.text = (p as NSString).lastPathComponent
            localVideoPathLabel.textColor = .label
        }
        videoInjectionOn = UserDefaults.standard.object(forKey: "videoInjection") as? Bool ?? true
        audioInjectionOn = UserDefaults.standard.bool(forKey: "audioInjection")
        loopEnabled = UserDefaults.standard.object(forKey: "loopEnabled") as? Bool ?? true
        videoInjectionSwitch.isOn = videoInjectionOn; audioInjectionSwitch.isOn = audioInjectionOn; loopSwitch.isOn = loopEnabled
        updateCardVisibility(); updateSourceButtons()
    }

    // MARK: - UI
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "RTMPCamera"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetAll))

        let w = view.bounds.width - 32
        var y: CGFloat = 8

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)
        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 900)
        scrollView.addSubview(contentView)

        // Status card
        setupCard(statusCard, at: &y, w: w, h: 60)
        contentView.addSubview(statusCard)
        statusIndicator.frame = CGRect(x: 10, y: 12, width: 10, height: 10)
        statusIndicator.backgroundColor = .systemGreen; statusIndicator.layer.cornerRadius = 5
        statusCard.addSubview(statusIndicator)
        statusTitleLabel.frame = CGRect(x: 26, y: 8, width: 200, height: 16)
        statusTitleLabel.text = "Status"; statusTitleLabel.font = .boldSystemFont(ofSize: 13)
        statusCard.addSubview(statusTitleLabel)
        statusLabel.frame = CGRect(x: 26, y: 28, width: 280, height: 14)
        statusLabel.text = "Current: Real Camera"; statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel; statusCard.addSubview(statusLabel)
        versionLabel.frame = CGRect(x: w - 100, y: 22, width: 90, height: 14)
        versionLabel.text = "v\(appVersion)"; versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabel; versionLabel.textAlignment = .right
        statusCard.addSubview(versionLabel)

        // Source selector
        setupCard(sourceCard, at: &y, w: w, h: 54)
        contentView.addSubview(sourceCard)
        let st = UILabel(frame: CGRect(x: 10, y: 6, width: 200, height: 16))
        st.text = "Video Source"; st.font = .boldSystemFont(ofSize: 13)
        sourceCard.addSubview(st)
        let bw: CGFloat = (w - 24) / 3
        realCameraBtn.frame = CGRect(x: 12, y: 26, width: bw, height: 22)
        realCameraBtn.setTitle("Real Cam", for: .normal); realCameraBtn.titleLabel?.font = .systemFont(ofSize: 11)
        realCameraBtn.addTarget(self, action: #selector(sourceSelected), for: .touchUpInside)
        sourceCard.addSubview(realCameraBtn)
        rtmpBtn.frame = CGRect(x: 14 + bw, y: 26, width: bw, height: 22)
        rtmpBtn.setTitle("RTMP", for: .normal); rtmpBtn.titleLabel?.font = .systemFont(ofSize: 11)
        rtmpBtn.addTarget(self, action: #selector(sourceSelected), for: .touchUpInside)
        sourceCard.addSubview(rtmpBtn)
        localVideoBtn.frame = CGRect(x: 16 + bw * 2, y: 26, width: bw, height: 22)
        localVideoBtn.setTitle("Local Video", for: .normal); localVideoBtn.titleLabel?.font = .systemFont(ofSize: 11)
        localVideoBtn.addTarget(self, action: #selector(sourceSelected), for: .touchUpInside)
        sourceCard.addSubview(localVideoBtn)

        // RTMP card
        setupCard(rtmpCard, at: &y, w: w, h: 56); rtmpCard.isHidden = true
        contentView.addSubview(rtmpCard)
        rtmpURLLabel.frame = CGRect(x: 10, y: 8, width: w - 80, height: 14)
        rtmpURLLabel.font = .systemFont(ofSize: 10); rtmpURLLabel.textColor = .secondaryLabel
        rtmpCard.addSubview(rtmpURLLabel)
        rtmpCopyButton.frame = CGRect(x: w - 68, y: 4, width: 58, height: 22)
        rtmpCopyButton.setTitle("Copy", for: .normal); rtmpCopyButton.titleLabel?.font = .systemFont(ofSize: 11)
        rtmpCopyButton.addTarget(self, action: #selector(copyRTMP), for: .touchUpInside)
        rtmpCard.addSubview(rtmpCopyButton)
        rtmpHintLabel.frame = CGRect(x: 10, y: 28, width: w - 20, height: 20)
        rtmpHintLabel.text = "OBS push to this phone"; rtmpHintLabel.font = .systemFont(ofSize: 9)
        rtmpHintLabel.textColor = .tertiaryLabel; rtmpCard.addSubview(rtmpHintLabel)

        // Local video card
        setupCard(localVideoCard, at: &y, w: w, h: 56); localVideoCard.isHidden = true
        contentView.addSubview(localVideoCard)
        let ll = UILabel(frame: CGRect(x: 10, y: 8, width: 80, height: 20))
        ll.text = "Loop Play"; ll.font = .systemFont(ofSize: 12)
        localVideoCard.addSubview(ll)
        loopSwitch.frame = CGRect(x: 85, y: 5, width: 51, height: 26)
        localVideoCard.addSubview(loopSwitch)
        selectVideoButton.frame = CGRect(x: 140, y: 4, width: 100, height: 26)
        selectVideoButton.setTitle("Select Video...", for: .normal); selectVideoButton.titleLabel?.font = .systemFont(ofSize: 11)
        selectVideoButton.addTarget(self, action: #selector(selectVideo), for: .touchUpInside)
        localVideoCard.addSubview(selectVideoButton)
        localVideoPathLabel.frame = CGRect(x: 10, y: 32, width: w - 20, height: 16)
        localVideoPathLabel.text = "Not selected"; localVideoPathLabel.font = .systemFont(ofSize: 10)
        localVideoPathLabel.textColor = .secondaryLabel
        localVideoCard.addSubview(localVideoPathLabel)

        // Injection card
        setupCard(injectionCard, at: &y, w: w, h: 56)
        contentView.addSubview(injectionCard)
        let it = UILabel(frame: CGRect(x: 10, y: 6, width: 200, height: 16))
        it.text = "Injection Control"; it.font = .boldSystemFont(ofSize: 13)
        injectionCard.addSubview(it)
        let vl = UILabel(frame: CGRect(x: 10, y: 28, width: 64, height: 22))
        vl.text = "Video"; vl.font = .systemFont(ofSize: 12)
        injectionCard.addSubview(vl)
        videoInjectionSwitch.frame = CGRect(x: 70, y: 25, width: 45, height: 28)
        injectionCard.addSubview(videoInjectionSwitch)
        let al = UILabel(frame: CGRect(x: 120, y: 28, width: 64, height: 22))
        al.text = "Audio"; al.font = .systemFont(ofSize: 12)
        injectionCard.addSubview(al)
        audioInjectionSwitch.frame = CGRect(x: 180, y: 25, width: 45, height: 28)
        injectionCard.addSubview(audioInjectionSwitch)

        // Preview
        setupCard(previewView, at: &y, w: w, h: 160)
        previewView.clipsToBounds = true; previewView.backgroundColor = .black
        previewView.layer.cornerRadius = 11
        contentView.addSubview(previewView)

        // Buttons
        y += 4
        floatBtn.frame = CGRect(x: 16, y: y, width: (w - 8) / 2, height: 42)
        floatBtn.setTitle("Float: OFF", for: .normal); floatBtn.backgroundColor = .systemGray
        floatBtn.setTitleColor(.white, for: .normal); floatBtn.layer.cornerRadius = 10
        floatBtn.titleLabel?.font = .boldSystemFont(ofSize: 13)
        floatBtn.addTarget(self, action: #selector(toggleFloatingWindow), for: .touchUpInside)
        contentView.addSubview(floatBtn)
        applyButton.frame = CGRect(x: (w - 8) / 2 + 24, y: y, width: (w - 8) / 2, height: 42)
        applyButton.setTitle("Apply", for: .normal); applyButton.backgroundColor = .systemBlue
        applyButton.setTitleColor(.white, for: .normal); applyButton.layer.cornerRadius = 10
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 13)
        applyButton.addTarget(self, action: #selector(applySettings), for: .touchUpInside)
        contentView.addSubview(applyButton)
        y += 52

        // Log card
        setupCard(logCard, at: &y, w: w, h: 200)
        contentView.addSubview(logCard)
        let lt = UILabel(frame: CGRect(x: 10, y: 6, width: 100, height: 18))
        lt.text = "Log"; lt.font = .boldSystemFont(ofSize: 13)
        logCard.addSubview(lt)
        clearLogBtn.frame = CGRect(x: w - 110, y: 4, width: 44, height: 22)
        clearLogBtn.setTitle("Clear", for: .normal); clearLogBtn.titleLabel?.font = .systemFont(ofSize: 11)
        clearLogBtn.addTarget(self, action: #selector(clearLog), for: .touchUpInside)
        logCard.addSubview(clearLogBtn)
        copyLogBtn.frame = CGRect(x: w - 60, y: 4, width: 50, height: 22)
        copyLogBtn.setTitle("Copy", for: .normal); copyLogBtn.titleLabel?.font = .boldSystemFont(ofSize: 11)
        copyLogBtn.setTitleColor(.systemBlue, for: .normal)
        copyLogBtn.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        logCard.addSubview(copyLogBtn)
        logTextView.frame = CGRect(x: 6, y: 26, width: w - 12, height: 166)
        logTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .label; logTextView.backgroundColor = .secondarySystemBackground
        logTextView.isEditable = false; logTextView.layer.cornerRadius = 6
        logCard.addSubview(logTextView)

        y += 16; contentView.frame.size.height = y; scrollView.contentSize = contentView.frame.size
        updateCardVisibility(); updateSourceButtons()
    }

    private func setupCard(_ card: UIView, at y: inout CGFloat, w: CGFloat, h: CGFloat) {
        card.frame = CGRect(x: 16, y: y, width: w, height: h)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 11
        card.layer.shadowColor = UIColor.black.cgColor; card.layer.shadowOpacity = 0.04
        card.layer.shadowOffset = CGSize(width: 0, height: 1); card.layer.shadowRadius = 5
        y += h + 10
    }

    @objc private func copyRTMP() {
        UIPasteboard.general.string = rtmpURL; addLog("RTMP URL copied")
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
        localVideoPathLabel.text = "OK \(url.lastPathComponent)"
        localVideoPathLabel.textColor = .label
        addLog("Selected: \(url.lastPathComponent)")
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
        floatWindow?.layer.shadowColor = UIColor.black.cgColor; floatWindow?.layer.shadowOpacity = 0.3
        floatWindow?.layer.shadowOffset = CGSize(width: 0, height: 2); floatWindow?.layer.shadowRadius = 8
        floatWindow?.windowLevel = .alert + 1
        let btn = UIButton(frame: floatWindow!.bounds)
        btn.setTitle("Cam", for: .normal); btn.titleLabel?.font = .systemFont(ofSize: 30)
        btn.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
        floatWindow?.addSubview(btn)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatPanned(_:)))
        floatWindow?.addGestureRecognizer(pan)
        floatWindow?.isHidden = false
    }

    func hide() { floatWindow?.isHidden = true; floatWindow = nil; isShowing = false }

    @objc private func floatTapped() {
        guard let vc = parentVC else { return }
        let alert = UIAlertController(title: "Quick Switch", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Real Camera", style: .default) { _ in vc.realCameraBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "Local Video", style: .default) { _ in vc.localVideoBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "Hide Float", style: .destructive) { [weak self] _ in self?.hide() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    @objc private func floatPanned(_ pan: UIPanGestureRecognizer) {
        guard let w = floatWindow else { return }
        let t = pan.translation(in: nil)
        w.center = CGPoint(x: w.center.x + t.x, y: w.center.y + t.y)
        pan.setTranslation(.zero, in: nil)
    }
}