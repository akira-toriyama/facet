// FacetCore — pure-logic core, GUI / OS / backend に依存しない。
// 詳細は docs/architecture.md。 現状は migration ベースの placeholder。

/// Module-level bootstrap marker. Replaced by real types
/// (`Workspace`, `WindowID`, `WindowBackend` 等) as the migration
/// from ws-tabs progresses.
public enum Facet {
    public static let version = "0.0.0-bootstrap"
}
