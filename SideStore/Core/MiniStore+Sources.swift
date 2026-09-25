//
//  MiniStore+Sources.swift
//  SideStore
//
//  Clears dead sources (including the old Mini's Repo URL, which 404s) and
//  seeds a catalogue only when `catalogueSourceURL` is a live feed.
//

import CoreData
import Foundation

public extension MiniStore
{
    /// The catalogue seeded on first launch.
    ///
    /// Deliberately separate from `Source.altStoreSourceURL`, which is this app's own update
    /// feed and carries no third-party apps.
    /// Previously `https://OofMini.github.io/Minis-Repo/mini.json`. That GitHub Pages site 404s
    /// and the HTML body is what launch logged as "The given data was not valid JSON", which
    /// failed the whole source refresh. Do not seed it again until a live catalogue exists.
    static let catalogueSourceURL: URL? = nil
    static let catalogueSourceName = "Mini's Repo"

    /// Feeds an upgrading install may still have in its database, matched against the
    /// normalized `Source.identifier` (lowercased, scheme stripped).
    ///
    /// Two kinds, both of which now serve nothing:
    ///
    /// - SideStore's catalogue, seeded before this fork repointed `Source.altStoreSourceURL`.
    /// - Earlier MiniStore self-update feeds, which lived at several paths over time.
    ///
    /// A source that 404s is not merely inert: `FetchSourceOperation` decodes the whole
    /// response, so one source returning GitHub's error page fails the refresh — which is what
    /// empties the News tab.
    ///
    /// Prefixes rather than exact URLs, because the path varied. **They also match this fork's
    /// own live feed**, `the-big-mini.github.io/MiniStore/source.json`, and deliberately still
    /// do: an identifier already written into a user's database is not rewritten by anything
    /// that happens on the server side, so narrowing them would strand the records this exists
    /// to clear. The `altStoreIdentifier` guard in `removeLegacySideStoreSource` is therefore
    /// the only thing keeping this from deleting the app's own update source. Do not remove it.
    static let legacySourceIdentifierPrefixes = [
        "sidestore.io/apps-v2.json",
        "raw.githubusercontent.com/the-big-mini/ministore/",
        "the-big-mini.github.io/ministore/",

        // The feed's home before the repo was renamed `The-Big-Mini/SideStore` →
        // `The-Big-Mini/MiniStore`. Its path is `/sidestore/`, so none of the prefixes above
        // reach it, and it outlived every launch: a row still named "MiniStore" — that being
        // the feed's own `name` — sitting in Sources reporting "failed to load", while
        // self-updates went on working from the current feed's separate row.
        "the-big-mini.github.io/sidestore/",
        // Dead catalogue. Fetching it returns GitHub Pages HTML, which fails JSON decode
        // for the entire source refresh (console: "Data corrupted. The given data was not valid JSON.").
        "oofmini.github.io/minis-repo/",
    ]

    /// Set once Mini's Repo has been seeded, so removing it sticks. An existence check
    /// instead would re-add the source on the next launch and make it undeletable.
    fileprivate static let didSeedCatalogueKey = "MiniStoreDidSeedCatalogueSource"
}

public extension MiniStore
{
    /// Called from `DatabaseManager.prepareDatabase`, inside its context and before its save.
    static func prepareDatabase(in context: NSManagedObjectContext)
    {
        Source.removeLegacySideStoreSource(in: context)
        Source.seedCatalogueSourceIfNeeded(in: context)
        self.renameSelfAppIfNeeded(in: context)
        self.detachOrphanedNewsBanners(in: context)
    }

    /// Clears `NewsItem.storeApp` wherever `appID` is gone.
    ///
    /// `NewsViewController` draws a whole app banner — icon, developer, OPEN button — under any
    /// item with a `storeApp`, which is what made every MiniStore release note read as MiniStore
    /// listing its own IPA. CI no longer publishes `appID`, and `Source.init(from:)` now clears
    /// the relationship when the key is absent, but neither reaches a row the feed has since
    /// scrolled past: those are never decoded again and keep whatever they were given.
    ///
    /// A `storeApp` without an `appID` is not a valid state in the first place, so this enforces
    /// the invariant rather than special-casing MiniStore's own feed.
    private static func detachOrphanedNewsBanners(in context: NSManagedObjectContext)
    {
        let predicate = NSPredicate(format: "%K == nil AND %K != nil",
                                    #keyPath(NewsItem.appID),
                                    #keyPath(NewsItem.storeApp))

        for newsItem in NewsItem.all(satisfying: predicate, in: context)
        {
            debugLog("[MiniStore] Detaching the app banner from news item \(newsItem.identifier).")
            newsItem.storeApp = nil
        }
    }

    /// `InstalledApp.update` only runs when the app is installed or refreshed, so a database
    /// carried over from an earlier build keeps whatever name it was given then — which is
    /// what My Apps shows.
    private static func renameSelfAppIfNeeded(in context: NSManagedObjectContext)
    {
        guard let installedApp = InstalledApp.fetchAltStore(in: context) else { return }
        guard installedApp.name != MiniStore.displayName else { return }

        debugLog("[MiniStore] Renaming the installed app record from \(installedApp.name).")
        installedApp.name = MiniStore.displayName
    }
}

extension Source
{

    static func seedCatalogueSourceIfNeeded(in context: NSManagedObjectContext)
    {
        guard let catalogueSourceURL = MiniStore.catalogueSourceURL else { return }
        guard !UserDefaults.standard.bool(forKey: MiniStore.didSeedCatalogueKey) else { return }

        guard let identifier = self.sourceID(for: catalogueSourceURL) else { return }

        let predicate = NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier)
        if Source.first(satisfying: predicate, in: context) == nil
        {
            // Apps stay empty until the next source refresh — `AppManager.fetchSources()`
            // walks every Source row, so this one gets populated with the rest.
            _ = Source.make(name: MiniStore.catalogueSourceName,
                            groupID: Source.altStoreGroupIdentifier,
                            sourceURL: catalogueSourceURL,
                            context: context)
        }

        UserDefaults.standard.set(true, forKey: MiniStore.didSeedCatalogueKey)
    }

    static func removeLegacySideStoreSource(in context: NSManagedObjectContext)
    {
        let predicates = MiniStore.legacySourceIdentifierPrefixes.map {
            NSPredicate(format: "%K BEGINSWITH %@", #keyPath(Source.identifier), $0)
        }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        for source in Source.all(satisfying: predicate, in: context)
        {
            // Guard against the fork ever pointing its own feed at one of these.
            guard source.identifier != Source.altStoreIdentifier else { continue }

            debugLog("[MiniStore] Removing dead source \(source.identifier).")
            context.delete(source)
        }
    }

    private static func sourceID(for sourceURL: URL) -> String?
    {
        do
        {
            return try Source.sourceID(from: sourceURL)
        }
        catch
        {
            debugLog("[MiniStore] Could not derive a source ID for \(sourceURL). [\(error._domain) \(error._code)] \(error.localizedDescription)")
            return nil
        }
    }
}
