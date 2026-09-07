import Foundation

@main
struct TocodeCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        exit(TocodeCLIRunner.run(arguments: args, transport: TocodeSocketTransport()))
    }
}
