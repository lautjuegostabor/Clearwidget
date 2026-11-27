import Foundation
@main struct WeatherShortcutRecipeTests {
    static func main() throws {
        let bundle = "com.clearwidget.app"
        let team = "TEST123456"
        let raw = try PropertyListSerialization.data(fromPropertyList: ["TeamIdentifier":[team]], format: .xml, options: 0)
        precondition(WeatherShortcutRecipe.teamIdentifier(profile: Data([1,2,3]) + raw + Data([4,5])) == team)
        precondition(WeatherShortcutRecipe.teamIdentifier(profile: Data()) == nil)
        let data = try WeatherShortcutRecipe.encodedItems(bundleID: bundle, teamID: team)
        let actions = try data.map { item -> [String: Any] in
            precondition(item.starts(with: Data("bplist00".utf8)))
            var format = PropertyListSerialization.PropertyListFormat.xml
            let action = try PropertyListSerialization.propertyList(from: item, options: [], format: &format) as! [String: Any]
            precondition(format == .binary && action["actions"] == nil)
            return action
        }
        precondition(WeatherShortcutRecipe.inspect(data).hasPrefix("14 elementos"))
        precondition(WeatherShortcutRecipe.inspect([]).contains("No hay"))
        let envelope = try PropertyListSerialization.data(fromPropertyList: ["actions":actions], format: .xml, options: 0)
        precondition(WeatherShortcutRecipe.inspect([envelope]).contains("conjunto de 14 acciones"))
        precondition(WeatherShortcutRecipe.inspect([Data([1,2,3])]).contains("no reconocidos"))
        precondition(actions.count == 14)
        var seen = Set<String>()
        func validate(_ value: Any) {
            if let d = value as? [String: Any] {
                if d["Type"] as? String == "ActionOutput" { precondition(seen.contains(d["OutputUUID"] as! String)) }
                for v in d.values { validate(v) }
            } else if let a = value as? [Any] { for v in a { validate(v) } }
        }
        for a in actions {
            let p = a["WFWorkflowActionParameters"] as! [String: Any]
            validate(p)
            precondition(seen.insert(p["UUID"] as! String).inserted)
        }
        let last = actions.last!
        precondition(last["WFWorkflowActionIdentifier"] as? String == bundle + ".NativeAppleWeatherIntent")
        let p = last["WFWorkflowActionParameters"] as! [String: Any]
        precondition(Set(p.keys) == Set(["UUID","AppIntentDescriptor","location","currentTemperature","currentCondition","hourlyDates","hourlyTemperatures","hourlyConditions","todayLow","tomorrowHigh"]))
        let desc = p["AppIntentDescriptor"] as! [String: Any]
        precondition(desc["TeamIdentifier"] as? String == team && desc["BundleIdentifier"] as? String == bundle)
        print("14 clipboard actions and all linked input references passed")
    }
}
