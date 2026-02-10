#!/bin/bash
# ZIVPN UDP Server + Web UI (Myanmar) - KSO Modified Edition
set -euo pipefail

# ===== Colors =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP-KSO Modified Web Panel${Z}\n$LINE"

# Root check
if [ "$(id -u)" -ne 0 ]; then echo -e "${R}Root user ဖြင့် run ပါ${Z}"; exit 1; fi

# Basic Installs
apt-get update -y && apt-get install -y curl ufw jq python3 python3-flask iproute2 conntrack openssl

# Paths
mkdir -p /etc/zivpn
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"

# Download Binary if not exists
if [ ! -f "$BIN" ]; then
  curl -fsSL -o "$BIN" "https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
  chmod +x "$BIN"
fi

# Config & Certs
[ -f "$CFG" ] || echo '{"listen":":5667","auth":{"mode":"passwords","config":["zi"]},"obfs":"zivpn"}' > "$CFG"
[ -f "$USERS" ] || echo "[]" > "$USERS"
if [ ! -f /etc/zivpn/zivpn.crt ]; then
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 -subj "/CN=zivpn" -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# Web Admin Credentials
echo -e "${Y}Setup Web Login (Enter လွတ်ပေးက Dev Mode)${Z}"
read -r -p "Username: " WEB_USER
if [ -n "$WEB_USER" ]; then
  read -r -s -p "Password: " WEB_PASS; echo
  WEB_SECRET=$(openssl rand -hex 16)
  echo "WEB_ADMIN_USER=$WEB_USER" > "$ENVF"
  echo "WEB_ADMIN_PASSWORD=$WEB_PASS" >> "$ENVF"
  echo "WEB_SECRET=$WEB_SECRET" >> "$ENVF"
else
  rm -f "$ENVF"
fi

# ===== Web UI (Python/Flask) =====
cat > /etc/zivpn/web.py << 'PY'
import os, json, subprocess, tempfile, hmac
from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify
from datetime import datetime, timedelta

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "kso-dev-key")
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"

def load_data():
    try:
        with open(USERS_FILE, "r") as f: return json.load(f)
    except: return []

def save_data(data):
    with open(USERS_FILE, "w") as f: json.dump(data, f, indent=2)
    # Sync to config.json
    try:
        with open(CONFIG_FILE, "r") as f: cfg = json.load(f)
        cfg["auth"]["config"] = [u["password"] for u in data if "password" in u]
        with open(CONFIG_FILE, "w") as f: json.dump(cfg, f, indent=2)
        subprocess.run(["systemctl", "restart", "zivpn"], check=False)
    except: pass

HTML = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>KSO PANEL</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        :root { --p: #2563eb; --bg: #f8fafc; --card: #ffffff; }
        body { font-family: sans-serif; background: var(--bg); margin: 0; padding: 20px; display: flex; flex-direction: column; align-items: center; }
        .container { width: 100%; max-width: 450px; }
        .card { background: var(--card); padding: 20px; border-radius: 15px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); margin-bottom: 20px; }
        .input-group { margin-bottom: 15px; }
        label { display: block; font-size: 12px; font-weight: bold; color: #64748b; margin-bottom: 5px; }
        input { width: 100%; padding: 10px; border: 1px solid #e2e8f0; border-radius: 8px; box-sizing: border-box; }
        .btn { cursor: pointer; border: none; padding: 10px 15px; border-radius: 8px; font-weight: bold; }
        .btn-add { background: var(--p); color: white; width: 100%; }
        .btn-exp { background: #f1f5f9; color: #475569; font-size: 11px; margin-right: 5px; }
        .user-row { display: flex; align-items: center; justify-content: space-between; padding: 15px; background: white; border-radius: 12px; margin-bottom: 10px; border-left: 5px solid #ccc; position: relative; }
        .status-green { border-left-color: #10b981; }
        .status-yellow { border-left-color: #f59e0b; }
        .status-red { border-left-color: #ef4444; }
        .user-info b { display: block; font-size: 16px; }
        .user-info span { font-size: 12px; color: #64748b; }
        .actions { display: flex; gap: 8px; }
        .copy-box { background: #1e293b; color: #38bdf8; padding: 10px; border-radius: 8px; font-family: monospace; font-size: 13px; cursor: pointer; margin-bottom: 15px; text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <h2 style="text-align:center; color:var(--p);">KSO VIP PANEL</h2>
        
        <div class="copy-box" onclick="copyIP(this)">
            <i class="fa-solid fa-server"></i> IP: <span id="vpsip">{{ip}}</span> (Click to Copy)
        </div>

        {% if not authed %}
        <div class="card">
            <form method="POST" action="/login">
                <div class="input-group"><label>Username</label><input name="u" required></div>
                <div class="input-group"><label>Password</label><input name="p" type="password" required></div>
                <button class="btn btn-add">LOGIN</button>
            </form>
        </div>
        {% else %}
        <div class="card">
            <form method="POST" action="/add" id="addForm">
                <div class="input-group"><label>နာမည် (Username)</label><input name="user" id="uname" required></div>
                <div class="input-group"><label>စကားဝှက် (Password)</label><input name="password" id="upass" required></div>
                <div class="input-group">
                    <label>ရက်ပေါင်း (Days)</label>
                    <input name="days" id="udays" value="30">
                    <div style="margin-top:8px;">
                        <button type="button" class="btn btn-exp" onclick="setDays(30)">1 လ (30 ရက်)</button>
                        <button type="button" class="btn btn-exp" onclick="setDays(60)">2 လ (60 ရက်)</button>
                    </div>
                </div>
                <button class="btn btn-add"><i class="fa-solid fa-user-plus"></i> သိမ်းဆည်းမည်</button>
            </form>
        </div>

        {% for u in users %}
        {% set rem = u.days_left %}
        <div class="user-row {% if rem > 10 %}status-green{% elif rem > 3 %}status-yellow{% else %}status-red{% endif %}">
            <div class="user-info">
                <b>{{u.user}}</b>
                <span><i class="fa-solid fa-calendar"></i> {{u.expires}} ({{rem}} ရက်ကျန်)</span>
            </div>
            <div class="actions">
                <button class="btn" style="background:#dcfce7; color:#166534;" onclick="editUser('{{u.user}}','{{u.password}}')"><i class="fa-solid fa-pen-to-square"></i></button>
                <form method="POST" action="/delete" style="display:inline;">
                    <input type="hidden" name="user" value="{{u.user}}">
                    <button class="btn" style="background:#fee2e2; color:#991b1b;"><i class="fa-solid fa-trash"></i></button>
                </form>
            </div>
        </div>
        {% endfor %}
        <a href="/logout" style="display:block; text-align:center; color:#ef4444; font-size:13px; text-decoration:none; margin-top:20px;">Logout ထွက်ရန်</a>
        {% endif %}
    </div>

    <script>
        function setDays(d) { document.getElementById('udays').value = d; }
        function editUser(u, p) {
            document.getElementById('uname').value = u;
            document.getElementById('upass').value = p;
            window.scrollTo(0,0);
        }
        function copyIP(el) {
            const ip = document.getElementById('vpsip').innerText;
            navigator.clipboard.writeText(ip);
            const old = el.innerHTML;
            el.innerHTML = "✅ Copied!";
            setTimeout(()=> el.innerHTML = old, 1500);
        }
    </script>
</body>
</html>
"""

@app.route("/")
def index():
    if not hmac.compare_digest(os.environ.get("WEB_ADMIN_USER",""), "") and not session.get("auth"):
        return render_template_string(HTML, authed=False, ip=request.host.split(":")[0])
    
    users = load_data()
    now = datetime.now()
    for u in users:
        try:
            exp = datetime.strptime(u["expires"], "%Y-%m-%d")
            u["days_left"] = (exp - now).days + 1
        except: u["days_left"] = 0
    
    return render_template_string(HTML, authed=True, users=users, ip=request.host.split(":")[0])

@app.route("/login", methods=["POST"])
def login():
    if request.form.get("u") == os.environ.get("WEB_ADMIN_USER") and request.form.get("p") == os.environ.get("WEB_ADMIN_PASSWORD"):
        session["auth"] = True
    return redirect("/")

@app.route("/logout")
def logout():
    session.clear()
    return redirect("/")

@app.route("/add", methods=["POST"])
def add():
    user = request.form.get("user")
    pw = request.form.get("password")
    days = int(request.form.get("days", 30))
    exp_date = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    
    data = load_data()
    # Update if exists, else append
    found = False
    for u in data:
        if u["user"] == user:
            u["password"] = pw
            u["expires"] = exp_date
            found = True; break
    if not found:
        data.append({"user": user, "password": pw, "expires": exp_date})
    
    save_data(data)
    return redirect("/")

@app.route("/delete", methods=["POST"])
def delete():
    user = request.form.get("user")
    data = [u for u in load_data() if u["user"] != user]
    save_data(data)
    return redirect("/")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8880)
PY

# ===== Services Setup =====
cat > /etc/systemd/system/zivpn.service << EOF
[Unit]
Description=ZIVPN UDP Server
After=network.target
[Service]
ExecStart=$BIN server -c $CFG
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/zivpn-web.service << EOF
[Unit]
Description=ZIVPN Web UI
After=network.target
[Service]
EnvironmentFile=-$ENVF
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# Networking
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A PREROUTING -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables -t nat -A POSTROUTING -j MASQUERADE
ufw allow 5667/udp && ufw allow 8880/tcp && ufw allow 6000:19999/udp

systemctl daemon-reload
systemctl enable --now zivpn zivpn-web

IP=$(hostname -I | awk '{print $1}')
echo -e "$LINE"
echo -e "${G}အိုကေပြီ ကိုကို... အောက်က link နဲ့ ဝင်ကြည့်ပါ${Z}"
echo -e "${C}Web Panel: ${Y}http://$IP:8880${Z}"
echo -e "$LINE"
