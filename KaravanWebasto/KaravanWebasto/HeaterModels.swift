import Foundation

struct DiscoveredHeater: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct HeaterTelemetry: Equatable {
    var connected = false
    var running = false
    var runningStep: Int?
    var heatGenieRunMode: Int?
    var setLevel: Int?
    var setTemperature: Int?
    var supplyVoltage: Double?
    var cabinTemperature: Double?
    var caseTemperature: Double?
    var intakeTemperature: Double?
    var outletTemperature: Double?
    var errorCode: Int = 0
    var pumpActive = false
    var fanActive = false
    var glowPlugActive = false
    var usesFahrenheit = false
    var rawPacketHex = ""

    var cooling: Bool {
        // HeatGenie/Boygu register parser treats state 5 as non-running.
        // On our controller this is the state we conservatively treat as cooldown/transition.
        runningStep == 5 || (!running && fanActive && (caseTemperature ?? 0) > 45)
    }

    var statusText: String {
        if errorCode != 0 { return "Hata \(errorCode)" }
        if cooling { return "Soğutuyor / CLEAR" }
        if running { return "Çalışıyor" }
        return "Kapalı"
    }

    var modeText: String {
        switch heatGenieRunMode {
        case 0: return "Sabit sıcaklık"
        case 1: return "Manuel güç"
        case 2: return "Start/Stop"
        default: return "Bilinmiyor"
        }
    }
}
