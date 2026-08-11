//
//  ChappyWidgetsLiveActivity.swift
//  ChappyWidgets
//
//  BUILD 154 — FLIGHT DAY on the lock screen and in the Dynamic Island:
//  countdown to wheels-up, gate, terminal, delay, leave-by. Updated by
//  the app's flight-day passes; nothing here talks to the network.
//
//  ⚠️ ChappyFlightAttributes exists in TWO places on purpose: here, and
//  in CameraAccess/Managers/LiveAIManager.swift. ActivityKit matches
//  them by TYPE NAME and Codable shape across the process boundary —
//  the two copies must stay IDENTICAL, field for field.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct ChappyFlightAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String       // scheduled / active / landed / cancelled
        var gate: String?
        var terminal: String?
        var delayMin: Int
        var departure: Date      // countdown target
        var leaveBy: Date?       // when to walk out the door
    }
    var number: String           // "QF52"
    var airport: String          // "Brisbane Airport"
}

struct ChappyWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChappyFlightAttributes.self) { context in
            // ── Lock screen banner ──
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "airplane.departure")
                        .foregroundStyle(.cyan)
                    Text(context.attributes.number)
                        .font(.headline).bold()
                    Text(context.attributes.airport)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    statusChip(context.state)
                }
                HStack(alignment: .firstTextBaseline) {
                    if context.state.status == "active" {
                        Text("In the air").font(.title3).bold()
                    } else if context.state.departure > Date() {
                        Text(timerInterval: Date()...context.state.departure,
                             countsDown: true)
                            .font(.title2).bold().monospacedDigit()
                        Text("to wheels-up").font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Departing").font(.title3).bold()
                    }
                    Spacer()
                    if let g = context.state.gate {
                        Label("Gate \(g)", systemImage: "signpost.right")
                            .font(.caption).bold()
                    }
                    if let t = context.state.terminal {
                        Label("T\(t)", systemImage: "building.2")
                            .font(.caption)
                    }
                }
                if let leave = context.state.leaveBy, leave > Date() {
                    Label {
                        Text("Leave by \(leave, style: .time)")
                    } icon: {
                        Image(systemName: "figure.walk.departure")
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(Color.cyan)

        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded ──
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.attributes.number, systemImage: "airplane.departure")
                            .font(.headline)
                        if let g = context.state.gate {
                            Text("Gate \(g)").font(.caption).bold()
                                .foregroundStyle(.cyan)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.departure > Date() {
                            Text(timerInterval: Date()...context.state.departure,
                                 countsDown: true)
                                .font(.headline).monospacedDigit()
                                .frame(maxWidth: 64)
                        }
                        if context.state.delayMin > 0 {
                            Text("+\(context.state.delayMin) min")
                                .font(.caption).bold().foregroundStyle(.red)
                        } else {
                            Text("On time").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let t = context.state.terminal {
                            Label("Terminal \(t)", systemImage: "building.2")
                                .font(.caption)
                        }
                        Spacer()
                        if let leave = context.state.leaveBy, leave > Date() {
                            Label {
                                Text("Leave \(leave, style: .time)")
                            } icon: {
                                Image(systemName: "figure.walk.departure")
                            }
                            .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "airplane.departure")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if context.state.delayMin > 0 {
                    Text("+\(context.state.delayMin)m")
                        .font(.caption2).bold().foregroundStyle(.red)
                } else if context.state.departure > Date() {
                    Text(timerInterval: Date()...context.state.departure,
                         countsDown: true)
                        .font(.caption2).monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "airplane")
                }
            } minimal: {
                Image(systemName: "airplane.departure")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(Color.cyan)
        }
    }

    @ViewBuilder
    private func statusChip(_ s: ChappyFlightAttributes.ContentState) -> some View {
        if s.status == "cancelled" {
            Text("CANCELLED").font(.caption2).bold()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.red))
                .foregroundStyle(.white)
        } else if s.delayMin > 0 {
            Text("+\(s.delayMin) min").font(.caption2).bold()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .foregroundStyle(.white)
        } else {
            Text("On time").font(.caption2).bold()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.85)))
                .foregroundStyle(.white)
        }
    }
}
