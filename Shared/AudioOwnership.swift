import Foundation

public struct AudioOwnership: Sendable {
    public private(set) var owner: String?
    public private(set) var revision: UInt64 = 0
    public init() {}
    public mutating func select(_ value: String?) { owner = value; revision &+= 1 }
    public func permits(_ value: String, revision expected: UInt64) -> Bool { owner == value && revision == expected }
}
