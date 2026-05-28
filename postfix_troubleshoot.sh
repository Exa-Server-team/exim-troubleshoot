#!/usr/bin/env bash
# =============================================================================
# postfix_troubleshoot.sh — Postfix Mail Troubleshooter for Plesk Servers
# =============================================================================
# Usage:
#   chmod +x postfix_troubleshoot.sh
#   sudo bash postfix_troubleshoot.sh
#
#   Or directly from GitHub:
#   curl -s https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/postfix_troubleshoot.sh \
#     -o /tmp/postfix_troubleshoot.sh && sudo bash /tmp/postfix_troubleshoot.sh
#
# Requirements: Must run as root on a Plesk server (Debian/Ubuntu or RHEL/AlmaLinux)
# =============================================================================

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
sep()   { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}ERROR:${RESET} This script must be run as root. Try: sudo $0"
  exit 1
fi

# ── Log output ────────────────────────────────────────────────────────────────
LOGFILE="/var/log/postfix_troubleshoot_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      Postfix Mail Troubleshooter — Plesk Server          ║"
echo "║      $(date '+%Y-%m-%d %H:%M:%S')                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  Full log saved to: $LOGFILE"

# ── Detect OS and mail log path ───────────────────────────────────────────────
if [[ -f /etc/debian_version ]]; then
  OS_FAMILY="debian"
  MAIL_LOG="/var/log/mail.log"
  PKG_MGR="apt"
else
  OS_FAMILY="rhel"
  MAIL_LOG="/var/log/maillog"
  PKG_MGR="yum"
fi
info "OS family  : $OS_FAMILY"
info "Mail log   : $MAIL_LOG"

# =============================================================================
# SECTION 1 — SERVER & PLESK BASICS
# =============================================================================
hdr "1. Server & Plesk Service"
sep

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || \
            ip route get 1 | awk '{print $7; exit}')

info "Hostname  : $HOSTNAME"
info "Public IP : ${SERVER_IP:-unknown}"

# Plesk version
if command -v plesk &>/dev/null; then
  PLESK_VER=$(plesk version 2>/dev/null | head -1)
  pass "Plesk detected: $PLESK_VER"
else
  warn "Plesk CLI not found — is this a Plesk server?"
fi

# ── Hostname Resolution & PTR Validation ─────────────────────────────────────
echo ""
info "── Hostname Resolution & PTR Validation ──"

HOSTNAME_RESOLVED_IP=$(dig +short "$HOSTNAME" A 2>/dev/null | \
  grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)

if [[ -z "$HOSTNAME_RESOLVED_IP" ]]; then
  fail "Hostname '$HOSTNAME' does NOT resolve to any IP (A record missing)"
  warn "Fix: Add an A record for $HOSTNAME pointing to $SERVER_IP"
else
  info "Hostname A record resolves to: $HOSTNAME_RESOLVED_IP"
  if [[ "$HOSTNAME_RESOLVED_IP" == "$SERVER_IP" ]]; then
    pass "Hostname resolves correctly to this server's IP ($SERVER_IP)"
  else
    fail "Hostname resolves to $HOSTNAME_RESOLVED_IP but server public IP is $SERVER_IP"
    warn "Mismatch may cause SMTP rejections — update A record or check IP binding"
  fi
fi

# PTR / rDNS
if [[ -n "$SERVER_IP" ]]; then
  PTR_RECORD=$(dig +short -x "$SERVER_IP" 2>/dev/null | sed 's/\.$//')
  if [[ -z "$PTR_RECORD" ]]; then
    fail "No PTR (rDNS) record found for $SERVER_IP"
    warn "Many mail servers reject email from IPs without PTR records"
    warn "Fix: Contact your datacenter/ISP to set PTR → $HOSTNAME"
  else
    info "PTR record for $SERVER_IP : $PTR_RECORD"
    if [[ "$PTR_RECORD" == "$HOSTNAME" ]]; then
      pass "PTR matches hostname exactly — FCrDNS OK"
    else
      HOSTNAME_DOMAIN=$(echo "$HOSTNAME" | cut -d. -f2-)
      if echo "$PTR_RECORD" | grep -q "$HOSTNAME_DOMAIN"; then
        warn "PTR '$PTR_RECORD' partially matches hostname domain — ideally should match FQDN exactly"
      else
        fail "PTR '$PTR_RECORD' does NOT match hostname '$HOSTNAME'"
        warn "FCrDNS failure — strict receivers (Gmail, Outlook) may reject your mail"
        warn "Fix: Ask your DC to set PTR for $SERVER_IP → $HOSTNAME"
      fi
    fi

    # Forward-confirm the PTR
    PTR_FORWARD_IP=$(dig +short "$PTR_RECORD" A 2>/dev/null | \
      grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ "$PTR_FORWARD_IP" == "$SERVER_IP" ]]; then
      pass "FCrDNS confirmed: $PTR_RECORD → $PTR_FORWARD_IP ✔"
    elif [[ -z "$PTR_FORWARD_IP" ]]; then
      warn "PTR hostname '$PTR_RECORD' does not resolve forward — broken FCrDNS"
    else
      warn "PTR hostname resolves to $PTR_FORWARD_IP (expected $SERVER_IP)"
    fi
  fi
fi

# Postfix myhostname vs system hostname
POSTFIX_HOSTNAME=$(postconf -h myhostname 2>/dev/null)
if [[ -n "$POSTFIX_HOSTNAME" ]]; then
  info "Postfix myhostname: $POSTFIX_HOSTNAME"
  if [[ "$POSTFIX_HOSTNAME" == "$HOSTNAME" ]]; then
    pass "Postfix myhostname matches system hostname"
  else
    warn "Postfix myhostname '$POSTFIX_HOSTNAME' differs from system hostname '$HOSTNAME'"
    warn "Fix: Edit /etc/postfix/main.cf → myhostname = $HOSTNAME"
  fi
fi

# ── Postfix Service ───────────────────────────────────────────────────────────
echo ""
info "── Postfix Service ──"

if systemctl is-active --quiet postfix 2>/dev/null; then
  pass "Postfix service is running"
else
  fail "Postfix service is NOT running"
  info "Attempting to start Postfix..."
  systemctl start postfix 2>/dev/null
  sleep 2
  if systemctl is-active --quiet postfix 2>/dev/null; then
    pass "Postfix started successfully"
  else
    fail "Could not start Postfix — check: journalctl -xe | grep postfix"
  fi
fi

# Postfix version
POSTFIX_VER=$(postconf -d mail_version 2>/dev/null | awk '{print $NF}')
info "Postfix version: ${POSTFIX_VER:-unknown}"

# Port checks
echo ""
info "Listening ports:"
for PORT in 25 587 465; do
  if ss -tlnp 2>/dev/null | grep -q ":$PORT " || \
     netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
    pass "Port $PORT is open"
  else
    if [[ $PORT -eq 25 ]]; then
      fail "Port 25 not listening — Postfix may not be receiving mail"
    else
      warn "Port $PORT not listening (optional but recommended)"
    fi
  fi
done

# Dovecot
echo ""
info "── Dovecot (IMAP/POP3) ──"
if systemctl is-active --quiet dovecot 2>/dev/null; then
  DOVECOT_VER=$(dovecot --version 2>/dev/null | head -1)
  pass "Dovecot is running: $DOVECOT_VER"
else
  warn "Dovecot is not running — IMAP/POP3 may be unavailable"
  warn "Start: systemctl start dovecot"
fi

# =============================================================================
# SECTION 2 — POSTFIX MAIL QUEUE
# =============================================================================
hdr "2. Postfix Mail Queue Status & Spam Analysis"
sep

QUEUE_RAW=$(postqueue -p 2>/dev/null)
# Count actual queued messages (lines starting with a queue ID: hex chars + letter)
QUEUE_SIZE=$(echo "$QUEUE_RAW" | grep -cE '^[0-9A-F]{8,}[*!]?' || echo 0)

info "Messages in queue: $QUEUE_SIZE"
echo ""

if [[ $QUEUE_SIZE -eq 0 ]]; then
  pass "Mail queue is empty"
elif [[ $QUEUE_SIZE -le 50 ]]; then
  pass "Queue size is normal ($QUEUE_SIZE messages)"
elif [[ $QUEUE_SIZE -le 200 ]]; then
  warn "Queue is moderate ($QUEUE_SIZE messages) — monitor for growth"
elif [[ $QUEUE_SIZE -le 500 ]]; then
  fail "Queue exceeds 200 ($QUEUE_SIZE messages) — deep analysis triggered below"
else
  fail "Queue is critically large ($QUEUE_SIZE messages) — likely spam backlog or loop!"
fi

# Queue age breakdown
if [[ $QUEUE_SIZE -gt 0 ]]; then
  echo ""
  info "Queue sample (first 20 entries):"
  echo "$QUEUE_RAW" | head -40 | sed 's/^/    /'

  echo ""
  info "Queue directories and sizes:"
  for QDIR in incoming active deferred bounce hold corrupt; do
    QPATH="/var/spool/postfix/$QDIR"
    if [[ -d "$QPATH" ]]; then
      COUNT=$(find "$QPATH" -type f 2>/dev/null | wc -l)
      SIZE=$(du -sh "$QPATH" 2>/dev/null | cut -f1)
      if [[ $COUNT -gt 0 ]]; then
        info "  $QDIR: $COUNT message(s) — $SIZE"
      else
        pass "  $QDIR: empty"
      fi
    fi
  done
fi

# Deep analysis when queue > 200
if [[ $QUEUE_SIZE -gt 200 ]]; then
  echo ""
  warn "Queue exceeds 200 — running bulk/spam analysis..."
  sep

  # Top senders
  echo ""
  info "[Queue Analysis] Top sender addresses:"
  postqueue -p 2>/dev/null | grep -oP '(?<=\()\S+@\S+(?=\))' | \
    sort | uniq -c | sort -rn | head -15 | \
    awk '{printf "    %6s messages  ->  %s\n", $1, $2}'

  # Top sender domains
  echo ""
  info "[Queue Analysis] Top sender domains:"
  postqueue -p 2>/dev/null | grep -oP '(?<=\()\S+@\S+(?=\))' | \
    grep -oP '@.+' | tr -d '@' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s messages  <- domain: %s\n", $1, $2}'

  # Deferred messages breakdown
  echo ""
  DEFERRED_COUNT=$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)
  info "[Queue Analysis] Deferred messages: $DEFERRED_COUNT"
  if [[ $DEFERRED_COUNT -gt 100 ]]; then
    fail "High deferred count ($DEFERRED_COUNT) — likely remote delivery failures or relay issues"
    warn "Check: postqueue -p | grep -A3 'deferred'"
  fi

  # Hold queue
  HOLD_COUNT=$(find /var/spool/postfix/hold -type f 2>/dev/null | wc -l)
  info "[Queue Analysis] Messages on hold: $HOLD_COUNT"
  [[ $HOLD_COUNT -gt 0 ]] && warn "$HOLD_COUNT messages manually held — review and release or delete"

  # Bounce queue
  BOUNCE_COUNT=$(find /var/spool/postfix/bounce -type f 2>/dev/null | wc -l)
  info "[Queue Analysis] Bounce notices: $BOUNCE_COUNT"
  if [[ $BOUNCE_COUNT -gt 50 ]]; then
    fail "High bounce count ($BOUNCE_COUNT) — possible backscatter or spam bounce storm"
  fi

  # Script/web injection via PHP mail()
  echo ""
  info "[Queue Analysis] Top originating script paths (from mail log, last 1000 lines):"
  tail -1000 "$MAIL_LOG" 2>/dev/null | \
    grep -oP '(?<=from=<)[^>]+' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s messages  ->  %s\n", $1, $2}'

  echo ""
  info "[Queue Analysis] PHP mail() injection check (uid in mail log):"
  tail -1000 "$MAIL_LOG" 2>/dev/null | \
    grep -oP 'uid=\d+' | sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "    %6s messages  from  %s\n", $1, $2}'

  # Recommended actions
  echo ""
  sep
  warn "Recommended Actions for Large Queue:"
  echo "    1. Identify spam source from top senders above"
  echo "    2. Suspend offending Plesk subscription    : plesk bin subscription --disable domain.com"
  echo "    3. Flush deferred (retry delivery)         : postqueue -f"
  echo "    4. Delete ALL deferred (use with caution)  : postsuper -d ALL deferred"
  echo "    5. Delete ALL queued (use with caution)    : postsuper -d ALL"
  echo "    6. Move suspicious to hold queue           : postsuper -h ALL deferred"
  echo "    7. Monitor live                            : tail -f $MAIL_LOG"
  sep
fi

# =============================================================================
# SECTION 3 — POSTFIX LOG ANALYSIS
# =============================================================================
hdr "3. Postfix Log Analysis (last 500 lines)"
sep

if [[ -f "$MAIL_LOG" ]]; then
  pass "Mail log found: $MAIL_LOG"
  LOG_LINES=$(wc -l < "$MAIL_LOG")
  info "Total log lines: $LOG_LINES"

  # Check for archived logs
  GZ_COUNT=$(ls ${MAIL_LOG}*.gz 2>/dev/null | wc -l)
  [[ $GZ_COUNT -gt 0 ]] && info "Archive files found: $GZ_COUNT (.gz)"

  echo ""
  info "Recent REJECTED connections:"
  grep -i "reject\|blocked\|denied" "$MAIL_LOG" 2>/dev/null | tail -10 | sed 's/^/    /'

  echo ""
  info "Recent DELIVERY FAILURES / deferrals:"
  grep -i "status=deferred\|status=bounced\|Connection refused\|Connection timed out\|No route" \
    "$MAIL_LOG" 2>/dev/null | tail -10 | sed 's/^/    /'

  echo ""
  info "Recent COMPLETED deliveries (last 5):"
  grep "status=sent" "$MAIL_LOG" 2>/dev/null | tail -5 | sed 's/^/    /'

  echo ""
  info "Top sender addresses (last 500 lines):"
  tail -500 "$MAIL_LOG" 2>/dev/null | \
    grep -oP '(?<=from=<)[^>]+' | grep -v '^$' | \
    sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'

  echo ""
  info "Top recipient domains (last 500 lines):"
  tail -500 "$MAIL_LOG" 2>/dev/null | \
    grep -oP '(?<=to=<)[^>]+' | grep -oP '@.+' | tr -d '@' | \
    sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'

  echo ""
  info "Recent authentication failures (SASL/login):"
  grep -i "SASL\|authentication\|auth.*fail\|LOGIN fail" \
    "$MAIL_LOG" 2>/dev/null | tail -10 | sed 's/^/    /'

  echo ""
  info "TLS errors:"
  grep -i "TLS.*error\|SSL.*error\|certificate.*error" \
    "$MAIL_LOG" 2>/dev/null | tail -5 | sed 's/^/    /'

else
  fail "Mail log not found at $MAIL_LOG"
  warn "Check alternate: /var/log/mail.log or /var/log/maillog"
fi

# Postfix warning/error log (if separate)
echo ""
if [[ -f /var/log/mail.err ]]; then
  ERR_COUNT=$(wc -l < /var/log/mail.err)
  if [[ $ERR_COUNT -gt 0 ]]; then
    fail "Mail error log has $ERR_COUNT entries:"
    tail -10 /var/log/mail.err | sed 's/^/    /'
  else
    pass "Mail error log is empty"
  fi
fi

# =============================================================================
# SECTION 4 — DNS & MX RECORD CHECKS (Per-Domain, Interactive)
# =============================================================================
hdr "4. DNS & MX Record Checks"
sep

DNS_TOOL=""
for tool in dig host nslookup; do
  command -v $tool &>/dev/null && DNS_TOOL=$tool && break
done

if [[ -z "$DNS_TOOL" ]]; then
  warn "No DNS lookup tool found. Install: $PKG_MGR install bind-utils -y"
else
  info "Using DNS tool: $DNS_TOOL"

  # Build domain list from Plesk
  declare -a DOMAIN_LIST=()

  if command -v plesk &>/dev/null; then
    while IFS= read -r dom; do
      [[ -z "$dom" ]] && continue
      DOMAIN_LIST+=("$dom")
    done < <(plesk bin subscription --list 2>/dev/null | \
              awk 'NR>1 && NF>0 {print $1}' | grep '\.')
    info "Found ${#DOMAIN_LIST[@]} subscription(s) in Plesk"
  fi

  # Fallback: read from /var/www/vhosts
  if [[ ${#DOMAIN_LIST[@]} -eq 0 && -d /var/www/vhosts ]]; then
    while IFS= read -r dom; do
      [[ "$dom" == "default" || "$dom" == "system" ]] && continue
      DOMAIN_LIST+=("$dom")
    done < <(ls /var/www/vhosts/ 2>/dev/null)
    info "Found ${#DOMAIN_LIST[@]} domain(s) from /var/www/vhosts"
  fi

  # Domain selection
  echo ""
  CHECK_DOMAIN=""

  if [[ ${#DOMAIN_LIST[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Domains hosted on this server:${RESET}"
    echo ""
    MAX_DISPLAY=50
    DISPLAY_COUNT=${#DOMAIN_LIST[@]}
    [[ $DISPLAY_COUNT -gt $MAX_DISPLAY ]] && DISPLAY_COUNT=$MAX_DISPLAY

    for i in $(seq 0 $((DISPLAY_COUNT - 1))); do
      printf "    %3d) %s\n" $((i + 1)) "${DOMAIN_LIST[$i]}"
    done

    [[ ${#DOMAIN_LIST[@]} -gt $MAX_DISPLAY ]] && \
      warn "Showing first $MAX_DISPLAY of ${#DOMAIN_LIST[@]} domains. Enter 0 to type manually."

    echo ""
    read -r -p "  Select domain number (or 0 to enter manually, Enter to skip): " DOMAIN_CHOICE

    if [[ -z "$DOMAIN_CHOICE" ]]; then
      info "Skipping DNS/MX check."
    elif [[ "$DOMAIN_CHOICE" == "0" ]]; then
      read -r -p "  Enter domain name: " CHECK_DOMAIN
    elif [[ "$DOMAIN_CHOICE" =~ ^[0-9]+$ ]] && \
         [[ "$DOMAIN_CHOICE" -ge 1 && "$DOMAIN_CHOICE" -le ${#DOMAIN_LIST[@]} ]]; then
      CHECK_DOMAIN="${DOMAIN_LIST[$((DOMAIN_CHOICE - 1))]}"
    else
      warn "Invalid selection."
      read -r -p "  Enter domain name manually: " CHECK_DOMAIN
    fi
  else
    read -r -p "  Enter domain name to check (or Enter to skip): " CHECK_DOMAIN
  fi

  if [[ -n "$CHECK_DOMAIN" ]]; then
    echo ""
    info "Running DNS/MX checks for: ${BOLD}$CHECK_DOMAIN${RESET}"
    sep

    # MX Records
    echo ""
    info "MX records:"
    MX_RESULT=$(dig +short MX "$CHECK_DOMAIN" 2>/dev/null)
    if [[ -n "$MX_RESULT" ]]; then
      pass "MX record(s) found:"
      echo "$MX_RESULT" | sort -n | awk '{printf "    Priority %-5s  Host: %s\n", $1, $2}'
      MX_HOST=$(echo "$MX_RESULT" | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//')
      MX_IP=$(dig +short A "$MX_HOST" 2>/dev/null | head -1)
      info "Primary MX host: $MX_HOST → $MX_IP"
      if [[ "$MX_IP" == "$SERVER_IP" ]]; then
        pass "Primary MX resolves to this server ($SERVER_IP)"
      elif [[ -n "$MX_IP" ]]; then
        warn "Primary MX resolves to $MX_IP — not this server ($SERVER_IP)"
      else
        warn "Primary MX host '$MX_HOST' does not resolve"
      fi
    else
      fail "No MX records found for $CHECK_DOMAIN"
    fi

    # A Record
    echo ""
    info "A record for $CHECK_DOMAIN:"
    A_RESULT=$(dig +short A "$CHECK_DOMAIN" 2>/dev/null | head -1)
    if [[ -n "$A_RESULT" ]]; then
      info "  $CHECK_DOMAIN → $A_RESULT"
      [[ "$A_RESULT" == "$SERVER_IP" ]] && pass "A record points to this server" || \
        warn "A record points to $A_RESULT — not this server ($SERVER_IP)"
    else
      warn "No A record found for $CHECK_DOMAIN"
    fi

    # SPF
    echo ""
    info "SPF record:"
    SPF=$(dig +short TXT "$CHECK_DOMAIN" 2>/dev/null | grep -i 'v=spf1' | head -1 | tr -d '"')
    SPF_COUNT=$(dig +short TXT "$CHECK_DOMAIN" 2>/dev/null | grep -ci 'v=spf1')
    if [[ $SPF_COUNT -gt 1 ]]; then
      fail "Multiple SPF records found ($SPF_COUNT) — only one is allowed"
    elif [[ -n "$SPF" ]]; then
      pass "SPF: $SPF"
      echo "$SPF" | grep -q "$SERVER_IP\|include:" && \
        pass "Server IP appears covered by SPF" || \
        warn "Verify that $SERVER_IP is authorised in the SPF record"
    else
      fail "No SPF record for $CHECK_DOMAIN"
      warn "Add TXT: v=spf1 ip4:$SERVER_IP ~all"
    fi

    # DKIM — Plesk uses selector 'default' by default; also try 'mail'
    echo ""
    info "DKIM check:"
    DKIM_FOUND=false
    for SELECTOR in default mail dkim; do
      DKIM_LOOKUP="${SELECTOR}._domainkey.${CHECK_DOMAIN}"
      DKIM=$(dig +short TXT "$DKIM_LOOKUP" 2>/dev/null | head -1 | tr -d '"')
      if [[ -n "$DKIM" ]]; then
        pass "DKIM key found at $DKIM_LOOKUP"
        echo "    Key (truncated): ${DKIM:0:80}..."
        # Validate with opendkim if available
        if command -v opendkim-testkey &>/dev/null; then
          DKIM_TEST=$(opendkim-testkey -d "$CHECK_DOMAIN" -s "$SELECTOR" 2>&1)
          if echo "$DKIM_TEST" | grep -qi "key OK\|key not secure"; then
            pass "opendkim-testkey: key validates OK"
          else
            warn "opendkim-testkey output: $DKIM_TEST"
          fi
        fi
        DKIM_FOUND=true
        break
      fi
    done
    if ! $DKIM_FOUND; then
      warn "No DKIM record found (tried: default, mail, dkim)"
      warn "Enable via: Plesk → Websites & Domains → $CHECK_DOMAIN → Mail Settings → DKIM"
      warn "Or CLI: plesk bin domain --update $CHECK_DOMAIN -dkim_enabled true"
    fi

    # DMARC
    echo ""
    info "DMARC record:"
    DMARC=$(dig +short TXT "_dmarc.$CHECK_DOMAIN" 2>/dev/null | head -1 | tr -d '"')
    if [[ -n "$DMARC" ]]; then
      pass "DMARC: $DMARC"
      DMARC_POLICY=$(echo "$DMARC" | grep -oP 'p=\w+' | head -1)
      info "Policy: ${DMARC_POLICY:-unknown}"
      echo "$DMARC_POLICY" | grep -q "p=none" && \
        warn "DMARC policy is 'none' (monitor only) — consider p=quarantine or p=reject"
    else
      warn "No DMARC record for $CHECK_DOMAIN"
      warn "Add: _dmarc.$CHECK_DOMAIN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@$CHECK_DOMAIN\""
    fi

    # Plesk mail routing check
    echo ""
    info "Plesk mail routing for $CHECK_DOMAIN:"
    PLESK_MAIL_STATUS=$(plesk bin mail --list "$CHECK_DOMAIN" 2>/dev/null | head -5)
    if [[ -n "$PLESK_MAIL_STATUS" ]]; then
      pass "Mail accounts found for $CHECK_DOMAIN:"
      echo "$PLESK_MAIL_STATUS" | sed 's/^/    /'
    else
      warn "No mail accounts found or Plesk cannot query domain"
    fi

    # Postfix routing test
    echo ""
    info "Postfix routing test for postmaster@$CHECK_DOMAIN:"
    postmap -q "postmaster@$CHECK_DOMAIN" hash:/etc/postfix/virtual 2>/dev/null && \
      pass "Found in virtual map" || \
      info "Not in /etc/postfix/virtual (may use local delivery)"
    postmap -q "$CHECK_DOMAIN" hash:/etc/postfix/transport 2>/dev/null && \
      info "Transport map entry found" || \
      info "No custom transport for $CHECK_DOMAIN (using default)"

    sep
    info "Further check: https://mxtoolbox.com/SuperTool.aspx?action=mx:$CHECK_DOMAIN"
  fi
fi

# =============================================================================
# SECTION 5 — POSTFIX CONFIGURATION AUDIT
# =============================================================================
hdr "5. Postfix Configuration Audit"
sep

MAIN_CF="/etc/postfix/main.cf"

if [[ ! -f "$MAIN_CF" ]]; then
  fail "Postfix main.cf not found at $MAIN_CF"
else
  pass "Postfix main.cf found"

  # Syntax check
  echo ""
  info "Config syntax check (postfix check):"
  POSTFIX_CHECK=$(postfix check 2>&1)
  if [[ -z "$POSTFIX_CHECK" ]]; then
    pass "No syntax errors found"
  else
    fail "Postfix config errors detected:"
    echo "$POSTFIX_CHECK" | sed 's/^/    /'
  fi

  # Key settings
  echo ""
  info "Key Postfix settings (postconf -n — non-default values):"
  postconf -n 2>/dev/null | sed 's/^/    /'

  # Specific setting checks
  echo ""
  info "Critical setting validation:"

  MYHOSTNAME=$(postconf -h myhostname 2>/dev/null)
  MYDOMAIN=$(postconf -h mydomain 2>/dev/null)
  MYORIGIN=$(postconf -h myorigin 2>/dev/null)
  INET_INTERFACES=$(postconf -h inet_interfaces 2>/dev/null)
  RELAYHOST=$(postconf -h relayhost 2>/dev/null)
  MYDEST=$(postconf -h mydestination 2>/dev/null)
  SMTP_TLS=$(postconf -h smtp_tls_security_level 2>/dev/null)
  SMTPD_TLS=$(postconf -h smtpd_tls_security_level 2>/dev/null)
  SASL_AUTH=$(postconf -h smtpd_sasl_auth_enable 2>/dev/null)

  info "  myhostname       : $MYHOSTNAME"
  info "  mydomain         : $MYDOMAIN"
  info "  myorigin         : $MYORIGIN"
  info "  inet_interfaces  : $INET_INTERFACES"
  info "  relayhost        : ${RELAYHOST:-(direct delivery — no relay)}"
  info "  smtp_tls_level   : ${SMTP_TLS:-not set}"
  info "  smtpd_tls_level  : ${SMTPD_TLS:-not set}"
  info "  SASL auth        : ${SASL_AUTH:-no}"

  # Warn on common misconfigs
  [[ "$INET_INTERFACES" == "loopback-only" ]] && \
    fail "inet_interfaces = loopback-only — Postfix will NOT accept external connections"
  [[ "$SMTP_TLS" == "none" ]] && \
    warn "smtp_tls_security_level = none — outbound TLS disabled, consider 'may'"
  [[ "$SASL_AUTH" != "yes" ]] && \
    warn "SASL auth not enabled — SMTP AUTH may not work for clients"

  # Check recipient restrictions
  echo ""
  info "Recipient restrictions (anti-relay check):"
  RECIPIENT_RESTRICTIONS=$(postconf -h smtpd_recipient_restrictions 2>/dev/null)
  info "  $RECIPIENT_RESTRICTIONS"
  echo "$RECIPIENT_RESTRICTIONS" | grep -q "reject_unauth_destination" && \
    pass "reject_unauth_destination present — open relay protection OK" || \
    fail "reject_unauth_destination MISSING — server may be an open relay!"

  # Check Postfix master.cf for submission ports
  echo ""
  info "Submission/smtps in master.cf:"
  grep -E "^(submission|smtps)" /etc/postfix/master.cf 2>/dev/null | sed 's/^/    /' || \
    warn "No submission/smtps entries in master.cf — ports 587/465 may not be active"
fi

# OpenDKIM
echo ""
info "── OpenDKIM Status ──"
if command -v opendkim &>/dev/null; then
  if systemctl is-active --quiet opendkim 2>/dev/null; then
    pass "OpenDKIM is running"
    OPENDKIM_CONF="/etc/opendkim.conf"
    [[ -f "$OPENDKIM_CONF" ]] && \
      info "OpenDKIM socket: $(grep -i '^Socket' "$OPENDKIM_CONF" 2>/dev/null | head -1)"
  else
    fail "OpenDKIM is installed but NOT running"
    warn "Start: systemctl start opendkim && systemctl enable opendkim"
  fi
else
  warn "OpenDKIM not found — DKIM signing may be handled by Plesk internally or not configured"
fi

# SpamAssassin / Amavis
echo ""
info "── Spam Filter Status ──"
for SVC in amavis amavisd spamassassin spamd; do
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    pass "$SVC is running"
  elif systemctl list-units --all 2>/dev/null | grep -q "$SVC"; then
    warn "$SVC is installed but not running"
  fi
done

# =============================================================================
# SECTION 6 — IP REPUTATION & BLACKLIST CHECK
# =============================================================================
hdr "6. IP Reputation & Blacklist Check"
sep

if [[ -n "$SERVER_IP" ]]; then
  info "Server public IP: $SERVER_IP"
  REVERSED_IP=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')

  declare -A DNSBLS=(
    ["Spamhaus SBL/XBL"]="zen.spamhaus.org"
    ["Barracuda"]="b.barracudacentral.org"
    ["SpamCop"]="bl.spamcop.net"
    ["SORBS"]="dnsbl.sorbs.net"
    ["UCEPROTECT L1"]="dnsbl-1.uceprotect.net"
    ["SpamRATS"]="spamrbl.imp.ch"
  )

  echo ""
  BL_COUNT=0
  for BL_NAME in "${!DNSBLS[@]}"; do
    BL_HOST="${DNSBLS[$BL_NAME]}"
    RESULT=$(dig +short "$REVERSED_IP.$BL_HOST" 2>/dev/null | \
             grep -Eo '127\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$RESULT" ]]; then
      fail "LISTED on $BL_NAME ($BL_HOST) → $RESULT"
      ((BL_COUNT++))
    else
      pass "Clean on $BL_NAME"
    fi
  done

  echo ""
  if [[ $BL_COUNT -eq 0 ]]; then
    pass "IP not found on any checked DNSBL"
  else
    fail "$BL_COUNT blacklist listing(s) detected — take action immediately"
    warn "Identify spam source first (Section 2), then request removal"
  fi

  echo ""
  info "Comprehensive RBL checkers for IP: $SERVER_IP"
  echo "    → MXToolbox       : https://mxtoolbox.com/blacklists.aspx"
  echo "    → MultiRBL        : https://multirbl.valli.org/lookup/${SERVER_IP}.html"
  echo "    → Blacklist Master: https://www.blacklistmaster.com/checker"
  echo "    → Trend Micro ERS : https://servicecentral.trendmicro.com/en-us/ers/ip-lookup/"
  echo "    → Talos Intel     : https://www.talosintelligence.com/reputation_center/lookup?search=$SERVER_IP"
fi

# =============================================================================
# SECTION 7 — FIREWALL & PORT CHECKS
# =============================================================================
hdr "7. Firewall & Port Checks"
sep

# firewalld
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld is active"
  for PORT in 25 587 465 993 995; do
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${PORT}/tcp" || \
       firewall-cmd --list-services 2>/dev/null | grep -qiE "smtp|smtps|imaps|pop3s"; then
      pass "Port $PORT appears allowed in firewalld"
    else
      warn "Port $PORT may not be open in firewalld — verify: firewall-cmd --list-all"
    fi
  done
fi

# iptables / nftables
if command -v iptables &>/dev/null; then
  echo ""
  info "iptables SMTP rules:"
  iptables -L INPUT -n 2>/dev/null | grep -E "25|587|465" | sed 's/^/    /' || \
    info "  No explicit SMTP rules in iptables INPUT chain"
fi

# CSF
if [[ -f /etc/csf/csf.conf ]]; then
  info "CSF firewall detected"
  if grep -q "^TCP_IN.*25" /etc/csf/csf.conf 2>/dev/null; then
    pass "Port 25 found in CSF TCP_IN"
  else
    warn "Port 25 not explicitly in CSF TCP_IN — check /etc/csf/csf.conf"
  fi
fi

# Live SMTP test
echo ""
info "Local SMTP connection test (port 25):"
SMTP_TEST=$(echo "QUIT" | timeout 5 nc -w 3 127.0.0.1 25 2>/dev/null | head -1)
if echo "$SMTP_TEST" | grep -q "220"; then
  pass "SMTP banner received: $SMTP_TEST"
else
  fail "No SMTP banner on localhost:25 — Postfix may be down or port blocked"
fi

# Port 587 test
echo ""
info "Submission port 587 test:"
SUBM_TEST=$(echo "QUIT" | timeout 5 nc -w 3 127.0.0.1 587 2>/dev/null | head -1)
if echo "$SUBM_TEST" | grep -q "220"; then
  pass "Submission banner received: $SUBM_TEST"
else
  warn "No response on port 587 — client submission may not work"
fi

# =============================================================================
# SECTION 8 — DISK SPACE & MAILBOX QUOTAS
# =============================================================================
hdr "8. Disk Space & Mailbox Quotas"
sep

echo ""
info "Disk usage (key partitions):"
df -h / /var /home /var/www/vhosts 2>/dev/null | sed 's/^/    /'

echo ""
SPOOL_USE=$(du -sh /var/spool/postfix 2>/dev/null | cut -f1)
info "Postfix spool size: ${SPOOL_USE:-unknown}"

VHOSTS_USE=$(du -sh /var/www/vhosts 2>/dev/null | cut -f1)
info "Plesk vhosts size : ${VHOSTS_USE:-unknown}"

# Mail directories per domain
echo ""
info "Top mail storage consumers (/var/qmail/mailnames or Plesk mail dirs):"
for MAIL_BASE in /var/qmail/mailnames /var/www/vhosts; do
  if [[ -d "$MAIL_BASE" ]]; then
    du -sh "$MAIL_BASE"/*/ 2>/dev/null | sort -rh | head -10 | sed 's/^/    /'
    break
  fi
done

# Full partitions
echo ""
FULL_PARTS=$(df -h 2>/dev/null | awk '$5+0 >= 90 {print $6, $5}')
if [[ -n "$FULL_PARTS" ]]; then
  fail "High disk usage (>=90%) detected:"
  echo "$FULL_PARTS" | sed 's/^/    /'
  warn "Full disk = mail delivery failures (452 bounce code)"
else
  pass "No partitions at critical disk usage"
fi

# =============================================================================
# SECTION 9 — COMMON ISSUES CHECKLIST
# =============================================================================
hdr "9. Common Issues Checklist"
sep

echo ""
checklist() {
  local NUM="$1"; local DESC="$2"; local CMD="$3"
  printf "  ${BOLD}[%s]${RESET} %s\n" "$NUM" "$DESC"
  [[ -n "$CMD" ]] && printf "      ${CYAN}Cmd:${RESET} %s\n" "$CMD"
}

checklist "A" "Postfix not starting after config change" \
  "postfix check && systemctl restart postfix"

checklist "B" "Test Postfix config without restarting" \
  "postfix check && postconf -n"

checklist "C" "Send a test email from CLI" \
  "echo 'Test body' | mail -s 'Test Subject' recipient@example.com"

checklist "D" "Trace a specific email in logs" \
  "grep 'user@domain.com' $MAIL_LOG | tail -50"

checklist "E" "Inspect a queued message" \
  "postcat -q <queue_id>"

checklist "F" "Force retry all deferred messages" \
  "postqueue -f"

checklist "G" "Remove a single queued message" \
  "postsuper -d <queue_id>"

checklist "H" "Delete all deferred messages" \
  "postsuper -d ALL deferred"

checklist "I" "Hold all active messages (for investigation)" \
  "postsuper -h ALL"

checklist "J" "Release all held messages" \
  "postsuper -H ALL"

checklist "K" "Check open relay (from external server)" \
  "telnet $SERVER_IP 25 → EHLO test → MAIL FROM:<x@x.com> → RCPT TO:<y@external.com>"

checklist "L" "Reload Postfix config without restart" \
  "postfix reload  OR  systemctl reload postfix"

checklist "M" "Check Dovecot auth for a mailbox" \
  "doveadm auth test user@domain.com password"

checklist "N" "Rebuild Postfix lookup tables after editing" \
  "postmap /etc/postfix/virtual && postmap /etc/postfix/transport && postfix reload"

checklist "O" "Plesk repair mail services" \
  "plesk repair mail"

checklist "P" "Suspend a Plesk subscription sending spam" \
  "plesk bin subscription --disable domain.com"

checklist "Q" "Re-enable DKIM for a domain via Plesk" \
  "plesk bin domain --update domain.com -dkim_enabled true"

checklist "R" "Check Postfix relay access denied errors" \
  "grep 'relay access denied' $MAIL_LOG | tail -20"

echo ""

# =============================================================================
# SECTION 10 — REFERENCE LINKS
# =============================================================================
hdr "10. Reference Links"
sep

echo ""
echo "  ── Plesk & Postfix Documentation ───────────────────────────"
echo "  Plesk Docs                   : https://docs.plesk.com/"
echo "  Plesk KB                     : https://support.plesk.com/hc/en-us"
echo "  Plesk Mail Guide             : https://docs.plesk.com/en-US/obsidian/administrator-guide/mail/"
echo "  Postfix Docs                 : https://www.postfix.org/documentation.html"
echo "  Postfix main.cf Reference    : https://www.postfix.org/postconf.5.html"
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
echo "  ── Email Auth Validators ────────────────────────────────────"
echo "  MXToolbox SuperTool          : https://mxtoolbox.com/SuperTool.aspx"
echo "  Mail Tester (score test)     : https://www.mail-tester.com/"
echo "  DKIM Validator               : https://dkimvalidator.com/"
echo "  SPF Checker                  : https://www.spf-record.com/spf-lookup"
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
echo "    1. Address any [FAIL] items first"
echo "    2. Review [WARN] items — many affect deliverability"
echo "    3. Check blacklist URLs in Section 10 for IP reputation"
echo "    4. Run: tail -f $MAIL_LOG  for live monitoring"
echo "    5. Run: plesk repair mail  if Plesk mail config seems broken"
echo ""
echo -e "${BOLD}${GREEN}  Done.${RESET}"
echo ""
