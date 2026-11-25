import HexplateCore
import SwiftUI

/// The Analysis tab: hosts StatsContent flatly inside a single NavigationStack and List.
struct AnalysisView: View {
    @State private var sheet: StatsSheet?

    var body: some View {
        NavigationStack {
            List {
                StatsContent(sheet: $sheet)
            }
            .navigationTitle("Analysis")
            .sheet(item: $sheet) { s in
                switch s {
                case .weight: WeightEntry()
                case .composition: MeasurementEntry(title: "Body composition", fields: BodyData.compositionFields, withWeight: true)
                case .tape: MeasurementEntry(title: "Measurements", fields: BodyData.tapeFields, withWeight: false)
                }
            }
            .navigationDestination(for: LiftLink.self) { OneRepMaxView(id: $0.id) }
        }
    }
}
