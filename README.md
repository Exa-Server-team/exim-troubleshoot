# Exim Mail Troubleshooter

Bash script for diagnosing Exim mail issues on Linux cPanel/WHM and Plesk servers.

## Requirements
- Must run as root
- cPanel/WHM server/plesk (CentOS/AlmaLinux/CloudLinux)
- `curl`, `perl`, `dig` (bind-utils)

## Run directly 
## cPanel
curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/exim_troubleshoot_v3.sh | sudo bash

curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/exim_troubleshoot_v3.sh | sudo bash -s -- --with-msp

## Plesk
curl -s https://raw.githubusercontent.com/Exa-Server-team/exim-troubleshoot/main/postfix_troubleshoot_v3.sh | sudo bash

## What it checks
1. Server & Exim Service
2. Mail Queue Status and Spam Analysis
3. Firewall & Port Checks
4. Disk Space & Mail Quotas
5. Outgoing Mail IP / NAT / MailHELO
6. MSP Reputation & RBL Scan
7. Exim Log Health
8. Executive Summary and Report
