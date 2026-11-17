import SwiftUI
import UIKit
import AVFoundation
import CoreImage

// A request owns its session. All session and delegate work uses the same queue.
final class RearFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "jarvis.camera.frame")
    private let session = AVCaptureSession()
    private var reply: CheckedContinuation<UIImage?, Never>?
    private var readyAfter = Date.distantFuture
    private var cancelled = false
    func capture() async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.reply = continuation
                guard !self.cancelled,
                      let lens = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: lens),
                      self.session.canAddInput(input) else { self.finish(nil); return }
                self.session.addInput(input)
                if self.session.canSetSessionPreset(.vga640x480) { self.session.sessionPreset = .vga640x480 }
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                guard self.session.canAddOutput(output) else { self.finish(nil); return }
                self.session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: self.queue)
                self.readyAfter = Date().addingTimeInterval(0.35)
                self.session.startRunning()
                self.queue.asyncAfter(deadline: .now() + 3) { self.finish(nil) }
            }
        }
    }
    func cancel() { queue.async { self.cancelled = true; self.finish(nil) } }
    private func finish(_ image: UIImage?) {
        guard let completion = reply else { return }
        reply = nil
        if session.isRunning { session.stopRunning() }
        completion.resume(returning: image)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard reply != nil, Date() >= readyAfter, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let pixels = CIContext().createCGImage(image, from: image.extent) else { return }
        finish(UIImage(cgImage: pixels, scale: 1, orientation: .right))
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}
