#!/usr/bin/env bash
# =============================================================================
# postfix_troubleshoot_v3.sh — Postfix Mail Troubleshooter for Plesk Servers
# =============================================================================
# Purpose:
#   Read-only diagnostic script for Plesk/Postfix mail delivery issues.
#   Generates:
#     1) Engineer technical log
#     2) Client-ready summary report
#
# Usage:
#   curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/postfix_troubleshoot_v3.sh | sudo bash
#
# Optional:
#   curl -s URL | sudo bash -s -- --domain example.com
#
# Safety:
#   This script does NOT restart services, delete queues, change configs,
#   suspend users, or modify firewall rules.
# =============================================================================

set -o pipefail

SCRIPT_VERSION="3.0.0"
QUEUE_WARN_THRESHOLD=200
LOG_TAIL_LINES=3000
DOMAIN_CONTEXT=""

# ── Parse optional arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN_CONTEXT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
sep()  { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}ERROR:${RESET} This script must be run as root."
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TECH_LOG="/var/log/postfix_troubleshoot_v3_${TIMESTAMP}.log"
CLIENT_REPORT="/root/postfix_mail_report_${TIMESTAMP}.txt"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
CLIENT_RESULTS=""
ENGINEER_NOTES=""

add_result() {
  local status="$1"
  local title="$2"
  local details="$3"
  local recommendation="$4"

  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  esac

  CLIENT_RESULTS+="${status}|${title}|${details}|${recommendation}"$'\n'
}

add_engineer_note() {
  ENGINEER_NOTES+="$*"$'\n'
}

# Send all terminal output to technical log as well.
exec > >(tee -a "$TECH_LOG") 2>&1

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       Postfix Mail Troubleshooter — Plesk V3             ║"
echo "║       Read-only diagnostic + client report               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
info "Script version : $SCRIPT_VERSION"
info "Technical log  : $TECH_LOG"
info "Client report  : $CLIENT_REPORT"
info "Mode           : READ-ONLY. No changes will be made."

# =============================================================================
# Helper Functions
# =============================================================================

get_public_ip() {
  local ip=""
  if cmd_exists curl; then
    ip="$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null)"
    [[ -z "$ip" ]] && ip="$(curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null)"
  fi
  if [[ -z "$ip" ]] && cmd_exists wget; then
    ip="$(wget -qO- --timeout=8 https://api.ipify.org 2>/dev/null)"
  fi
  echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}

reverse_ip() {
  echo "$1" | awk -F. '{print $4"."$3"."$2"."$1}'
}

dns_lookup_a() {
  local name="$1"
  if cmd_exists dig; then
    dig +short A "$name" 2>/dev/null | head -5
  elif cmd_exists host; then
    host -t A "$name" 2>/dev/null | awk '/has address/ {print $4}' | head -5
  elif cmd_exists nslookup; then
    nslookup -type=A "$name" 2>/dev/null | awk '/^Address: / {print $2}' | grep -v '#53' | head -5
  elif cmd_exists getent; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u | head -5
  fi
}

dns_lookup_ptr() {
  local ip="$1"
  if cmd_exists dig; then
    dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' | head -1
  elif cmd_exists host; then
    host "$ip" 2>/dev/null | awk -F'pointer ' '/pointer/ {print $2}' | sed 's/\.$//' | head -1
  elif cmd_exists nslookup; then
    nslookup -type=PTR "$ip" 2>/dev/null | awk -F'= ' '/name =/ {print $2}' | sed 's/\.$//' | head -1
  fi
}

dnsbl_query() {
  local ip="$1"
  local zone="$2"
  local reversed query result
  reversed="$(reverse_ip "$ip")"
  query="${reversed}.${zone}"

  result="$(dns_lookup_a "$query" | head -1)"
  if [[ -n "$result" ]]; then
    echo "LISTED:$result"
  else
    echo "NOT_LISTED"
  fi
}

check_port_listening() {
  local port="$1"
  if cmd_exists ss; then
    ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"
  elif cmd_exists netstat; then
    netstat -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"
  else
    return 2
  fi
}

find_mail_log() {
  for f in /var/log/maillog /var/log/mail.log /usr/local/psa/var/log/maillog; do
    [[ -f "$f" ]] && echo "$f" && return 0
  done
  return 1
}

# =============================================================================
# SECTION 1 — SERVER & PLESK / POSTFIX SERVICE
# =============================================================================
hdr "1. Server & Plesk / Postfix Service"
sep

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
PUBLIC_IP="$(get_public_ip)"
[[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="unknown"

info "Hostname       : $HOSTNAME_FQDN"
info "Public IP      : $PUBLIC_IP"

if [[ -x /usr/local/psa/bin/plesk ]]; then
  PLESK_VER="$(plesk version 2>/dev/null | head -1)"
  info "Plesk version  : ${PLESK_VER:-detected}"
  add_result "PASS" "Plesk detected" "Plesk command-line tools are available on the server." "No action required."
else
  warn "Plesk CLI not found at /usr/local/psa/bin/plesk"
  add_result "WARN" "Plesk detection" "Plesk command-line tools were not detected in the expected path." "Engineer should confirm whether this is a Plesk server."
fi

if cmd_exists postfix; then
  POSTFIX_VER="$(postconf mail_version 2>/dev/null | awk '{print $3}')"
  info "Postfix version: ${POSTFIX_VER:-unknown}"
  add_result "PASS" "Postfix installed" "Postfix is installed on the server." "No action required."
else
  fail "Postfix binary not found"
  add_result "FAIL" "Postfix installed" "Postfix binary was not found." "Engineer should verify mail server package and Plesk mail service configuration."
fi

if systemctl is-active --quiet postfix 2>/dev/null; then
  pass "Postfix service is running"
  add_result "PASS" "Postfix service" "Postfix mail service is running." "No action required."
else
  fail "Postfix service is not running"
  add_result "FAIL" "Postfix service" "Postfix mail service is not running." "Engineer should review systemctl status postfix and mail logs."
fi

if systemctl is-active --quiet dovecot 2>/dev/null; then
  pass "Dovecot service is running"
  add_result "PASS" "Dovecot service" "Dovecot IMAP/POP service is running." "No action required."
else
  warn "Dovecot service is not running or not detected"
  add_result "WARN" "Dovecot service" "Dovecot service is not running or could not be detected." "Engineer should verify if mailbox access is affected."
fi

for p in 25 587 465 993 995; do
  if check_port_listening "$p"; then
    pass "Port $p is listening"
    add_result "PASS" "Port $p listening" "Mail-related port $p is listening locally." "No action required."
  else
    warn "Port $p is not listening"
    add_result "WARN" "Port $p listening" "Mail-related port $p is not listening locally." "Engineer should verify whether this port is required for the customer's mail usage."
  fi
done

PTR_RECORD=""
if [[ "$PUBLIC_IP" != "unknown" ]]; then
  PTR_RECORD="$(dns_lookup_ptr "$PUBLIC_IP")"
  if [[ -n "$PTR_RECORD" ]]; then
    pass "PTR record found: $PTR_RECORD"
    add_result "PASS" "PTR record" "The public IP has a reverse DNS/PTR record: $PTR_RECORD." "No action required."
  else
    fail "No PTR record found for $PUBLIC_IP"
    add_result "FAIL" "PTR record" "No reverse DNS/PTR record was found for the public mail IP." "Set PTR/rDNS with the datacenter or upstream provider."
  fi
fi

# =============================================================================
# SECTION 2 — POSTFIX QUEUE STATUS AND SPAM ANALYSIS
# =============================================================================
hdr "2. Postfix Queue Status and Spam Analysis"
sep

QUEUE_SIZE="unknown"
if cmd_exists postqueue; then
  QUEUE_OUTPUT="$(postqueue -p 2>/dev/null)"
  if echo "$QUEUE_OUTPUT" | grep -q "Mail queue is empty"; then
    QUEUE_SIZE=0
  else
    QUEUE_SIZE="$(echo "$QUEUE_OUTPUT" | grep -cE '^[A-F0-9]{5,}')"
  fi

  info "Messages in queue: $QUEUE_SIZE"

  if [[ "$QUEUE_SIZE" -eq 0 ]]; then
    pass "Mail queue is empty"
    add_result "PASS" "Mail queue" "The Postfix mail queue is empty." "No action required."
  elif [[ "$QUEUE_SIZE" -le 50 ]]; then
    pass "Mail queue is normal: $QUEUE_SIZE messages"
    add_result "PASS" "Mail queue" "The Postfix queue contains $QUEUE_SIZE message(s), which is within normal range." "Monitor if the customer reports delayed delivery."
  elif [[ "$QUEUE_SIZE" -le "$QUEUE_WARN_THRESHOLD" ]]; then
    warn "Mail queue is moderate: $QUEUE_SIZE messages"
    add_result "WARN" "Mail queue" "The Postfix queue contains $QUEUE_SIZE message(s)." "Engineer should monitor queue growth and check recent deferred deliveries."
  else
    fail "Mail queue exceeds threshold: $QUEUE_SIZE messages"
    add_result "FAIL" "Mail queue" "The Postfix queue contains $QUEUE_SIZE message(s), exceeding the warning threshold of $QUEUE_WARN_THRESHOLD." "Engineer should investigate spam, remote delivery failures, or mail loops."
  fi

  echo ""
  info "Queue sample:"
  echo "$QUEUE_OUTPUT" | head -40 | sed 's/^/    /'

  echo ""
  info "Queue directory usage:"
  for d in /var/spool/postfix/{active,deferred,incoming,maildrop,bounce,corrupt,hold}; do
    [[ -d "$d" ]] && du -sh "$d" 2>/dev/null | sed 's/^/    /'
  done

  add_engineer_note "Queue sample and spool breakdown are available in technical log: $TECH_LOG"
else
  warn "postqueue command not found"
  add_result "WARN" "Postfix queue" "postqueue command was not available, so queue analysis could not be completed." "Engineer should verify Postfix installation."
fi

MAIL_LOG="$(find_mail_log)"
if [[ -n "$MAIL_LOG" ]]; then
  info "Mail log detected: $MAIL_LOG"

  echo ""
  info "Top SASL authenticated users from recent logs:"
  tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | \
    grep -ioE 'sasl_username=[^, ]+' | cut -d= -f2 | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'

  SASL_TOP_COUNT="$(tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | grep -ioE 'sasl_username=[^, ]+' | cut -d= -f2 | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')"
  if [[ "${SASL_TOP_COUNT:-0}" -gt 100 ]]; then
    warn "High authenticated SMTP volume detected from one user in recent logs"
    add_result "WARN" "Authenticated SMTP volume" "High authenticated SMTP activity was detected from at least one mailbox/account." "Engineer should review the top SASL user list in the technical log."
  else
    pass "No obvious high-volume SASL sender detected in recent log sample"
    add_result "PASS" "Authenticated SMTP volume" "No obvious high-volume authenticated SMTP sender was detected in the recent log sample." "No action required."
  fi

  echo ""
  info "PHP mail() / web script indicators from recent logs:"
  tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | \
    grep -iE 'uid=|php|sendmail|pickup|www-data|apache|nginx|cwd=' | tail -30 | sed 's/^/    /'

  add_engineer_note "Recent SASL and PHP/script indicators are available in technical log."
else
  warn "Mail log not found"
  add_result "WARN" "Mail log" "No standard Postfix mail log was found." "Engineer should confirm the mail log path for this server."
fi

# =============================================================================
# SECTION 3 — FIREWALL AND PORT CHECKS
# =============================================================================
hdr "3. Firewall & Port Checks"
sep

if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld is active"
  firewall-cmd --list-all 2>/dev/null | sed 's/^/    /'
  add_result "PASS" "firewalld" "firewalld is active and firewall details were captured in the technical log." "Engineer should verify required mail ports are allowed."
else
  info "firewalld not active or not installed"
  add_result "PASS" "firewalld" "firewalld is not active or not installed." "No action required if another firewall is used."
fi

if [[ -f /etc/csf/csf.conf ]]; then
  info "CSF detected"
  grep -E '^(TCP_IN|TCP_OUT|UDP_IN|UDP_OUT)' /etc/csf/csf.conf 2>/dev/null | sed 's/^/    /'

  if grep -E '^TCP_IN' /etc/csf/csf.conf 2>/dev/null | grep -qE '25|587|465|993|995'; then
    pass "Mail ports appear in CSF TCP_IN"
    add_result "PASS" "CSF mail ports" "Mail ports appear to be included in CSF TCP_IN." "No action required."
  else
    warn "Mail ports not clearly detected in CSF TCP_IN"
    add_result "WARN" "CSF mail ports" "Mail ports were not clearly detected in CSF TCP_IN." "Engineer should review /etc/csf/csf.conf."
  fi
else
  info "CSF not detected"
fi

if cmd_exists iptables; then
  info "iptables rules summary:"
  iptables -S 2>/dev/null | grep -E '25|465|587|993|995|DROP|REJECT' | head -50 | sed 's/^/    /'
fi

echo ""
info "Local SMTP banner test:"
if cmd_exists nc; then
  SMTP_BANNER="$(echo QUIT | timeout 8 nc -w 5 127.0.0.1 25 2>/dev/null | head -1)"
elif cmd_exists telnet; then
  SMTP_BANNER="$(timeout 8 bash -c '{ echo QUIT; sleep 1; } | telnet 127.0.0.1 25' 2>/dev/null | grep -m1 '^220')"
else
  SMTP_BANNER=""
fi

if echo "$SMTP_BANNER" | grep -q '^220'; then
  pass "SMTP banner received: $SMTP_BANNER"
  add_result "PASS" "Local SMTP banner" "The local SMTP service responded on port 25." "No action required."
else
  fail "No local SMTP banner received on port 25"
  add_result "FAIL" "Local SMTP banner" "No local SMTP banner was received from 127.0.0.1:25." "Engineer should review Postfix service status and local firewall rules."
fi

# =============================================================================
# SECTION 4 — DISK SPACE AND MAILBOX QUOTAS
# =============================================================================
hdr "4. Disk Space & Mailbox Quotas"
sep

info "Disk usage:"
df -h / /var /tmp /usr/local/psa 2>/dev/null | sed 's/^/    /'

FULL_PARTS="$(df -h 2>/dev/null | awk '$5+0 >= 90 {print $6 " " $5}')"
if [[ -n "$FULL_PARTS" ]]; then
  fail "High disk usage detected:"
  echo "$FULL_PARTS" | sed 's/^/    /'
  add_result "FAIL" "Disk usage" "One or more partitions are at or above 90% usage." "Engineer should free disk space or expand storage before mail delivery is affected."
else
  pass "No partition at or above 90% usage"
  add_result "PASS" "Disk usage" "No partition is at or above 90% usage." "No action required."
fi

echo ""
info "Postfix spool size:"
du -sh /var/spool/postfix 2>/dev/null | sed 's/^/    /'

echo ""
info "Plesk mailbox storage breakdown:"
if [[ -d /var/qmail/mailnames ]]; then
  du -sh /var/qmail/mailnames/* 2>/dev/null | sort -hr | head -20 | sed 's/^/    /'
  add_result "PASS" "Mailbox storage" "Mailbox storage path was detected and top usage was captured in the technical log." "Engineer should review large domains if quota or disk issues are reported."
else
  warn "/var/qmail/mailnames not found"
  add_result "WARN" "Mailbox storage" "Plesk mailbox storage path /var/qmail/mailnames was not found." "Engineer should confirm mailbox storage path."
fi

# =============================================================================
# SECTION 5 — OUTGOING MAIL IP / NAT / HELO CHECK
# =============================================================================
hdr "5. Outgoing Mail IP / NAT / HELO Check"
sep

info "Primary detected public IP: $PUBLIC_IP"

echo ""
info "Local IPv4 addresses:"
ip -4 addr show 2>/dev/null | awk '/inet / {print "    "$2" "$NF}'

echo ""
info "Default outbound route:"
ip route get 8.8.8.8 2>/dev/null | sed 's/^/    /'

SMTP_BIND_ADDRESS="$(postconf -h smtp_bind_address 2>/dev/null)"
SMTP_HELO_NAME="$(postconf -h smtp_helo_name 2>/dev/null)"
MYHOSTNAME="$(postconf -h myhostname 2>/dev/null)"

info "Postfix smtp_bind_address : ${SMTP_BIND_ADDRESS:-not set}"
info "Postfix smtp_helo_name    : ${SMTP_HELO_NAME:-not set}"
info "Postfix myhostname        : ${MYHOSTNAME:-not set}"
info "System hostname           : $HOSTNAME_FQDN"
info "PTR hostname              : ${PTR_RECORD:-not found}"

if [[ -n "$SMTP_BIND_ADDRESS" ]]; then
  add_result "PASS" "Outgoing bind IP" "Postfix smtp_bind_address is configured as $SMTP_BIND_ADDRESS." "Engineer should verify this IP has correct PTR and SPF coverage."
else
  add_result "PASS" "Outgoing bind IP" "Postfix smtp_bind_address is not explicitly set; server will use the default outbound route/IP." "No action required if the detected public IP is expected."
fi

HELO_EFFECTIVE="${SMTP_HELO_NAME:-$MYHOSTNAME}"
if [[ -n "$PTR_RECORD" && -n "$HELO_EFFECTIVE" ]]; then
  if [[ "$HELO_EFFECTIVE" == "$PTR_RECORD" ]]; then
    pass "HELO matches PTR"
    add_result "PASS" "HELO/PTR alignment" "Postfix HELO hostname matches the PTR hostname." "No action required."
  else
    warn "HELO/PTR mismatch: HELO=$HELO_EFFECTIVE, PTR=$PTR_RECORD"
    add_result "WARN" "HELO/PTR alignment" "Postfix HELO hostname does not exactly match the PTR hostname." "Engineer should review smtp_helo_name, myhostname, and PTR alignment."
  fi
else
  warn "Unable to fully validate HELO/PTR alignment"
  add_result "WARN" "HELO/PTR alignment" "HELO/PTR alignment could not be fully validated." "Engineer should confirm Postfix HELO and PTR manually."
fi

echo ""
info "Plesk IP information:"
if [[ -x /usr/local/psa/bin/ipmanage ]]; then
  /usr/local/psa/bin/ipmanage --list 2>/dev/null | sed 's/^/    /'
else
  warn "Plesk ipmanage command not available"
fi

# =============================================================================
# SECTION 6 — MAIL REPUTATION ASSESSMENT
# =============================================================================
hdr "6. Mail Reputation Assessment"
sep

REPUTATION_WARN=0
REPUTATION_FAIL=0

if [[ "$PUBLIC_IP" == "unknown" || -z "$PUBLIC_IP" ]]; then
  warn "Public IP could not be detected; reputation assessment is limited"
  add_result "WARN" "Mail reputation" "Public IP could not be detected, so reputation assessment is limited." "Engineer should verify outbound NAT/public IP manually."
else
  info "Assessing reputation for public IP: $PUBLIC_IP"

  # 6.1 PTR validation already done, but include here as reputation-critical.
  if [[ -n "$PTR_RECORD" ]]; then
    pass "PTR exists: $PTR_RECORD"
  else
    fail "PTR missing for $PUBLIC_IP"
    REPUTATION_FAIL=$((REPUTATION_FAIL + 1))
  fi

  # 6.2 HELO consistency already checked.
  if [[ -n "$PTR_RECORD" && -n "$HELO_EFFECTIVE" && "$PTR_RECORD" == "$HELO_EFFECTIVE" ]]; then
    pass "HELO/PTR alignment is good"
  else
    warn "HELO/PTR alignment needs review"
    REPUTATION_WARN=$((REPUTATION_WARN + 1))
  fi

  # 6.3 Outbound SMTP smoke test to Gmail MX.
  echo ""
  info "Outbound SMTP smoke test to gmail-smtp-in.l.google.com:25"
  if cmd_exists nc; then
    GMAIL_SMTP_BANNER="$(echo QUIT | timeout 12 nc -w 8 gmail-smtp-in.l.google.com 25 2>/dev/null | head -1)"
    if echo "$GMAIL_SMTP_BANNER" | grep -q '^220'; then
      pass "Outbound SMTP connection succeeded: $GMAIL_SMTP_BANNER"
    else
      warn "No SMTP banner from Gmail MX. This may indicate outbound port 25 block, routing issue, or remote connection filtering."
      REPUTATION_WARN=$((REPUTATION_WARN + 1))
    fi
  else
    warn "nc not found; outbound SMTP smoke test skipped"
    REPUTATION_WARN=$((REPUTATION_WARN + 1))
  fi

  # 6.4 DNSBL scan using any available resolver command.
  echo ""
  info "DNSBL checks using available resolver command:"
  if cmd_exists dig || cmd_exists host || cmd_exists nslookup || cmd_exists getent; then
    DNSBL_ZONES=(
      "zen.spamhaus.org"
      "bl.spamcop.net"
      "b.barracudacentral.org"
      "dnsbl.sorbs.net"
      "spam.dnsbl.sorbs.net"
      "cbl.abuseat.org"
    )

    LISTED_ZONES=()
    for zone in "${DNSBL_ZONES[@]}"; do
      RESULT="$(dnsbl_query "$PUBLIC_IP" "$zone")"
      if [[ "$RESULT" == LISTED:* ]]; then
        fail "LISTED on $zone (${RESULT#LISTED:})"
        LISTED_ZONES+=("$zone")
      else
        pass "Not listed on $zone"
      fi
    done

    if [[ "${#LISTED_ZONES[@]}" -gt 0 ]]; then
      REPUTATION_FAIL=$((REPUTATION_FAIL + 1))
      add_engineer_note "DNSBL listed zones for $PUBLIC_IP: ${LISTED_ZONES[*]}"
    fi
  else
    warn "No DNS resolver tool found. DNSBL scan skipped."
    warn "Install one of: bind-utils / dnsutils / bind9-dnsutils"
    REPUTATION_WARN=$((REPUTATION_WARN + 1))
  fi

  # 6.5 Clickable manual lookup references.
  echo ""
  info "Manual reputation lookup links:"
  echo "    Talos     : https://www.talosintelligence.com/reputation_center/lookup?search=${PUBLIC_IP}"
  echo "    MultiRBL  : https://multirbl.valli.org/lookup/${PUBLIC_IP}.html"
  echo "    MXToolbox : https://mxtoolbox.com/SuperTool.aspx?action=blacklist%3a${PUBLIC_IP}"
  echo "    Spamhaus  : https://check.spamhaus.org/listed/?searchterm=${PUBLIC_IP}"

  if [[ "$REPUTATION_FAIL" -gt 0 ]]; then
    add_result "FAIL" "Mail reputation assessment" "One or more reputation-critical issues were detected, such as missing PTR or DNSBL listing." "Engineer should review PTR, HELO alignment, DNSBL results, and manual reputation links."
  elif [[ "$REPUTATION_WARN" -gt 0 ]]; then
    add_result "WARN" "Mail reputation assessment" "Mail reputation assessment completed with warning items." "Engineer should review PTR/HELO alignment, SMTP connectivity, and manual reputation links."
  else
    add_result "PASS" "Mail reputation assessment" "No obvious PTR, HELO, SMTP connectivity, or DNSBL issues were detected." "No action required."
  fi
fi

# =============================================================================
# SECTION 7 — POSTFIX LOG HEALTH
# =============================================================================
hdr "7. Postfix Log Health"
sep

if [[ -n "$MAIL_LOG" && -f "$MAIL_LOG" ]]; then
  info "Analyzing recent log sample from: $MAIL_LOG"

  SASL_ERRORS="$(tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | grep -ciE 'sasl.*fail|authentication failed|warning.*sasl')"
  TLS_ERRORS="$(tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | grep -ciE 'TLS.*fail|SSL.*error|certificate verify failed')"
  DEFER_ERRORS="$(tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | grep -ciE 'status=deferred|temporarily deferred|connect to .* timed out|Connection timed out')"
  BOUNCE_ERRORS="$(tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | grep -ciE 'status=bounced|User unknown|mailbox full|Relay access denied')"

  info "SASL/auth errors : $SASL_ERRORS"
  info "TLS/SSL errors   : $TLS_ERRORS"
  info "Deferred entries : $DEFER_ERRORS"
  info "Bounce entries   : $BOUNCE_ERRORS"

  echo ""
  info "Recent warning/error lines:"
  tail -n "$LOG_TAIL_LINES" "$MAIL_LOG" 2>/dev/null | \
    grep -iE 'warning|error|fatal|panic|deferred|bounced|reject|sasl|TLS|timeout' | tail -40 | sed 's/^/    /'

  if [[ "$SASL_ERRORS" -gt 50 || "$DEFER_ERRORS" -gt 100 || "$BOUNCE_ERRORS" -gt 100 ]]; then
    warn "High volume of mail log errors detected"
    add_result "WARN" "Postfix log health" "Recent mail logs show elevated SASL, deferred, or bounced mail events." "Engineer should review recent warning/error lines in the technical log."
  else
    pass "No severe mail log error pattern detected in recent sample"
    add_result "PASS" "Postfix log health" "No severe mail log error pattern was detected in the recent sample." "No action required."
  fi
else
  warn "Mail log unavailable; log health analysis skipped"
  add_result "WARN" "Postfix log health" "Mail log was unavailable, so log health analysis was skipped." "Engineer should confirm the correct mail log path."
fi

# =============================================================================
# SECTION 8 — EXECUTIVE SUMMARY / CLIENT REPORT
# =============================================================================
hdr "8. Executive Summary"
sep

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  OVERALL_STATUS="CRITICAL"
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  OVERALL_STATUS="WARNING"
else
  OVERALL_STATUS="PASS"
fi

info "Overall status : $OVERALL_STATUS"
info "PASS count     : $PASS_COUNT"
info "WARN count     : $WARN_COUNT"
info "FAIL count     : $FAIL_COUNT"

{
  echo "MAIL DELIVERY DIAGNOSTIC REPORT"
  echo "================================"
  echo ""
  echo "Platform       : Plesk / Postfix"
  echo "Script Version : $SCRIPT_VERSION"
  echo "Server         : $HOSTNAME_FQDN"
  echo "Public IP      : $PUBLIC_IP"
  echo "PTR            : ${PTR_RECORD:-Not detected}"
  echo "Date           : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  [[ -n "$DOMAIN_CONTEXT" ]] && echo "Domain Context : $DOMAIN_CONTEXT"
  echo ""
  echo "Overall Status : $OVERALL_STATUS"
  echo ""
  echo "Summary Counts"
  echo "--------------"
  echo "PASS           : $PASS_COUNT"
  echo "WARNING        : $WARN_COUNT"
  echo "CRITICAL       : $FAIL_COUNT"
  echo ""
  echo "Findings"
  echo "--------"

  while IFS='|' read -r status title details recommendation; do
    [[ -z "$status" ]] && continue
    case "$status" in
      PASS) label="[PASS]" ;;
      WARN) label="[WARNING]" ;;
      FAIL) label="[CRITICAL]" ;;
      *) label="[INFO]" ;;
    esac

    echo "$label $title"
    echo "  Status Detail : $details"
    echo "  Recommendation: $recommendation"
    echo ""
  done <<< "$CLIENT_RESULTS"

  echo "Engineer Notes"
  echo "--------------"
  echo "Full technical log:"
  echo "$TECH_LOG"
  echo ""
  if [[ -n "$ENGINEER_NOTES" ]]; then
    echo "$ENGINEER_NOTES"
  else
    echo "No additional engineer notes."
  fi

  echo ""
  echo "Important Note"
  echo "--------------"
  echo "This report is based on read-only checks. No mail queue, service, firewall,"
  echo "or configuration changes were performed by this script."
} > "$CLIENT_REPORT"

echo ""
pass "Troubleshooting completed"
pass "Technical log saved : $TECH_LOG"
pass "Client report saved : $CLIENT_REPORT"
echo ""
echo -e "${BOLD}${GREEN}Done.${RESET}"
