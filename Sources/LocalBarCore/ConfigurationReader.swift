import Foundation

// Read saved changes off the main actor, including files replaced by an editor's atomic save.
public actor ConfigurationReader {
    private let file: URL
    private var lastData: Data?
    private var lastResult: Result<Configuration, Error>?

    public init(file: URL) { self.file = file }

    public func read() throws -> Configuration {
        let data = try Data(contentsOf: file)
        if data == lastData, let lastResult { return try lastResult.get() }
        let result = Result {
            let config = try JSONDecoder().decode(Configuration.self, from: data)
            try config.validate()
            return config
        }
        lastData = data
        lastResult = result
        return try result.get()
    }
}
