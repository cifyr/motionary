import AVFoundation
import CoreGraphics
import Foundation
import os

enum PreviewVideoError: Error, CustomStringConvertible {
    case noFrames
    case writerSetupFailed(path: String, underlying: Error)
    case cannotAppend(frameIndex: Int, status: AVAssetWriter.Status, underlying: Error?)
    case finishFailed(underlying: Error?)
    case renderFailed(frameIndex: Int)

    var description: String {
        switch self {
        case .noFrames:
            "preview video: no frames to encode"
        case .writerSetupFailed(let path, let underlying):
            "preview video: could not create a writer at \(path): \(underlying)"
        case .cannotAppend(let index, let status, let underlying):
            "preview video: writer refused frame \(index) (status \(status.rawValue)): \(underlying.map(String.init(describing:)) ?? "no error")"
        case .finishFailed(let underlying):
            "preview video: finishing failed: \(underlying.map(String.init(describing:)) ?? "no error")"
        case .renderFailed(let index):
            "preview video: could not draw frame \(index) into the pixel buffer"
        }
    }
}

/// Encodes the composed loop as a plain MP4.
///
/// The timer-font animation is produced by the system widget renderer, which
/// the containing app is not. A normal video loop is both the honest way to
/// preview motion in-app and, per the reference project, the cheaper one.
struct PreviewVideoWriter {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "PreviewVideo")

    let size: CGSize
    let framesPerSecond: Int

    func write(frames: [CGImage], to url: URL) async throws {
        guard !frames.isEmpty else { throw PreviewVideoError.noFrames }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // h.264 rejects odd luma dimensions.
        let width = Int(size.width) - Int(size.width) % 2
        let height = Int(size.height) - Int(size.height) % 2

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw PreviewVideoError.writerSetupFailed(path: url.path, underlying: error)
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try pixelBuffer(from: frame, width: width, height: height, frameIndex: index)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw PreviewVideoError.cannotAppend(
                    frameIndex: index,
                    status: writer.status,
                    underlying: writer.error
                )
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PreviewVideoError.finishFailed(underlying: writer.error)
        }
        Self.logger.info("wrote \(frames.count)-frame preview to \(url.lastPathComponent, privacy: .public)")
    }

    private func pixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PreviewVideoError.renderFailed(frameIndex: frameIndex)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw PreviewVideoError.renderFailed(frameIndex: frameIndex)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
