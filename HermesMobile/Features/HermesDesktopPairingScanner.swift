@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct HermesDesktopPairingScannerSheet: View {
    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HermesDesktopPairingScannerCamera(
                    onCode: onCode,
                    onError: { errorMessage = $0 }
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()
                    Text("Open Hermes Dashboard → Pairing, then scan the mobile companion code.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Scan desktop code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Camera unavailable",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { dismiss() }
            } message: {
                Text(errorMessage ?? "Hermes could not scan the pairing code.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct HermesDesktopPairingScannerCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> HermesDesktopPairingScannerViewController {
        HermesDesktopPairingScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(
        _ uiViewController: HermesDesktopPairingScannerViewController,
        context: Context
    ) {}
}

private final class HermesDesktopPairingScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate
{
    private let captureSession = AVCaptureSession()
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didFinish = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFinish,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty
        else {
            return
        }

        didFinish = true
        captureSession.stopRunning()
        onCode(value)
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.onError("Allow camera access in Settings to scan a Hermes Desktop pairing code.")
                    }
                }
            }
        case .denied, .restricted:
            onError("Allow camera access in Settings to scan a Hermes Desktop pairing code.")
        @unknown default:
            onError("Camera access is unavailable on this device.")
        }
    }

    private func configureAndStart() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            onError("This device does not have an available camera.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()

            captureSession.beginConfiguration()
            guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                onError("Hermes could not start the QR scanner.")
                return
            }

            captureSession.addInput(input)
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            captureSession.commitConfiguration()

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview

            captureSession.startRunning()
        } catch {
            onError("Hermes could not open the camera: \(error.localizedDescription)")
        }
    }
}
