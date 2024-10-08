#if !canImport(Darwin)
@preconcurrency
#endif
import Dispatch

/// SchedulingWatchdog makes sure that databases connections are used on correct
/// dispatch queues, and warns the user with a fatal error whenever she misuses
/// a database connection.
///
/// Generally speaking, each connection has its own dispatch queue. But it's not
/// enough: users need to use two database connections at the same time:
/// <https://github.com/groue/GRDB.swift/issues/55>. To support this use case, a
/// single dispatch queue can be temporarily shared by two or more connections.
///
/// - SchedulingWatchdog.makeSerializedQueue(allowingDatabase:) creates a
///   dispatch queue that allows one database.
///
///   It does so by registering one instance of SchedulingWatchdog as a specific
///   of the dispatch queue, a SchedulingWatchdog that allows that database only.
///
///   Later on, the queue can be shared by several databases with the method
///   inheritingAllowedDatabases(from:execute:). See SerializedDatabase.sync()
///   for an example.
///
/// - preconditionValidQueue() crashes whenever a database is used in an invalid
///   dispatch queue.
final class SchedulingWatchdog: @unchecked Sendable {
    // @unchecked Sendable because mutable `allowedDatabases` is only
    // accessed from the serial dispatch queue the instance is attached to.
    
    private static let watchDogKey = DispatchSpecificKey<SchedulingWatchdog>()
    
    /// The databases allowed in the current dispatch queue.
    ///
    /// MUST be accessed from the serial dispatch queue the instance is attached to.
    private(set) var allowedDatabases: [Database]
    
    var databaseObservationBroker: DatabaseObservationBroker?
    
    private init(allowedDatabase database: Database) {
        allowedDatabases = [database]
    }
    
    static func allowDatabase(_ database: Database, onQueue queue: DispatchQueue) {
        precondition(queue.getSpecific(key: watchDogKey) == nil)
        let watchdog = SchedulingWatchdog(allowedDatabase: database)
        queue.setSpecific(key: watchDogKey, value: watchdog)
    }
    
    /// Must be called from a DispatchQueue with an attached SchedulingWatchdog.
    static func inheritingAllowedDatabases<T>(
        _ allowedDatabases: [Database], execute body: () throws -> T
    ) rethrows -> T {
        let watchdog = current!
        let backup = watchdog.allowedDatabases
        watchdog.allowedDatabases.append(contentsOf: allowedDatabases)
        defer { watchdog.allowedDatabases = backup }
        return try body()
    }
    
    static func preconditionValidQueue(
        _ db: Database,
        _ message: @autoclosure() -> String = "Database was not used on the correct thread.",
        file: StaticString = #file,
        line: UInt = #line)
    {
        GRDBPrecondition(allows(db), message(), file: file, line: line)
    }
    
    /// Returns whether the database argument can be used in the current
    /// dispatch queue.
    static func allows(_ db: Database) -> Bool {
        current?.allows(db) ?? false
    }
    
    func allows(_ db: Database) -> Bool {
        allowedDatabases.contains { $0 === db }
    }
    
    static var current: SchedulingWatchdog? {
        DispatchQueue.getSpecific(key: watchDogKey)
    }
}
