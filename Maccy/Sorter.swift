import AppKit
import Defaults

// swiftlint:disable identifier_name
// swiftlint:disable type_name
class Sorter {
  enum By: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case lastCopiedAt
    case firstCopiedAt
    case numberOfCopies

    var id: Self { self }

    var description: String {
      switch self {
      case .lastCopiedAt:
        return NSLocalizedString("LastCopiedAt", tableName: "StorageSettings", comment: "")
      case .firstCopiedAt:
        return NSLocalizedString("FirstCopiedAt", tableName: "StorageSettings", comment: "")
      case .numberOfCopies:
        return NSLocalizedString("NumberOfCopies", tableName: "StorageSettings", comment: "")
      }
    }
  }

  func sort(_ items: [HistoryItem], by: By = Defaults[.sortBy]) -> [HistoryItem] {
    items.sorted {
      areInIncreasingOrder($0, $1, by: by)
    }
  }

  /// Stable storage ordering used for offset-based page queries.
  ///
  /// Secondary descriptors keep equal primary values from moving between
  /// neighboring pages.
  func sortDescriptors(
    by: By = Defaults[.sortBy]
  ) -> [SortDescriptor<HistoryItem>] {
    switch by {
    case .lastCopiedAt:
      return [
        SortDescriptor(\.lastCopiedAt, order: .reverse),
        SortDescriptor(\.firstCopiedAt, order: .reverse),
        SortDescriptor(\.numberOfCopies, order: .reverse),
        SortDescriptor(\.title),
        SortDescriptor(\.persistentModelID),
      ]
    case .firstCopiedAt:
      return [
        SortDescriptor(\.firstCopiedAt, order: .reverse),
        SortDescriptor(\.lastCopiedAt, order: .reverse),
        SortDescriptor(\.numberOfCopies, order: .reverse),
        SortDescriptor(\.title),
        SortDescriptor(\.persistentModelID),
      ]
    case .numberOfCopies:
      return [
        SortDescriptor(\.numberOfCopies, order: .reverse),
        SortDescriptor(\.lastCopiedAt, order: .reverse),
        SortDescriptor(\.firstCopiedAt, order: .reverse),
        SortDescriptor(\.title),
        SortDescriptor(\.persistentModelID),
      ]
    }
  }

  func areInIncreasingOrder(
    _ lhs: HistoryItem,
    _ rhs: HistoryItem,
    by: By = Defaults[.sortBy]
  ) -> Bool {
    switch by {
    case .firstCopiedAt:
      return lhs.firstCopiedAt > rhs.firstCopiedAt
    case .numberOfCopies:
      return lhs.numberOfCopies > rhs.numberOfCopies
    default:
      return lhs.lastCopiedAt > rhs.lastCopiedAt
    }
  }
}
// swiftlint:enable identifier_name
// swiftlint:enable type_name
