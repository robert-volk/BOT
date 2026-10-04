import SwiftUI
import AVFoundation

/// Point the camera at something, tap the shutter, and BOT (with a Claude key) tells you what it sees.
struct CameraCaptureView: View {
    let question: String
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.denied {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 40))
                    Text("Camera access is off").font(.headline)
                    Text("Turn on the camera for BOT in iPhone Settings, then try again.")
                        .font(.subheadline).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).padding()
            } else {
                CameraPreview(session: model.session).ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                    Spacer()
                }
                .padding()
                Spacer()
                Text(question)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                Button {
                    model.capture { data in if let data { onCapture(data) } }
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(.white).frame(width: 64, height: 64)
                    }
                }
                .padding(.bottom, 28)
                .disabled(model.denied)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var denied = false

    private let output = AVCapturePhotoOutput()
    private var completion: ((Data?) -> Void)?
    private let queue = DispatchQueue(label: "bot.camera")

    @MainActor
    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { denied = true; return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let s = session
        queue.async { s.startRunning() }
    }

    func stop() {
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    func capture(_ done: @escaping (Data?) -> Void) {
        completion = done
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async { [weak self] in
            self?.completion?(data)
            self?.completion = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
