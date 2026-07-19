import UIKit
import AVFoundation
import CoreMedia

// 视频源类型 (与 SharedFrame.h 保持一致)
enum VideoSourceType: Int {
    case realCamera = 0
    case rtmpStream = 1
    case localVideo = 2
    case testPattern = 3
}

// MARK: - 主视图控制器
class MainViewController: UIViewController {

    // MARK: - UI 组件
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let statusIndicator = UIView()

    // 视频源选择
    private let sourceSegment = UISegmentedControl(items: [
        "真实摄像头", "RTMP流", "本地视频", "测试帧"
    ])

    // RTMP 地址输入区域
    private let rtmpContainer = UIView()
    private let rtmpLabel = UILabel()
    private let rtmpTextField = UITextField()
    private let rtmpStatusLabel = UILabel()

    // 本地视频区域
    private let localVideoContainer = UIView()
    private let localVideoLabel = UILabel()
    private let localVideoPathLabel = UILabel()
    private let selectVideoButton = UIButton(type: .system)

    // 测试帧区域
    private let testPatternContainer = UIView()
    private let testPatternLabel = UILabel()
    private let testPatternSegment = UISegmentedControl(items: [
        "纯红色", "纯绿色", "纯蓝色", "渐变"
    ])

    // 控制按钮
    private let applyButton = UIButton(type: .system)
    private let previewContainer = UIView()
    private let previewLabel = UILabel()

    // 当前状态
    private var currentSource: VideoSourceType = .realCamera
    private var rtmpURL: String = "rtmp://192.168.1.100/live/stream"
    private var localVideoPath: String = ""
    private var testPattern: Int = 0
    private var isActive: Bool = false

    // 共享内存操作
    private let sharedFrameQueue = DispatchQueue(label: "com.rtmpcamera.app.sharedframe")

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadSavedConfig()
    }

    // MARK: - UI 设置
    private func setupUI() {
        view.backgroundColor = UIColor.systemGroupedBackground
        title = "虚拟摄像头"
        navigationController?.navigationBar.prefersLargeTitles = true

        let scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let contentView = UIView()
        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        var yOffset: CGFloat = 20

        // ---- 状态指示器 ----
        let statusCard = createCardView()
        contentView.addSubview(statusCard)

        statusIndicator.frame = CGRect(x: 16, y: 16, width: 14, height: 14)
        statusIndicator.layer.cornerRadius = 7
        statusIndicator.backgroundColor = .systemGray
        statusCard.addSubview(statusIndicator)

        titleLabel.frame = CGRect(x: 38, y: 12, width: 200, height: 22)
        titleLabel.text = "虚拟摄像头状态"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        statusCard.addSubview(titleLabel)

        statusLabel.frame = CGRect(x: 16, y: 40, width: 300, height: 18)
        statusLabel.text = "当前: 真实摄像头"
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusCard.addSubview(statusLabel)

        statusCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 70)
        yOffset += 86

        // ---- 视频源切换 ----
        let sourceCard = createCardView()
        contentView.addSubview(sourceCard)

        let sourceTitle = UILabel(frame: CGRect(x: 16, y: 12, width: 260, height: 22))
        sourceTitle.text = "视频源切换"
        sourceTitle.font = UIFont.boldSystemFont(ofSize: 17)
        sourceCard.addSubview(sourceTitle)

        sourceSegment.frame = CGRect(x: 12, y: 42, width: sourceCard.bounds.width - 24, height: 36)
        sourceSegment.selectedSegmentIndex = 0
        sourceSegment.addTarget(self, action: #selector(sourceChanged(_:)), for: .valueChanged)
        sourceCard.addSubview(sourceSegment)

        sourceCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 90)
        yOffset += 106

        // ---- RTMP 配置 ----
        let rtmpCard = createCardView()
        contentView.addSubview(rtmpCard)
        setupRTMPSection(in: rtmpCard)
        rtmpCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 110)
        yOffset += 126

        // ---- 本地视频 ----
        let localCard = createCardView()
        contentView.addSubview(localCard)
        setupLocalVideoSection(in: localCard)
        localCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 100)
        localCard.isHidden = true
        yOffset += 116

        // ---- 测试帧 ----
        let testCard = createCardView()
        contentView.addSubview(testCard)
        setupTestPatternSection(in: testCard)
        testCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 90)
        testCard.isHidden = true
        yOffset += 106

        // ---- 应用按钮 ----
        applyButton.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 48)
        applyButton.setTitle("应用设置", for: .normal)
        applyButton.backgroundColor = .systemBlue
        applyButton.setTitleColor(.white, for: .normal)
        applyButton.layer.cornerRadius = 12
        applyButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        applyButton.addTarget(self, action: #selector(applySettings), for: .touchUpInside)
        contentView.addSubview(applyButton)
        yOffset += 64

        // ---- 预览提示 ----
        let previewCard = createCardView()
        contentView.addSubview(previewCard)
        previewLabel.frame = CGRect(x: 16, y: 12, width: previewCard.bounds.width - 32, height: 40)
        previewLabel.text = "设置已应用后，打开微信/视频号等App\n即可看到虚拟摄像头画面"
        previewLabel.numberOfLines = 2
        previewLabel.font = UIFont.systemFont(ofSize: 13)
        previewLabel.textColor = .secondaryLabel
        previewCard.addSubview(previewLabel)
        previewCard.frame = CGRect(x: 16, y: yOffset, width: view.bounds.width - 32, height: 60)
        yOffset += 80

        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: yOffset)
        scrollView.contentSize = contentView.frame.size

        // 保存引用用于显隐
        contentView.accessibilityElements = [rtmpCard, localCard, testCard]
        rtmpContainer.tag = 100
        localVideoContainer.tag = 101
        testPatternContainer.tag = 102

        // 初始状态
        updateVisibleSections()
    }

    private func setupRTMPSection(in card: UIView) {
        rtmpLabel.frame = CGRect(x: 16, y: 12, width: 260, height: 22)
        rtmpLabel.text = "RTMP 推流地址"
        rtmpLabel.font = UIFont.boldSystemFont(ofSize: 15)
        card.addSubview(rtmpLabel)

        rtmpTextField.frame = CGRect(x: 16, y: 40, width: card.bounds.width - 32, height: 38)
        rtmpTextField.borderStyle = .roundedRect
        rtmpTextField.placeholder = "rtmp://192.168.1.100/live/stream"
        rtmpTextField.text = rtmpURL
        rtmpTextField.autocapitalizationType = .none
        rtmpTextField.autocorrectionType = .no
        rtmpTextField.keyboardType = .URL
        rtmpTextField.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        card.addSubview(rtmpTextField)

        rtmpStatusLabel.frame = CGRect(x: 16, y: 82, width: card.bounds.width - 32, height: 16)
        rtmpStatusLabel.text = "请输入 OBS 推流地址"
        rtmpStatusLabel.font = UIFont.systemFont(ofSize: 12)
        rtmpStatusLabel.textColor = .secondaryLabel
        card.addSubview(rtmpStatusLabel)
    }

    private func setupLocalVideoSection(in card: UIView) {
        localVideoLabel.frame = CGRect(x: 16, y: 12, width: 260, height: 22)
        localVideoLabel.text = "本地视频文件"
        localVideoLabel.font = UIFont.boldSystemFont(ofSize: 15)
        card.addSubview(localVideoLabel)

        localVideoPathLabel.frame = CGRect(x: 16, y: 40, width: card.bounds.width - 120, height: 18)
        localVideoPathLabel.text = "未选择文件"
        localVideoPathLabel.font = UIFont.systemFont(ofSize: 13)
        localVideoPathLabel.textColor = .secondaryLabel
        card.addSubview(localVideoPathLabel)

        selectVideoButton.frame = CGRect(
            x: card.bounds.width - 110, y: 36,
            width: 94, height: 32
        )
        selectVideoButton.setTitle("选择文件", for: .normal)
        selectVideoButton.backgroundColor = .systemIndigo
        selectVideoButton.setTitleColor(.white, for: .normal)
        selectVideoButton.layer.cornerRadius = 8
        selectVideoButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        selectVideoButton.addTarget(self, action: #selector(selectLocalVideo), for: .touchUpInside)
        card.addSubview(selectVideoButton)
    }

    private func setupTestPatternSection(in card: UIView) {
        testPatternLabel.frame = CGRect(x: 16, y: 12, width: 260, height: 22)
        testPatternLabel.text = "测试帧颜色"
        testPatternLabel.font = UIFont.boldSystemFont(ofSize: 15)
        card.addSubview(testPatternLabel)

        testPatternSegment.frame = CGRect(x: 12, y: 42, width: card.bounds.width - 24, height: 36)
        testPatternSegment.selectedSegmentIndex = 0
        card.addSubview(testPatternSegment)
    }

    private func createCardView() -> UIView {
        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.06
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowRadius = 8
        return card
    }

    // MARK: - 交互

    @objc private func sourceChanged(_ sender: UISegmentedControl) {
        currentSource = VideoSourceType(rawValue: sender.selectedSegmentIndex) ?? .realCamera
        updateVisibleSections()
    }

    private func updateVisibleSections() {
        guard let cards = view.subviews.first?.subviews.first?.accessibilityElements as? [UIView] else { return }

        for card in cards {
            if card.tag == 100 { card.isHidden = (currentSource != .rtmpStream) }
            if card.tag == 101 { card.isHidden = (currentSource != .localVideo) }
            if card.tag == 102 { card.isHidden = (currentSource != .testPattern) }
        }
    }

    @objc private func selectLocalVideo() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .movie, .mpeg4Movie, .quickTimeMovie
        ])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func applySettings() {
        let newURL = rtmpTextField.text ?? ""
        let patternIndex = testPatternSegment.selectedSegmentIndex

        // 更新状态
        switch currentSource {
        case .realCamera:
            statusLabel.text = "当前: 真实摄像头"
            statusIndicator.backgroundColor = .systemGreen
        case .rtmpStream:
            statusLabel.text = "当前: RTMP流 - \(newURL)"
            statusIndicator.backgroundColor = .systemBlue
        case .localVideo:
            statusLabel.text = "当前: 本地视频 - \(localVideoPath.isEmpty ? "未选择" : (localVideoPath as NSString).lastPathComponent)"
            statusIndicator.backgroundColor = .systemOrange
        case .testPattern:
            statusLabel.text = "当前: 测试帧 - 模式\(patternIndex + 1)"
            statusIndicator.backgroundColor = .systemPurple
        }

        // 通过共享内存发送控制命令到 Daemon
        sendControlCommand()

        // 保存设置
        UserDefaults.standard.set(currentSource.rawValue, forKey: "videoSource")
        UserDefaults.standard.set(newURL, forKey: "rtmpURL")
        UserDefaults.standard.set(patternIndex, forKey: "testPattern")
        UserDefaults.standard.synchronize()

        // 提示
        let alert = UIAlertController(
            title: "设置已应用",
            message: "视频源已切换，请打开目标 App 查看效果",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 共享内存控制

    private func sendControlCommand() {
        sharedFrameQueue.async { [weak self] in
            guard let self = self else { return }

            let controlFD = open("/tmp/rtmpcamera_control", O_RDWR)
            guard controlFD >= 0 else {
                DispatchQueue.main.async {
                    self.rtmpStatusLabel.text = "无法连接守护进程 (共享内存未创建)"
                    self.rtmpStatusLabel.textColor = .systemRed
                }
                return
            }
            defer { close(controlFD) }

            // 映射控制内存
            let ptr = mmap(nil, 2048, PROT_READ | PROT_WRITE, MAP_SHARED, controlFD, 0)
            guard ptr != MAP_FAILED else {
                DispatchQueue.main.async {
                    self.rtmpStatusLabel.text = "映射控制内存失败"
                    self.rtmpStatusLabel.textColor = .systemRed
                }
                return
            }
            defer { munmap(ptr, 2048) }

            let control = ptr.bindMemory(to: Int32.self, capacity: 512)

            // 写入命令: [command, sourceType, ...]
            control[0] = 3 // RTMPControlSwitchSource = 3
            control[1] = Int32(self.currentSource.rawValue)

            if self.currentSource == .rtmpStream {
                // 写入 RTMP URL
                let url = self.rtmpTextField.text ?? ""
                let urlData = url.utf8CString
                let dest = ptr.advanced(by: 8).bindMemory(to: CChar.self, capacity: 512)
                _ = urlData.withUnsafeBytes { src in
                    memcpy(dest, src.baseAddress!, min(src.count, 511))
                }
                dest[min(urlData.count, 511)] = 0
            }

            if self.currentSource == .localVideo {
                let path = self.localVideoPath.utf8CString
                let dest = ptr.advanced(by: 8 + 512).bindMemory(to: CChar.self, capacity: 1024)
                _ = path.withUnsafeBytes { src in
                    memcpy(dest, src.baseAddress!, min(src.count, 1023))
                }
                dest[min(path.count, 1023)] = 0
            }

            DispatchQueue.main.async {
                self.rtmpStatusLabel.text = "控制命令已发送"
                self.rtmpStatusLabel.textColor = .systemGreen
            }
        }
    }

    // MARK: - 配置持久化

    private func loadSavedConfig() {
        let savedSource = UserDefaults.standard.integer(forKey: "videoSource")
        if savedSource >= 0 && savedSource <= 3 {
            currentSource = VideoSourceType(rawValue: savedSource) ?? .realCamera
            sourceSegment.selectedSegmentIndex = savedSource
        }
        if let url = UserDefaults.standard.string(forKey: "rtmpURL") {
            rtmpURL = url
            rtmpTextField.text = url
        }
        testPatternSegment.selectedSegmentIndex = UserDefaults.standard.integer(forKey: "testPattern")
        updateVisibleSections()
    }
}

// MARK: - UIDocumentPickerDelegate
extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // 获取安全范围访问
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        localVideoPath = url.path
        localVideoPathLabel.text = (url.path as NSString).lastPathComponent
        localVideoPathLabel.textColor = .label
    }
}
