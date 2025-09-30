import ARKit
import AVFoundation
import UIKit

extension FlutterArkitView {
    func startRecording(_ args: [String: Any]?, _ result: @escaping FlutterResult) {
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
        let cameraWidth = CVPixelBufferGetWidth(pixelBuffer)
        let cameraHeight = CVPixelBufferGetHeight(pixelBuffer)

        // Dartからの指定サイズ（未指定時はカメラ原寸）
        let requestedWidth = (args?["width"] as? Int) ?? Int(cameraWidth)
        let requestedHeight = (args?["height"] as? Int) ?? Int(cameraHeight)
        
        // Dartからの指定FPS（未指定時は30fps）
        recordingFps = (args?["fps"] as? Int) ?? 30

        // 端末の向きを取得
        let orientation = UIApplication.shared.statusBarOrientation
        let isPortrait = (orientation == .portrait || orientation == .portraitUpsideDown)
        
        // Portrait時は出力サイズを入れ替えて常に横長に（Landscape時はそのまま）
        let videoWidth = isPortrait ? requestedHeight : requestedWidth
        let videoHeight = isPortrait ? requestedWidth : requestedHeight
        
        // PixelBuffer生成用（常に横長）
        recordingOutputWidth = videoWidth
        recordingOutputHeight = videoHeight

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            // より互換性の高い H.264 設定
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: NSNumber(value: 1_000_000), // 1Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: compressionProps,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            // 端末の向きに応じて出力トラックを回転（iPad/iPhone共通）
            var transform = CGAffineTransform.identity
            
            switch orientation {
            case .portrait:
                // Portrait: 90度時計回り回転
                transform = CGAffineTransform(rotationAngle: CGFloat.pi / 2)
                transform = transform.translatedBy(x: 0, y: -CGFloat(videoHeight))
            case .portraitUpsideDown:
                // Portrait Upside Down: 270度時計回り回転（-90度）
                transform = CGAffineTransform(rotationAngle: -CGFloat.pi / 2)
                transform = transform.translatedBy(x: -CGFloat(videoWidth), y: 0)
            case .landscapeLeft:
                // Landscape Left: 180度回転
                transform = CGAffineTransform(rotationAngle: CGFloat.pi)
                transform = transform.translatedBy(x: -CGFloat(videoWidth), y: -CGFloat(videoHeight))
            case .landscapeRight:
                // Landscape Right: 回転なし
                transform = CGAffineTransform.identity
            default:
                // Unknown: デフォルトでPortrait扱い
                transform = CGAffineTransform(rotationAngle: CGFloat.pi / 2)
                transform = transform.translatedBy(x: 0, y: -CGFloat(videoHeight))
            }
            
            input.transform = transform

            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
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
            self.recordingFps = 30

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

        // タイムスタンプ: 指定されたfps相当の安定したPTS
        let timescale = recordingTimescale
        let step = max(Int64(timescale / Int32(recordingFps)), 1)
        let frameDuration = CMTime(value: step, timescale: timescale)
        let frameTime = CMTimeMultiply(frameDuration, multiplier: Int32(recordingFrameIndex))
        recordingFrameIndex += 1

        // capturedImage は YpCbCr なので、RGB に変換が必要。
        // 簡易に CIContext で BGRA に変換した PixelBuffer を作成して投入する。
        var outputPixelBuffer: CVPixelBuffer?
        let width = recordingOutputWidth > 0 ? recordingOutputWidth : CVPixelBufferGetWidth(pixelBuffer)
        let height = recordingOutputHeight > 0 ? recordingOutputHeight : CVPixelBufferGetHeight(pixelBuffer)
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
        
        // アスペクト比を維持したまま中央クロップ
        let sourceWidth = ciImage.extent.width
        let sourceHeight = ciImage.extent.height
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        
        // アスペクト比を計算
        let sourceAspect = sourceWidth / sourceHeight
        let targetAspect = targetWidth / targetHeight
        
        var finalImage: CIImage
        
        if abs(sourceAspect - targetAspect) < 0.01 {
            // アスペクト比がほぼ同じ: 単純にスケール
            finalImage = ciImage.transformed(by: CGAffineTransform(scaleX: targetWidth / sourceWidth,
                                                                    y: targetHeight / sourceHeight))
        } else {
            // アスペクト比が異なる: アスペクト比を維持して中央クロップ
            let scale: CGFloat
            let cropX: CGFloat
            let cropY: CGFloat
            
            if sourceAspect > targetAspect {
                // ソースの方が横長: 高さに合わせてスケールし、横をクロップ
                scale = targetHeight / sourceHeight
                let scaledWidth = sourceWidth * scale
                cropX = (scaledWidth - targetWidth) / 2.0
                cropY = 0
            } else {
                // ソースの方が縦長: 幅に合わせてスケールし、縦をクロップ
                scale = targetWidth / sourceWidth
                let scaledHeight = sourceHeight * scale
                cropX = 0
                cropY = (scaledHeight - targetHeight) / 2.0
            }
            
            // スケール変換
            let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            
            // クロップ領域を指定
            let cropRect = CGRect(x: cropX, y: cropY, width: targetWidth, height: targetHeight)
            finalImage = scaledImage.cropped(to: cropRect)
            
            // クロップ後の座標をリセット（原点を0,0に）
            finalImage = finalImage.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        }
        
        context.render(finalImage, to: outBuffer)

        _ = adaptor.append(outBuffer, withPresentationTime: frameTime)
    }
}


