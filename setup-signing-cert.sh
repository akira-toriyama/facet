#!/bin/zsh
# Create a persistent self-signed code-signing identity in the LOGIN
# keychain so that the Accessibility (TCC) grant for Facet.app
# survives rebuilds.
#
# Run ONCE. macOS asks for your login password once, so that codesign
# can use the key without a dialog — that is the only interactive
# step. Afterwards `package.sh` auto-uses the identity (it writes the
# name to `.signing-id`).
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
# Read before the tee below: once stderr is the tee's pipe, `-t 2` is false for
# a person at a terminal too. Both fds, because security(1) prompts on stderr and
# reads the password from stdin; capsule's verify.sh leaves stdin on a person's
# terminal while the prompt would go to its log.
INTERACTIVE=0
[[ -t 0 && -t 2 ]] && INTERACTIVE=1
# Tee stdout+stderr to a log by default (CLAUDE.md: state-changing
# scripts log by default; --silent opts out).
if (( ! SILENT )); then exec > >(tee "/tmp/setup-signing-cert.log") 2>&1; fi

CN="facet Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PARTITIONS="apple-tool:,apple:,codesign:"

# `security import` leaves the key's partition list at `apple-tool:`, which keeps
# codesign out: the first signature fails with errSecInternalComponent over ssh
# and stops at a SecurityAgent dialog in a GUI session (chord#237, Tart VM, macOS
# 26.5, 2026-11-07; same with this CN, t-wc1c).
#
# A usable key stays a silent no-op: capsule's verify.sh runs this script on every
# verify of a facet profile, unattended, with its output in a log, and stops the
# run if it fails. A keychain locked in this session shows no partition_id entry,
# which reads as "no". No early exit in the awk: closing the pipe would SIGPIPE
# security.
key_allows_codesign() {
  security dump-keychain -a "$KEYCHAIN" 2>/dev/null | awk -v cn="$CN" '
    /^keychain: /                             { key = 0; named = 0 }
    /^class: 0x00000010/                      { key = 1 }
    index($0, "0x00000001 <blob>=\"" cn "\"") { named = 1 }
    /authorizations .*: partition_id/         { list = 1; next }
    list && /description: / {
      if (key && named) { seen = 1; if ($0 !~ / apple:(,|$)/) missing = 1 }
      list = 0
    }
    END { exit !(seen && !missing) }
  '
}

# The list takes the keychain's password, which security(1) reads from the terminal
# (its -k is deprecated), so someone has to be there to see the prompt. -l because
# without it the list of every signing key in the keychain is replaced. A wrong
# password exits 1 and changes nothing, so a run that finds the identity present
# still has to come through here.
allow_codesign() {
  if (( ! INTERACTIVE )); then
    echo "codesign cannot use the \"$CN\" key yet, and allowing it takes your login password: run this script in a terminal." >&2
    exit 1
  fi
  echo "macOS asks for your login password once, so that codesign can use the \"$CN\" key without a dialog."
  if ! security set-key-partition-list -S "$PARTITIONS" -s -l "$CN" "$KEYCHAIN" >/dev/null; then
    echo "codesign cannot use the \"$CN\" key yet: run this script again with your login password." >&2
    exit 1
  fi
}

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
    if key_allows_codesign; then
      echo "[dry-run] identity already present: $CN — codesign can use its key; would refresh .signing-id; no keychain change"
    else
      echo "[dry-run] identity already present: $CN — codesign cannot use its key yet; would set"
      echo "[dry-run] the key's partition list to $PARTITIONS (asks for your login"
      echo "[dry-run] password), then refresh .signing-id"
    fi
    exit 0
  fi
  echo "identity already present: $CN"
  key_allows_codesign || allow_codesign
  echo -n "$CN" > .signing-id
  exit 0
fi

if (( DRY_RUN )); then
  echo "[dry-run] no \"$CN\" identity found — would create a self-signed"
  echo "[dry-run] codesigning cert, import it into $KEYCHAIN, set the key's"
  echo "[dry-run] partition list to $PARTITIONS (asks for your login"
  echo "[dry-run] password), then write .signing-id"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
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
CNF

# /usr/bin's, a LibreSSL every Mac has, never PATH's: an OpenSSL 3+ takes -legacy
# for these options and a LibreSSL refuses it, with this script's output hidden
# (chord#238: macOS 26.5, LibreSSL 3.3.6, Tart VM, 2026-11-07).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# SHA-1 MAC / 3DES + a password: required for Apple's `security` to
# import the .p12 without "MAC verification failed". Weak crypto but
# irrelevant — the .p12 lives in a per-run /tmp dir and is removed on
# exit.
P12PW="facet"
/usr/bin/openssl pkcs12 -export -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" -name "$CN" >/dev/null 2>&1

# -A opens the key's ACL to any app; codesign still needs allow_codesign.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PW" -A >/dev/null
allow_codesign

echo -n "$CN" > .signing-id
echo "created identity: $CN"
# Self-signed + untrusted: it won't show under `find-identity -p
# codesigning` (that lists trusted identities only) — `codesign`
# still uses it by name.
security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
  | grep 'SHA-1 hash' || true
echo "now run: ./run.sh   (it will sign Facet.app with this identity)"
