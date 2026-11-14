// Vérifie la logique sans interface de l'app (Sources/PVEHub/Logic.swift), sous Linux ou macOS :
//   swiftc ../Sources/PVEHub/Logic.swift main.swift -o /tmp/pvehub-check && /tmp/pvehub-check
import Foundation

var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ what: String, line: Int = #line) {
    if got != want { failures += 1; print("✗ ligne \(line) \(what) : obtenu \(got), attendu \(want)") }
}

// JSON dynamique : nombres en texte, booléens, null, champs absents
let raw = #"{"vmid": 101, "name": "web", "cpu": 0.25, "template": 0, "mem": "1024", "on": true, "tags": ["a", "b"], "n": null, "sub": {"x": 2}}"#
let j = J(try! JSONSerialization.jsonObject(with: Data(raw.utf8)))
check(j.vmid.str, "101", "vmid.str")
check(j.vmid.int, 101, "vmid.int")
check(j.cpu.num, 0.25, "cpu.num")
check(j.template.bool, false, "template.bool")
check(j.on.bool, true, "on.bool")
check(j.mem.num, 1024, "mem en texte")
check(j.tags.strs, ["a", "b"], "tags.strs")
check(j.n.isNil, true, "null")
check(j.absent.isNil, true, "champ absent")
check(j.absent.str, "", "champ absent .str")
check(j.sub.x.int, 2, "imbriqué")
check(j.id, "101", "id : repli sur vmid")
check(J(["id": "lxc/101", "vmid": 101]).id, "lxc/101", "id prioritaire")
check(J(["volid": "local:backup/x"]).id, "local:backup/x", "id : volid")
check(J(nil).arr.count, 0, "arr vide")
let body: [String: Any] = ["report": orNull(nil as String?), "id": orNull("x")]
check(JSONSerialization.isValidJSONObject(body), true, "orNull donne du JSON valide")

// formats
check(fb(0), "0 o", "fb 0")
check(fb(1536), "2 Ko", "fb Ko")
check(fb(1_073_741_824), "1,0 Go", "fb Go")
check(fb(2.5 * 1_099_511_627_776), "2,5 To", "fb To")
check(up(90_061), "1 j 1 h", "up jours")
check(up(3720), "1 h 2 min", "up heures")
check(pct(5, 0), 0, "pct total nul")
check(pct(150, 100), 100, "pct plafonné")
check(withScheme("192.168.1.2:8096"), "http://192.168.1.2:8096", "withScheme ajoute http")
check(withScheme("HTTPS://x.ts.net"), "HTTPS://x.ts.net", "withScheme garde https")
check(plural(1, "cœur"), "1 cœur", "plural 1")
check(plural(4, "cœur"), "4 cœurs", "plural 4")
check(hmString(hmDate("07:05")), "07:05", "heure aller-retour")
check(uaName("PVEHub-iOS (iPhone; iOS 26.1)"), "iPhone", "User-Agent de l'app")
check(uaName("curl/8"), "Appareil inconnu", "User-Agent inconnu")

// cron → français (mêmes règles que la version web)
check(cronFr("@reboot"), "Au démarrage", "@reboot")
check(cronFr("* * * * *"), "Chaque minute", "chaque minute")
check(cronFr("*/5 * * * *"), "Toutes les 5 minutes", "toutes les 5 min")
check(cronFr("0 * * * *"), "Toutes les heures à :00", "toutes les heures")
check(cronFr("30 */2 * * *"), "Toutes les 2 heures à :30", "toutes les 2 h")
check(cronFr("0 3 * * *"), "Tous les jours à 03:00", "tous les jours")
check(cronFr("15 4 * * 1-5"), "Du lundi au vendredi à 04:15", "plage de jours")
check(cronFr("0 3 * * mon,wed,fri"), "Le lundi, mercredi et vendredi à 03:00", "liste de jours")
check(cronFr("0 3 * * 7"), "Le dimanche à 03:00", "dimanche = 7")
check(cronFr("0 3 1 * *"), "Le 1er de chaque mois à 03:00", "1er du mois")
check(cronFr("0 3 15 * *"), "Le 15 de chaque mois à 03:00", "15 du mois")
check(cronFr("0 3 * 1 *"), nil, "mois précis : expression brute")
check(cronFr("0 3 * * *  extra"), nil, "trop de champs")

// planification Proxmox
check(scheduleFr("01:00"), "Tous les jours à 01:00", "tous les jours")
check(scheduleFr("1:30"), "Tous les jours à 01:30", "heure sur un chiffre")
check(scheduleFr("sun 02:00"), "Le dimanche à 02:00", "un jour")
check(scheduleFr("mon..fri 21:00"), "Du lundi au vendredi à 21:00", "plage")
check(scheduleFr("sat,sun 03:00"), "Le samedi et dimanche à 03:00", "liste")
check(scheduleFr(""), "Planification inconnue", "vide")
check(scheduleFr("*/2:00"), "*/2:00", "exotique gardée telle quelle")
check(bkParse("02:00").map { "\($0.0) \($0.1)" }, "02:00 all", "bkParse tous les jours")
check(bkParse("mon..fri 21:00").map { "\($0.0) \($0.1)" }, "21:00 week", "bkParse semaine")
check(bkParse("sat,sun 3:05").map { "\($0.0) \($0.1)" }, "03:05 weekend", "bkParse week-end")
check(bkParse("sun 02:00").map { "\($0.0) \($0.1)" }, "02:00 sun", "bkParse dimanche")
check(bkParse("tue 02:00").map { "\($0.0) \($0.1)" }, nil, "bkParse hors préréglages")

// Hermes : blocs d'action, demandes lxc-approve, découpage des messages
let msg = "Je redémarre :\n```pvehub\n{\"action\":\"reboot\",\"vmid\":101}\n```\nPuis :\n```bash\n$ apt update\n```\n```choix\n- Oui\n- Non\n```"
check(matches(ACTION_RE, msg), ["{\"action\":\"reboot\",\"vmid\":101}"], "bloc pvehub")
let parts = splitMessage(msg)
check(parts.map { $0.0 ?? "texte" }, ["texte", "pvehub", "texte", "bash", "choix"], "découpage : types")
check(parts[3].1, "$ apt update\n", "découpage : contenu bash")
check(splitMessage("```pvehub {\"action\":\"start\"}```").first?.0, "pvehub", "bloc sur une ligne")
check(splitMessage("Voici :\n```bash\nls").map { $0.0 ?? "texte" }, ["texte", "bash"], "bloc pas encore fermé")
check(splitMessage("juste du texte").count, 1, "texte seul")
let lxc = #"Lance : printf 'approve %s exec 101 -- apt update\n' "$(date +%s)" > /root/.lxc-approve et encore printf 'approve %s exec 101 -- apt update\n' "$(date +%s)" > /root/.lxc-approve"#
check(lxcGrants(lxc), ["exec 101 -- apt update"], "lxc-approve (dédoublonné)")

print(failures == 0 ? "✓ logique OK" : "\(failures) échec(s)")
exit(failures == 0 ? 0 : 1)
