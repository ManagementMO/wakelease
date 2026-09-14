import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Custom integration recipes")
struct CustomIntegrationRecipeTests {
    @Test
    func `sources namespace otherwise identical work identifiers`() throws {
        var first = CustomIntegrationOptions()
        first.source = "first-tool"
        var second = first
        second.source = "second-tool"
        let a = try first.recipe(cliPath: "/usr/local/bin/wakelease")
        let b = try second.recipe(cliPath: "/usr/local/bin/wakelease")
        #expect(a.steps.allSatisfy { $0.command.contains("'first-tool:'\"${WORK_ID}\"") })
        #expect(b.steps.allSatisfy { $0.command.contains("'second-tool:'\"${WORK_ID}\"") })
        #expect(a.steps.map(\.operation) == ["acquire", "wait", "heartbeat", "release"])
    }

    @Test
    func `invalid variables lifetimes and identifiers are rejected`() {
        var options = CustomIntegrationOptions()
        options.sessionVariable = "ID:-$(false)"
        #expect(throws: (any Error).self) { try options.recipe(cliPath: "/usr/local/bin/wakelease") }
        options.sessionVariable = "WORK_ID"
        for ttl in [0, -1, Double.nan, Double.infinity, 86_401] {
            options.ttlSeconds = ttl
            #expect(throws: (any Error).self) { try options.recipe(cliPath: "/usr/local/bin/wakelease") }
        }
        options.ttlSeconds = 60
        options.source = "two words;command"
        #expect(throws: (any Error).self) { try options.recipe(cliPath: "/usr/local/bin/wakelease") }
    }

    @Test
    func `executable paths are literal and display demand is explicit`() throws {
        var options = CustomIntegrationOptions()
        options.wakeClass = .display
        options.executable = "/tmp/My Tool's executable"
        let path = "/tmp/O'Reilly tools/wakelease"
        let recipe = try options.recipe(cliPath: path)
        #expect(recipe.steps.allSatisfy { $0.command.contains(LeaseIntegrations.quote(path)) })
        #expect(recipe.steps[0].command.contains(" --display"))
        #expect(recipe.steps.dropFirst().allSatisfy { !$0.command.contains(" --display") })
        #expect(recipe.wrapper.contains(LeaseIntegrations.quote(options.executable)))
        #expect(recipe.wrapper.contains(" --display -- "))
    }

    @Test
    func `missing identifiers and unreachable tools fail soft without a lease`() throws {
        let recipe = try CustomIntegrationOptions().recipe(cliPath: "/usr/bin/false")
        for prefix in ["unset WORK_ID; ", "WORK_ID='literal value; $HOME'; "] {
            for step in recipe.steps {
                let result = try BoundedProcess.run(arguments: ["/bin/sh", "-c", prefix + step.command], timeout: 2)
                #expect(result.status == 0)
            }
        }
    }

    @Test
    func `json recipe carries a version and never executes host event labels`() throws {
        var options = CustomIntegrationOptions()
        options.startEvent = "BeforeWork $(not-a-command)"
        let recipe = try options.recipe(cliPath: "/usr/local/bin/wakelease")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(recipe.steps[0].event == options.startEvent)
        #expect(!recipe.steps[0].command.contains("not-a-command"))
    }
}
