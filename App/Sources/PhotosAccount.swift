import Foundation
import SwiftUI

/// The connected Google account, as far as the Photos side of the app cares:
/// is there a usable credential, and is it still being honoured?
///
/// Three states have to be told apart, because the user does something
/// different about each: nothing stored yet, stored and working, and stored but
/// refused (revoked elsewhere, password changed, bound token).
@MainActor
final class PhotosAccount: ObservableObject {
    enum VerificationOutcome: Equatable {
        case succeeded
        case failed(String)
    }

    enum Status: Equatable {
        case loading
        case disconnected
        case connected(email: String, since: Date)
        case rejected(email: String, reason: String)

        var email: String? {
            switch self {
            case .connected(let email, _): return email
            case .rejected(let email, _) where !email.isEmpty: return email
            default: return nil
            }
        }
        var isUsable: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var verifying = false
    /// Set when the credential works but could not be stored. Not a rejection:
    /// the account is usable until the app is relaunched.
    @Published private(set) var persistenceWarning: String?

    private let store: CredentialStore
    private let requestNetworkPolicy: UploadRequestNetworkPolicy
    private let fileUploadTransport: any FileUploadTransport
    private var credential: StoredCredential?
    private var client: GPMCClient?

    init(store: CredentialStore = CredentialStore(),
         requestNetworkPolicy: UploadRequestNetworkPolicy = UploadRequestNetworkPolicy(),
         fileUploadTransport: any FileUploadTransport = AppFileUploadTransport.shared) {
        self.store = store
        self.requestNetworkPolicy = requestNetworkPolicy
        self.fileUploadTransport = fileUploadTransport
    }

    func setCellularUploadsAllowed(_ allowed: Bool) {
        requestNetworkPolicy.setCellularAllowed(allowed)
    }

    /// Call once at launch. Restores the account without hitting the network —
    /// the first upload (or an explicit `verify()`) is what proves the token.
    func restore() async {
        do {
            guard let credential = try await store.load() else { status = .disconnected; return }
            adopt(credential)
        } catch {
            // Nothing has been connected yet, so an unreadable store is not a
            // rejected account — it just means there is nothing to restore.
            credential = nil; client = nil
            persistenceWarning = Self.describe(error)
            status = .disconnected
        }
    }

    /// Persist a fresh exchange result and connect with it.
    func connect(_ result: TokenExchange.Result) async {
        do {
            adopt(try await store.save(result))
            persistenceWarning = nil
        } catch let unpersisted as CredentialStore.Unpersisted {
            adopt(unpersisted.credential)
            persistenceWarning = unpersisted.reason
        } catch {
            status = .rejected(email: result.email, reason: Self.describe(error))
        }
    }

    func disconnect() async {
        await store.clear()
        credential = nil; client = nil
        persistenceWarning = nil
        status = .disconnected
    }

    /// Optional round trip to Google. Only worth running when the user asks —
    /// uploads report rejection on their own through `report(_:)`.
    @discardableResult
    func verify() async -> VerificationOutcome {
        guard let client else { return .failed("Connect an account before checking it.") }
        guard !verifying else { return .failed("A connection check is already running.") }
        verifying = true
        defer { verifying = false }
        do {
            try await client.validateReadAccess()
            if let credential { status = .connected(email: credential.email, since: credential.connectedAt) }
            return .succeeded
        } catch {
            report(error)
            return .failed(Self.describe(error))
        }
    }

    /// A client bound to the stored credential, or nil when there is nothing to
    /// upload with. The same actor instance is reused so its access token and
    /// expiry survive between items.
    func currentClient() -> GPMCClient? { client }

    /// Fold an error raised anywhere downstream back into the account state.
    /// Only a credential rejection changes it; a flat tyre on the network does not.
    func report(_ error: Error) {
        guard let gpmc = error as? GPMCError, gpmc.kind == .credentialRejected || gpmc.kind == .tokenBound else { return }
        let email = credential?.email ?? ""
        status = .rejected(email: email, reason: gpmc.message)
        client = nil
    }

    private func adopt(_ credential: StoredCredential) {
        self.credential = credential
        do {
            client = try GPMCClient(authData: credential.authData,
                                    networkPolicy: requestNetworkPolicy,
                                    fileUploadTransport: fileUploadTransport)
            status = .connected(email: credential.email, since: credential.connectedAt)
        } catch {
            client = nil
            status = .rejected(email: credential.email, reason: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
