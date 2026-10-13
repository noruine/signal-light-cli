import Foundation

/// One wording per context: inside the menu the next step is an item on
/// screen, while a one-shot command can name the command to type.
enum ContextText {
    static func choose(cli: String, menu: String) -> String {
        CLIRuntimeContext.isMenuSession ? menu : cli
    }
}
