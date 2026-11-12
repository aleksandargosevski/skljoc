import CoreGraphics
import SkljocCore
@preconcurrency import Vision

/// Reads text in images with Vision, on device.
enum TextRecognizer {
    /// The text in reading order, with rows and paragraphs kept. Empty when nothing was found.
    static func text(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                // Vision's boxes have a bottom-left origin.
                return RecognizedLine(text: candidate.string, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
            return RecognizedText.join(lines)
        }.value
    }
}
