import UIKit
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

// 视频源类型 (与 SharedFrame.h 保持一致，移除测试帧)
enum VideoSourceType: Int {
    case realCamera = 0
    case rtmpStream = 1
    case localVideo = 2
}

// MARK: - 主视图控制器
class MainViewController: UIViewController {

    // MARK: - UI 组件
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // 状态卡片
    private let statusCard = UIView()
    private let statusIndicator = UIView()
    private let statusTitleLabel = UILabel()
    private let statusLabel = UILabel()

    // 视频源选择 (三个按钮代替分段控件)
    private let sourceCard = UIView()
    private let sourceTitleLabel = UILabel()
    let realCameraBtn = UIButton(type: .system)
    let rtmpBtn = UIButton(type: .system)
    let localVideoBtn = UIButton(type: .system)
    private var sourceButtons: [UIButton] { [realCameraBtn, rtmpBtn, localVideoBtn] }

    // RTMP 配置卡片
    private let rtmpCard = UIView()
    private let rtmpTitleLabel = UILabel()
    private let rtmpURLLabel = UILabel()
    private let rtmpHintLabel = UILabel()
    private let rtmpCopyButton = UIButton(type: .system)

    // 本地视频卡片
    private let localVideoCard = UIView()
    private let loopLabel = UILabel()
    private let loopSwitch = UISwitch()
    private let localVideoTitleLabel = UILabel()
    private let localVideoPathLabel = UILabel()
    private let selectVideoButton = UIButton(type: .system)

    // 注入开关卡片
    private let injectionCard = UIView()
    private let injectionTitleLabel = UILabel()
    private let videoInjectionLabel = UILabel()
    private let videoInjectionSwitch = UISwitch()
    private let audioInjectionLabel = UILabel()
    private let audioInjectionSwitch = UISwitch()

    // 悬浮窗 + 预览
    private let floatBtn = UIButton(type: .system)
    private let previewView = UIView()
    private let previewHintLabel = UILabel()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureSession: AVCaptureSession?

    // 应用按钮
    private let applyButton = UIButton(type: .system)

    // 状态
    private var currentSource: VideoSourceType = .realCamera
    private var rtmpURL: String = ""
    private var localVideoPath: String = ""
    private var videoInjectionOn: Bool = true
    private var audioInjectionOn: Bool = false
    private var loopEnabled: Bool = true
    private var phoneIP: String = ""

    private let sharedFrameQueue = DispatchQueue(label: "com.rtmpcamera.app.sharedframe")
    private let defaultRTMPPort = 1935

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        detectLocalIP()
        setupUI()
        loadSavedConfig()
        startCameraPreview()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    deinit {
        captureSession?.stopRunning()
    }

    // MARK: - IP 检测
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
                        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                                       &host, socklen_t(host.count),
                                       nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: host)
                            if ip != "127.0.0.1" && ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
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

    // MARK: - UI 设置
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "虚拟摄像头"
        navigationController?.navigationBar.prefersLargeTitles = false

        // 还原按钮
        let resetBtn = UIBarButtonItem(title: "还原", style: .plain, target: self, action: #selector(resetAllSettings))
        navigationItem.rightBarButtonItem = resetBtn

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0)
        scrollView.addSubview(contentView)

        var y: CGFloat = 16
        let w = view.bounds.width - 32

        // ==== 1. 状态卡片 ====
        setupCard(statusCard, at: &y, w: w, h: 68)
        contentView.addSubview(statusCard)

        statusIndicator.frame = CGRect(x: 14, y: 14, width: 12, height: 12)
        statusIndicator.layer.cornerRadius = 6
        statusIndicator.backgroundColor = .systemGreen
        statusCard.addSubview(statusIndicator)

        statusTitleLabel.frame = CGRect(x: 34, y: 10, width: 200, height: 20)
        statusTitleLabel.text = "虚拟摄像头状态"
        statusTitleLabel.font = .boldSystemFont(ofSize: 15)
        statusCard.addSubview(statusTitleLabel)

        statusLabel.frame = CGRect(x: 14, y: 36, width: w - 28, height: 18)
        statusLabel.text = "当前: 真实摄像头"
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusCard.addSubview(statusLabel)

        // ==== 2. 视频源选择 ====
        setupCard(sourceCard, at: &y, w: w, h: 110)
        contentView.addSubview(sourceCard)

        sourceTitleLabel.frame = CGRect(x: 14, y: 10, width: w - 28, height: 20)
        sourceTitleLabel.text = "视频源选择"
        sourceTitleLabel.font = .boldSystemFont(ofSize: 15)
        sourceCard.addSubview(sourceTitleLabel)

        let btnW = (w - 48) / 3
        let btns: [(UIButton, String, String, VideoSourceType)] = [
            (realCameraBtn, "🎥", "真实摄像头", .realCamera),
            (rtmpBtn, "📡", "RTMP推流", .rtmpStream),
            (localVideoBtn, "📁", "本地视频", .localVideo),
        ]
        for (i, (btn, icon, title, _)) in btns.enumerated() {
            let x = CGFloat(14 + Int(btnW + 10) * i)
            btn.frame = CGRect(x: x, y: 38, width: btnW, height: 58)
            btn.setTitle("\(icon)\n\(title)", for: .normal)
            btn.titleLabel?.numberOfLines = 2
            btn.titleLabel?.textAlignment = .center
            btn.titleLabel?.font = .systemFont(ofSize: 12)
            btn.backgroundColor = .systemGray6
            btn.layer.cornerRadius = 10
            btn.addTarget(self, action: #selector(sourceBtnTapped(_:)), for: .touchUpInside)
            sourceCard.addSubview(btn)
        }

        // ==== 3. RTMP 卡片 ====
        setupCard(rtmpCard, at: &y, w: w, h: 115)
        contentView.addSubview(rtmpCard)

        rtmpTitleLabel.frame = CGRect(x: 14, y: 10, width: w - 28, height: 20)
        rtmpTitleLabel.text = "📡 RTMP 推流接收"
        rtmpTitleLabel.font = .boldSystemFont(ofSize: 15)
        rtmpCard.addSubview(rtmpTitleLabel)

        rtmpURLLabel.frame = CGRect(x: 14, y: 36, width: w - 80, height: 22)
        rtmpURLLabel.text = rtmpURL
        rtmpURLLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        rtmpURLLabel.textColor = .systemBlue
        rtmpURLLabel.adjustsFontSizeToFitWidth = true
        rtmpCard.addSubview(rtmpURLLabel)

        rtmpCopyButton.frame = CGRect(x: w - 62, y: 33, width: 52, height: 28)
        rtmpCopyButton.setTitle("复制", for: .normal)
        rtmpCopyButton.backgroundColor = .systemBlue
        rtmpCopyButton.setTitleColor(.white, for: .normal)
        rtmpCopyButton.layer.cornerRadius = 8
        rtmpCopyButton.titleLabel?.font = .systemFont(ofSize: 13)
        rtmpCopyButton.addTarget(self, action: #selector(copyRTMPURL), for: .touchUpInside)
        rtmpCard.addSubview(rtmpCopyButton)

        rtmpHintLabel.frame = CGRect(x: 14, y: 66, width: w - 28, height: 36)
        rtmpHintLabel.text = "将此地址填入 OBS「推流」→「服务」→「自定义」\n手机端会自动接收并显示画面"
        rtmpHintLabel.font = .systemFont(ofSize: 11)
        rtmpHintLabel.textColor = .secondaryLabel
        rtmpHintLabel.numberOfLines = 2
        rtmpCard.addSubview(rtmpHintLabel)

        // ==== 4. 本地视频卡片 ====
        setupCard(localVideoCard, at: &y, w: w, h: 135)
        contentView.addSubview(localVideoCard)

        loopLabel.frame = CGRect(x: 14, y: 10, width: 100, height: 22)
        loopLabel.text = "循环播放"
        loopLabel.font = .boldSystemFont(ofSize: 15)
        localVideoCard.addSubview(loopLabel)

        loopSwitch.frame = CGRect(x: w - 65, y: 8, width: 51, height: 31)
        loopSwitch.isOn = loopEnabled
        loopSwitch.addTarget(self, action: #selector(loopToggled), for: .valueChanged)
        localVideoCard.addSubview(loopSwitch)

        let sep1 = UIView(frame: CGRect(x: 14, y: 40, width: w - 28, height: 1))
        sep1.backgroundColor = .separator
        localVideoCard.addSubview(sep1)

        localVideoTitleLabel.frame = CGRect(x: 14, y: 48, width: 100, height: 20)
        localVideoTitleLabel.text = "选择视频"
        localVideoTitleLabel.font = .boldSystemFont(ofSize: 15)
        localVideoCard.addSubview(localVideoTitleLabel)

        selectVideoButton.frame = CGRect(x: w - 110, y: 44, width: 96, height: 32)
        selectVideoButton.setTitle("选择 MP4", for: .normal)
        selectVideoButton.backgroundColor = .systemIndigo
        selectVideoButton.setTitleColor(.white, for: .normal)
        selectVideoButton.layer.cornerRadius = 8
        selectVideoButton.titleLabel?.font = .systemFont(ofSize: 13)
        selectVideoButton.addTarget(self, action: #selector(selectLocalVideo), for: .touchUpInside)
        localVideoCard.addSubview(selectVideoButton)

        localVideoPathLabel.frame = CGRect(x: 14, y: 82, width: w - 28, height: 36)
        localVideoPathLabel.text = "未选择文件（仅支持 MP4 格式）"
        localVideoPathLabel.font = .systemFont(ofSize: 12)
        localVideoPathLabel.textColor = .secondaryLabel
        localVideoPathLabel.numberOfLines = 2
        localVideoCard.addSubview(localVideoPathLabel)

        // ==== 5. 注入开关卡片 ====
        setupCard(injectionCard, at: &y, w: w, h: 80)
        contentView.addSubview(injectionCard)

        injectionTitleLabel.frame = CGRect(x: 14, y: 10, width: 200, height: 20)
        injectionTitleLabel.text = "注入控制"
        injectionTitleLabel.font = .boldSystemFont(ofSize: 15)
        injectionCard.addSubview(injectionTitleLabel)

        videoInjectionLabel.frame = CGRect(x: 14, y: 42, width: 80, height: 24)
        videoInjectionLabel.text = "注入视频"
        videoInjectionLabel.font = .systemFont(ofSize: 14)
        injectionCard.addSubview(videoInjectionLabel)

        videoInjectionSwitch.frame = CGRect(x: w - 65, y: 39, width: 51, height: 31)
        videoInjectionSwitch.isOn = videoInjectionOn
        videoInjectionSwitch.addTarget(self, action: #selector(injectionToggled), for: .valueChanged)
        injectionCard.addSubview(videoInjectionSwitch)

        audioInjectionLabel.frame = CGRect(x: 140, y: 42, width: 80, height: 24)
        audioInjectionLabel.text = "注入音频"
        audioInjectionLabel.font = .systemFont(ofSize: 14)
        injectionCard.addSubview(audioInjectionLabel)

        audioInjectionSwitch.frame = CGRect(x: w - 170, y: 39, width: 51, height: 31)
        audioInjectionSwitch.isOn = audioInjectionOn
        audioInjectionSwitch.addTarget(self, action: #selector(injectionToggled), for: .valueChanged)
        injectionCard.addSubview(audioInjectionSwitch)

        // ==== 6. 预览区域 ====
        setupCard(previewView, at: &y, w: w, h: 180)
        previewView.clipsToBounds = true
        previewView.backgroundColor = .black
        contentView.addSubview(previewView)

        previewHintLabel.frame = CGRect(x: 10, y: previewView.bounds.height - 22, width: w - 20, height: 16)
        previewHintLabel.text = "预览画面"
        previewHintLabel.font = .systemFont(ofSize: 10)
        previewHintLabel.textColor = .white.withAlphaComponent(0.6)
        previewHintLabel.autoresizingMask = [.flexibleTopMargin, .flexibleWidth]
        previewView.addSubview(previewHintLabel)

        // ==== 7. 悬浮窗 + 应用按钮 ====
        y += 8
        floatBtn.frame = CGRect(x: 14, y: y, width: (w - 24) / 2, height: 44)
        floatBtn.setTitle("⚪ 显示悬浮窗", for: .normal)
        floatBtn.backgroundColor = .systemGray
        floatBtn.setTitleColor(.white, for: .normal)
        floatBtn.layer.cornerRadius = 10
        floatBtn.titleLabel?.font = .boldSystemFont(ofSize: 14)
        floatBtn.addTarget(self, action: #selector(toggleFloatingWindow), for: .touchUpInside)
        contentView.addSubview(floatBtn)

        applyButton.frame = CGRect(x: (w - 24) / 2 + 22, y: y, width: (w - 24) / 2, height: 44)
        applyButton.setTitle("应用设置", for: .normal)
        applyButton.backgroundColor = .systemBlue
        applyButton.setTitleColor(.white, for: .normal)
        applyButton.layer.cornerRadius = 10
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 14)
        applyButton.addTarget(self, action: #selector(applySettings), for: .touchUpInside)
        contentView.addSubview(applyButton)

        y += 60

        contentView.frame.size.height = y
        scrollView.contentSize = contentView.frame.size

        updateCardVisibility()
        updateSourceButtons()
    }

    private func setupCard(_ card: UIView, at y: inout CGFloat, w: CGFloat, h: CGFloat) {
        card.frame = CGRect(x: 16, y: y, width: w, height: h)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 12
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.05
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 6
        y += h + 12
    }

    // MARK: - 预览
    private func startCameraPreview() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              let session = captureSession,
              session.canAddInput(input) else { return }

        session.addInput(input)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds
        layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    // MARK: - 卡片显隐
    private func updateCardVisibility() {
        rtmpCard.isHidden = (currentSource != .rtmpStream)
        localVideoCard.isHidden = (currentSource != .localVideo)
    }

    private func updateSourceButtons() {
        for btn in sourceButtons {
            btn.backgroundColor = .systemGray6
            btn.setTitleColor(.label, for: .normal)
        }
        switch currentSource {
        case .realCamera:
            realCameraBtn.backgroundColor = .systemBlue
            realCameraBtn.setTitleColor(.white, for: .normal)
        case .rtmpStream:
            rtmpBtn.backgroundColor = .systemBlue
            rtmpBtn.setTitleColor(.white, for: .normal)
        case .localVideo:
            localVideoBtn.backgroundColor = .systemBlue
            localVideoBtn.setTitleColor(.white, for: .normal)
        }
    }

    // MARK: - 交互

    @objc private func sourceBtnTapped(_ sender: UIButton) {
        if sender == realCameraBtn { currentSource = .realCamera }
        else if sender == rtmpBtn { currentSource = .rtmpStream }
        else if sender == localVideoBtn { currentSource = .localVideo }
        updateCardVisibility()
        updateSourceButtons()
    }

    @objc private func resetAllSettings() {
        let alert = UIAlertController(title: "还原所有设置", message: "将恢复到系统默认配置", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定还原", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.currentSource = .realCamera
            self.localVideoPath = ""
            self.videoInjectionOn = true
            self.audioInjectionOn = false
            self.loopEnabled = true

            self.videoInjectionSwitch.isOn = true
            self.audioInjectionSwitch.isOn = false
            self.loopSwitch.isOn = true
            self.localVideoPathLabel.text = "未选择文件（仅支持 MP4 格式）"
            self.localVideoPathLabel.textColor = .secondaryLabel
            self.statusLabel.text = "当前: 真实摄像头"
            self.statusIndicator.backgroundColor = .systemGreen

            self.updateCardVisibility()
            self.updateSourceButtons()

            // 清除持久化
            ["videoSource", "rtmpURL", "localVideoPath", "videoInjection", "audioInjection", "loopEnabled"].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
            UserDefaults.standard.synchronize()

            self.sendControlCommand()
        })
        present(alert, animated: true)
    }

    @objc private func copyRTMPURL() {
        UIPasteboard.general.string = rtmpURL
        let alert = UIAlertController(title: "已复制", message: "RTMP 地址已复制到剪贴板，\n请粘贴到 OBS 推流设置中", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    @objc private func selectLocalVideo() {
        // 只选择 MP4 格式
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mpeg4Movie])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func loopToggled() {
        loopEnabled = loopSwitch.isOn
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
    }

    @objc private func injectionToggled() {
        videoInjectionOn = videoInjectionSwitch.isOn
        audioInjectionOn = audioInjectionSwitch.isOn
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        sendControlCommand()
    }

    @objc private func toggleFloatingWindow() {
        if FloatingWindowManager.shared.isShowing {
            FloatingWindowManager.shared.hide()
            floatBtn.setTitle("⚪ 显示悬浮窗", for: .normal)
            floatBtn.backgroundColor = .systemGray
        } else {
            FloatingWindowManager.shared.show(with: self)
            floatBtn.setTitle("🔵 隐藏悬浮窗", for: .normal)
            floatBtn.backgroundColor = .systemGreen
        }
    }

    @objc private func applySettings() {
        switch currentSource {
        case .realCamera:
            statusLabel.text = "当前: 真实摄像头"
            statusIndicator.backgroundColor = .systemGreen
        case .rtmpStream:
            statusLabel.text = "当前: RTMP流 - 接收中"
            statusIndicator.backgroundColor = .systemBlue
        case .localVideo:
            let name = localVideoPath.isEmpty ? "未选择" : (localVideoPath as NSString).lastPathComponent
            statusLabel.text = "当前: 本地视频 - \(name)"
            statusIndicator.backgroundColor = .systemOrange
        }

        sendControlCommand()

        UserDefaults.standard.set(currentSource.rawValue, forKey: "videoSource")
        UserDefaults.standard.set(rtmpURL, forKey: "rtmpURL")
        UserDefaults.standard.set(localVideoPath, forKey: "localVideoPath")
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
        UserDefaults.standard.synchronize()

        let alert = UIAlertController(title: "设置已应用", message: "打开微信/视频号等 App 即可看到效果", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 共享内存控制
    private func sendControlCommand() {
        sharedFrameQueue.async { [weak self] in
            guard let self = self else { return }

            let controlFD = shm_open(CONTROL_MEMORY_NAME, O_RDWR, 0)
            guard controlFD >= 0 else {
                DispatchQueue.main.async { print("控制内存未创建") }
                return
            }
            defer { close(controlFD) }

            let size = MemoryLayout<SharedControlData>.size
            let ptr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, controlFD, 0)
            guard ptr != MAP_FAILED else {
                DispatchQueue.main.async { print("映射失败") }
                return
            }
            defer { munmap(ptr, size) }

            let ctrl = ptr.bindMemory(to: SharedControlData.self, capacity: 1)

            ctrl.pointee.command = 1 // RTMPControlSwitchSource
            ctrl.pointee.sourceType = UInt32(self.currentSource.rawValue)
            ctrl.pointee.videoInjectionEnabled = self.videoInjectionOn ? 1 : 0
            ctrl.pointee.audioInjectionEnabled = self.audioInjectionOn ? 1 : 0
            ctrl.pointee.loopEnabled = self.loopEnabled ? 1 : 0

            // RTMP URL
            let url = self.rtmpURL.utf8CString
            withUnsafeMutablePointer(to: &ctrl.pointee.rtmpURL) { dest in
                _ = url.withUnsafeBytes { src in
                    memcpy(dest, src.baseAddress!, min(src.count, MAX_RTMP_URL_LENGTH - 1))
                }
                dest[min(url.count, MAX_RTMP_URL_LENGTH - 1)] = 0
            }

            // 本地视频路径
            let path = self.localVideoPath.utf8CString
            let pathDest = ptr.advanced(by: MemoryLayout<SharedControlData>.offset(of: \SharedControlData.localVideoPath)!)
                .bindMemory(to: CChar.self, capacity: MAX_VIDEO_PATH_LENGTH)
            _ = path.withUnsafeBytes { src in
                memcpy(pathDest, src.baseAddress!, min(src.count, MAX_VIDEO_PATH_LENGTH - 1))
            }
            pathDest[min(path.count, MAX_VIDEO_PATH_LENGTH - 1)] = 0
        }
    }

    // MARK: - 配置持久化
    private func loadSavedConfig() {
        let savedSource = UserDefaults.standard.integer(forKey: "videoSource")
        if savedSource >= 0 && savedSource <= 2 {
            currentSource = VideoSourceType(rawValue: savedSource) ?? .realCamera
        }
        if let url = UserDefaults.standard.string(forKey: "rtmpURL"), !url.isEmpty {
            rtmpURL = url
        }
        if let path = UserDefaults.standard.string(forKey: "localVideoPath") {
            localVideoPath = path
            localVideoPathLabel.text = (path as NSString).lastPathComponent
            localVideoPathLabel.textColor = .label
        }
        videoInjectionOn = UserDefaults.standard.bool(forKey: "videoInjection")
        audioInjectionOn = UserDefaults.standard.bool(forKey: "audioInjection")
        loopEnabled = UserDefaults.standard.object(forKey: "loopEnabled") as? Bool ?? true

        // 首次: videoInjection 默认 true
        if UserDefaults.standard.object(forKey: "videoInjection") == nil {
            videoInjectionOn = true
        }

        videoInjectionSwitch.isOn = videoInjectionOn
        audioInjectionSwitch.isOn = audioInjectionOn
        loopSwitch.isOn = loopEnabled
        updateCardVisibility()
        updateSourceButtons()
    }
}

// MARK: - UIDocumentPickerDelegate
extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        localVideoPath = url.path
        localVideoPathLabel.text = "✅ \((url.path as NSString).lastPathComponent)"
        localVideoPathLabel.textColor = .label
    }
}

// MARK: - 悬浮窗管理器
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

        let size: CGFloat = 80
        let scene = UIApplication.shared.connectedScenes.compactMap({ let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        floatWindow = UIWindow(windowScene: scene ?? UIWindowScene()) as? UIWindowScene }).first
        if let sc = scene {
            floatWindow = UIWindow(windowScene: sc)
        } else {
            floatWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        floatWindow?.frame = CGRect(x: UIScreen.main.bounds.width - size - 16, y: 200, width: size, height: size)
        floatWindow?.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        floatWindow?.layer.cornerRadius = size / 2
        floatWindow?.layer.shadowColor = UIColor.black.cgColor
        floatWindow?.layer.shadowOpacity = 0.3
        floatWindow?.layer.shadowOffset = CGSize(width: 0, height: 2)
        floatWindow?.layer.shadowRadius = 8
        floatWindow?.windowLevel = .alert + 1

        let btn = UIButton(frame: floatWindow!.bounds)
        btn.setTitle("📷", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 32)
        btn.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
        floatWindow?.addSubview(btn)

        // 拖拽手势
        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatPanned(_:)))
        floatWindow?.addGestureRecognizer(pan)

        floatWindow?.isHidden = false
    }

    func hide() {
        floatWindow?.isHidden = true
        floatWindow = nil
        isShowing = false
    }

    @objc private func floatTapped() {
        guard let vc = parentVC else { return }
        let alert = UIAlertController(title: "快速切换", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "真实摄像头", style: .default) { _ in
            vc.realCameraBtn.sendActions(for: .touchUpInside)
            vc.applySettings()
        })
        alert.addAction(UIAlertAction(title: "RTMP推流", style: .default) { _ in
            vc.rtmpBtn.sendActions(for: .touchUpInside)
            vc.applySettings()
        })
        alert.addAction(UIAlertAction(title: "本地视频", style: .default) { _ in
            vc.localVideoBtn.sendActions(for: .touchUpInside)
            vc.applySettings()
        })
        alert.addAction(UIAlertAction(title: "隐藏悬浮窗", style: .destructive) { [weak self] _ in
            self?.hide()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.present(alert, animated: true)
    }

    @objc private func floatPanned(_ pan: UIPanGestureRecognizer) {
        guard let window = floatWindow else { return }
        let translation = pan.translation(in: nil)
        window.center = CGPoint(x: window.center.x + translation.x, y: window.center.y + translation.y)
        pan.setTranslation(.zero, in: nil)
    }
}



