import Combine
import CoreData
import OSLog
import SwiftUI
import Swinject

extension AddCarbs {
    struct RootView: BaseView {
        let resolver: Resolver
        let editMode: Bool
        let override: Bool
        let mode: MealMode.Mode
        @StateObject var state: StateModel
        @StateObject var foodSearchState = FoodSearchStateModel()

        @State var dish: String = ""
        @State var isPromptPresented = false
        @State var saved = false
        @State var pushed = false
        @State var button = false

        @State private var showAlert = false
        @State private var presentPresets = false
        @State private var string = ""
        @State private var showMicronutrients = false

        // Food Search States
        @State private var showCancelConfirmation = false

        @State private var newPreset: (
            dish: String,
            carbs: Decimal,
            fat: Decimal,
            protein: Decimal,
            fiber: Decimal,
            micronutrient: [MicronutrientValue]
        ) = ("", 0, 0, 0, 0, [])

        @State private var showFddbImportSheet = false
        @State private var fddbURLString: String = ""
        @State private var fddbIsImporting = false
        @State private var fddbErrorMessage: String? = nil
        @State private var fddbImportInfo: String? = nil

        // NOTE: We keep the import UI simple and manual on purpose (no deep-link handler).
        // The importer normalizes values to per serving (1 portion) where possible.

        @FetchRequest(
            entity: Presets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)], predicate:
            NSCompoundPredicate(
                andPredicateWithSubpredicates: [
                    NSPredicate(format: "dish != %@", " " as String),
                    NSPredicate(format: "dish != %@", "Empty" as String)
                ]
            )
        ) var carbPresets: FetchedResults<Presets>

        @Environment(\.managedObjectContext) var moc
        @Environment(\.colorScheme) var colorScheme
        @EnvironmentObject var mainState: Main.StateModel

        init(
            resolver: Resolver,
            editMode: Bool,
            override: Bool,
            mode: MealMode.Mode
        ) {
            self.resolver = resolver
            self.editMode = editMode
            self.override = override
            self.mode = mode
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        private static let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        private func format(_ value: Decimal) -> String {
            Self.formatter.string(from: value as NSNumber) ?? ""
        }

        var body: some View {
            content
                .background(Color(.systemGroupedBackground))
                .compactSectionSpacing()
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(leading: leadingNavItem, trailing: trailingNavItem)
                .sheet(isPresented: $foodSearchState.showingSettings) {
                    FoodSearchSettingsView(state: state)
                }
                .sheet(isPresented: $isPromptPresented) { editView }
                .confirmationDialog(
                    NSLocalizedString("Discard Meal?", comment: "Discard Meal"),
                    isPresented: $showCancelConfirmation,
                    titleVisibility: .visible,
                    actions: cancelDialogActions,
                    message: { Text("Do you want to discard this meal?") }
                )
                .onAppear(perform: handleOnAppear)
                .onDisappear { mainState.shouldPreventModalDismiss = false }
                .onChange(of: shouldPreventDismiss) { syncDismissState() }
                .onChange(of: foodSearchState.showSavedFoods) { syncDismissState() }
                .onChange(of: carbPresets.count) { updateSavedFoods() }
                .sheet(isPresented: $foodSearchState.showNewSavedFoodEntry) { foodItemEditorSheet }
                .sheet(isPresented: $showFddbImportSheet) { fddbImportSheet }
        }

        @ViewBuilder private var content: some View {
            VStack(spacing: 0) {
                FoodSearchBar(rootState: state, state: foodSearchState)
                    .padding(.horizontal)

                if foodSearchState.showingFoodSearch {
                    foodSearchView
                } else {
                    mealView
                }
            }
        }

        private var foodSearchView: some View {
            FoodSearchView(
                state: foodSearchState,
                onContinue: handleFoodContinue,
                onHypoTreatment: hypoHandler,
                onPersist: saveOrUpdatePreset,
                onDelete: deletePreset,
                continueButtonLabelKey: continueLabel,
                hypoTreatmentButtonLabelKey: "Hypo Treatment"
            )
        }

        @ViewBuilder private var foodItemEditorSheet: some View {
            FoodItemEditorSheet(
                existingItem: foodSearchState.newFoodEntryToEdit,
                title: NSLocalizedString("Add Food Manually", comment: ""),
                allExistingTags: Set(foodSearchState.savedFoods?.foodItems.flatMap { $0.tags ?? [] } ?? []),
                showTagsAndFavorite: true,
                onSave: { foodItem in
                    saveOrUpdatePreset(foodItem)
                    foodSearchState.showNewSavedFoodEntry = false
                    foodSearchState.newFoodEntryToEdit = nil
                },
                onCancel: {
                    foodSearchState.showNewSavedFoodEntry = false
                    foodSearchState.newFoodEntryToEdit = nil
                }
            )
        }

        @ViewBuilder private var fddbImportSheet: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import from FDDB")
                        .font(.headline)
                        .padding(.top, 8)

                    Text(
                        "Füge den FDDB-Share-Link ein (z. B. https://share.fddbextender.de/3975627). Wir lesen Name und Nährwerte und normalisieren auf eine Portion."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Share URL")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            TextField("https://share.fddbextender.de/...", text: $fddbURLString)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .disabled(fddbIsImporting)
                                .textFieldStyle(.roundedBorder)

                            if !fddbURLString.isEmpty {
                                Button(action: { fddbURLString = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(fddbIsImporting)
                            }
                        }
                    }

                    if let error = fddbErrorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.footnote)
                        }
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                    if let info = fddbImportInfo {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(info)
                                .font(.footnote)
                        }
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        Button("Cancel") {
                            showFddbImportSheet = false
                            fddbErrorMessage = nil
                            fddbImportInfo = nil
                            fddbURLString = ""
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(10)

                        Button(action: { performFddbImport() }) {
                            HStack(spacing: 8) {
                                if fddbIsImporting {
                                    ProgressView()
                                }
                                Text("Import")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            (!fddbURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fddbIsImporting) ?
                                Color.accentColor : Color.gray.opacity(0.2)
                        )
                        .foregroundColor((
                            !fddbURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty && !fddbIsImporting
                        ) ? .white : .secondary)
                        .cornerRadius(10)
                        .disabled(fddbURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fddbIsImporting)
                    }
                }
                .padding()
                .navigationTitle("FDDB Import")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.height(260), .medium])
            .presentationDragIndicator(.visible)
        }

        private var hypoHandler: ((FoodItemDetailed, UIImage?, Date?) -> Void)? {
            guard state.id != nil,
                  state.id != "None",
                  state.carbsRequired != nil else { return nil }

            return { food, _, date in
                button.toggle()
                guard button else { return }

                state.hypoTreatment = true
                state.addAIFood(override, fetch: editMode, food: food, date: date)
            }
        }

        private var navigationTitle: LocalizedStringKey {
            foodSearchState.showSavedFoods ? "Saved Foods" : "Add Meal"
        }

        @ViewBuilder private var leadingNavItem: some View {
            if foodSearchState.showSavedFoods {
                HStack(spacing: 12) {
                    Button(action: {
                        foodSearchState.showNewSavedFoodEntry = true
                    }) {
                        Label("New", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.blue)
                    }

                    Button(action: {
                        // Open the FDDB import sheet where the user can paste a share link
                        showFddbImportSheet = true
                    }) {
                        Label("Import", systemImage: "link.badge.plus")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.blue)
                    }
                }
            }
        }

        private var trailingNavItem: some View {
            Button(action: handleDismissAction) {
                Text(foodSearchState.showSavedFoods ? "Done" : "Cancel")
            }
        }

        private var continueLabel: LocalizedStringKey {
            (state.skipBolus && !override && !editMode) ? "Save" : "Continue"
        }

        @ViewBuilder private func cancelDialogActions() -> some View {
            Button("Discard", role: .destructive) {
                state.hideModal()
                if editMode { state.apsManager.determineBasalSync() }
            }
            Button("Cancel", role: .cancel) {}
        }

        // MARK: - Main Meal Section

        private var mealView: some View {
            Form {
                if let carbsReq = state.carbsRequired,
                   state.carbs < carbsReq
                {
                    Section {
                        HStack {
                            Text("Carbs required")

                            Spacer()

                            Text(
                                (Self.formatter.string(
                                    from: carbsReq as NSNumber
                                ) ?? "") + " g"
                            )
                        }
                    }
                }

                Section {
                    macroRow(
                        title: "Carbs",
                        value: $state.carbs,
                        color: .primary,
                        bold: true,
                        autofocus: true
                    )

                    macroRow(
                        title: "Fat",
                        value: $state.fat,
                        color: .blue
                    )

                    macroRow(
                        title: "Protein",
                        value: $state.protein,
                        color: .green
                    )

                    if state.mealViewMicronutrients {
                        otherNutritionButton
                    }

                    timeRow
                }

                if !empty, !saved {
                    savePresetButton
                }

                if state.carbs > 0,
                   let profile = state.id,
                   profile != "None",
                   state.carbsRequired != nil
                {
                    hypoTreatmentSection
                }

                continueSection
            }
            .sheet(isPresented: $presentPresets) {
                presetView
            }
            .sheet(isPresented: $showMicronutrients) {
                OtherNutritionSheet(
                    fiber: $state.fiber,
                    note: $state.note,
                    micronutrients: $state.micronutrient,
                    formatter: Self.formatter
                )
            }
        }

        // MARK: - Compact Macro Row

        @ViewBuilder private func macroRow(
            title: LocalizedStringKey,
            value: Binding<Decimal>,
            color: Color,
            bold: Bool = false,
            autofocus: Bool = false
        ) -> some View {
            HStack {
                Text(title)
                    .foregroundStyle(color)
                    .fontWeight(bold ? .semibold : .regular)

                Spacer()

                DecimalTextField(
                    "0",
                    value: value,
                    formatter: Self.formatter,
                    autofocus: autofocus,
                    liveEditing: true
                )

                Text("g")
                    .foregroundStyle(.secondary)
            }
        }

        private var otherNutritionButton: some View {
            Button {
                showMicronutrients = true
            } label: {
                HStack {
                    Label("Other", systemImage: "ellipsis.circle")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(otherNutritionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var otherNutritionSummary: String {
            let hasFiber = state.fiber > 0
            let microCount = state.micronutrient.count

            switch (hasFiber, microCount > 0) {
            case (false, false):
                return state.note

            case (true, false):
                return "Fiber"

            case (false, true):
                return String(format: NSLocalizedString("%d micros", comment: "Micros count"), microCount)

            case (true, true):
                return String(format: NSLocalizedString("Fiber • %d", comment: "Fiber and micros count"), microCount)
            }
        }

        // MARK: - Time Row

        private var timeRow: some View {
            HStack {
                Text("Time")

                Spacer()

                if !pushed {
                    Button {
                        pushed = true
                    } label: {
                        Text("Now")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 5)

                } else {
                    Button {
                        state.date = state.date.addingTimeInterval(
                            -15.minutes.timeInterval
                        )
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .tint(.blue)
                    .buttonStyle(.borderless)

                    DatePicker(
                        "Time",
                        selection: $state.date,
                        displayedComponents: [.hourAndMinute]
                    )
                    .controlSize(.mini)
                    .labelsHidden()

                    Button {
                        state.date = state.date.addingTimeInterval(
                            15.minutes.timeInterval
                        )
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .tint(.blue)
                    .buttonStyle(.borderless)
                }
            }
        }

        private var savePresetButton: some View {
            Button {
                saveAsPreset()
            } label: {
                Text("Save as preset")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .listRowBackground(Color(.systemGroupedBackground))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }

        // MARK: - Hypo Section

        private var hypoTreatmentSection: some View {
            Section {
                Button {
                    state.hypoTreatment = true

                    button.toggle()

                    if button {
                        state.add(override, fetch: editMode)
                    }

                } label: {
                    Text("Hypo Treatment")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color(.orange).opacity(0.9))
            .tint(.white)
        }

        // MARK: - Continue Section

        private var continueSection: some View {
            Section {
                Button {
                    button.toggle()

                    if button {
                        state.add(override, fetch: editMode)
                    }

                } label: {
                    Text(
                        (
                            (state.skipBolus && !override && !editMode)
                                || state.carbs <= 0
                        )
                            ? "Save"
                            : "Continue"
                    )
                }
                .disabled(empty)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(
                !empty
                    ? Color(.systemBlue)
                    : Color(.systemGray4)
            )
            .tint(.white)
        }

        private struct OtherNutritionSheet: View {
            @Binding var fiber: Decimal
            @Binding var note: String
            @Binding var micronutrients: [MicronutrientValue]

            let formatter: NumberFormatter

            @Environment(\.dismiss) private var dismiss

            var body: some View {
                NavigationStack {
                    Form {
                        Section("Note") {
                            TextField("Meal", text: $note)
                        }

                        Section("Fiber") {
                            HStack {
                                Text("Fiber")

                                Spacer()

                                DecimalTextField(
                                    "0",
                                    value: $fiber,
                                    formatter: formatter,
                                    autofocus: false,
                                    liveEditing: true
                                )

                                Text("g")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        MicronutrientSection(
                            values: $micronutrients,
                            formatter: formatter
                        )
                    }
                    .navigationTitle("Other")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Micronutrient Section

        private struct MicronutrientSection: View {
            @Binding var values: [MicronutrientValue]

            let formatter: NumberFormatter

            @State private var selected = MicroNutrient.allCases.first!
            @State private var amount: Decimal = 0

            private var sortedNutrients: [MicroNutrient] {
                MicroNutrient.allCases.sorted {
                    $0.displayName < $1.displayName
                }
            }

            var body: some View {
                Section("Micronutrients") {
                    Picker("Nutrient", selection: $selected) {
                        ForEach(sortedNutrients, id: \.self) { nutrient in

                            Text(nutrient.displayName)
                                .tag(nutrient)
                        }
                    }

                    HStack {
                        Text("Amount")

                        Spacer()

                        DecimalTextField(
                            "0",
                            value: $amount,
                            formatter: formatter,
                            autofocus: false,
                            liveEditing: true
                        )

                        Text(selected.unit)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        addOrUpdate()

                    } label: {
                        Text("Add Micronutrient")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(amount <= 0)
                }

                if !values.isEmpty {
                    Section("Added") {
                        ForEach(
                            values.sorted { $0.name < $1.name }
                        ) { value in

                            HStack {
                                VStack(
                                    alignment: .leading,
                                    spacing: 2
                                ) {
                                    Text(value.name)

                                    Text(
                                        value.substance.coreDataType
                                            .capitalized
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(value.formattedAmount)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }

            private func addOrUpdate() {
                var dict = Dictionary(
                    uniqueKeysWithValues: values.map {
                        ($0.substance, $0)
                    }
                )

                dict[selected] = MicronutrientValue(
                    substance: selected,
                    amount: amount,
                    amountPer100: 0
                )

                values = dict.values
                    .filter {
                        $0.amount > 0 || $0.amountPer100 > 0
                    }
                    .sorted {
                        $0.name < $1.name
                    }

                amount = 0
            }

            private func delete(at offsets: IndexSet) {
                let sortedValues = values.sorted {
                    $0.name < $1.name
                }

                let substancesToDelete = offsets.map {
                    sortedValues[$0].substance
                }

                values.removeAll {
                    substancesToDelete.contains($0.substance)
                }
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                Text("Fat").foregroundColor(.blue)
                Spacer()
                DecimalTextField(
                    "0",
                    value: $state.fat,
                    formatter: Self.formatter,
                    autofocus: false,
                    liveEditing: true
                )
                Text("grams").foregroundColor(.secondary)
            }
            HStack {
                Text("Protein").foregroundColor(.green)
                Spacer()
                DecimalTextField(
                    "0",
                    value: $state.protein,
                    formatter: Self.formatter,
                    autofocus: false,
                    liveEditing: true
                )
                Text("grams").foregroundColor(.secondary)
            }
        }

        private var otherSummary: some View {
            let hasFiber = state.fiber > 0
            let microCount = state.micronutrient.count

            return Text(summaryText(hasFiber: hasFiber, microCount: microCount))
        }

        private func summaryText(
            hasFiber: Bool,
            microCount: Int
        ) -> String {
            switch (hasFiber, microCount > 0) {
            case (false, false):
                return state.note

            case (true, false):
                return "Fiber"

            case (false, true):
                return "\(microCount) micros"

            case (true, true):
                return "Fiber • \(microCount)"
            }
        }

        @ViewBuilder private func macroRow(
            title: LocalizedStringKey,
            value: Binding<Decimal>,
            color: Color,
            bold: Bool = false
        ) -> some View {
            HStack {
                Text(title)
                    .foregroundStyle(color)
                    .fontWeight(bold ? .semibold : .regular)

                Spacer()

                DecimalTextField(
                    "0",
                    value: value,
                    formatter: Self.formatter,
                    autofocus: false,
                    liveEditing: true
                )

                Text("grams")
                    .foregroundStyle(.secondary)
            }
        }

        // MARK: - Helper Functions

        private var meal: Bool {
            mode == .meal
        }

        private var hasUnsavedFoodSearchResults: Bool {
            foodSearchState.showingFoodSearch && foodSearchState.searchResultsState.nonDeletedItems.isNotEmpty
        }

        // Opens an edit-and-save View
        private func saveAsPreset() {
            foodSearchState.newFoodEntryToEdit = FoodItemDetailed(
                name: "New",
                nutrition: .perServing(
                    values: [
                        .carbs: state.carbs,
                        .protein: state.protein,
                        .fat: state.fat,
                        .fiber: state.fiber
                    ],
                    servingsMultiplier: 1.0
                ),
                micronutrient: state.micronutrient,
                source: .manual
            )

            foodSearchState.showNewSavedFoodEntry = true
            saved.toggle()
        }

        private func handleFoodContinue(_ food: FoodItemDetailed, _: UIImage?, date: Date?) {
            button.toggle()
            guard button else { return }

            state.hypoTreatment = false
            state.addAIFood(override, fetch: editMode, food: food, date: date)
        }

        private func handleOnAppear() {
            syncDismissState()

            state.loadEntries(editMode)
            addMissingFoodIDs()
            updateSavedFoods()

            guard !meal else { return }

            switch mode {
            case .image:
                if state.ai {
                    showFoodSearch(.camera)
                }
            case .barcode:
                showFoodSearch(.barcodeScanner)
            case .presets:
                foodSearchState.showingFoodSearch = true
                foodSearchState.showSavedFoods = true
            default:
                break
            }
        }

        private func syncDismissState() {
            mainState.shouldPreventModalDismiss = shouldPreventDismiss
        }

        private func showFoodSearch(_ route: FoodSearchRoute) {
            foodSearchState.foodSearchRoute = route
            foodSearchState.showingFoodSearch = true
        }

        // Transform Presets to FoodItemDetailed
        private func transformPresetsToFoodItems(_ presets: FetchedResults<Presets>) -> [FoodItemDetailed] {
            presets.compactMap { preset -> FoodItemDetailed? in
                FoodItemDetailed.fromPreset(preset: preset)
            }
        }

        private func addMissingFoodIDs() {
            let noId = carbPresets.filter { $0.foodID == nil }
            if noId.isNotEmpty {
                for preset in noId {
                    preset.foodID = UUID()
                }
                do {
                    try moc.save()
                } catch {
                    print("Couldn't save presets after adding IDs: \(error.localizedDescription)")
                }
            }
        }

        // Update savedFoods when presets change
        private func updateSavedFoods() {
            let foodItems = transformPresetsToFoodItems(carbPresets)
            foodSearchState.savedFoods = FoodItemGroup(
                foodItems: foodItems,
                briefDescription: nil,
                overallDescription: nil,
                diabetesConsiderations: nil,
                source: .database,
                barcode: nil,
                textQuery: nil
            )
        }

        // MARK: - Food Search Section

        private func saveOrUpdatePreset(_ food: FoodItemDetailed) {
            guard food.name.isNotEmpty else { return }

            let existingPreset = carbPresets.first(where: { preset in
                preset.foodID == food.id
            })

            let preset = existingPreset ?? Presets(context: moc)

            food.updatePreset(preset: preset)

            do {
                try moc.save()
                updateSavedFoods()
            } catch {
                print("Couldn't save " + (preset.dish ?? "new preset."))
            }
        }

        private func deletePreset(_ food: FoodItemDetailed) {
            // Find preset by food ID
            if let presetToDelete = carbPresets.first(where: { preset in
                preset.foodID == food.id
            }) {
                moc.delete(presetToDelete)
                do {
                    try moc.save()
                } catch {
                    debug(.apsManager, "Couldn't delete meal preset for food: \(food.name).")
                }
            }
        }

        private var empty: Bool {
            state.carbs <= 0 &&
                state.fat <= 0 &&
                state.protein <= 0 &&
                state.fiber <= 0 &&
                state.micronutrient.allSatisfy { $0.amount <= 0 }
        }

        private var presetView: some View {
            Form {
                Section {} header: { back }

                if !empty {
                    Section {
                        Button {
                            addfromCarbsView()
                        }
                        label: {
                            HStack {
                                Text("Save as Preset")
                                Spacer()
                                Text(
                                    "[Carbs: \(format(state.carbs)), Fat: \(format(state.fat)), Protein: \(format(state.protein))]"
                                )
                            }
                        }.frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color(.systemBlue)).tint(.white)
                    }
                    header: { Text("Save") }
                }

                let filtered = carbPresets.filter { !($0.dish ?? "").isEmpty && ($0.dish ?? "Empty") != "Empty" }
                    .removeDublicates()
                if filtered.count > 4 {
                    Section {
                        TextField("Search", text: $string)
                    } header: { Text("Search") }
                }
                let data = string.isEmpty ? filtered : carbPresets
                    .filter { ($0.dish ?? "").localizedCaseInsensitiveContains(string) }

                Section {
                    ForEach(data, id: \.self) { preset in
                        presetsList(for: preset)
                    }.onDelete(perform: delete)
                } header: {
                    HStack {
                        Text("Saved Food")
                        Button {
                            state.presetToEdit = Presets(context: moc)
                            newPreset = (NSLocalizedString("New", comment: ""), 0, 0, 0, 0, [])
                            state.edit = true
                        } label: { Image(systemName: "plus").font(.system(size: 22)) }
                            .buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .sheet(isPresented: $state.edit, content: { editView })
            .environment(\.colorScheme, colorScheme)
        }

        private var back: some View {
            Button { reset() }
            label: { Image(systemName: "chevron.backward").font(.system(size: 22)).padding(5) }
                .foregroundStyle(.primary)
                .buttonBorderShape(.circle)
                .buttonStyle(.borderedProminent)
                .tint(colorScheme == .light ? Color.white.opacity(0.5) : Color(.systemGray5))
                .offset(x: -10)
        }

        @ViewBuilder private func presetsList(for preset: Presets) -> some View {
            let dish = preset.dish ?? ""

            if !preset.hasChanges {
                HStack {
                    VStack(alignment: .leading) {
                        Text(dish)
                        HStack {
                            Text("Carbs")
                            Text("\(preset.carbs ?? 0)")
                            Spacer()
                            Text("Fat")
                            Text("\(preset.fat ?? 0)")
                            Spacer()
                            Text("Protein")
                            Text("\(preset.protein ?? 0)")
                        }.foregroundStyle(.secondary).font(.caption).padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selection = preset
                        state.addU(state.selection)
                        reset()
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            state.edit = true
                            state.presetToEdit = preset
                            update()
                        } label: {
                            Label("Edit", systemImage: "pencil.line")
                        }
                    }
                }
            }
        }

        private func delete(at offsets: IndexSet) {
            for index in offsets {
                let preset = carbPresets[index]
                moc.delete(preset)
            }
            do {
                try moc.save()
            } catch {
                debug(.apsManager, "Couldn't delete meal preset at \(offsets).")
            }
        }

        private func save() {
            if let preset = state.presetToEdit {
                preset.dish = newPreset.dish
                preset.carbs = newPreset.carbs as NSDecimalNumber
                preset.fat = newPreset.fat as NSDecimalNumber
                preset.protein = newPreset.protein as NSDecimalNumber
                preset.fiber = newPreset.fiber as NSDecimalNumber

                try? preset.replaceMicronutrients(
                    with: newPreset.micronutrient.map {
                        (
                            name: $0.substance.coreDataName,
                            type: $0.substance.coreDataType,
                            unit: $0.substance.unit,
                            amount: $0.amount,
                            per100: false
                        )
                    },
                    context: moc
                )

            } else if !disabled {
                let preset = Presets(context: moc)
                preset.foodID = UUID()
                preset.carbs = newPreset.carbs as NSDecimalNumber
                preset.fat = newPreset.fat as NSDecimalNumber
                preset.protein = newPreset.protein as NSDecimalNumber
                preset.fiber = newPreset.fiber as NSDecimalNumber
                preset.dish = newPreset.dish
                preset.per100 = false

                try? preset.replaceMicronutrients(
                    with: newPreset.micronutrient.map {
                        (
                            name: $0.substance.coreDataName,
                            type: $0.substance.coreDataType,
                            unit: $0.substance.unit,
                            amount: $0.amount,
                            per100: false
                        )
                    },
                    context: moc
                )
            }

            if moc.hasChanges {
                do {
                    try moc.save()
                } catch {
                    debug(.apsManager, "Failed to save \(moc.updatedObjects)")
                }
            }

            state.edit = false
            isPromptPresented.toggle()
        }

        private func update() {
            newPreset.dish = state.presetToEdit?.dish ?? ""
            newPreset.carbs = (state.presetToEdit?.carbs ?? 0) as Decimal
            newPreset.fat = (state.presetToEdit?.fat ?? 0) as Decimal
            newPreset.protein = (state.presetToEdit?.protein ?? 0) as Decimal
            newPreset.fiber = (state.presetToEdit?.fiber ?? 0) as Decimal
            newPreset.micronutrient = state.presetToEdit?.micronutrientValuesTyped() ?? []
        }

        private func addfromCarbsView() {
            newPreset = (
                state.note,
                state.carbs.rounded(to: 1),
                state.fat.rounded(to: 1),
                state.protein.rounded(to: 1),
                state.fiber.rounded(to: 1),
                state.micronutrient
            )

            state.edit = true
        }

        private func reset() {
            presentPresets = false
            string = ""
        }

        private var disabled: Bool {
            let isDefaultName = newPreset.dish == NSLocalizedString("New", comment: "")
            let hasNoMacros = newPreset.carbs + newPreset.fat + newPreset.protein <= 0
            let hasNoMicros = newPreset.micronutrient.isEmpty

            return newPreset.dish.isEmpty || (isDefaultName && hasNoMacros && hasNoMicros)
        }

        /// Determines if the view should prevent interactive dismissal (swipe down)
        private var shouldPreventDismiss: Bool {
            // Prevent dismiss if showing saved foods OR if there are unsaved changes
            if foodSearchState.showSavedFoods {
                return true // Block swipe when saved foods are shown
            } else if hasUnsavedFoodSearchResults {
                return true // Block swipe when there are unsaved food search results
            } else {
                return false // Allow swipe in other cases
            }
        }

        /// Handles the dismiss action from the Cancel/Done button
        private func handleDismissAction() {
            // If showing saved foods, just close them
            if foodSearchState.showSavedFoods {
                withAnimation(.easeInOut(duration: 0.3)) {
                    foodSearchState.showSavedFoods = false
                }
                return
            }

            // If there are unsaved food search results, show confirmation
            if hasUnsavedFoodSearchResults {
                showCancelConfirmation = true
                return
            }

            // Otherwise, just dismiss
            state.hideModal()
            if editMode { state.apsManager.determineBasalSync() }
        }

        private var editView: some View {
            Form {
                Section {
                    HStack {
                        TextField("", text: $newPreset.dish)
                    }
                    HStack {
                        Text("Carbs").foregroundStyle(.secondary)
                        Spacer()
                        DecimalTextField("0", value: $newPreset.carbs, formatter: Self.formatter, liveEditing: true)
                    }
                    HStack {
                        Text("Fat").foregroundStyle(.secondary)
                        Spacer()
                        DecimalTextField("0", value: $newPreset.fat, formatter: Self.formatter, liveEditing: true)
                    }
                    HStack {
                        Text("Protein").foregroundStyle(.secondary)
                        Spacer()
                        DecimalTextField("0", value: $newPreset.protein, formatter: Self.formatter, liveEditing: true)
                    }
                } header: { Text("Saved Food") }

                Section {
                    Button { save() }
                    label: { Text("Save") }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(!disabled ? Color(.systemBlue) : Color(.systemGray4))
                        .tint(.white)
                        .disabled(disabled)
                }
            }.environment(\.colorScheme, colorScheme)
        }

        /// Triggers the FDDB import flow: downloads the share page, parses it, and opens the Saved Food editor prefilled.
        private func performFddbImport() {
            let trimmed = fddbURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                fddbErrorMessage = NSLocalizedString("Bitte eine gültige FDDB-Share-URL eingeben.", comment: "")
                return
            }

            fddbIsImporting = true
            fddbErrorMessage = nil

            Task {
                do {
                    // 1) Load + parse the FDDB share page
                    let result = try await FddbExtenderImporter.importFrom(urlString: trimmed)

                    // 2) Map to the app's FoodItemDetailed structure
                    var values: [NutrientType: Decimal] = [:]
                    if let c = result.carbs { values[.carbs] = max(0, c) }
                    if let p = result.protein { values[.protein] = max(0, p) }
                    if let f = result.fat { values[.fat] = max(0, f) }
                    if let fi = result.fiber { values[.fiber] = max(0, fi) }
                    if let su = result.sugars { values[.sugars] = max(0, su) }

                    // Standard serving (if detected)
                    let standardSize = result.standardServingSize
                    let units: MealUnits? = {
                        switch result.standardServingUnit {
                        case .grams?: return .grams
                        case .milliliters?: return .milliliters
                        case nil: return nil
                        }
                    }()

                    let importedItem: FoodItemDetailed
                    switch result.mode {
                    case .perServing:
                        importedItem = FoodItemDetailed(
                            name: result.name,
                            nutrition: .perServing(values: values, servingsMultiplier: 1),
                            standardServingSize: standardSize,
                            units: units ?? .grams,
                            source: .manual
                        )

                    case let .per100(unit):
                        // If only per-100 is available, prefill the editor in per-100 mode.
                        // Portion size defaults to 100 of the detected unit unless we have a clear standard serving size.
                        let portionSize = standardSize ?? 100
                        let portionUnits: MealUnits = (unit == .milliliters) ? .milliliters : .grams
                        importedItem = FoodItemDetailed(
                            name: result.name,
                            nutrition: .per100(values: values, portionSize: portionSize),
                            standardServingSize: standardSize,
                            units: portionUnits,
                            source: .manual
                        )
                    }

                    // Show a short info banner about the detected mode before opening the editor
                    let modeInfo: String = {
                        switch result.mode {
                        case .perServing:
                            return NSLocalizedString("Erkannt: pro Portion", comment: "")
                        case let .per100(unit):
                            return unit == .milliliters ? NSLocalizedString("Erkannt: pro 100 ml", comment: "") :
                                NSLocalizedString("Erkannt: pro 100 g", comment: "")
                        }
                    }()

                    await MainActor.run { fddbImportInfo = modeInfo }
                    try? await Task.sleep(nanoseconds: 700_000_000)

                    await MainActor.run {
                        // Close the import sheet first
                        showFddbImportSheet = false
                        fddbIsImporting = false

                        // Open the Saved Food editor with prefilled values
                        foodSearchState.newFoodEntryToEdit = importedItem
                        foodSearchState.showNewSavedFoodEntry = true

                        // Reset the form
                        fddbURLString = ""
                        fddbErrorMessage = nil
                        fddbImportInfo = nil
                    }
                } catch {
                    await MainActor.run {
                        fddbIsImporting = false
                        fddbErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
    }

    private struct MicronutrientEntrySheet: View {
        @Binding var values: [MicronutrientValue]

        let formatter: NumberFormatter

        @Environment(\.dismiss) private var dismiss

        @State private var selected = MicroNutrient.allCases.first!
        @State private var amount: Decimal = 0

        private var sortedNutrients: [MicroNutrient] {
            MicroNutrient.allCases.sorted { $0.displayName < $1.displayName }
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Picker("Nutrient", selection: $selected) {
                            ForEach(sortedNutrients, id: \.self) { nutrient in
                                Text(nutrient.displayName)
                                    .tag(nutrient)
                            }
                        }

                        HStack {
                            Text("Amount")
                            Spacer()

                            DecimalTextField(
                                "0",
                                value: $amount,
                                formatter: formatter,
                                autofocus: false,
                                liveEditing: true
                            )

                            Text(selected.unit)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            addOrUpdate()
                        } label: {
                            Text("Add Micronutrient")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .disabled(amount <= 0)
                    }

                    if !values.isEmpty {
                        Section("Added") {
                            ForEach(values.sorted { $0.name < $1.name }) { value in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(value.name)
                                        Text(value.substance.coreDataType.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(value.formattedAmount)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .onDelete(perform: delete)
                        }
                    }
                }
                .navigationTitle("Micronutrients")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }

        private func addOrUpdate() {
            var dict = Dictionary(
                uniqueKeysWithValues: values.map { ($0.substance, $0) }
            )

            dict[selected] = MicronutrientValue(
                substance: selected,
                amount: amount,
                amountPer100: 0
            )

            values = dict.values
                .filter { $0.amount > 0 || $0.amountPer100 > 0 }
                .sorted { $0.name < $1.name }

            amount = 0
        }

        private func delete(at offsets: IndexSet) {
            let sortedValues = values.sorted { $0.name < $1.name }
            let substancesToDelete = offsets.map { sortedValues[$0].substance }

            values.removeAll { substancesToDelete.contains($0.substance) }
        }
    }
}
