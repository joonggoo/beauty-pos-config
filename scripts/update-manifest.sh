#!/bin/bash
# ============================================================
# update-manifest.sh
# ecomsupports.com 인증서 체인을 추출해 SPKI 핀을 계산하고,
# manifest.json의 ssl_pins를 갱신한다.
#
# 사용법:
#   ./scripts/update-manifest.sh
#
# 환경변수:
#   DOMAIN  — 검사 대상 도메인 (기본: ecomsupports.com)
#   PORT    — 포트 (기본: 443)
#
# 동작:
#   1. openssl s_client로 인증서 체인 받기
#   2. 각 인증서에 대해 SPKI 핀(SHA-256 base64) 계산
#   3. 현재 manifest.json의 ssl_pins[*].pin과 비교
#   4. 변경이 발견되면 manifest.json을 갱신
#   5. 변경 없으면 종료 코드 0 (no-op)
#
# 종료 코드:
#   0  — 성공 (변경 없음 또는 갱신 완료)
#   1  — 인증서 추출 실패 또는 파싱 오류
#   2  — manifest.json 파일이 없거나 손상
# ============================================================

set -euo pipefail

DOMAIN="${DOMAIN:-ecomsupports.com}"
PORT="${PORT:-443}"
MANIFEST="${MANIFEST:-manifest.json}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$(dirname "$0")/.."

if [ ! -f "$MANIFEST" ]; then
    echo "❌ $MANIFEST not found"
    exit 2
fi

echo "🔍 Fetching certificate chain from $DOMAIN:$PORT ..."

# 인증서 체인 추출
openssl s_client -connect "${DOMAIN}:${PORT}" -servername "$DOMAIN" -showcerts 2>/dev/null </dev/null \
    | awk '
        /-----BEGIN CERTIFICATE-----/ { n++; out="'$TMPDIR'/cert"n".pem" }
        /-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/ { print > out }
    '

if ! ls "$TMPDIR"/cert*.pem >/dev/null 2>&1; then
    echo "❌ No certificates extracted from $DOMAIN"
    exit 1
fi

CERT_COUNT=$(ls "$TMPDIR"/cert*.pem | wc -l | tr -d ' ')
echo "✅ Extracted $CERT_COUNT certificate(s)"

# 각 인증서 분석
declare -a NEW_PINS
declare -a NEW_SUBJECTS
declare -a NEW_EXPIRES
declare -a NEW_TYPES

for i in $(seq 1 $CERT_COUNT); do
    CERT="$TMPDIR/cert$i.pem"
    SUBJECT=$(openssl x509 -in "$CERT" -noout -subject | sed 's/^subject=//' | sed 's/^[[:space:]]*//')
    ISSUER=$(openssl x509 -in "$CERT" -noout -issuer | sed 's/^issuer=//' | sed 's/^[[:space:]]*//')
    NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate | sed 's/notAfter=//')
    PIN=$(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | openssl enc -base64)

    # 만료일을 ISO date(YYYY-MM-DD)로 변환 (openssl 자체 출력 활용 — 가장 안정적)
    EXPIRES=$(openssl x509 -in "$CERT" -noout -enddate \
        | sed 's/notAfter=//' \
        | python3 -c "import sys,datetime as dt; s=sys.stdin.read().strip(); print(dt.datetime.strptime(s,'%b %d %H:%M:%S %Y %Z').strftime('%Y-%m-%d'))" 2>/dev/null \
        || echo "unknown")

    # CN 추출 (분류에 사용)
    SUBJECT_CN=$(echo "$SUBJECT" | grep -oE 'CN=[^,]*' | sed 's/^CN=//' || echo "")

    # 타입 추론 (휴리스틱):
    # - CN에 "Root Certificate Authority" → root_ca/safety_net (cross-sign 대응)
    # - CN에 "Certificate Authority" → intermediate_ca/primary
    # - 도메인 형태 (점 포함, CA 키워드 없음) → leaf/precision
    # - 그 외 → leaf/precision (보수적)
    if echo "$SUBJECT_CN" | grep -qi "Root Certificate Authority"; then
        TYPE="root_ca"
        TIER="safety_net"
    elif echo "$SUBJECT_CN" | grep -qi "Certificate Authority"; then
        TYPE="intermediate_ca"
        TIER="primary"
    else
        TYPE="leaf"
        TIER="precision"
    fi

    NEW_PINS+=("$PIN")
    NEW_SUBJECTS+=("$SUBJECT")
    NEW_EXPIRES+=("$EXPIRES")
    NEW_TYPES+=("$TYPE:$TIER")

    echo "  [$i] $TYPE/$TIER expires=$EXPIRES pin=$PIN"
done

# 현재 manifest의 핀 목록과 비교
CURRENT_PINS=$(jq -r '.ssl_pins[].pin' "$MANIFEST" | sort)
NEW_PINS_SORTED=$(printf '%s\n' "${NEW_PINS[@]}" | sort)

if [ "$CURRENT_PINS" = "$NEW_PINS_SORTED" ]; then
    echo "✅ No pin changes — manifest already up-to-date"
    exit 0
fi

echo ""
echo "⚠️  Pin changes detected — updating manifest.json"

# 새 manifest 생성
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ssl_pins 배열 JSON 빌드
SSL_PINS_JSON="[]"
for i in "${!NEW_PINS[@]}"; do
    TIER_TYPE="${NEW_TYPES[$i]}"
    TYPE="${TIER_TYPE%%:*}"
    TIER="${TIER_TYPE##*:}"

    # subject에서 CN 추출 (간단히)
    CN=$(echo "${NEW_SUBJECTS[$i]}" | grep -oE 'CN=[^,]*' | sed 's/^CN=//' || echo "${NEW_SUBJECTS[$i]}")

    SSL_PINS_JSON=$(echo "$SSL_PINS_JSON" | jq \
        --arg tier "$TIER" \
        --arg type "$TYPE" \
        --arg subject "$CN" \
        --arg expires "${NEW_EXPIRES[$i]}" \
        --arg pin "${NEW_PINS[$i]}" \
        '. + [{tier: $tier, type: $type, subject: $subject, expires: $expires, pin: $pin}]')
done

# 기존 app 섹션은 유지하면서 ssl_pins, generated_at만 갱신
jq \
    --arg generated_at "$GENERATED_AT" \
    --argjson ssl_pins "$SSL_PINS_JSON" \
    '.generated_at = $generated_at | .ssl_pins = $ssl_pins' \
    "$MANIFEST" > "$TMPDIR/manifest.new.json"

# 검증
if ! jq empty "$TMPDIR/manifest.new.json" 2>/dev/null; then
    echo "❌ Generated manifest is invalid JSON"
    exit 1
fi

mv "$TMPDIR/manifest.new.json" "$MANIFEST"

echo "✅ manifest.json updated:"
jq '.ssl_pins' "$MANIFEST"
echo ""
echo "Run 'git diff manifest.json' to inspect, then commit & push."
