//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public class CloudBackupChatItemArchiverImp: CloudBackupChatItemArchiver {

    private let dateProvider: DateProvider
    private let interactionStore: InteractionStore
    private let reactionStore: ReactionStore
    private let threadStore: ThreadStore

    public init(
        dateProvider: @escaping DateProvider,
        interactionStore: InteractionStore,
        reactionStore: ReactionStore,
        threadStore: ThreadStore
    ) {
        self.dateProvider = dateProvider
        self.interactionStore = interactionStore
        self.reactionStore = reactionStore
        self.threadStore = threadStore
    }

    private lazy var reactionArchiver = CloudBackupReactionArchiver(reactionStore: reactionStore)

    private lazy var contentsArchiver = CloudBackupTSMessageContentsArchiver(
        reactionArchiver: reactionArchiver
    )

    private lazy var interactionArchivers: [CloudBackupInteractionArchiver] = [
        CloudBackupTSIncomingMessageArchiver(
            contentsArchiver: contentsArchiver,
            interactionStore: interactionStore
        ),
        CloudBackupTSOutgoingMessageArchiver(
            contentsArchiver: contentsArchiver,
            interactionStore: interactionStore
        )
        // TODO: need for info messages. not story messages, those are skipped.
        // are there other message types? what about e.g. payment messages?
        // anything that isnt a TSOutgoingMessage or TSIncomingMessage.
    ]

    public func archiveInteractions(
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        var completeFailureError: Error?
        var partialFailures = [ArchiveMultiFrameResult.Error]()

        func archiveInteraction(
            _ interaction: TSInteraction,
            stop: inout Bool
        ) {
            let result = self.archiveInteraction(
                interaction,
                stream: stream,
                context: context,
                tx: tx
            )
            switch result {
            case .success:
                break
            case .partialSuccess(let errors):
                partialFailures.append(contentsOf: errors)
            case .completeFailure(let error):
                completeFailureError = error
                stop = true
            }
        }

        do {
            try interactionStore.enumerateAllInteractions(
                tx: tx,
                block: archiveInteraction(_:stop:)
            )
        } catch let error {
            // Errors thrown here are from the iterator's SQL query,
            // not the individual interaction handler.
            return .completeFailure(error)
        }

        if let completeFailureError {
            return .completeFailure(completeFailureError)
        } else if partialFailures.isEmpty {
            return .success
        } else {
            return .partialSuccess(partialFailures)
        }
    }

    private func archiveInteraction(
        _ interaction: TSInteraction,
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        var partialErrors = [ArchiveMultiFrameResult.Error]()

        guard let chatId = context[interaction.uniqueThreadIdentifier] else {
            partialErrors.append(.init(
                objectId: interaction.chatItemId,
                error: .referencedIdMissing(.thread(interaction.uniqueThreadIdentifier))
            ))
            return .partialSuccess(partialErrors)
        }

        guard let archiver = interactionArchivers.first(where: {
            type(of: $0).canArchiveInteraction(interaction)
        }) else {
            // TODO: when we have a complete set of archivers, this should
            // maybe be considered a catastrophic failure?
            // For now there's interactions we don't handle; just ignore it.
            return .success
        }

        let result = archiver.archiveInteraction(
            interaction,
            context: context,
            tx: tx
        )

        let details: CloudBackup.InteractionArchiveDetails
        switch result {
        case .success(let deets):
            details = deets

        case .isPastRevision, .notYetImplemented:
            // Skip! Say it succeeded so we ignore it.
            return .success

        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return .partialSuccess(partialErrors)
        case .partialFailure(let deets, let errors):
            partialErrors.append(contentsOf: errors)
            details = deets
        case .completeFailure(let error):
            return .completeFailure(error)
        }

        let minExpireTime = dateProvider().ows_millisecondsSince1970
            + CloudBackup.Constants.minExpireTimerMs
        if
            let expireStartDate = details.expireStartDate,
            let expiresInMs = details.expiresInMs,
            expireStartDate + expiresInMs < minExpireTime
        {
            // Skip this message, but count it as a success.
            return .success
        }

        let chatItemBuilder = BackupProtoChatItem.builder(
            chatID: chatId.value,
            authorID: details.author.value,
            dateSent: interaction.timestamp,
            sealedSender: details.isSealedSender,
            sms: details.isSms
        )

        switch details.type {
        case .standard(let msg):
            chatItemBuilder.setStandardMessage(msg)
        case .contact(let msg):
            chatItemBuilder.setContactMessage(msg)
        case .voice(let msg):
            chatItemBuilder.setVoiceMessage(msg)
        case .sticker(let msg):
            chatItemBuilder.setStickerMessage(msg)
        case .remotelyDeleted(let msg):
            chatItemBuilder.setRemoteDeletedMessage(msg)
        case .chatUpdate(let msg):
            chatItemBuilder.setUpdateMessage(msg)
        }

        if let expireStartDate = details.expireStartDate {
            chatItemBuilder.setExpireStartDate(expireStartDate)
        }
        if let expiresInMs = details.expiresInMs {
            chatItemBuilder.setExpiresInMs(expiresInMs)
        }

        chatItemBuilder.setRevisions(details.revisions)

        let error = Self.writeFrameToStream(stream) { frameBuilder in
            let chatItemProto = try chatItemBuilder.build()
            let frameBuilder = BackupProtoFrame.builder()
            frameBuilder.setChatItem(chatItemProto)
            return try frameBuilder.build()
        }

        if let error {
            partialErrors.append(.init(objectId: interaction.chatItemId, error: error))
            return .partialSuccess(partialErrors)
        } else if partialErrors.isEmpty {
            return .success
        } else {
            return .partialSuccess(partialErrors)
        }
    }

    public func restore(
        _ chatItem: BackupProtoChatItem,
        context: CloudBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult {
        guard let archiver = interactionArchivers.first(where: {
            type(of: $0).canRestoreChatItem(chatItem)
        }) else {
            // TODO: when we have a complete set of archivers, this should
            // maybe be considered a catastrophic failure?
            // For now there's interactions we don't handle; just ignore it.
            return .success
        }

        guard let threadUniqueId = context[chatItem.chatId] else {
            return .failure(chatItem.id, [.identifierNotFound(.chat(chatItem.chatId))])
        }

        guard
            let thread = threadStore.fetchThread(uniqueId: threadUniqueId.value, tx: tx)
        else {
            return .failure(
                chatItem.id,
                [.referencedDatabaseObjectNotFound(.thread(threadUniqueId))]
            )
        }

        let result = archiver.restoreChatItem(
            chatItem,
            thread: thread,
            context: context,
            tx: tx
        )

        switch result {
        case .success:
            return .success
        case .partialRestore(_, let errors):
            return .partialRestore(chatItem.id, errors)
        case .messageFailure(let errors):
            return .failure(chatItem.id, errors)
        }
    }
}
