import Foundation
import CoreBluetooth

enum HeatGenieProtocol {
    static let serviceUUID = CBUUID(string: "181A")
    static let preferredNotifyUUID = CBUUID(string: "3A00")
    static let preferredWriteUUID = CBUUID(string: "3A01")

    private static let framePrefix: UInt8 = 0xAA
    private static let statusType: UInt8 = 0xF2

    private static let commandButton: UInt8 = 0x61
    private static let commandAutoUpdate: UInt8 = 0x65
    private static let commandShortParameter: UInt8 = 0x66

    private static let buttonOn: UInt8 = 1
    private static let buttonOff: UInt8 = 2

    private static let registerArea: UInt8 = 2
    private static let shortRunMode: UInt8 = 0
    private static let shortTargetTemp: UInt8 = 1

    static let runModeTemperature: UInt8 = 0
    static let runModeManual: UInt8 = 1
    static let runModeStartStop: UInt8 = 2

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0

        for value in bytes {
            let nibbles: [UInt8] = [value >> 4, value & 0x0F]
            for nibble in nibbles {
                crc ^= UInt16(nibble) << 12
                for _ in 0..<4 {
                    if (crc & 0x8000) != 0 {
                        crc = ((crc << 1) ^ 0x1021) & 0xFFFF
                    } else {
                        crc = (crc << 1) & 0xFFFF
                    }
                }
            }
        }

        return crc
    }

    private static func frame(command: UInt8, first: UInt8, second: UInt8, third: UInt8) -> Data {
        var bytes: [UInt8] = [framePrefix, 0, command, first, second, third, 0, 0]
        let crc = crc16(Array(bytes.prefix(6)))
        bytes[6] = UInt8((crc >> 8) & 0xFF)
        bytes[7] = UInt8(crc & 0xFF)
        return Data(bytes)
    }

    static func statusRequest() -> Data {
        frame(command: commandAutoUpdate, first: registerArea, second: 20, third: 30)
    }

    static func power(_ enabled: Bool) -> Data {
        frame(
            command: commandButton,
            first: enabled ? buttonOn : buttonOff,
            second: 0xFF,
            third: 0
        )
    }

    static func setRunMode(_ mode: UInt8) -> Data {
        frame(command: commandShortParameter, first: shortRunMode, second: 0, third: mode)
    }

    static func setTargetTemperature(_ celsius: Int, fahrenheit: Bool = false) -> Data {
        let safe = max(5, min(35, celsius))
        let value: Int
        if fahrenheit {
            value = Int((Double(safe) * 9.0 / 5.0 + 32.0).rounded())
        } else {
            value = safe
        }

        return frame(
            command: commandShortParameter,
            first: shortTargetTemp,
            second: fahrenheit ? 1 : 0,
            third: UInt8(clamping: value)
        )
    }

    static func parseStatus(_ data: Data) -> HeaterTelemetry? {
        let bytes = [UInt8](data)
        guard bytes.count >= 50, bytes[0] == framePrefix else { return nil }

        let frameLength = 8 + 4 * (Int(bytes[1]) + 1) + 2
        guard frameLength >= 50, bytes.count >= frameLength else { return nil }
        guard bytes[7] == statusType else { return nil }
        guard crc16(Array(bytes.prefix(frameLength))) == 0 else { return nil }

        let registers = Array(bytes[8..<48])
        let state = Int(registers[0] & 0x0F)
        let flags = registers[1]

        func u16LE(_ index: Int) -> UInt16 {
            UInt16(registers[index]) | (UInt16(registers[index + 1]) << 8)
        }

        func i16LE(_ index: Int) -> Int16 {
            Int16(bitPattern: u16LE(index))
        }

        let rawError = u16LE(20)
        let errorCode: Int
        if rawError == 0 {
            errorCode = 0
        } else {
            var lowest = 0
            for bit in 0..<16 {
                if (rawError & (UInt16(1) << UInt16(bit))) != 0 {
                    lowest = Int(UInt16(1) << UInt16(bit))
                    break
                }
            }
            errorCode = lowest
        }

        let intakeRaw = i16LE(16)
        let outletRaw = i16LE(18)
        let unsupportedProbe = Int16(bitPattern: UInt16(32760))

        var telemetry = HeaterTelemetry()
        telemetry.connected = true
        telemetry.running = !(state == 0 || state == 5)
        telemetry.runningStep = state
        telemetry.heatGenieRunMode = Int((flags >> 5) & 0x03)
        telemetry.setLevel = Int(registers[32])
        telemetry.setTemperature = Int(registers[33])
        telemetry.supplyVoltage = Double(u16LE(2)) / 10.0
        telemetry.cabinTemperature = Double(i16LE(6)) / 10.0
        telemetry.caseTemperature = Double(i16LE(8)) / 10.0
        telemetry.usesFahrenheit = (flags & 0x10) != 0
        telemetry.errorCode = errorCode
        telemetry.pumpActive = (flags & 0x03) != 0
        telemetry.fanActive = (flags & 0x04) != 0
        telemetry.glowPlugActive = (flags & 0x08) != 0
        telemetry.intakeTemperature = intakeRaw == unsupportedProbe ? nil : Double(intakeRaw) / 10.0
        telemetry.outletTemperature = outletRaw == unsupportedProbe ? nil : Double(outletRaw) / 10.0
        telemetry.rawPacketHex = bytes.prefix(frameLength).map { String(format: "%02X", $0) }.joined(separator: " ")

        return telemetry
    }
}
