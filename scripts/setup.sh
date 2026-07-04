#!/bin/sh
# setup.sh - installs a 'relay-recover' shortcut into the shell profile.
# Run once. Afterwards, 'relay-recover' works from any terminal and always
# resolves the latest installed Relay version (so plugin updates never break it).

# Pick the rc file for the user's shell.
rc="$HOME/.bashrc"
case "$SHELL" in *zsh*) rc="$HOME/.zshrc" ;; esac
[ -n "$ZSH_VERSION" ] && rc="$HOME/.zshrc"

M0='# >>> relay-recover >>>'
M1='# <<< relay-recover <<<'

# Remove any existing block (idempotent).
if [ -f "$rc" ] && grep -qF "$M0" "$rc"; then
    awk -v m0="$M0" -v m1="$M1" 'BEGIN{skip=0} $0==m0{skip=1} skip==0{print} $0==m1{skip=0}' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
fi

cat >> "$rc" <<'EOF'

# >>> relay-recover >>>
relay-recover() {
    files=$(find "$HOME/.claude/plugins" -name relay-recover.py -type f 2>/dev/null)
    if [ -z "$files" ]; then echo "relay: could not find relay-recover.py. Is Relay installed?"; return 1; fi
    script=$(ls -t $files | head -1)
    python3 "$script" "$@"
}
# <<< relay-recover <<<
EOF

echo "Installed 'relay-recover' into: $rc"
echo ""
echo "Reopen your terminal (or run: . $rc), then use:"
echo "  relay-recover --list"
echo "  relay-recover"
