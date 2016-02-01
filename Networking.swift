//
//  Network.swift
//  Playground
//
//  Created by Christopher Davis on 1/30/16.
//  Copyright © 2016 Christopher Davis. All rights reserved.
//

import Foundation

enum ThreadEnum: Equatable {
    case Main
    case Ambiguous
    case Custom(dispatch_queue_t)
}

enum HTTPVerb: String {
    case POST   = "POST"
    case GET    = "GET"
    case PUT    = "PUT"
    case DELETE = "DELETE"
}

func ==(lhs: ThreadEnum, rhs: ThreadEnum) -> Bool {
    switch(lhs, rhs) {
    case (.Main, .Main):
        fallthrough
    case (.Ambiguous, .Ambiguous):
        return true
    default:
        return false
    }
}

typealias networkCompletion = ((response: NetworkResponse?, error: NSError?) -> NetworkRequest?)
protocol NetworkResponse {
    //var returningThread: ThreadEnum { get }
    var returningQueue: dispatch_queue_t? { get set }
    
}

protocol JsonResponse: NetworkResponse {
    func populateWithJSON(json: [String : AnyObject?]?)
}

protocol DataResponse: NetworkResponse {
    func populateWithData(data: NSData?)
}

class NetworkRequest: NSMutableURLRequest {
    init?(_ verb: HTTPVerb, _ urlString: String) {
        super.init(coder: NSCoder())
        guard let url = NSURL(string: urlString) else {
            return nil
        }
        URL = url
        HTTPMethod = verb.rawValue
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
}

class NetworkNode {
    var request: NetworkRequest
    var response: NetworkResponse?
    var completion: networkCompletion?
    var nextNetworkNode: NetworkNode?
    var prevNetworkNode: NetworkNode?
    
    init(request: NetworkRequest, response: NetworkResponse?, completion: networkCompletion?) {
        self.request = request
        self.response = response
        self.completion = completion
        nextNetworkNode = nil
        prevNetworkNode = nil
    }
    
    func andThen(request: NetworkRequest, response: NetworkResponse? = nil, completion: networkCompletion?) -> NetworkNode {
        return andThen(NetworkNode(request: request, response: response, completion: completion))
    }
    
    func andThen(nextNode: NetworkNode) -> NetworkNode {
        nextNetworkNode = nextNode
        nextNode.prevNetworkNode = self
        return nextNode
    }
    
    func start() {
        var cur = self
        while(cur.prevNetworkNode != nil) {
            cur = prevNetworkNode!
        }
        NetworkCall.call(cur)
    }
}

class NetworkCall {
    static func call(node: NetworkNode) {
        NSURLSession.sharedSession().dataTaskWithRequest(node.request) {
            (data: NSData?, response: NSURLResponse?, error: NSError?) -> Void in
            defer {
                if let returningQueue = node.response?.returningQueue {
                    dispatch_async(returningQueue, {
                        () -> Void in
                        if let nextRequest = node.completion?(response: node.response, error: error) {
                            node.nextNetworkNode?.request = nextRequest
                        }
                        if let nextNode = node.nextNetworkNode {
                            call(nextNode)
                        }
                    })
                }
            }
            if let data = data {
                if let responseObject = node.response as? JsonResponse {
                    do {
                        let json = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions.MutableContainers) as? Dictionary<String, AnyObject>
                        responseObject.populateWithJSON(json)
                    } catch {
                        print(error)
                    }
                }
                else if let responseObject = node.response as? DataResponse {
                    responseObject.populateWithData(data)
                }
            }
        }.resume()
    }
}

func foo() {
    struct R: NetworkResponse {
        var returningQueue: dispatch_queue_t? = dispatch_get_main_queue()
    }
    
    let r = NetworkRequest(.GET, "google.com")
    
    NetworkNode(request: r!, response: R()) {
        (response, error) -> NetworkRequest? in
        return nil
    }.andThen(r!) {
        (response, error) -> NetworkRequest? in
        return nil
    }.start()
}
