//
//  ChappyWidgetsLiveActivity.swift
//  ChappyWidgets
//
//  Created by user951653 on 8/11/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct ChappyWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct ChappyWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChappyWidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension ChappyWidgetsAttributes {
    fileprivate static var preview: ChappyWidgetsAttributes {
        ChappyWidgetsAttributes(name: "World")
    }
}

extension ChappyWidgetsAttributes.ContentState {
    fileprivate static var smiley: ChappyWidgetsAttributes.ContentState {
        ChappyWidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: ChappyWidgetsAttributes.ContentState {
         ChappyWidgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: ChappyWidgetsAttributes.preview) {
   ChappyWidgetsLiveActivity()
} contentStates: {
    ChappyWidgetsAttributes.ContentState.smiley
    ChappyWidgetsAttributes.ContentState.starEyes
}
