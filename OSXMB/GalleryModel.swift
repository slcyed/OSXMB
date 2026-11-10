import Foundation
import Combine

final class GalleryModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedFamily = "All"
    @Published var hoveredVariant: XMBVariant?
    @Published var appliedID: String

    @Published private(set) var variants: [XMBVariant]
    let families: [String]

    init(initialID: String) {
        let catalog = XMBCatalog.shared
        var allVariants = catalog.variants
        if let index = allVariants.firstIndex(where: { $0.id == SeasonalTheme.variantID }) {
            allVariants[index] = SeasonalTheme.makeVariant()
        }
        variants = allVariants
        families = catalog.families
        appliedID = initialID
        hoveredVariant = catalog.variant(id: initialID) ?? catalog.defaultVariant
    }

    var filtered: [XMBVariant] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return variants.filter { variant in
            let familyMatch = selectedFamily == "All" || variant.family == selectedFamily
            guard familyMatch else { return false }
            guard !query.isEmpty else { return true }
            return variant.name.lowercased().contains(query)
                || variant.family.lowercased().contains(query)
                || (variant.lighting ?? "").lowercased().contains(query)
        }
    }

    var currentVariant: XMBVariant? {
        variants.first { $0.id == appliedID }
    }

    func markApplied(_ variant: XMBVariant) {
        appliedID = variant.id
        hoveredVariant = variant
    }

    func refreshLiveVariant(_ variant: XMBVariant) {
        guard let index = variants.firstIndex(where: { $0.id == SeasonalTheme.variantID }) else { return }
        variants[index] = variant
        if hoveredVariant?.id == variant.id {
            hoveredVariant = variant
        }
    }
}
