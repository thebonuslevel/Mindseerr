import Foundation
import CryptoKit
import Security
import SwiftUI

/// A server certificate tvOS doesn't trust (self-signed, or from an unknown authority), waiting for the user to decide.
struct UntrustedCertificate: Error, LocalizedError, Identifiable, Sendable, Equatable {
    let host: String
    let port: Int
    /// SHA-256 of the certificate, as pairs of hex digits.
    let fingerprint: String
    let subject: String

    var id: String { "\(host):\(port)" }
    var errorDescription: String? {
        String(localized: "The server's HTTPS certificate isn't trusted by Apple TV.")
    }
}

/// Certificates the user has approved, for servers on their own network that use a self-signed HTTPS certificate.
///
/// Approval is pinned to the certificate itself (its SHA-256 fingerprint) for one host and port, so it doesn't
/// switch off checking for anything else, and a different certificate on the same server asks again.
enum CertificateTrust {
    private static let storageKey = "trustedCertificates"
    private static let lock = NSLock()
    /// The untrusted certificate each host last presented, so the screen that hit the error can offer to trust it.
    nonisolated(unsafe) private static var rejections: [String: UntrustedCertificate] = [:]

    /// Approved fingerprints by "host:port".
    static var trusted: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    static func port(of url: URL) -> Int { url.port ?? (url.scheme == "http" ? 80 : 443) }

    static func approve(_ certificate: UntrustedCertificate) {
        lock.lock(); defer { lock.unlock() }
        trusted[key(certificate.host, certificate.port)] = certificate.fingerprint
        rejections[key(certificate.host, certificate.port)] = nil
    }

    static func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        trusted[id] = nil
    }

    /// The untrusted certificate the server at this address presented last, if any.
    static func rejection(for url: URL) -> UntrustedCertificate? {
        guard let host = url.host else { return nil }
        lock.lock(); defer { lock.unlock() }
        return rejections[key(host, port(of: url))]
    }

    /// Forgets an earlier rejection, so one found afterwards is from the check that's about to run.
    static func clearRejection(for url: URL) {
        guard let host = url.host else { return }
        lock.lock(); defer { lock.unlock() }
        rejections[key(host, port(of: url))] = nil
    }

    /// Decides a server-trust challenge: valid certificates go through as usual, an approved one is accepted, and
    /// anything else fails with the usual certificate error after being noted for `rejection(for:)`.
    static func handle(_ challenge: URLAuthenticationChallenge,
                       completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            return completion(.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) { return completion(.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return completion(.performDefaultHandling, nil)
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: " ")
        let id = key(space.host, space.port)

        lock.lock()
        let approved = trusted[id] == fingerprint
        if !approved {
            rejections[id] = UntrustedCertificate(host: space.host, port: space.port, fingerprint: fingerprint,
                                                  subject: SecCertificateCopySubjectSummary(leaf) as String? ?? space.host)
        }
        lock.unlock()
        completion(approved ? .useCredential : .performDefaultHandling, approved ? URLCredential(trust: trust) : nil)
    }
}

/// A session delegate that lets approved certificates through. Use it for every session that talks to a server
/// the user typed in.
class TrustedCertificateDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        CertificateTrust.handle(challenge, completion: completionHandler)
    }
}

// MARK: - Asking the user

extension View {
    /// Offers to trust a certificate that tvOS rejected, showing its fingerprint so it can be compared with the server's.
    func certificateApproval(_ certificate: Binding<UntrustedCertificate?>, onTrust: @escaping () -> Void) -> some View {
        confirmationDialog("Trust this certificate?", isPresented: Binding(get: { certificate.wrappedValue != nil },
                                                                           set: { if !$0 { certificate.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: certificate.wrappedValue) { cert in
            Button("Trust Certificate") {
                CertificateTrust.approve(cert)
                certificate.wrappedValue = nil
                onTrust()
            }
            Button("Cancel", role: .cancel) { certificate.wrappedValue = nil }
        } message: { cert in
            Text("\(cert.host) uses a certificate Apple TV can't verify, like a self-signed one. Trust it only if this is your own server.\n\nSHA-256 fingerprint:\n\(cert.fingerprint)")
        }
    }
}
