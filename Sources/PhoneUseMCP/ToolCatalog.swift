import Foundation

public enum ToolArg: Sendable, Equatable { case int(Int), string(String), strings([String]) }
public enum ToolOutput: Sendable, Equatable { case text(String), jpeg(Data, note: String), error(String) }
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let required: [String]
    public let properties: [String: (type: String, description: String)]
}
public enum ToolCatalog {
    public static let all: [ToolSpec] = [
        spec("list_phones", "List available phones and discovery hints", [], [:], phone: false),
        spec("screenshot", "Capture JPEG, capped at 1344 pixels on its longest edge. Use screenshot coordinates for input.", [], [:]),
        spec("tap", "Tap a screenshot coordinate", ["x", "y"], ["x": integer("Screenshot x"), "y": integer("Screenshot y"), "count": integer("1-3, default 1")]),
        spec("long_press", "Hold a screenshot coordinate", ["x", "y"], ["x": integer("Screenshot x"), "y": integer("Screenshot y"), "duration_ms": integer("1-60000, default 800")]),
        spec("swipe", "Swipe between screenshot coordinates", ["from_x", "from_y", "to_x", "to_y"], ["from_x": integer("Start x"), "from_y": integer("Start y"), "to_x": integer("End x"), "to_y": integer("End y"), "duration_ms": integer("1-60000, default 300")]),
        spec("type_text", "Type up to 100 US-ASCII characters", ["text"], ["text": ("string", "Text to type")]),
        spec("press_key", "Press a named key or lowercase a-z", ["key"], ["key": ("string", "enter, escape, backspace, tab, space, arrow_up, arrow_down, arrow_left, arrow_right, or a-z"), "modifiers": ("array", "control, shift, option, command"), "repeat": integer("1-100, default 1")]),
        spec("press_home", "Go to the home screen", [], [:]),
        spec("open_app", "Open an app using Spotlight", ["name"], ["name": ("string", "Nonempty app name, at most 100 US-ASCII characters")]),
        spec("set_task", "Show the user what you are doing on this phone. Call when you start a job; an empty title clears it.", ["title"], ["title": ("string", "Short task title, at most 80 characters")]),
        spec("request_help", "Ask the user to take over, for example at a passcode, Face ID, or a step you are not authorized to do. Returns at once; actions fail until the user hands the phone back or you call cancel_help. Keep taking screenshots to see when it is solved.", ["reason"], ["reason": ("string", "What the user needs to do, 1-200 characters")]),
        spec("cancel_help", "Withdraw your help request when you no longer need the user. Does not work once the user has taken over.", [], [:]),
    ]
    private static func integer(_ description: String) -> (String, String) { ("integer", description) }
    private static func spec(_ name: String, _ description: String, _ required: [String], _ properties: [String: (type: String, description: String)], phone: Bool = true) -> ToolSpec {
        var properties = properties
        if phone { properties["phone_id"] = ("string", "Required when multiple phones are available") }
        return ToolSpec(name: name, description: description, required: required, properties: properties)
    }
}
