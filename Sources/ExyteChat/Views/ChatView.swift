//
//  ChatView.swift
//  Chat
//
//  Created by Alisa Mylnikova on 20.04.2022.
//

import SwiftUI
import ExyteMediaPicker

public typealias MediaPickerLiveCameraStyle = LiveCameraCellStyle
public typealias MediaPickerSelectionParameters = SelectionParameters

public enum ChatType: CaseIterable, Sendable {
    case conversation
    case comments
}

public enum ReplyMode: CaseIterable, Sendable {
    case quote
    case answer
}

public struct ChatView<MessageContent: View, InputViewContent: View, MenuAction: MessageMenuAction>: View {
    public typealias TapAvatarClosure = (User, String) -> ()

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatTheme) private var theme
    @Environment(\.giphyConfig) private var giphyConfig

    @ViewBuilder var messageBuilder: MessageBuilderParamsClosure
    @ViewBuilder var inputViewBuilder: InputViewBuilderParamsClosure
    var messageMenuAction: MessageMenuActionClosure

    var type: ChatType
    var sections: [MessagesSection]
    var ids: [String]
    var didSendMessage: (DraftMessage) async -> Bool
    var didUpdateAttachmentStatus: ((AttachmentUploadUpdate) -> Void)?

    var mainHeaderBuilder: (() -> AnyView)?
    var headerBuilder: ((Date) -> AnyView)?
    var betweenListAndInputViewBuilder: (() -> AnyView)?

    var chatCustomizationParameters = ChatCustomizationParameters()
    var messageCustomizationParameters = MessageCustomizationParameters()
    var inputViewCustomizationParameters = InputViewCustomizationParameters()

    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var inputViewModel = InputViewModel()
    @StateObject private var globalFocusState = GlobalFocusState()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var keyboardState = KeyboardState()

    @State private var isScrolledToBottom = true
    @State private var shouldScrollToTop: () -> Void = {}
    @State private var isShowingMenu = false
    @State private var tableContentHeight: CGFloat = 0
    @State private var inputViewSize = CGSize.zero
    @State private var timeViewSize = CGSize.zero
    @State private var bottomChromeSize = CGSize.zero
    @State private var cellFrames = [String: CGRect]()
    @State private var scrollToBottomRequestID = 0
    @State private var pendingScrollToBottomTask: Task<Void, Never>?

    public var body: some View {
        mainView
            .background(chatBackground())
            .environmentObject(keyboardState)
            .onChange(of: inputViewModel.text) { _, newValue in
                inputViewCustomizationParameters.onInputTextChange?(newValue)
            }
            .onChange(of: inputViewCustomizationParameters.externalInputText) {
                DispatchQueue.main.async {
                    inputViewModel.text = inputViewCustomizationParameters.externalInputText ?? ""
                }
            }
            .onChange(of: inputViewModel.showPicker) { _, newValue in
                if newValue {
                    globalFocusState.focus = nil
                }
            }
            .onChange(of: inputViewModel.showGiphyPicker) { _, newValue in
                if newValue {
                    globalFocusState.focus = nil
                }
            }
            .sheet(isPresented: $inputViewModel.showGiphyPicker) {
                GiphyEditorView(giphyConfig: giphyConfig)
                    .environmentObject(globalFocusState)
            }
            .fullScreenCover(isPresented: $inputViewModel.showPicker) {
                AttachmentsEditor(
                    inputViewModel: inputViewModel,
                    inputViewBuilder: inputViewBuilder,
                    mediaPickerParameters: inputViewCustomizationParameters.mediaPickerParameters,
                    availableInputs: inputViewCustomizationParameters.availableInputs,
                    localization: chatCustomizationParameters.localization
                )
                .environmentObject(globalFocusState)
                .environmentObject(keyboardState)
            }
            .fullScreenCover(isPresented: $viewModel.fullscreenAttachmentPresented) {
                let attachments = sections.flatMap { section in section.rows.flatMap { $0.message.attachments } }
                let index = attachments.firstIndex { $0.id == viewModel.fullscreenAttachmentItem?.id }

                GeometryReader { g in
                    FullscreenMediaPages(
                        viewModel: FullscreenMediaPagesViewModel(
                            attachments: attachments,
                            index: index ?? 0
                        ),
                        safeAreaInsets: g.safeAreaInsets,
                        onClose: { [weak viewModel] in
                            viewModel?.dismissAttachmentFullScreen()
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .background {
                // Assume all time views share width, e.g. "00:00".
                if messageCustomizationParameters.showTimeView,
                   let anyMessage = sections.first?.rows.first?.message,
                   timeViewSize == .zero {
                    FinalMeasuringTrickView(size: $timeViewSize, id: "uu") {
                        MessageTimeView(text: anyMessage.time, userType: anyMessage.user.type)
                    }
                }
            }
    }

    var mainView: some View {
        VStack(spacing: 0) {
            if chatCustomizationParameters.showNetworkConnectionProblem, !networkMonitor.isConnected {
                waitingForNetwork
            }

            if chatCustomizationParameters.isListAboveInputView {
                ZStack(alignment: .bottom) {
                    listWithButton
                    bottomChrome
                }
            } else {
                inputView
                if let builder = betweenListAndInputViewBuilder {
                    builder()
                }
                listWithButton
            }
        }
        .ignoresSafeArea(isShowingMenu ? .keyboard : [])
    }

    var waitingForNetwork: some View {
        VStack {
            Rectangle()
                .foregroundColor(theme.colors.mainText.opacity(0.12))
                .frame(height: 1)
            HStack {
                Spacer()
                Image("waiting", bundle: .current)
                Text(chatCustomizationParameters.localization.waitingForNetwork)
                Spacer()
            }
            .padding(.top, 6)
            Rectangle()
                .foregroundColor(theme.colors.mainText.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    var listWithButton: some View {
        switch type {
        case .conversation:
            ZStack(alignment: .bottomTrailing) {
                list

                if chatCustomizationParameters.showScrollToBottomButton, !isScrolledToBottom {
                    Button {
                        requestScrollToBottom()
                    } label: {
                        theme.images.scrollToBottom
                            .frame(width: 40, height: 40)
                            .circleBackground(theme.colors.messageFriendBG)
                            .foregroundStyle(theme.colors.sendButtonBackground)
                            .shadow(color: .primary.opacity(0.1), radius: 2, y: 1)
                    }
                    .padding(.trailing, MessageView.horizontalScreenEdgePadding)
                    .padding(.bottom, bottomChromeSize.height + 8)
                }
            }
        case .comments:
            list
        }
    }

    @ViewBuilder
    var list: some View {
        UIList(
            viewModel: viewModel,
            inputViewModel: inputViewModel,
            isScrolledToBottom: $isScrolledToBottom,
            shouldScrollToTop: $shouldScrollToTop,
            tableContentHeight: $tableContentHeight,
            messageBuilder: messageBuilder,
            mainHeaderBuilder: mainHeaderBuilder,
            headerBuilder: headerBuilder,
            type: type,
            bottomOverlayHeight: chatCustomizationParameters.isListAboveInputView ? bottomChromeSize.height : 0,
            sections: sections,
            ids: ids,
            scrollToBottomRequestID: scrollToBottomRequestID,
            chatParams: chatCustomizationParameters,
            messageParams: messageCustomizationParameters,
            timeViewWidth: $timeViewSize.width
        )
        .applyIf(!chatCustomizationParameters.isScrollEnabled) {
            $0.frame(height: tableContentHeight)
        }
        .onStatusBarTap {
            shouldScrollToTop()
        }
        .transparentNonAnimatingFullScreenCover(item: $viewModel.messageMenuRow) {
            if let row = viewModel.messageMenuRow {
                messageMenu(row)
                    .onAppear(perform: showMessageMenu)
            }
        }
        .onPreferenceChange(MessageMenuPreferenceKey.self) { frames in
            DispatchQueue.main.async {
                if self.cellFrames != frames {
                    self.cellFrames = frames
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                globalFocusState.focus = nil
                keyboardState.resignFirstResponder()
            }
        )
        .onAppear {
            viewModel.didSendMessage = didSendMessage
            viewModel.inputViewModel = inputViewModel
            viewModel.globalFocusState = globalFocusState
            if let didUpdateAttachmentStatus {
                viewModel.didUpdateAttachmentStatus = didUpdateAttachmentStatus
            }

            inputViewModel.didSendMessage = { value in
                let accepted = await didSendMessage(value)
                if accepted, type == .conversation {
                    scheduleScrollToBottom()
                }
                return accepted
            }
        }
        .onDisappear {
            pendingScrollToBottomTask?.cancel()
            pendingScrollToBottomTask = nil
        }
    }

    private func requestScrollToBottom() {
        scrollToBottomRequestID = scrollToBottomRequestID &+ 1
    }

    private func scheduleScrollToBottom() {
        pendingScrollToBottomTask?.cancel()
        pendingScrollToBottomTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            requestScrollToBottom()
        }
    }

    var inputView: some View {
        Group {
            let customInputView = inputViewBuilder(
                InputViewBuilderParameters(
                    text: $inputViewModel.text,
                    attachments: inputViewModel.attachments,
                    inputViewState: inputViewModel.state,
                    inputViewStyle: .message,
                    inputViewActionClosure: inputViewModel.inputViewAction()
                ) {
                    globalFocusState.focus = nil
                }
            )

            if customInputView is DummyView {
                InputView(
                    viewModel: inputViewModel,
                    inputFieldId: viewModel.inputFieldId,
                    style: .message,
                    availableInputs: inputViewCustomizationParameters.availableInputs,
                    recorderSettings: inputViewCustomizationParameters.recorderSettings,
                    localization: chatCustomizationParameters.localization
                )
            } else {
                if inputViewCustomizationParameters.appliesFocusModifierToCustomInputView {
                    customInputView
                        .customFocus($globalFocusState.focus, equals: .uuid(viewModel.inputFieldId))
                } else {
                    customInputView
                }
            }
        }
        .sizeGetter($inputViewSize)
        .environmentObject(globalFocusState)
        .onAppear(perform: inputViewModel.onStart)
        .onDisappear(perform: inputViewModel.onStop)
    }

    @ViewBuilder
    var bottomChrome: some View {
        VStack(spacing: 0) {
            if let builder = betweenListAndInputViewBuilder {
                builder()
            }
            inputView
        }
        .sizeGetter($bottomChromeSize)
    }

    func messageMenu(_ row: MessageRow) -> some View {
        let cellFrame = cellFrames[row.id] ?? .zero

        return MessageMenu(
            viewModel: viewModel,
            isShowingMenu: $isShowingMenu,
            message: row.message,
            cellFrame: cellFrame,
            alignment: menuAlignment(row.message, chatType: type),
            positionInUserGroup: row.positionInUserGroup,
            leadingPadding: messageCustomizationParameters.avatarSize + MessageView.horizontalScreenEdgePadding + MessageView.horizontalSpacing,
            trailingPadding: MessageView.statusViewWidth + MessageView.horizontalScreenEdgePadding + MessageView.horizontalSpacing,
            font: messageCustomizationParameters.font,
            animationDuration: chatCustomizationParameters.messageMenuAnimationDuration,
            onAction: menuActionClosure(row.message),
            reactionHandler: MessageMenu.ReactionConfig(
                delegate: chatCustomizationParameters.reactionDelegate,
                didReact: reactionClosure(row.message)
            )
        ) {
            ChatMessageView(
                viewModel: viewModel,
                messageBuilder: messageBuilder,
                row: row,
                chatType: type,
                messageParams: messageCustomizationParameters,
                timeViewWidth: $timeViewSize.width,
                isDisplayingMessageMenu: true
            )
            .onTapGesture {
                hideMessageMenu()
            }
        }
    }

    private func menuAlignment(_ message: Message, chatType: ChatType) -> MessageMenuAlignment {
        switch chatType {
        case .conversation:
            return message.user.isCurrentUser ? .right : .left
        case .comments:
            return .left
        }
    }

    private func reactionClosure(_ message: Message) -> (ReactionType?) -> Void {
        { reactionType in
            Task { @MainActor in
                hideMessageMenu()
                guard let reactionDelegate = chatCustomizationParameters.reactionDelegate, let reactionType else { return }
                reactionDelegate.didReact(to: message, reaction: DraftReaction(messageID: message.id, type: reactionType))
            }
        }
    }

    func menuActionClosure(_ message: Message) -> (MenuAction) -> Void {
        { action in
            hideMessageMenu()
            messageMenuAction(action, viewModel.messageMenuAction(), message)
        }
    }

    func showMessageMenu() {
        isShowingMenu = true
    }

    func hideMessageMenu() {
        viewModel.messageMenuRow = nil
        viewModel.messageFrame = .zero
        isShowingMenu = false
    }

    private func chatBackground() -> some View {
        Group {
            if let background = theme.images.background {
                switch (isLandscape(), colorScheme) {
                case (true, .dark):
                    background.landscapeBackgroundDark
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (true, .light):
                    background.landscapeBackgroundLight
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (false, .dark):
                    background.portraitBackgroundDark
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (false, .light):
                    background.portraitBackgroundLight
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                default:
                    theme.colors.mainBG
                }
            } else {
                theme.colors.mainBG
            }
        }
    }

    private func isLandscape() -> Bool {
        UIDevice.current.orientation.isLandscape
    }

    private func isGiphyAvailable() -> Bool {
        GiphySupport.isBundled && inputViewCustomizationParameters.availableInputs.contains(.giphy)
    }
}

#Preview {
    let romeo = User(id: "romeo", name: "Romeo Montague", avatarURL: nil, isCurrentUser: true)
    let juliet = User(id: "juliet", name: "Juliet Capulet", avatarURL: nil, isCurrentUser: false)

    let monday = try! Date.iso8601Date.parse("2025-05-12")
    let tuesday = try! Date.iso8601Date.parse("2025-05-13")

    ChatView(messages: [
        Message(
            id: "26tb", user: romeo, status: .read, createdAt: monday,
            text: "And I’ll still stay, to have thee still forget"),
        Message(
            id: "zee6", user: romeo, status: .read, createdAt: monday,
            text: "Forgetting any other home but this"),
        Message(
            id: "oWUN", user: juliet, status: .read, createdAt: monday,
            text: "’Tis almost morning. I would have thee gone"),
        Message(
            id: "P261", user: juliet, status: .read, createdAt: monday,
            text: "And yet no farther than a wanton’s bird"),
        Message(
            id: "46hu", user: juliet, status: .read, createdAt: monday,
            text: "That lets it hop a little from his hand"),
        Message(
            id: "Gjbm", user: juliet, status: .read, createdAt: monday,
            text: "Like a poor prisoner in his twisted gyves"),
        Message(
            id: "IhRQ", user: juliet, status: .read, createdAt: monday,
            text: "And with a silken thread plucks it back again"),
        Message(
            id: "kwWd", user: juliet, status: .read, createdAt: monday,
            text: "So loving-jealous of his liberty"),
        Message(
            id: "9481", user: romeo, status: .read, createdAt: tuesday,
            text: "I would I were thy bird"),
        Message(
            id: "dzmY", user: juliet, status: .sent, createdAt: tuesday, text: "Sweet, so would I"),
        Message(
            id: "r5HH", user: juliet, status: .sent, createdAt: tuesday,
            text: "Yet I should kill thee with much cherishing"),
        Message(
            id: "quy1", user: juliet, status: .sent, createdAt: tuesday,
            text: "Good night, good night. Parting is such sweet sorrow"),
        Message(
            id: "Mwh6", user: juliet, status: .sent, createdAt: tuesday,
            text: "That I shall say 'Good night' till it be morrow"),
    ]) { draft in }
}
