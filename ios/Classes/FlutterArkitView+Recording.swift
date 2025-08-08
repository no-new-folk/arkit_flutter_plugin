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
        let filename = "arkit_camera_\(Int(Date().timeIntervalSince1970)).mov"
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
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            // より互換性の高い H.264 設定
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: NSNumber(value: 4_000_000), // 4Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProps,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourcePixelBufferAttributes)

            if writer.canAdd(input) {
                writer.add(input)
            }

            if writer.startWriting() {
                // セッションは 0 から開始（以後のフレームは相対時間で投入）
                writer.startSession(atSourceTime: .zero)
                recordingStartTimeSeconds = 0
                recordingWriter = writer
                recordingInput = input
                recordingAdaptor = adaptor
                recordingOutputURL = outputURL
                recordingFrameIndex = 0
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
            let movURL = self.recordingOutputURL

            // 状態クリア
            self.recordingWriter = nil
            self.recordingAdaptor = nil
            self.recordingInput = nil
            self.recordingStartTimeSeconds = nil
            self.recordingOutputURL = nil
            self.recordingFrameIndex = 0

            guard let movURL else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            // .mov -> .mp4 へ変換
            let asset = AVURLAsset(url: movURL)
            let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
            let preset = presets.contains(AVAssetExportPresetHighestQuality) ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
                DispatchQueue.main.async { result(movURL.path) }
                return
            }

            let tempDir = FileManager.default.temporaryDirectory
            let mp4URL = tempDir.appendingPathComponent("arkit_camera_\(Int(Date().timeIntervalSince1970)).mp4")
            if FileManager.default.fileExists(atPath: mp4URL.path) {
                try? FileManager.default.removeItem(at: mp4URL)
            }
            exporter.outputURL = mp4URL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true

            exporter.exportAsynchronously {
                DispatchQueue.main.async {
                    switch exporter.status {
                    case .completed:
                        // 変換成功: 元の .mov は削除
                        try? FileManager.default.removeItem(at: movURL)
                        result(mp4URL.path)
                    case .failed, .cancelled:
                        // フォールバック: 変換に失敗したら .mov を返す
                        result(movURL.path)
                    default:
                        result(movURL.path)
                    }
                }
            }
        }
    }

    func appendCurrentFrameToRecording(currentTime: TimeInterval) {
        guard let writer = recordingWriter,
              let input = recordingInput,
              let adaptor = recordingAdaptor,
              writer.status == .writing,
              input.isReadyForMoreMediaData,
              let frame = sceneView.session.currentFrame
        else { return }

        // ARコンテンツを含めない: capturedImage をそのままエンコード
        let pixelBuffer = frame.capturedImage

        // タイムスタンプ: 録画開始からの相対時間（IETF推奨の timescale 600）
        // 連番で安定した pts を与える（動画の可読性向上）
        let frameDuration = CMTime(value: 1, timescale: recordingTimescale / 30) // 約30fps
        let frameTime = CMTimeMultiply(frameDuration, multiplier: Int32(recordingFrameIndex))
        recordingFrameIndex += 1

        // capturedImage は YpCbCr なので、RGB に変換が必要。
        // 簡易に CIContext で BGRA に変換した PixelBuffer を作成して投入する。
        var outputPixelBuffer: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outBuffer = outputPixelBuffer else { return }

        // CIImage で変換
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        context.render(ciImage, to: outBuffer)

        _ = adaptor.append(outBuffer, withPresentationTime: frameTime)
    }
}


