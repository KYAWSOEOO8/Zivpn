#!/bin/bash
# ZIVPN UDP Server + Web UI (Myanmar) - Clean & Optimized
# Author: Zahid Islam + KSO polish

set -euo pipefail

# ===== Colors & UI =====
B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"
LINE="${B}────────────────────────────────────────────────────────${Z}"
say(){ echo -e "$1"; }

echo -e "\n$LINE\n${G}🌟 ZIVPN UDP-KSO (Cleaned Version)${Z}\n$LINE"

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}ဤ script ကို root အဖြစ် run ရပါမယ် (sudo -i)${Z}"; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ===== 1. Packages Install =====
say "${Y}📦 လိုအပ်သော Packages များတင်နေသည်...${Z}"
apt-get update -y >/dev/null
apt-get install -y curl ufw jq python3 python3-flask iproute2 conntrack openssl ca-certificates >/dev/null

# Stop old services
systemctl stop zivpn.service zivpn-web.service 2>/dev/null || true

# ===== 2. Folders & Binary =====
mkdir -p /etc/zivpn
BIN="/usr/local/bin/zivpn"
CFG="/etc/zivpn/config.json"
USERS="/etc/zivpn/users.json"
ENVF="/etc/zivpn/web.env"

say "${Y}⬇️ ZIVPN binary ဒေါင်းလုဒ်ဆွဲနေသည်...${Z}"
curl -fsSL -o "$BIN" "https://github.com/zahidbd2/udp-zivpn/releases/latest/download/udp-zivpn-linux-amd64"
chmod +x "$BIN"

# SSL Certs
if [ ! -f /etc/zivpn/zivpn.crt ]; then
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/C=MM/ST=Yangon/L=Yangon/O=KSO/CN=zivpn" \
    -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt" >/dev/null 2>&1
fi

# ===== 3. Web Admin Credentials =====
say "${Y}🔒 Web Admin Login သတ်မှတ်ပါ${Z}"
read -r -p "Admin Username: " WEB_USER
if [ -n "$WEB_USER" ]; then
  read -r -s -p "Admin Password: " WEB_PASS; echo
  WEB_SECRET=$(openssl rand -hex 16)
  {
    echo "WEB_ADMIN_USER=$WEB_USER"
    echo "WEB_ADMIN_PASSWORD=$WEB_PASS"
    echo "WEB_SECRET=$WEB_SECRET"
  } > "$ENVF"
  chmod 600 "$ENVF"
  say "${G}✅ Web Login UI ဖွင့်ထားသည်${Z}"
else
  rm -f "$ENVF" 2>/dev/null || true
  say "${Y}ℹ️ Web Admin ကို default (no login) ဖြင့်သွားမည်${Z}"
fi

# ===== 4. Web UI Script (web.py) =====
say "${Y}📝 Web UI ဖိုင်များကို ဖန်တီးနေသည်...${Z}"
cat > /etc/zivpn/web.py << 'PY'
from flask import Flask, jsonify, render_template_string, request, redirect, url_for, session, make_response
import json, re, subprocess, os, tempfile, hmac
from datetime import datetime, timedelta

USERS_FILE = "/etc/zivpn/users.json"
CONFIG_FILE = "/etc/zivpn/config.json"
LOGO_URL = "https://raw.githubusercontent.com/KYAWSOEOO8/kso-script/main/icon.png"

HTML = """<!doctype html>
<html lang="my"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js"></script>
<style>
 :root{ --bg:#f0f2f5; --fg:#1e293b; --primary:#2563eb; --ok:#10b981; --bad:#ef4444; --card:#ffffff; --bd:#e2e8f0; --muted:#64748b; }
 body{ background:var(--bg); color:var(--fg); font-family:'Segoe UI',sans-serif; margin:0; padding:15px; display:flex; flex-direction:column; align-items:center; }
 .card{ background:var(--card); border-radius:20px; padding:20px; width:100%; max-width:400px; box-shadow:0 10px 25px rgba(0,0,0,0.05); margin-bottom:15px; }
 header{ text-align:center; margin-bottom:20px; }
 .logo{ width:70px; border-radius:20px; margin-bottom:10px; border:2px solid #fff; }
 .btn-primary{ background:var(--primary); color:#fff; border:none; width:100%; padding:12px; border-radius:12px; font-weight:800; cursor:pointer; display:flex; justify-content:center; align-items:center; gap:8px; }
 table{ width:100%; border-collapse:collapse; }
 td{ padding:12px; border-bottom:1px solid var(--bd); }
 .status-dot{ width:10px; height:10px; border-radius:50%; display:inline-block; margin-right:5px; }
 #receipt{ position:fixed; left:-9999px; width:300px; background:#fff; padding:20px; text-align:center; border-radius:15px; }
</style></head><body>

{% if not authed %}
  <div class="card" style="margin-top:50px; text-align:center;">
    <img src="{{logo}}" class="logo"><h2>ADMIN LOGIN</h2>
    <form method="post" action="/login">
      <input name="u" placeholder="Username" style="width:100%; padding:10px; margin-bottom:10px; border-radius:8px; border:1px solid var(--bd);">
      <input name="p" type="password" placeholder="Password" style="width:100%; padding:10px; margin-bottom:15px; border-radius:8px; border:1px solid var(--bd);">
      <button class="btn-primary">LOGIN</button>
    </form>
  </div>
{% else %}
  <header><img src="{{logo}}" class="logo"><h1>KSO VIP PANEL</h1>
    <div style="display:flex; gap:10px; justify-content:center;">
      <a href="https://m.me/kyawsoe.oo.1292019" target="_blank" style="text-decoration:none; color:var(--primary); font-weight:bold;"><i class="fa-brands fa-facebook-messenger"></i> Messenger</a>
      <a href="/logout" style="text-decoration:none; color:var(--bad); font-weight:bold;">Logout</a>
    </div>
  </header>

  <form method="post" action="/add" id="userForm" class="card">
    <label>နာမည်</label><input id="inUser" name="user" required style="width:100%; padding:8px; margin-bottom:10px;">
    <label>စကားဝှက်</label><input id="inPass" name="password" required style="width:100%; padding:8px; margin-bottom:10px;">
    <label>ရက်ပေါင်း</label><input id="inDays" name="expires" placeholder="30" style="width:100%; padding:8px; margin-bottom:15px;">
    <button type="button" onclick="handleSave()" class="btn-primary">SAVE & DOWNLOAD <i class="fa-solid fa-download"></i></button>
  </form>

  <div class="card">
    <table>
      {% for u in users %}
      <tr>
        <td><strong>{{u.user}}</strong><br><small>{{u.expires}}</small></td>
        <td style="text-align:right;">
          <form method="post" action="/delete" onsubmit="return confirm('ဖျက်မှာသေချာလား?')">
            <input type="hidden" name="user" value="{{u.user}}">
            <button style="background:none; border:none; color:var(--bad); cursor:pointer;"><i class="fa-solid fa-trash"></i></button>
          </form>
        </td>
      </tr>
      {% endfor %}
    </table>
  </div>

  <div id="receipt">
    <h3 style="color:var(--primary);">KSO VIP</h3>
    <p>User: <span id="rU"></span></p>
    <p>Pass: <span id="rP"></span></p>
    <p>Exp: <span id="rE"></span></p>
  </div>

  <script>
    function handleSave(){
      const u=document.getElementById('inUser').value;
      const p=document.getElementById('inPass').value;
      const d=document.getElementById('inDays').value || "30";
      if(!u || !p) return alert("ဖြည့်ပါ");
      document.getElementById('rU').innerText=u;
      document.getElementById('rP').innerText=p;
      const date = new Date(); date.setDate(date.getDate() + parseInt(d));
      document.getElementById('rE').innerText=date.toISOString().split('T')[0];
      
      html2canvas(document.getElementById('receipt')).then(canvas => {
        const a = document.createElement('a'); a.download = u+'.png'; a.href = canvas.toDataURL(); a.click();
        setTimeout(()=> document.getElementById('userForm').submit(), 500);
      });
    }
  </script>
{% endif %}
</body></html>"""

app = Flask(__name__)
app.secret_key = os.environ.get("WEB_SECRET","dev-key")
ADMIN_U = os.environ.get("WEB_ADMIN_USER")
ADMIN_P = os.environ.get("WEB_ADMIN_PASSWORD")

def load_users():
    try:
        with open(USERS_FILE,"r") as f: return json.load(f)
    except: return []

def save_and_sync(users):
    with open(USERS_FILE,"w") as f: json.dump(users, f, indent=2)
    # Sync to config.json
    try:
        with open(CONFIG_FILE,"r") as f: cfg=json.load(f)
        cfg["auth"]["config"] = [u["password"] for u in users]
        with open(CONFIG_FILE,"w") as f: json.dump(cfg, f, indent=2)
        subprocess.run("systemctl restart zivpn", shell=True)
    except: pass

@app.route("/")
def index():
    if ADMIN_U and not session.get("auth"): return render_template_string(HTML, authed=False, logo=LOGO_URL)
    return render_template_string(HTML, authed=True, logo=LOGO_URL, users=load_users())

@app.route("/login", methods=["POST"])
def login():
    if request.form.get("u")==ADMIN_U and request.form.get("p")==ADMIN_P:
        session["auth"]=True
    return redirect(url_for("index"))

@app.route("/logout")
def logout(): session.clear(); return redirect(url_for("index"))

@app.route("/add", methods=["POST"])
def add():
    u, p = request.form.get("user"), request.form.get("password")
    exp = request.form.get("expires") or "30"
    if exp.isdigit(): exp = (datetime.now()+timedelta(days=int(exp))).strftime("%Y-%m-%d")
    users = load_users()
    users.append({"user":u, "password":p, "expires":exp})
    save_and_sync(users)
    return redirect(url_for("index"))

@app.route("/delete", methods=["POST"])
def delete():
    u = request.form.get("user")
    users = [user for user in load_users() if user["user"] != u]
    save_and_sync(users)
    return redirect(url_for("index"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8880)
PY

# ===== 5. Services Setup =====
say "${Y}⚙️ Systemd services သတ်မှတ်နေသည်...${Z}"

# ZIVPN Service
cat >/etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=ZIVPN UDP Server
After=network.target

[Service]
WorkingDirectory=/etc/zivpn
ExecStart=$BIN server -c $CFG
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Web Service
cat >/etc/systemd/system/zivpn-web.service <<EOF
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
EnvironmentFile=-$ENVF
ExecStart=/usr/bin/python3 /etc/zivpn/web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ===== 6. Networking & Firewall =====
say "${Y}🌐 Networking rules များ သတ်မှတ်နေသည်...${Z}"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf || true

IFACE=$(ip -4 route ls | awk '/default/ {print $5; exit}')
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

ufw allow 5667/udp && ufw allow 6000:19999/udp && ufw allow 8880/tcp || true

# ===== 7. Finalize =====
systemctl daemon-reload
systemctl enable --now zivpn.service zivpn-web.service

IP=$(hostname -I | awk '{print $1}')
echo -e "\n$LINE\n${G}VPS-IP-COPYလုပ်ပါ${Z}"
echo -e "${C}ဘာကြည့်နေတာလဲ    :${Z} ${Y}http://$IP:8880${Z}"
echo -e "${C}ရပါပြီဆို  :${Z} ${Y}/etc/zivpn/users.json${Z}"
echo -e "${C}မယုံရင် :${Z} ${Y}/etc/zivpn/config.json${Z}"
echo -e "${C}လော့အင်ကြည့်ကွာ    :${Z} ${Y}systemctl status|restart zivpn  •  systemctl status|restart zivpn-web${Z}"
echo -e "$LINE"
