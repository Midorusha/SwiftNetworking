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
typealias clusterCompletion = (responses: [(NetworkResponse?, NSError?)]?) -> NetworkRequest?

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

protocol BLEResponse: NetworkResponse {
    func populateWithCharacteristic(data: NSData?)
}


protocol NetworkRequest {
    var priority: Int { get set }
}

class WebRequest: NSMutableURLRequest, NetworkRequest {
    var priority: Int = 0
    
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

class BLERequest: NetworkRequest {
    var priority: Int = 0
    
}

class NetworkNode {
    var request: NetworkRequest?
    var response: NetworkResponse?
    var completion: networkCompletion?
    var nextNetworkNode: NetworkNode?
    var prevNetworkNode: NetworkNode?
    
    init() {
        nextNetworkNode = nil
        prevNetworkNode = nil
    }
    
    convenience init(request: NetworkRequest?, response: NetworkResponse?, completion: networkCompletion?) {
        self.init()
        self.request = request
        self.response = response
        self.completion = completion
    }
    
    func andThen(request: NetworkRequest? = nil, response: NetworkResponse? = nil, completion: networkCompletion?) -> NetworkNode {
        return andThen(NetworkNode(request: request, response: response, completion: completion))
    }
    
    func andThen(requests: (NetworkRequest, NetworkResponse?)..., completion: clusterCompletion) -> NetworkNode {
        return andThen(ClusterNetworkNode(requests: requests, completion: completion))
    }
    
    func andThen(nextNode: NetworkNode) -> NetworkNode {
        nextNetworkNode = nextNode
        nextNode.prevNetworkNode = self
        return nextNode
    }
    
    final func start() {
        var cur = self
        while(cur.prevNetworkNode != nil) {
            cur = prevNetworkNode!
        }
        cur.call()
    }
    
    func call() {
        if request is WebRequest {
            NetworkCall.call(self)
        }
        else if request is BLERequest {
            //TODO BLECall.call(cur)
        }
    }
}

class ClusterNetworkNode: NetworkNode {
    var fullCompletion: clusterCompletion?
    var callsCompleted: Int = 0
    var childNetworkNodes: [NetworkNode] = []
    var completionTuples: [(NetworkResponse?, NSError?)] = []
    override var request: NetworkRequest? {
        willSet {
            fatalError("NO")
        }
    }
    
    override var completion: networkCompletion? {
        willSet {
            fatalError("NO")
        }
    }
    
    init(requests: [(NetworkRequest, NetworkResponse?)], completion: clusterCompletion?) {
        fullCompletion = completion
        for request in requests {
            childNetworkNodes.append(NetworkNode(request: request.0, response: request.1, completion: nil))
        }
        super.init()
    }
    
    override func call() {
        let fauxCompletion = {
            [weak self] (response: NetworkResponse?, error: NSError?) -> NetworkRequest? in
                guard let this = self else {
                    return nil
                }
                this.completionTuples.append((response, error))
                this.callsCompleted += 1
                if this.childNetworkNodes.count == this.callsCompleted {
                    if let nextRequest = this.fullCompletion?(responses: this.completionTuples) {
                        this.nextNetworkNode?.request = nextRequest
                    }
                    if let nextNode = this.nextNetworkNode {
                        nextNode.call()
                    }
                }
                return nil
            }
        for node in childNetworkNodes {
            node.completion = fauxCompletion
            node.call()
        }
    }
}

class NetworkCall {
    private static var outGoingPriorityRequest: WebRequest?
    static func call(node: NetworkNode) {
        guard let request = node.request as? WebRequest else {
            return
        }
        
        if request.priority >= outGoingPriorityRequest?.priority {
            outGoingPriorityRequest = request
        }

        NSURLSession.sharedSession().dataTaskWithRequest(request) {
            (data: NSData?, response: NSURLResponse?, error: NSError?) -> Void in
            defer {
                if let returningQueue = node.response?.returningQueue
                    where request.priority >= outGoingPriorityRequest?.priority {
                    outGoingPriorityRequest = nil
                    dispatch_async(returningQueue, {
                        () -> Void in
                        if let nextRequest = node.completion?(response: node.response, error: error) {
                            node.nextNetworkNode?.request = nextRequest
                        }
                        if var nextNode = node.nextNetworkNode {
                            nextNode.call()
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
    
    let r = WebRequest(.GET, "google.com")
    
    NetworkNode(request: r!, response: R()) {
        (response, error) -> NetworkRequest? in
        return nil
    }.andThen(r!) {
        (response, error) -> NetworkRequest? in
        return nil
    }.start()
    
    NetworkNode(request: r!, response: R()) {
        (response, error) -> NetworkRequest? in
        return r
    }.andThen(response: R()) {
        (response, error) -> NetworkRequest? in
        return nil
    }.andThen(r!) {
        (response, error) -> NetworkRequest? in
        return nil
    }.andThen {
        (response, error) -> NetworkRequest? in
        return nil
    }.andThen((r!, R()), (r!, nil)) {
        (responses: [(NetworkResponse?, NSError?)]?) -> NetworkRequest? in
            
        return nil
    }.start()
}
