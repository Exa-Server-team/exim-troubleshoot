# Exim Mail Troubleshooter

Bash script for diagnosing Exim mail issues on cPanel/WHM servers.

## Requirements
- Must run as root
- cPanel/WHM server (CentOS/AlmaLinux/CloudLinux)
- `curl`, `perl`, `dig` (bind-utils)

## Run directly 
curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/exim_troubleshoot.sh | sudo bash


## What it checks
1. Server hostname, PTR/FCrDNS validation
2. Mail queue size + spam source analysis (>200 threshold)
2b. MSP/SSE spam scanner
3. Exim log analysis
4. DNS/MX checks (per domain, interactive)
5. Email authentication config (DKIM/SPF/DMARC)
6. Firewall & port checks
7. Disk & quota check
8. Email delivery trace (multi-filter, searches all .gz archives)
9. Common issues checklist
10. Reference links
