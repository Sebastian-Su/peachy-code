import OSLog

/// Centralized logging for PeachyPet.
/// Each subsystem component gets its own category for easy filtering in Console.app.
///
/// Usage:
///   PeachyLog.session.info("Session started: \(id)")
///   PeachyLog.event.debug("Received \(event.hookEventName)")
///   PeachyLog.codex.error("JSONL parse failed: \(error)")
///
/// Console.app filter: subsystem == "com.peachy.pet"
/// CLI: log stream --predicate 'subsystem == "com.peachy.pet"'
enum PeachyLog {
    static let session   = Logger(subsystem: "com.peachy.pet", category: "session")
    static let event     = Logger(subsystem: "com.peachy.pet", category: "event")
    static let codex     = Logger(subsystem: "com.peachy.pet", category: "codex")
    static let network   = Logger(subsystem: "com.peachy.pet", category: "network")
    static let permission = Logger(subsystem: "com.peachy.pet", category: "permission")
    static let ui        = Logger(subsystem: "com.peachy.pet", category: "ui")
    static let lang      = Logger(subsystem: "com.peachy.pet", category: "lang")
}
