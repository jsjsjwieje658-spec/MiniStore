//
//  ALTApplication+AltStoreApp.swift
//  AltStore
//
//  Created by Riley Testut on 11/11/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import SideSign

extension ALTApplication {
    /// Suffixes this project embeds. A refresh must never write one of these onto the host app:
    /// the console from a crashing sign-in showed the host identified as
    /// `com.SideStore.SideStore.<team>.AltWidget`, so UIKit then loaded the host's nibs out of
    /// the widget bundle and `UIStoryboard` instantiation aborted.
    static let embeddedExtensionSuffixes = [".AltWidget", ".SideBackup"]

    var isAltStoreApp: Bool {
        if self.fileURL.standardizedFileURL == Bundle.Info.activeBundleURL.standardizedFileURL {
            return true
        }
        return self.bundleIdentifier.isAltStoreAppID
    }

    var isAppExtensionBundle: Bool {
        fileURL.pathExtension == "appex"
    }

    /// `.AltWidget` / `.SideBackup` when this bundle is one of those extensions, else nil.
    var embeddedExtensionSuffix: String? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        if name.localizedCaseInsensitiveContains("AltWidget") { return ".AltWidget" }
        if name.localizedCaseInsensitiveContains("SideBackup") { return ".SideBackup" }
        return Self.embeddedExtensionSuffixes.first { bundleIdentifier.hasSuffix($0) }
    }

    /// Host bundle ID with an accidentally applied extension suffix removed.
    /// Third-party apps are left alone — only SideStore's own IDs use these suffixes.
    static func correctedSideStoreHostBundleID(_ bundleID: String) -> String {
        guard bundleID.isAltStoreAppID else { return bundleID }
        for suffix in embeddedExtensionSuffixes where bundleID.hasSuffix(suffix) {
            let stripped = String(bundleID.dropLast(suffix.count))
            if !stripped.isEmpty { return stripped }
        }
        return bundleID
    }
}
