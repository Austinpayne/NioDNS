import NIO

extension DNSClient {
    /// Request A records
    ///
    /// - parameters:
    ///     - host: The hostname address to request the records from
    ///     - port: The port to use
    /// - returns: A future of SocketAddresses
    public func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        let result = self.sendQuery(forHost: host, type: .a)

        return result.map { message in
            return message.answers.compactMap { answer in
                guard case .a(let record) = answer else {
                    return nil
                }

                return try? record.resource.address.socketAddress(port: port)
            }
        }
    }

    /// Request AAAA records
    ///
    /// - parameters:
    ///     - host: The hostname address to request the records from
    ///     - port: The port to use
    /// - returns: A future of SocketAddresses
    public func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        let result = self.sendQuery(forHost: host, type: .aaaa)

        return result.map { message in
            return message.answers.compactMap { answer in
                guard case .aaaa(let record) = answer else {
                    return nil
                }

                return try? record.resource.address.socketAddress(port: port)
            }
        }
    }

    /// Cancel all queries
    public func cancelQueries() {
        for (id, query) in dnsCache.messageCache {
            dnsCache.messageCache[id] = nil
            query.promise.fail(CancelError())
        }
    }

    /// Send a question to the dns host
    ///
    /// - parameters:
    ///     - address: The hostname address to request a certain resource from
    ///     - type: The resource you want to request
    ///     - additionalOptions: Additional message options
    /// - returns: A future with the response message
    public func sendQuery(forHost address: String, type: DNSResourceType, additionalOptions: MessageOptions? = nil, callback: @escaping QueryCallback = defaultCallback) -> EventLoopFuture<Message> {
        messageID = messageID &+ 1

        var options: MessageOptions = [.standardQuery, .recursionDesired]
        if let additionalOptions = additionalOptions {
            options.insert(additionalOptions)
        }

        let header = DNSMessageHeader(id: messageID, options: options, questionCount: 1, answerCount: 0, authorityCount: 0, additionalRecordCount: 0)
        let labels = address.dnsLabels
        let question = QuestionSection(labels: labels, type: type, questionClass: .internet)
        let message = Message(header: header, questions: [question], answers: [], authorities: [], additionalData: [])

        return send(message, callback: callback)
    }

    func send(_ message: Message, to address: SocketAddress? = nil, callback: @escaping QueryCallback = defaultCallback) -> EventLoopFuture<Message> {
        let promise: EventLoopPromise<Message> = loop.makePromise()
        dnsCache.messageCache[message.header.id] = SentQuery(message: message, promise: promise, callback: callback)
        
        channel.writeAndFlush(message, promise: nil)
        
        struct DNSTimeoutError: Error {}
        
        loop.scheduleTask(in: .seconds(30)) {
            promise.fail(DNSTimeoutError())
        }

        return promise.futureResult
    }

    /// Request SRV records from a host
    ///
    /// - parameters:
    ///     - host: Hostname to get the records from
    /// - returns: A future with the resource record
    public func getSRVRecords(from host: String) -> EventLoopFuture<[ResourceRecord<SRVRecord>]> {
        return self.sendQuery(forHost: host, type: .srv).map { message in
            return message.answers.compactMap { answer in
                guard case .srv(let record) = answer else {
                    return nil
                }

                return record
            }
        }
    }
}
