#!/bin/sh
# Prints the Apple Team ID that `make install` and `make mac` sign with, or
# nothing when there is no single answer. Passed to xcodebuild as
# DEVELOPMENT_TEAM, it outlives `make generate`, which resets the Team picked
# in Xcode (docs/10).
#
# First match wins:
#   1. $VOCAL_TEAM
#   2. .signing-team at the repo root (gitignored; one line, the Team ID)
#   3. the Team of the Apple Development certificates in your login keychain,
#      when they all belong to one Team. With several Teams it prints nothing
#      rather than guess — write the one you want to .signing-team.
#
#   sh scripts/signing-team.sh            print it
#   sh scripts/signing-team.sh --save     also write it to .signing-team
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
file="$root/.signing-team"

team=""
if [ -n "${VOCAL_TEAM:-}" ]; then
    team=$VOCAL_TEAM
elif [ -s "$file" ]; then
    team=$(tr -d ' \t\r\n' < "$file")
elif command -v security >/dev/null 2>&1; then
    # The Team ID is the certificate subject's OU. OpenSSL prints
    # "OU = X, O = …" and LibreSSL (macOS) "/OU=X/O=…"; the pattern takes both.
    teams=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | awk '
            /-----BEGIN CERTIFICATE-----/ { pem = "" }
            { pem = pem $0 "\n" }
            /-----END CERTIFICATE-----/ {
                cmd = "openssl x509 -noout -subject"
                printf "%s", pem | cmd
                close(cmd)
            }' \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\)\([,/].*\)\{0,1\}$/\1/p' \
        | sort -u) || teams=""
    if [ -n "$teams" ] && [ "$(printf '%s\n' "$teams" | wc -l | tr -d ' ')" = 1 ]; then
        team=$teams
    fi
fi

# A Team ID is ten uppercase letters and digits; anything else is a typo.
case "$team" in
    "") ;;
    *[!A-Z0-9]*) echo "signing-team: '$team' is not a Team ID" >&2; team="" ;;
    *) [ ${#team} -eq 10 ] || { echo "signing-team: '$team' is not a Team ID" >&2; team=""; } ;;
esac

if [ "${1:-}" = "--save" ]; then
    if [ -z "$team" ]; then
        echo "No single Team found. Write yours by hand: echo YOURTEAMID > .signing-team" >&2
        exit 1
    fi
    printf '%s\n' "$team" > "$file"
    echo "Saved $team to .signing-team" >&2
fi
printf '%s' "$team"
