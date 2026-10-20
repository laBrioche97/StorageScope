import SwiftUI

struct ResultFilters: View {
    @EnvironmentObject private var model: AppModel
    var showsKind = true
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { sizePicker; if showsKind { kindPicker }; sortPicker; resetButton }
            VStack(alignment: .leading) { HStack { sizePicker; sortPicker }; HStack { if showsKind { kindPicker }; resetButton } }
        }
        .controlSize(.small)
    }
    private var sizePicker: some View {
        Picker("Taille minimale", selection: $model.sizeFilter) {
            ForEach(SizeFilter.allCases) { Text($0.label).tag($0) }
        }.frame(maxWidth: 190)
    }
    private var kindPicker: some View {
        Picker("Afficher", selection: $model.kindFilter) {
            ForEach(FileKindFilter.allCases) { Text($0.rawValue).tag($0) }
        }.frame(maxWidth: 225)
    }
    private var sortPicker: some View {
        Picker("Tri", selection: $model.sort) {
            ForEach([ItemSort.allocated, .smallest, .name], id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(maxWidth: 235)
    }
    private var resetButton: some View {
        Button("Réinitialiser") {
            model.searchText = ""; model.sizeFilter = .all; model.kindFilter = .all; model.categoryFilter = nil; model.sort = .allocated
        }
    }
}
