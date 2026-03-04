# PowerPoint Presentation Update Instructions

Update the breakingbAD pentest demo presentation with the following content based on the lab's attack chain and 12 vulnerabilities.

## Lab Overview Slide

- **Domain:** `breakingbad.local`
- **DC01:** 192.168.100.10 (Domain Controller + ADCS)
- **srv01:** 192.168.100.20 (Member server)
- **srv02:** 192.168.100.21 (Member server, WebClient enabled)
- **backups:** 192.168.100.149 (Non-domain-joined backup server)
- **Kali attacker:** on same network segment

## 12 Vulnerabilities (one slide each or grouped)

| # | Vulnerability | Target | Impact |
|---|--------------|--------|--------|
| 01 | ESC8 — ADCS HTTP enrollment | dc01 | Relay naar certificaat, domain admin |
| 02 | NTLMv1 enabled | dc01 | Downgrade attack, eenvoudig te kraken |
| 03 | WebClient enabled | srv02 | Coerce auth naar attacker (HTTP relay) |
| 04 | GPO misconfigured DACL | dc01 | Ongeautoriseerde GPO-wijzigingen |
| 05 | IPv6 poisoning (DHCPv6/DNS) | netwerk | Man-in-the-middle via IPv6 |
| 06 | LLMNR/NBT-NS poisoning | netwerk | Credential capture en relay |
| 07 | Wachtwoord in AD description | dc01 (saul.goodman) | Direct account compromise |
| 08 | Kerberoasting (SPN op user) | dc01 (hector.salamanca) | Offline hash cracking |
| 09 | AS-REP Roasting (no preauth) | dc01 (jessie.pinkman) | Offline hash cracking |
| 10 | ESC1 — Vulnerable cert template | dc01 | Certificaat als elke user, domain admin |
| 11 | Anonymous RPC/LDAP access | dc01 | User enumeration zonder credentials |
| 12 | Shared local admin password | srv01, srv02, backups | Lateral movement over alle servers |

## Attack Chain Demo Slide(s)

Title: **"Van netwerk-toegang tot volledige compromittatie in 7 stappen"**

### Flow (visueel als pijlen/stappen):

1. **Responder Poisoning** — LLMNR/NBT-NS poisoning vangt walter.white's authenticatie op
2. **NTLM Relay naar LDAP** — Authenticatie wordt doorgestuurd naar de Domain Controller, alle domeininfo wordt gedumpt
3. **Wachtwoord in Description** — In de LDAP dump staat saul.goodman's wachtwoord (657crsH!) in het description-veld
4. **Kerberoasting** — hector.salamanca heeft een SPN (description: "Serviceaccount webapplicatie srv01"), TGS hash wordt gekraakt → 346modL!
5. **Local Admin op srv01** — hector is local admin, toegang tot server
6. **DPAPI Credential Dump** — Op srv01 worden opgeslagen credentials gedumpt: svc_admin:Zomer123! uit een scheduled task "Backup to 192.168.100.149"
7. **Lateral Movement + SAM Dump + RDP** — svc_admin is shared local admin op srv02 en backups. SAM dump op backups levert administrator hash op → Pass-the-Hash naar RDP

### Narrative (voor speaker notes):

> Een aanvaller met alleen netwerktoegang compromitteert in 7 stappen het volledige domein en een non-domain-joined backup server. Elke stap bouwt voort op de vorige en maakt gebruik van een andere kwetsbaarheid. Dit demonstreert hoe ogenschijnlijk kleine misconfiguraties samen een kritiek risico vormen.

## Remediation Slide

Per vulnerability kort de aanbeveling:

| # | Aanbeveling |
|---|-------------|
| 01 | Schakel HTTP enrollment uit, gebruik alleen HTTPS met EPA |
| 02 | Stel LmCompatibilityLevel in op 5 (alleen NTLMv2) |
| 03 | Schakel WebClient uit op servers waar het niet nodig is |
| 04 | Beperk schrijfrechten op GPO's tot geautoriseerde beheerders |
| 05 | Schakel DHCPv6 uit of gebruik DHCPv6 Guard |
| 06 | Schakel LLMNR en NBT-NS uit via GPO |
| 07 | Sla nooit wachtwoorden op in AD-attributen, gebruik een PAM-oplossing |
| 08 | Vermijd SPN's op gebruikersaccounts, gebruik managed service accounts |
| 09 | Vereis Kerberos pre-authentication voor alle accounts |
| 10 | Beperk enrollment-rechten en vereis manager approval op templates |
| 11 | Blokkeer anonieme toegang tot LDAP en RPC |
| 12 | Gebruik LAPS of unieke wachtwoorden per server |

## Useful Screenshots for Slides

Consider adding screenshots of:
- Responder capturing hashes (terminal output)
- ntlmrelayx LDAP relay success + "Domain info dumped"
- ldapdomaindump HTML showing saul.goodman's password in description
- GetUserSPNs.py output showing hector's SPN
- nxc `--dpapi` output showing svc_admin credential
- nxc `--sam` dump on backups server
- xfreerdp RDP session on backups as administrator (final slide / demo climax)
