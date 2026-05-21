// facet executable bootstrap.
import FacetCore
import FacetAdapterRift
import FacetAdapterNative
import FacetView
import FacetViewTree
import FacetViewGrid

@main
enum FacetApp {
    static func main() {
        print("facet v\(Facet.version) — bootstrap. Migration from ws-tabs in progress.")
        print("See https://github.com/akira-toriyama/facet")
    }
}
