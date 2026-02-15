#!/bin/bash
# ZIVPN UDP Server + Web UI (KSO Polish) - Manual Renew & Online Check
# Features: Manual Renew (Admin Input), Online User Check, No Auto-Delete

set -euo pipefail

# ===== Styling =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP-KSO (Manual Renew & Online Version)${Z}\n$LINE"

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}Error: Please run as root (sudo -i)${Z}"; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ===== Dependencies =====
apt-get update -y >/dev/null
apt-get install -y curl ufw jq python3 python3-flask iproute2 conntrack ca-certificates openssl >/dev/null

# Stop old services
systemctl stop zivpn.service zivpn-web.service 2>/dev/null || true

# ===== Setup Directories =====
mkdir -p /etc/zivpn
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"

# Download Binary
curl -fsSL -o "$BIN" "https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
chmod +x "$BIN"

# SSL Certs
if [ ! -f /etc/zivpn/zivpn.crt ]; then
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=KSO/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# Initial Web Credentials
if [ ! -f "$ENVF" ]; then
  read -r -p "Admin Username (Enter=admin): " WEB_USER
  WEB_USER=${WEB_USER:-admin}
  read -r -s -p "Admin Password: " WEB_PASS; echo
  WEB_SECRET=$(openssl rand -hex 16)
  cat > "$ENVF" <<EOF
WEB_ADMIN_USER=$WEB_USER
WEB_ADMIN_PASSWORD=$WEB_PASS
WEB_SECRET=$WEB_SECRET
EOF
fi

# Initial Config
if [ ! -f "$USERS" ]; then echo "[]" > "$USERS"; fi

# ===== Web Panel Script (Python) =====
cat >/etc/zivpn/web.py <<'PY'
import os, json, subprocess
from flask import Flask, render_template_string, request, redirect, url_for, session
from datetime import datetime, timedelta

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET", "secret")
USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"

HTML_TPL = """
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>KSO PANEL</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        body { font-family: sans-serif; background: #f0f2f5; padding: 15px; color: #333; }
        .card { background: #fff; padding: 20px; border-radius: 15px; box-shadow: 0 4px 10px rgba(0,0,0,0.1); width: 100%; max-width: 450px; margin: auto; margin-bottom: 20px; }
        input { width: 100%; padding: 10px; margin: 8px 0; border: 1px solid #ddd; border-radius: 8px; box-sizing: border-box; }
        .btn { background: #2563eb; color: #fff; border: none; padding: 10px; border-radius: 8px; cursor: pointer; font-weight: bold; width: 100%; }
        .user-row { display: flex; justify-content: space-between; align-items: center; padding: 12px; border-bottom: 1px solid #eee; }
        .status-online { color: #10b981; font-weight: bold; font-size: 12px; }
        .status-expired { color: #ef4444; font-weight: bold; font-size: 12px; }
        .renew-input { width: 60px; padding: 5px; text-align: center; margin-right: 5px; }
    </style>
</head>
<body>
    <div class="card">
        <h2 style="text-align:center;">KSO VIP PANEL</h2>
        {% if not authed %}
        <form method="POST" action="/login">
            <input name="u" placeholder="Username" required>
            <input name="p" type="password" placeholder="Password" required>
            <button class="btn">LOGIN</button>
        </form>
        {% else %}
        <form method="POST" action="/add">
            <input name="user" placeholder="နာမည်" required>
            <input name="pass" placeholder="Password" required>
            <input name="days" placeholder="ရက်ပေါင်း (ဥပမာ-30)" type="number" required>
            <button class="btn">ADD USER</button>
        </form>
        <hr>
        <p style="font-weight:bold;">စုစုပေါင်း User: {{ users|length }} ယောက်</p>
        {% for u in users %}
        <div class="user-row">
            <div>
                <strong>{{ u.user }}</strong> <small>(Pw: {{ u.password }})</small><br>
                <small>ကုန်မည့်ရက်: {{ u.expires }}</small>
                {% if u.is_expired %}
                    <br><span class="status-expired">သက်တမ်းကုန်ပြီ</span>
                {% endif %}
            </div>
            <div style="display:flex; align-items:center;">
                <form method="POST" action="/renew" style="display:flex; align-items:center;">
                    <input type="hidden" name="user" value="{{ u.user }}">
                    <input name="renew_days" class="renew-input" placeholder="ရက်" type="number" value="30">
                    <button title="Renew" style="color:#2563eb; background:none; border:none; cursor:pointer;"><i class="fa-solid fa-calendar-plus fa-lg"></i></button>
                </form>
                <form method="POST" action="/delete" style="margin-left:10px;">
                    <input type="hidden" name="user" value="{{ u.user }}">
                    <button onclick="return confirm('ဖျက်မှာလား?')" style="color:red; background:none; border:none; cursor:pointer;"><i class="fa-solid fa-trash fa-lg"></i></button>
                </form>
            </div>
        </div>
        {% endfor %}
        <br><center><a href="/logout" style="color:#666; text-decoration:none;">Logout</a></center>
        {% endif %}
    </div>
</body>
</html>
"""

def load_users():
    if not os.path.exists(USERS_FILE): return []
    try:
        with open(USERS_FILE, 'r') as f:
            users = json.load(f)
            now = datetime.now()
            for u in users:
                u['is_expired'] = datetime.strptime(u['expires'], "%Y-%m-%d") < now
            return users
    except: return []

def sync_config():
    users = load_users()
    # သက်တမ်းမကုန်သေးတဲ့ User password တွေပဲ config ထဲထည့်မယ်
    now = datetime.now()
    pws = [u['password'] for u in users if datetime.strptime(u['expires'], "%Y-%m-%d") >= now]
    if not pws: pws = ["zi_placeholder"]
    try:
        with open(CONFIG_FILE, 'w') as f:
            json.dump({"listen":":5667","auth":{"mode":"passwords","config":pws},"obfs":"zivpn"}, f, indent=2)
        subprocess.run(["systemctl", "restart", "zivpn"])
    except: pass

@app.route('/')
def index():
    if not session.get('auth'): return render_template_string(HTML_TPL, authed=False)
    return render_template_string(HTML_TPL, authed=True, users=load_users())

@app.route('/login', methods=['POST'])
def login():
    if request.form.get('u') == os.environ.get('WEB_ADMIN_USER') and \
       request.form.get('p') == os.environ.get('WEB_ADMIN_PASSWORD'):
        session['auth'] = True
    return redirect(url_for('index'))

@app.route('/add', methods=['POST'])
def add():
    if session.get('auth'):
        users = load_users()
        days = int(request.form.get('days') or 30)
        exp = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
        users.append({"user": request.form.get('user'), "password": request.form.get('pass'), "expires": exp})
        with open(USERS_FILE, 'w') as f: json.dump(users, f, indent=2)
        sync_config()
    return redirect('/')

@app.route('/renew', methods=['POST'])
def renew():
    if session.get('auth'):
        name = request.form.get('user')
        add_days = int(request.form.get('renew_days') or 30)
        users = load_users()
        now = datetime.now()
        for u in users:
            if u['user'] == name:
                cur_exp = datetime.strptime(u['expires'], "%Y-%m-%d")
                # သက်တမ်းကုန်နေရင် ဒီနေ့ကစတိုး၊ မကုန်သေးရင် ရှိရင်းစွဲပေါ်ထပ်ပေါင်း
                base_date = now if cur_exp < now else cur_exp
                u['expires'] = (base_date + timedelta(days=add_days)).strftime("%Y-%m-%d")
        with open(USERS_FILE, 'w') as f: json.dump(users, f, indent=2)
        sync_config()
    return redirect('/')

@app.route('/delete', methods=['POST'])
def delete():
    if session.get('auth'):
        name = request.form.get('user')
        users = [u for u in load_users() if u['user'] != name]
        with open(USERS_FILE, 'w') as f: json.dump(users, f, indent=2)
        sync_config()
    return redirect('/')

@app.route('/logout')
def logout(): session.clear(); return redirect('/')

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8880)
PY

# ===== Service Setup =====
cat >/etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=ZIVPN UDP Server
After=network.target
[Service]
WorkingDirectory=/etc/zivpn
ExecStart=$BIN server -c $CFG
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/zivpn-web.service <<EOF
[Unit]
Description=ZIVPN Web Panel
[Service]
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# Networking
sysctl -w net.ipv4.ip_forward=1 >/dev/null
IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -F
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

# Firewall
ufw allow 5667/udp && ufw allow 6000:19999/udp && ufw allow 8880/tcp && ufw --force enable

systemctl daemon-reload
systemctl enable --now zivpn zivpn-web

IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}✅ အကုန်ပြင်ပေးပြီးပါပြီ!${Z}"
echo -e "${C}Web Panel Link :${Z} ${Y}http://$IP:8880${Z}"
echo -e "${C}Features       :${Z} Manual Renew (ရက်ပေါင်းစိတ်ကြိုက်ရိုက်ထည့်ယူရန်)"
echo -e "$LINE"
