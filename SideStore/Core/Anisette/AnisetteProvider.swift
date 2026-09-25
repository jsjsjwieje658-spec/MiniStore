//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if UserDefaults.standard.useOnDeviceAnisette, await shouldAttemptOnDeviceAnisette() {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            do {
                return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
            } catch {
                // A native ADI abort cannot be caught, but a thrown provisioning error can.
                // Sign-in must still be able to complete against a remote server.
                debugLog("[AnisetteProvider] On-device anisette failed (\(error.localizedDescription)). Falling back to a remote server.")
            }
        } else if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Skipping on-device anisette (libraries missing or app group container unavailable after launch wiped adi.pb). Using a remote server.")
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
        }
        return try await fetchRemote(handler: handler)
    }

    /// ODA's C ABI aborts the process (Swift `try` does not catch it) when the shared
    /// container or the local libraries are missing. Launch maintenance clears `adi.pb`
    /// whenever that container can't be recorded; don't call into the native client then.
    private static func shouldAttemptOnDeviceAnisette() async -> Bool {
        guard FileManager.default.altstoreSharedDirectory != nil else { return false }
        return await OnDeviceAnisetteManager.shared.isReady()
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return anisetteData
    }
}
