#!/bin/bash
# breakingbAD Hash Cracker - Auto-detect and crack hashes from demo
# Usage: ./hashcrack.sh [type] or ./hashcrack.sh (interactive menu)

HASH_DIR="$(dirname "$0")/hashes"
WORDLIST="/usr/share/john/password.lst"
CRACKED_DIR="$(dirname "$0")/cracked"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$CRACKED_DIR"

show_menu() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    breakingbAD Hash Cracker${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Available hash types:"
    echo ""

    # Check which hash files exist
    [[ -f "$HASH_DIR/ntlmv1.txt" ]] && echo -e "  ${GREEN}1)${NC} NTLMv1          (hashcat -m 5500)"
    [[ -f "$HASH_DIR/ntlmv2.txt" ]] && echo -e "  ${GREEN}2)${NC} NTLMv2          (hashcat -m 5600)"
    [[ -f "$HASH_DIR/asreproast.txt" ]] && echo -e "  ${GREEN}3)${NC} AS-REP Roast    (hashcat -m 18200)"
    [[ -f "$HASH_DIR/kerberoast.txt" ]] && echo -e "  ${GREEN}4)${NC} Kerberoast TGS  (hashcat -m 13100)"
    [[ -f "$HASH_DIR/ntds.txt" ]] && echo -e "  ${GREEN}5)${NC} NTLM (NTDS)     (hashcat -m 1000)"
    echo ""
    echo -e "  ${YELLOW}a)${NC} Crack ALL available hashes"
    echo -e "  ${YELLOW}l)${NC} List hash files"
    echo -e "  ${YELLOW}q)${NC} Quit"
    echo ""
}

crack_hash() {
    local hash_file="$1"
    local mode="$2"
    local name="$3"
    local output_file="$CRACKED_DIR/${name}_cracked.txt"

    if [[ ! -f "$hash_file" ]]; then
        echo -e "${RED}[!] Hash file not found: $hash_file${NC}"
        return 1
    fi

    if [[ ! -f "$WORDLIST" ]]; then
        echo -e "${RED}[!] Wordlist not found: $WORDLIST${NC}"
        echo -e "${YELLOW}[*] Trying rockyou.txt...${NC}"
        WORDLIST="/usr/share/wordlists/rockyou.txt"
        if [[ ! -f "$WORDLIST" ]]; then
            echo -e "${RED}[!] No wordlist available${NC}"
            return 1
        fi
    fi

    local hash_count=$(wc -l < "$hash_file" 2>/dev/null || echo "0")
    echo -e "${BLUE}[*] Cracking $name hashes ($hash_count hashes)${NC}"
    echo -e "${BLUE}[*] Mode: $mode | Wordlist: $WORDLIST${NC}"
    echo ""

    hashcat -m "$mode" "$hash_file" "$WORDLIST" --potfile-path="$CRACKED_DIR/hashcat.pot" -o "$output_file" --outfile-format=2 2>/dev/null

    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        echo ""
        echo -e "${GREEN}[+] Cracked passwords saved to: $output_file${NC}"
        echo -e "${GREEN}[+] Results:${NC}"
        cat "$output_file"
    else
        # Check potfile for already cracked
        echo ""
        echo -e "${YELLOW}[*] Checking for previously cracked...${NC}"
        hashcat -m "$mode" "$hash_file" --show --potfile-path="$CRACKED_DIR/hashcat.pot" 2>/dev/null
    fi
    echo ""
}

list_hashes() {
    echo -e "${BLUE}[*] Hash files in $HASH_DIR:${NC}"
    echo ""
    for f in "$HASH_DIR"/*.txt; do
        if [[ -f "$f" ]]; then
            local count=$(wc -l < "$f")
            local basename=$(basename "$f")
            echo -e "  ${GREEN}$basename${NC} ($count hashes)"
            head -1 "$f" | cut -c1-80
            echo ""
        fi
    done
}

crack_all() {
    echo -e "${BLUE}[*] Cracking all available hashes...${NC}"
    echo ""

    [[ -f "$HASH_DIR/ntlmv1.txt" ]] && crack_hash "$HASH_DIR/ntlmv1.txt" 5500 "ntlmv1"
    [[ -f "$HASH_DIR/ntlmv2.txt" ]] && crack_hash "$HASH_DIR/ntlmv2.txt" 5600 "ntlmv2"
    [[ -f "$HASH_DIR/asreproast.txt" ]] && crack_hash "$HASH_DIR/asreproast.txt" 18200 "asreproast"
    [[ -f "$HASH_DIR/kerberoast.txt" ]] && crack_hash "$HASH_DIR/kerberoast.txt" 13100 "kerberoast"
    [[ -f "$HASH_DIR/ntds.txt" ]] && crack_hash "$HASH_DIR/ntds.txt" 1000 "ntds"

    echo -e "${GREEN}[+] Done!${NC}"
}

# Handle command line argument
case "$1" in
    ntlmv1|1)
        crack_hash "$HASH_DIR/ntlmv1.txt" 5500 "ntlmv1"
        exit 0
        ;;
    ntlmv2|2)
        crack_hash "$HASH_DIR/ntlmv2.txt" 5600 "ntlmv2"
        exit 0
        ;;
    asreproast|asrep|3)
        crack_hash "$HASH_DIR/asreproast.txt" 18200 "asreproast"
        exit 0
        ;;
    kerberoast|kerb|4)
        crack_hash "$HASH_DIR/kerberoast.txt" 13100 "kerberoast"
        exit 0
        ;;
    ntds|ntlm|5)
        crack_hash "$HASH_DIR/ntds.txt" 1000 "ntds"
        exit 0
        ;;
    all|a)
        crack_all
        exit 0
        ;;
    list|l)
        list_hashes
        exit 0
        ;;
    help|-h|--help)
        echo "Usage: $0 [ntlmv1|ntlmv2|asreproast|kerberoast|ntds|all|list]"
        echo ""
        echo "Hash modes:"
        echo "  ntlmv1     - NTLMv1 hashes (mode 5500)"
        echo "  ntlmv2     - NTLMv2 hashes (mode 5600)"
        echo "  asreproast - AS-REP hashes (mode 18200)"
        echo "  kerberoast - TGS-REP hashes (mode 13100)"
        echo "  ntds       - NTLM hashes from NTDS (mode 1000)"
        echo "  all        - Crack all available"
        echo "  list       - List hash files"
        exit 0
        ;;
esac

# Interactive menu
while true; do
    show_menu
    read -p "Select option: " choice

    case "$choice" in
        1) crack_hash "$HASH_DIR/ntlmv1.txt" 5500 "ntlmv1" ;;
        2) crack_hash "$HASH_DIR/ntlmv2.txt" 5600 "ntlmv2" ;;
        3) crack_hash "$HASH_DIR/asreproast.txt" 18200 "asreproast" ;;
        4) crack_hash "$HASH_DIR/kerberoast.txt" 13100 "kerberoast" ;;
        5) crack_hash "$HASH_DIR/ntds.txt" 1000 "ntds" ;;
        a|A) crack_all ;;
        l|L) list_hashes ;;
        q|Q) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac

    read -p "Press Enter to continue..."
done
