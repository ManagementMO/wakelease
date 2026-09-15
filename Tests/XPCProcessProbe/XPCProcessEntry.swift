import Foundation

@main
enum XPCProcessEntry {
    static func main() {
        FileHandle.standardError.write(Data("Cross-process fixture is not implemented.\n".utf8))
        exit(1)
    }
}
