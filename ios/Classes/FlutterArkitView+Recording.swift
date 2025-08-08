import ARKit
import AVFoundation

extension FlutterArkitView {
    func startRecording(_ result: @escaping FlutterResult) {
        guard !isRecording else {
            // 既に録画中なら成功として返す（冪等）
            result(true)
            return
        }

        guard let frame = sceneView.session.currentFrame else {
            logPluginError("no current frame to start recording", toChannel: channel)
            result(false)
            return
        }

        // 出力先: temporaryDirectory
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "arkit_camera_\(Int(Date().timeIntervalSince1970)).mp4"
        let outputURL = tempDir.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            logPluginError("failed to cleanup temp file: \(error)", toChannel: channel)
        }

        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourcePixelBufferAttributes)

            if writer.canAdd(input) {
                writer.add(input)
            }

            if writer.startWriting() {
                let startSeconds = CACurrentMediaTime()
                let startTime = CMTime(seconds: startSeconds, preferredTimescale: 1_000_000)
                writer.startSession(atSourceTime: startTime)
                recordingStartTimeSeconds = startSeconds
                recordingWriter = writer
                recordingInput = input
                recordingAdaptor = adaptor
                recordingOutputURL = outputURL
                isRecording = true
                result(true)
            } else {
                logPluginError("failed to start writing", toChannel: channel)
                result(false)
            }
        } catch {
            logPluginError("failed to start recording: \(error)", toChannel: channel)
            result(false)
        }
    }

    func stopRecording(_ result: @escaping FlutterResult) {
        guard isRecording, let writer = recordingWriter, let input = recordingInput else {
            // 録画していない場合は nil を返す
            result(nil)
            return
        }

        isRecording = false
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            let path = self.recordingOutputURL?.path
            self.recordingWriter = nil
            self.recordingAdaptor = nil
            self.recordingInput = nil
            self.recordingStartTimeSeconds = nil
            self.recordingOutputURL = nil
            DispatchQueue.main.async {
                result(path)
            }
        }
    }

    func appendCurrentFrameToRecording(currentTime: TimeInterval) {
        guard let writer = recordingWriter,
              let input = recordingInput,
              let adaptor = recordingAdaptor,
              let startSeconds = recordingStartTimeSeconds,
              writer.status == .writing,
              input.isReadyForMoreMediaData,
              let frame = sceneView.session.currentFrame
        else { return }

        // ARコンテンツを含めない: capturedImage をそのままエンコード
        let pixelBuffer = frame.capturedImage

        // タイムスタンプ: 録画開始からの相対時間
        let timestampSeconds = CACurrentMediaTime() - startSeconds
        let frameTime = CMTime(seconds: timestampSeconds, preferredTimescale: 1_000_000)

        // capturedImage は YpCbCr なので、RGB に変換が必要。
        // 簡易に CIContext で BGRA に変換した PixelBuffer を作成して投入する。
        var outputPixelBuffer: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]

        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return }

        // CIImage で変換
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        context.render(ciImage, to: outBuffer)

        _ = adaptor.append(outBuffer, withPresentationTime: frameTime)
    }
}


