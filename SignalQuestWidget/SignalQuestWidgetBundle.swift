import WidgetKit
import SwiftUI

@main
struct SignalQuestWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedtestWidget()
        SpeedtestTrendWidget()
        NetworkWidget()
        if #available(iOS 16.1, *) {
            SpeedtestLiveActivity()
        }
        if #available(iOS 18.0, *) {
            SpeedtestControl()
        }
    }
}
