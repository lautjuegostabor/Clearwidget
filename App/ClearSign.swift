import Foundation
import SwiftUI
import Security
import BackgroundTasks
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit

@_silgen_name("clearsign_refresh")
private func nativeRefresh(_ directory: UnsafePointer<CChar>,_ data: UnsafePointer<UInt8>,_ count: Int) -> UnsafeMutablePointer<CChar>?
@_silgen_name("clearsign_free")
private func nativeFree(_ pointer: UnsafeMutablePointer<CChar>)

private struct EmbeddedProfile {
    let bundleID: String
    let uuid: String
    let expires: Date
    let bytes: Data
    init?(_ bundle: Bundle) {
        guard let id=bundle.bundleIdentifier,
              let url=bundle.url(forResource:"embedded",withExtension:"mobileprovision"),
              let data=try? Data(contentsOf:url),data.count <= 1_000_000,
              let start=data.range(of:Data("<plist".utf8)),let end=data.range(of:Data("</plist>".utf8),in:start.lowerBound..<data.endIndex),
              let p=try? PropertyListSerialization.propertyList(from:data.subdata(in:start.lowerBound..<end.upperBound),format:nil) as? [String:Any],
              let uuid=p["UUID"] as? String,let exp=p["ExpirationDate"] as? Date else {return nil}
        bundleID=id;self.uuid=uuid;expires=exp;bytes=data
    }
    static func installed() -> [EmbeddedProfile] {
        guard let main=EmbeddedProfile(.main),let dir=Bundle.main.builtInPlugInsURL,
              let urls=try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil),
              let extURL=urls.first(where:{$0.pathExtension=="appex"}),
              let ext=Bundle(url:extURL).flatMap(EmbeddedProfile.init) else{return []}
        return [main,ext]
    }
}

private struct ClearSignError: LocalizedError {
    let message:String
    var errorDescription:String? {message}
}
// Sensitive exported BariStore session and pairing material never leaves device.
// Only Keychain retains it between runs. No Apple password or signing private key.
private enum ClearSignVault {
    static let service="com.clearwidget.clearsign"
    static let account="baristore-session-v1"
    static var query:[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]}
    static func load()->[String:Data]? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var out:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&out)==errSecSuccess,let d=out as? Data else{return nil}
        return try? JSONDecoder().decode([String:Data].self,from:d)
    }
    static func save(_ entries:[String:Data]) throws {
        let d=try JSONEncoder().encode(entries)
        var q=query;q[kSecValueData as String]=d;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:d,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status==errSecItemNotFound {
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw ClearSignError(message:"No se pudo guardar la sesión en Keychain.")}
        } else if status != errSecSuccess {throw ClearSignError(message:"No se pudo actualizar Keychain.")}
    }
    static func erase(){SecItemDelete(query as CFDictionary)}
    static func allowed(_ name:String)->Bool {
        if ["account.plist","pairing.plist","anisette-server","host-uuid","device-port"].contains(name){return true}
        return name.hasPrefix("anisette-") && name.hasSuffix(".plist") && !name.contains("/") && !name.contains("..") && name.count<200
    }
    static func readFolder(_ url:URL) throws -> [String:Data] {
        let scoped=url.startAccessingSecurityScopedResource()
        defer {if scoped{url.stopAccessingSecurityScopedResource()}}
        let files=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        var result:[String:Data]=[:];var size=0
        for item in files where allowed(item.lastPathComponent) {
            let v=try item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard v.isRegularFile==true,v.isSymbolicLink != true,let n=v.fileSize,n<=256_000 else{continue}
            size += n
            guard size<=1_000_000 else{throw ClearSignError(message:"Exportación demasiado grande.")}
            result[item.lastPathComponent]=try Data(contentsOf:item)
        }
        guard result["account.plist"] != nil,result["pairing.plist"] != nil,
              let route=result["anisette-server"].flatMap({String(data:$0,encoding:.utf8)}),
              route.hasPrefix("https://"),result.keys.contains(where:{$0.hasPrefix("anisette-") && $0.hasSuffix(".plist")})
        else{throw ClearSignError(message:"Faltan sesión, identidad de anisette o emparejamiento.")}
        return result
    }
}
private struct SignRequest:Encodable {
    struct Item:Encodable {let bundleID:String;let profile:String}
    let bundles:[Item]
    let previousExpiry:UInt64
}
private struct SignResult:Decodable {
    let ok:Bool
    let expiry:UInt64?
    let code:String?
}
private struct SignReceipt:Codable {
    let installation:String
    let expiry:Date
    let at:Date
}

@MainActor final class ClearSign:ObservableObject {
    static let shared=ClearSign()
    static var taskID: String? {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let matches = ids.filter { $0.hasSuffix(".clearsign") }
        return matches.count == 1 ? matches.first : nil
    }
    @Published private(set) var configured=false
    @Published private(set) var status="Sin configurar"
    @Published private(set) var running=false
    @Published private(set) var setupActive=false
    @Published private(set) var expiry:Date?
    @Published var automatic:Bool {
        didSet {UserDefaults.standard.set(automatic,forKey:"clearsign.auto");schedule();Task{await notifications()}}
    }
    private var registered=false
    private let receiptKey="clearsign.receipt"
    private let attemptKey="clearsign.attempt"
    private let alertIDs=["clearsign.warning48","clearsign.warning24"]
    private init(){automatic=UserDefaults.standard.bool(forKey:"clearsign.auto");update()}
    private func installation(_ profiles:[EmbeddedProfile])->String {
        let bytes=Data(profiles.map{$0.bundleID+":"+$0.uuid}.joined(separator:"|").utf8)
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    private func currentExpiry(_ profiles:[EmbeddedProfile])->Date? {
        guard let embedded=profiles.map(\.expires).min(),profiles.count==2 else{return nil}
        if let d=UserDefaults.standard.data(forKey:receiptKey),let r=try? JSONDecoder().decode(SignReceipt.self,from:d),
           r.installation==installation(profiles){return max(embedded,r.expiry)}
        return embedded
    }
    func update(){
        configured=ClearSignVault.load() != nil
        expiry=currentExpiry(EmbeddedProfile.installed())
        if !configured{status="Configurá el emparejamiento y la cuenta de firma, o migrá una sesión existente."}
        else if expiry==nil{status="No se pudieron leer los dos perfiles incluidos."}
        else if status=="Sin configurar" || status.hasPrefix("Configurá"){status="Sesión importada. Pendiente de renovación comprobada."}
    }
    func register(){
        guard !registered else{return}
        guard let taskID = Self.taskID else { status = "Falta el identificador efectivo de renovación."; return }
        if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ClearSign-Transient", isDirectory: true))
        }
        registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:taskID,using:nil){task in
            guard let task=task as? BGProcessingTask else{task.setTaskCompleted(success:false);return}
            Task{@MainActor in Self.shared.handle(task)}
        }
    }
    func setSetupActive(_ active: Bool) {
        setupActive = active
        schedule()
    }
    func schedule(){
        guard registered, let taskID = Self.taskID else{return}
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:taskID)
        guard !setupActive,automatic,configured,let expiry else{return}
        let earliest=max(Date().addingTimeInterval(60),expiry.addingTimeInterval(-5*86400))
        let last=Date(timeIntervalSince1970:UserDefaults.standard.double(forKey:attemptKey))
        let req=BGProcessingTaskRequest(identifier:taskID)
        req.earliestBeginDate=max(earliest,last.addingTimeInterval(6*3600))
        req.requiresNetworkConnectivity=true
        req.requiresExternalPower=false
        do{try BGTaskScheduler.shared.submit(req)}catch{status="iOS no aceptó programar la renovación. "+error.localizedDescription}
    }
    @discardableResult func importSession(_ url:URL, fromSetup: Bool = false) -> Bool {
        guard !running, !setupActive || fromSetup else{return false}
        do{
            let data=try ClearSignVault.readFolder(url)
            try ClearSignVault.save(data)
            configured=true;status="Sesión importada. Probá renovar ahora."
            update();schedule()
            Task{await notifications()}
            return true
        }catch{status=error.localizedDescription;return false}
    }
    func recoveryExport() throws -> (ClearRecoveryDocument, String) {
        guard !running, !setupActive, let files=ClearSignVault.load() else { throw ClearSignError(message:"No hay sesión disponible.") }
        let profiles=EmbeddedProfile.installed()
        guard profiles.count==2,let until=currentExpiry(profiles) else { throw ClearSignError(message:"No hay dos perfiles válidos.") }
        let request=SignRequest(bundles:profiles.map{.init(bundleID:$0.bundleID,profile:$0.bytes.base64EncodedString())}, previousExpiry:UInt64(max(0,until.timeIntervalSince1970)))
        return try ClearRecoveryExport.encrypt(request:JSONEncoder().encode(request),files:files)
    }
    func forget(){
        guard !running,!setupActive else{return}
        automatic=false;ClearSignVault.erase();configured=false
        status="Sesión eliminada de Keychain."
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:alertIDs)
    }
    func enableAlerts() async {
        do{_ = try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]);await notifications()}
        catch{status="No se pudo habilitar avisos."}
    }
    private func notifications() async {
        let center=UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:alertIDs)
        guard automatic,let expiry else{return}
        for (id,days) in zip(alertIDs,[2.0,1.0]){
            let remaining=expiry.addingTimeInterval(-days*86400).timeIntervalSinceNow
            let c=UNMutableNotificationContent()
            c.title="ClearWidget: revisá la firma"
            c.body="No hay confirmación de una renovación posterior. Abrí ClearWidget o BariStore antes del vencimiento."
            c.sound = .default
            if remaining>0 {
                let trigger=UNTimeIntervalNotificationTrigger(timeInterval:max(1,remaining),repeats:false)
                try? await center.add(UNNotificationRequest(identifier:id,content:c,trigger:trigger))
            }
        }
    }
    private func handle(_ task:BGProcessingTask){
        let work=Task{@MainActor in await renew(automaticRun:true)}
        task.expirationHandler={work.cancel()}
        Task{@MainActor in
            let success=await work.value
            task.setTaskCompleted(success:success)
            schedule()
        }
    }
    func renew(automaticRun:Bool=false) async -> Bool {
        guard !running,!setupActive,let data=ClearSignVault.load() else{return false}
        let profiles=EmbeddedProfile.installed()
        guard profiles.count==2,let until=currentExpiry(profiles) else{status="No hay dos perfiles válidos para comprobar.";return false}
        guard until>Date() else{status="Firma vencida: recuperá la instalación con BariStore.";return false}
        if automaticRun {
            guard automatic,until.timeIntervalSinceNow<=5*86400 else{return true}
            let last=UserDefaults.standard.double(forKey:attemptKey)
            guard Date().timeIntervalSince1970-last>=6*3600 else{return false}
        }
        running=true;status="Solicitando perfiles de app y extensión…"
        UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:attemptKey)
        defer{running=false;schedule();Task{await notifications()}}
        let request=SignRequest(bundles:profiles.map{.init(bundleID:$0.bundleID,profile:$0.bytes.base64EncodedString())},
                                previousExpiry:UInt64(max(0,until.timeIntervalSince1970)))
        guard let encoded=try? JSONEncoder().encode(request) else{return false}
        do{
            let response=try await Task.detached(priority:.utility){
                try Self.runNative(data:data,request:encoded)
            }.value
            // Keep a renewed token/anisette state, never log or expose it.
            try ClearSignVault.save(response.files)
            guard response.result.ok,let e=response.result.expiry else{
                status="Renovación no confirmada: "+Self.explanation(response.result.code)
                return false
            }
            let new=Date(timeIntervalSince1970:Double(e))
            guard new>until else{status="El vencimiento no se extendió.";return false}
            let receipt=SignReceipt(installation:installation(profiles),expiry:new,at:Date())
            UserDefaults.standard.set(try JSONEncoder().encode(receipt),forKey:receiptKey)
            expiry=new;status="Ambos perfiles aceptados por el servicio del dispositivo."
            return true
        }catch{status="Renovación no confirmada: "+error.localizedDescription;return false}
    }
    nonisolated private static func runNative(data:[String:Data],request:Data) throws -> (result:SignResult,files:[String:Data]){
        let fm=FileManager.default
        let root=try fm.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        var dir=root.appendingPathComponent("ClearSign-Transient",isDirectory:true)
        // Only a single native invocation is permitted by the coordinator.
        try? fm.removeItem(at:dir)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication,.posixPermissions:0o700])
        var rv=URLResourceValues();rv.isExcludedFromBackup=true;try dir.setResourceValues(rv)
        defer{try? fm.removeItem(at:dir)}
        for (name,bytes) in data where ClearSignVault.allowed(name){
            let target=dir.appendingPathComponent(name)
            try bytes.write(to:target,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        }
        let pointer:UnsafeMutablePointer<CChar>?=dir.path.withCString{path in
            request.withUnsafeBytes{raw in
                guard let p=raw.bindMemory(to:UInt8.self).baseAddress else{return nil}
                return nativeRefresh(path,p,request.count)
            }
        }
        guard let pointer else{throw ClearSignError(message:"El motor no respondió.")}
        defer{nativeFree(pointer)}
        let response=try JSONDecoder().decode(SignResult.self,from:Data(String(cString:pointer).utf8))
        let updated=try ClearSignVault.readFolder(dir)
        return (response,updated)
    }
    private static func explanation(_ code:String?)->String{
        switch code{
        case "session_unavailable","session_route_invalid":return "sesión de Apple no disponible. Requiere configuración local explícita."
        case "vpn_or_pairing_unavailable","pairing_missing":return "LocalDevVPN o emparejamiento no disponible."
        case "certificate_changed","entitlements_changed","profile_identity_mismatch","device_mismatch":return "el perfil no coincide con la firma instalada; no se instaló."
        case "profile_not_extended":return "Apple no entregó una extensión del vencimiento."
        case "device_install_failed":return "el dispositivo rechazó al menos un perfil; no se confirma la renovación."
        case "timeout":return "tiempo de espera agotado."
        default:return code ?? "error sin detalle."
        }
    }
}

struct SigningPanel:View {
    @ObservedObject private var signing=ClearSign.shared
    @State private var importing=false
    var body:some View{
        Text("ClearSign · experimental").font(.headline)
        if let expiry=signing.expiry {
            LabeledContent("Vencimiento de perfiles",value:expiry.formatted(date:.abbreviated,time:.shortened))
        }else{Text("Vencimiento no disponible.")}
        Text(signing.status).font(.footnote)
        Toggle("Renovación preventiva",isOn:$signing.automatic).disabled(!signing.configured || signing.running || signing.setupActive)
        Button("Migrar sesión local existente (opcional)"){importing=true}.disabled(signing.running || signing.setupActive)
        Button("Renovar ahora"){Task{_ = await signing.renew()}}.disabled(!signing.configured || signing.running || signing.setupActive)
        Button("Habilitar avisos de vencimiento"){Task{await signing.enableAlerts()}}
        Button("Eliminar sesión de firma",role:.destructive){signing.forget()}.disabled(!signing.configured || signing.running || signing.setupActive)
        Text("Requiere LocalDevVPN y sesión válida. iOS decide cuándo ejecuta tareas en segundo plano. Si vence, recuperá con BariStore. No se almacena contraseña ni clave privada de firma.")
            .font(.caption).foregroundStyle(.secondary)
            .fileImporter(isPresented:$importing,allowedContentTypes:[.folder]){result in
                switch result{case .success(let url):signing.importSession(url);case .failure:break}
            }
    }
}
