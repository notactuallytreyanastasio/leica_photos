import CoreWLAN
let iface = CWInterface()
do {
    let networks = try iface.scanForNetworks(withSSID: nil)
    for n in networks {
        let ssid = n.ssid ?? "?"
        let flag = ssid.lowercased().contains("leica") || ssid.lowercased().contains("m10") ? "MATCH" : "     "
        print("\(flag) \(ssid)")
    }
} catch {
    print("scan error: \(error)")
    exit(1)
}
