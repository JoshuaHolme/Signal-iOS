//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import SignalClient
import GRDB

@objc
public class MessageSendLog: NSObject {

    struct Payload: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "MessageSendLog_Payload"
        static let recipient = hasMany(Recipient.self)

        var payloadId: Int64?
        let plaintextContent: Data
        let contentHint: UnidentifiedSenderMessageContent.ContentHint
        let sentTimestamp: Date
        let uniqueThreadId: String

        init(
            plaintextContent: Data,
            contentHint: UnidentifiedSenderMessageContent.ContentHint,
            sentTimestamp: Date,
            uniqueThreadId: String
        ) {
            self.plaintextContent = plaintextContent
            self.contentHint = contentHint
            self.sentTimestamp = sentTimestamp
            self.uniqueThreadId = uniqueThreadId
        }

        mutating func didInsert(with rowID: Int64, for column: String?) {
            guard column == "payloadId" else { return owsFailDebug("") }
            payloadId = rowID
        }
    }

    struct Recipient: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "MessageSendLog_Recipient"
        static let payload = belongsTo(Payload.self)

        private let payloadId: Int64
        private let recipientUUID: UUID
        private let recipientDeviceId: Int64

        init(payloadId: Int64, recipientUUID: UUID, recipientDeviceId: Int64) {
            self.payloadId = payloadId
            self.recipientUUID = recipientUUID
            self.recipientDeviceId = recipientDeviceId
        }
    }

    struct Message: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "MessageSendLog_Message"
        static let payloadId = belongsTo(Payload.self)

        private let payloadId: Int64
        private let uniqueId: String

        init(payloadId: Int64, uniqueId: String) {
            self.payloadId = payloadId
            self.uniqueId = uniqueId
        }
    }

    @objc
    public static func recordPayload(
        _ plaintext: Data,
        for message: TSOutgoingMessage,
        transaction writeTx: SDSAnyWriteTransaction
    ) -> NSNumber? {
        guard message.shouldRecordSendLog else { return nil }

        var payload = Payload(
            plaintextContent: plaintext,
            contentHint: message.contentHint,
            sentTimestamp: message.date,
            uniqueThreadId: message.uniqueThreadId)

        do {
            // Insert the plaintext into the database
            try payload.insert(writeTx.unwrapGrdbWrite.database)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_ABORT {
            // A UNIQUE constraint may fail if the payload for this message
            // has already been inserted. e.g. The message is being resent.
            // That's okay, just ignore it.
            Logger.warn("")
            // Sender Key TODO: Verify cached payload matches?
            return nil

        } catch {
            // We don't anticipate any other error.
            owsFailDebug("")
            return nil
        }

        // If the payload was successfully recorded, we should also record
        // any interactions related to this payload. This should not fail.
        do {
            guard let payloadId = payload.payloadId else {
                throw OWSAssertionError("Expected payloadId to be set")
            }
            try message.relatedUniqueIds.forEach { uniqueId in
                try Message(payloadId: payloadId, uniqueId: uniqueId)
                    .insert(writeTx.unwrapGrdbWrite.database)
            }
            return NSNumber(value: payloadId)
        } catch {
            owsFailDebug("")
            return nil
        }
    }

    static func fetchPayload(
        address: SignalServiceAddress,
        deviceId: Int64,
        timestamp: Date,
        transaction readTx: SDSAnyReadTransaction
    ) -> Payload? {
        do {
            let recipientAlias = TableAlias()
            let request = Payload
                .joining(required: Payload.recipient.aliased(recipientAlias))
                .filter(Column("sentTimestamp") == timestamp)
                .filter(recipientAlias[Column("recipientUUID")] == address.uuid)
                .filter(recipientAlias[Column("recipientDeviceId")] == deviceId)

            let payloads = try Payload.fetchAll(readTx.unwrapGrdbRead.database, request)
            if payloads.count == 1, let result = payloads.first {
                return result
            } else {
                return nil
            }
        } catch {
            owsFailDebug("\(error)")
            return nil
        }
    }

    public static func recordPendingDelivery(
        payloadId: Int64,
        recipientUuid: UUID,
        recipientDeviceId: Int64,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        do {
            try Recipient(
                payloadId: payloadId,
                recipientUUID: recipientUuid,
                recipientDeviceId: recipientDeviceId
            ).insert(writeTx.unwrapGrdbWrite.database)
        } catch {
            owsFailDebug("")
        }
    }

    public static func recordSuccessfulDelivery(
        timestamp: Date,
        recipientUuid: UUID,
        recipientDeviceId: Int,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        do {
            let payloadAlias = TableAlias()
            try Recipient
                .joining(required: Recipient.payload.aliased(payloadAlias))
                .filter(payloadAlias[Column("sentTimestamp")] == timestamp)
                .filter(Column("recipientUuid") == recipientUuid)
                .filter(Column("recipientDeviceId") == recipientDeviceId)
                .deleteAll(writeTx.unwrapGrdbWrite.database)
        } catch {
            owsFailDebug("")
        }
    }

    @objc
    public static func deleteAllPayloadsForInteraction(
        _ interaction: TSInteraction,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        do {
            try Recipient
                .filter(Column("uniqueId") == interaction.uniqueId)
                .deleteAll(writeTx.unwrapGrdbWrite.database)
        } catch {
            owsFailDebug("")
        }
    }

    public static func cleanupStaleEntries(transaction writeTx: SDSAnyWriteTransaction) {
        // TODO: Clear everything older than one day
    }
}

extension UnidentifiedSenderMessageContent.ContentHint: Codable {}
