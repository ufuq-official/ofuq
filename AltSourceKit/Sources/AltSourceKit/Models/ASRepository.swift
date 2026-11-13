//
//  Repository.swift
//  Feather
//
//  Created by Lakhan Lothiyi on 19/04/2025.
//

import Foundation
import SwiftUI

// Evidently, every repo is silly, they all have slightly different formats :c
// only altstore repo (ofc) has the correct format.
// we're going to use a defensive approach and try to parse many repos.

// MARK: - Repository

public struct ASRepository: Sendable, Decodable, Hashable, Identifiable {
    // Core data
    public var id: String?
    public var name: String?

    // descriptive fields
    public var subtitle: String?
    public var description: String?
    public var website: URL?
    public var iconURL: URL?
    public var headerURL: URL?
    public var tintColor: Color?

    // special fields
    public var patreonURL: URL?
    public var userInfo: UserInfo?

    // apps, news etc.
    public var apps: [App]
    public var featuredApps: [App.ID]?
    public var news: [News]?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.lenientString(forKey: .id)
        self.name = container.lenientString(forKey: .name)

        self.subtitle = container.lenientString(forKey: .subtitle)
        self.description = container.lenientString(forKey: .description)
        // Ofuq: optional fields that are malformed are left out instead of rejecting the whole source.
        self.website = container.lenientURL(forKey: .website)
        self.iconURL = container.lenientURL(forKey: .iconURL)
        self.headerURL = container.lenientURL(forKey: .headerURL)
        self.tintColor = container.lenient(Color.self, forKey: .tintColor)

        let patreonString = container.lenientString(forKey: .patreonURL)
        
        // another case of inconsistent altstore stuff
        if
            let string = patreonString,
            !string.isEmpty,
            let url = URL(string: string)
        {
            self.patreonURL = url
        } else {
            self.patreonURL = nil
        }

        self.userInfo = container.lenient(UserInfo.self, forKey: .userInfo)

        // Ofuq: an app that cannot be read is left out, the other apps of the source still load.
        let decodedApps = try container.decodeIfPresent(ASLossyArray<App>.self, forKey: .apps)
        guard
            let apps = decodedApps?.elements,
            !apps.isEmpty
        else {
            // Every app failed: say why, an AltStore PAL source keeps its own message.
            let errors = decodedApps?.errors ?? []
            if let palError = errors.first(where: { ($0 as NSError).code == 112789 }) {
                throw palError
            }
            if let firstError = errors.first {
                throw firstError
            }
            throw NSError(
                domain: "FeatherSources",
                code: 44521,
                userInfo: [
                    NSLocalizedDescriptionKey: "This source does not contain any apps."
                ]
            )
        }
        
        self.apps = apps
        self.featuredApps = container.lossyArray(App.ID.self, forKey: .featuredApps) ?? []
        self.news = container.lossyArray(News.self, forKey: .news) ?? []
    }

    public enum CodingKeys: String, CodingKey {
        case id = "identifier"
        case name,
             subtitle,
             description,
             website,
             patreonURL,
             userInfo,
             iconURL,
             headerURL,
             tintColor,
             apps,
             featuredApps,
             news
    }
    
    public var currentIconURL: URL? {
        iconURL ?? apps.first?.iconURL
    }

    //    func encode(to encoder: any Encoder) throws {
    //        var container = encoder.container(keyedBy: CodingKeys.self)
    //        try container.encode(id, forKey: .id)
    //        try container.encode(name, forKey: .name)
    //
    //        try container.encodeIfPresent(subtitle, forKey: .subtitle)
    //        try container.encodeIfPresent(description, forKey: .description)
    //        try container.encodeIfPresent(website, forKey: .website)
    //
    //        try container.encodeIfPresent(patreonURL, forKey: .patreonURL)
    //        try container.encodeIfPresent(userInfo, forKey: .userInfo)
    //
    //        try container.encodeIfPresent(apps, forKey: .apps)
    //        try container.encodeIfPresent(featuredApps, forKey: .featuredApps)
    //        try container.encodeIfPresent(news, forKey: .news)
    //    }
}

// MARK: - App

extension ASRepository {
    public struct App: Sendable, Decodable, Hashable, Identifiable {
        public var uuid = UUID()
        
        public var id: String?
        public var name: String?

        public var subtitle: String?
        public var description: String?

        public var developer: String?

        public var versions: [Version]?

        public var version: String?

        public var versionDate: DateParsed?

        public var versionDescription: String?

        public var downloadURL: URL?

        public var localizedDescription: String?

        public var iconURL: URL?

        public var tintColor: Color?

        public var size: Int64?

        public var category: String?

        public var beta: Bool?

        public var permissions: [Permission]?

        public var appPermissions: AppPermissions?

        public var screenshots: Screenshots?

        public var screenshotURLs: [URL]?

        /// How many times the app was downloaded, when the source gives it
        /// (`downloads`, `downloadCount` or `downloadsCount`). AltStore sources do not have it.
        public var downloads: Int?

        public var marketplaceID: String?

        public struct Screenshots: Decodable, Hashable, Sendable {
            public var iPhone: [URL]?
            public var iPad: [URL]?

            public init(from decoder: any Decoder) throws {
                // theres a bunch of ways this shit can be formatted
                // 1. an array of urls (strings)
                // 2. an array of dictionaries that contain url, width, height.
                // 3. a mix of 1 and 2, having urls or dictionaries
                // 4. a dictionary with properties for iphone and ipad, which are arrays of above types

                // 4.
                if
                    let container = try? decoder.container(keyedBy: CodingKeys.self),
                    container.contains(.iPhone) || container.contains(.iPad)
                {
                    let iPhone: [Item]? = try? container.decodeIfPresent([Item].self, forKey: .iPhone)
                    let iPad: [Item]? = try? container.decodeIfPresent([Item].self, forKey: .iPad)
                    self.iPhone = (iPhone ?? []).compactMap { $0.url }
                    self.iPad = (iPad ?? []).compactMap { $0.url }
                    return
                }

                // 1, 2 and 3: a plain list is for the iPhone.
                let single = try decoder.singleValueContainer()
                let items: [Item] = (try? single.decode([Item].self)) ?? []
                self.iPhone = items.compactMap { $0.url }
                self.iPad = []
            }

            public enum CodingKeys: String, CodingKey {
                case iPhone = "iphone"
                case iPad = "ipad"
                case url
            }

            /// One screenshot: either a URL string, or a dictionary with `imageURL` (or `url`), width and height.
            private struct Item: Decodable {
                let url: URL?

                init(from decoder: any Decoder) throws {
                    if
                        let single = try? decoder.singleValueContainer(),
                        let string = try? single.decode(String.self)
                    {
                        self.url = URL(string: string)
                        return
                    }

                    let container = try decoder.container(keyedBy: ItemKeys.self)
                    let imageURL: String? = try? container.decodeIfPresent(String.self, forKey: .imageURL)
                    let plainURL: String? = try? container.decodeIfPresent(String.self, forKey: .url)
                    self.url = (imageURL ?? plainURL).flatMap { URL(string: $0) }
                }

                enum ItemKeys: String, CodingKey {
                    case imageURL, url
                }
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Ofuq: a malformed optional field is left out instead of rejecting the app (and so the source).
            self.id = container.lenientString(forKey: .id)
            self.name = container.lenientString(forKey: .name)

            self.subtitle = container.lenientString(forKey: .subtitle)
            self.description = container.lenientString(forKey: .description)

            self.developer = container.lenientString(forKey: .developer)

            // A version without a version number is left out, the others stay.
            self.versions = container.lossyArray(Version.self, forKey: .versions)

            self.version = container.lenientString(forKey: .version)

            self.versionDate = container.lenient(DateParsed.self, forKey: .versionDate)

            self.versionDescription = container.lenientString(forKey: .versionDescription)

            self.downloadURL = container.lenientURL(forKey: .downloadURL)

            self.localizedDescription = container.lenientString(forKey: .localizedDescription)

            self.iconURL = container.lenientURL(forKey: .iconURL)

            self.tintColor = container.lenient(Color.self, forKey: .tintColor)

            self.size =
                (try? container.decodeIfPresent(Int64.self, forKey: .size))
                ?? (try? container.decodeIfPresent(String.self, forKey: .size))
                .flatMap { Int64($0) }

            self.category = container.lenientString(forKey: .category)

            self.beta =
                (try? container.decodeIfPresent(Bool.self, forKey: .beta)) ?? false

            self.permissions = container.lossyArray(Permission.self, forKey: .permissions)
            self.appPermissions = container.lenient(AppPermissions.self, forKey: .appPermissions)

            self.screenshots = container.lenient(Screenshots.self, forKey: .screenshots)

            // Links with a space are refused by iOS 16: they are encoded, unusable ones are left out.
            self.screenshotURLs = container.lossyArray(String.self, forKey: .screenshotURLs)?
                .compactMap(URL.asLenient)

            self.downloads = Self._decodeCount(
                in: container,
                keys: [.downloads, .downloadCount, .downloadsCount]
            )

            if
                let marketplaceID = container.lenientString(forKey: .marketplaceID),
                !marketplaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw NSError(
                    domain: "FeatherSources",
                    code: 112789, userInfo: [NSLocalizedDescriptionKey: "AltStore PAL repositories aren't supported: \(id ?? "")"]
                )
            }
        }

        //        func encode(to encoder: any Encoder) throws {
        //            var container = encoder.container(keyedBy: CodingKeys.self)
        //            try container.encode(id, forKey: .id)
        //            try container.encode(name, forKey: .name)
        //
        //            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        //            try container.encodeIfPresent(description, forKey: .description)
        //
        //            try container.encode(developer, forKey: .developer)
        //
        //            try container.encode(versions, forKey: .versions)
        //
        //            try container.encode(version, forKey: .version)
        //
        //            try container.encode(versionDate, forKey: .versionDate)
        //
        //            try container.encodeIfPresent(versionDescription, forKey: .versionDescription)
        //
        //            try container.encode(downloadURL, forKey: .downloadURL)
        //
        //            try container.encode(localizedDescription, forKey: .localizedDescription)
        //
        //            try container.encode(iconURL, forKey: .iconURL)
        //
        //            try container.encodeIfPresent(tintColor, forKey: .tintColor)
        //
        //            if let size = size {
        //                try container.encode(size, forKey: .size)
        //            }
        //
        //            try container.encode(category, forKey: .category)
        //            try container.encode(beta, forKey: .beta)
        //
        //            // try container.encode(permissions, forKey: .permissions)
        //            // try container.encode(appPermissions, forKey: .appPermissions)
        //
        //            try container.encode(screenshots, forKey: .screenshots)
        //        }

        public enum CodingKeys: String, CodingKey {
            case id = "bundleIdentifier"
            case name, subtitle, description
            case developer = "developerName"
            case versions, version, versionDate, versionDescription, downloadURL,
                localizedDescription, iconURL, tintColor, size, category, beta
            case permissions, appPermissions
            case screenshots, screenshotURLs
            case marketplaceID
            case downloads, downloadCount, downloadsCount
        }

        /// Reads a count written as a number or as a string such as "12,345".
        private static func _decodeCount(
            in container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Int? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return value
                }
                if
                    let string = try? container.decodeIfPresent(String.self, forKey: key),
                    let value = Int(string.filter { $0.isASCII && $0.isNumber })
                {
                    return value
                }
            }
            return nil
        }
        
        public var currentAppVersion: Version? {
            versions?.first
        }
        
        public var currentName: String {
            var name = name ?? "Unknown"
            // additional check for blank names
            if name.isEmpty { name = "Unknown" }
            
            if let id, id.hasSuffix("Beta") {
                name += " (BETA)"
            }
            
            return name
        }
        
        public var currentVersion: String? {
            currentAppVersion?.version ?? version
        }
        
        public var currentDownloadUrl: URL? {
            currentAppVersion?.downloadURL ?? downloadURL
        }
        
        public var currentDate: DateParsed? {
            currentAppVersion?.date ?? versionDate
        }
        
        public var currentDescription: String? {
            subtitle ?? localizedDescription
        }

        /// Screenshots from either key: the older `screenshotURLs` list or the newer `screenshots`.
        public var allScreenshotURLs: [URL]? {
            if let urls = screenshotURLs, !urls.isEmpty { return urls }
            if let urls = screenshots?.iPhone, !urls.isEmpty { return urls }
            if let urls = screenshots?.iPad, !urls.isEmpty { return urls }
            return nil
        }
        
        // "UNIQUE" hahaha
        public var currentUniqueId: String {
            "\(id ?? uuid.uuidString).\(downloadURL?.absoluteString ?? uuid.uuidString)"
        }

        public struct Version: Decodable, Hashable, Identifiable, Comparable, Sendable {
            public var id: String { version + (build ?? "") }
            public var version: String
            public var build: String?
            public var date: DateParsed?
            public var localizedDescription: String?
            public var downloadURL: URL?
            public var size: UInt?
            public var minOSVersion: OSVersion?

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.version = try container.decode(String.self, forKey: .version)
                self.build = container.lenientString(forKey: .build)
                self.date = container.lenient(DateParsed.self, forKey: .date)
                self.localizedDescription = container.lenientString(forKey: .localizedDescription)
                self.downloadURL = container.lenientURL(forKey: .downloadURL)
                self.size =
                    (try? container.decodeIfPresent(UInt.self, forKey: .size))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .size))
                    .flatMap { UInt($0) }
                self.minOSVersion = container.lenient(OSVersion.self, forKey: .minOSVersion)
            }

            static public func < (lhs: Self, rhs: Self) -> Bool {
                // compare id
                lhs.id < rhs.id
            }

            public enum CodingKeys: String, CodingKey {
                case version
                case build = "buildVersion"
                case date, localizedDescription, downloadURL, size, minOSVersion
            }
        }
    }
}

// MARK: - News

extension ASRepository {
    public struct News: Sendable, Decodable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var caption: String
        public var tintColor: Color?
        public var imageURL: URL?
        public var url: URL?
        public var appID: App.ID?
        public var date: DateParsed?
        public var notify: Bool

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.title = try container.decode(String.self, forKey: .title)
            self.caption = try container.decode(String.self, forKey: .caption)
            // Ofuq: a malformed date or link (apps.altstore.io had "T015:00") no longer rejects the source.
            self.tintColor = container.lenient(Color.self, forKey: .tintColor)
            self.imageURL = container.lenientURL(forKey: .imageURL)
            self.url = container.lenientURL(forKey: .url)
            if let appID = container.lenientString(forKey: .appID) {
                self.appID = appID
            } else {
                self.appID = nil
            }
            self.date = container.lenient(DateParsed.self, forKey: .date)
            self.notify = container.lenient(Bool.self, forKey: .notify) ?? false
        }

        public enum CodingKeys: String, CodingKey {
            case id = "identifier"
            case title, caption, tintColor, imageURL, url, appID, date, notify
        }
    }
}

extension ASRepository {
    public struct Permission: Decodable, Hashable, Sendable {
        public var type: String
        public var usageDescription: String
    }
}

extension ASRepository {
    public struct AppPermissions: Decodable, Hashable, Sendable {
        public var entitlements: [Entitlement]?
        public var privacy: [Privacy]?

        public struct Entitlement: Decodable, Hashable, Sendable {
            public var name: String

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                self.name = try container.decode(String.self)
            }
        }

        public struct Privacy: Decodable, Hashable, Sendable {
            public var name: String
            public var usageDescription: String
        }

        public struct PrivacyDictionary: Decodable, Hashable, Sendable {
            private var _permissions: [String: String]
            
            public var privacyArray: [Privacy] {
                _permissions.map { Privacy(name: $0.key, usageDescription: $0.value) }
            }
            
            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                self._permissions = try container.decode([String: String].self)
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.entitlements = try? container.decodeIfPresent(
                [Entitlement].self,
                forKey: .entitlements
            )
            // some people are silly and are using empty dictionaries instead of empty arrays so lets ignore decoding errors
            self.privacy = try? container.decodeIfPresent(
                [Privacy].self,
                forKey: .privacy
            )
            // lets not ignore the silly people
            if self.privacy == nil {
                if let privacyDict = try? container.decodeIfPresent(
                    PrivacyDictionary.self,
                    forKey: .privacy
                ) {
                    self.privacy = privacyDict.privacyArray
                }
            }
        }

        public enum CodingKeys: String, CodingKey {
            case entitlements
            case privacy
        }
    }
}

extension ASRepository {
    public struct UserInfo: Decodable, Hashable, Sendable {
        public var patreonAccessToken: String?
    }
}

// MARK: - DateParsed

// everyone keeps using different formats for dates, even altstore

// taken from meret
public struct DateParsed: Codable, Equatable, Hashable, Comparable, Sendable {
    public let date: Date
    public let rawDate: RawDate
    
    public enum RawDate: Decodable, Hashable, Sendable {
        case number(Double)
        case string(String)
    }
    
    // ISO8601 formatters (more accurate for machine-generated dates)
    private static let isoFormatters: [ISO8601DateFormatter] = [
        {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }(),
        {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    ]
    
    // legacy formatters
    private static let formatters: [DateFormatter] = {
        let locale = Locale(identifier: "en_US_POSIX")
        let tz = TimeZone(secondsFromGMT: 0)
        
        return [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
            "EEE, dd MMM yyyy HH:mm:ss zzz", // RFC1123
            "EEE MMM dd HH:mm:ss Z yyyy",    // Twitter
            "yyyy-MM-dd HH:mm:ss",
        ].map {
            let formatter = DateFormatter()
            formatter.dateFormat = $0
            formatter.locale = locale
            formatter.timeZone = tz
            return formatter
        }
    }()
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // prevent nil
        if container.decodeNil() {
            throw DecodingError.valueNotFound(
                Date.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Found nil for date. Mark the date optional."
                )
            )
        }
        
        // Ofuq: text first, as almost every source writes dates as text, and the usual ISO 8601 forms are
        // read directly. A source with 17,000 apps has 34,000 dates: trying the formatters below one after
        // the other for each of them took seconds.
        let dateString: String
        if let text = try? container.decode(String.self) {
            dateString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // timestamp (e.g., 1699999999.0)
            let timestamp = try container.decode(Double.self)
            self.date = Date(timeIntervalSince1970: timestamp)
            self.rawDate = .number(timestamp)
            return
        }
        self.rawDate = .string(dateString)

        if let date = Self.fastISODate(dateString) {
            self.date = date
            return
        }

        // ISO8601 formatters
        for formatter in Self.isoFormatters {
            if let date = formatter.date(from: dateString) {
                self.date = date
                return
            }
        }
        
        // legacy formatters
        for formatter in Self.formatters {
            if let date = formatter.date(from: dateString) {
                self.date = date
                return
            }
        }
        
        // numeric timestamp string
        if let timestamp = Double(dateString) {
            self.date = Date(timeIntervalSince1970: timestamp)
            return
        }
        
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Failed to decode date from: \(dateString)"
        )
    }

    /// "2026-11-12", "2026-11-12T04:00:38Z", "2026-11-12 04:00:38", with or without seconds, a fraction of
    /// a second and an offset ("Z", "+03:00", "+0300"). A time without an offset is UTC, as with the
    /// formatters above. Anything else returns nil and is left to the formatters.
    static func fastISODate(_ string: String) -> Date? {
        var text = string
        return text.withUTF8 { bytes -> Date? in
            var index = 0

            func number(_ count: Int) -> Int? {
                guard index + count <= bytes.count else { return nil }
                var value = 0
                for _ in 0..<count {
                    let byte = bytes[index]
                    guard byte >= 48, byte <= 57 else { return nil }
                    value = value * 10 + Int(byte - 48)
                    index += 1
                }
                return value
            }

            func skip(_ byte: UInt8) -> Bool {
                guard index < bytes.count, bytes[index] == byte else { return false }
                index += 1
                return true
            }

            // yyyy-MM-dd
            guard
                let year = number(4), skip(45),
                let month = number(2), skip(45),
                let day = number(2),
                (1...12).contains(month),
                day >= 1, day <= _days(inMonth: month, year: year)
            else {
                return nil
            }

            var seconds = 0.0
            if index < bytes.count {
                // "T", "t" or a space, then HH:mm
                guard
                    skip(84) || skip(116) || skip(32),
                    let hour = number(2), skip(58),
                    let minute = number(2),
                    hour <= 23, minute <= 59
                else {
                    return nil
                }
                var second = 0
                if skip(58) {
                    guard let value = number(2), value <= 59 else { return nil }
                    second = value
                }
                var fraction = 0.0
                if skip(46) || skip(44) {
                    var scale = 0.1
                    var hasDigits = false
                    while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                        fraction += Double(bytes[index] - 48) * scale
                        scale /= 10
                        index += 1
                        hasDigits = true
                    }
                    guard hasDigits else { return nil }
                }
                seconds = Double(hour * 3600 + minute * 60 + second) + fraction

                if skip(90) || skip(122) {
                    // "Z": UTC
                } else if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
                    let sign = bytes[index] == 45 ? -1 : 1
                    index += 1
                    guard let offsetHours = number(2), offsetHours <= 23 else { return nil }
                    var offsetMinutes = 0
                    if index < bytes.count {
                        _ = skip(58)
                        guard let value = number(2), value <= 59 else { return nil }
                        offsetMinutes = value
                    }
                    seconds -= Double(sign * (offsetHours * 3600 + offsetMinutes * 60))
                }
                guard index == bytes.count else { return nil }
            }

            let days = _daysSince1970(year: year, month: month, day: day)
            return Date(timeIntervalSince1970: Double(days) * 86_400 + seconds)
        }
    }

    private static func _days(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to this date of the Gregorian calendar (Howard Hinnant's `days_from_civil`).
    private static func _daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date)
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date
    }
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.date < rhs.date
    }
}


public struct OSVersion: Decodable, Hashable, CustomStringConvertible, Sendable {
    public var description: String {
        return "\(majorVersion).\(minorVersion).\(patchVersion)"
    }

    public var majorVersion: UInt
    public var minorVersion: UInt
    public var patchVersion: UInt

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let versionString = try container.decode(String.self)

        let components = versionString.split(separator: ".").compactMap { UInt($0) }

        self.majorVersion = components[safe: 0] ?? 0
        self.minorVersion = components[safe: 1] ?? 0
        self.patchVersion = components[safe: 2] ?? 0
    }
}
