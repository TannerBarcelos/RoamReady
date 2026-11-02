import Foundation
import OSLog
import SwiftData

/// Deletes menu data from before ingredient amounts were structured. See
/// docs/adr/0001-structured-ingredient-amounts.md.
///
/// A meal is old when `hasStructuredAmounts` is false; deleting it cascades to its dishes and
/// ingredients. Nothing else is touched: rigs, trips, checklist steps, photos, notes, documents, and
/// saved campgrounds are never fetched here.
///
/// It runs every time the real library opens and keeps no "already done" flag. The delete is idempotent
/// (once the old meals are gone it finds none), and a flag or date cutoff could let a second device
/// delete a menu already rebuilt on the first. A meal an older build syncs in after a launch is
/// removed by the next one.
public enum MenuWipe {
    private static let log = Logger(subsystem: "com.tannerdev.roamready", category: "MenuWipe")

    /// Deletes every meal without the marker and saves. Returns how many meals were deleted. On a failed
    /// save the deletions are rolled back, so nothing is half done.
    @discardableResult
    public static func deleteMealsWithoutStructuredAmounts(in context: ModelContext) throws -> Int {
        // The marker is read from each meal rather than filtered in a predicate: a stored row that has no
        // value for it (as a synced record from an older build can) still reads as false and is removed.
        let old = try context.fetch(FetchDescriptor<TripMeal>()).filter { !$0.hasStructuredAmounts }
        guard !old.isEmpty else { return 0 }
        for meal in old { context.delete(meal) }
        do { try context.save() } catch { context.rollback(); throw error }
        return old.count
    }

    /// What the app calls as the library opens. A failure is logged and skipped, never thrown, so the
    /// app still opens and the next launch retries. Only counts are logged, never the owner's text.
    @discardableResult
    public static func runAtLaunch(in context: ModelContext) -> Int {
        do {
            let deleted = try deleteMealsWithoutStructuredAmounts(in: context)
            if deleted > 0 { log.info("MENU-WIPE: deleted \(deleted, privacy: .public) meals from before structured amounts") }
            return deleted
        } catch {
            log.error("MENU-WIPE: failed, will retry on the next launch (\(type(of: error), privacy: .public))")
            return 0
        }
    }
}
