//
//  ResignAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign

final class ResignAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[ResignAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[ResignAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let team = try await AuthManager.shared.getAuthenticatedTeam()
        guard
            let appBundle = self.context.targetAppBundle,
            let profiles = self.context.provisioningProfiles,
            let certificate = self.context.targetSigningCertificate
        else {
            throw OperationError.invalidParameters("ResignAppOperation.main: " +
                                                   "self.context.targetAppBundle or " +
                                                   "self.context.provisioningProfiles or " +
                                                   "self.context.targetSigningCertificate is nil")
        }
        
        debugLog("[ResignAppOperation] Resigning app \(self.context.bundleIdentifier)...")
        
        self.setProgress(5)
        
        let effectiveBundleId = self.context.targetBundleIdentifier
        let appBundleURL = try await self.prepareAppBundle(for: appBundle, profiles: profiles, appexBundleIds: context.appexBundleIds ?? [:])
        
        self.setProgress(40)
        
        let resignedAppURL = try await self.resignAppBundle(at: appBundleURL, team: team, certificate: certificate, profiles: Array(profiles.values))
        guard let resignedAppBundle = ALTApplication(fileURL: resignedAppURL) else {
            throw OperationError.invalidApp(reason: "Could not load resigned app bundle at '\(resignedAppURL.lastPathComponent)'")
        }
        
        self.debugLog("[ResignAppOperation] Resigned app \(self.context.bundleIdentifier) to \(resignedAppBundle.bundleIdentifier).")
        self.setProgress(100)
        
        return resignedAppBundle
    }

    
    private func prepareAppBundle(for targetAppBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) async throws -> URL {

        let bundleIdentifier = self.hostBundleIdentifier(context.targetBundleIdentifier, profiles: profiles, appBundle: targetAppBundle)
        let finalBundleIdentifier = bundleIdentifier
        
        // Use customized bundle ID if applicable
        let openURL = InstalledApp.openAppURL(targetBundleIdentifier: finalBundleIdentifier)
        let fileURL = targetAppBundle.fileURL

        let appBundleURL = self.context.temporaryDirectory.appendingPathComponent("App.app")
        if fileURL.path != appBundleURL.path {
            if FileManager.default.fileExists(atPath: appBundleURL.path) {
                try FileManager.default.removeItem(at: appBundleURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: appBundleURL)
        }
        
        guard let appBundle = ALTApplication(fileURL: appBundleURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load bundle at '\(appBundleURL.lastPathComponent)'")
        }
        let infoDictionary = appBundle.infoPlist
        
        // replace scheme targets to match the bundle suffix so multiple instances can be correctly routed for helper apps like SideBackup
        var allURLSchemes = infoDictionary[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
        allURLSchemes.removeAll { urlType in
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else { return false }
            return schemes.contains { $0.hasPrefix("sidestore-") }
        }
        
        let altstoreURLScheme = ["CFBundleTypeRole": "Editor",
                                 "CFBundleURLName": finalBundleIdentifier,
                                 "CFBundleURLSchemes": [openURL.scheme!]] as [String : Any]
        allURLSchemes.append(altstoreURLScheme)
        
        var additionalValues: [String: Any] = [Bundle.Info.urlTypes: allURLSchemes]

        if targetAppBundle.isAltStoreApp {
            if let activeCert = CertificateManager.shared.activeCertificate {
                additionalValues[Bundle.Info.certificateID] = activeCert.serialNumber
                let certURL = appBundle.fileURL.appendingPathComponent("ALTCertificate.p12")
                try activeCert.p12Data.write(to: certURL, options: .atomic)
            } else {
                self.verboseLog("[ResignAppOperation] No activeCertificate found in CertificateManager. Embedded certificate + certificate identifier in app bundle will not be updated.")
            }
        }
        
        // Prepare app
        try self.prepare(appBundle, bundleID: bundleIdentifier, additionalInfoDictionaryValues: additionalValues, profiles: profiles, appexBundleIds: appexBundleIds)
        try self.removeMissingAppExtensionReferences(from: appBundle)
        
        for appExtension in appBundle.appExtensions {
            let updatedAppExBundleId = self.extensionBundleID(appExtension, originalHostID: targetAppBundle.bundleIdentifier, correctedHostID: bundleIdentifier)
            try self.prepare(appExtension, bundleID: updatedAppExBundleId, profiles: profiles, appexBundleIds: appexBundleIds)
        }
        
        return appBundleURL
    }
    
    private func prepare(_ appBundle: ALTApplication, bundleID identifier: String?, additionalInfoDictionaryValues: [String: Any] = [:], profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) throws {
        guard let identifier else {
            throw OperationError.invalidParameters("Bundle is missing bundle identifier.")
        }
        guard let profile = self.profile(for: identifier, in: profiles, appBundle: appBundle) else {
            throw OperationError.missingProvisioningProfile(reason: "No provisioning profile found for identifier '\(identifier)'.")
        }
        guard var parser = try? InfoPlistParser(plistURL: appBundle.infoPlistURL) else {
            throw OperationError.missingInfoPlist(reason: "Could not read Info.plist for bundle '\(identifier)'.")
        }
        var infoDictionary = parser.rawDictionary as [String: Any]
        
        let newBundleID = self.rewrittenBundleID(identifier, profile: profile, appBundle: appBundle, appexBundleIds: appexBundleIds)
        infoDictionary[kCFBundleIdentifierKey as String] = newBundleID

        // Fix-up BGTaskScheduler identifiers so they stay under the new bundle ID.
        // Otherwise bg register() and submit() both succeed and the handler is never
        // called, with no error surfaced to the app.
        if identifier != newBundleID, let taskIDs = infoDictionary["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            let taskIDs = self.rewrittenTaskSchedulerIdentifiers(taskIDs, from: identifier, to: newBundleID)
            infoDictionary["BGTaskSchedulerPermittedIdentifiers"] = taskIDs
        }

        infoDictionary.removeValue(forKey: "DTXcode")
        infoDictionary.removeValue(forKey: "DTXcodeBuild")

        for (key, value) in additionalInfoDictionaryValues {
            infoDictionary[key] = value
        }

        if let customPlist = context.customInfoPlistByBundleID[identifier] {
            for (key, value) in customPlist {
                if key == (kCFBundleIdentifierKey as String) || key == "CFBundleIdentifier" {
                    continue
                }
                infoDictionary[key] = value
            }
        }

        if let appGroups = profile.entitlements[.appGroups] as? [String] {
            // To keep file providers working, remap the NSExtensionFileProviderDocumentGroup, if there is one.
            if var extensionInfo = infoDictionary["NSExtension"] as? [String: Any],
                let appGroup = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
                let localAppGroup = appGroups.filter({ $0.contains(appGroup) }).min(by: { $0.count < $1.count }) {
                extensionInfo["NSExtensionFileProviderDocumentGroup"] = localAppGroup
                infoDictionary["NSExtension"] = extensionInfo
            }
        }
        
        // Add app-specific exported UTI so we can check later if this app (extension) is installed or not.
        let installedAppUTI = ["UTTypeConformsTo": [],
                               "UTTypeDescription": "AltStore Installed App",
                               "UTTypeIconFiles": [],
                               "UTTypeIdentifier": InstalledApp.installedAppUTI(forBundleIdentifier: profile.bundleIdentifier),
                               "UTTypeTagSpecification": [:]] as [String : Any]
        
        var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        exportedUTIs.append(installedAppUTI)
        infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs
        
        try InfoPlistParser(dictionary: infoDictionary).write(to: appBundle.infoPlistURL)
        
        // Remove _CodeSignature folder (if it exists) because it will be added when resigning and it may have files that aren't overwritten when resigning
        // These files might be the cause of some ApplicationVerificationFailed errors
        let codeSignatureURL = appBundle.fileURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: codeSignatureURL.path) {
            try FileManager.default.removeItem(at: codeSignatureURL)
            self.verboseLog("[ResignAppOperation] Removed _CodeSignature folder at \(codeSignatureURL.path)")
        }
    }
    
    private func resignAppBundle(at fileURL: URL, team: ALTTeam, certificate: ALTCertificate, profiles: [ALTProvisioningProfile]) async throws -> URL {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await signer.signApp(at: fileURL, provisioningProfiles: profiles, progress: nil)
        return fileURL
    }
    
    /// `profiles.values` is unordered. Picking `.first` while "use main profile" is on can
    /// hand the host the widget's profile, which is how a refresh rewrote the host bundle ID
    /// to `….AltWidget` and the next launch crashed while presenting Apple ID sign-in.
    private func profile(for identifier: String, in profiles: [String: ALTProvisioningProfile], appBundle: ALTApplication) -> ALTProvisioningProfile? {
        if let exact = profiles[identifier] {
            return exact
        }
        let corrected = ALTApplication.correctedSideStoreHostBundleID(identifier)
        if corrected != identifier, let exact = profiles[corrected] {
            return exact
        }
        guard context.useMainProfile else { return nil }
        if !appBundle.isAppExtensionBundle {
            let host = profiles.first { element in
                !Self.isEmbeddedExtensionIdentifier(element.key) && !Self.isEmbeddedExtensionIdentifier(element.value.bundleIdentifier)
            }
            if let host { return host.value }
        }
        return profiles.values.first
    }

    private func hostBundleIdentifier(_ identifier: String, profiles: [String: ALTProvisioningProfile], appBundle: ALTApplication) -> String {
        let profileID = self.profile(for: identifier, in: profiles, appBundle: appBundle)?.bundleIdentifier ?? identifier
        return self.rewrittenBundleID(identifier, profileID: profileID, appBundle: appBundle, appexBundleIds: [:])
    }

    private func rewrittenBundleID(_ identifier: String, profile: ALTProvisioningProfile, appBundle: ALTApplication, appexBundleIds: [String: String]) -> String {
        let mapped = appexBundleIds[identifier] ?? profile.bundleIdentifier
        return self.rewrittenBundleID(identifier, profileID: mapped, appBundle: appBundle, appexBundleIds: appexBundleIds)
    }

    private func rewrittenBundleID(_ identifier: String, profileID: String, appBundle: ALTApplication, appexBundleIds: [String: String]) -> String {
        if appBundle.isAppExtensionBundle {
            return self.extensionBundleID(appBundle, originalHostID: identifier, correctedHostID: appexBundleIds[identifier] ?? profileID)
        }
        let candidate = appexBundleIds[identifier] ?? profileID
        let corrected = ALTApplication.correctedSideStoreHostBundleID(candidate)
        if corrected != candidate {
            self.debugLog("[ResignAppOperation] Refusing to stamp extension bundle ID '\(candidate)' onto the host app. Using '\(corrected)'.")
        }
        return corrected
    }

    /// Keep `.AltWidget` / `.SideBackup` on the extension even when a previous refresh copied
    /// that identifier onto the host, so replacing the host ID would otherwise delete the suffix.
    private func extensionBundleID(_ appExtension: ALTApplication, originalHostID: String, correctedHostID: String) -> String {
        let hostID = ALTApplication.correctedSideStoreHostBundleID(correctedHostID)
        // Only SideStore's own extensions have a suffix we are allowed to reattach.
        // Doing this for every appex would rewrite third-party bundle IDs.
        if appExtension.bundleIdentifier.isAltStoreAppID, let suffix = appExtension.embeddedExtensionSuffix {
            return hostID.hasSuffix(suffix) ? hostID : hostID + suffix
        }
        if originalHostID.isEmpty || appExtension.bundleIdentifier == originalHostID {
            return hostID
        }
        return appExtension.bundleIdentifier.replacingOccurrences(of: originalHostID, with: hostID)
    }

    private static func isEmbeddedExtensionIdentifier(_ identifier: String) -> Bool {
        ALTApplication.embeddedExtensionSuffixes.contains { identifier.hasSuffix($0) }
    }

    private func removeMissingAppExtensionReferences(from appBundle: ALTApplication) throws {

        // If app extensions have been removed from an app (either by AltStore or the developer),
        // we must remove all references to them from SC_Info/Manifest.plist (if it exists).
        
        let scInfoURL = appBundle.fileURL.appendingPathComponent("SC_Info")
        let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")
        
        guard let manifestPlist = try? InfoPlistParser(plistURL: manifestPlistURL),
              let sinfReplicationPaths = manifestPlist.rawDictionary["SinfReplicationPaths"] as? [String] else { return }
        
        // Remove references to missing files.
        let filteredReplicationPaths = sinfReplicationPaths.filter { path in
            guard let fileURL = URL(string: path, relativeTo: appBundle.fileURL) else { return false }
            
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            return fileExists
        }
        
        var updatedManifest = manifestPlist.rawDictionary
        updatedManifest["SinfReplicationPaths"] = filteredReplicationPaths
        
        // Save updated Manifest.plist to disk.
        try InfoPlistParser(dictionary: updatedManifest).write(to: manifestPlistURL)
    }

    private func rewrittenTaskSchedulerIdentifiers(_ taskIDs: [String], from originalBundleID: String, to newBundleID: String) -> [String] {
        var seen = Set<String>()
        var rewrittenTaskIDs = [String]()
        for taskID in taskIDs {
            let rewritten: String
            if taskID == newBundleID || taskID.hasPrefix(newBundleID + ".") {
                rewritten = taskID
            } else if taskID == originalBundleID || taskID.hasPrefix(originalBundleID + ".") {
                rewritten = newBundleID + taskID.dropFirst(originalBundleID.count)
            } else {
                rewritten = taskID
            }
            if seen.insert(rewritten).inserted {
                rewrittenTaskIDs.append(rewritten)
            }
        }
        return rewrittenTaskIDs
    }
}
