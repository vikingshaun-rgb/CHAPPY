//
//  ChappyWidgetsBundle.swift
//  ChappyWidgets
//
//  Created by user951653 on 8/11/26.
//

import WidgetKit
import SwiftUI

@main
struct ChappyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChappyWidgets()
        ChappyWidgetsControl()
        ChappyWidgetsLiveActivity()
    }
}
