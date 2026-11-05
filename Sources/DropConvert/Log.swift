import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "com.bobclawblaw.dropconvert", category: "app")
    static let jobs = Logger(subsystem: "com.bobclawblaw.dropconvert", category: "jobs")
    static let tools = Logger(subsystem: "com.bobclawblaw.dropconvert", category: "tools")
}
