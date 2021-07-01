import NIO
import Foundation

/// The header of a
public struct DNSMessageHeader {
    public internal(set) var id: UInt16
    
    public let options: MessageOptions
    
    public let questionCount: UInt16
    public let answerCount: UInt16
    public let authorityCount: UInt16
    public let additionalRecordCount: UInt16

    static func Answer(message: Message, answers: UInt16) -> DNSMessageHeader {
        return DNSMessageHeader(
            id: message.header.id,
            options: [.answer, .authorativeAnswer],
            questionCount: 0,
            answerCount: answers,
            authorityCount: 0,
            additionalRecordCount: 0)
    }
}

public struct DNSLabel: ExpressibleByStringLiteral {
    public let length: UInt8
    
    // Max UInt8.max in length
    public let label: [UInt8]
    
    public init(stringLiteral string: String) {
        self.init(bytes: Array(string.utf8))
    }
    
    public init(bytes: [UInt8]) {
        assert(bytes.count < 64)
        
        self.label = bytes
        self.length = UInt8(bytes.count)
    }
}

public enum DNSResourceType: UInt16 {
    case a = 1
    case ns
    case md
    case mf
    case cName
    case soa
    case mb
    case mg
    case mr
    case null
    case wks
    case ptr
    case hInfo
    case mInfo
    case mx
    case txt
    case aaaa = 28
    case srv = 33
    
    // QuestionType exclusive
    case axfr = 252
    case mailB = 253
    case mailA = 254
    case any = 255
}

public typealias QuestionType = DNSResourceType

internal let rrclassMask: UInt16 = 0x7fff
internal let cacheFlushBit: UInt16 = 0x8000
internal let unicastResponseBit: UInt16 = 0x8000

public enum DataClass: UInt16 {
    case internet = 1
    case chaos = 3
    case hesoid = 4
}

public struct QuestionSection {
    public let labels: [DNSLabel]
    public let type: QuestionType
    public let questionClass: DataClass
    public let unicastResponse: Bool

    // unicastResponse only applies to mDNS questions/answers.
    // For plain unicast DNS it should always be false.
    init(labels: [DNSLabel],
                  type: QuestionType,
                  questionClass: DataClass,
                  unicastResponse: Bool = false)
    {
        self.labels = labels
        self.type = type
        self.questionClass = questionClass
        self.unicastResponse = unicastResponse
    }
}

public enum Record {
    case aaaa(ResourceRecord<AAAARecord>)
    case a(ResourceRecord<ARecord>)
    case txt(ResourceRecord<TXTRecord>)
    case srv(ResourceRecord<SRVRecord>)
    case ptr(ResourceRecord<PTRRecord>)
    case other(ResourceRecord<ByteBuffer>)

    public static func AAAA(domainName: [DNSLabel],
                            address: SocketAddress,
                            ttl: UInt32 = 120,
                            cacheFlush: Bool = false) throws -> Record
    {
        return .aaaa(
            .init(
                domainName: domainName,
                dataType: DNSResourceType.aaaa.rawValue,
                dataClass: DataClass.internet.rawValue,
                ttl: ttl,
                resource: try .init(address: address),
                cacheFlush: cacheFlush))
    }
}

public struct TXTRecord: DNSResource {
    public let text: String
    public let key: String
    public let value: String
    
    init?(text: String) {
        self.text = text

        // Key-value TXT records are common but RFC 1035 does not specify the format
        // See: https://tools.ietf.org/html/rfc1035 section 3.3.14
        let parts = text.split(separator: "=")
        if parts.count != 2 {
            self.key = ""
            self.value = ""
        } else {
            self.key = String(parts[0])
            self.value = String(parts[1])
        }
    }

    public static func read(from buffer: inout ByteBuffer, length: Int) -> TXTRecord? {
        guard let string = buffer.readString(length: length) else {
            return nil
        }
        
        return TXTRecord(text: string)
    }
}

public struct ARecord: DNSResource {
    public let address: UInt32
    public var stringAddress: String {
        guard let addr = self.socketAddress(port: 0) else {
            return ""
        }
        return addr.ipAddress ?? ""
    }

    public func socketAddress(port: Int) -> SocketAddress? {
        return try? self.address.socketAddress(port: port)
    }

    public static func read(from buffer: inout ByteBuffer, length: Int) -> ARecord? {
        guard let address = buffer.readInteger(endianness: .big, as: UInt32.self) else { return nil }
        return ARecord(address: address)
    }
}

public struct AAAARecord: DNSResource {
    public let address: [UInt8]

    init(address: [UInt8]) {
        self.address = address
    }

    init(address: SocketAddress) throws {
        guard case let .v6(ipv6) = address else {
            throw SocketAddressError.unsupported
        }

        #if os(Linux)
        let data = ipv6.address.sin6_addr.__in6_u.__u6_addr8
        #else
        let data = ipv6.address.sin6_addr.__u6_addr.__u6_addr8
        #endif
        self.address = [ data.0,  data.1,  data.2,  data.3,
                         data.4,  data.5,  data.6,  data.7,
                         data.8,  data.9,  data.10, data.11,
                         data.12, data.13, data.14, data.15 ]
    }

    public var stringAddress: String {
        guard let addr = self.socketAddress(port: 0) else {
            return ""
        }
        return addr.ipAddress ?? ""
    }

    public func socketAddress(port: Int) -> SocketAddress? {
        return try? self.address.socketAddress(port: port)
    }

    public static func read(from buffer: inout ByteBuffer, length: Int) -> AAAARecord? {
        guard let address = buffer.readBytes(length: 16) else { return nil }
        return AAAARecord(address: address)
    }
}

public struct PTRRecord: DNSResource {
    public let domainName: [DNSLabel]

    public static func read(from buffer: inout ByteBuffer, length: Int) -> PTRRecord? {
        guard let domainName = buffer.readLabels() else {
            return nil
        }

        return PTRRecord(domainName: domainName)
    }
}

public struct ResourceRecord<Resource: DNSResource> {
    public let domainName: [DNSLabel]
    public let dataType: UInt16
    public let dataClass: UInt16
    public let ttl: UInt32
    public var resource: Resource
    public let cacheFlush: Bool
}

public protocol DNSResource {
    static func read(from buffer: inout ByteBuffer, length: Int) -> Self?
}

extension ByteBuffer: DNSResource {
    public static func read(from buffer: inout ByteBuffer, length: Int) -> ByteBuffer? {
        return buffer.readSlice(length: length)
    }
}

fileprivate struct InvalidSOARecord: Error {}

extension ResourceRecord where Resource == ByteBuffer {
    mutating func parseSOA() throws -> ZoneAuthority {
        guard
            let domainName = resource.readLabels(),
            resource.readableBytes >= 20, // Minimum 5 UInt32's
            let serial: UInt32 = resource.readInteger(endianness: .big),
            let refresh: UInt32 = resource.readInteger(endianness: .big),
            let retry: UInt32 = resource.readInteger(endianness: .big),
            let expire: UInt32 = resource.readInteger(endianness: .big),
            let minimumExpire: UInt32 = resource.readInteger(endianness: .big)
        else {
            throw InvalidSOARecord()
        }
        
        return ZoneAuthority(
            domainName: domainName,
            adminMail: "",
            serial: serial,
            refreshInterval: refresh,
            retryTimeinterval: retry,
            expireTimeout: expire,
            minimumExpireTimeout: minimumExpire
        )
    }
}

extension UInt32 {
    func socketAddress(port: Int) throws -> SocketAddress {
        var host = ""
        if let text = inet_ntoa(in_addr(s_addr: self.bigEndian)) {
            host = String(cString: text)
        }
        
        return try SocketAddress(ipAddress: host, port: port)
    }
}

typealias s6_addr = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
extension Array where Element == UInt8 {
    func socketAddress(port: Int) throws -> SocketAddress {
        if self.count != 16 {
            throw SocketAddressError.unsupported
        }

        let scopeID: UInt32 = 0 // More info about scope_id/zone_id https://tools.ietf.org/html/rfc6874#page-3
        let flowinfo: UInt32 = 0 // More info about flowinfo https://tools.ietf.org/html/rfc6437#page-4

        #if os(Linux)
        let ipAddress = self.withUnsafeBytes { buffer in
            return buffer.bindMemory(to: in6_addr.__Unnamed_union___in6_u.self).baseAddress!.pointee
        }
        let sockaddr = sockaddr_in6(sin6_family: sa_family_t(AF_INET6), sin6_port: in_port_t(port).bigEndian, sin6_flowinfo: flowinfo, sin6_addr: in6_addr(__in6_u: ipAddress), sin6_scope_id: scopeID)
        #else
        let ipAddress = self.withUnsafeBytes { buffer in
            return buffer.bindMemory(to: in6_addr.__Unnamed_union___u6_addr.self).baseAddress!.pointee
        }
        let size = MemoryLayout<sockaddr_in6>.size
        let sockaddr = sockaddr_in6(sin6_len: numericCast(size), sin6_family: sa_family_t(AF_INET6), sin6_port: in_port_t(port).bigEndian, sin6_flowinfo: flowinfo, sin6_addr: in6_addr(__u6_addr: ipAddress), sin6_scope_id: scopeID)
        #endif

        return SocketAddress(sockaddr, host: "")
    }
}

struct ZoneAuthority {
    let domainName: [DNSLabel]
    let adminMail: String
    let serial: UInt32
    let refreshInterval: UInt32
    let retryTimeinterval: UInt32
    let expireTimeout: UInt32
    let minimumExpireTimeout: UInt32
}

extension Array where Element == DNSLabel {
    public var string: String {
        return self.compactMap { label in
            if let string = String(bytes: label.label, encoding: .utf8), string.count > 0 {
                return string
            }
            
            return nil
            }.joined(separator: ".")
    }
}

// TODO: https://tools.ietf.org/html/rfc1035 section 4.1.4 compression

public struct Message {
    public internal(set) var header: DNSMessageHeader
    public let questions: [QuestionSection]
    public let answers: [Record]
    public let authorities: [Record]
    public let additionalData: [Record]

    public static func Answer(message: Message, with answers: [Record]) -> Message {
        return Message(
            header: .Answer(message: message, answers: UInt16(answers.count)),
            questions: [],
            answers: answers,
            authorities: [],
            additionalData: [])
    }
}
