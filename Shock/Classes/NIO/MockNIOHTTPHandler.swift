//
//  MockNIOHTTPHandler.swift
//  Shock
//
//  Created by Antonio Strijdom on 30/09/2020.
//

import Foundation
import NIO
import NIOHTTP1

class MockNIOHTTPHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let router: MockNIOHTTPRouter
    private var httpRequest: HTTPRequestHead?
    private var handlerRequest: MockNIOHTTPRequest?
    
    var middleware: [Middleware]
    var notFoundHandler: HandlerClosure?
    
    init(router: MockNIOHTTPRouter, middleware: [Middleware], notFoundHandler: HandlerClosure?) {
        self.router = router
        self.middleware = middleware
        self.notFoundHandler = notFoundHandler
    }
    
    private func httpResponseHeadForRequestHead(_ request: HTTPRequestHead, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) -> HTTPResponseHead {
        HTTPResponseHead(version: request.version, status: status, headers: headers)
    }
    
    private func completeResponse(_ context: ChannelHandlerContext, trailers: HTTPHeaders?) {
        _ = context.writeAndFlush(self.wrapOutboundOut(.end(trailers)))
    }
    
    private func stringForHTTPMethod(_ method: HTTPMethod) -> String {
        switch method {
        case .HEAD:
            return "HEAD"
        case .GET:
            return "GET"
        case .POST:
            return "POST"
        case .PUT:
            return "PUT"
        case .PATCH:
            return "PATCH"
        case .DELETE:
            return "DELETE"
        default:
            return ""
        }
    }
    
    private func requestForHTTPRequestHead(_ request: HTTPRequestHead, eventLoop: EventLoop) -> MockNIOHTTPRequest? {
        guard let url = URLComponents(string: request.uri) else { return nil }
        let path = url.path
        let method = stringForHTTPMethod(request.method)
        let headers = request.headers.reduce(into: [String: String](), { $0[$1.0.lowercased()] = $1.1 })
        let body = [UInt8]()
        let address = url.host
        var params = [String: String]()
        var queryParams =  [(String, String)]()
        if let queryItems = url.queryItems {
            params = queryItems.reduce(into: [String: String](), { $0[$1.name] = $1.value })
            queryParams = queryItems.reduce(into: [(String, String)](), { $0.append(($1.name, $1.value ?? "")) })
        }
        
        return MockNIOHTTPRequest(eventLoop: eventLoop,
                                  path: path,
                                  queryParams: queryParams,
                                  method: method,
                                  headers: headers,
                                  body: body,
                                  address: address,
                                  params: params)
    }
    
    private func handleResponse(forResponseContext middlewareContext: MiddlewareContext, in     channelHandlerContext: ChannelHandlerContext) {
        
        // TODO
        
        let headers = middlewareContext.responseContext.headers
        let body = middlewareContext.responseContext.responseBody
        let statusCode = middlewareContext.responseContext.statusCode
        
        // Write head
        guard let requestHead = self.httpRequest else { return }
        let responseHead = httpResponseHeadForRequestHead(requestHead,
                                                          status: HTTPResponseStatus(statusCode: statusCode),
                                                          headers: HTTPHeaders(headers.map { ($0.key, $0.value) }))
        let outboundHeadData = self.wrapOutboundOut(.head(responseHead))
        channelHandlerContext.writeAndFlush(outboundHeadData, promise: nil)
        
        // Write body
        if let body = body {
            let buffer = ByteBuffer(bytes: body)
            let outboundBodyData = self.wrapOutboundOut(.body(.byteBuffer(buffer)))
            channelHandlerContext.writeAndFlush(outboundBodyData, promise: nil)
        }
        
        completeResponse(channelHandlerContext, trailers: nil)
    }
    
    private func writeAndFlushHeaderResponse(status: HTTPResponseStatus, for request: HTTPRequestHead, in context: ChannelHandlerContext) {
        _ = context.writeAndFlush(self.wrapOutboundOut(.head(httpResponseHeadForRequestHead(request, status: status))))
    }
}
    
// MARK: ChannelInboundHandler

extension MockNIOHTTPHandler: ChannelInboundHandler {
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        
        switch reqPart {
        case .head(let request):
            self.httpRequest = request
            self.handlerRequest = requestForHTTPRequestHead(request, eventLoop: context.eventLoop)
        case .body(buffer: var bytes):
            guard var handlerRequest = self.handlerRequest else { return }
            handlerRequest.body += bytes.readBytes(length: bytes.readableBytes) ?? []
            self.handlerRequest = handlerRequest
        case .end(_):
            guard let request = self.httpRequest else { return }
            guard let handlerRequest = self.handlerRequest else { return }
            
            let responder = MiddlwareResponder(middleware: middleware, notFoundHandler: notFoundHandler)
            responder.respond(to: handlerRequest).whenSuccess { (responseContext) in
                if let finalContext = responseContext {
                    self.handleResponse(forResponseContext: finalContext, in: context)
                }
            }

            self.httpRequest = nil
            self.handlerRequest = nil
        }
    }
}

// MARK: MiddlewareResponder

struct MiddlwareResponder {
    
    let middleware: [Middleware]
    let notFoundHandler: HandlerClosure?
    
    let middlewareService = ThreadSpecificVariable<MiddlewareService>()
    private func makeMiddlewareService(for eventLoop: EventLoop) -> MiddlewareService {
        if let existingService = middlewareService.currentValue {
            return existingService
        }
        
        let newService = MiddlewareService(middleware: middleware, notFoundHandler: notFoundHandler)
        middlewareService.currentValue = newService
        return newService
    }
    
    func respond(to request: MockNIOHTTPRequest) -> EventLoopFuture<MiddlewareContext?> {
        let middlewareService = makeMiddlewareService(for: request.eventLoop)
        return middlewareService.executeAll(forRequest: request)
    }
}
