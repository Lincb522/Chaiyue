import Foundation
import RuleEngine

/// 发现页筛选控件（select/toggle/text）的当前值，按书源保存，执行控件 action 时作为 `infoMap` 传入
public enum ExploreInfoStore {
    static func key(_ sourceUrl: String) -> String { "exploreInfo_" + sourceUrl }

    public static func load(_ store: KeyValueStore, sourceUrl: String) -> [String: String] {
        guard let text = store.string(forKey: key(sourceUrl)), let data = text.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    public static func save(_ map: [String: String], store: KeyValueStore, sourceUrl: String) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        store.set(String(decoding: data, as: UTF8.self), forKey: key(sourceUrl))
    }
}
