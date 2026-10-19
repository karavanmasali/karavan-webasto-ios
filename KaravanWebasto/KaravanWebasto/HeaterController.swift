import Foundation
import CoreBluetooth
import SwiftUI

@MainActor
final class HeaterController: NSObject, ObservableObject {
    @Published private(set) var discovered: [DiscoveredHeater] = []
    @Published private(set) var connectionStatus = "Bluetooth hazırlanıyor…"
    @Published private(set) var connectedName = ""
    @Published private(set) var telemetry = HeaterTelemetry()
    @Published private(set) var lastAction = "Henüz işlem yok"
    @Published private(set) var logs: [String] = []

    @Published var thermostatEnabled: Bool {
        didSet { defaults.set(thermostatEnabled, forKey: Keys.thermostatEnabled) }
    }

    @Published var startTemperature: Int {
        didSet {
            if stopTemperature < startTemperature + 2 {
                stopTemperature = startTemperature + 2
            }
            defaults.set(startTemperature, forKey: Keys.startTemperature)
        }
    }

    @Published var stopTemperature: Int {
        didSet {
            if stopTemperature < startTemperature + 2 {
                stopTemperature = startTemperature + 2
            }
            defaults.set(stopTemperature, forKey: Keys.stopTemperature)
            if thermostatEnabled && isReady {
                configureNativeStop()
            }
        }
    }

    var isConnected: Bool {
        peripheral?.state == .connected
    }

    var isReady: Bool {
        isConnected && notifyCharacteristic != nil && writeCharacteristic != nil
    }

    private enum Keys {
        static let thermostatEnabled = "thermostatEnabled"
        static let startTemperature = "startTemperature"
        static let stopTemperature = "stopTemperature"
        static let selectedPeripheral = "selectedPeripheral"
    }

    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var statusTimer: Timer?
    private var shouldReconnect = true

    private var lastAutomationCommandAt = Date.distantPast
    private var lastObservedRunning = false
    private var lastStoppedAt = Date.distantPast
    private var overStopSince: Date?

    override init() {
        let savedStart = UserDefaults.standard.object(forKey: Keys.startTemperature) as? Int ?? 20
        let savedStop = UserDefaults.standard.object(forKey: Keys.stopTemperature) as? Int ?? 25
        thermostatEnabled = UserDefaults.standard.bool(forKey: Keys.thermostatEnabled)
        startTemperature = savedStart
        stopTemperature = max(savedStop, savedStart + 2)

        super.init()

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "KaravanWebasto.Central"
            ]
        )
    }

    deinit {
        statusTimer?.invalidate()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            connectionStatus = "Bluetooth açık değil"
            return
        }

        discovered.removeAll()
        peripheralCache.removeAll()
        connectionStatus = "HeatGenie cihazı aranıyor…"

        central.scanForPeripherals(
            withServices: [HeatGenieProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Tarama başladı: servis 181A")
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(to id: UUID) {
        guard let p = peripheralCache[id] else { return }
        stopScan()
        shouldReconnect = true
        defaults.set(id.uuidString, forKey: Keys.selectedPeripheral)
        peripheral = p
        p.delegate = self
        connectionStatus = "Bağlanıyor…"
        central.connect(p, options: nil)
    }

    func disconnect() {
        shouldReconnect = false
        statusTimer?.invalidate()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        connectedName = ""
        telemetry.connected = false
        connectionStatus = "Bağlantı kesildi"
    }

    func manualStart() {
        guard isReady else {
            lastAction = "Önce cihaza bağlan"
            return
        }
        send(HeatGenieProtocol.power(true), reason: "Manuel START")
    }

    func manualStop() {
        guard isReady else {
            lastAction = "Önce cihaza bağlan"
            return
        }
        thermostatEnabled = false
        send(HeatGenieProtocol.power(false), reason: "Manuel STOP / CLEAR")
    }

    func setThermostatEnabled(_ enabled: Bool) {
        thermostatEnabled = enabled

        if enabled {
            lastAction = "Otomatik termostat etkin"
            if isReady {
                configureNativeStop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.requestStatus()
                }
            }
        } else {
            overStopSince = nil
            lastAction = "Otomatik termostat devre dışı"
        }
    }

    func setStartTemperature(_ value: Int) {
        startTemperature = max(5, min(value, 33))
    }

    func setStopTemperature(_ value: Int) {
        stopTemperature = max(startTemperature + 2, min(value, 35))
    }

    func leaveCaravan() {
        thermostatEnabled = false
        overStopSince = nil
        lastAction = "Karavandan ayrılma: otomasyon kapalı"
        if isReady && (telemetry.running || telemetry.cooling) {
            send(HeatGenieProtocol.power(false), reason: "Karavandan ayrıl: STOP / CLEAR")
        }
    }

    func requestStatus() {
        guard isReady else { return }
        send(HeatGenieProtocol.statusRequest(), reason: "Durum sorgusu", quiet: true)
    }

    private func configureNativeStop() {
        guard isReady else { return }

        // Hibrit tasarım:
        // 1) Isıtıcının kendi Start/Stop modunu ve kapanma hedefini kullan.
        // 2) Bizim uygulama yalnızca düşük eşikte tekrar START komutunu tamamlar.
        send(
            HeatGenieProtocol.setRunMode(HeatGenieProtocol.runModeStartStop),
            reason: "Isıtıcı modu: Start/Stop"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.send(
                HeatGenieProtocol.setTargetTemperature(
                    self.stopTemperature,
                    fahrenheit: self.telemetry.usesFahrenheit
                ),
                reason: "Kapanma hedefi: \(self.stopTemperature)°C"
            )
        }
    }

    private func evaluateAutomation(previous: HeaterTelemetry) {
        guard thermostatEnabled, isReady else { return }
        guard telemetry.errorCode == 0 else {
            lastAction = "Otomasyon beklemede: cihaz hata bildiriyor"
            return
        }
        guard let ambient = telemetry.cabinTemperature else { return }

        if previous.running && !telemetry.running {
            lastStoppedAt = Date()
        }

        // STOP: Öncelikle kontrol kartının kendi A/Start-Stop moduna bırakıyoruz.
        // Hedefin üstünde 30 saniye hâlâ çalışıyorsa normal OFF komutu yedek olarak gönderilir.
        if ambient >= Double(stopTemperature) && telemetry.running {
            if overStopSince == nil {
                overStopSince = Date()
            } else if let since = overStopSince,
                      Date().timeIntervalSince(since) >= 30,
                      Date().timeIntervalSince(lastAutomationCommandAt) >= 15 {
                send(HeatGenieProtocol.power(false), reason: "Otomatik STOP (yedek)")
                lastAutomationCommandAt = Date()
                overStopSince = nil
            }
            return
        } else {
            overStopSince = nil
        }

        // START: Tamamen OFF olmasını bekle. CLEAR/soğutma sırasında yeniden ateşleme yok.
        let fullyOff = !telemetry.running && telemetry.runningStep == 0
        let coolEnough = (telemetry.caseTemperature ?? 0) < 70
        let minimumRestElapsed = Date().timeIntervalSince(lastStoppedAt) >= 120
        let commandCooldownElapsed = Date().timeIntervalSince(lastAutomationCommandAt) >= 30

        if ambient <= Double(startTemperature),
           fullyOff,
           coolEnough,
           minimumRestElapsed,
           commandCooldownElapsed {
            send(
                HeatGenieProtocol.setRunMode(HeatGenieProtocol.runModeStartStop),
                reason: "Otomatik START hazırlığı"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.send(HeatGenieProtocol.power(true), reason: "Otomatik START")
                self.lastAutomationCommandAt = Date()
            }
        }
    }

    private func send(_ data: Data, reason: String, quiet: Bool = false) {
        guard let p = peripheral, let characteristic = writeCharacteristic, p.state == .connected else {
            if !quiet { lastAction = "Komut gönderilemedi: bağlantı hazır değil" }
            return
        }

        let type: CBCharacteristicWriteType
        if characteristic.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else {
            type = .withResponse
        }

        p.writeValue(data, for: characteristic, type: type)

        if !quiet {
            lastAction = reason
            log("\(reason) → \(data.hexString)")
        }
    }

    private func beginStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestStatus()
            }
        }
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)"
        logs.insert(line, at: 0)
        if logs.count > 80 {
            logs.removeLast(logs.count - 80)
        }
    }

    private func tryReconnectSavedPeripheral() {
        guard let idString = defaults.string(forKey: Keys.selectedPeripheral),
              let id = UUID(uuidString: idString) else {
            return
        }

        let retrieved = central.retrievePeripherals(withIdentifiers: [id])
        guard let saved = retrieved.first else { return }

        peripheral = saved
        saved.delegate = self
        connectionStatus = "Kayıtlı ısıtıcıya bağlanıyor…"
        shouldReconnect = true
        central.connect(saved, options: nil)
    }
}

extension HeaterController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.connectionStatus = "Bluetooth hazır"
                self.tryReconnectSavedPeripheral()
            case .poweredOff:
                self.connectionStatus = "Bluetooth kapalı"
            case .unauthorized:
                self.connectionStatus = "Bluetooth izni verilmedi"
            case .unsupported:
                self.connectionStatus = "Bu cihaz Bluetooth LE desteklemiyor"
            default:
                self.connectionStatus = "Bluetooth hazırlanıyor…"
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let id = peripheral.identifier
            let name = peripheral.name
                ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? "HeatGenie / Boygu"

            self.peripheralCache[id] = peripheral

            let item = DiscoveredHeater(id: id, name: name, rssi: RSSI.intValue)
            if let index = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[index] = item
            } else {
                self.discovered.append(item)
            }

            self.discovered.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            self.connectedName = peripheral.name ?? "HeatGenie / Boygu"
            self.connectionStatus = "Bağlandı, servis aranıyor…"
            self.log("Bağlandı: \(self.connectedName)")
            peripheral.discoverServices([HeatGenieProtocol.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectionStatus = "Bağlantı başarısız"
            self.log("Bağlantı hatası: \(error?.localizedDescription ?? "bilinmiyor")")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.statusTimer?.invalidate()
            self.notifyCharacteristic = nil
            self.writeCharacteristic = nil
            self.telemetry.connected = false
            self.connectionStatus = "Bağlantı kesildi"
            self.log("Bağlantı kesildi")

            if self.shouldReconnect {
                self.connectionStatus = "Yeniden bağlanılıyor…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        Task { @MainActor in
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let restored = peripherals.first {
                self.peripheral = restored
                restored.delegate = self
                self.shouldReconnect = true
                self.connectionStatus = "Bluetooth bağlantısı geri yükleniyor…"

                if restored.state == .connected {
                    restored.discoverServices([HeatGenieProtocol.serviceUUID])
                } else {
                    central.connect(restored, options: nil)
                }
            }
        }
    }
}

extension HeaterController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.log("Servis hatası: \(error.localizedDescription)")
                return
            }

            guard let services = peripheral.services else { return }
            for service in services where service.uuid == HeatGenieProtocol.serviceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.log("Karakteristik hatası: \(error.localizedDescription)")
                return
            }

            guard let characteristics = service.characteristics else { return }

            for characteristic in characteristics {
                let props = characteristic.properties

                if characteristic.uuid == HeatGenieProtocol.preferredNotifyUUID
                    || props.contains(.notify)
                    || props.contains(.indicate) {
                    if self.notifyCharacteristic == nil
                        || characteristic.uuid == HeatGenieProtocol.preferredNotifyUUID {
                        self.notifyCharacteristic = characteristic
                    }
                }

                if characteristic.uuid == HeatGenieProtocol.preferredWriteUUID
                    || props.contains(.write)
                    || props.contains(.writeWithoutResponse) {
                    if self.writeCharacteristic == nil
                        || characteristic.uuid == HeatGenieProtocol.preferredWriteUUID {
                        self.writeCharacteristic = characteristic
                    }
                }
            }

            if let notify = self.notifyCharacteristic {
                peripheral.setNotifyValue(true, for: notify)
                if notify.properties.contains(.read) {
                    peripheral.readValue(for: notify)
                }
            }

            if self.notifyCharacteristic != nil && self.writeCharacteristic != nil {
                self.connectionStatus = "Kontrol hazır"
                self.log("181A hazır: notify=\(self.notifyCharacteristic!.uuid.uuidString), write=\(self.writeCharacteristic!.uuid.uuidString)")
                self.beginStatusTimer()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.requestStatus()
                    if self.thermostatEnabled {
                        self.configureNativeStop()
                    }
                }
            } else {
                self.connectionStatus = "181A bulundu ama kontrol karakteristikleri eksik"
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.log("BLE veri hatası: \(error.localizedDescription)")
                return
            }

            guard let value = characteristic.value else { return }

            if let parsed = HeatGenieProtocol.parseStatus(value) {
                let previous = self.telemetry
                self.telemetry = parsed
                self.lastObservedRunning = parsed.running
                self.evaluateAutomation(previous: previous)
            } else {
                self.log("Ham paket: \(value.hexString)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.log("Komut yazma hatası: \(error.localizedDescription)")
            }
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
