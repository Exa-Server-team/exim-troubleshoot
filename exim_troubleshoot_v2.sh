#!/usr/bin/env bash
# =============================================================================
# exim_troubleshoot_v2.sh — Read-Only Exim Mail Diagnostic Report for cPanel/WHM
# =============================================================================
# Purpose:
#   Collect safe, read-only Exim/cPanel mail diagnostics and generate:
#     1) Full engineer technical log
#     2) Clean client-ready report
#
# Usage:
#   curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/exim_troubleshoot_v2.sh | sudo bash
#
# Optional:
#   curl -s URL | sudo bash -s -- --no-color
#
# Scope kept in V2:
#   1. Server & Exim Service
#   2. Mail Queue Status and Spam Analysis
#   3. Firewall & Port Checks
#   4. Disk Space & Mail Quotas
#
# Safety:
#   READ-ONLY ONLY. This script does not restart services, delete queue messages,
#   suspend accounts, edit configs, or make firewall changes.
# =============================================================================

set -o pipefail

SCRIPT_NAME="exim_troubleshoot_v2.sh"
SCRIPT_VERSION="2.0.0"
QUEUE_WARN_THRESHOLD=200
QUEUE_MODERATE_THRESHOLD=50
QUEUE_CRITICAL_THRESHOLD=500
LOG_SAMPLE_LINES=1000
NO_COLOR=0

for arg in "$@"; do
  case "$arg" in
    --no-color) NO_COLOR=1 ;;
    --help|-h)
      echo "Usage: sudo bash $SCRIPT_NAME [--no-color]"
      exit 0
      ;;
  esac
done

if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
else
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
sep()   { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}ERROR:${RESET} This script must be run as root. Try: sudo bash $SCRIPT_NAME"
  exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"
TECH_LOG="/var/log/exim_troubleshoot_v2_${RUN_TS}.log"
CLIENT_REPORT="/root/exim_mail_report_${RUN_TS}.txt"
TMP_DIR="/tmp/exim_troubleshoot_v2_${RUN_TS}"
mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"

# Redirect all console output to technical log while still displaying it.
exec > >(tee -a "$TECH_LOG") 2>&1

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
CLIENT_RESULTS=""
CLIENT_RECOMMENDATIONS=""
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

  if [[ -n "$recommendation" && "$recommendation" != "No action required." ]]; then
    CLIENT_RECOMMENDATIONS+="- ${title}: ${recommendation}"$'\n'
  fi
}

add_engineer_note() {
  ENGINEER_NOTES+="- $*"$'\n'
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_public_ip() {
  local ip=""
  if command_exists curl; then
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ -z "$ip" && $(command_exists dig; echo $?) -eq 0 ]]; then
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
  fi
  echo "$ip"
}

safe_count() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo 0
}

sanitize_for_client() {
  # Avoid exposing internal paths, emails, or message IDs in client report.
  sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[redacted-email]/g' \
    -e 's#/home/[A-Za-z0-9._-]+/[^[:space:]]*#/home/[redacted]/...#g' \
    -e 's/[0-9A-Za-z]{6}-[0-9A-Za-z]{6}-[0-9A-Za-z]{2}/[redacted-message-id]/g'
}

write_client_report() {
  local overall_status
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    overall_status="FAIL"
  elif [[ "$WARN_COUNT" -gt 0 ]]; then
    overall_status="WARNING"
  else
    overall_status="PASS"
  fi

  {
    echo "MAIL DELIVERY DIAGNOSTIC REPORT"
    echo "================================"
    echo ""
    echo "Server Hostname : ${HOSTNAME:-unknown}"
    echo "Server IP       : ${SERVER_IP:-unknown}"
    echo "Control Panel   : cPanel/WHM"
    echo "Mail Service    : Exim"
    echo "Report Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Overall Status  : $overall_status"
    echo ""
    echo "Executive Summary"
    echo "-----------------"
    case "$overall_status" in
      PASS)
        echo "The checked mail service components appear healthy. No critical issue was detected within the selected diagnostic scope."
        ;;
      WARNING)
        echo "The mail service is operational, but one or more items require attention to reduce the risk of mail delay, rejection, or delivery degradation."
        ;;
      FAIL)
        echo "One or more critical items were detected. Hosting support should review the engineer log and address the failed checks before confirming mail stability."
        ;;
    esac
    echo ""
    echo "Result Summary"
    echo "--------------"
    echo "PASS    : $PASS_COUNT"
    echo "WARNING : $WARN_COUNT"
    echo "FAIL    : $FAIL_COUNT"
    echo ""
    echo "Findings"
    echo "--------"

    while IFS='|' read -r status title details recommendation; do
      [[ -z "$status" ]] && continue
      case "$status" in
        PASS) label="PASS" ;;
        WARN) label="WARNING" ;;
        FAIL) label="FAIL" ;;
        *) label="INFO" ;;
      esac
      echo "[$label] $title"
      echo "Details       : $details" | sanitize_for_client
      echo "Recommendation: ${recommendation:-No action required.}" | sanitize_for_client
      echo ""
    done <<< "$CLIENT_RESULTS"

    echo "Recommended Actions"
    echo "-------------------"
    if [[ -n "$CLIENT_RECOMMENDATIONS" ]]; then
      echo "$CLIENT_RECOMMENDATIONS" | sanitize_for_client
    else
      echo "No client action required based on the selected diagnostic checks."
    fi

    echo ""
    echo "Engineer Notes"
    echo "--------------"
    echo "This report is generated from a read-only diagnostic script. No service restart, queue deletion, account suspension, firewall change, or configuration modification was performed."
    echo "Full technical log: $TECH_LOG"
    if [[ -n "$ENGINEER_NOTES" ]]; then
      echo ""
      echo "Internal notes for hosting support:"
      echo "$ENGINEER_NOTES" | sanitize_for_client
    fi
  } > "$CLIENT_REPORT"

  chmod 600 "$CLIENT_REPORT" 2>/dev/null || true
}

# =============================================================================
# HEADER
# =============================================================================
clear 2>/dev/null || true
cat <<BANNER
╔══════════════════════════════════════════════════════════╗
║        Exim Mail Troubleshooter V2 — cPanel/WHM          ║
║        Read-Only Diagnostic + Client Report              ║
╚══════════════════════════════════════════════════════════╝
BANNER

echo "Script version : $SCRIPT_VERSION"
echo "Run date       : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Technical log  : $TECH_LOG"
echo "Client report  : $CLIENT_REPORT"
echo "Mode           : READ-ONLY. No changes will be made."

# =============================================================================
# SECTION 1 — SERVER & EXIM SERVICE
# =============================================================================
hdr "1. Server & Exim Service"
sep

HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
SERVER_IP=$(get_public_ip)

info "Hostname  : $HOSTNAME"
info "Public IP : ${SERVER_IP:-unknown}"

if [[ -x /usr/local/cpanel/cpanel ]]; then
  CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | awk '{print $1}')
  info "cPanel    : ${CPANEL_VER:-detected}"
  add_result "PASS" "cPanel environment" "cPanel/WHM was detected on the server." "No action required."
else
  warn "cPanel binary not found. This may not be a cPanel server."
  add_result "WARN" "cPanel environment" "cPanel/WHM binary was not detected at the expected path." "Confirm that the script is being executed on a cPanel/WHM server."
fi

if command_exists exim; then
  EXIM_VER=$(exim -bV 2>/dev/null | head -1)
  info "Exim version: ${EXIM_VER:-unknown}"
  add_result "PASS" "Exim binary" "Exim binary is available on the server." "No action required."
else
  fail "Exim command not found."
  add_result "FAIL" "Exim binary" "The Exim command was not found on this server." "Verify the mail server installation and ensure this script is executed on a cPanel Exim server."
fi

# Hostname forward DNS
if command_exists dig; then
  HOSTNAME_RESOLVED_IP=$(dig +short "$HOSTNAME" A 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  if [[ -z "$HOSTNAME_RESOLVED_IP" ]]; then
    fail "Hostname does not resolve via A record."
    add_result "FAIL" "Hostname DNS" "The server hostname does not resolve to an A record." "Add or correct the hostname A record so it points to the server IP address."
  elif [[ -n "$SERVER_IP" && "$HOSTNAME_RESOLVED_IP" == "$SERVER_IP" ]]; then
    pass "Hostname resolves correctly to this server IP."
    add_result "PASS" "Hostname DNS" "The server hostname resolves to the detected public server IP." "No action required."
  else
    warn "Hostname resolves to $HOSTNAME_RESOLVED_IP, expected ${SERVER_IP:-unknown}."
    add_result "WARN" "Hostname DNS" "The server hostname resolves to a different IP than the detected public server IP." "Review the hostname DNS A record and server outbound IP configuration."
  fi

  if [[ -n "$SERVER_IP" ]]; then
    PTR_RECORD=$(dig +short -x "$SERVER_IP" 2>/dev/null | sed 's/\.$//' | head -1)
    if [[ -z "$PTR_RECORD" ]]; then
      fail "No PTR/rDNS record found for $SERVER_IP."
      add_result "FAIL" "Reverse DNS / PTR" "No reverse DNS PTR record was found for the detected server IP." "Request the datacenter or IP provider to configure PTR/rDNS for the mail server hostname."
    else
      info "PTR record: $PTR_RECORD"
      PTR_FORWARD_IP=$(dig +short "$PTR_RECORD" A 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
      if [[ "$PTR_FORWARD_IP" == "$SERVER_IP" ]]; then
        pass "Forward-confirmed reverse DNS is valid."
        add_result "PASS" "Reverse DNS / PTR" "PTR record exists and forward-confirmed reverse DNS appears valid." "No action required."
      else
        warn "PTR exists but forward confirmation does not match this server IP."
        add_result "WARN" "Reverse DNS / PTR" "PTR record exists, but the PTR hostname does not resolve back to the detected server IP." "Correct the PTR hostname A record or update the PTR record to match the mail server hostname."
      fi
    fi
  fi
else
  warn "dig command not available. DNS checks skipped."
  add_result "WARN" "DNS tooling" "The dig command was not available, so hostname and PTR checks were limited." "Install bind-utils or dnsutils for complete DNS validation."
fi

if command_exists systemctl; then
  if systemctl is-active --quiet exim 2>/dev/null; then
    pass "Exim service is running."
    add_result "PASS" "Exim service status" "The Exim service is active and running." "No action required."
  else
    fail "Exim service is not running. No restart attempted."
    add_result "FAIL" "Exim service status" "The Exim service is not active." "Engineer should review service status and Exim logs. No automatic restart was performed by this report."
    add_engineer_note "Suggested checks: systemctl status exim -l; journalctl -u exim --no-pager | tail -100; tail -100 /var/log/exim_paniclog"
  fi
else
  if service exim status >/dev/null 2>&1; then
    pass "Exim service is running."
    add_result "PASS" "Exim service status" "The Exim service appears to be running." "No action required."
  else
    fail "Exim service is not running. No restart attempted."
    add_result "FAIL" "Exim service status" "The Exim service does not appear to be running." "Engineer should review service status and Exim logs."
  fi
fi

if command_exists ss; then
  PORT25_LISTEN=$(ss -tlnp 2>/dev/null | grep -E '(:25\s|:25$)' || true)
  PORT587_LISTEN=$(ss -tlnp 2>/dev/null | grep -E '(:587\s|:587$)' || true)
elif command_exists netstat; then
  PORT25_LISTEN=$(netstat -tlnp 2>/dev/null | grep -E '(:25\s|:25$)' || true)
  PORT587_LISTEN=$(netstat -tlnp 2>/dev/null | grep -E '(:587\s|:587$)' || true)
else
  PORT25_LISTEN=""
  PORT587_LISTEN=""
  warn "Neither ss nor netstat is available. Port listening checks are limited."
fi

if [[ -n "$PORT25_LISTEN" ]]; then
  pass "SMTP port 25 is listening."
  add_result "PASS" "SMTP port 25" "The server is listening on SMTP port 25." "No action required."
else
  fail "SMTP port 25 is not listening."
  add_result "FAIL" "SMTP port 25" "The server does not appear to be listening on SMTP port 25." "Engineer should confirm Exim status and local port binding."
fi

if [[ -n "$PORT587_LISTEN" ]]; then
  pass "Submission port 587 is listening."
  add_result "PASS" "Submission port 587" "The server is listening on mail submission port 587." "No action required."
else
  warn "Submission port 587 is not detected."
  add_result "WARN" "Submission port 587" "The server does not appear to be listening on port 587." "Confirm whether SMTP submission is expected for this server."
fi

# =============================================================================
# SECTION 2 — MAIL QUEUE STATUS AND SPAM ANALYSIS
# =============================================================================
hdr "2. Mail Queue Status and Spam Analysis"
sep

QUEUE_RAW_FILE="$TMP_DIR/exim_queue.txt"
QUEUE_RAW=""
QUEUE_SIZE=0

if command_exists exim; then
  exim -bp 2>/dev/null > "$QUEUE_RAW_FILE"
  QUEUE_RAW=$(cat "$QUEUE_RAW_FILE")
  if command_exists exiqgrep; then
    QUEUE_SIZE=$(exim -bpc 2>/dev/null | tr -d '[:space:]')
  else
    QUEUE_SIZE=$(grep -cE '^\s*[0-9]+[smhdw]' "$QUEUE_RAW_FILE" 2>/dev/null || echo 0)
  fi
  QUEUE_SIZE=$(safe_count "$QUEUE_SIZE")
else
  fail "Exim not available, queue check skipped."
  add_result "FAIL" "Mail queue" "Unable to check mail queue because Exim is not available." "Engineer should verify Exim installation and service state."
fi

if command_exists exim; then
  info "Messages in queue: $QUEUE_SIZE"

  if [[ "$QUEUE_SIZE" -eq 0 ]]; then
    pass "Mail queue is empty."
    add_result "PASS" "Mail queue volume" "The mail queue is empty." "No action required."
  elif [[ "$QUEUE_SIZE" -le "$QUEUE_MODERATE_THRESHOLD" ]]; then
    pass "Mail queue is normal: $QUEUE_SIZE messages."
    add_result "PASS" "Mail queue volume" "The mail queue contains $QUEUE_SIZE message(s), which is within the normal threshold." "No action required."
  elif [[ "$QUEUE_SIZE" -le "$QUEUE_WARN_THRESHOLD" ]]; then
    warn "Mail queue is moderate: $QUEUE_SIZE messages."
    add_result "WARN" "Mail queue volume" "The mail queue contains $QUEUE_SIZE message(s), which is elevated but below the alert threshold of $QUEUE_WARN_THRESHOLD." "Monitor queue growth and review recent delivery delays if users report mail issues."
  elif [[ "$QUEUE_SIZE" -le "$QUEUE_CRITICAL_THRESHOLD" ]]; then
    fail "Mail queue exceeds threshold: $QUEUE_SIZE messages."
    add_result "FAIL" "Mail queue volume" "The mail queue contains $QUEUE_SIZE message(s), exceeding the threshold of $QUEUE_WARN_THRESHOLD." "Engineer should investigate possible delivery failure, spam activity, or remote rejection patterns."
  else
    fail "Mail queue is critically large: $QUEUE_SIZE messages."
    add_result "FAIL" "Mail queue volume" "The mail queue contains $QUEUE_SIZE message(s), which is critically high." "Urgent engineer review is required to identify spam source, delivery blockage, or mail loop."
  fi

  if [[ "$QUEUE_SIZE" -gt 0 ]]; then
    info "Queue age breakdown:"
    awk '
      /^ *[0-9]+[smhdw]/ {
        age=$1
        unit=substr($1,length($1),1)
        sub(/[smhdw]/,"",age)
        if(unit=="m") age=age*60
        else if(unit=="h") age=age*3600
        else if(unit=="d") age=age*86400
        else if(unit=="w") age=age*604800
        if(age<3600) lt1h++
        else if(age<86400) lt1d++
        else if(age<604800) lt1w++
        else gt1w++
      }
      END {
        print "    < 1 hour : " lt1h+0
        print "    < 1 day  : " lt1d+0
        print "    < 1 week : " lt1w+0
        print "    > 1 week : " gt1w+0
      }
    ' "$QUEUE_RAW_FILE"

    FROZEN_COUNT=$(grep -ci "frozen" "$QUEUE_RAW_FILE" 2>/dev/null || echo 0)
    FROZEN_COUNT=$(safe_count "$FROZEN_COUNT")
    info "Frozen messages: $FROZEN_COUNT"
    if [[ "$FROZEN_COUNT" -gt 20 ]]; then
      fail "High frozen message count detected."
      add_result "FAIL" "Frozen queue messages" "$FROZEN_COUNT frozen message(s) were detected in the mail queue." "Engineer should review frozen messages and confirm whether they are failed deliveries, bounces, or spam-related backlog."
    elif [[ "$FROZEN_COUNT" -gt 0 ]]; then
      warn "Frozen messages detected."
      add_result "WARN" "Frozen queue messages" "$FROZEN_COUNT frozen message(s) were detected in the mail queue." "Review frozen messages if users report delayed or failed delivery."
    else
      pass "No frozen messages detected."
      add_result "PASS" "Frozen queue messages" "No frozen messages were detected in the mail queue." "No action required."
    fi

    BOUNCE_COUNT=$(grep -c '<>' "$QUEUE_RAW_FILE" 2>/dev/null || echo 0)
    BOUNCE_COUNT=$(safe_count "$BOUNCE_COUNT")
    info "Bounce/DSN messages: $BOUNCE_COUNT"
    if [[ "$BOUNCE_COUNT" -gt 50 ]]; then
      fail "High bounce/DSN volume detected."
      add_result "FAIL" "Bounce message volume" "$BOUNCE_COUNT bounce or DSN message(s) were detected." "Engineer should investigate potential outbound spam, backscatter, or invalid recipient activity."
    elif [[ "$BOUNCE_COUNT" -gt 10 ]]; then
      warn "Elevated bounce/DSN volume detected."
      add_result "WARN" "Bounce message volume" "$BOUNCE_COUNT bounce or DSN message(s) were detected." "Monitor bounce volume and review recent mail delivery failures."
    else
      pass "Bounce/DSN volume is low."
      add_result "PASS" "Bounce message volume" "Bounce or DSN message count is low." "No action required."
    fi

    # Technical-only spam source summaries. Do not expose raw addresses in client report.
    echo ""
    info "Technical-only queue sender summary, redacted from client report:"
    sed -n 's/.*<\([^>]*@[^>]*\)>.*/\1/p' "$QUEUE_RAW_FILE" | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'

    TOP_SENDER_COUNT=$(sed -n 's/.*<\([^>]*@[^>]*\)>.*/\1/p' "$QUEUE_RAW_FILE" | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    TOP_SENDER_COUNT=$(safe_count "$TOP_SENDER_COUNT")
    if [[ "$TOP_SENDER_COUNT" -gt 50 ]]; then
      warn "One sender appears frequently in queue. Details are kept in engineer log only."
      add_result "WARN" "Possible bulk sender pattern" "One sender appears frequently in the queue based on the technical analysis." "Engineer should review the technical log to confirm whether this is legitimate bulk mail or possible compromised sending."
    else
      add_result "PASS" "Bulk sender pattern" "No single sender exceeded the bulk sender alert threshold in the current queue sample." "No action required."
    fi

    if [[ -f /var/log/exim_mainlog ]]; then
      echo ""
      info "Technical-only script path summary from recent Exim log entries:"
      tail -"$LOG_SAMPLE_LINES" /var/log/exim_mainlog 2>/dev/null | sed -n 's/.*cwd=\([^ ]*\).*/\1/p' | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    fi
  fi

  # Exim panic log check
  if [[ -f /var/log/exim_paniclog ]]; then
    PANIC_LINES=$(wc -l < /var/log/exim_paniclog 2>/dev/null || echo 0)
    PANIC_LINES=$(safe_count "$PANIC_LINES")
    if [[ "$PANIC_LINES" -gt 0 ]]; then
      fail "Exim panic log has entries."
      add_result "FAIL" "Exim panic log" "The Exim panic log contains $PANIC_LINES line(s)." "Engineer should review /var/log/exim_paniclog for critical Exim errors."
      add_engineer_note "Recent Exim panic log entries are available in the technical log."
      tail -20 /var/log/exim_paniclog 2>/dev/null | sed 's/^/    /'
    else
      pass "Exim panic log is empty."
      add_result "PASS" "Exim panic log" "No entries were found in the Exim panic log." "No action required."
    fi
  else
    warn "Exim panic log not found."
    add_result "WARN" "Exim panic log" "The Exim panic log file was not found at the expected path." "Confirm Exim logging configuration if troubleshooting service failures."
  fi
fi

# =============================================================================
# SECTION 3 — FIREWALL & PORT CHECKS
# =============================================================================
hdr "3. Firewall & Port Checks"
sep

if command_exists systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld is active."
  if command_exists firewall-cmd; then
    FIREWALL_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
    FIREWALL_SERVICES=$(firewall-cmd --list-services 2>/dev/null || true)
    echo "  firewalld ports    : ${FIREWALL_PORTS:-none listed}"
    echo "  firewalld services : ${FIREWALL_SERVICES:-none listed}"
    if echo "$FIREWALL_PORTS $FIREWALL_SERVICES" | grep -Eq '25/tcp|smtp'; then
      pass "SMTP appears allowed in firewalld."
      add_result "PASS" "firewalld SMTP access" "firewalld is active and SMTP appears to be allowed." "No action required."
    else
      warn "SMTP is not explicitly listed in firewalld rules."
      add_result "WARN" "firewalld SMTP access" "firewalld is active, but SMTP was not explicitly found in listed ports or services." "Engineer should verify inbound SMTP allowance if external delivery to the server is affected."
    fi
  else
    warn "firewalld active but firewall-cmd unavailable."
    add_result "WARN" "firewalld tooling" "firewalld appears active, but firewall-cmd was not available for rule inspection." "Engineer should manually verify firewall rules."
  fi
else
  info "firewalld is not active or not installed."
  add_result "PASS" "firewalld status" "firewalld is not active, or it is not installed." "No action required unless this server is expected to use firewalld."
fi

if [[ -f /etc/csf/csf.conf ]]; then
  info "CSF detected."
  CSF_TCP_IN=$(grep -E '^TCP_IN' /etc/csf/csf.conf 2>/dev/null | head -1)
  CSF_TCP_OUT=$(grep -E '^TCP_OUT' /etc/csf/csf.conf 2>/dev/null | head -1)
  echo "  $CSF_TCP_IN"
  echo "  $CSF_TCP_OUT"

  if echo "$CSF_TCP_IN" | grep -Eq '(^|[^0-9])25([^0-9]|$)'; then
    pass "Port 25 found in CSF TCP_IN."
    add_result "PASS" "CSF inbound SMTP" "CSF configuration includes port 25 in TCP_IN." "No action required."
  else
    warn "Port 25 not found in CSF TCP_IN."
    add_result "WARN" "CSF inbound SMTP" "CSF configuration does not clearly include port 25 in TCP_IN." "Engineer should verify CSF inbound SMTP rules if inbound mail is affected."
  fi

  if echo "$CSF_TCP_OUT" | grep -Eq '(^|[^0-9])25([^0-9]|$)'; then
    pass "Port 25 found in CSF TCP_OUT."
    add_result "PASS" "CSF outbound SMTP" "CSF configuration includes port 25 in TCP_OUT." "No action required."
  else
    warn "Port 25 not found in CSF TCP_OUT."
    add_result "WARN" "CSF outbound SMTP" "CSF configuration does not clearly include port 25 in TCP_OUT." "Engineer should verify CSF outbound SMTP rules if outbound delivery is affected."
  fi
else
  info "CSF configuration not detected."
  add_result "PASS" "CSF status" "CSF configuration was not detected on this server." "No action required unless this server is expected to use CSF."
fi

# Local SMTP banner test
if command_exists nc; then
  SMTP_TEST=$(echo "QUIT" | timeout 5 nc -w 3 127.0.0.1 25 2>/dev/null | head -1)
  if echo "$SMTP_TEST" | grep -q '^220'; then
    pass "Local SMTP banner received: $SMTP_TEST"
    add_result "PASS" "Local SMTP banner" "The local SMTP service responded with a valid banner on port 25." "No action required."
  else
    fail "No valid local SMTP banner received on port 25."
    add_result "FAIL" "Local SMTP banner" "The local SMTP service did not return a valid SMTP banner on port 25." "Engineer should verify Exim listener status and local firewall rules."
  fi
else
  warn "nc command not available. Local SMTP banner test skipped."
  add_result "WARN" "Local SMTP banner" "The nc command was not available, so local SMTP banner testing was skipped." "Install nc/nmap-ncat if local SMTP banner validation is required."
fi

# External SMTP reachability quick test; only test if timeout + bash tcp available is not reliable, so keep as technical note.
add_engineer_note "External SMTP reachability from the internet is not fully proven by local checks. If inbound mail is affected, test from an external network."

# =============================================================================
# SECTION 4 — DISK SPACE & MAIL QUOTAS
# =============================================================================
hdr "4. Disk Space & Mail Quotas"
sep

info "Disk usage for key partitions:"
df -h / /home /var /tmp 2>/dev/null | sed 's/^/    /'

FULL_PARTS=$(df -P 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if($5+0 >= 90) print $6 " " $5 "%"}')
if [[ -n "$FULL_PARTS" ]]; then
  fail "One or more partitions are at or above 90%."
  echo "$FULL_PARTS" | sed 's/^/    /'
  add_result "FAIL" "Disk usage" "One or more server partitions are at or above 90% usage." "Engineer should free disk space or expand storage to prevent mail queue, logging, and mailbox delivery issues."
else
  pass "No partitions at or above 90% usage."
  add_result "PASS" "Disk usage" "No checked partition was found at or above 90% usage." "No action required."
fi

if [[ -d /var/spool/exim ]]; then
  EXIM_SPOOL_SIZE=$(du -sh /var/spool/exim 2>/dev/null | awk '{print $1}')
  info "Exim spool size: ${EXIM_SPOOL_SIZE:-unknown}"
  add_result "PASS" "Exim spool directory" "The Exim spool directory is present. Current size: ${EXIM_SPOOL_SIZE:-unknown}." "No action required unless the queue is elevated or disk usage is high."
else
  warn "Exim spool directory not found."
  add_result "WARN" "Exim spool directory" "The Exim spool directory was not found at /var/spool/exim." "Engineer should confirm Exim spool path and mail server configuration."
fi

# Mailbox usage summary for cPanel accounts
if [[ -d /home ]]; then
  info "Top mailbox storage usage under /home/*/mail, if available:"
  MAIL_USAGE_FILE="$TMP_DIR/mail_usage.txt"
  find /home -maxdepth 2 -type d -name mail 2>/dev/null | while read -r maildir; do
    du -sh "$maildir" 2>/dev/null
  done | sort -hr | head -10 | tee "$MAIL_USAGE_FILE" | sed 's/^/    /'

  if [[ -s "$MAIL_USAGE_FILE" ]]; then
    add_result "PASS" "Mailbox storage scan" "Mailbox storage directories were detected and summarized in the engineer log." "No action required unless a specific mailbox or account is consuming abnormal storage."
  else
    warn "No /home/*/mail directories found or accessible."
    add_result "WARN" "Mailbox storage scan" "No cPanel mailbox directories were found or accessible under /home." "Confirm whether this server stores mail locally or uses a custom home directory path."
  fi
else
  warn "/home directory not found."
  add_result "WARN" "Mailbox storage scan" "/home directory was not found." "Confirm the server home directory layout."
fi

# cPanel quota summary if available
if command_exists repquota; then
  info "Quota tool detected. Full quota output is not included in client report."
  add_engineer_note "Use repquota -a for full user quota details if mailbox delivery fails due to account quota."
else
  info "repquota command not available or quotas may not be enabled."
fi

# =============================================================================
# REPORT OUTPUT
# =============================================================================
write_client_report

hdr "Summary"
sep

echo "PASS count       : $PASS_COUNT"
echo "WARNING count    : $WARN_COUNT"
echo "FAIL count       : $FAIL_COUNT"
echo "Technical log    : $TECH_LOG"
echo "Client report    : $CLIENT_REPORT"
echo "Mode             : READ-ONLY. No changes were made."

echo ""
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  fail "Diagnostic completed with failed checks. Review the client report and engineer log."
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  warn "Diagnostic completed with warnings. Review the client report."
else
  pass "Diagnostic completed successfully. No issue detected within selected scope."
fi

rm -rf "$TMP_DIR" 2>/dev/null || true
