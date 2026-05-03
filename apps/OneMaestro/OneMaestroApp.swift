import AppKit
import Combine
import Foundation
import SwiftUI

struct StatusEnvelope: Decodable {
    let device: DeviceStatus
}

struct DeviceStatus: Decodable {
    let vendorId: Int
    let productId: Int
    let coreAudio: CoreAudioStatus
    let uac: UACStatus
    let monitor: MonitorStatus
}

struct CoreAudioStatus: Decodable {
    let visible: Bool
    let name: String?
    let manufacturer: String?
    let uid: String?
    let nominalSampleRate: Double?
    let inputChannels: Int?
    let outputChannels: Int?
    let defaultRoles: DefaultRoles?
}

struct DefaultRoles: Decodable {
    let input: Bool
    let output: Bool
    let systemOutput: Bool
}

struct UACStatus: Decodable {
    let mainOutput: OutputStatus
    let headphone: HeadphoneStatus
    let input: InputStatus
}

struct OutputStatus: Decodable {
    let featureUnit: Int
    let mute: Bool?
    let volume: VolumeStatus
}

struct HeadphoneStatus: Decodable {
    let featureUnit: Int
    let mute: Bool?
}

struct InputStatus: Decodable {
    let selectorUnit: Int
    let sources: [InputSourceStatus]
    let currentSource: InputSourceStatus?
    let currentGain: VolumeStatus?
}

struct InputSourceStatus: Decodable, Identifiable, Hashable {
    let pin: Int
    let featureUnit: Int
    let name: String
    let cliName: String
    let descriptorHint: String

    var id: String { cliName }
}

struct VolumeStatus: Decodable {
    let currentDb: Double?
    let minimumDb: Double?
    let maximumDb: Double?
    let resolutionDb: Double?
}

struct MonitorStatus: Decodable {
    let attenuationWrite: MonitorWriteStatus
    let directInputMixWrite: MonitorMixStatus
}

struct MonitorWriteStatus: Decodable {
    let enabled: Bool
    let readback: Bool
    let bRequest: Int?
    let audibleEffectConfirmed: Bool?
    let volumeDbRange: [Double]?
}

struct MonitorMixStatus: Decodable {
    let enabled: Bool
    let dryRunOnly: Bool
    let bRequest: Int?
    let rawDirection: String?
    let levelRange: [Int]?
    let volumeDbRange: [Double]?
}

enum ControlError: LocalizedError {
    case missingTool
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingTool:
            return "one-control was not found."
        case let .commandFailed(code, output):
            return "one-control exited \(code): \(output)"
        }
    }
}

enum OneControlRunner {
    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let toolURL = try controlToolURL()
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = toolURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw ControlError.commandFailed(process.terminationStatus,
                                                 (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }.value
    }

    private static func controlToolURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "one-control", withExtension: nil) {
            return bundled
        }

        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/one-control")
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return local
        }

        throw ControlError.missingTool
    }
}

@MainActor
final class DeviceModel: ObservableObject {
    @Published var status: DeviceStatus?
    @Published var outputVolumeDb: Double = -20
    @Published var outputMuted = false
    @Published var inputSource = "ext-48v-mic"
    @Published var inputGainDb: Double = 0
    @Published var monitorVolumeDb: Double = -48
    @Published var busy = false
    @Published var message = ""
    @Published var lastSeenUID = ""

    private var syncingFromDevice = false

    var shouldIgnoreControlChanges: Bool {
        syncingFromDevice || busy
    }

    init() {
        loadPersistedState()
    }

    var outputRange: ClosedRange<Double> {
        range(from: status?.uac.mainOutput.volume, fallback: -64...0)
    }

    var inputGainRange: ClosedRange<Double> {
        range(from: status?.uac.input.currentGain, fallback: 0...63)
    }

    var monitorRange: ClosedRange<Double> {
        guard let values = status?.monitor.directInputMixWrite.volumeDbRange, values.count == 2 else {
            return -63...0
        }
        return values[0]...values[1]
    }

    func refresh() async {
        await runAndReload(nil)
    }

    func pollStatus() async {
        while !Task.isCancelled {
            await reloadStatus(showBusy: false)
            try? await Task.sleep(for: .seconds(4))
        }
    }

    func applyOutputVolume() async {
        await runAndReload(["output", "--volume-db", dbArgument(outputVolumeDb)])
    }

    func applyOutputMute() async {
        await runAndReload(["output", "--mute", outputMuted ? "on" : "off"])
    }

    func applyInputSource() async {
        await runAndReload(["input", "--source", inputSource])
    }

    func applyInputGain() async {
        await runAndReload(["input", "--gain-db", dbArgument(inputGainDb)])
    }

    func dryRunMonitorVolume() async {
        await runCommand(["monitor", "--volume-db", dbArgument(monitorVolumeDb), "--dry-run"], reload: false)
    }

    func applyMonitorVolume() async {
        await runCommand(["monitor", "--volume-db", dbArgument(monitorVolumeDb)], reload: false)
    }

    private func runAndReload(_ command: [String]?) async {
        if let command {
            await runCommand(command, reload: true)
        } else {
            await reloadStatus()
        }
    }

    private func runCommand(_ command: [String], reload: Bool) async {
        busy = true
        defer { busy = false }

        do {
            let output = try await OneControlRunner.run(command)
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            persistEditableState()
            if reload {
                await reloadStatus(showBusy: false)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func reloadStatus(showBusy: Bool = true) async {
        if showBusy {
            busy = true
        }
        defer {
            if showBusy {
                busy = false
            }
        }

        do {
            let output = try await OneControlRunner.run(["status", "--json"])
            let decoded = try JSONDecoder().decode(StatusEnvelope.self, from: Data(output.utf8))
            syncingFromDevice = true
            status = decoded.device
            outputVolumeDb = decoded.device.uac.mainOutput.volume.currentDb ?? outputVolumeDb
            outputMuted = decoded.device.uac.mainOutput.mute ?? false
            inputSource = decoded.device.uac.input.currentSource?.cliName ?? inputSource
            inputGainDb = decoded.device.uac.input.currentGain?.currentDb ?? inputGainDb
            lastSeenUID = decoded.device.coreAudio.uid ?? lastSeenUID
            syncingFromDevice = false
            persistEditableState()
            message = "Ready"
        } catch {
            syncingFromDevice = true
            status = nil
            syncingFromDevice = false
            message = error.localizedDescription
        }
    }

    private func range(from volume: VolumeStatus?, fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let min = volume?.minimumDb, let max = volume?.maximumDb else {
            return fallback
        }
        return min...max
    }

    private func dbArgument(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "outputVolumeDb") != nil {
            outputVolumeDb = defaults.double(forKey: "outputVolumeDb")
        }
        if defaults.object(forKey: "outputMuted") != nil {
            outputMuted = defaults.bool(forKey: "outputMuted")
        }
        if let source = defaults.string(forKey: "inputSource") {
            inputSource = source
        }
        if defaults.object(forKey: "inputGainDb") != nil {
            inputGainDb = defaults.double(forKey: "inputGainDb")
        }
        if defaults.object(forKey: "monitorVolumeDb") != nil {
            monitorVolumeDb = defaults.double(forKey: "monitorVolumeDb")
        }
        if let uid = defaults.string(forKey: "lastSeenUID") {
            lastSeenUID = uid
        }
    }

    private func persistEditableState() {
        let defaults = UserDefaults.standard
        defaults.set(outputVolumeDb, forKey: "outputVolumeDb")
        defaults.set(outputMuted, forKey: "outputMuted")
        defaults.set(inputSource, forKey: "inputSource")
        defaults.set(inputGainDb, forKey: "inputGainDb")
        defaults.set(monitorVolumeDb, forKey: "monitorVolumeDb")
        defaults.set(lastSeenUID, forKey: "lastSeenUID")
    }
}

struct ContentView: View {
    @StateObject private var model = DeviceModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            outputSection
            inputSection
            monitorSection
            diagnosticsSection
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 540)
        .task {
            await model.pollStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status?.coreAudio.name ?? "Apogee ONE")
                    .font(.title2.weight(.semibold))
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.busy)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Output")
            HStack(spacing: 12) {
                Slider(value: $model.outputVolumeDb, in: model.outputRange, step: 1)
                Text(dbText(model.outputVolumeDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Button {
                    Task { await model.applyOutputVolume() }
                } label: {
                    Label("Set", systemImage: "checkmark")
                }
                .disabled(model.busy)
            }
            Toggle("Mute", isOn: $model.outputMuted)
                .onChange(of: model.outputMuted) {
                    guard !model.shouldIgnoreControlChanges else { return }
                    Task { await model.applyOutputMute() }
                }
                .disabled(model.busy)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Input")
            HStack(spacing: 12) {
                Picker("Source", selection: $model.inputSource) {
                    ForEach(model.status?.uac.input.sources ?? []) { source in
                        Text(source.name).tag(source.cliName)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.inputSource) {
                    guard !model.shouldIgnoreControlChanges else { return }
                    Task { await model.applyInputSource() }
                }
                .disabled(model.busy)
            }
            HStack(spacing: 12) {
                Slider(value: $model.inputGainDb, in: model.inputGainRange, step: 1)
                Text(dbText(model.inputGainDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Button {
                    Task { await model.applyInputGain() }
                } label: {
                    Label("Set", systemImage: "checkmark")
                }
                .disabled(model.busy)
            }
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Monitor")
            HStack(spacing: 12) {
                Slider(value: $model.monitorVolumeDb, in: model.monitorRange, step: 1)
                Text(dbText(model.monitorVolumeDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Button {
                    Task { await model.dryRunMonitorVolume() }
                } label: {
                    Label("Dry Run", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.busy)
                Button {
                    Task { await model.applyMonitorVolume() }
                } label: {
                    Label("Apply", systemImage: "slider.horizontal.3")
                }
                .disabled(model.busy || !(model.status?.monitor.directInputMixWrite.enabled ?? false))
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.busy {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(width: 20, height: 20)
            }
            Text(model.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
        }
        .frame(minHeight: 28)
    }

    private var diagnosticsSection: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                diagnosticRow("USB", usbLine)
                diagnosticRow("Core Audio", coreAudioLine)
                diagnosticRow("Output", outputDiagnosticLine)
                diagnosticRow("Input", inputDiagnosticLine)
                diagnosticRow("Monitor", monitorDiagnosticLine)
                diagnosticRow("Legacy", legacyDiagnosticLine)
            }
            .font(.caption)
            .textSelection(.enabled)
            .padding(.top, 6)
        } label: {
            sectionTitle("Diagnostics")
        }
    }

    private var statusLine: String {
        guard let status = model.status else {
            if model.lastSeenUID.isEmpty {
                return "Disconnected"
            }
            return "Disconnected - last seen \(model.lastSeenUID)"
        }
        let rate = status.coreAudio.nominalSampleRate.map { "\(Int($0)) Hz" } ?? "rate unavailable"
        let output = status.coreAudio.defaultRoles?.output == true ? "default output" : "not default output"
        return "\(status.coreAudio.manufacturer ?? "Apogee") - \(output) - \(rate)"
    }

    private var usbLine: String {
        guard let status = model.status else {
            return "unavailable"
        }
        return String(format: "vendor 0x%04x product 0x%04x", status.vendorId, status.productId)
    }

    private var coreAudioLine: String {
        guard let status = model.status else {
            return "unavailable"
        }
        let roles = status.coreAudio.defaultRoles
        return "uid \(status.coreAudio.uid ?? "unavailable"), in \(roles?.input == true ? "yes" : "no"), out \(roles?.output == true ? "yes" : "no"), system \(roles?.systemOutput == true ? "yes" : "no")"
    }

    private var outputDiagnosticLine: String {
        guard let status = model.status else {
            return "unavailable"
        }
        return "feature \(status.uac.mainOutput.featureUnit), headphone feature \(status.uac.headphone.featureUnit)"
    }

    private var inputDiagnosticLine: String {
        guard let input = model.status?.uac.input else {
            return "unavailable"
        }
        let current = input.currentSource.map { "\($0.cliName) pin \($0.pin) feature \($0.featureUnit)" } ?? "unknown"
        return "selector \(input.selectorUnit), current \(current)"
    }

    private var monitorDiagnosticLine: String {
        guard let monitor = model.status?.monitor.directInputMixWrite else {
            return "unavailable"
        }
        return "request 0x\(String(monitor.bRequest ?? 0, radix: 16)), \(monitor.rawDirection ?? "raw direction unavailable")"
    }

    private var legacyDiagnosticLine: String {
        guard let legacy = model.status?.monitor.attenuationWrite else {
            return "unavailable"
        }
        let audible = legacy.audibleEffectConfirmed == true ? "audible" : "not audible"
        return "request 0x\(String(legacy.bRequest ?? 0, radix: 16)), enabled \(legacy.enabled ? "yes" : "no"), \(audible)"
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospaced()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    private func dbText(_ value: Double) -> String {
        String(format: "%.0f dB", value)
    }
}

@main
struct OneMaestroApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}
