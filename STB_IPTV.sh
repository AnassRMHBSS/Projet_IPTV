#!/bin/bash

# ==========================================
# PROJET IPTV - SET-TOP BOX (VERSION FINALE)
# Option : mTLS + Python3 JSON Parser + HDMI-CEC
# ==========================================

# --- CONFIGURATION ---
CONFIG_FILE="./channels.conf"
MIDDLEWARE_URL="https://192.168.10.40:3000/auth/me"
CERT_DIR="."

declare -A CHANNEL_NAMES
declare -A CHANNEL_URLS

CURRENT_CH=1
MAX_CH=0
CURRENT_URL=""

TMP_INPUT=""
LAST_INPUT_TIME=0
INPUT_TIMEOUT=2

WATCH_PID=""

# ==========================================
# COMMUNICATION SÉCURISÉE (MIDDLEWARE)
# Appelle GET /auth/me avec certificat mTLS
# Reçoit : { channels:[{id, name, multicast:{url}}] }
# ==========================================
fetch_middleware() {
    echo "[*] Authentification mTLS auprès du Middleware..."

    curl -sk \
        --cacert "$CERT_DIR/ca.crt" \
        --cert   "$CERT_DIR/stb-01.crt" \
        --key    "$CERT_DIR/stb-01.key" \
        "$MIDDLEWARE_URL" > /tmp/CHAINES.json

    if [ ! -s /tmp/CHAINES.json ]; then
        echo "[!] Echec de connexion au Middleware."
        echo "[!] Utilisation du fichier de configuration local (cache)."
        return 1
    fi

    echo "[+] Réponse reçue. Extraction des données..."

    # ── Parser Python3 — gère la structure imbriquée multicast.url ──
    python3 - << 'PYEOF' /tmp/CHAINES.json > "$CONFIG_FILE"
import sys, json
try:
    data = json.load(open(sys.argv[1]))
    channels = data.get("channels", [])
    for ch in channels:
        cid  = ch.get("id", "")
        name = ch.get("name", "")
        url  = ch.get("multicast", {}).get("url", "")
        if cid and name and url:
            print(f"{cid} | {name} | {url}")
except Exception as e:
    print(f"# ERREUR : {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    if [ -s "$CONFIG_FILE" ]; then
        local count
        count=$(wc -l < "$CONFIG_FILE")
        echo "[+] $count chaine(s) chargee(s) :"
        cat "$CONFIG_FILE"
    else
        echo "[!] Erreur : parsing JSON échoué."
        echo "[!] Contenu brut reçu :"
        cat /tmp/CHAINES.json
        return 1
    fi
}

# ==========================================
# SURVEILLANCE DES DROITS (toutes les 30s)
# Si la chaîne en cours est révoquée → coupe cvlc
# ==========================================
watch_rights() {
    echo "[*] Surveillance des droits démarrée (30s)"

    while true; do
        sleep 30

        curl -sk \
            --cacert "$CERT_DIR/ca.crt" \
            --cert   "$CERT_DIR/stb-01.crt" \
            --key    "$CERT_DIR/stb-01.key" \
            "$MIDDLEWARE_URL" > /tmp/CHAINES_refresh.json 2>/dev/null

        [ ! -s /tmp/CHAINES_refresh.json ] && continue

        # Récupère toutes les URLs autorisées après refresh
        AUTHORIZED_URLS=$(python3 - << 'PYEOF' /tmp/CHAINES_refresh.json
import sys, json
try:
    data = json.load(open(sys.argv[1]))
    for ch in data.get("channels", []):
        url = ch.get("multicast", {}).get("url", "")
        if url:
            print(url)
except:
    pass
PYEOF
)

        # Vérifie si la chaîne en cours est encore autorisée
        if [ -n "$CURRENT_URL" ]; then
            if ! echo "$AUTHORIZED_URLS" | grep -qF "$CURRENT_URL"; then
                echo "[!] ACCÈS RÉVOQUÉ → arrêt de la chaîne en cours"
                pkill -9 vlc 2>/dev/null
                CURRENT_URL=""

                # Met à jour le fichier de config
                python3 - << 'PYEOF' /tmp/CHAINES_refresh.json > "$CONFIG_FILE"
import sys, json
try:
    data = json.load(open(sys.argv[1]))
    for ch in data.get("channels", []):
        cid  = ch.get("id", "")
        name = ch.get("name", "")
        url  = ch.get("multicast", {}).get("url", "")
        if cid and name and url:
            print(f"{cid} | {name} | {url}")
except:
    pass
PYEOF

                # Recharge en mémoire
                unset CHANNEL_NAMES CHANNEL_URLS
                declare -gA CHANNEL_NAMES
                declare -gA CHANNEL_URLS
                MAX_CH=0
                load_channels

                # Relance sur la première chaîne encore autorisée
                for ch in $(seq 1 "$MAX_CH"); do
                    if [[ -n "${CHANNEL_URLS[$ch]}" ]]; then
                        CURRENT_CH="$ch"
                        launch_vlc "$CURRENT_CH"
                        break
                    fi
                done
            fi
        fi
    done
}

# ==========================================
# MOTEUR DE LECTURE VIDÉO
# Lance cvlc sur l'URL multicast reçue du middleware
# ==========================================
launch_vlc() {
    local ch="$1"
    local url="${CHANNEL_URLS[$ch]}"
    local name="${CHANNEL_NAMES[$ch]}"

    [ -z "$url" ] && echo "[!] Aucune URL pour canal $ch" && return

    echo "--------------------------------"
    echo "ZAPPING → CANAL $ch : $name"
    echo "URL     → $url"
    echo "--------------------------------"

    # Arrête le flux précédent
    pkill -9 vlc 2>/dev/null
    sleep 0.3

    # Mémorise l'URL en cours pour la surveillance
    CURRENT_URL="$url"

    # Signal HDMI-CEC pour activer la TV
    echo "as" | cec-client -s -d 1 2>/dev/null

    # Lance cvlc sur l'URL multicast rtp://@239.255.x.x:5001
    cvlc "$url" \
        --fullscreen \
        --no-video-title-show \
        --network-caching=500 \
        2>/dev/null &
}

# ==========================================
# LOGIQUE DE NAVIGATION (TÉLÉCOMMANDE)
# ==========================================
trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

load_channels() {
    [ ! -f "$CONFIG_FILE" ] && echo "[!] Pas de config." && return

    while IFS='|' read -r num name url; do
        num="$(trim "$num")"
        name="$(trim "$name")"
        url="$(trim "$url")"
        [[ -z "$num" || "$num" =~ ^# || ! "$num" =~ ^[0-9]+$ ]] && continue
        CHANNEL_NAMES["$num"]="$name"
        CHANNEL_URLS["$num"]="$url"
        (( num > MAX_CH )) && MAX_CH=$num
    done < "$CONFIG_FILE"

    echo "[+] $MAX_CH canal/canaux en mémoire."
}

commit_pending_input() {
    if [[ -n "$TMP_INPUT" && -n "${CHANNEL_URLS[$TMP_INPUT]}" ]]; then
        CURRENT_CH="$TMP_INPUT"
        launch_vlc "$CURRENT_CH"
    fi
    TMP_INPUT=""
}

handle_number() {
    local digit="$1"
    local now
    now=$(date +%s)
    (( now - LAST_INPUT_TIME > INPUT_TIMEOUT )) && TMP_INPUT=""
    TMP_INPUT="${TMP_INPUT}${digit}"
    LAST_INPUT_TIME=$now
    echo "Saisie : $TMP_INPUT"
    if (( ${#TMP_INPUT} >= 2 )); then
        commit_pending_input
    fi
}

next_channel() {
    local start="$CURRENT_CH"
    while true; do
        ((CURRENT_CH++))
        (( CURRENT_CH > MAX_CH )) && CURRENT_CH=1
        [[ -n "${CHANNEL_URLS[$CURRENT_CH]}" ]] && launch_vlc "$CURRENT_CH" && return
        [[ "$CURRENT_CH" -eq "$start" ]] && return
    done
}

prev_channel() {
    local start="$CURRENT_CH"
    while true; do
        ((CURRENT_CH--))
        (( CURRENT_CH < 1 )) && CURRENT_CH=$MAX_CH
        [[ -n "${CHANNEL_URLS[$CURRENT_CH]}" ]] && launch_vlc "$CURRENT_CH" && return
        [[ "$CURRENT_CH" -eq "$start" ]] && return
    done
}

cleanup() {
    echo "[*] Arrêt STB..."
    pkill -9 vlc        2>/dev/null
    pkill -f cec-client 2>/dev/null
    [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
    exit 0
}

# ==========================================
# INITIALISATION ET LANCEMENT
# ==========================================
trap cleanup INT TERM
clear

echo "========================================="
echo "     STB IPTV CIEL 2026 - HDMI CEC"
echo "========================================="
echo "Middleware : $MIDDLEWARE_URL"

# Vérifie les certificats
for f in ca.crt stb-01.crt stb-01.key; do
    if [ ! -f "$CERT_DIR/$f" ]; then
        echo "[!] Certificat manquant : $CERT_DIR/$f"
        exit 1
    fi
done

# Vérifie que Python3 est installé
if ! command -v python3 &>/dev/null; then
    echo "[!] Python3 non installé. Installez-le avec :"
    echo "    sudo apt install python3"
    exit 1
fi

# 1. Récupère les chaînes autorisées depuis le middleware
fetch_middleware || echo "[!] Démarrage en mode cache"

# 2. Charge les chaînes en mémoire
load_channels

if [ "$MAX_CH" -eq 0 ]; then
    echo "[!] Aucune chaîne disponible."
    exit 1
fi

# 3. Lance la première chaîne autorisée
for ch in $(seq 1 "$MAX_CH"); do
    if [[ -n "${CHANNEL_URLS[$ch]}" ]]; then
        CURRENT_CH="$ch"
        launch_vlc "$CURRENT_CH"
        break
    fi
done

# 4. Surveillance des droits en arrière-plan
watch_rights &
WATCH_PID=$!
echo "[*] Surveillance PID : $WATCH_PID"

# 5. Écoute HDMI-CEC
echo "[*] En attente commandes télécommande..."
exec 3< <(cec-client -d 8)

while true; do
    if IFS= read -r -t 0.2 line <&3; then
        [[ "$line" != *"44:"* ]] && continue
        code=$(echo "$line" | sed -n 's/.*44:\([0-9A-F][0-9A-F]\).*/\1/p')
        case "$code" in
            01) next_channel ;;
            02) prev_channel ;;
            20) handle_number 0 ;;
            21) handle_number 1 ;;
            22) handle_number 2 ;;
            23) handle_number 3 ;;
            24) handle_number 4 ;;
            25) handle_number 5 ;;
            26) handle_number 6 ;;
            27) handle_number 7 ;;
            28) handle_number 8 ;;
            29) handle_number 9 ;;
        esac
    fi

    now=$(date +%s)
    [[ -n "$TMP_INPUT" ]] && \
        (( now - LAST_INPUT_TIME >= INPUT_TIMEOUT )) && \
        commit_pending_input
done