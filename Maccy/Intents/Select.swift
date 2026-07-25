import AppIntents

struct Select: AppIntent, CustomIntentMigratedAppIntent {
  static let intentClassName = "SelectIntent"

  static var title: LocalizedStringResource = "Select Item in Clipboard History"
  static var description = IntentDescription("""
  Selects an item in Maccy clipboard history.
  Depending on Maccy settings, it might trigger pasting of the selected item.
  """)

  static var parameterSummary: some ParameterSummary {
    Summary("Select \(\.$number) Item in Clipboard History")
  }

  @Parameter(title: "Number", default: 1, requestValueDialog: "What is the number of the item?")
  var number: Int

  private let positionOffset = 1

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let index = number - positionOffset
    guard let locatedItem = try await AppState.shared.history.historyItems.item(
      atDisplayIndex: index
    ) else {
      throw AppIntentError.notFound
    }

    let value = locatedItem.item.title
    await AppState.shared.history.select(locatedItem.item)

    return .result(value: value)
  }
}
