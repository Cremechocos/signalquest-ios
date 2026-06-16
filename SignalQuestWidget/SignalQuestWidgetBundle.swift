import WidgetKit
import SwiftUI

@main
struct SignalQuestWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedtestWidget()
        SpeedtestTrendWidget()
        if #available(iOS 16.1, *) {
            SpeedtestLiveActivity()
        }
    }
}
