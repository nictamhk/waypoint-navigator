import Foundation

/// Minimal GPX track parser for replay fixtures. Reads <trkpt lat lon>, <time>, and <speed> when present;
/// derives speed and course from consecutive points otherwise.
public enum GPXParser {
    public enum Failure: Error, Equatable {
        case malformed(String)
        case noTrackPoints
    }

    public static func parse(_ data: Data, defaultInterval: TimeInterval = 1, accuracy: Double = 5) throws -> [LocationFix] {
        let delegate = GPXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw Failure.malformed(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        let raw = delegate.points
        guard !raw.isEmpty else { throw Failure.noTrackPoints }

        let base = Date(timeIntervalSinceReferenceDate: 0)
        let times = raw.enumerated().map { index, point in
            point.time ?? base.addingTimeInterval(Double(index) * defaultInterval)
        }
        let coordinates = raw.map { GeoCoordinate(latitude: $0.lat, longitude: $0.lon) }

        var speeds = [Double?](repeating: nil, count: raw.count)
        var courses = [Double?](repeating: nil, count: raw.count)
        for i in 1..<max(raw.count, 1) {
            let dt = times[i].timeIntervalSince(times[i - 1])
            if dt > 0 { speeds[i] = coordinates[i - 1].distance(to: coordinates[i]) / dt }
            courses[i] = coordinates[i - 1].bearing(to: coordinates[i])
        }
        if raw.count > 1 {
            speeds[0] = speeds[1]
            courses[0] = courses[1]
        }

        return raw.indices.map { i in
            LocationFix(coordinate: coordinates[i], timestamp: times[i], horizontalAccuracy: accuracy,
                        speed: raw[i].speed ?? speeds[i], course: courses[i])
        }
    }
}

private struct RawPoint {
    var lat: Double
    var lon: Double
    var time: Date?
    var speed: Double?
}

private final class GPXDelegate: NSObject, XMLParserDelegate {
    var points: [RawPoint] = []
    private var current: RawPoint?
    private var text = ""
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "trkpt",
           let lat = Double(attributeDict["lat"] ?? ""), let lon = Double(attributeDict["lon"] ?? "") {
            current = RawPoint(lat: lat, lon: lon)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "time":
            current?.time = fractional.date(from: value) ?? plain.date(from: value)
        case "speed":
            current?.speed = Double(value)
        case "trkpt":
            if let point = current { points.append(point) }
            current = nil
        default:
            break
        }
    }
}
