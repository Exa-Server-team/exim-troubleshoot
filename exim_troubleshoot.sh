#!/usr/bin/env bash
# =============================================================================
# exim_troubleshoot.sh — Exim Mail Troubleshooter for cPanel/WHM Servers
# =============================================================================
# Usage:
#   chmod +x exim_troubleshoot.sh
#   sudo ./exim_troubleshoot.sh
#
# Requirements: Must run as root or via sudo on a cPanel/WHM server
# Tested on: CentOS 7/8, AlmaLinux 8/9, CloudLinux (cPanel/WHM)
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
sep()   { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}ERROR:${RESET} This script must be run as root. Try: sudo $0"
  exit 1
fi

# ── Log output ───────────────────────────────────────────────────────────────
LOGFILE="/var/log/exim_troubleshoot_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Exim Mail Troubleshooter — cPanel/WHM             ║"
echo "║        $(date '+%Y-%m-%d %H:%M:%S')                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  Full log saved to: $LOGFILE"

# =============================================================================
# SECTION 1 — SERVER & EXIM BASICS
# =============================================================================
hdr "1. Server & Exim Service"
sep

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || \
            ip route get 1 | awk '{print $7; exit}')

info "Hostname  : $HOSTNAME"
info "Public IP : ${SERVER_IP:-unknown}"

# cPanel version
if [[ -x /usr/local/cpanel/cpanel ]]; then
  CPANEL_VER=$(/usr/local/cpanel/cpanel -V 2>/dev/null | awk '{print $1}')
  info "cPanel    : $CPANEL_VER"
else
  warn "cPanel binary not found — is this a cPanel server?"
fi

# ── Hostname Resolution & PTR Check ──────────────────────────────────────────
echo ""
info "── Hostname Resolution & PTR Validation ──"

# Forward DNS: does hostname resolve to an IP?
HOSTNAME_RESOLVED_IP=$(dig +short "$HOSTNAME" A 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)

if [[ -z "$HOSTNAME_RESOLVED_IP" ]]; then
  fail "Hostname '$HOSTNAME' does NOT resolve to any IP via forward DNS (A record missing)"
  warn "Fix: Add an A record for $HOSTNAME pointing to $SERVER_IP"
else
  info "Hostname A record resolves to: $HOSTNAME_RESOLVED_IP"

  # Does the hostname resolve to THIS server's IP?
  if [[ "$HOSTNAME_RESOLVED_IP" == "$SERVER_IP" ]]; then
    pass "Hostname resolves correctly to this server's IP ($SERVER_IP)"
  else
    fail "Hostname resolves to $HOSTNAME_RESOLVED_IP but server public IP is $SERVER_IP"
    warn "Mismatch may cause SMTP rejections — update A record or check IP binding"
  fi
fi

# Reverse DNS: does the server IP have a PTR record?
if [[ -n "$SERVER_IP" ]]; then
  PTR_RECORD=$(dig +short -x "$SERVER_IP" 2>/dev/null | sed 's/\.$//')

  if [[ -z "$PTR_RECORD" ]]; then
    fail "No PTR (rDNS) record found for $SERVER_IP"
    warn "Many mail servers reject email from IPs without PTR records"
    warn "Fix: Contact your datacenter/ISP to set PTR → $HOSTNAME"
  else
    info "PTR record for $SERVER_IP : $PTR_RECORD"

    # Does PTR match the server hostname? (forward-confirmed rDNS)
    if [[ "$PTR_RECORD" == "$HOSTNAME" ]]; then
      pass "PTR record matches hostname exactly — forward-confirmed rDNS (FCrDNS) OK"
    else
      # Partial match check (e.g. PTR is subdomain of hostname domain)
      HOSTNAME_DOMAIN=$(echo "$HOSTNAME" | cut -d. -f2-)
      if echo "$PTR_RECORD" | grep -q "$HOSTNAME_DOMAIN"; then
        warn "PTR '$PTR_RECORD' partially matches hostname domain '$HOSTNAME_DOMAIN'"
        warn "Ideally PTR should match the FQDN exactly: $HOSTNAME"
      else
        fail "PTR '$PTR_RECORD' does NOT match hostname '$HOSTNAME'"
        warn "FCrDNS failure — strict receivers (Gmail, Outlook) may reject your mail"
        warn "Fix: Ask your DC to set PTR for $SERVER_IP → $HOSTNAME"
      fi
    fi

    # Forward-confirm the PTR: does PTR hostname resolve back to server IP?
    PTR_FORWARD_IP=$(dig +short "$PTR_RECORD" A 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ "$PTR_FORWARD_IP" == "$SERVER_IP" ]]; then
      pass "FCrDNS confirmed: $PTR_RECORD → $PTR_FORWARD_IP ✔"
    elif [[ -z "$PTR_FORWARD_IP" ]]; then
      warn "PTR hostname '$PTR_RECORD' does not resolve forward — broken FCrDNS"
    else
      warn "PTR hostname '$PTR_RECORD' resolves to $PTR_FORWARD_IP (expected $SERVER_IP)"
    fi
  fi
fi

# Does Exim's configured hostname match the system hostname?
EXIM_HOSTNAME=$(exim -bP primary_hostname 2>/dev/null | awk '{print $NF}' | tr -d '"')
if [[ -n "$EXIM_HOSTNAME" ]]; then
  info "Exim primary_hostname: $EXIM_HOSTNAME"
  if [[ "$EXIM_HOSTNAME" == "$HOSTNAME" ]]; then
    pass "Exim primary_hostname matches system hostname"
  else
    warn "Exim primary_hostname '$EXIM_HOSTNAME' differs from system hostname '$HOSTNAME'"
    warn "This affects SMTP HELO/EHLO greeting — update WHM → Exim Configuration Manager"
  fi
fi

# ── Exim Service ──────────────────────────────────────────────────────────────
echo ""
info "── Exim Service ──"

# Exim service
if systemctl is-active --quiet exim 2>/dev/null || \
   service exim status &>/dev/null 2>&1; then
  pass "Exim service is running"
else
  fail "Exim service is NOT running"
  echo ""
  echo "  Attempting to start Exim..."
  service exim start 2>/dev/null || systemctl start exim 2>/dev/null
  sleep 2
  if systemctl is-active --quiet exim 2>/dev/null; then
    pass "Exim started successfully"
  else
    fail "Could not start Exim — check: journalctl -xe | grep exim"
  fi
fi

# Exim version
EXIM_VER=$(exim -bV 2>/dev/null | head -1)
info "Exim version: ${EXIM_VER:-not found}"

# Exim listening on port 25
if ss -tlnp 2>/dev/null | grep -q ':25 ' || \
   netstat -tlnp 2>/dev/null | grep -q ':25 '; then
  pass "Exim is listening on port 25"
else
  fail "Nothing is listening on port 25"
fi

# Port 587 (submission)
if ss -tlnp 2>/dev/null | grep -q ':587 ' || \
   netstat -tlnp 2>/dev/null | grep -q ':587 '; then
  pass "Submission port 587 is open"
else
  warn "Port 587 not detected (may not be required)"
fi

# =============================================================================
# SECTION 2 — MAIL QUEUE
# =============================================================================
hdr "2. Mail Queue Status and Spam Analysis"
sep

# Capture full queue output once for reuse
QUEUE_RAW=$(exim -bp 2>/dev/null)
QUEUE_SIZE=$(echo "$QUEUE_RAW" | grep -c '^\s*[0-9]' || echo 0)

info "Messages in queue: $QUEUE_SIZE"
echo ""

# Threshold evaluation
if [[ $QUEUE_SIZE -eq 0 ]]; then
  pass "Mail queue is empty"
elif [[ $QUEUE_SIZE -le 50 ]]; then
  pass "Queue size is normal ($QUEUE_SIZE messages)"
elif [[ $QUEUE_SIZE -le 200 ]]; then
  warn "Queue is moderate ($QUEUE_SIZE messages) — monitor for growth"
elif [[ $QUEUE_SIZE -le 500 ]]; then
  fail "Queue exceeds 200 ($QUEUE_SIZE messages) — deep analysis triggered below"
else
  fail "Queue is critically large ($QUEUE_SIZE messages >500) — likely spam backlog or delivery loop!"
fi

# Queue age breakdown
if [[ $QUEUE_SIZE -gt 0 ]]; then
  echo ""
  info "Queue age breakdown:"
  echo "$QUEUE_RAW" | awk '
    /^ *[0-9]+[smhdw]/ {
      age=$1
      unit=substr($1,length($1),1)
      sub(/[smhdw]/,"",age)
      if(unit=="m") age=age*60
      else if(unit=="h") age=age*3600
      else if(unit=="d") age=age*86400
      else if(unit=="w") age=age*604800
      if(age<3600)       lt1h++
      else if(age<86400) lt1d++
      else if(age<604800) lt1w++
      else               gt1w++
    }
    END {
      print "    < 1 hour : " lt1h+0
      print "    < 1 day  : " lt1d+0
      print "    < 1 week : " lt1w+0
      print "    > 1 week : " gt1w+0
    }
  '
fi

# Deep analysis triggered when queue > 200
if [[ $QUEUE_SIZE -gt 200 ]]; then
  echo ""
  warn "Queue exceeds 200 — running bulk/spam analysis..."
  sep

  # Top senders in queue
  echo ""
  info "[Queue Analysis] Top sender addresses in spool:"
  echo "$QUEUE_RAW" | grep -oP '(?<=<)[^>]+@[^>]+(?=>)' | \
    sort | uniq -c | sort -rn | head -15 | \
    awk '{printf "    %6s messages  ->  %s\n", $1, $2}'

  TOP_SENDER_COUNT=$(echo "$QUEUE_RAW" | grep -oP '(?<=<)[^>]+@[^>]+(?=>)' | \
    sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
  TOP_SENDER_ADDR=$(echo "$QUEUE_RAW" | grep -oP '(?<=<)[^>]+@[^>]+(?=>)' | \
    sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

  if [[ ${TOP_SENDER_COUNT:-0} -gt 50 ]]; then
    fail "POSSIBLE SPAM SOURCE: '$TOP_SENDER_ADDR' has $TOP_SENDER_COUNT queued messages"
    warn "Investigate: grep '$TOP_SENDER_ADDR' /var/log/exim_mainlog | tail -30"
    warn "Suspend if confirmed: /scripts/suspendacct <cpanel_user>"
  fi

  # Top sender domains
  echo ""
  info "[Queue Analysis] Top sender domains in spool:"
  echo "$QUEUE_RAW" | grep -oP '(?<=<)[^>]+@[^>]+(?=>)' | \
    grep -oP '@.+' | tr -d '@' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s messages  <- domain: %s\n", $1, $2}'

  # Top recipient domains
  echo ""
  info "[Queue Analysis] Top recipient domains (outbound targets):"
  echo "$QUEUE_RAW" | grep -oP '^\s+[A-Za-z0-9]+\s+\S+\s+<[^>]+>' | \
    grep -oP '(?<=<)[^>]+' | grep -oP '@.+' | tr -d '@' | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s messages  ->  %s\n", $1, $2}'

  # Frozen messages
  echo ""
  FROZEN_COUNT=$(echo "$QUEUE_RAW" | grep -c "frozen")
  info "[Queue Analysis] Frozen messages: $FROZEN_COUNT"
  if [[ $FROZEN_COUNT -gt 20 ]]; then
    fail "$FROZEN_COUNT frozen messages — likely bounces or undeliverables piling up"
    warn "Remove frozen: exim -bp | awk '/frozen/{print \$3}' | xargs exim -Mrm"
  elif [[ $FROZEN_COUNT -gt 0 ]]; then
    warn "$FROZEN_COUNT frozen messages — review before purging"
  else
    pass "No frozen messages"
  fi

  # Bounce / DSN storm check
  echo ""
  BOUNCE_COUNT=$(echo "$QUEUE_RAW" | grep -c '<>')
  info "[Queue Analysis] Bounce/DSN messages (empty sender <>): $BOUNCE_COUNT"
  if [[ $BOUNCE_COUNT -gt 50 ]]; then
    fail "High bounce volume ($BOUNCE_COUNT) — possible backscatter or spam bounce storm"
    warn "Indicator of outbound spam causing NDRs; check SPF/DKIM and sending accounts"
  elif [[ $BOUNCE_COUNT -gt 10 ]]; then
    warn "Elevated bounce messages ($BOUNCE_COUNT) — monitor"
  else
    pass "Bounce/DSN count is low ($BOUNCE_COUNT)"
  fi

  # Unique sender count
  echo ""
  UNIQUE_SENDERS=$(echo "$QUEUE_RAW" | grep -oP '(?<=<)[^>]+@[^>]+(?=>)' | \
    sort -u | wc -l)
  info "[Queue Analysis] Unique sender addresses in queue: $UNIQUE_SENDERS"
  if [[ $UNIQUE_SENDERS -gt 50 ]]; then
    fail "Many unique senders ($UNIQUE_SENDERS) — possible multiple compromised accounts or mass-mailer script"
    warn "Check script paths: grep 'cwd=' /var/log/exim_mainlog | grep -oP 'cwd=\S+' | sort | uniq -c | sort -rn | head -10"
  elif [[ $UNIQUE_SENDERS -gt 20 ]]; then
    warn "Elevated unique senders ($UNIQUE_SENDERS) in queue — investigate if unexpected"
  fi

  # Script path analysis
  echo ""
  info "[Queue Analysis] Top originating script paths (cwd in mainlog, last 1000 lines):"
  tail -1000 /var/log/exim_mainlog 2>/dev/null | \
    grep -oP 'cwd=\S+' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s calls  ->  %s\n", $1, $2}' | sed 's/cwd=//g'
  echo ""
  info "  If /home/<user>/public_html paths dominate, that account's web app"
  info "  is likely sending mail programmatically — investigate for compromise."

  # Recommended actions
  echo ""
  sep
  warn "Recommended Actions for Large Queue:"
  echo "    1. Identify the spam source from top senders above"
  echo "    2. Run MSP --auth for deep auth-based source analysis (see Section 2b)"
  echo "    3. Run SSE -s for a full outbound send summary (see Section 2b)"
  echo "    4. Suspend offending cPanel account : /scripts/suspendacct <user>"
  echo "    5. Purge frozen messages            : exim -bp | awk '/frozen/{print \$3}' | xargs exim -Mrm"
  echo "    6. Purge all bounces                : exim -bp | awk '/^ *[0-9].*<>/{print \$3}' | xargs exim -Mrm"
  echo "    7. After cleanup, flush queue       : exim -qff"
  echo "    8. Monitor live                     : tail -f /var/log/exim_mainlog"
  sep

elif [[ $QUEUE_SIZE -gt 0 ]]; then
  echo ""
  info "Queue sample (first 10 entries):"
  echo "$QUEUE_RAW" | head -30 | sed 's/^/    /'
fi

# =============================================================================
# SECTION 2b — cPANEL MSP / SSE SPAM SOURCE SCANNER
# =============================================================================
hdr "2b. cPanel MSP / SSE — Spam Source Scanner"
sep

echo ""
info "MSP (Mail Status Probe) and SSE are official cPanel tools for identifying"
info "spam sources, checking Exim config, RBL status, and auth-based abuse."
echo ""
info "  MSP repo : https://github.com/CpanelInc/tech-MSP"
info "  SSE cmd  : perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) -s"
echo ""

# Check prerequisites: perl and curl
PERL_OK=false; CURL_OK=false
command -v perl &>/dev/null && PERL_OK=true
command -v curl &>/dev/null && CURL_OK=true

if ! $PERL_OK; then
  fail "perl not found — cannot run MSP/SSE tools"
  warn "Install: yum install perl -y"
elif ! $CURL_OK; then
  fail "curl not found — cannot fetch MSP/SSE scripts"
  warn "Install: yum install curl -y"
else
  pass "perl and curl available"

  # Prefer cPanel's bundled Perl for best compatibility
  if [[ -x /usr/local/cpanel/3rdparty/bin/perl ]]; then
    CPANEL_PERL=/usr/local/cpanel/3rdparty/bin/perl
    info "Using cPanel bundled Perl: $CPANEL_PERL"
  else
    CPANEL_PERL=perl
    info "Using system Perl: $(command -v perl)"
  fi

  # ── MSP — Mail Status Probe (modern, maintained) ────────────────────────
  echo ""
  info "── Running MSP (msp.pl) — Mail Status Probe ──"
  sep

  MSP_URL="https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl"
  MSP_TMP=$(mktemp /tmp/msp_XXXXXX.pl)

  info "Fetching msp.pl from GitHub..."
  if curl -s --max-time 30 "$MSP_URL" -o "$MSP_TMP" 2>/dev/null && \
     [[ -s "$MSP_TMP" ]]; then
    pass "msp.pl downloaded successfully ($(wc -l < "$MSP_TMP") lines)"

    # Run: --auth  → aggregates password auth, local SMTP, sendmail — primary spam source check
    echo ""
    info "[MSP] Running --auth (authentication-based spam source check)..."
    info "      This scans Exim logs for auth abuse — may take 30-60s on busy servers"
    echo ""
    $CPANEL_PERL "$MSP_TMP" --auth 2>/dev/null | sed 's/^/    /' || \
      warn "MSP --auth returned no output or encountered an error"

    # Run: --conf  → checks Exim/Dovecot/WHM config for concerning settings
    echo ""
    sep
    info "[MSP] Running --conf (Exim/Dovecot/WHM configuration audit)..."
    echo ""
    $CPANEL_PERL "$MSP_TMP" --conf 2>/dev/null | sed 's/^/    /' || \
      warn "MSP --conf returned no output or encountered an error"

    # Run: --rbl all  → checks all server IPs against known RBLs
    echo ""
    sep
    info "[MSP] Running --rbl all (RBL/blacklist check for all server IPs)..."
    echo ""
    $CPANEL_PERL "$MSP_TMP" --rbl all 2>/dev/null | sed 's/^/    /' || \
      warn "MSP --rbl returned no output or encountered an error"

    rm -f "$MSP_TMP"
    pass "MSP scan complete"
  else
    fail "Failed to download msp.pl — check internet connectivity or GitHub access"
    rm -f "$MSP_TMP"
  fi

  # ── SSE — Legacy tool (still useful for quick summary and -b blacklist check) ──
  echo ""
  sep
  info "── Running SSE (sse.pl) — Legacy Quick Summary ──"
  sep

  SSE_URL="https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl"
  SSE_TMP=$(mktemp /tmp/sse_XXXXXX.pl)

  info "Fetching sse.pl from GitHub..."
  if curl -s --max-time 30 "$SSE_URL" -o "$SSE_TMP" 2>/dev/null && \
     [[ -s "$SSE_TMP" ]]; then
    pass "sse.pl downloaded successfully"

    # -s : summary of email sent from server (top senders, volume, subjects)
    echo ""
    info "[SSE] Running -s (outbound email send summary)..."
    echo ""
    perl "$SSE_TMP" -s 2>/dev/null | sed 's/^/    /' || \
      warn "SSE -s returned no output or encountered an error"

    # -b : blacklist check for main IP and IPs in /etc/ips
    echo ""
    sep
    info "[SSE] Running -b (IP blacklist check)..."
    echo ""
    perl "$SSE_TMP" -b 2>/dev/null | sed 's/^/    /' || \
      warn "SSE -b returned no output or encountered an error"

    rm -f "$SSE_TMP"
    pass "SSE scan complete"
  else
    fail "Failed to download sse.pl — check internet connectivity or GitHub access"
    rm -f "$SSE_TMP"
  fi

  # ── Manual reference commands ─────────────────────────────────────────────
  echo ""
  sep
  info "Reference: Run MSP/SSE manually anytime with these commands:"
  echo ""
  echo "  # MSP — full spam source auth audit:"
  echo "  $CPANEL_PERL <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --auth"
  echo ""
  echo "  # MSP — with rotated logs (deeper historical scan):"
  echo "  $CPANEL_PERL <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --auth --rotated"
  echo ""
  echo "  # MSP — config audit:"
  echo "  $CPANEL_PERL <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --conf"
  echo ""
  echo "  # MSP — RBL check all IPs:"
  echo "  $CPANEL_PERL <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --rbl all"
  echo ""
  echo "  # SSE — quick outbound send summary:"
  echo "  perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) -s"
  echo ""
  echo "  # SSE — domain-specific check:"
  echo "  perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) --domain example.com"
  echo ""
  echo "  # SSE — specific email check:"
  echo "  perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) --email user@example.com"
  sep
fi

# =============================================================================
# SECTION 3 — LOG ANALYSIS
# =============================================================================
hdr "3. Exim Log Analysis (last 500 lines)"
sep

MAINLOG="/var/log/exim_mainlog"
REJECTLOG="/var/log/exim_rejectlog"
PANICLOG="/var/log/exim_paniclog"

if [[ -f "$MAINLOG" ]]; then
  pass "Exim mainlog found: $MAINLOG"
  LOG_LINES=$(wc -l < "$MAINLOG")
  info "Total log lines: $LOG_LINES"

  echo ""
  info "Recent REJECTED connections:"
  grep -i "rejected\|REJECT\|blocked" "$MAINLOG" 2>/dev/null | tail -10 | \
    sed 's/^/    /'

  echo ""
  info "Recent DELIVERY FAILURES / deferrals:"
  grep -i "failed\|defer\|DEFER\|unrout\|no route" "$MAINLOG" 2>/dev/null | \
    tail -10 | sed 's/^/    /'

  echo ""
  info "Recent COMPLETED deliveries (last 5):"
  grep "Completed" "$MAINLOG" 2>/dev/null | tail -5 | sed 's/^/    /'

  echo ""
  info "Top senders (last 500 lines of mainlog):"
  tail -500 "$MAINLOG" 2>/dev/null | \
    grep -oP '(?<=from <)[^>]+' | sort | uniq -c | sort -rn | head -10 | \
    sed 's/^/    /'

  echo ""
  info "Top recipient domains (last 500 lines of mainlog):"
  tail -500 "$MAINLOG" 2>/dev/null | \
    grep -oP '(?<=to <)[^>]+' | grep -oP '@.+' | sort | uniq -c | sort -rn | \
    head -10 | sed 's/^/    /'
else
  fail "Exim mainlog not found at $MAINLOG"
fi

echo ""
if [[ -f "$REJECTLOG" ]]; then
  REJECT_COUNT=$(wc -l < "$REJECTLOG")
  info "Reject log lines: $REJECT_COUNT"
  if [[ $REJECT_COUNT -gt 0 ]]; then
    warn "Recent rejections:"
    tail -10 "$REJECTLOG" | sed 's/^/    /'
  fi
else
  info "No reject log at $REJECTLOG (may be normal)"
fi

echo ""
if [[ -f "$PANICLOG" ]]; then
  PANIC_COUNT=$(wc -l < "$PANICLOG")
  if [[ $PANIC_COUNT -gt 0 ]]; then
    fail "Panic log has $PANIC_COUNT entries — Exim may have critical errors!"
    tail -10 "$PANICLOG" | sed 's/^/    /'
  else
    pass "Panic log is empty (good)"
  fi
fi


# =============================================================================
# SECTION 4 — DNS & MX RECORD CHECKS (Per-Domain, Interactive)
# =============================================================================
hdr "4. DNS & MX Record Checks"
sep

# Check DNS tools
DNS_TOOL=""
for tool in dig host nslookup; do
  command -v $tool &>/dev/null && DNS_TOOL=$tool && break
done

if [[ -z "$DNS_TOOL" ]]; then
  warn "No DNS lookup tool found (dig/host/nslookup). Install: yum install bind-utils -y"
else
  info "Using DNS tool: $DNS_TOOL"

  # ── Build domain list from cPanel userdomains ──────────────────────────────
  USERDOMAINS_FILE="/etc/userdomains"
  declare -a DOMAIN_LIST=()

  if [[ -f "$USERDOMAINS_FILE" ]]; then
    # Extract unique domains (col 1), exclude *.example.com wildcards and duplicates
    while IFS=': ' read -r dom user; do
      [[ -z "$dom" || "$dom" == \#* || "$dom" == \*.* ]] && continue
      DOMAIN_LIST+=("$dom")
    done < "$USERDOMAINS_FILE"
    info "Found ${#DOMAIN_LIST[@]} domain(s) in $USERDOMAINS_FILE"
  else
    warn "/etc/userdomains not found — will prompt for manual domain entry"
  fi

  # ── Domain selection menu ──────────────────────────────────────────────────
  echo ""
  CHECK_DOMAIN=""

  if [[ ${#DOMAIN_LIST[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Domains hosted on this server:${RESET}"
    echo ""

    # Print numbered list (cap display at 50 to avoid flooding terminal)
    MAX_DISPLAY=50
    DISPLAY_COUNT=${#DOMAIN_LIST[@]}
    [[ $DISPLAY_COUNT -gt $MAX_DISPLAY ]] && DISPLAY_COUNT=$MAX_DISPLAY

    for i in $(seq 0 $((DISPLAY_COUNT - 1))); do
      printf "    %3d) %s\n" $((i + 1)) "${DOMAIN_LIST[$i]}"
    done

    if [[ ${#DOMAIN_LIST[@]} -gt $MAX_DISPLAY ]]; then
      echo ""
      warn "Showing first $MAX_DISPLAY of ${#DOMAIN_LIST[@]} domains."
      echo "  Enter 0 to type a domain manually."
    fi

    echo ""
    read -r -p "  Select a domain number to check (or 0 to enter manually, Enter to skip): " DOMAIN_CHOICE

    if [[ -z "$DOMAIN_CHOICE" ]]; then
      info "Skipping DNS/MX check."
    elif [[ "$DOMAIN_CHOICE" == "0" ]]; then
      read -r -p "  Enter domain name: " CHECK_DOMAIN
    elif [[ "$DOMAIN_CHOICE" =~ ^[0-9]+$ ]] && \
         [[ "$DOMAIN_CHOICE" -ge 1 && "$DOMAIN_CHOICE" -le ${#DOMAIN_LIST[@]} ]]; then
      CHECK_DOMAIN="${DOMAIN_LIST[$((DOMAIN_CHOICE - 1))]}"
    else
      warn "Invalid selection — enter a domain manually instead."
      read -r -p "  Enter domain name: " CHECK_DOMAIN
    fi
  else
    read -r -p "  Enter domain name to check (or press Enter to skip): " CHECK_DOMAIN
  fi

  # ── Run DNS checks against the chosen domain ───────────────────────────────
  if [[ -n "$CHECK_DOMAIN" ]]; then
    echo ""
    info "Running DNS/MX checks for: ${BOLD}$CHECK_DOMAIN${RESET}"
    sep

    # ── MX Records ──────────────────────────────────────────────────────────
    echo ""
    info "MX records:"
    MX_RESULT=$(dig +short MX "$CHECK_DOMAIN" 2>/dev/null)
    if [[ -n "$MX_RESULT" ]]; then
      pass "MX record(s) found:"
      echo "$MX_RESULT" | sort -n | awk '{printf "    Priority %-5s  Host: %s\n", $1, $2}'

      # Check if MX points to this server
      MX_HOST=$(echo "$MX_RESULT" | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//')
      MX_IP=$(dig +short A "$MX_HOST" 2>/dev/null | head -1)
      info "Primary MX host: $MX_HOST → $MX_IP"
      if [[ "$MX_IP" == "$SERVER_IP" ]]; then
        pass "Primary MX resolves to this server ($SERVER_IP)"
      elif [[ -n "$MX_IP" ]]; then
        warn "Primary MX resolves to $MX_IP — not this server ($SERVER_IP)"
        warn "Mail for $CHECK_DOMAIN may be delivered to a remote host"
      else
        warn "Primary MX host '$MX_HOST' does not resolve to any IP"
      fi
    else
      fail "No MX records found for $CHECK_DOMAIN"
      warn "Fix: Add an MX record pointing to your mail server hostname"
    fi

    # ── A Record ────────────────────────────────────────────────────────────
    echo ""
    info "A record for $CHECK_DOMAIN:"
    A_RESULT=$(dig +short A "$CHECK_DOMAIN" 2>/dev/null | head -1)
    if [[ -n "$A_RESULT" ]]; then
      info "  $CHECK_DOMAIN → $A_RESULT"
      if [[ "$A_RESULT" == "$SERVER_IP" ]]; then
        pass "A record points to this server"
      else
        warn "A record points to $A_RESULT — not this server ($SERVER_IP)"
      fi
    else
      warn "No A record found for $CHECK_DOMAIN"
    fi

    # ── SPF Record ──────────────────────────────────────────────────────────
    echo ""
    info "SPF record:"
    SPF=$(dig +short TXT "$CHECK_DOMAIN" 2>/dev/null | grep -i 'v=spf1' | head -1 | tr -d '"')
    SPF_COUNT=$(dig +short TXT "$CHECK_DOMAIN" 2>/dev/null | grep -ci 'v=spf1')
    if [[ $SPF_COUNT -gt 1 ]]; then
      fail "Multiple SPF records found ($SPF_COUNT) — only one is allowed, others will be ignored"
    elif [[ -n "$SPF" ]]; then
      pass "SPF: $SPF"
      # Check server IP is covered
      if echo "$SPF" | grep -q "$SERVER_IP\|include:"; then
        pass "Server IP appears covered by SPF"
      else
        warn "Verify that $SERVER_IP is authorised in the SPF record"
      fi
    else
      fail "No SPF record found for $CHECK_DOMAIN"
      warn "Fix: Add TXT record — e.g. v=spf1 ip4:$SERVER_IP ~all"
    fi

    # ── DKIM Record ─────────────────────────────────────────────────────────
    echo ""
    info "DKIM check (cPanel default selector):"
    for SELECTOR in default mail dkim; do
      DKIM_LOOKUP="${SELECTOR}._domainkey.${CHECK_DOMAIN}"
      DKIM=$(dig +short TXT "$DKIM_LOOKUP" 2>/dev/null | head -1 | tr -d '"')
      if [[ -n "$DKIM" ]]; then
        pass "DKIM key found at $DKIM_LOOKUP"
        echo "    Key (truncated): ${DKIM:0:80}..."
        break
      fi
    done
    if [[ -z "$DKIM" ]]; then
      warn "No DKIM record found (tried selectors: default, mail, dkim)"
      warn "Enable via: WHM → Email → Email Authentication → Enable DKIM"
    fi

    # ── DMARC Record ────────────────────────────────────────────────────────
    echo ""
    info "DMARC record:"
    DMARC=$(dig +short TXT "_dmarc.$CHECK_DOMAIN" 2>/dev/null | head -1 | tr -d '"')
    if [[ -n "$DMARC" ]]; then
      pass "DMARC: $DMARC"
      DMARC_POLICY=$(echo "$DMARC" | grep -oP 'p=\w+' | head -1)
      info "Policy: ${DMARC_POLICY:-unknown}"
      if echo "$DMARC_POLICY" | grep -q "p=none"; then
        warn "DMARC policy is 'none' (monitor only) — consider p=quarantine or p=reject"
      fi
    else
      warn "No DMARC record found for $CHECK_DOMAIN"
      warn "Add: _dmarc.$CHECK_DOMAIN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@$CHECK_DOMAIN\""
    fi

    # ── Exim routing test ────────────────────────────────────────────────────
    echo ""
    info "Exim routing test for postmaster@$CHECK_DOMAIN:"
    exim -bt "postmaster@$CHECK_DOMAIN" 2>/dev/null | sed 's/^/    /' || \
      warn "Could not run Exim routing test"

    # ── cPanel domain routing mode ────────────────────────────────────────────
    echo ""
    info "cPanel mail routing mode for $CHECK_DOMAIN:"
    ROUTING_FILE="/etc/localdomains"
    REMOTE_FILE="/etc/remotedomains"
    if grep -qx "$CHECK_DOMAIN" "$ROUTING_FILE" 2>/dev/null; then
      pass "Domain is in /etc/localdomains — mail delivered locally"
    elif grep -qx "$CHECK_DOMAIN" "$REMOTE_FILE" 2>/dev/null; then
      warn "Domain is in /etc/remotedomains — mail routed remotely (not delivered to this server)"
    else
      warn "Domain not found in localdomains or remotedomains — check WHM → Email Routing"
    fi

    sep
    info "Check additional: https://mxtoolbox.com/SuperTool.aspx?action=mx:$CHECK_DOMAIN"
  fi
fi

# =============================================================================
# SECTION 5 — AUTHENTICATION RECORDS (cPanel)
# =============================================================================
hdr "5. cPanel Email Authentication Config"
sep

# Check WHM DKIM global setting
DKIM_CONF="/var/cpanel/cpanel.config"
if [[ -f "$DKIM_CONF" ]]; then
  DKIM_EN=$(grep -i "dkim" "$DKIM_CONF" 2>/dev/null | head -5)
  info "DKIM config snippet from cpanel.config:"
  echo "${DKIM_EN:-  (not found)}" | sed 's/^/    /'
fi

# Check Exim config for DKIM signing
EXIM_CONF="/etc/exim.conf"
if [[ -f "$EXIM_CONF" ]]; then
  if grep -qi "dkim" "$EXIM_CONF" 2>/dev/null; then
    pass "DKIM signing references found in Exim config"
  else
    warn "No DKIM references in Exim config — verify via WHM → Email Authentication"
  fi

  # Check TLS
  if grep -qi "tls_certificate\|tls_privatekey" "$EXIM_CONF" 2>/dev/null; then
    pass "TLS certificate configuration found in Exim config"
  else
    warn "No TLS certificate config in Exim — check WHM → Service SSL Certificates"
  fi
fi

# =============================================================================
# SECTION 6 — FIREWALL / PORT CONNECTIVITY
# =============================================================================
hdr "6. Firewall & Port Checks"
sep

# Check if firewall is active
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld is active"
  if firewall-cmd --list-ports 2>/dev/null | grep -q "25/tcp\|smtp"; then
    pass "Port 25 allowed in firewalld"
  else
    SMTP_SVCCHECK=$(firewall-cmd --list-services 2>/dev/null | grep -o "smtp")
    if [[ -n "$SMTP_SVCCHECK" ]]; then
      pass "SMTP service allowed in firewalld"
    else
      warn "Port 25/SMTP not explicitly in firewalld rules — verify manually"
    fi
  fi
fi

if systemctl is-active --quiet csf 2>/dev/null || \
   [[ -f /etc/csf/csf.conf ]]; then
  info "CSF (ConfigServer Firewall) detected"
  if grep -q "^TCP_IN.*25" /etc/csf/csf.conf 2>/dev/null; then
    pass "Port 25 found in CSF TCP_IN rules"
  else
    warn "Port 25 not explicitly in CSF TCP_IN — check /etc/csf/csf.conf"
  fi
fi

# Local SMTP test
echo ""
info "Testing local SMTP connection (port 25):"
SMTP_TEST=$(echo "QUIT" | timeout 5 nc -w 3 127.0.0.1 25 2>/dev/null | head -1)
if echo "$SMTP_TEST" | grep -q "220"; then
  pass "SMTP banner received: $SMTP_TEST"
else
  fail "No SMTP banner on localhost:25 — Exim may be down or blocked locally"
fi

# =============================================================================
# SECTION 7 — DISK & QUOTA CHECK
# =============================================================================
hdr "7. Disk Space & Mail Quotas"
sep

# Overall disk
echo ""
info "Disk usage (key partitions):"
df -h / /home /var /tmp 2>/dev/null | sed 's/^/    /'

# /var/spool — Exim queue spool
SPOOL_USE=$(du -sh /var/spool/exim 2>/dev/null | cut -f1)
info "Exim spool size: ${SPOOL_USE:-unknown}"

# Check for any full partitions
FULL_PARTS=$(df -h 2>/dev/null | awk '$5+0 >= 90 {print $6, $5}')
if [[ -n "$FULL_PARTS" ]]; then
  fail "High disk usage detected (>=90%):"
  echo "$FULL_PARTS" | sed 's/^/    /'
else
  pass "No partitions at critical disk usage"
fi

# =============================================================================
# SECTION 8 — COMMON ISSUE CHECKLIST
# =============================================================================
hdr "8. Common Issues Checklist"
sep

echo ""
echo "  Use the following as a guided checklist:"
echo ""

checklist() {
  local NUM="$1"; local DESC="$2"; local CMD="$3"
  printf "  ${BOLD}[%s]${RESET} %s\n" "$NUM" "$DESC"
  if [[ -n "$CMD" ]]; then
    printf "      ${CYAN}Cmd:${RESET} %s\n" "$CMD"
  fi
}

checklist "A" "Exim not starting after config change" \
  "exim -bV && exim -C /etc/exim.conf -bP | head -20"

checklist "B" "Mail received but not appearing in inbox" \
  "grep 'user@domain' /var/log/exim_mainlog | grep -i 'deliver\|stored'"

checklist "C" "Outbound rejected by remote server (check bounce)" \
  "grep 'rejected' /var/log/exim_mainlog | tail -20"

checklist "D" "IP blacklisted — emergency queue freeze" \
  "exim -qff  OR  exim -bp | awk '/^ *[0-9]+[smhdw]/{print \$3}' | xargs exim -Mrm"

checklist "E" "DKIM signing not working" \
  "WHM → Email → Email Authentication → Enable DKIM globally"

checklist "F" "Greylisting delaying inbound mail" \
  "WHM → Email → Greylisting → Review or disable"

checklist "G" "Spam filter catching legitimate email" \
  "WHM → Email → Apache SpamAssassin → Adjust score or whitelist"

checklist "H" "Mail loop / relay misconfiguration" \
  "grep 'loop\|route' /var/log/exim_mainlog | tail -20"

checklist "I" "Force re-attempt all deferred messages" \
  "exim -qff"

checklist "J" "Remove a single stuck message from queue" \
  "exim -Mrm <message-id>"

checklist "K" "Inspect a specific queued message" \
  "exim -Mvh <message-id>  &&  exim -Mvb <message-id>"

checklist "L" "Check cPanel mail routing for a domain" \
  "cat /etc/userdomains | grep domain.com  &&  exim -bt user@domain.com"

echo ""

# =============================================================================
# SECTION 9 — USEFUL REFERENCE LINKS
# =============================================================================
hdr "9. Reference Links"
sep

echo ""
echo "  ── cPanel / Exim Documentation ──────────────────────────────"
echo "  cPanel Email Deliverability  : https://docs.cpanel.net/cpanel/email/email-deliverability-in-cpanel/"
echo "  WHM Mail Troubleshooter      : https://docs.cpanel.net/whm/email/mail-troubleshooter/"
echo "  Exim Reference (cPanel)      : https://support.cpanel.net/hc/en-us/community/posts/19631729696279"
echo "  Can't Receive Emails         : https://support.cpanel.net/hc/en-us/articles/4402368750871"
echo ""
echo "  -- cPanel Spam Source Tools -----------------------------------------"
echo "  MSP (Mail Status Probe) repo : https://github.com/CpanelInc/tech-MSP"
echo "  MSP --auth (spam sources)    : /usr/local/cpanel/3rdparty/bin/perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --auth"
echo "  MSP --auth --rotated         : (add --rotated to scan historical/rotated logs)"
echo "  MSP --conf (config audit)    : /usr/local/cpanel/3rdparty/bin/perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --conf"
echo "  MSP --rbl all (RBL check)    : /usr/local/cpanel/3rdparty/bin/perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/msp.pl) --rbl all"
echo "  SSE -s (send summary)        : perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) -s"
echo "  SSE -b (blacklist check)     : perl <(curl -s https://raw.githubusercontent.com/CpanelInc/tech-SSE/master/sse.pl) -b"
echo ""
echo "  ── IP / Domain Reputation ───────────────────────────────────"
echo "  Talos Intelligence           : https://www.talosintelligence.com/"
echo ""
echo "  ── Blacklist / RBL Checkers ─────────────────────────────────"
echo "  MXToolbox Blacklists         : https://mxtoolbox.com/blacklists.aspx"
if [[ -n "$SERVER_IP" ]]; then
  echo "  MultiRBL (your IP)           : https://multirbl.valli.org/lookup/${SERVER_IP}.html"
fi
echo "  MultiRBL (manual)            : https://multirbl.valli.org/"
echo "  Trend Micro ERS              : https://servicecentral.trendmicro.com/en-us/ers/ip-lookup/"
echo "  Blacklist Master             : https://www.blacklistmaster.com/checker"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
hdr "Summary"
sep
echo ""
echo "  ✔  Troubleshoot run completed"
echo "  ✔  Full output saved to: $LOGFILE"
echo ""
echo "  Next steps if issues found:"
echo "    1. Address any [FAIL] items above first"
echo "    2. Review [WARN] items — many affect deliverability"
echo "    3. Use Section 8 trace (coming soon) to investigate specific addresses"
echo "    4. Check blacklist URLs in Section 9 for IP reputation"
echo "    5. Run: tail -f /var/log/exim_mainlog  for live monitoring"
echo ""
echo -e "${BOLD}${GREEN}  Done.${RESET}"
echo ""
