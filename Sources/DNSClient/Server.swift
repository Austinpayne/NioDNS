// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import NIO

public final class DNSServer {
    public init() {}
    public func listenMulticast(on group: EventLoopGroup, using interface: NIONetworkInterface? = nil, ipv4: Bool = false, handler: @escaping DNSServerHanderFunction) {
        let multicastGroup = try! SocketAddress(ipAddress: ipv4 ? "224.0.0.251" : "ff02::fb", port: 5353)
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelOption(ChannelOptions.receivePacketInfo, value: true)
            .channelInitializer { channel in
                return channel.pipeline.addHandlers(
                    DNSDecoder(),
                    DNSServerHandler(handler: handler),
                    DNSEncoder()
                )
        }

        _ = try! bootstrap.bind(host: ipv4 ? "0.0.0.0" : "::", port: 5353)
            .flatMap { channel -> EventLoopFuture<Channel> in
                let channel = channel as! MulticastChannel
                return channel.joinGroup(multicastGroup, interface: interface).map { channel }
            }.flatMap { channel -> EventLoopFuture<Channel> in
                guard let interface = interface else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                let provider = channel as! SocketOptionProvider
                switch interface.address {
                case .v4(let addr):
                    return provider.setIPMulticastIF(addr.address.sin_addr).map { channel }
                case .v6:
                    return provider.setIPv6MulticastIF(CUnsignedInt(interface.interfaceIndex)).map { channel }
                case .unixDomainSocket:
                    preconditionFailure("Should not be possible to create a multicast socket on a unix domain socket")
                }
            }.wait()
    }
}
