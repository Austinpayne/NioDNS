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
            for label in question.labels {
                out.writeInteger(label.length, endianness: .big)
                out.writeBytes(label.label)
            }

            out.writeInteger(0, endianness: .big, as: UInt8.self)
            out.writeInteger(question.type.rawValue, endianness: .big)
            out.writeInteger(question.questionClass.rawValue, endianness: .big)
        }

        for answer in message.answers {
            switch answer {
            case let .aaaa(aaaa):
                let cacheFlush = aaaa.cacheFlush ? cacheFlushBit : 0x0
                let classNumber = aaaa.dataClass & rrclassMask
                for label in aaaa.domainName {
                    out.writeInteger(label.length, endianness: .big)
                    out.writeBytes(label.label)
                }
                out.writeInteger(aaaa.dataType, endianness: .big)
                out.writeInteger(cacheFlush | classNumber, endianness: .big)
                out.writeInteger(aaaa.ttl, endianness: .big)

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
