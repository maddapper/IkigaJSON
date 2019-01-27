import Foundation
import NIO

public struct JSONArray: ExpressibleByArrayLiteral {
    var jsonBuffer: ByteBuffer
    var description: JSONDescription
    
    public var data: Data {
        return jsonBuffer.withUnsafeReadableBytes { buffer in
            return Data(buffer: buffer.bindMemory(to: UInt8.self))
        }
    }
    
    public var string: String! {
        return String(data: data, encoding: .utf8)
    }
    
    public init(buffer: ByteBuffer) throws {
        self.jsonBuffer = buffer
        
        self.description = try buffer.withUnsafeReadableBytes { buffer in
            let buffer = buffer.bindMemory(to: UInt8.self)
            return try JSONParser.scanValue(fromPointer: buffer.baseAddress!, count: buffer.count)
        }
        
        guard description.topLevelType == .array else {
            throw JSONError.expectedObject
        }
    }
    
    public init() {
        var buffer = allocator.buffer(capacity: 4_096)
        buffer.write(integer: UInt8.squareLeft)
        buffer.write(integer: UInt8.squareRight)
        self.jsonBuffer = buffer
        
        var description = JSONDescription()
        let partialObject = description.describeArray(atJSONOffset: 0)
        let result = _ArrayObjectDescription(valueCount: 0, jsonByteCount: 2)
        description.complete(partialObject, withResult: result)
        
        self.description = description
    }
    
    public init(arrayLiteral elements: JSONValue...) {
        self.init()
        
        for element in elements {
            self.append(element)
        }
    }
    
    public var count: Int {
        return description.arrayObjectCount()
    }
    
    internal init(buffer: ByteBuffer, description: JSONDescription) {
        self.jsonBuffer = buffer
        self.description = description
    }
    
    public mutating func append(_ value: JSONValue) {
        let oldSize = jsonBuffer.writerIndex
        // Before `]`
        jsonBuffer.moveWriterIndex(to: jsonBuffer.writerIndex &- 1)
        
        if count > 0 {
            jsonBuffer.write(integer: UInt8.comma)
        }
        
        let valueJSONOffset = Int32(jsonBuffer.writerIndex)
        let indexOffset = description.buffer.writerIndex
        
        defer {
            jsonBuffer.write(integer: UInt8.squareRight)
            let extraSize = jsonBuffer.writerIndex - oldSize
            description.incrementArrayCount(jsonSize: Int32(extraSize), atIndexOffset: indexOffset)
        }
        
        func write(_ string: String) -> Bounds {
            jsonBuffer.write(string: string)
            let length = Int32(jsonBuffer.writerIndex) - valueJSONOffset
            return Bounds(offset: valueJSONOffset, length: length)
        }
        
        switch value {
        case let value as String:
            let (escaped, bytes) = value.escaped
            jsonBuffer.write(integer: UInt8.quote)
            jsonBuffer.write(bytes: bytes)
            jsonBuffer.write(integer: UInt8.quote)
            let length = Int32(jsonBuffer.writerIndex) - valueJSONOffset
            let bounds = Bounds(offset: valueJSONOffset, length: length)
            description.describeString(at: bounds, escaped: escaped)
        case let value as Int:
            description.describeNumber(at: write(String(value)), floatingPoint: false)
        case let value as Double:
            description.describeNumber(at: write(String(value)), floatingPoint: true)
        case let value as Bool:
            if value {
                jsonBuffer.write(staticString: boolTrue)
                description.describeTrue(atJSONOffset: valueJSONOffset)
            } else {
                jsonBuffer.write(staticString: boolFalse)
                description.describeFalse(atJSONOffset: valueJSONOffset)
            }
        case is NSNull:
            jsonBuffer.write(staticString: nullBytes)
            description.describeNull(atJSONOffset: valueJSONOffset)
        case var value as JSONArray:
            jsonBuffer.write(buffer: &value.jsonBuffer)
            description.addNestedDescription(value.description, at: valueJSONOffset)
        case var value as JSONObject:
            jsonBuffer.write(buffer: &value.jsonBuffer)
            description.addNestedDescription(value.description, at: valueJSONOffset)
        default:
            fatalError("Unsupported JSON value \(value)")
        }
    }

//    public mutating func remove(at index: Int) {
//        _checkBounds(index)
//
//        let indexStart = reader.offset(forIndex: index)
//        let bounds = reader.dataBounds(atIndexOffset: indexStart)
//        description.removeArrayDescription(atIndex: indexStart, jsonOffset: bounds.offset, removedLength: bounds.length)
//    }

    private func _checkBounds(_ index: Int) {
        assert(index <= description.arrayObjectCount(), "Index out of bounds. \(index) > \(count)")
        assert(index >= 0, "Negative index requested for JSONArray.")
    }
    
    private func value(at index: Int, in json: UnsafePointer<UInt8>) -> JSONValue {
        _checkBounds(index)
        
        // Array descriptions are 17 bytes
        var offset = Constants.firstArrayObjectChildOffset
        
        for _ in 0..<index {
            description.skipIndex(atOffset: &offset)
        }
        
        let type = description.type(atOffset: offset)
        
        switch type {
        case .object, .array:
            let indexLength = description.indexLength(atOffset: offset)
            let jsonBounds = description.dataBounds(atIndexOffset: offset)
            
            var subDescription = description.slice(from: offset, length: indexLength)
            subDescription.advanceAllJSONOffsets(by: -jsonBounds.offset)
            let subBuffer = jsonBuffer.getSlice(at: Int(jsonBounds.offset), length: Int(jsonBounds.length))!
            
            if type == .object {
                return JSONObject(buffer: subBuffer, description: subDescription)
            } else {
                return JSONArray(buffer: subBuffer, description: subDescription)
            }
        case .boolTrue:
            return true
        case .boolFalse:
            return false
        case .string:
            return description.dataBounds(atIndexOffset: offset).makeString(from: json, escaping: false, unicode: true)!
        case .stringWithEscaping:
            return description.dataBounds(atIndexOffset: offset).makeString(from: json, escaping: true, unicode: true)!
        case .integer:
            return description.dataBounds(atIndexOffset: offset).makeInt(from: json)!
        case .floatingNumber:
            return description.dataBounds(atIndexOffset: offset).makeDouble(from: json, floating: true)!
        case .null:
            return NSNull()
        }
    }

    public subscript(index: Int) -> JSONValue {
        get {
            return jsonBuffer.withBytePointer { pointer in
                value(at: index, in: pointer)
            }
        }
        set {
            _checkBounds(index)
            
            // Array descriptions are 17 bytes
            var offset = Constants.firstArrayObjectChildOffset
            
            for _ in 0..<index {
                description.skipIndex(atOffset: &offset)
            }

            description.rewrite(buffer: &jsonBuffer, to: newValue, at: offset)
        }
    }
}

extension String {
    internal var escaped: (Bool, [UInt8]) {
        var escaped = false
        
        var characters = [UInt8](self.utf8)
        
        var i = characters.count
        nextByte: while i > 0 {
            i = i &- 1
            
            switch characters[i] {
            case .newLine:
                escaped = true
                characters[i] = .backslash
                characters.insert(.n, at: i &+ 1)
            case .carriageReturn:
                escaped = true
                characters[i] = .backslash
                characters.insert(.r, at: i &+ 1)
            case .quote:
                escaped = true
                characters.insert(.backslash, at: i)
            case .tab:
                escaped = true
                characters[i] = .backslash
                characters.insert(.t, at: i &+ 1)
            case .backslash:
                escaped = true
                characters.insert(.backslash, at: i &+ 1)
            default:
                continue
            }
        }
        
        return (escaped, characters)
    }
}