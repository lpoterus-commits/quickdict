import CoreGraphics
import Foundation
import Vision

enum QRCode {
    struct Hit {
        var payload: String
        var symbology: String
        /// payload 能解析成 http/https 链接时非 nil
        var url: URL?
    }

    /// 除了二维码也认常见一维码，扫商品条码时不用换快捷键
    private static let symbologies: [VNBarcodeSymbology] = [
        .qr, .aztec, .dataMatrix, .pdf417, .microQR,
        .ean8, .ean13, .code39, .code93, .code128, .itf14, .upce,
    ]

    static func detect(in image: CGImage) -> [Hit] {
        let request = VNDetectBarcodesRequest()
        // 按本机实际支持的码制过滤，免得设了不支持的导致整个请求失败
        if let supported = try? request.supportedSymbologies() {
            let wanted = symbologies.filter { supported.contains($0) }
            if !wanted.isEmpty { request.symbologies = wanted }
        }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("[OCRDict] 条码识别失败: \(error)")
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return Hit(payload: payload,
                       symbology: observation.symbology.rawValue
                           .replacingOccurrences(of: "VNBarcodeSymbology", with: ""),
                       url: httpURL(from: payload))
        }
    }

    /// 只把 http/https 当链接。二维码里也可能是 mailto:、tel:、WIFI: 之类，
    /// 那些不自动打开，留给用户看内容自己决定。
    private static func httpURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}
