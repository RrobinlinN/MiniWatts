import SwiftUI

/// Switches for finding what makes a scroll on Power hitch once a second on iOS 16.
///
/// There is no Instruments here: the build is made in CI and run on a phone with
/// no Mac attached, so the cost is bisected by hand, the way the original was found
/// by turning things off one at a time (see *Performance* in CLAUDE.md). Each switch
/// removes one suspect; whichever one makes the hitch go away is the cost. Remove
/// this panel once that is known.
struct PerformanceExperiments: View {
    static let noDialGlowKey = "experiment.noDialGlow"
    static let noLiveChartKey = "experiment.noLiveChart"

    @AppStorage(noDialGlowKey) private var noDialGlow = false
    @AppStorage(noLiveChartKey) private var noLiveChart = false

    var body: some View {
        Panel("Performance experiments", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $noDialGlow) {
                    Text("No glow on the dial")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(.mwAccent)
                Toggle(isOn: $noLiveChart) {
                    Text("No live chart on Power")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(.mwAccent)
                Text("For finding what makes scrolling stutter once a second. Turn one on, scroll the Power page and let it coast, and see whether the stutter goes.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
