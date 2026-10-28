import MemeMeCore

/// SwiftUI (via DeveloperToolsSupport) also declares a `LibraryItem`. This module-level alias
/// shadows it, so every use in the app target resolves to the core type.
typealias LibraryItem = MemeMeCore.LibraryItem
