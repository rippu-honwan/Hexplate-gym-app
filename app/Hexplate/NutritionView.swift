import SwiftUI

/// The Nutrition tab placeholder shell until Stage 4 introduces meal and body-scan tracking.
struct NutritionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nutrition",
                systemImage: "fork.knife",
                description: Text("Daily calories, macros, and body composition will appear here.")
            )
            .navigationTitle("Nutrition")
        }
    }
}
