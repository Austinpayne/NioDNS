import NIO

final class DNSDecoder: ChannelInboundHandler {
    init() {}

    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias InboundOut = AddressedEnvelope<Message>
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        var buffer = envelope.data

        guard let header = buffer.readHeader() else {
            context.fireErrorCaught(ProtocolError())
            return
        }

        var questions = [QuestionSection]()

        for _ in 0..<header.questionCount {
            guard let question = buffer.readQuestion() else {
                context.fireErrorCaught(ProtocolError())
                return
            }

            questions.append(question)
        }

        func resourceRecords(count: UInt16) throws -> [Record] {
            var records = [Record]()

            for _ in 0..<count {
                guard let record = buffer.readRecord() else {
                    throw ProtocolError()
                }

                records.append(record)
            }

            return records
        }

        do {
            let message = Message(
                header: header,
                questions: questions,
                answers: try resourceRecords(count: header.answerCount),
                authorities: try resourceRecords(count: header.authorityCount),
                additionalData: try resourceRecords(count: header.additionalRecordCount)
            )

            var metaData: AddressedEnvelope<Message>.Metadata? = nil
            if let meta = envelope.metadata {
                metaData = AddressedEnvelope<Message>.Metadata(ecnState: meta.ecnState, packetInfo: meta.packetInfo)
            }
            let messageEnvelope = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: message, metadata: metaData)
            context.fireChannelRead(wrapInboundOut(messageEnvelope))
        } catch {
            context.fireErrorCaught(error)
        }
    }

    func errorCaught(context ctx: ChannelHandlerContext, error: Error) {
        // TODO
        _ = ctx.close()
    }
}

final class DNSClientCache: ChannelInboundHandler {
    let group: EventLoopGroup
    var messageCache = [UInt16: SentQuery]()
    var clients = [ObjectIdentifier: DNSClient]()
    weak var mainClient: DNSClient?

    init(group: EventLoopGroup) {
        self.group = group
    }

    public typealias InboundIn = AddressedEnvelope<Message>
    public typealias OutboundOut = Never

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        let message = envelope.data
        let id = message.header.id

        do {
            guard let query = messageCache[id] else {
                throw UnknownQuery()
            }
            query.promise.succeed(message)
            _ = query.callback(message, context.eventLoop).map {
                switch $0 {
                case .done: self.messageCache[id] = nil
                case .continue: break
                }
            }
        } catch {
            messageCache[id]?.promise.fail(error)
            messageCache[id] = nil
            context.fireErrorCaught(error)
        }
    }

    func errorCaught(context ctx: ChannelHandlerContext, error: Error) {
        for query in self.messageCache.values {
            query.promise.fail(error)
        }

        messageCache = [:]
    }
}

public typealias DNSServerHanderFunction = (AddressedEnvelope<Message>) throws -> AddressedEnvelope<Message>?
final class DNSServerHandler: ChannelInboundHandler {
    let handler: DNSServerHanderFunction

    init(handler: @escaping DNSServerHanderFunction) {
        self.handler = handler
    }

    public typealias InboundIn = AddressedEnvelope<Message>
    public typealias OutboundOut = Never

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        do {
            if let responseEnvelope = try self.handler(envelope) {
                context.channel.writeAndFlush(responseEnvelope, promise: nil)
            }
        } catch {
            context.fireErrorCaught(error)
        }
    }
}
