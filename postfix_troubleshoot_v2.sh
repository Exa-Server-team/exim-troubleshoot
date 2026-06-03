#!/usr/bin/env bash
# =============================================================================
# postfix_troubleshoot_v1.sh — Read-Only Postfix Mail Diagnostic Report for Plesk
# =============================================================================
# Usage:
#   curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/postfix_troubleshoot_v1.sh | sudo bash
#   curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/postfix_troubleshoot_v1.sh | sudo bash -s -- --domain example.com
#
# Scope:
#   READ-ONLY diagnostics only.
#   No service restart, no queue deletion, no mailbox change, no config changes.
#
# Output:
#   Technical log        : /var/log/postfix_troubleshoot_v1_TIMESTAMP.log
#   Client-ready report  : /root/postfix_mail_report_v1_TIMESTAMP.txt
# =============================================================================

set -o pipefail

SCRIPT_VERSION="1.0.0"
QUEUE_WARN_THRESHOLD=200
QUEUE_MODERATE_THRESHOLD=50
LOG_SAMPLE_LINES=500
ENABLE_DNSBL_SCAN=true
DNSBL_TIMEOUT=8

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
sep()   { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}ERROR:${RESET} This script must be run as root."
  exit 1
fi

# ── Args ─────────────────────────────────────────────────────────────────────
CHECK_DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      CHECK_DOMAIN="${2:-}"
      shift 2
      ;;
    --no-dnsbl)
      ENABLE_DNSBL_SCAN=false
      shift
      ;;
    --help|-h)
      cat <<USAGE
Usage: sudo bash postfix_troubleshoot_v1.sh [options]

Options:
  --domain example.com   Optional domain context for report
  --no-dnsbl             Skip DNSBL/RBL lookup section
  --help                 Show this help

This script is read-only and does not modify services, queue, mailboxes, or config.
USAGE
      exit 0
      ;;
    *)
      warn "Unknown option ignored: $1"
      shift
      ;;
  esac
done

# ── Output files ─────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
TECH_LOG="/var/log/postfix_troubleshoot_v1_${TS}.log"
CLIENT_REPORT="/root/postfix_mail_report_v1_${TS}.txt"

exec > >(tee -a "$TECH_LOG") 2>&1

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
CLIENT_RESULTS=""
ENGINEER_NOTES=""
OUTGOING_IPS=""
MAIN_PUBLIC_IP=""
LOG_PATH=""

add_result() {
  local status="$1" title="$2" details="$3" recommendation="$4"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT+1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)) ;;
  esac
  CLIENT_RESULTS+="${status}|${title}|${details}|${recommendation}"$'\n'
}

add_engineer_note() {
  ENGINEER_NOTES+="$*"$'\n'
}

safe_cat() {
  local file="$1"
  if [[ -s "$file" ]]; then
    echo "# $file"
    sed 's/^/    /' "$file"
  else
    echo "# $file not found or empty"
  fi
}

get_public_ip() {
  local ip=""
  if cmd_exists curl; then
    ip=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  fi
  if [[ -z "$ip" ]] && cmd_exists dig; then
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  fi
  echo "$ip"
}

reverse_ip() {
  local ip="$1"
  awk -F. '{print $4"."$3"."$2"."$1}' <<< "$ip"
}

print_banner() {
  echo -e "${BOLD}"
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║        Postfix Mail Troubleshooter — Plesk Read-Only       ║"
  echo "║        Version ${SCRIPT_VERSION} — $(date '+%Y-%m-%d %H:%M:%S')              ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo "  Mode               : READ-ONLY diagnostic/report"
  echo "  Technical log      : $TECH_LOG"
  echo "  Client report      : $CLIENT_REPORT"
  echo "  DNSBL scan enabled : $ENABLE_DNSBL_SCAN"
}

# =============================================================================
# SECTION 1 — SERVER & PLESK / POSTFIX SERVICE
# =============================================================================
section_1_server_service() {
  hdr "1. Server & Plesk/Postfix Service"
  sep

  local hostname fqdn plesk_ver postfix_ver dovecot_ver ptr ptr_forward postfix_active dovecot_active
  hostname=$(hostname 2>/dev/null || echo unknown)
  fqdn=$(hostname -f 2>/dev/null || echo "$hostname")
  MAIN_PUBLIC_IP=$(get_public_ip)

  info "Hostname  : $fqdn"
  info "Public IP : ${MAIN_PUBLIC_IP:-unknown}"

  if cmd_exists plesk; then
    plesk_ver=$(plesk version 2>/dev/null | head -5 | paste -sd ' ' -)
    pass "Plesk CLI detected"
    info "Plesk      : ${plesk_ver:-detected, version unavailable}"
    add_result "PASS" "Plesk platform" "Plesk command-line tools were detected on the server." "No action required."
  elif [[ -x /usr/local/psa/bin/plesk ]]; then
    pass "Plesk binary detected at /usr/local/psa/bin/plesk"
    add_result "PASS" "Plesk platform" "Plesk binary was detected on the server." "No action required."
  else
    warn "Plesk CLI not detected"
    add_result "WARN" "Plesk platform" "Plesk command-line tools were not detected. This may not be a Plesk server or PATH may be limited." "Engineer should verify whether the server is managed by Plesk."
  fi

  if [[ -n "$MAIN_PUBLIC_IP" ]] && cmd_exists dig; then
    ptr=$(dig +short -x "$MAIN_PUBLIC_IP" 2>/dev/null | sed 's/\.$//' | head -1)
    if [[ -n "$ptr" ]]; then
      info "PTR record : $ptr"
      ptr_forward=$(dig +short A "$ptr" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
      if [[ "$ptr_forward" == "$MAIN_PUBLIC_IP" ]]; then
        pass "PTR forward-confirmed: $ptr -> $MAIN_PUBLIC_IP"
        add_result "PASS" "Reverse DNS / PTR" "The public IP has a PTR record and it forward-confirms back to the server IP." "No action required."
      else
        warn "PTR exists but does not forward-confirm to public IP"
        add_result "WARN" "Reverse DNS / PTR" "The server IP has a PTR record, but the PTR hostname does not resolve back to the same IP." "Ask the datacenter/provider to align PTR and forward DNS for better deliverability."
      fi
    else
      fail "No PTR record found for $MAIN_PUBLIC_IP"
      add_result "FAIL" "Reverse DNS / PTR" "No PTR record was found for the server public IP." "Ask the datacenter/provider to configure PTR/rDNS for the sending IP."
    fi
  else
    warn "Cannot perform PTR check because public IP or dig is unavailable"
    add_result "WARN" "Reverse DNS / PTR" "PTR validation could not be completed due to missing public IP or DNS tools." "Install bind-utils/dnsutils or verify network access."
  fi

  if systemctl is-active --quiet postfix 2>/dev/null || service postfix status >/dev/null 2>&1; then
    pass "Postfix service is running"
    postfix_active=1
    add_result "PASS" "Postfix service" "The Postfix mail service is running." "No action required."
  else
    fail "Postfix service is not running"
    postfix_active=0
    add_result "FAIL" "Postfix service" "The Postfix mail service is not running." "Engineer should review service status and mail logs. No automatic restart was performed."
  fi

  if systemctl is-active --quiet dovecot 2>/dev/null || service dovecot status >/dev/null 2>&1; then
    pass "Dovecot service is running"
    dovecot_active=1
    add_result "PASS" "Dovecot service" "The Dovecot POP/IMAP service is running." "No action required."
  else
    warn "Dovecot service is not running or not installed"
    dovecot_active=0
    add_result "WARN" "Dovecot service" "Dovecot is not running or was not detected. POP/IMAP mailbox access may be affected." "Engineer should verify if local mailbox service is expected on this server."
  fi

  postfix_ver=$(postconf mail_version 2>/dev/null | awk -F'= ' '{print $2}')
  [[ -n "$postfix_ver" ]] && info "Postfix version: $postfix_ver"
  dovecot_ver=$(dovecot --version 2>/dev/null | head -1)
  [[ -n "$dovecot_ver" ]] && info "Dovecot version: $dovecot_ver"

  echo ""
  info "Listening mail ports:"
  local ports="25 465 587 993 995 143 110"
  local listening=""
  for port in $ports; do
    if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]" || netstat -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
      pass "Port $port is listening"
      listening+="$port "
    else
      warn "Port $port is not listening"
    fi
  done

  if grep -qw "25" <<< "$listening"; then
    add_result "PASS" "SMTP listener" "SMTP port 25 is listening locally." "No action required."
  else
    add_result "FAIL" "SMTP listener" "SMTP port 25 is not listening locally." "Engineer should verify Postfix listener configuration and service status."
  fi

  if grep -qw "587" <<< "$listening" || grep -qw "465" <<< "$listening"; then
    add_result "PASS" "Submission listener" "At least one authenticated submission port, 587 or 465, is listening locally." "No action required."
  else
    add_result "WARN" "Submission listener" "Neither port 587 nor 465 appears to be listening locally." "Engineer should confirm whether authenticated outbound submission is required."
  fi
}

# =============================================================================
# SECTION 2 — POSTFIX QUEUE STATUS AND SPAM ANALYSIS
# =============================================================================
section_2_queue_spam() {
  hdr "2. Postfix Queue Status and Spam Analysis"
  sep

  local queue_raw queue_size deferred active incoming maildrop hold corrupt bounce_count top_sender_count top_sender
  if cmd_exists postqueue; then
    queue_raw=$(postqueue -p 2>/dev/null)
  elif cmd_exists mailq; then
    queue_raw=$(mailq 2>/dev/null)
  else
    fail "postqueue/mailq not found"
    add_result "FAIL" "Mail queue" "Unable to inspect the Postfix mail queue because postqueue/mailq was not found." "Engineer should verify Postfix installation."
    return
  fi

  if grep -qi "Mail queue is empty" <<< "$queue_raw"; then
    queue_size=0
  else
    queue_size=$(echo "$queue_raw" | awk '/^[A-F0-9][A-F0-9]/ {count++} END {print count+0}')
  fi

  info "Messages in queue: $queue_size"

  if [[ "$queue_size" -eq 0 ]]; then
    pass "Mail queue is empty"
    add_result "PASS" "Mail queue" "The Postfix mail queue is empty." "No action required."
  elif [[ "$queue_size" -le "$QUEUE_MODERATE_THRESHOLD" ]]; then
    pass "Queue size is normal ($queue_size messages)"
    add_result "PASS" "Mail queue" "The Postfix queue contains $queue_size message(s), which is within normal range." "No action required."
  elif [[ "$queue_size" -le "$QUEUE_WARN_THRESHOLD" ]]; then
    warn "Queue is moderate ($queue_size messages)"
    add_result "WARN" "Mail queue" "The Postfix queue contains $queue_size message(s). This is moderate and should be monitored." "Engineer should monitor queue growth and review deferred reasons if the number increases."
  else
    fail "Queue exceeds threshold ($queue_size > $QUEUE_WARN_THRESHOLD)"
    add_result "FAIL" "Mail queue" "The Postfix queue contains $queue_size message(s), exceeding the recommended threshold of $QUEUE_WARN_THRESHOLD." "Engineer should review deferred reasons, top senders, and possible spam source."
  fi

  echo ""
  info "Postfix spool directory breakdown:"
  for d in incoming active deferred hold maildrop bounce corrupt; do
    if [[ -d "/var/spool/postfix/$d" ]]; then
      local count size
      count=$(find "/var/spool/postfix/$d" -type f 2>/dev/null | wc -l)
      size=$(du -sh "/var/spool/postfix/$d" 2>/dev/null | awk '{print $1}')
      printf "    %-10s files=%-8s size=%s\n" "$d" "$count" "${size:-unknown}"
    fi
  done

  deferred=$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)
  hold=$(find /var/spool/postfix/hold -type f 2>/dev/null | wc -l)
  maildrop=$(find /var/spool/postfix/maildrop -type f 2>/dev/null | wc -l)

  if [[ ${deferred:-0} -gt 100 ]]; then
    add_result "WARN" "Deferred queue" "There are $deferred message file(s) in the deferred queue." "Engineer should review remote rejection, DNS, network, or reputation issues."
  fi
  if [[ ${hold:-0} -gt 0 ]]; then
    add_result "WARN" "Hold queue" "There are $hold message file(s) in the hold queue." "Engineer should verify whether messages were intentionally held."
  fi
  if [[ ${maildrop:-0} -gt 100 ]]; then
    add_result "WARN" "Maildrop queue" "There are $maildrop message file(s) in maildrop." "Engineer should check local injection volume and pickup service behavior."
  fi

  if [[ "$queue_size" -gt 0 ]]; then
    echo ""
    info "Queue sample, first 40 lines:"
    echo "$queue_raw" | head -40 | sed 's/^/    /'

    echo ""
    info "Top sender addresses visible in queue:"
    echo "$queue_raw" | sed -n 's/.*<\([^>]*@[^>]*\)>.*/\1/p' | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'

    top_sender_count=$(echo "$queue_raw" | sed -n 's/.*<\([^>]*@[^>]*\)>.*/\1/p' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    top_sender=$(echo "$queue_raw" | sed -n 's/.*<\([^>]*@[^>]*\)>.*/\1/p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    if [[ ${top_sender_count:-0} -gt 50 ]]; then
      add_result "WARN" "Possible bulk sender" "A sender appears frequently in the queue with approximately $top_sender_count queued message(s)." "Engineer should validate whether this is legitimate bulk mail or a compromised mailbox/script."
      add_engineer_note "Top queue sender candidate: $top_sender ($top_sender_count messages)"
    fi

    bounce_count=$(echo "$queue_raw" | grep -c '<>' || true)
    info "Bounce/DSN messages with empty sender <>: $bounce_count"
    if [[ ${bounce_count:-0} -gt 50 ]]; then
      add_result "WARN" "Bounce volume" "High bounce/DSN volume was observed in the queue." "Engineer should check for outbound spam, invalid recipient lists, or backscatter."
    fi
  fi

  echo ""
  info "PHP mail() / local script indicators from recent logs:"
  if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
    tail -n "$LOG_SAMPLE_LINES" "$LOG_PATH" 2>/dev/null | grep -Ei 'uid=|php|/var/www/vhosts|sendmail|pickup' | tail -30 | sed 's/^/    /'
  else
    warn "Mail log path unavailable for PHP/local script indicator scan"
  fi
}

# =============================================================================
# SECTION 3 — FIREWALL / PORT CONNECTIVITY
# =============================================================================
section_3_firewall_ports() {
  hdr "3. Firewall & Port Checks"
  sep

  local firewall_found=0 csf_conf="/etc/csf/csf.conf"

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall_found=1
    info "firewalld is active"
    echo ""
    firewall-cmd --list-all 2>/dev/null | sed 's/^/    /'
    if firewall-cmd --list-ports 2>/dev/null | grep -qE '25/tcp|465/tcp|587/tcp' || firewall-cmd --list-services 2>/dev/null | grep -qE 'smtp|smtps|submission'; then
      pass "Mail-related ports/services appear in firewalld"
      add_result "PASS" "firewalld mail rules" "firewalld is active and mail-related ports/services appear to be allowed." "No action required."
    else
      warn "Mail ports not clearly visible in firewalld rules"
      add_result "WARN" "firewalld mail rules" "firewalld is active, but mail ports were not clearly found in the listed rules." "Engineer should verify firewalld zones and allowed services."
    fi
  fi

  if [[ -f "$csf_conf" ]]; then
    firewall_found=1
    info "CSF detected: $csf_conf"
    grep -E '^(TCP_IN|TCP_OUT|SMTP_BLOCK|SMTP_ALLOWUSER|SMTP_ALLOWGROUP)' "$csf_conf" 2>/dev/null | sed 's/^/    /'
    if grep -q '^TCP_IN.*25' "$csf_conf" 2>/dev/null && grep -q '^TCP_OUT.*25' "$csf_conf" 2>/dev/null; then
      pass "Port 25 appears in CSF TCP_IN/TCP_OUT"
      add_result "PASS" "CSF mail rules" "CSF configuration includes port 25 in inbound and outbound TCP rules." "No action required."
    else
      warn "Port 25 not clearly present in both CSF TCP_IN and TCP_OUT"
      add_result "WARN" "CSF mail rules" "CSF is detected, but port 25 was not clearly found in both inbound and outbound rules." "Engineer should review /etc/csf/csf.conf for mail port rules."
    fi
  fi

  if iptables -S >/dev/null 2>&1; then
    firewall_found=1
    info "iptables rules sample for mail ports:"
    iptables -S 2>/dev/null | grep -E 'dport (25|465|587|993|995)|--dport (25|465|587|993|995)' | head -30 | sed 's/^/    /' || true
  fi

  if [[ "$firewall_found" -eq 0 ]]; then
    warn "No common firewall manager detected from firewalld/CSF/iptables"
    add_result "INFO" "Firewall manager" "No common firewall manager was clearly detected." "Engineer should verify the server firewall stack manually if network issues are reported."
  fi

  echo ""
  info "Local SMTP banner test:"
  local banner=""
  if cmd_exists nc; then
    banner=$(echo "QUIT" | timeout 5 nc -w 3 127.0.0.1 25 2>/dev/null | head -1)
  elif cmd_exists telnet; then
    banner=$(timeout 5 bash -c 'echo QUIT | telnet 127.0.0.1 25' 2>/dev/null | grep '^220' | head -1)
  fi

  if echo "$banner" | grep -q '^220'; then
    pass "SMTP banner received: $banner"
    add_result "PASS" "SMTP banner" "The local SMTP service returned a valid SMTP banner." "No action required."
  else
    fail "No SMTP banner received on localhost:25"
    add_result "FAIL" "SMTP banner" "No SMTP banner was received from localhost port 25." "Engineer should verify Postfix listener status and local firewall behavior."
  fi
}

# =============================================================================
# SECTION 4 — DISK SPACE & MAIL QUOTAS
# =============================================================================
section_4_disk_quotas() {
  hdr "4. Disk Space & Mail Quotas"
  sep

  info "Disk usage for key partitions:"
  df -h / /var /tmp /var/spool /var/qmail /var/www/vhosts 2>/dev/null | sed 's/^/    /'

  local full_parts spool_size mailnames_size vhosts_mail_size
  full_parts=$(df -h 2>/dev/null | awk '$5+0 >= 90 {print $6 " " $5}')
  if [[ -n "$full_parts" ]]; then
    fail "High disk usage detected >=90%"
    echo "$full_parts" | sed 's/^/    /'
    add_result "FAIL" "Disk usage" "One or more partitions are at or above 90% usage." "Engineer should review disk usage immediately because full disks can stop mail delivery."
  else
    pass "No partitions at or above 90% usage"
    add_result "PASS" "Disk usage" "No partitions were detected at critical disk usage." "No action required."
  fi

  spool_size=$(du -sh /var/spool/postfix 2>/dev/null | awk '{print $1}')
  info "Postfix spool size: ${spool_size:-unknown}"

  if [[ -d /var/qmail/mailnames ]]; then
    mailnames_size=$(du -sh /var/qmail/mailnames 2>/dev/null | awk '{print $1}')
    info "Plesk mailnames size: ${mailnames_size:-unknown}"
    echo ""
    info "Top mail storage domains under /var/qmail/mailnames:"
    du -sh /var/qmail/mailnames/* 2>/dev/null | sort -hr | head -15 | sed 's/^/    /'
    add_result "INFO" "Mailbox storage" "Mailbox storage details were collected from /var/qmail/mailnames." "Engineer should review the technical log if mailbox quota or storage usage is suspected."
  else
    warn "/var/qmail/mailnames not found"
    add_result "WARN" "Mailbox storage" "Plesk mail storage path /var/qmail/mailnames was not found." "Engineer should verify Plesk mail storage path on this system."
  fi

  if cmd_exists plesk; then
    echo ""
    info "Plesk mail accounts summary, first 30 lines:"
    plesk bin mail --list 2>/dev/null | head -30 | sed 's/^/    /' || warn "Unable to list Plesk mail accounts"
  fi
}

# =============================================================================
# SECTION 5 — OUTGOING MAIL IP / NAT / MAILHELO
# =============================================================================
section_5_outgoing_ip() {
  hdr "5. Outgoing Mail IP / NAT / MailHELO Check"
  sep

  local route_src inet_ips postfix_interfaces smtp_bind smtp_bind6 ptr
  MAIN_PUBLIC_IP="${MAIN_PUBLIC_IP:-$(get_public_ip)}"
  route_src=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  inet_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | paste -sd ' ' -)
  postfix_interfaces=$(postconf -h inet_interfaces 2>/dev/null)
  smtp_bind=$(postconf -h smtp_bind_address 2>/dev/null)
  smtp_bind6=$(postconf -h smtp_bind_address6 2>/dev/null)

  info "Detected public outbound IP : ${MAIN_PUBLIC_IP:-unknown}"
  info "Default route source IP     : ${route_src:-unknown}"
  info "Local IPv4 addresses        : ${inet_ips:-unknown}"
  info "Postfix inet_interfaces     : ${postfix_interfaces:-unknown}"
  info "Postfix smtp_bind_address   : ${smtp_bind:-not set}"
  info "Postfix smtp_bind_address6  : ${smtp_bind6:-not set}"

  OUTGOING_IPS=$(printf "%s\n%s\n%s\n" "$MAIN_PUBLIC_IP" "$route_src" "$smtp_bind" | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)

  if [[ -n "$OUTGOING_IPS" ]]; then
    pass "Outgoing IP candidate(s) identified"
    echo "$OUTGOING_IPS" | sed 's/^/    /'
    add_result "PASS" "Outgoing mail IP" "Outgoing IP candidate(s) were identified for reputation and PTR validation." "No action required."
  else
    warn "No outgoing IP candidates identified"
    add_result "WARN" "Outgoing mail IP" "The script could not confidently determine outgoing mail IP candidates." "Engineer should verify NAT, routing, and Postfix bind configuration manually."
  fi

  echo ""
  info "PTR check for outgoing IP candidate(s):"
  while read -r ipaddr; do
    [[ -z "$ipaddr" ]] && continue
    if cmd_exists dig; then
      ptr=$(dig +short -x "$ipaddr" 2>/dev/null | sed 's/\.$//' | head -1)
      if [[ -n "$ptr" ]]; then
        pass "$ipaddr PTR -> $ptr"
      else
        warn "$ipaddr has no PTR record"
        add_result "WARN" "Outgoing IP PTR" "Outgoing IP $ipaddr does not appear to have a PTR record." "Ask the datacenter/provider to configure PTR/rDNS for the sending IP."
      fi
    fi
  done <<< "$OUTGOING_IPS"

  echo ""
  info "Plesk/Postfix sender-dependent maps and related files:"
  for f in /etc/postfix/main.cf /etc/postfix/master.cf /etc/postfix/sender_dependent_default_transport_maps /etc/postfix/sender_dependent_relayhost_maps /var/spool/postfix/plesk/sdd_transport_maps.db; do
    if [[ -e "$f" ]]; then
      echo "    Found: $f"
    fi
  done

  echo ""
  info "Postfix relevant configuration:"
  postconf -n 2>/dev/null | grep -Ei '^(myhostname|myorigin|mydestination|relayhost|inet_interfaces|smtp_bind_address|smtp_helo_name|smtpd_banner|smtpd_tls|smtp_tls|smtpd_sasl|mynetworks|smtpd_recipient_restrictions|smtpd_relay_restrictions)' | sed 's/^/    /'
}

# =============================================================================
# SECTION 6 — IP REPUTATION / DNSBL SCAN
# =============================================================================
section_6_reputation_dnsbl() {
  hdr "6. IP Reputation / DNSBL Scan"
  sep

  if [[ "$ENABLE_DNSBL_SCAN" != "true" ]]; then
    warn "DNSBL scan skipped by option"
    add_result "INFO" "DNSBL scan" "DNSBL/RBL scan was skipped." "Engineer may rerun without --no-dnsbl if reputation validation is required."
    return
  fi

  if ! cmd_exists dig; then
    warn "dig not found; DNSBL scan unavailable"
    add_result "WARN" "DNSBL scan" "DNSBL scan could not run because dig is not installed." "Install bind-utils/dnsutils or perform reputation checks manually."
    return
  fi

  local rbls=(
    "zen.spamhaus.org"
    "bl.spamcop.net"
    "b.barracudacentral.org"
    "dnsbl.sorbs.net"
    "psbl.surriel.com"
    "spam.dnsbl.sorbs.net"
  )

  local total_listed=0 checked=0 lookup result rev
  local ips="$OUTGOING_IPS"
  [[ -z "$ips" && -n "$MAIN_PUBLIC_IP" ]] && ips="$MAIN_PUBLIC_IP"

  if [[ -z "$ips" ]]; then
    warn "No IP available for DNSBL scan"
    add_result "WARN" "DNSBL scan" "No outgoing/public IP was available for DNSBL scanning." "Engineer should verify public outbound IP and use external reputation tools."
    return
  fi

  while read -r ipaddr; do
    [[ -z "$ipaddr" ]] && continue
    echo ""
    info "Checking IP: $ipaddr"
    rev=$(reverse_ip "$ipaddr")
    for rbl in "${rbls[@]}"; do
      lookup="${rev}.${rbl}"
      result=$(timeout "$DNSBL_TIMEOUT" dig +short A "$lookup" 2>/dev/null | head -1)
      checked=$((checked+1))
      if [[ -n "$result" ]]; then
        fail "LISTED on $rbl -> $result"
        total_listed=$((total_listed+1))
        add_engineer_note "DNSBL listing detected: $ipaddr on $rbl ($result)"
      else
        pass "Not listed on $rbl"
      fi
    done
  done <<< "$ips"

  if [[ "$total_listed" -gt 0 ]]; then
    add_result "FAIL" "IP reputation / DNSBL" "$total_listed DNSBL listing(s) were detected across outgoing IP checks." "Engineer should verify reputation using RBL tools and follow delisting/remediation after spam source is resolved."
  else
    add_result "PASS" "IP reputation / DNSBL" "No DNSBL listings were detected across the configured DNSBL checks." "No action required."
  fi

  echo ""
  info "External reputation tools:"
  while read -r ipaddr; do
    [[ -z "$ipaddr" ]] && continue
    echo "    MXToolbox: https://mxtoolbox.com/SuperTool.aspx?action=blacklist:${ipaddr}"
    echo "    MultiRBL : https://multirbl.valli.org/lookup/${ipaddr}.html"
    echo "    Talos    : https://www.talosintelligence.com/reputation_center/lookup?search=${ipaddr}"
  done <<< "$ips"
}

# =============================================================================
# SECTION 7 — POSTFIX LOG HEALTH
# =============================================================================
section_7_log_health() {
  hdr "7. Postfix Log Health"
  sep

  local candidates=(/var/log/maillog /var/log/mail.log /usr/local/psa/var/log/maillog)
  local path=""
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      path="$p"
      break
    fi
  done
  LOG_PATH="$path"

  if [[ -z "$path" ]]; then
    fail "No common Postfix mail log found"
    add_result "FAIL" "Mail log" "No common Postfix mail log was found at /var/log/maillog, /var/log/mail.log, or /usr/local/psa/var/log/maillog." "Engineer should verify rsyslog/journald mail logging configuration."
    return
  fi

  pass "Mail log found: $path"
  add_result "PASS" "Mail log" "Postfix mail log was found at $path." "No action required."

  echo ""
  info "Recent SASL/authentication errors:"
  local sasl_count tls_count reject_count defer_count warning_count fatal_count
  sasl_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'sasl|authentication failed|auth failed')
  tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Ei 'sasl|authentication failed|auth failed' | tail -15 | sed 's/^/    /'

  echo ""
  info "Recent TLS/SSL related errors:"
  tls_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'TLS|SSL|certificate|handshake')
  tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Ei 'TLS|SSL|certificate|handshake' | tail -15 | sed 's/^/    /'

  echo ""
  info "Recent rejects/deferrals/bounces:"
  reject_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'reject|blocked|NOQUEUE')
  defer_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'defer|deferred|temporarily deferred|connect to .* timed out')
  tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Ei 'reject|blocked|NOQUEUE|defer|deferred|bounced|timed out' | tail -25 | sed 's/^/    /'

  echo ""
  info "Recent warning/fatal/panic style entries:"
  warning_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'warning:|fatal:|panic:|error:')
  fatal_count=$(tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Eic 'fatal:|panic:')
  tail -n "$LOG_SAMPLE_LINES" "$path" 2>/dev/null | grep -Ei 'warning:|fatal:|panic:|error:' | tail -25 | sed 's/^/    /'

  if [[ ${fatal_count:-0} -gt 0 ]]; then
    add_result "FAIL" "Postfix critical log errors" "Recent fatal/panic entries were found in the mail log." "Engineer should review the technical log and Postfix configuration immediately."
  elif [[ ${warning_count:-0} -gt 20 ]]; then
    add_result "WARN" "Postfix warnings" "Elevated warning/error entries were found in the recent mail log sample." "Engineer should review the technical log for recurring errors."
  else
    add_result "PASS" "Postfix log health" "No excessive critical Postfix errors were detected in the recent mail log sample." "No action required."
  fi

  if [[ ${sasl_count:-0} -gt 20 ]]; then
    add_result "WARN" "SASL authentication errors" "Elevated SASL/authentication errors were found in recent logs." "Engineer should check for brute-force attempts, compromised passwords, or client misconfiguration."
  fi
  if [[ ${defer_count:-0} -gt 20 ]]; then
    add_result "WARN" "Delivery deferrals" "Elevated delivery deferrals were detected in recent logs." "Engineer should review network, DNS, recipient server, and reputation causes."
  fi
}

# =============================================================================
# SECTION 8 — EXECUTIVE SUMMARY / CLIENT REPORT
# =============================================================================
generate_client_report() {
  local overall="PASS"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    overall="CRITICAL"
  elif [[ "$WARN_COUNT" -gt 0 ]]; then
    overall="WARNING"
  fi

  {
    echo "MAIL DELIVERY DIAGNOSTIC REPORT — PLESK / POSTFIX"
    echo "=================================================="
    echo "Date              : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Server Hostname   : $(hostname -f 2>/dev/null || hostname)"
    echo "Public IP         : ${MAIN_PUBLIC_IP:-unknown}"
    [[ -n "$CHECK_DOMAIN" ]] && echo "Domain Checked    : $CHECK_DOMAIN"
    echo "Overall Status    : $overall"
    echo ""
    echo "Summary Counts"
    echo "--------------"
    echo "PASS              : $PASS_COUNT"
    echo "WARNING           : $WARN_COUNT"
    echo "CRITICAL/FAIL     : $FAIL_COUNT"
    echo ""
    echo "Findings"
    echo "--------"

    while IFS='|' read -r status title details recommendation; do
      [[ -z "$status" ]] && continue
      case "$status" in
        PASS) label="PASS" ;;
        WARN) label="WARNING" ;;
        FAIL) label="CRITICAL" ;;
        INFO) label="INFO" ;;
        *) label="$status" ;;
      esac
      echo "[$label] $title"
      echo "Finding       : $details"
      echo "Recommendation: $recommendation"
      echo ""
    done <<< "$CLIENT_RESULTS"

    echo "Outgoing IP Candidate(s)"
    echo "------------------------"
    if [[ -n "$OUTGOING_IPS" ]]; then
      echo "$OUTGOING_IPS" | sed 's/^/- /'
    else
      echo "- Unable to determine confidently"
    fi
    echo ""

    echo "Engineer Notes"
    echo "--------------"
    echo "This report is generated from a read-only diagnostic script. No service restart, queue deletion, mailbox change, or configuration change was performed."
    echo "Full technical evidence log: $TECH_LOG"
    if [[ -n "$ENGINEER_NOTES" ]]; then
      echo ""
      echo "$ENGINEER_NOTES"
    fi
    echo ""
    echo "Reference Tools"
    echo "---------------"
    echo "Plesk Documentation     : https://docs.plesk.com/"
    echo "Postfix Documentation   : https://www.postfix.org/documentation.html"
    echo "MXToolbox Blacklist     : https://mxtoolbox.com/blacklists.aspx"
    echo "MultiRBL                : https://multirbl.valli.org/"
    echo "Mail Tester             : https://www.mail-tester.com/"
    echo "Talos Reputation        : https://www.talosintelligence.com/"
  } > "$CLIENT_REPORT"

  hdr "8. Executive Summary"
  sep
  echo "Overall Status : $overall"
  echo "PASS           : $PASS_COUNT"
  echo "WARNING        : $WARN_COUNT"
  echo "CRITICAL/FAIL  : $FAIL_COUNT"
  echo ""
  pass "Client-ready report generated: $CLIENT_REPORT"
  pass "Technical log saved: $TECH_LOG"
}

# =============================================================================
# MAIN
# =============================================================================
print_banner

# Determine log path early for queue/script checks
for p in /var/log/maillog /var/log/mail.log /usr/local/psa/var/log/maillog; do
  if [[ -f "$p" ]]; then
    LOG_PATH="$p"
    break
  fi
done

section_1_server_service
section_2_queue_spam
section_3_firewall_ports
section_4_disk_quotas
section_5_outgoing_ip
section_6_reputation_dnsbl
section_7_log_health
generate_client_report

echo ""
echo -e "${BOLD}${GREEN}Done.${RESET}"
echo "Client report: $CLIENT_REPORT"
echo "Technical log: $TECH_LOG"
