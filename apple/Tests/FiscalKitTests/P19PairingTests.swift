import Foundation
import Testing

@testable import FiscalKit

@Suite("P19 device pairing link")
struct P19PairingTests {
  @Test("Pairing URL round-trips the one-time key")
  func roundTrip() throws {
    let token = "fiscal_dt_v1_" + String(repeating: "a", count: 48)
    let url = try #require(PairingLink.url(token: token))
    #expect(url.scheme == "fiscal")
    #expect(url.host == "pair")
    #expect(PairingLink.token(from: url) == token)
  }

  @Test("Foreign schemes, hosts, and empty tokens are rejected")
  func rejectsForeignLinks() throws {
    for raw in [
      "https://pair?token=fiscal_dt_v1_abc",
      "fiscal://rotate?token=fiscal_dt_v1_abc",
      "fiscal://pair",
      "fiscal://pair?token=",
      "otherapp://pair?token=fiscal_dt_v1_abc",
    ] {
      let url = try #require(URL(string: raw))
      #expect(PairingLink.token(from: url) == nil, "should reject \(raw)")
    }
  }

  @Test("Query encoding survives token-safe characters")
  func tokenSafeCharacters() throws {
    let token = "fiscal_dt_v1_A-z0_9-_"
    let url = try #require(PairingLink.url(token: token))
    #expect(PairingLink.token(from: url) == token)
  }
}
