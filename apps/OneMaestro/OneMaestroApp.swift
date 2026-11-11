import AppKit
import Combine
import CoreAudio
import Foundation
import SwiftUI

struct StatusEnvelope: Decodable {
    let device: DeviceStatus
}

struct CommandEnvelope: Decodable {
    let ok: Bool
    let command: String
    let changed: Bool
    let dryRun: Bool
    let message: String
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
    let controls: [CoreAudioControl]?
}

struct DefaultRoles: Decodable {
    let input: Bool
    let output: Bool
    let systemOutput: Bool
}

struct CoreAudioControl: Decodable, Identifiable {
    let id: Int
    let classFourCC: String
    let className: String
    let scopeFourCC: String
    let scopeName: String
    let element: Int
    let name: String?
    let values: CoreAudioControlValues
}

struct CoreAudioControlValues: Decodable {
    let scalar: Double?
    let decibels: Double?
    let decibelRange: CoreAudioDecibelRange?
    let boolean: Bool?
    let currentItem: Int?
}

struct CoreAudioDecibelRange: Decodable {
    let minimum: Double
    let maximum: Double
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
    let phantomPower: Bool?
    let hiZ: Bool?
    let microphone: Bool?
    let externalInput: Bool?

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

actor OneControlExecutor {
    func run(_ arguments: [String]) throws -> String {
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

    private func controlToolURL() throws -> URL {
        try Self.controlToolURL()
    }
}

enum OneControlRunner {
    private static let executor = OneControlExecutor()

    static func run(_ arguments: [String]) async throws -> String {
        try await executor.run(arguments)
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
    private var busyCount = 0
    private var outputVolumeApplyRunning = false
    private var outputVolumeNeedsApply = false
    private var inputGainApplyRunning = false
    private var inputGainNeedsApply = false
    private var monitorVolumeApplyRunning = false
    private var monitorVolumeNeedsApply = false
    private var observedCoreAudioOutputControlID: AudioObjectID?
    private var coreAudioOutputVolumeListener: AudioObjectPropertyListenerBlock?

    var shouldIgnoreControlChanges: Bool {
        syncingFromDevice || busy
    }

    var shouldIgnoreSliderChanges: Bool {
        syncingFromDevice
    }

    init() {
        loadPersistedState()
    }

    var outputRange: ClosedRange<Double> {
        if let range = coreAudioOutputControl?.values.decibelRange {
            return range.minimum...range.maximum
        }
        return range(from: status?.uac.mainOutput.volume, fallback: -64...0)
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

    var coreAudioOutputControl: CoreAudioControl? {
        status?.coreAudio.controls?.first {
            $0.className == "volume" && $0.scopeName == "output"
        }
    }

    var usesCoreAudioOutputVolume: Bool {
        status?.coreAudio.defaultRoles?.systemOutput == true &&
            coreAudioOutputControl?.values.decibels != nil
    }

    func refresh() async {
        await runAndReload(nil)
    }

    func pollStatus() async {
        while !Task.isCancelled {
            if !busy {
                await reloadStatus(showBusy: false)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func applyOutputVolume() async {
        await runAndReload(outputVolumeCommand())
    }

    func scheduleOutputVolumeApply() {
        outputVolumeNeedsApply = true
        guard !outputVolumeApplyRunning else { return }
        outputVolumeApplyRunning = true

        Task { @MainActor in
            while self.outputVolumeNeedsApply {
                self.outputVolumeNeedsApply = false
                await self.runCommand(self.outputVolumeCommand(), reload: false)
                try? await Task.sleep(for: .milliseconds(40))
            }
            self.outputVolumeApplyRunning = false
        }
    }

    func applyOutputMute() async {
        await runAndReload(["output", "--mute", outputMuted ? "on" : "off"])
    }

    func applyInputSource() async {
        if await runCommand(["input", "--source", inputSource], reload: true) {
            await runCommand(["monitor", "--volume-db", dbArgument(monitorVolumeDb)], reload: false)
        }
    }

    func applyInputGain() async {
        await runAndReload(["input", "--gain-db", dbArgument(inputGainDb)])
    }

    func scheduleInputGainApply() {
        inputGainNeedsApply = true
        guard !inputGainApplyRunning else { return }
        inputGainApplyRunning = true

        Task { @MainActor in
            while self.inputGainNeedsApply {
                self.inputGainNeedsApply = false
                await self.runCommand(["input", "--gain-db", self.dbArgument(self.inputGainDb)], reload: false)
                try? await Task.sleep(for: .milliseconds(40))
            }
            self.inputGainApplyRunning = false
        }
    }

    func dryRunMonitorVolume() async {
        await runCommand(["monitor", "--volume-db", dbArgument(monitorVolumeDb), "--dry-run"], reload: false)
    }

    func applyMonitorVolume() async {
        await runCommand(["monitor", "--volume-db", dbArgument(monitorVolumeDb)], reload: false)
    }

    func scheduleMonitorVolumeApply() {
        monitorVolumeNeedsApply = true
        guard !monitorVolumeApplyRunning else { return }
        monitorVolumeApplyRunning = true

        Task { @MainActor in
            while self.monitorVolumeNeedsApply {
                self.monitorVolumeNeedsApply = false
                await self.runCommand(["monitor", "--volume-db", self.dbArgument(self.monitorVolumeDb)], reload: false)
                try? await Task.sleep(for: .milliseconds(40))
            }
            self.monitorVolumeApplyRunning = false
        }
    }

    func applyMonitorPreset(_ db: Double) async {
        monitorVolumeDb = min(max(db, monitorRange.lowerBound), monitorRange.upperBound)
        await applyMonitorVolume()
    }

    private func runAndReload(_ command: [String]?) async {
        if let command {
            await runCommand(command, reload: true)
        } else {
            await reloadStatus()
        }
    }

    @discardableResult
    private func runCommand(_ command: [String], reload: Bool) async -> Bool {
        beginBusy()
        defer { endBusy() }

        do {
            let output = try await OneControlRunner.run(jsonCommand(command))
            let result = try JSONDecoder().decode(CommandEnvelope.self, from: Data(output.utf8))
            message = result.message
            persistEditableState()
            if reload {
                await reloadStatus(showBusy: false)
            }
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func reloadStatus(showBusy: Bool = true) async {
        if showBusy {
            beginBusy()
        }
        defer {
            if showBusy {
                endBusy()
            }
        }

        do {
            let output = try await OneControlRunner.run(["status", "--json"])
            let decoded = try JSONDecoder().decode(StatusEnvelope.self, from: Data(output.utf8))
            syncingFromDevice = true
            status = decoded.device
            outputVolumeDb = coreAudioOutputControl?.values.decibels ??
                decoded.device.uac.mainOutput.volume.currentDb ??
                outputVolumeDb
            outputMuted = decoded.device.uac.mainOutput.mute ?? false
            inputSource = decoded.device.uac.input.currentSource?.cliName ?? inputSource
            inputGainDb = decoded.device.uac.input.currentGain?.currentDb ?? inputGainDb
            lastSeenUID = decoded.device.coreAudio.uid ?? lastSeenUID
            updateCoreAudioOutputVolumeObserver()
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

    private func beginBusy() {
        busyCount += 1
        busy = true
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        busy = busyCount > 0
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

    private func outputVolumeCommand() -> [String] {
        if usesCoreAudioOutputVolume {
            return ["output", "--system-volume-db", dbArgument(outputVolumeDb)]
        }
        return ["output", "--volume-db", dbArgument(outputVolumeDb)]
    }

    private func updateCoreAudioOutputVolumeObserver() {
        guard let controlID = coreAudioOutputControl.map({ AudioObjectID($0.id) }),
              observedCoreAudioOutputControlID != controlID else {
            return
        }

        if let observed = observedCoreAudioOutputControlID,
           let listener = coreAudioOutputVolumeListener {
            var oldDbAddress = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyDecibelValue,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
            var oldScalarAddress = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyScalarValue,
                                                              mScope: kAudioObjectPropertyScopeGlobal,
                                                              mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(observed, &oldDbAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(observed, &oldScalarAddress, .main, listener)
        }

        observedCoreAudioOutputControlID = controlID
        var dbAddress = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyDecibelValue,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var scalarAddress = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyScalarValue,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshCoreAudioOutputVolumeFromObserver()
            }
        }

        let dbStatus = AudioObjectAddPropertyListenerBlock(controlID, &dbAddress, .main, listener)
        let scalarStatus = AudioObjectAddPropertyListenerBlock(controlID, &scalarAddress, .main, listener)
        if dbStatus == noErr || scalarStatus == noErr {
            coreAudioOutputVolumeListener = listener
        } else {
            observedCoreAudioOutputControlID = nil
            coreAudioOutputVolumeListener = nil
        }
    }

    private func refreshCoreAudioOutputVolumeFromObserver() {
        guard let controlID = observedCoreAudioOutputControlID,
              let db = readCoreAudioOutputVolumeDb(controlID: controlID) else {
            return
        }
        syncingFromDevice = true
        outputVolumeDb = db
        syncingFromDevice = false
        persistEditableState()
    }

    private func readCoreAudioOutputVolumeDb(controlID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyDecibelValue,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(controlID, &address) else {
            return nil
        }

        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(controlID, &address, 0, nil, &size, &value)
        guard status == noErr, size == UInt32(MemoryLayout<Float32>.size) else {
            return nil
        }
        return Double(value)
    }

    private func jsonCommand(_ command: [String]) -> [String] {
        guard let first = command.first, first != "status", !command.contains("--json") else {
            return command
        }
        return [first, "--json"] + command.dropFirst()
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
    private let monitorPresets: [(label: String, value: Double)] = [
        ("Silent", -63),
        ("Quiet", -54),
        ("Medium", -36),
        ("Loud", -18),
    ]

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
                    .onChange(of: model.outputVolumeDb) {
                        guard !model.shouldIgnoreSliderChanges else { return }
                        model.scheduleOutputVolumeApply()
                    }
                Text(dbText(model.outputVolumeDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            Toggle("Mute", isOn: $model.outputMuted)
                .onChange(of: model.outputMuted) {
                    guard !model.shouldIgnoreControlChanges else { return }
                    Task { await model.applyOutputMute() }
                }
                .disabled(model.busy)
            if let outputComparisonLine {
                Text(outputComparisonLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text(inputModeLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Slider(value: $model.inputGainDb, in: model.inputGainRange, step: 1)
                    .onChange(of: model.inputGainDb) {
                        guard !model.shouldIgnoreSliderChanges else { return }
                        model.scheduleInputGainApply()
                    }
                Text(dbText(model.inputGainDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Monitor")
            HStack(spacing: 12) {
                Slider(value: $model.monitorVolumeDb, in: model.monitorRange, step: 1)
                    .onChange(of: model.monitorVolumeDb) {
                        guard !model.shouldIgnoreSliderChanges else { return }
                        model.scheduleMonitorVolumeApply()
                    }
                    .disabled(!(model.status?.monitor.directInputMixWrite.enabled ?? false))
                Text(dbText(model.monitorVolumeDb))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Button {
                    Task { await model.dryRunMonitorVolume() }
                } label: {
                    Label("Dry Run", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.busy)
            }
            HStack(spacing: 8) {
                ForEach(monitorPresets, id: \.label) { preset in
                    Button(preset.label) {
                        Task { await model.applyMonitorPreset(preset.value) }
                    }
                    .disabled(model.busy || !(model.status?.monitor.directInputMixWrite.enabled ?? false))
                }
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
        let uacDb = status.uac.mainOutput.volume.currentDb.map { dbText($0) } ?? "unavailable"
        let coreDb = coreAudioOutputVolume.map { dbText($0) } ?? "unavailable"
        return "UAC feature \(status.uac.mainOutput.featureUnit) \(uacDb), Core Audio output \(coreDb), headphone feature \(status.uac.headphone.featureUnit)"
    }

    private var inputDiagnosticLine: String {
        guard let input = model.status?.uac.input else {
            return "unavailable"
        }
        let current = input.currentSource.map { "\($0.cliName) pin \($0.pin) feature \($0.featureUnit)" } ?? "unknown"
        return "selector \(input.selectorUnit), current \(current)"
    }

    private var inputModeLine: String {
        guard let source = model.status?.uac.input.currentSource else {
            return "Input mode unavailable"
        }
        if source.phantomPower == true {
            return "48V external microphone mode"
        }
        if source.hiZ == true {
            return "Hi-Z instrument mode"
        }
        if source.externalInput == true {
            return "External microphone mode"
        }
        return "Internal microphone mode"
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

    private var coreAudioOutputVolume: Double? {
        model.status?.coreAudio.controls?.first {
            $0.className == "volume" && $0.scopeName == "output"
        }?.values.decibels
    }

    private var outputComparisonLine: String? {
        guard let uacDb = model.status?.uac.mainOutput.volume.currentDb,
              let coreDb = coreAudioOutputVolume,
              abs(uacDb - coreDb) >= 1 else {
            return nil
        }
        return "Hardware output \(dbText(uacDb)); macOS output \(dbText(coreDb))"
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
