import ActivityKit
import SwiftUI
import WidgetKit

/*
 * The running workout on the Lock Screen and in the Dynamic Island (and, through the compact
 * views, in an Apple Watch's Smart Stack), moved from frontend/ios/App/OpenGymWidgets/
 * LiveActivityWidget.swift and App/WidgetViews.swift. The buttons are WorkoutActivity.swift's intents.
 */
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LiveLockView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(context.attributes.accentColor)
        } dynamicIsland: { context in
            let accent = context.attributes.accentColor
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.cur?.exName ?? context.attributes.noSetText(context.state))
                            .font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                        if let c = context.state.cur {
                            Text(c.setLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.showsClock {
                        LiveRest(attributes: context.attributes, state: context.state, font: .title3)
                            .frame(maxWidth: 80, alignment: .trailing)
                            .padding(.trailing, 4)
                    } else if let c = context.state.cur {
                        Text(c.target).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveControls(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(accent)
            } compactTrailing: {
                if context.state.showsClock {
                    LiveRest(attributes: context.attributes, state: context.state, font: .caption).frame(width: 46)
                } else {
                    Text("\(context.state.done)/\(context.state.total)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(accent)
                }
            } minimal: {
                if let range = context.state.holdRange ?? context.state.restRange {
                    Text(timerInterval: range, countsDown: true, showsHours: false)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(accent)
                        .frame(width: 34)
                } else {
                    Image(systemName: "dumbbell.fill").foregroundStyle(accent)
                }
            }
            .keylineTint(accent)
        }
    }
}

extension WorkoutActivityAttributes {
    var accentColor: Color { Color(hex: accent) ?? .cyan }
    var inkColor: Color { Color(hex: ink) ?? .black }

    /// The line with no set to show: all done, or sets left that the activity does not carry.
    func noSetText(_ state: ContentState) -> String { state.done < state.total ? labels.openApp : labels.allDone }

    /// The word over the clock: the hold or the rest.
    func clockLabel(_ state: ContentState) -> String { state.holding ? labels.hold : labels.rest }
}

extension WorkoutActivityAttributes.ContentState {
    var showsClock: Bool { holding || resting }
}

/// The hold or the rest counting down (a hold first: it is what is happening now).
struct LiveRest: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    var font: Font = .title2

    var body: some View {
        if let range = state.holdRange ?? state.restRange {
            Text(timerInterval: range, countsDown: true)
                .font(font.weight(.bold)).monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(attributes.accentColor)
        } else if let left = state.holdLeft ?? state.restLeft {
            Label(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60), systemImage: "pause.fill")
                .font(font.weight(.bold)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Progress, then Skip rest or Next exercise, then Log set.
struct LiveControls: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        let accent = attributes.accentColor
        HStack(spacing: 10) {
            ProgressBar(value: Double(state.done) / Double(max(1, state.total)), accent: accent)
            Text("\(state.done)/\(state.total)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            if state.resting {
                Button(intent: SkipRestIntent(wid: attributes.wid)) {
                    Image(systemName: "forward.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(accent)
                .accessibilityLabel(Text(attributes.labels.skipRest))
            } else if let c = state.cur, state.nextUnitStart != nil {
                Button(intent: NextExerciseIntent(wid: attributes.wid, entryIdx: c.entryIdx)) {
                    Image(systemName: "forward.end.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(accent)
                .accessibilityLabel(Text(attributes.labels.nextExercise))
            }
            if let c = state.cur {
                Button(intent: DoneSetIntent(wid: attributes.wid, exId: c.exId, entryIdx: c.entryIdx, setIdx: c.setIdx)) {
                    Label(attributes.labels.done, systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(attributes.inkColor)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .accessibilityHint(Text([c.exName, c.setLine].filter { !$0.isEmpty }.joined(separator: ", ")))
            }
        }
    }
}

/// The Lock Screen's (and a watch Smart Stack's) workout.
struct LiveLockView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.cur?.exName ?? attributes.noSetText(state)).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(state.cur.map { [$0.setLine, $0.target].filter { !$0.isEmpty }.joined(separator: " · ") } ?? state.name)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if state.showsClock {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(attributes.clockLabel(state)).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                        LiveRest(attributes: attributes, state: state).frame(maxWidth: 96, alignment: .trailing)
                    }
                }
            }
            LiveControls(attributes: attributes, state: state)
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
    }
}
