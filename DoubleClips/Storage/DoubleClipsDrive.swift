import Foundation

/// Van Vat Drive access for DoubleClips.
///
/// There is no second sign-in: the account login the app already has stores the JWT in the cookie jar (cookie "authToken",
/// see Auth/NetworkClient.swift). The Drive API takes that same token as `Authorization: Bearer`.
enum DoubleClipsDrive {
    static let client = DriveClient(tokenProvider: { sessionToken() })

    /// The OpenEditz client: the part of the Drive API the editor needs, locked to the protected OpenEditz folder.
    static let openEditz = OpenEditzClient(client: client)

    static func sessionToken() -> String? {
        guard let url = URL(string: "https://account.vanvatcorp.com") else { return nil }
        return HTTPCookieStorage.shared.cookies(for: url)?.first(where: { $0.name == "authToken" })?.value
    }
}
