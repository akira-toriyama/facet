// FacetAdapterNative — Swift から AX / CGS / SLS を直接叩いて
// FacetCore の backend protocol を実装する adapter。 SIP enable で
// 動く WM を目指す。 Phase α-ε で段階開発（docs/architecture.md）。
import FacetCore

public enum FacetAdapterNative {
    public static let kind = "native"
}
