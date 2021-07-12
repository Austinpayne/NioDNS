// Copyright (c) 2021 PassiveLogic, Inc.

import DNSClient
import NIO
import XCTest

final class MulticastTests: XCTestCase {
    var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    func testMulticastIPv6() throws {
        let lo = try System.enumerateDevices().filter({$0.address?.ipAddress == "::1"}).first!
        try _testMulticast(interface: lo)
    }

    func testMulticastIPv4() throws {
        let lo = try System.enumerateDevices().filter({$0.address?.ipAddress == "127.0.0.1"}).first!
        try _testMulticast(interface: lo)
    }

    private func _testMulticast(interface: NIONetworkDevice) throws {
        let service = "_fake._tcp.local"
        let expectedServer = "test.\(service)"

        // Listen for and respond to PTR requests
        let server = DNSServer()
        server.listenMulticast(on: group, using: [interface]) { envelope in
            let msg = envelope.data
            XCTAssertEqual(msg.questions.count, 1)
            return Message.Answer(
                message: msg,
                with: [Record.PTR(
                        sourceDomainName: msg.questions[0].labels,
                        targetDomainName: expectedServer.dnsLabels,
                        ttl: 10)])
        }

        // Do PTR service request
        let exp = XCTestExpectation(description: "Expecting mDNS reply")
        let client = try DNSClient.connectMulticast(on: group, using: interface).wait()
        _ = client.sendQuery(forHost: service, type: .ptr) { msg, loop in
            XCTAssertEqual(msg.answers.count, 1)
            exp.fulfill()
            return loop.makeSucceededFuture(.continue)
        }
        wait(for: [exp], timeout: 5)
    }
}
