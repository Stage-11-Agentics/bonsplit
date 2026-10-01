import Foundation

/// Host-supplied detail for one tab, rendered by the tab sheet's grid.
///
/// Bonsplit stays generic: it never derives any of this. The host fills it from
/// its own panels and metadata, and the sheet only draws it.
public struct BonsplitTabDetail: Codable, Hashable, Sendable {
    /// The lifecycle word shown in the sheet's status column.
    public enum StatusKind: String, Codable, Hashable, Sendable, CaseIterable {
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

        private enum CodingKeys: String, CodingKey { case kind, since, needsAttention }

        /// `needsAttention` decodes with the kind's default when absent.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(StatusKind.self, forKey: .kind)
            self.kind = kind
            self.since = try c.decodeIfPresent(Date.self, forKey: .since)
            self.needsAttention = try c.decodeIfPresent(Bool.self, forKey: .needsAttention)
                ?? (kind == .waiting || kind == .flagged)
        }
    }

    /// The tab's full, untruncated title. The tab strip shows a shortened
    /// label; the sheet's title column has room for the whole title.
    public var title: String?
    /// `Harness · model`, `Harness` alone when the model is unknown, nil when
    /// the tab hosts no agent. The Type column shows it as a chip.
    public var agentLabel: String?
    /// The agent chip's text colour as `#RRGGBB` (the host colours by model
    /// family). Deepened on a light sheet until it reads; nil uses the chip's
    /// default ink.
    public var agentTintHex: String?
    /// The tab's kind when it hosts no agent (`Terminal`, `Browser`,
    /// `Markdown`), shown as plain text in the Type column.
    public var typeLabel: String?
    /// Second line of the row: the tab's description, or a kind-specific
    /// fallback (cwd, host, path).
    public var subtitle: String?
    public var status: Status?
    /// Named clocks by lowercase name (`active`, `launched`, `seen`). A missing
    /// entry renders as a dash.
    public var clocks: [String: Date]
    /// Host-formatted text for clocks that are not a point in time (a turn
    /// duration, a tool-call count, a token count), by lowercase name. When a
    /// name has text here the cell shows it instead of an age; a missing entry
    /// falls back to `clocks`, then a dash.
    public var clockTexts: [String: String]

    public init(
        title: String? = nil,
        agentLabel: String? = nil,
        agentTintHex: String? = nil,
        typeLabel: String? = nil,
        subtitle: String? = nil,
        status: Status? = nil,
        clocks: [String: Date] = [:],
        clockTexts: [String: String] = [:]
    ) {
        self.title = title
        self.agentLabel = agentLabel
        self.agentTintHex = agentTintHex
        self.typeLabel = typeLabel
        self.subtitle = subtitle
        self.status = status
        self.clocks = clocks
        self.clockTexts = clockTexts
    }

    /// Decodes tolerantly: a payload written by an older build (drag payloads
    /// cross builds) has no `agentTintHex`, `typeLabel`, `clocks` or `clockTexts`, and must still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.agentLabel = try c.decodeIfPresent(String.self, forKey: .agentLabel)
        self.agentTintHex = try c.decodeIfPresent(String.self, forKey: .agentTintHex)
        self.typeLabel = try c.decodeIfPresent(String.self, forKey: .typeLabel)
        self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        self.status = try c.decodeIfPresent(Status.self, forKey: .status)
        self.clocks = try c.decodeIfPresent([String: Date].self, forKey: .clocks) ?? [:]
        self.clockTexts = try c.decodeIfPresent([String: String].self, forKey: .clockTexts) ?? [:]
    }
}
