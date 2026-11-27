import Foundation

enum WeatherShortcutRecipe {
    static let pasteboardType = "com.apple.shortcuts.action"
    static let intentName = "NativeAppleWeatherIntent"

    // Read the actual profile embedded by the user's signer. No account login,
    // network request, private API or hard-coded developer team is used.
    static func teamIdentifier(profile: Data) -> String? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        let entitlements = dict["Entitlements"] as? [String: Any]
        let value = entitlements?["com.apple.developer.team-identifier"] as? String
            ?? (dict["TeamIdentifier"] as? [String])?.first
        guard let value, value.count == 10, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) else { return nil }
        return value
    }

    static func actions(bundleID: String, teamID: String?) -> [[String: Any]] {
        var actions: [[String: Any]] = []
        func action(_ name: String, _ parameters: [String: Any], _ output: String, native: Bool = true) -> [String: Any] {
            let id = UUID().uuidString
            var p = parameters
            p["UUID"] = id
            if !output.isEmpty { p["CustomOutputName"] = output }
            actions.append(["WFWorkflowActionIdentifier": native ? "is.workflow.actions." + name : name,
                            "WFWorkflowActionParameters": p])
            return ["WFSerializationType": "WFTextTokenAttachment",
                    "Value": ["Type": "ActionOutput", "OutputUUID": id, "OutputName": output]]
        }
        func detail(_ input: [String: Any], _ property: String, _ name: String) -> [String: Any] {
            action("properties.weather.conditions", ["WFInput": input, "WFContentItemPropertyName": property], name)
        }
        func item(_ input: [String: Any], _ index: Int, _ name: String) -> [String: Any] {
            action("getitemfromlist", ["WFInput": input, "WFItemSpecifier": "Item At Index", "WFItemIndex": index], name)
        }
        let location = action("getcurrentlocation", [:], "Ubicación")
        let current = action("weather.currentconditions", ["WFWeatherCustomLocation": location], "Clima actual")
        let hourly = action("weather.forecast", ["WFWeatherCustomLocation": location, "WFWeatherForecastType": "Hourly"], "Pronóstico horario")
        let daily = action("weather.forecast", ["WFWeatherCustomLocation": location, "WFWeatherForecastType": "Daily"], "Pronóstico diario")
        let today = item(daily, 1, "Hoy")
        let tomorrow = item(daily, 2, "Mañana")
        let temperature = detail(current, "Temperature", "Temperatura actual")
        let condition = detail(current, "Condition", "Condición actual")
        let dates = detail(hourly, "Date", "Fechas por hora")
        let temperatures = detail(hourly, "Temperature", "Temperaturas por hora")
        let conditions = detail(hourly, "Condition", "Condiciones por hora")
        let low = detail(today, "Low", "Mínima de hoy")
        let high = detail(tomorrow, "High", "Máxima de mañana")
        var descriptor: [String: Any] = ["BundleIdentifier": bundleID, "Name": "ClearWidget", "AppIntentIdentifier": intentName]
        if let teamID { descriptor["TeamIdentifier"] = teamID }
        _ = action(bundleID + "." + intentName,
            ["AppIntentDescriptor": descriptor, "location": location, "currentTemperature": temperature,
             "currentCondition": condition, "hourlyDates": dates, "hourlyTemperatures": temperatures,
             "hourlyConditions": conditions, "todayLow": low, "tomorrowHigh": high], "", native: false)
        return actions
    }

    static func encoded(bundleID: String, teamID: String?) throws -> Data {
        // Multi-action clipboard envelope as used by Shortcut Source Tool.
        // It is an editor clipboard payload, not an unsigned .shortcut file.
        let a = actions(bundleID: bundleID, teamID: teamID)
        return try PropertyListSerialization.data(fromPropertyList: ["actions": a], format: .xml, options: 0)
    }
}

// Clipboard generation is local-only; actual editor paste requires device verification.
