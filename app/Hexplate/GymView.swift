import HexplateCore
import SwiftUI

/// The Gym tab: Plan, Programmes, and Exercises under a single navigation stack.
struct GymView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var editMode: EditMode = .inactive
    @State private var query = ""
    @State private var filter = ExerciseFilter()
    @State private var favouritesOnly = false
    @State private var customOnly = false
    @State private var mineOnly = true
    @State private var creating = false

    private var activeEquipmentProfile: [String: JSONValue]? { ExerciseCatalog.activeProfile(model.root) }
    private var isExercisesFiltered: Bool { favouritesOnly || customOnly }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                switch model.gymSegment {
                case .plan:
                    PlanContent(path: $path)
                case .programmes:
                    ProgrammesContent()
                case .exercises:
                    LibraryContent(
                        query: $query,
                        filter: $filter,
                        favouritesOnly: $favouritesOnly,
                        customOnly: $customOnly,
                        mineOnly: $mineOnly
                    )
                }
            }
            .safeAreaBar(edge: .top) {
                VStack(spacing: 0) {
                    Picker("Gym", selection: $model.gymSegment) {
                        Text("Plan").tag(AppModel.GymSegment.plan)
                        Text("Programmes").tag(AppModel.GymSegment.programmes)
                        Text("Exercises").tag(AppModel.GymSegment.exercises)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)

                    if model.gymSegment == .exercises {
                        ExerciseFilterBar(filter: $filter)
                    }
                }
            }
            .navigationTitle("Gym")
            .toolbar {
                if model.gymSegment == .plan && model.routines.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
                if model.gymSegment == .exercises {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Filter", systemImage: isExercisesFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") {
                            Toggle("Favourites", systemImage: "star", isOn: $favouritesOnly)
                            Toggle("My exercises", systemImage: "person", isOn: $customOnly)
                            if activeEquipmentProfile != nil {
                                Toggle("My equipment only", systemImage: "dumbbell", isOn: $mineOnly)
                            }
                            if isExercisesFiltered || filter.isOn {
                                Button("Clear", systemImage: "xmark") {
                                    filter = ExerciseFilter()
                                    favouritesOnly = false
                                    customOnly = false
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New exercise", systemImage: "plus") { creating = true }
                    }
                }
            }
            // Applied outside .toolbar so EditButton toggles GymView's owned editMode binding.
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $creating) { CustomExerciseEditor() }
            .navigationDestination(for: RoutineLink.self) { RoutineEditorView(routineId: $0.id) }
            .navigationDestination(for: ProgrammeLink.self) { ProgrammeEditor(id: $0.id) }
            .exerciseDestination()
            .workoutDestination()
        }
        .onChange(of: model.gymSegment) {
            editMode = .inactive
            path = NavigationPath()
        }
        .onChange(of: model.gymResetToken) {
            editMode = .inactive
            path = NavigationPath()
        }
    }
}
