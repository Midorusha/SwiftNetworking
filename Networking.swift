//
//  Network.swift
//  Playground
//
//  Created by Christopher Davis on 1/30/16.
//  Copyright © 2016 Christopher Davis. All rights reserved.
//

import Foundation

enum HTTPVerb: String {
    case POST   = "POST"
    case GET    = "GET"
    case PUT    = "PUT"
    case DELETE = "DELETE"
}

enum ClearCallQueue {
    case None
    case Web
    case BLE
    case Both
}

typealias networkCompletion = ((response: NetworkResponse?, error: NSError?) -> NetworkRequest?)
typealias clusterCompletion = (responses: [(NetworkResponse?, NSError?)]?) -> NetworkRequest?

protocol NetworkResponse {
    var returningQueue: dispatch_queue_t? { get set }
    func populateWithData(data: NSData)
}

protocol JsonResponse: NetworkResponse {
    func populateWithJSON(json: [String : AnyObject?]?)
}

extension JsonResponse {
    func populateWithData(data: NSData) {
        do {
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions.MutableContainers) as? Dictionary<String, AnyObject>
            populateWithJSON(json)
        } catch {
            // TO THROW OR NOT TO THRO
            print(error)
        }
    }
}

protocol DataResponse: NetworkResponse {
    func populateWithData(data: NSData?)
}

protocol XMLResponse: NetworkResponse {
    func populateWithXML(data: NSData?)
}

extension XMLResponse {
    func populateWithData(data: NSData) {
        populateWithXML(data)
    }
}

protocol BLEResponse: NetworkResponse {
    func populateWithCharacteristic(data: NSData?)
}


protocol NetworkRequest {
    var clearQueue: ClearCallQueue { get }
    var timeStamp: Double { get }
    func call(node: NetworkNode)
}

func ==(lhs: NetworkRequest?, rhs: NetworkRequest?) -> Bool {
    return lhs?.timeStamp == rhs?.timeStamp
}

class WebRequest: NSMutableURLRequest, NetworkRequest {
    var clearQueue: ClearCallQueue = .None
    var timeStamp: Double = NSDate().timeIntervalSince1970
    
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
    
    func call(node: NetworkNode) {
        NetworkCall.call(node)
    }
}

class BLERequest: NetworkRequest {
    var clearQueue: ClearCallQueue = .None
    var timeStamp: Double = NSDate().timeIntervalSince1970
    
    func call(node: NetworkNode) {
        //TODO
    }
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
        request?.call(self)
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

struct BLECall {
    static func call(node: NetworkNode) {
        // so who should keep track of the peripheral....
        // and the characteristic....
    }
}

struct Locker {
    static var lockingNode: NetworkRequest?
    static func enterLock(request: NetworkRequest) -> Bool {
        if lockingNode == nil {
            var shouldLock = false
            switch (request.clearQueue) {
            case .Both:
                fallthrough
            case .Web where request is WebRequest:
                fallthrough
            case .BLE where request is BLERequest:
                shouldLock = true
            default:
                break
            }
            if shouldLock {
                lockingNode = request
            }
            return true
        }
        return false
    }
    
    static func exitLock(request: NetworkRequest) -> Bool {
        if lockingNode == request {
            lockingNode = nil
        }
        return (lockingNode == nil)
    }
}

struct NetworkCall {
    static func call(node: NetworkNode) {
        guard let request = node.request as? WebRequest
            where !Locker.enterLock(request) else {
            return
        }
        NSURLSession.sharedSession().dataTaskWithRequest(request) {
            (data: NSData?, response: NSURLResponse?, error: NSError?) -> Void in
            defer {
                if Locker.exitLock(request) {
                    dispatch_async(node.response?.returningQueue ?? dispatch_get_main_queue(), {
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
                node.response?.populateWithData(data)
            }
        }.resume()
    }
}

func foo() {
    struct R: NetworkResponse {
        var returningQueue: dispatch_queue_t?
        func populateWithData(data: NSData){}
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
