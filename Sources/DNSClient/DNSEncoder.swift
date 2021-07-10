import NIO

final class EnvelopeOutboundChannel: ChannelOutboundHandler {
    typealias OutboundIn = Message
    typealias OutboundOut = AddressedEnvelope<Message>
    
    let address: SocketAddress
    
    init(address: SocketAddress) {
        self.address = address
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
        context.write(wrapOutboundOut(envelope), promise: promise)
    }
}

final class DNSEncoder: ChannelOutboundHandler {
    typealias OutboundIn = AddressedEnvelope<Message>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let envelope = unwrapOutboundIn(data)
        let message = envelope.data
        let data = DNSEncoder.encodeMessage(message, allocator: context.channel.allocator)

        let messageEnvelope = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: data)
        context.write(wrapOutboundOut(messageEnvelope), promise: promise)
    }
    
    static func encodeMessage(_ message: Message, allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 512)

        let header = message.header

        out.write(header)

        for question in message.questions {
            out.writeLabel(question.labels)

            out.writeInteger(0, endianness: .big, as: UInt8.self)
            out.writeInteger(question.type.rawValue, endianness: .big)
            let rrclass = (question.unicastResponse ? unicastResponseBit : 0x0) | question.questionClass.rawValue
            out.writeInteger(rrclass, endianness: .big)
        }

        for answer in message.answers {
            switch answer {
            case let .aaaa(aaaa):
                out.writeAnswerHeader(aaaa)

                out.writeInteger(UInt16(aaaa.resource.address.count), endianness: .big)
                out.writeBytes(aaaa.resource.address)
                break
            default:
                break
            }
        }

        return out
    }
}

final class MDNSResponder: ChannelOutboundHandler {
    typealias OutboundIn = AddressedEnvelope<Message>
    typealias OutboundOut = AddressedEnvelope<Message>

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Per RFC 6762 we should delay response by 20-120ms to avoid collisions:
        // See also https://datatracker.ietf.org/doc/html/rfc6762#section-6
        context.eventLoop.scheduleTask(in: .milliseconds(Int64.random(in: 20...120))) {
            context.write(data, promise: promise)
        }
    }
}
