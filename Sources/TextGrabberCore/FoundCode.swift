import Foundation
import Vision

/// A QR code or barcode found in a capture.
public struct FoundCode: Equatable {
    public var payload: String
    /// Normalised, top-left origin, like `TextFragment.box`.
    public var box: CGRect
    /// "QR code", "barcode", …: for the confirmation.
    public var kind: String

    public init(payload: String, box: CGRect, kind: String = "QR code") {
        self.payload = payload
        self.box = box
        self.kind = kind
    }

    /// The payload as a web link, when it is one.
    public var link: URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func name(of symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr, .microQR: return "QR code"
        case .aztec: return "Aztec code"
        case .dataMatrix, .microPDF417, .pdf417: return "2D code"
        default: return "barcode"
        }
    }
}
