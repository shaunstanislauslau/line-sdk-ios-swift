//
//  Message.swift
//
//  Copyright (c) 2016-present, LINE Corporation. All rights reserved.
//
//  You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
//  copy and distribute this software in source code or binary form for use
//  in connection with the web services and APIs provided by LINE Corporation.
//
//  As with any software that integrates with the LINE Corporation platform, your use of this software
//  is subject to the LINE Developers Agreement [http://terms2.line.me/LINE_Developers_Agreement].
//  This copyright notice shall be included in all copies or substantial portions of the software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation

public enum Message: Codable {
    
    case text(TextMessage)
    case image(ImageMessage)
    case video(VideoMessage)
    
    case unknown
    
    enum CodingKeys: String, CodingKey {
        case type
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case TextMessage.typeName:
            let message = try TextMessage(from: decoder)
            self = .text(message)
        case ImageMessage.typeName:
            let message = try ImageMessage(from: decoder)
            self = .image(message)
        case VideoMessage.typeName:
            let message = try VideoMessage(from: decoder)
            self = .video(message)
        default:
            self = .unknown
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let message):
            try message.encode(to: encoder)
        case .image(let message):
            try message.encode(to: encoder)
        case .video(let message):
            try message.encode(to: encoder)
        case .unknown:
            Log.assertionFailure("Cannot encode unknown message type.")
        }
    }
    
    public var asTextMessage: TextMessage? {
        if case .text(let m) = self { return m }
        return nil
    }
    
    public var asImageMessage: ImageMessage? {
        if case .image(let m) = self { return m }
        return nil
    }
    
    public var asVideoMessage: VideoMessage? {
        if case .video(let m) = self { return m }
        return nil
    }
}
