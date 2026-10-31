"""CrystalHost - kostenloser Minecraft-Server auf dem eigenen PC, mit Web-Panel.

Wird vom CrystalHost-Setup eingerichtet. Ordner:
  host.py, host.json (Einstellungen), web/index.html (Panel), runtime/ (Java, Tunnel), server/ (Minecraft)
Panel:  http://127.0.0.1:<panelPort>   - von unterwegs ueber die Panel-Adresse (Cloudflare-Tunnel)
Login:  Owner-Code aus ZUGANG.txt (wird beim ersten Start erzeugt)
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import struct
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

BASE = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(BASE, "host.json"), encoding="utf-8-sig") as _f:
    CFG = json.load(_f)
# Minecraft-Ordner: neu eingerichtet (server/) oder ein schon vorhandener Server auf dem PC (serverDir)
DIR = os.path.realpath(CFG.get("serverDir") or os.path.join(BASE, "server"))  # nur dieser Ordner ist im Dateimanager sichtbar
JAR = CFG.get("jar") or "server.jar"
# Server-ID: steckt in jedem Login-Code; darunter findet die CrystalHost-Website die aktuelle Panel-Adresse
if not CFG.get("serverId"):
    import secrets as _s
    CFG["serverId"] = _s.token_hex(6)
    with open(os.path.join(BASE, "host.json"), "w", encoding="utf-8") as _f:
        json.dump(CFG, _f, indent=2, ensure_ascii=False)
SERVER_ID = CFG["serverId"].lower()
RELAY = "https://ntfy.sh/crystalhost-" + SERVER_ID
PORT = int(CFG.get("panelPort", 8130))
MC_PORT = int(CFG.get("port", 25565))
ALLOWED_ORIGINS = {"https://crystalsmp.github.io", f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"}
ADDRESS_TXT = os.path.join(BASE, "PANEL-ADRESSE.txt")  # aktuelle Panel-Adresse fuer unterwegs
# Panel-Seite liegt im Server-Ordner und wird direkt ausgeliefert: http://127.0.0.1:8130
WEB_FILE = os.path.join(BASE, "web", "index.html")
ACCESS_FILE = os.path.join(BASE, "zugang.json")
ACCESS_TXT = os.path.join(BASE, "ZUGANG.txt")
LOG = os.path.join(BASE, "host.log")
JAVA = CFG.get("java") or "java"
RAM_MB = int(CFG.get("ramMb", 4096))
PUBLIC = {"panel": None, "address": None}  # Tunnel-Adressen (werden im Panel angezeigt)

SESSION_HOURS = 12
sessions = {}          # token -> {id, name, role, exp}
fails = {}             # ip -> [zeitpunkte]
activity = []          # letzte Aktionen (fuer die Seite)
lock = threading.Lock()


def log(msg):
    line = time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def remember(name, action):
    with lock:
        activity.append({"t": int(time.time() * 1000), "user": name, "action": action})
        del activity[:-50]
    log(f"{name}: {action}")


# ------------------------------------------------------------------ Zugang

ROLES = {"owner": "Owner", "coowner": "Co-Owner"}


def load_access():
    """Zugaenge: {"users": {id: {name, role, hash, created}}}. Gespeichert wird nur der Hash des Codes.
    Beim allerersten Start wird ein Owner-Code erzeugt (steht einmalig in PANEL-ZUGANG.txt)."""
    data = None
    if os.path.exists(ACCESS_FILE):
        with open(ACCESS_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if "users" not in data:  # altes Format {name: hash} -> erster Eintrag wird Owner
            users = {}
            for i, (name, digest) in enumerate(data.items()):
                users[secrets.token_hex(6)] = {"name": name, "role": "owner" if i == 0 else "coowner", "hash": digest, "created": int(time.time() * 1000)}
            data = {"users": users}
            save_access(data)
    if not data or not data.get("users"):
        code = new_code()
        data = {"users": {secrets.token_hex(6): {"name": CFG.get("owner", "Owner"), "role": "owner", "hash": digest_of(code), "created": int(time.time() * 1000)}}}
        save_access(data)
        with open(ACCESS_TXT, "w", encoding="utf-8") as f:
            f.write("CrystalHost - dein Owner-Code fuer das Panel (gut aufbewahren!)\n\n" + code + "\n")
        log("Owner-Code erzeugt -> PANEL-ZUGANG.txt")
    return data


def save_access(data):
    tmp = ACCESS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, ACCESS_FILE)


def new_code():
    # CH-<Server-ID>-<Geheimteil>: die Website liest die Server-ID, nur der ganze Code meldet an
    return "CH-" + SERVER_ID.upper() + "-" + "-".join(secrets.token_hex(3).upper() for _ in range(4))


def digest_of(code):
    return hashlib.sha256(code.strip().upper().encode()).hexdigest()


# Rechte, die der Owner pro Code einstellen kann (Owner hat immer alle)
PERMS = {
    "power": "Server starten, stoppen & neu starten",
    "console": "Konsole ansehen",
    "command": "Befehle in der Konsole ausführen",
    "files": "Dateien ansehen & herunterladen",
    "files_edit": "Dateien hochladen, bearbeiten & löschen",
    "plugins": "Plugins hochladen & an/aus schalten",
}
DEFAULT_PERMS = list(PERMS)


def perms_of(uid):
    """Aktuelle Rechte (live aus der Datei - Aenderungen wirken sofort)."""
    u = load_access()["users"].get(uid)
    if not u:
        return set()
    if u["role"] == "owner":
        return set(PERMS) | {"users"}
    return set(u.get("perms", DEFAULT_PERMS)) & set(PERMS)


def clean_perms(perms):
    return [p for p in PERMS if p in set(perms or [])]


def set_perms(uid, perms, by):
    data = load_access()
    u = data["users"].get(uid)
    if not u:
        raise FileError("Zugang nicht gefunden")
    if u["role"] == "owner":
        raise FileError("Owner haben immer alle Rechte")
    u["perms"] = clean_perms(perms)
    save_access(data)
    remember(by, f"Rechte geaendert: {u['name']}")


def check_key(key):
    digest = digest_of(key)
    for uid, u in load_access()["users"].items():
        if hmac.compare_digest(digest, u["hash"]):
            return {"id": uid, "name": u["name"], "role": u["role"]}
    return None


def list_users():
    return [{"id": uid, "name": u["name"], "role": u["role"], "roleName": ROLES.get(u["role"], u["role"]), "created": u.get("created"),
             "perms": sorted(perms_of(uid) - {"users"}, key=list(PERMS).index)}
            for uid, u in load_access()["users"].items()]


def create_user(name, role, by, perms=None):
    name = re.sub(r"[^\w .-]", "", name or "").strip()[:24]
    if not name:
        raise FileError("Name fehlt")
    if role not in ROLES:
        raise FileError("Rolle ungueltig")
    data = load_access()
    code = new_code()
    entry = {"name": name, "role": role, "hash": digest_of(code), "created": int(time.time() * 1000)}
    if role != "owner":
        entry["perms"] = clean_perms(DEFAULT_PERMS if perms is None else perms)
    data["users"][secrets.token_hex(6)] = entry
    save_access(data)
    remember(by, f"Zugang erstellt: {name} ({ROLES[role]})")
    return code


def reset_user(uid, by):
    data = load_access()
    u = data["users"].get(uid)
    if not u:
        raise FileError("Zugang nicht gefunden")
    code = new_code()
    u["hash"] = digest_of(code)
    save_access(data)
    end_sessions(uid)
    remember(by, f"Neuer Code fuer {u['name']}")
    return code


def delete_user(uid, by_user):
    data = load_access()
    u = data["users"].get(uid)
    if not u:
        raise FileError("Zugang nicht gefunden")
    if uid == by_user["id"]:
        raise FileError("Du kannst dich nicht selbst entfernen")
    del data["users"][uid]
    save_access(data)
    end_sessions(uid)
    remember(by_user["name"], f"Zugang entfernt: {u['name']}")


def end_sessions(uid):
    with lock:
        for t, s in list(sessions.items()):
            if s["id"] == uid:
                sessions.pop(t, None)


def blocked(ip):
    now = time.time()
    with lock:
        fails[ip] = [t for t in fails.get(ip, []) if now - t < 600]
        return len(fails[ip]) >= 5


# ------------------------------------------------------------------ Server-Steuerung

def props():
    out = {}
    with open(os.path.join(DIR, "server.properties"), encoding="utf-8") as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def rcon(command):
    p = props()
    if p.get("enable-rcon") != "true":
        return None
    password = re.sub(r"\\(.)", r"\1", p.get("rcon.password", ""))
    try:
        with socket.create_connection(("127.0.0.1", int(p.get("rcon.port", 25575))), timeout=5) as s:
            def send(pid, ptype, body):
                data = body.encode("utf-8")
                s.sendall(struct.pack("<iii", len(data) + 10, pid, ptype) + data + b"\x00\x00")
                head = s.recv(4)
                length = struct.unpack("<i", head)[0]
                rest = b""
                while len(rest) < length:
                    rest += s.recv(length - len(rest))
                rid = struct.unpack("<i", rest[:4])[0]
                return rid, rest[8:-2].decode("utf-8", "replace")
            if send(1, 3, password)[0] == -1:
                return None
            return re.sub(r"§.", "", send(2, 2, command)[1])
    except OSError:
        return None


def ps(command):
    try:
        return subprocess.run(["powershell", "-NoProfile", "-Command", command],
                              capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return ""


PROC = {"p": None, "want": False, "restarts": []}


def java_pid():
    p = PROC["p"]
    if p and p.poll() is None:
        return p.pid
    # Server wurde vor einem Panel-Neustart gestartet: am Server-Ordner in der Befehlszeile erkennen
    jar = os.path.join(DIR, JAR).replace("'", "''")
    out = ps(f"(Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | ? {{ $_.CommandLine -like '*{jar}*' }}).ProcessId")
    return int(out.split()[0]) if out else None


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


_cpu = {"pid": None, "cpu": 0.0, "t": 0.0}


def resources(pid):
    out = ps(f"$p = Get-Process -Id {pid}; '{{0}} {{1}} {{2}}' -f $p.TotalProcessorTime.TotalSeconds, $p.WorkingSet64, (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors")
    try:
        cpu_s, ws, cores = out.split()
        cpu_s, ws, cores = float(cpu_s.replace(",", ".")), int(ws), int(cores)
    except ValueError:
        return None
    now = time.time()
    percent = 0.0
    if _cpu["pid"] == pid and now > _cpu["t"]:
        percent = max(0.0, (cpu_s - _cpu["cpu"]) / (now - _cpu["t"]) / cores * 100)
    _cpu.update(pid=pid, cpu=cpu_s, t=now)
    return {"cpu": round(percent, 1), "ramMb": ws // 1048576}


_status = {"t": 0, "data": None}


def status():
    with lock:
        if time.time() - _status["t"] < 3 and _status["data"]:
            return _status["data"]
    pid = java_pid()
    mc_port = port_open(MC_PORT)
    state = "offline"
    if pid and mc_port:  # mit java gehoert 25565 dem echten Server (der Wecker laeuft nur ohne java)
        state = "online"
    elif pid:
        state = "starting"
    data = {"state": state, "flag": False, "time": int(time.time() * 1000), "name": CFG.get("name", "Server"),
            "version": CFG.get("version"), "address": PUBLIC["address"], "panelUrl": PUBLIC["panel"],
            "localAddress": f"localhost:{MC_PORT}", "ramMax": RAM_MB, "plan": CFG.get("plan", "free"), "serverId": SERVER_ID.upper()}
    if pid:
        data["resources"] = resources(pid)
    if state == "online":
        out = rcon("list") or ""
        m = re.search(r"(\d+)\D+?(\d+)", out)
        if m:
            data["online"], data["max"] = int(m.group(1)), int(m.group(2))
            names = out.split(":", 1)[1] if ":" in out else ""
            data["players"] = [n.strip() for n in re.split(r"[,\n]", names) if n.strip()][:50]
        tps = re.findall(r"(\d+(?:\.\d+)?)", (rcon("tps") or "").replace("*", "").split(":")[-1])
        if tps:
            data["tps"] = min(20.0, float(tps[0]))
        if PROC.get("started"):
            data["uptime"] = int(time.time() - PROC["started"])
    data["activity"] = activity[-15:]
    with lock:
        _status.update(t=time.time(), data=data)
    return data


def launch():
    os.makedirs(os.path.join(DIR, "logs"), exist_ok=True)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    PROC["p"] = subprocess.Popen([JAVA, f"-Xms{max(512, RAM_MB // 2)}M", f"-Xmx{RAM_MB}M", "-XX:+UseG1GC",
                                  # Windows-Zertifikate nutzen (Virenscanner/Router mit HTTPS-Pruefung brechen sonst den ersten Download ab)
                                  "-Djavax.net.ssl.trustStoreType=Windows-ROOT",
                                  "-jar", os.path.join(DIR, JAR), "nogui"],
                                 cwd=DIR, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 creationflags=flags)
    PROC["started"] = time.time()


def start_server(name):
    if java_pid():
        return "Server laeuft bereits"
    PROC["want"] = True
    launch()
    remember(name, "Server gestartet")
    return "Server wird gestartet (dauert ca. 30-60 Sekunden)"


def send_console(cmd):
    """Befehl an die Server-Konsole: direkt ueber stdin, sonst per RCON."""
    p = PROC["p"]
    if p and p.poll() is None and p.stdin:
        try:
            p.stdin.write((cmd + "\n").encode("utf-8"))
            p.stdin.flush()
            return True
        except OSError:
            pass
    return rcon(cmd) is not None


def stop_server(name, restart):
    if not java_pid():
        if restart:
            return start_server(name)
        return "Server ist schon aus"
    PROC["want"] = False
    if not send_console("stop"):
        return "Server nicht erreichbar"
    remember(name, "Server neu gestartet" if restart else "Server gestoppt")
    if restart:
        def again():
            for _ in range(120):  # bis zu 2 Minuten auf das Herunterfahren warten
                if not java_pid():
                    break
                time.sleep(1)
            PROC["want"] = True
            launch()
        threading.Thread(target=again, daemon=True).start()
        return "Neustart laeuft (dauert ca. 1 Minute)"
    return "Server wird gestoppt"


def clean_stop():
    try:
        with open(os.path.join(DIR, "logs", "latest.log"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 8192))
            return re.search(rb"Stopping (the )?server", f.read()) is not None
    except OSError:
        return False  # kein Log = Server kam nicht mal hoch -> wie Absturz behandeln


def supervisor():
    """Startet den Server nach einem Absturz neu (max. 3x in 10 Minuten)."""
    while True:
        time.sleep(10)
        p = PROC["p"]
        if PROC["want"] and p and p.poll() is not None:
            if clean_stop():  # z. B. /stop im Spiel -> aus lassen
                PROC["want"] = False
                remember("System", "Server wurde beendet")
                continue
            now = time.time()
            PROC["restarts"] = [t for t in PROC["restarts"] if now - t < 600] + [now]
            if len(PROC["restarts"]) > 3:
                PROC["want"] = False
                remember("System", "Server stuerzt immer wieder ab - automatischer Neustart gestoppt (siehe Konsole)")
                continue
            remember("System", "Server abgestuerzt - starte neu")
            launch()


NOISE = re.compile(r"RCON (Listener|Client)|squaremap-render-progresslogger")


def console(since):
    path = os.path.join(DIR, "logs", "latest.log")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            start = since if 0 < since <= size else max(0, size - 60000)
            f.seek(start)
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return {"lines": [], "pos": 0}
    lines = [l for l in data.splitlines() if l and not NOISE.search(l)]
    return {"lines": lines[-400:], "pos": size}


# ------------------------------------------------------------------ Dateien

MAX_UPLOAD = 95 * 1024 * 1024        # Cloudflare-Quick-Tunnel erlaubt max. 100 MB pro Anfrage
MAX_TEXT = 2 * 1024 * 1024
TRASH = os.path.join(BASE, "papierkorb")
# Zugangsdaten des Panels bleiben unsichtbar und unveraenderbar
HIDDEN = {".papierkorb", ".git"}
TEXT_EXT = {".yml", ".yaml", ".json", ".txt", ".properties", ".toml", ".conf", ".cfg", ".log", ".md", ".mcmeta",
            ".csv", ".ini", ".bat", ".sh", ".ps1", ".py", ".js", ".html", ".css", ".xml", ".lang", ".sk"}


class FileError(Exception):
    pass


def safe_path(rel, must_exist=True):
    """Pfad relativ zum Server-Ordner aufloesen - nie ausserhalb, nie die Panel-Zugangsdaten."""
    rel = (rel or "").replace("\\", "/").strip("/")
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts) or any(p.lower() in HIDDEN for p in parts):
        raise FileError("Pfad nicht erlaubt")
    full = os.path.realpath(os.path.join(DIR, *parts))
    if full != DIR and not full.startswith(DIR + os.sep):
        raise FileError("Pfad nicht erlaubt")
    if must_exist and not os.path.exists(full):
        raise FileError("Nicht gefunden")
    return full, "/".join(parts)


def list_dir(rel):
    full, rel = safe_path(rel)
    if not os.path.isdir(full):
        raise FileError("Kein Ordner")
    items = []
    with os.scandir(full) as it:
        for e in it:
            if e.name.lower() in HIDDEN:
                continue
            try:
                st = e.stat()
            except OSError:
                continue
            is_dir = e.is_dir()
            items.append({"name": e.name, "dir": is_dir, "size": 0 if is_dir else st.st_size, "mtime": int(st.st_mtime * 1000),
                          "text": not is_dir and os.path.splitext(e.name)[1].lower() in TEXT_EXT})
    items.sort(key=lambda i: (not i["dir"], i["name"].lower()))
    return {"path": rel, "items": items}


def read_text(rel):
    full, rel = safe_path(rel)
    if os.path.isdir(full) or os.path.getsize(full) > MAX_TEXT:
        raise FileError("Datei zu gross oder kein Text")
    with open(full, "rb") as f:
        return {"path": rel, "content": f.read().decode("utf-8", "replace")}


def write_text(rel, content, name):
    full, rel = safe_path(rel, must_exist=False)
    if os.path.isdir(full):
        raise FileError("Ist ein Ordner")
    if os.path.exists(full):  # Sicherung der alten Version
        backup = os.path.join(TRASH, time.strftime("%Y%m%d-%H%M%S") + "_" + os.path.basename(full))
        os.makedirs(TRASH, exist_ok=True)
        with open(full, "rb") as src, open(backup, "wb") as dst:
            dst.write(src.read())
    with open(full, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    remember(name, "Datei bearbeitet: " + rel)


def server_running():
    return java_pid() is not None


def save_upload(rel_dir, filename, stream, length, name):
    filename = os.path.basename((filename or "").replace("\\", "/"))
    if not filename or filename.lower() in HIDDEN or filename.startswith("."):
        raise FileError("Dateiname ungueltig")
    if length > MAX_UPLOAD:
        raise FileError("Datei zu gross (max. 95 MB)")
    folder, rel_dir = safe_path(rel_dir)
    if not os.path.isdir(folder):
        raise FileError("Zielordner fehlt")
    note = ""
    target = os.path.join(folder, filename)
    # Plugin ersetzen, waehrend der Server laeuft: Paper tauscht Jars aus plugins/update beim Start aus
    if rel_dir == "plugins" and filename.lower().endswith(".jar") and os.path.exists(target) and server_running():
        os.makedirs(os.path.join(folder, "update"), exist_ok=True)
        target = os.path.join(folder, "update", filename)
        note = " (ersetzt beim naechsten Neustart)"
    tmp = target + ".upload"
    remaining = length
    with open(tmp, "wb") as f:
        while remaining > 0:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            f.write(chunk)
            remaining -= len(chunk)
    if remaining:
        os.remove(tmp)
        raise FileError("Upload abgebrochen")
    os.replace(tmp, target)
    remember(name, f"Hochgeladen: {rel_dir}/{filename}{note}")
    if rel_dir == "plugins" and filename.lower().endswith(".jar") and not note:
        note = " - aktiv nach dem naechsten Neustart"
    return f"{filename} hochgeladen{note}"


def delete_path(rel, name):
    full, rel = safe_path(rel)
    if full == DIR:
        raise FileError("Nicht erlaubt")
    os.makedirs(TRASH, exist_ok=True)
    dest = os.path.join(TRASH, time.strftime("%Y%m%d-%H%M%S") + "_" + os.path.basename(full))
    os.replace(full, dest)  # nichts wird endgueltig geloescht
    remember(name, "In den Papierkorb: " + rel)


def rename_path(rel, new_name, name):
    full, rel = safe_path(rel)
    new_name = os.path.basename((new_name or "").replace("\\", "/"))
    if not new_name or new_name.lower() in HIDDEN or full == DIR:
        raise FileError("Name ungueltig")
    target, _ = safe_path(os.path.join(os.path.dirname(rel), new_name), must_exist=False)
    if os.path.exists(target):
        raise FileError("Name existiert schon")
    os.replace(full, target)
    remember(name, f"Umbenannt: {rel} -> {new_name}")


def make_dir(rel, name):
    full, rel = safe_path(rel, must_exist=False)
    os.makedirs(full, exist_ok=True)
    remember(name, "Ordner erstellt: " + rel)


def plugins():
    folder = os.path.join(DIR, "plugins")
    out = []
    for sub, enabled in (("", True), ("__disabled", False)):
        path = os.path.join(folder, sub)
        if not os.path.isdir(path):
            continue
        for f in os.listdir(path):
            if f.lower().endswith(".jar"):
                st = os.stat(os.path.join(path, f))
                pending = os.path.exists(os.path.join(folder, "update", f))
                out.append({"file": f, "enabled": enabled, "size": st.st_size, "mtime": int(st.st_mtime * 1000), "update": pending})
    out.sort(key=lambda p: p["file"].lower())
    return {"plugins": out, "running": server_running()}


def toggle_plugin(file, enable, name):
    file = os.path.basename(file or "")
    if not file.lower().endswith(".jar"):
        raise FileError("Keine Plugin-Datei")
    folder = os.path.join(DIR, "plugins")
    src = os.path.join(folder, "__disabled" if enable else "", file)
    dst = os.path.join(folder, "" if enable else "__disabled", file)
    if not os.path.exists(src):
        raise FileError("Plugin nicht gefunden")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.replace(src, dst)
    remember(name, ("Plugin aktiviert: " if enable else "Plugin deaktiviert: ") + file)
    return "Gespeichert - wirkt beim naechsten Neustart"


# ------------------------------------------------------------------ Webserver

class Handler(BaseHTTPRequestHandler):
    server_version = "CrystalPanel"

    def log_message(self, *args):
        pass

    def origin_ok(self):
        return self.headers.get("Origin") in ALLOWED_ORIGINS

    def cors(self):
        origin = self.headers.get("Origin")
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Max-Age", "600")

    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def ip(self):
        return self.headers.get("CF-Connecting-IP") or self.client_address[0]

    def user(self):
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        with lock:
            entry = sessions.get(token)
            if entry and entry["exp"] > time.time():
                return entry
            sessions.pop(token, None)
        return None

    def body(self, limit=4096):
        n = min(int(self.headers.get("Content-Length") or 0), limit)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        if self.headers.get("Origin") in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Private-Network", "true")
        self.end_headers()

    def direct_local(self):
        """Anfrage kommt vom Browser auf DIESEM PC - nicht ueber den Tunnel (Cloudflare setzt immer Cf-Ray)."""
        return (self.client_address[0] in ("127.0.0.1", "::1") and not self.headers.get("Cf-Ray")
                and not self.headers.get("CF-Connecting-IP") and self.headers.get("Origin") in ALLOWED_ORIGINS)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/api/ping":
            return self.reply(200, {"ok": True, "name": CFG.get("name", "Server"), "local": self.direct_local()})
        if path in ("/", "/index.html"):
            try:
                with open(WEB_FILE, "rb") as f:
                    page = f.read()
            except OSError:
                return self.reply(404, {"error": "panel-web/index.html fehlt"})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
            return
        me = self.user()
        if not me:
            return self.reply(401, {"error": "Nicht angemeldet"})
        allowed = perms_of(me["id"])
        if path == "/api/me":
            return self.reply(200, {"name": me["name"], "role": me["role"], "roleName": ROLES.get(me["role"]), "perms": sorted(allowed)})
        if path == "/api/users":
            if me["role"] != "owner":
                return self.reply(403, {"error": "Nur der Owner darf Zugaenge verwalten"})
            return self.reply(200, {"users": list_users(), "me": me["id"], "permNames": PERMS})
        if path == "/api/status":
            return self.reply(200, status())
        need = {"/api/console": "console", "/api/files": "files", "/api/file/text": "files",
                "/api/file/download": "files", "/api/plugins": "plugins"}.get(path)
        if need and need not in allowed:
            return self.reply(403, {"error": "Dafür hast du keine Berechtigung"})
        if path == "/api/console":
            m = re.search(r"since=(\d+)", query)
            return self.reply(200, console(int(m.group(1)) if m else 0))
        q = {k: v[0] for k, v in parse_qs(query).items()}
        try:
            if path == "/api/files":
                return self.reply(200, list_dir(q.get("path", "")))
            if path == "/api/file/text":
                return self.reply(200, read_text(q.get("path", "")))
            if path == "/api/plugins":
                return self.reply(200, plugins())
            if path == "/api/file/download":
                full, rel = safe_path(q.get("path", ""))
                if os.path.isdir(full):
                    raise FileError("Ordner koennen nicht heruntergeladen werden")
                size = os.path.getsize(full)
                self.send_response(200)
                self.cors()
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                with open(full, "rb") as f:
                    while chunk := f.read(1024 * 1024):
                        self.wfile.write(chunk)
                return
        except FileError as e:
            return self.reply(400, {"error": str(e)})
        except OSError as e:
            return self.reply(500, {"error": f"Dateifehler: {e.strerror or e}"})
        self.reply(404, {"error": "unbekannt"})

    def do_POST(self):
        if not self.origin_ok():
            return self.reply(403, {"error": "Herkunft nicht erlaubt"})
        path = self.path.split("?")[0]
        if path == "/api/login/local":
            # Auf dem eigenen PC braucht es keinen Code: der Besitzer sitzt ja vor dem Rechner
            if not self.direct_local():
                return self.reply(403, {"error": "Ohne Code nur direkt auf dem PC moeglich, auf dem der Server laeuft"})
            uid, u = next((k, v) for k, v in load_access()["users"].items() if v["role"] == "owner")
            token = secrets.token_urlsafe(32)
            with lock:
                sessions[token] = {"id": uid, "name": u["name"], "role": "owner", "exp": time.time() + SESSION_HOURS * 3600}
            return self.reply(200, {"token": token, "name": u["name"], "role": "owner"})
        if path == "/api/login":
            ip = self.ip()
            if blocked(ip):
                return self.reply(429, {"error": "Zu viele Fehlversuche - warte 10 Minuten"})
            acc = check_key(str(self.body().get("key", "")))
            if not acc:
                with lock:
                    fails.setdefault(ip, []).append(time.time())
                log(f"Fehlgeschlagener Login von {ip}")
                return self.reply(403, {"error": "Schluessel ungueltig"})
            token = secrets.token_urlsafe(32)
            with lock:
                sessions[token] = {**acc, "exp": time.time() + SESSION_HOURS * 3600}
            remember(acc["name"], "angemeldet")
            return self.reply(200, {"token": token, "name": acc["name"], "role": acc["role"]})
        me = self.user()
        if not me:
            return self.reply(401, {"error": "Nicht angemeldet"})
        name = me["name"]
        allowed = perms_of(me["id"])
        if me["id"] not in load_access()["users"]:  # Zugang wurde inzwischen entfernt
            return self.reply(401, {"error": "Nicht angemeldet"})
        q = {k: v[0] for k, v in parse_qs(self.path.partition("?")[2]).items()}
        need = {"/api/start": "power", "/api/stop": "power", "/api/restart": "power", "/api/command": "command",
                "/api/file/text": "files_edit", "/api/file/delete": "files_edit", "/api/file/rename": "files_edit",
                "/api/file/mkdir": "files_edit", "/api/plugins/toggle": "plugins"}.get(path)
        if path == "/api/upload":  # Plugin-Upload geht auch nur mit dem Plugin-Recht
            is_plugin = q.get("path", "") == "plugins" and q.get("name", "").lower().endswith(".jar")
            need = "files_edit" if not (is_plugin and "plugins" in allowed) else None
        if need and need not in allowed:
            return self.reply(403, {"error": "Dafür hast du keine Berechtigung"})
        if path.startswith("/api/users"):
            if me["role"] != "owner":
                return self.reply(403, {"error": "Nur der Owner darf Zugaenge verwalten"})
            b = self.body()
            try:
                if path == "/api/users/create":
                    perms = b.get("perms") if isinstance(b.get("perms"), list) else None
                    return self.reply(200, {"code": create_user(str(b.get("name", "")), str(b.get("role", "coowner")), name, perms)})
                if path == "/api/users/perms":
                    set_perms(str(b.get("id", "")), b.get("perms") if isinstance(b.get("perms"), list) else [], name)
                    return self.reply(200, {"message": "Rechte gespeichert"})
                if path == "/api/users/reset":
                    return self.reply(200, {"code": reset_user(str(b.get("id", "")), name)})
                if path == "/api/users/delete":
                    delete_user(str(b.get("id", "")), me)
                    return self.reply(200, {"message": "Zugang entfernt"})
            except FileError as e:
                return self.reply(400, {"error": str(e)})
        if path == "/api/start":
            return self.reply(200, {"message": start_server(name)})
        if path == "/api/stop":
            return self.reply(200, {"message": stop_server(name, False)})
        if path == "/api/restart":
            return self.reply(200, {"message": stop_server(name, True)})
        if path == "/api/command":
            cmd = str(self.body().get("command", "")).strip().lstrip("/")[:256]
            if not cmd:
                return self.reply(400, {"error": "Kein Befehl"})
            out = rcon(cmd)
            if out is None:
                out = "" if send_console(cmd) else "(Server nicht erreichbar)"
            remember(name, "Befehl: /" + cmd)
            return self.reply(200, {"output": out})
        try:
            if path == "/api/upload":
                length = int(self.headers.get("Content-Length") or 0)
                msg = save_upload(q.get("path", ""), q.get("name", ""), self.rfile, length, name)
                return self.reply(200, {"message": msg})
            if path == "/api/file/text":
                b = self.body(MAX_TEXT + 65536)
                write_text(str(b.get("path", "")), str(b.get("content", "")), name)
                return self.reply(200, {"message": "Gespeichert"})
            if path == "/api/file/delete":
                delete_path(str(self.body().get("path", "")), name)
                return self.reply(200, {"message": "In den Papierkorb verschoben"})
            if path == "/api/file/rename":
                b = self.body()
                rename_path(str(b.get("path", "")), str(b.get("to", "")), name)
                return self.reply(200, {"message": "Umbenannt"})
            if path == "/api/file/mkdir":
                make_dir(str(self.body().get("path", "")), name)
                return self.reply(200, {"message": "Ordner erstellt"})
            if path == "/api/plugins/toggle":
                b = self.body()
                return self.reply(200, {"message": toggle_plugin(str(b.get("file", "")), bool(b.get("enable")), name)})
        except FileError as e:
            return self.reply(400, {"error": str(e)})
        except OSError as e:
            return self.reply(500, {"error": f"Dateifehler: {e.strerror or e}"})
        if path == "/api/logout":
            auth = self.headers.get("Authorization", "")
            with lock:
                sessions.pop(auth[7:], None)
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "unbekannt"})


# ------------------------------------------------------------------ Tunnel (fuer unterwegs + Freunde)

def run_tunnel(args, pattern, on_url, name):
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    while True:
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, creationflags=flags)
        except OSError:
            log(f"{name}: Programm fehlt - nur lokal erreichbar")
            return
        for line in proc.stdout:
            m = re.search(pattern, line)
            if m:
                on_url(m.group(1))
        proc.wait()
        log(f"{name} beendet - neuer Versuch in 15 s")
        time.sleep(15)


def announce(url):
    """Aktuelle Panel-Adresse unter der Server-ID ablegen (ntfy.sh), damit die CrystalHost-Website sie findet."""
    try:
        req = urllib.request.Request(RELAY, data=url.encode(), method="POST",
                                     headers={"Title": "CrystalHost", "Cache": "yes", "X-Tags": "crystalhost"})
        urllib.request.urlopen(req, timeout=15).close()
        return True
    except Exception as e:
        log(f"Panel-Adresse konnte nicht gemeldet werden: {e}")
        return False


def announce_loop():
    # ntfy behaelt Nachrichten ca. 12 Stunden -> regelmaessig erneuern
    while True:
        time.sleep(4 * 3600)
        if PUBLIC["panel"]:
            announce(PUBLIC["panel"])


def panel_url(url):
    PUBLIC["panel"] = url
    ALLOWED_ORIGINS.add(url)
    with open(ADDRESS_TXT, "w", encoding="utf-8") as f:
        f.write(url + "\n")
    log(f"Panel von unterwegs: {url}" + (" (auf der Website gemeldet)" if announce(url) else ""))


def mc_address(addr):
    PUBLIC["address"] = addr
    log(f"Server-Adresse fuer Freunde: {addr}")


def start_tunnels():
    rt = os.path.join(BASE, "runtime")
    cloudflared = os.path.join(rt, "cloudflared.exe")
    if os.path.exists(cloudflared):
        threading.Thread(target=run_tunnel, daemon=True, args=(
            [cloudflared, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{PORT}"],
            r"(https://[a-z0-9-]+\.trycloudflare\.com)", panel_url, "Panel-Tunnel")).start()
    bore = os.path.join(rt, "bore.exe")
    if os.path.exists(bore) and CFG.get("publicTunnel", True):
        threading.Thread(target=run_tunnel, daemon=True, args=(
            [bore, "local", str(MC_PORT), "--to", "bore.pub"],
            r"listening at (bore\.pub:\d+)", mc_address, "Server-Tunnel")).start()


def main():
    load_access()
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        log(f"Port {PORT} belegt - Panel laeuft schon?")
        return
    if os.environ.get("HOST_NO_TUNNEL") != "1":
        start_tunnels()
    threading.Thread(target=supervisor, daemon=True).start()
    threading.Thread(target=announce_loop, daemon=True).start()
    if CFG.get("autostart", True) and not java_pid():
        PROC["want"] = True
        launch()
        log("Server automatisch gestartet")
    log(f"CrystalHost-Panel: http://127.0.0.1:{PORT}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
