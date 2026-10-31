import Foundation

// Storage transactions are intentionally unavailable until the locking/Trash implementation in Phase 2.
FileHandle.standardError.write(Data("{\"ok\":false,\"code\":\"storage-transactions-unavailable\"}\n".utf8))
exit(64)
