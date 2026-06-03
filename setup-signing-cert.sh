#!/bin/zsh
# Create a persistent self-signed code-signing identity in the LOGIN
# keychain so that the Accessibility (TCC) grant for Facet.app
# survives rebuilds.
#
# Run ONCE. macOS may prompt to unlock your login keychain — that is
# the only interactive step. Afterwards `package.sh` auto-uses the
# identity (it writes the name to `.signing-id`).
#
# Why this works: TCC keys an app's grant to its code-signing
# identity. Ad-hoc (`codesign -s -`) has no stable identity, so
# every rebuild looks "new" and the grant is lost. A reused
# self-signed cert keeps the identity constant.
#
# Memory [[brew-install-keychain-sandbox]]: Homebrew install
# subprocess can't reach the login keychain, so this script is for
# from-source builds. Homebrew users get ad-hoc signing and re-grant
# on every formula update (acceptable cost for the install model).
set -e
cd "$(dirname "$0")"

DRY_RUN=0; SILENT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --silent)  SILENT=1 ;;
    -h|--help) echo "usage: $0 [--dry-run] [--silent]"; exit 0 ;;
    *) echo "setup-signing-cert: unknown option \"$arg\" (try --dry-run / --silent)" >&2; exit 2 ;;
  esac
done
# Tee stdout+stderr to a log by default (CLAUDE.md: state-changing
# scripts log by default; --silent opts out).
if (( ! SILENT )); then exec > >(tee "/tmp/setup-signing-cert.log") 2>&1; fi

CN="facet Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Idempotency: a self-signed cert that isn't trusted does NOT appear
# in `find-identity -v -p codesigning`, so a naive guard there never
# trips and every re-run adds another cert with the same CN —
# making `codesign --sign "$CN"` fail with "ambiguous". Detect via
# `find-certificate` (lists untrusted too) and, if duplicates
# already exist, collapse them to one.
hashes=("${(@f)$(security find-certificate -a -c "$CN" -Z "$KEYCHAIN" \
  2>/dev/null | awk '/SHA-1 hash:/ { print $3 }')}")
hashes=("${(@)hashes:#}")            # drop empty entries
if (( ${#hashes} >= 1 )); then
  if (( ${#hashes} > 1 )); then
    if (( DRY_RUN )); then
      echo "[dry-run] found ${#hashes} duplicate \"$CN\" certs — would collapse to one"
    else
      echo "found ${#hashes} duplicate \"$CN\" certs — collapsing to one"
      for h in "${hashes[@]:1}"; do
        security delete-certificate -Z "$h" "$KEYCHAIN" >/dev/null 2>&1 || true
      done
    fi
  fi
  if (( DRY_RUN )); then
    echo "[dry-run] identity already present: $CN — would refresh .signing-id; no keychain change"
    exit 0
  fi
  echo "identity already present: $CN"
  echo -n "$CN" > .signing-id
  exit 0
fi

if (( DRY_RUN )); then
  echo "[dry-run] no \"$CN\" identity found — would create a self-signed"
  echo "[dry-run] codesigning cert and import it into $KEYCHAIN, then"
  echo "[dry-run] write .signing-id"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Legacy PKCS12 (SHA1 MAC / 3DES) + a password: required for Apple's
# `security` to import OpenSSL 3 output without "MAC verification
# failed".
P12PW="facet"
openssl pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" -name "$CN" >/dev/null 2>&1

# -A: usable by any app (so /usr/bin/codesign can use the key
# non-interactively).
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PW" -A >/dev/null

echo -n "$CN" > .signing-id
echo "created identity: $CN"
# Self-signed + untrusted: it won't show under `find-identity -p
# codesigning` (that lists trusted identities only) — `codesign`
# still uses it by name.
security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
  | grep 'SHA-1 hash' || true
echo "now run: ./run.sh   (it will sign Facet.app with this identity)"
