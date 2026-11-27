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

    // Native per-action clipboard layout documented by the working macOS
    // implementation in Samin100/codex-ios-assistant/scripts/copy-shortcut-actions.swift.
    // iOS editor acceptance still needs device verification.
    static func encodedItems(bundleID: String, teamID: String?) throws -> [Data] {
        try actions(bundleID: bundleID, teamID: teamID).map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
    }

    // Decode only the clipboard representation of Shortcuts actions, not
    // arbitrary text or other pasteboard data. No data leaves this device.
    static func inspect(_ values: [Data]) -> String {
        guard !values.isEmpty else { return "No hay acciones de Atajos en el portapapeles." }
        var result: [String] = []
        for data in values {
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
                result.append("Datos no reconocidos: \(data.count) bytes")
                continue
            }
            let label = format == .binary ? "binario" : "XML"
            if let dict = obj as? [String: Any], let id = dict["WFWorkflowActionIdentifier"] as? String {
                result.append("\(label) · \(id)")
            } else if let dict = obj as? [String: Any], let a = dict["actions"] as? [[String: Any]] {
                result.append("\(label) · conjunto de \(a.count) acciones")
            } else {
                result.append("\(label) · estructura no reconocida")
            }
        }
        return "\(values.count) elementos · " + result.joined(separator: "\n")
    }
}

// Clipboard generation is local-only; actual editor paste requires device verification.

// Build 18: per-action binary representation; iOS import remains to be verified.
