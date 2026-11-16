import Foundation

// MARK: - Model

/// Builds greetings for a person.
struct Greeter {
    let name: String
    var punctuation = "!"

    init(name: String) {
        self.name = name
    }

    func greet(times count: Int = 1) -> String {
        let line = "Hello, \(name)\(punctuation)"
        return Array(repeating: line, count: max(1, count)).joined(separator: "\n")
    }
}

// MARK: - Entry

@main
enum Main {
    static func main() {
        let greeter = Greeter(name: "EOF")
        print(greeter.greet(times: 2)) /* twice */
        #if DEBUG
        print(0x2A, 3.14, true, nil as Int? as Any)
        #endif
    }
}
