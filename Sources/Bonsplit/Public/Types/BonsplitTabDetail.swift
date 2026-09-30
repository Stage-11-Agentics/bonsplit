import Foundation

/// Host-supplied detail for one tab, rendered by the tab sheet's grid.
///
/// Bonsplit stays generic: it never derives any of this. The host fills it from
/// its own panels and metadata, and the sheet only draws it.
public struct BonsplitTabDetail: Codable, Hashable, Sendable {
    /// The lifecycle word shown in the sheet's status column.
    public enum StatusKind: String, Codable, Hashable, Sendable {
        case working
        case waiting
        case flagged
        case idle
        case cold
    }

    public struct Status: Codable, Hashable, Sendable {
        public var kind: StatusKind
        /// When the tab entered `kind`; the sheet renders the elapsed time.
        public var since: Date?
        /// Whether the operator is wanted (counted as "need you" in the sheet's
        /// footer). The host decides; the default is waiting and flagged.
        public var needsAttention: Bool

        public init(kind: StatusKind, since: Date? = nil, needsAttention: Bool? = nil) {
            self.kind = kind
            self.since = since
            self.needsAttention = needsAttention ?? (kind == .waiting || kind == .flagged)
        }
    }

    /// The tab's full, untruncated title. The tab strip shows a shortened
    /// label; the sheet's title column has room for the whole title.
    public var title: String?
    /// `Harness · model`, `Harness` alone when the model is unknown, nil when
    /// the tab hosts no agent.
    public var agentLabel: String?
    /// Second line of the row: the tab's description, or a kind-specific
    /// fallback (cwd, host, path).
    public var subtitle: String?
    public var status: Status?
    /// Named clocks by lowercase name (`active`, `launched`, `seen`). A missing
    /// entry renders as a dash.
    public var clocks: [String: Date]

    public init(
        title: String? = nil,
        agentLabel: String? = nil,
        subtitle: String? = nil,
        status: Status? = nil,
        clocks: [String: Date] = [:]
    ) {
        self.title = title
        self.agentLabel = agentLabel
        self.subtitle = subtitle
        self.status = status
        self.clocks = clocks
    }
}
