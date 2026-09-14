import AdrafinilShared
import Foundation
import SwiftUI

struct CustomIntegrationSetup: View {
    let cliPath: String
    let copy: (String) -> Void
    let close: () -> Void
    @State private var options = CustomIntegrationOptions()
    @State private var copied: String?

    private var recipe: Result<CustomIntegrationRecipe, Error> {
        Result { try options.recipe(cliPath: cliPath) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom integration").font(.title2.weight(.semibold))
            Text("Connect any local tool using lifecycle hooks. This generates a recipe; it does not install hooks or run commands.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Work identity") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                Text("Source ID")
                                TextField("my-tool", text: $options.source).accessibilityLabel("Source identifier")
                            }
                            GridRow {
                                Text("Work ID variable")
                                TextField("WORK_ID", text: $options.sessionVariable).accessibilityLabel("Work identifier environment variable")
                            }
                            GridRow {
                                Text("Lease lifetime")
                                Stepper(value: Binding(get: { Int(options.ttlSeconds / 60) }, set: { options.ttlSeconds = Double($0 * 60) }), in: 1 ... 1_440, step: 15) {
                                    Text("\(Int(options.ttlSeconds / 60)) minutes").monospacedDigit()
                                }
                            }
                        }
                        .textFieldStyle(.roundedBorder).padding(8)
                    }
                    Text("Use a different work ID for every concurrent job or turn. Reusing one ID merges that work into one lease; a long-lived application session is not necessarily one job.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Keep the display awake for screen-dependent work", isOn: Binding(get: { options.wakeClass == .display }, set: { options.wakeClass = $0 ? .display : .system }))
                    DisclosureGroup("Name your host events (optional)") {
                        TextField("Start / resume event", text: $options.startEvent)
                        TextField("Finish / cancel event", text: $options.stopEvent)
                    }.textFieldStyle(.roundedBorder)
                    switch recipe {
                    case let .failure(error):
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case let .success(recipe):
                        ForEach(recipe.steps) { step in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(step.event).font(.headline)
                                    Spacer()
                                    Button(copied == step.id ? "Copied" : "Copy", systemImage: "doc.on.doc") { copy(step.command); copied = step.id }
                                        .accessibilityLabel("Copy \(step.event) command")
                                }
                                Text(step.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                        }
                        Text("Attach only the events your tool actually supports. Start also resumes work; waiting follows your WakeLease waiting policy. Send heartbeats before expiry for longer work. Missing IDs and unavailable services fail soft, not as proof of protection.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        GroupBox("No lifecycle hooks?") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Executable only; defaults to source ID", text: $options.executable).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Executable for command wrapper")
                                Text(recipe.wrapper).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Copy command wrapper") { copy(recipe.wrapper); copied = "wrapper" }
                                Text("Add literal arguments after the executable. The wrapper protects the entire process, including idle prompts; it cannot infer semantic work.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Copy recipe as JSON") {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            if let data = try? encoder.encode(recipe) { copy(String(decoding: data, as: UTF8.self)); copied = "json" }
                        }
                    }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack {
                Text(copied == nil ? "Nothing is installed automatically." : "Command or recipe copied.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 620, height: 650)
        .onExitCommand(perform: close)
    }
}
