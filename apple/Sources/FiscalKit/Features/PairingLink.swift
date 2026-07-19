import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR/deep-link contract for one-time device-key pairing: `fiscal://pair?token=<key>`.
/// The link only ferries the key between the issuing Mac and the phone camera; format and
/// server-side validation stay in `DeviceSecurityModel.installIssuedToken`.
public enum PairingLink {
  public static let scheme = "fiscal"
  public static let host = "pair"

  public static func url(token: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    return components.url
  }

  public static func token(from url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
      !token.isEmpty
    else { return nil }
    return token
  }
}

/// Renders a scannable QR for the pairing link. CoreImage only — no external dependencies.
public struct PairingQRCode: View {
  private let cgImage: CGImage?

  public init(token: String) {
    cgImage = PairingQRCode.render(text: PairingLink.url(token: token)?.absoluteString)
  }

  public var body: some View {
    if let cgImage {
      Image(decorative: cgImage, scale: 1)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: 148, height: 148)
        .padding(7)
        .background(.white, in: .rect(cornerRadius: 9))
        .accessibilityLabel("设备配对二维码")
    }
  }

  private static func render(text: String?) -> CGImage? {
    guard let text else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}
