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
        addLog("App 閸氼垰濮?v\(appVersion)")
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
        // daemon not running
    }

    @objc private func resetAllSettings() {@objc private func resetAllSettings() {    @objc private func resetAllSettings() {
        let alert = UIAlertController(title: "鏉╂ê甯幍鈧張澶庮啎缂?, message: "閹垹顦查崚鎵兇缂佺喖绮拋銈夊帳缂?, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閸欐牗绉?, style: .cancel))
        alert.addAction(UIAlertAction(title: "绾喖鐣炬潻妯哄斧", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.currentSource = .realCamera; self.localVideoPath = ""
            self.videoInjectionOn = true; self.audioInjectionOn = false; self.loopEnabled = true
            self.videoInjectionSwitch.isOn = true; self.audioInjectionSwitch.isOn = false
            self.loopSwitch.isOn = true
            self.localVideoPathLabel.text = "閺堫亪鈧瀚ㄩ敍鍫滅矌 MP4閿?; self.localVideoPathLabel.textColor = .secondaryLabel
            self.statusLabel.text = "瑜版挸澧? 閻喎鐤勯幗鍕剼婢?| 鐎瑰牊濮㈡潻娑氣柤: 缁涘绶熸稉?; self.statusIndicator.backgroundColor = .systemGreen
            self.updateCardVisibility(); self.updateSourceButtons()
            ["videoSource","rtmpURL","localVideoPath","videoInjection","audioInjection","loopEnabled"].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
            UserDefaults.standard.synchronize()
            self.sendControlCommand()
            self.addLog("鐠佸墽鐤嗗鑼剁箷閸樼喍璐熸妯款吇閸?)
        })
        present(alert, animated: true)
    }

    @objc private func copyRTMPURL() {
        UIPasteboard.general.string = rtmpURL
        addLog("RTMP 閸︽澘娼冨鎻掝槻閸? \(rtmpURL)")
        let a = UIAlertController(title: "瀹告彃顦查崚?, message: rtmpURL, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "绾喖鐣?, style: .default))
        present(a, animated: true)
    }

    @objc private func selectLocalVideo() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mpeg4Movie])
        picker.delegate = self; picker.allowsMultipleSelection = false
        present(picker, animated: true)
        addLog("閹垫挸绱戦弬鍥︽闁瀚ㄩ崳?(MP4)")
    }

    @objc private func loopToggled() {
        loopEnabled = loopSwitch.isOn
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
        addLog("瀵邦亞骞嗛幘顓熸杹: \(loopEnabled ? "瀵偓" : "閸?)")
    }

    @objc private func injectionToggled() {
        videoInjectionOn = videoInjectionSwitch.isOn; audioInjectionOn = audioInjectionSwitch.isOn
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        sendControlCommand()
        addLog("濞夈劌鍙嗗鈧崗? 鐟欏棝顣?\(videoInjectionOn ? "瀵偓" : "閸?) 闂婃娊顣?\(audioInjectionOn ? "瀵偓" : "閸?)")
    }

    @objc private func toggleFloatingWindow() {
        if FloatingWindowManager.shared.isShowingWindow {
            FloatingWindowManager.shared.hide()
            floatBtn.setTitle("閳?閹剚璇炵粣?, for: .normal); floatBtn.backgroundColor = .systemGray
            addLog("閹剚璇炵粣? 闂呮劘妫?)
        } else {
            FloatingWindowManager.shared.show(with: self)
            floatBtn.setTitle("棣冩暩 閹剚璇炵粣?, for: .normal); floatBtn.backgroundColor = .systemGreen
            addLog("閹剚璇炵粣? 閺勫墽銇?)
        }
    }

    @objc func applySettings() {
        switch currentSource {
        case .realCamera: statusLabel.text = "瑜版挸澧? 閻喎鐤勯幗鍕剼婢?| 鐎瑰牊濮㈡潻娑氣柤: 鏉╂劘顢戞稉?; statusIndicator.backgroundColor = .systemGreen
        case .rtmpStream: statusLabel.text = "瑜版挸澧? RTMP濞?| 鐎瑰牊濮㈡潻娑氣柤: 鏉╂劘顢戞稉?; statusIndicator.backgroundColor = .systemBlue
        case .localVideo:
            let n = localVideoPath.isEmpty ? "閺堫亪鈧瀚? : (localVideoPath as NSString).lastPathComponent
            statusLabel.text = "瑜版挸澧? 閺堫剙婀寸憴鍡涱暥 (\(n)) | 鐎瑰牊濮㈡潻娑氣柤: 鏉╂劘顢戞稉?; statusIndicator.backgroundColor = .systemOrange
        }
        sendControlCommand()
        UserDefaults.standard.set(currentSource.rawValue, forKey: "videoSource")
        UserDefaults.standard.set(rtmpURL, forKey: "rtmpURL")
        UserDefaults.standard.set(localVideoPath, forKey: "localVideoPath")
        UserDefaults.standard.set(videoInjectionOn, forKey: "videoInjection")
        UserDefaults.standard.set(audioInjectionOn, forKey: "audioInjection")
        UserDefaults.standard.set(loopEnabled, forKey: "loopEnabled")
        UserDefaults.standard.synchronize()
        addLog("鐠佸墽鐤嗗鎻掔安閻? \(["閻喎鐤勯幗鍕剼婢?,"RTMP閹恒劍绁?,"閺堫剙婀寸憴鍡涱暥"][currentSource.rawValue])")
    }


    private func sendControlCommand() {
        // 娴ｈ法鏁ら弬鍥︽閸愭瑥鍙嗛幒褍鍩楅弫鐗堝祦閿涘牊娓堕崣顖炴浆閻?iOS IPC 閺傜懓绱￠敍?        let dir = "/var/jb/tmp"
        var path = "\(dir)/rtmpcamera_control.plist"
        // 绾喕绻氶惄顔肩秿鐎涙ê婀?        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        
        let dict: [String: Any] = [
            "command": 1,
            "sourceType": currentSource.rawValue,
            "videoInjectionEnabled": videoInjectionOn,
            "audioInjectionEnabled": audioInjectionOn,
            "loopEnabled": loopEnabled,
            "rtmpURL": rtmpURL,
            "localVideoPath": localVideoPath
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            DispatchQueue.main.async { self.addLog("閹貉冨煑閺佺増宓佸鎻掑晸閸忋儲鏋冩禒?) }
        } catch {
            // fallback 閸?/tmp
            path = "/tmp/rtmpcamera_control.plist"
            try? FileManager.default.createDirectory(atPath: "/tmp", withIntermediateDirectories: true, attributes: nil)
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            DispatchQueue.main.async { self.addLog("閹貉冨煑閺佺増宓侀崘娆忓弳: \(path)") }
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
        localVideoPathLabel.text = "閴?\((url.path as NSString).lastPathComponent)"
        localVideoPathLabel.textColor = .label
        addLog("瀹告煡鈧瀚ㄧ憴鍡涱暥: \((url.path as NSString).lastPathComponent)")
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
        btn.setTitle("棣冩懖", for: .normal); btn.titleLabel?.font = .systemFont(ofSize: 30)
        btn.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
        floatWindow?.addSubview(btn)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatPanned(_:)))
        floatWindow?.addGestureRecognizer(pan)
        floatWindow?.isHidden = false
    }

    func hide() { floatWindow?.isHidden = true; floatWindow = nil; isShowing = false }

    @objc private func floatTapped() {
        guard let vc = parentVC else { return }
        let alert = UIAlertController(title: "韫囶偊鈧喎鍨忛幑?, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "閻喎鐤勯幗鍕剼婢?, style: .default) { _ in vc.realCameraBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "RTMP閹恒劍绁?, style: .default) { _ in vc.rtmpBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "閺堫剙婀寸憴鍡涱暥", style: .default) { _ in vc.localVideoBtn.sendActions(for: .touchUpInside); vc.applySettings() })
        alert.addAction(UIAlertAction(title: "闂呮劘妫岄幃顒佽癁缁?, style: .destructive) { [weak self] _ in self?.hide() })
        alert.addAction(UIAlertAction(title: "閸欐牗绉?, style: .cancel))
        vc.present(alert, animated: true)
    }

    @objc private func floatPanned(_ pan: UIPanGestureRecognizer) {
        guard let w = floatWindow else { return }
        let t = pan.translation(in: nil)
        w.center = CGPoint(x: w.center.x + t.x, y: w.center.y + t.y)
        pan.setTranslation(.zero, in: nil)
    }
}
