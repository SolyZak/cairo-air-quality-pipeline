#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fill the empty secret values in .env with freshly generated ones.
#
#   ./scripts/gen_secrets.sh
#
# Only touches keys that are currently blank, so it is safe to re-run -- an
# existing Fernet key is never overwritten, because doing so would make every
# already-encrypted Airflow connection unreadable.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "error: .env not found. Run: cp .env.example .env" >&2; exit 1; }

# Fernet requires exactly 32 random bytes, url-safe base64 encoded. Generated
# with the stdlib so this works on any Python, without the cryptography package.
fernet() { python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())'; }
hexsecret() { python3 -c 'import os;print(os.urandom(32).hex())'; }
password() { python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(20)))'; }

set_if_blank() {
  local key="$1" value="$2"
  if grep -qE "^${key}=.+" .env; then
    echo "  ${key} already set, leaving it alone"
  else
    # BSD sed (macOS) needs the empty backup-suffix argument.
    sed -i '' "s|^${key}=.*|${key}=${value}|" .env
    echo "  ${key} generated"
  fi
}

set_if_blank AIRFLOW_FERNET_KEY    "$(fernet)"
set_if_blank AIRFLOW_JWT_SECRET    "$(hexsecret)"
set_if_blank AIRFLOW_ADMIN_PASSWORD "$(password)"

echo
echo "Airflow UI login:"
grep -E '^AIRFLOW_ADMIN_(USERNAME|PASSWORD)=' .env | sed 's/^/  /'
