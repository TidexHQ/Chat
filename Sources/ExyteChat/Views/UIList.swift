//
//  UIList.swift
//
//
//  Created by Alisa Mylnikova on 24.02.2023.
//

import SwiftUI

public extension Notification.Name {
    static let onScrollToBottom = Notification.Name("onScrollToBottom")
}

struct UIList<MessageContent: View>: UIViewRepresentable {

    typealias MessageBuilderParamsClosure = ChatView<MessageContent, InputView, DefaultMessageMenuAction>.MessageBuilderParamsClosure

    @Environment(\.chatTheme) var theme

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var inputViewModel: InputViewModel

    @Binding var isScrolledToBottom: Bool
    @Binding var shouldScrollToTop: () -> ()
    @Binding var tableContentHeight: CGFloat

    // MARK: - View builders

    let messageBuilder: MessageBuilderParamsClosure
    let mainHeaderBuilder: (()->AnyView)?
    let headerBuilder: ((Date)->AnyView)?

    // MARK: - Data / type

    let type: ChatType
    let bottomOverlayHeight: CGFloat
    let sections: [MessagesSection]
    let ids: [String]

    // MARK: - Customization

    let chatParams: ChatCustomizationParameters
    let messageParams: MessageCustomizationParameters
    @Binding var timeViewWidth: CGFloat

    // MARK: - State

    @State private var isScrolledToTop = false
    @State private var updateQueue = UpdateQueue()
    @State private var transaction = TableUpdateTransaction()

    func makeUIView(context: Context) -> UITableView {
        let style = mainHeaderBuilder != nil || chatParams.showDateHeaders ? UITableView.Style.grouped : .plain
        let tableView = UITableView(frame: .zero, style: style)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.transform = CGAffineTransform(rotationAngle: (type == .conversation ? .pi : 0))

        tableView.showsVerticalScrollIndicator = false
        tableView.estimatedSectionHeaderHeight = 1
        tableView.estimatedSectionFooterHeight = UITableView.automaticDimension
        tableView.backgroundColor = UIColor(theme.colors.mainBG)
        tableView.scrollsToTop = false
        tableView.isScrollEnabled = chatParams.isScrollEnabled
        tableView.keyboardDismissMode = chatParams.keyboardDismissMode
        updateInsets(for: tableView)

        NotificationCenter.default.addObserver(forName: .onScrollToBottom, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                if !context.coordinator.sections.isEmpty {
                    scrollToBottom(tableView, animated: true)
                }
            }
        }

        DispatchQueue.main.async {
            shouldScrollToTop = {
                tableView.setContentOffset(CGPoint(x: 0, y: tableView.contentSize.height - tableView.frame.height), animated: false)
            }
        }

        transaction.updateQueue = updateQueue
        chatParams.onTransactionReady?(transaction)

        return tableView
    }

    private func scrollToBottom(_ tableView: UITableView, animated: Bool) {
        guard tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 else { return }

        let scrollPosition: UITableView.ScrollPosition = (type == .conversation) ? .top : .bottom
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: scrollPosition, animated: animated)
    }

    private func resolvedContentInsets() -> UIEdgeInsets {
        var insets = chatParams.contentInsets
        let overlayHeight = max(bottomOverlayHeight, 0)

        switch type {
        case .conversation:
            insets.top += overlayHeight
        case .comments:
            insets.bottom += overlayHeight
        }

        return insets
    }

    private func updateInsets(for tableView: UITableView) {
        let insets = resolvedContentInsets()

        guard tableView.contentInset != insets || tableView.scrollIndicatorInsets != insets else { return }

        let shouldMaintainLiveEdge = type == .conversation && isScrolledToBottom

        tableView.contentInset = insets
        tableView.scrollIndicatorInsets = insets

        if shouldMaintainLiveEdge {
            if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
                scrollToBottom(tableView, animated: false)
            } else {
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: -insets.top),
                    animated: false
                )
            }
        }
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        if tableView.isScrollEnabled != chatParams.isScrollEnabled {
            tableView.isScrollEnabled = chatParams.isScrollEnabled
        }
        if tableView.keyboardDismissMode != chatParams.keyboardDismissMode {
            tableView.keyboardDismissMode = chatParams.keyboardDismissMode
        }

        updateInsets(for: tableView)

        if !chatParams.isScrollEnabled {
            DispatchQueue.main.async {
                tableContentHeight = tableView.contentSize.height
            }
        }

        if context.coordinator.sections != sections || tableView.contentOffset != chatParams.externalContentOffset, chatParams.scrollToMessageID != nil {
            updateQueue.didPerformRealUpdate = true
        }

        let needToScroll = chatParams.externalContentOffset != nil || chatParams.scrollToMessageID != nil
        let animateTableUpdate = transaction.animated && !needToScroll

        Task {
            await updateQueue.enqueue {
                if context.coordinator.sections != sections {
                    await updateIfNeeded(coordinator: context.coordinator, tableView: tableView, animated: animateTableUpdate)
                }

                if needToScroll {
                    await withCheckedContinuation { continuation in
                        UIView.animate(withDuration: transaction.animated ? 0.25 : 0) {
                            if let offset = chatParams.externalContentOffset, tableView.contentOffset != offset {
                                tableView.setContentOffset(offset, animated: false)
                            } else if let messageID = chatParams.scrollToMessageID, let indexPath = indexPath(for: messageID, in: sections) {
                                tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                            }
                        } completion: { _ in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    func indexPath(for id: String, in sections: [MessagesSection]) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() {
            if let rowIndex = section.rows.firstIndex(where: { $0.message.id == id }) {
                return IndexPath(row: rowIndex, section: sectionIndex)
            }
        }
        return nil
    }

    @MainActor
    private func updateIfNeeded(coordinator: Coordinator, tableView: UITableView, animated: Bool) async {
        if coordinator.sections == sections {
            return
        }

        if coordinator.sections.isEmpty {
            coordinator.sections = sections

            tableView.reloadData()

            if type == .conversation, isScrolledToBottom {
                scrollToBottom(tableView, animated: false)
            }
            if !chatParams.isScrollEnabled {
                DispatchQueue.main.async {
                    tableContentHeight = tableView.contentSize.height
                }
            }

            return
        }

        if let lastSection = sections.last, let paginationHandler = chatParams.paginationHandler {
            coordinator.paginationTargetIndexPath = IndexPath(row: lastSection.rows.count - 1 - paginationHandler.offset, section: sections.count - 1)
        }

        let prevSections = coordinator.sections
        let splitInfo = await performSplitInBackground(prevSections, sections)
        await applyUpdatesToTable(tableView, splitInfo: splitInfo, animated: animated) {
            coordinator.sections = $0
        }
    }

    nonisolated private func performSplitInBackground(_ prevSections: [MessagesSection], _ sections: [MessagesSection]) async -> SplitInfo {
        await withCheckedContinuation { continuation in
            Task.detached {
                let result = operationsSplit(oldSections: prevSections, newSections: sections)
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    private func applyUpdatesToTable(_ tableView: UITableView, splitInfo: SplitInfo, animated: Bool, updateContextClosure: ([MessagesSection])->()) async {
        if shouldFallbackToFullReload(splitInfo: splitInfo) {
            updateContextClosure(sections)
            UIView.performWithoutAnimation {
                tableView.reloadData()
                tableView.layoutIfNeeded()
            }

            if type == .conversation, isScrolledToBottom {
                scrollToBottom(tableView, animated: false)
            }
            if !chatParams.isScrollEnabled {
                tableContentHeight = tableView.contentSize.height
            }
            return
        }

        await performBatchTableUpdates(tableView) {
            updateContextClosure(splitInfo.appliedDeletes)
            for operation in splitInfo.deleteOperations {
                applyOperation(operation, tableView: tableView)
            }
        }

        await performBatchTableUpdates(tableView) {
            updateContextClosure(splitInfo.appliedDeletesSwapsAndEdits)
            for operation in splitInfo.swapOperations {
                applyOperation(operation, tableView: tableView)
            }
        }

        UIView.setAnimationsEnabled(false)
        await performBatchTableUpdates(tableView) {
            updateContextClosure(splitInfo.appliedDeletesSwapsAndEdits)

            for operation in splitInfo.editOperations {
                applyOperation(operation, tableView: tableView)
            }
        }
        UIView.setAnimationsEnabled(true)

        updateContextClosure(sections)

        if animated, isScrolledToBottom || isScrolledToTop {
            await performBatchTableUpdates(tableView) {
                for operation in splitInfo.insertOperations {
                    applyOperation(operation, tableView: tableView)
                }
            }
        } else {
            UIView.setAnimationsEnabled(false)
            for operation in splitInfo.insertOperations {
                applyOperation(operation, tableView: tableView)
            }
            UIView.setAnimationsEnabled(true)
        }

        if type == .conversation && isScrolledToBottom {
            scrollToBottom(tableView, animated: false)
        }
        if !chatParams.isScrollEnabled {
            tableContentHeight = tableView.contentSize.height
        }
    }

    private func shouldFallbackToFullReload(splitInfo: SplitInfo) -> Bool {
        let hasSectionOperations =
            splitInfo.deleteOperations.contains(where: isSectionOperation)
            || splitInfo.insertOperations.contains(where: isSectionOperation)

        if hasSectionOperations {
            return true
        }

        // Diff-based row inserts are only stable at the live edges in this inverted table setup.
        if !splitInfo.insertOperations.isEmpty && !(isScrolledToBottom || isScrolledToTop) {
            return true
        }

        return false
    }

    private func isSectionOperation(_ operation: Operation) -> Bool {
        switch operation {
        case .deleteSection, .insertSection:
            return true
        case .delete, .insert, .swap, .edit:
            return false
        }
    }

    // MARK: - Operations

    enum Operation {
        case deleteSection(Int)
        case insertSection(Int)

        case delete(Int, Int) // delete with animation
        case insert(Int, Int) // insert with animation
        case swap(Int, Int, Int) // delete first with animation, then insert it into new position with animation. do not do anything with the second for now
        case edit(Int, Int) // reload the element without animation

        var description: String {
            switch self {
            case .deleteSection(let int):
                return "deleteSection \(int)"
            case .insertSection(let int):
                return "insertSection \(int)"
            case .delete(let int, let int2):
                return "delete section \(int) row \(int2)"
            case .insert(let int, let int2):
                return "insert section \(int) row \(int2)"
            case .swap(let int, let int2, let int3):
                return "swap section \(int) rowFrom \(int2) rowTo \(int3)"
            case .edit(let int, let int2):
                return "edit section \(int) row \(int2)"
            }
        }
    }

    func applyOperation(_ operation: Operation, tableView: UITableView) {
        let animation: UITableView.RowAnimation = .top
        switch operation {
        case .deleteSection(let section):
            tableView.deleteSections([section], with: animation)
        case .insertSection(let section):
            tableView.insertSections([section], with: animation)
        case .delete(let section, let row):
            tableView.deleteRows(at: [IndexPath(row: row, section: section)], with: animation)
        case .insert(let section, let row):
            tableView.insertRows(at: [IndexPath(row: row, section: section)], with: animation)
        case .edit(let section, let row):
            tableView.reconfigureRows(at: [IndexPath(row: row, section: section)])
        case .swap(let section, let rowFrom, let rowTo):
            tableView.deleteRows(at: [IndexPath(row: rowFrom, section: section)], with: animation)
            tableView.insertRows(at: [IndexPath(row: rowTo, section: section)], with: animation)
        }
    }

    private nonisolated func operationsSplit(oldSections: [MessagesSection], newSections: [MessagesSection]) -> SplitInfo {
        var appliedDeletes = oldSections
        var appliedDeletesSwapsAndEdits = newSections

        var deleteOperations = [Operation]()
        var swapOperations = [Operation]()
        var editOperations = [Operation]()
        var insertOperations = [Operation]()

        let oldDates = oldSections.map { $0.date }
        let newDates = newSections.map { $0.date }
        let commonDates = Array(Set(oldDates + newDates)).sorted(by: >)
        for date in commonDates {
            let oldIndex = appliedDeletes.firstIndex(where: { $0.date == date } )
            let newIndex = appliedDeletesSwapsAndEdits.firstIndex(where: { $0.date == date } )
            if oldIndex == nil, let newIndex {
                if let operationIndex = newSections.firstIndex(where: { $0.date == date } ) {
                    appliedDeletesSwapsAndEdits.remove(at: newIndex)
                    insertOperations.append(.insertSection(operationIndex))
                }
                continue
            }
            if newIndex == nil, let oldIndex {
                if let operationIndex = oldSections.firstIndex(where: { $0.date == date } ) {
                    appliedDeletes.remove(at: oldIndex)
                    deleteOperations.append(.deleteSection(operationIndex))
                }
                continue
            }
            guard let newIndex, let oldIndex else { continue }

            var oldRows = appliedDeletes[oldIndex].rows
            var newRows = appliedDeletesSwapsAndEdits[newIndex].rows
            let oldRowIDs = oldRows.map { $0.id }
            let newRowIDs = newRows.map { $0.id }
            let rowIDsToDelete = oldRowIDs.filter { !newRowIDs.contains($0) }.reversed()
            let rowIDsToInsert = newRowIDs.filter { !oldRowIDs.contains($0) }
            for rowId in rowIDsToDelete {
                if let index = oldRows.firstIndex(where: { $0.id == rowId }) {
                    oldRows.remove(at: index)
                    deleteOperations.append(.delete(oldIndex, index))
                }
            }
            for rowId in rowIDsToInsert {
                if let index = newRows.firstIndex(where: { $0.id == rowId }) {
                    insertOperations.append(.insert(newIndex, index))
                }
            }

            for rowId in rowIDsToInsert {
                if let index = newRows.firstIndex(where: { $0.id == rowId }) {
                    newRows.remove(at: index)
                }
            }

            for i in 0..<oldRows.count {
                let oldRow = oldRows[i]
                let newRow = newRows[i]
                if oldRow.id != newRow.id {
                    if let index = newRows.firstIndex(where: { $0.id == oldRow.id }) {
                        if !swapsContain(swaps: swapOperations, section: oldIndex, index: i) ||
                            !swapsContain(swaps: swapOperations, section: oldIndex, index: index) {
                            swapOperations.append(.swap(oldIndex, i, index))
                        }
                    }
                } else if oldRow != newRow {
                    editOperations.append(.edit(oldIndex, i))
                }
            }

            appliedDeletes[oldIndex].rows = oldRows
            appliedDeletesSwapsAndEdits[newIndex].rows = newRows
        }

        return SplitInfo(
            appliedDeletes: appliedDeletes,
            appliedDeletesSwapsAndEdits: appliedDeletesSwapsAndEdits,
            deleteOperations: deleteOperations,
            swapOperations: swapOperations,
            editOperations: editOperations,
            insertOperations: insertOperations
        )
    }

    private nonisolated func swapsContain(swaps: [Operation], section: Int, index: Int) -> Bool {
        swaps.filter {
            if case let .swap(swapSection, rowFrom, rowTo) = $0 {
                return swapSection == section && (rowFrom == index || rowTo == index)
            }
            return false
        }.count > 0
    }

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            viewModel: viewModel,
            inputViewModel: inputViewModel,
            isScrolledToBottom: $isScrolledToBottom,
            isScrolledToTop: $isScrolledToTop,

            messageBuilder: messageBuilder,
            mainHeaderBuilder: mainHeaderBuilder,
            headerBuilder: headerBuilder,

            type: type,
            sections: sections,
            ids: ids,

            chatParams: chatParams,
            messageParams: messageParams,
            timeViewWidth: $timeViewWidth,
            mainBackgroundColor: theme.colors.mainBG
        )
    }

    class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {

        @ObservedObject var viewModel: ChatViewModel
        @ObservedObject var inputViewModel: InputViewModel

        @Binding var isScrolledToBottom: Bool
        @Binding var isScrolledToTop: Bool

        // MARK: - View builders

        let messageBuilder: MessageBuilderParamsClosure
        let mainHeaderBuilder: (()->AnyView)?
        let headerBuilder: ((Date)->AnyView)?

        // MARK: - Data / type

        let type: ChatType
        var sections: [MessagesSection] {
            didSet {
                if let lastSection = sections.last {
                    paginationTargetIndexPath = IndexPath(row: lastSection.rows.count - 1, section: sections.count - 1)
                }
            }
        }
        let ids: [String]

        // MARK: - Customization

        let chatParams: ChatCustomizationParameters
        let messageParams: MessageCustomizationParameters
        @Binding var timeViewWidth: CGFloat
        let mainBackgroundColor: Color

        /// call pagination handler when this row is reached
        /// without this there is a bug: during new cells insertion willDisplay is called one extra time for the cell which used to be the last one while it is being updated (its position in group is changed from first to middle)
        var paginationTargetIndexPath: IndexPath?

        private let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)

        init(
            viewModel: ChatViewModel,
            inputViewModel: InputViewModel,
            isScrolledToBottom: Binding<Bool>,
            isScrolledToTop: Binding<Bool>,

            messageBuilder: @escaping MessageBuilderParamsClosure,
            mainHeaderBuilder: (() -> AnyView)?,
            headerBuilder: ((Date) -> AnyView)?,

            type: ChatType,
            sections: [MessagesSection],
            ids: [String],

            chatParams: ChatCustomizationParameters,
            messageParams: MessageCustomizationParameters,
            timeViewWidth: Binding<CGFloat>,
            mainBackgroundColor: Color
        ) {
            self.viewModel = viewModel
            self.inputViewModel = inputViewModel
            self._isScrolledToBottom = isScrolledToBottom
            self._isScrolledToTop = isScrolledToTop

            self.messageBuilder = messageBuilder
            self.mainHeaderBuilder = mainHeaderBuilder
            self.headerBuilder = headerBuilder

            self.type = type
            self.sections = sections
            self.ids = ids

            self.chatParams = chatParams
            self.messageParams = messageParams
            self._timeViewWidth = timeViewWidth
            self.mainBackgroundColor = mainBackgroundColor
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            sections[section].rows.count
        }

        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            if type == .comments {
                return sectionHeaderView(section)
            }
            return nil
        }

        func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
            if type == .conversation {
                return sectionHeaderView(section)
            }
            return nil
        }

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            if !chatParams.showDateHeaders && (section != 0 || mainHeaderBuilder == nil) {
                return 0
            }
            return type == .conversation ? 0.1 : UITableView.automaticDimension
        }

        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            if !chatParams.showDateHeaders && (section != 0 || mainHeaderBuilder == nil) {
                return 0
            }
            return type == .conversation ? UITableView.automaticDimension : 0.1
        }

        func sectionHeaderView(_ section: Int) -> UIView? {
            if !chatParams.showDateHeaders && (section != 0 || mainHeaderBuilder == nil) {
                return nil
            }

            let header = UIHostingController(rootView:
                sectionHeaderViewBuilder(section)
                    .rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
            ).view
            header?.backgroundColor = UIColor(mainBackgroundColor)
            return header
        }

        @ViewBuilder
        func sectionHeaderViewBuilder(_ section: Int) -> some View {
            if let mainHeaderBuilder, section == 0 {
                VStack(spacing: 0) {
                    mainHeaderBuilder()
                    dateViewBuilder(section)
                }
            } else {
                dateViewBuilder(section)
            }
        }

        @ViewBuilder
        func dateViewBuilder(_ section: Int) -> some View {
            if chatParams.showDateHeaders {
                if let headerBuilder {
                    headerBuilder(sections[section].date)
                } else {
                    Text(sections[section].formattedDate)
                        .font(.system(size: 11))
                        .padding(.top, 30)
                        .padding(.bottom, 8)
                        .foregroundColor(.gray)
                }
            }
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let tableViewCell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            tableViewCell.selectionStyle = .none
            tableViewCell.backgroundColor = UIColor(mainBackgroundColor)

            let row = sections[indexPath.section].rows[indexPath.row]
            tableViewCell.contentConfiguration = UIHostingConfiguration {
                ChatMessageView(
                    viewModel: viewModel,
                    messageBuilder: messageBuilder,
                    row: row,
                    chatType: type,
                    messageParams: messageParams,
                    timeViewWidth: $timeViewWidth,
                    isDisplayingMessageMenu: false
                )
                .background(MessageMenuPreferenceViewSetter(id: row.id))
                .rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
                .applyIf(chatParams.showMessageMenuOnLongPress) {
                    $0.simultaneousGesture(
                        TapGesture().onEnded { }
                    )
                    .onLongPressGesture {
                        self.impactGenerator.impactOccurred()
                        self.viewModel.messageMenuRow = row
                    }
                }
            }
            .minSize(width: 0, height: 0)
            .margins(.all, 0)

            return tableViewCell
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            if let onWillDisplayCell = chatParams.onWillDisplayCell {
                onWillDisplayCell(sections[indexPath.section].rows[indexPath.row].message)
            }

            guard let paginationHandler = chatParams.paginationHandler, let paginationTargetIndexPath, indexPath == paginationTargetIndexPath else {
                return
            }

            paginationHandler.handleClosure()
        }

        func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let items = type == .conversation ? chatParams.listSwipeActions.trailing : chatParams.listSwipeActions.leading else { return nil }
            guard !items.actions.isEmpty else { return nil }
            let message = sections[indexPath.section].rows[indexPath.row].message
            let conf = UISwipeActionsConfiguration(actions: items.actions.filter({ $0.activeFor(message) }).map { toContextualAction($0, message: message) })
            conf.performsFirstActionWithFullSwipe = items.performsFirstActionWithFullSwipe
            return conf
        }

        func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let items = type == .conversation ? chatParams.listSwipeActions.leading : chatParams.listSwipeActions.trailing else { return nil }
            guard !items.actions.isEmpty else { return nil }
            let message = sections[indexPath.section].rows[indexPath.row].message
            let conf = UISwipeActionsConfiguration(actions: items.actions.filter({ $0.activeFor(message) }).map { toContextualAction($0, message: message) })
            conf.performsFirstActionWithFullSwipe = items.performsFirstActionWithFullSwipe
            return conf
        }

        private func toContextualAction(_ item: SwipeActionable, message: Message) -> UIContextualAction {
            let ca = UIContextualAction(style: .normal, title: nil) { (_, _, completionHandler) in
                item.action(message, self.viewModel.messageMenuAction())
                completionHandler(true)
            }
            ca.image = item.render(type: type)

            let bgColor = item.background ?? mainBackgroundColor
            ca.backgroundColor = UIColor(bgColor)

            return ca
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            chatParams.onContentOffsetChange?(scrollView.contentOffset)
            isScrolledToBottom = scrollView.contentOffset.y <= 0
            isScrolledToTop = scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.frame.height - 1
        }
    }

    func formatRow(_ row: MessageRow) -> String {
        String(
            "id: \(row.id) text: \(String(row.message.attributedText.characters)) status: \(row.message.status ?? .none) date: \(row.message.createdAt) position in user group: \(row.positionInUserGroup) position in messages section: \(row.positionInMessagesSection) trigger: \(row.message.triggerRedraw)"
        )
    }

    func formatSections(_ sections: [MessagesSection]) -> String {
        var res = "(\(sections.count))(\(sections.map{$0.rows.count})){\n"
        for section in sections.reversed() {
            res += String("\t{\n")
            for row in section.rows {
                res += String("\t\t\(formatRow(row))\n")
            }
            res += String("\t}\n")
        }
        res += String("}")
        return res
    }
}

extension UIList {
    struct SplitInfo: @unchecked Sendable {
        let appliedDeletes: [MessagesSection]
        let appliedDeletesSwapsAndEdits: [MessagesSection]
        let deleteOperations: [Operation]
        let swapOperations: [Operation]
        let editOperations: [Operation]
        let insertOperations: [Operation]
    }
}

actor UpdateQueue {
    var didPerformRealUpdate = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    private var isProcessing = false

    // MARK: - Transaction lifecycle

    func beginTransaction() {
        didPerformRealUpdate = false
    }

    func waitForTransactionToFinish() async {
        await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func finishIfNeeded() {
        guard let continuation = pendingContinuation else { return }

        if didPerformRealUpdate == false {
            pendingContinuation = nil
            continuation.resume()
        }
    }

    func finishBecauseRealUpdateHappened() {
        guard let continuation = pendingContinuation else { return }

        pendingContinuation = nil
        continuation.resume()
    }

    // MARK: - Enqueue

    func enqueue(_ work: @escaping () async -> Void) async {
        while isProcessing {
            await Task.yield()
        }

        isProcessing = true
        await work()
        isProcessing = false

        self.didPerformRealUpdate = true
        finishBecauseRealUpdateHappened()
    }
}

public final class TableUpdateTransaction {
    var updateQueue: UpdateQueue?
    var animated: Bool = true

    public func callAsFunction(animated: Bool = true, _ updates: @escaping () -> Void) async {
        self.animated = animated
        await updateQueue?.beginTransaction()

        await MainActor.run {
            updates()
        }

        DispatchQueue.main.async {
            Task {
                await self.updateQueue?.finishIfNeeded()
            }
        }

        await updateQueue?.waitForTransactionToFinish()
    }
}
