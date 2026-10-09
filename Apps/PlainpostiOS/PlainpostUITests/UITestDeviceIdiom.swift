import UIKit

/// Whether this UI test run is on an iPhone-class idiom. iPad still shows the split-view
/// root, while the iPhone shell exposes different accessibility identifiers; `PlainpostUITests`
/// and `ContactAutocompleteAcceptanceTests` both branch on this. Ledger Task 25: one place
/// instead of two copies that could drift.
var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
