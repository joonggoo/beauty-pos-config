# beauty-pos-config

ECOM IT Manager 모바일 앱(beauty-pos)의 무핀 설정 채널입니다.

## 목적

GoDaddy SSL 인증서가 갱신될 때마다 앱을 재배포해야 했던 문제를 해결하기 위해, **별도 인프라(GitHub Pages)**에서 SSL 핀과 앱 버전 정보를 호스팅합니다.

앱은 시작 시점에 이 채널에서 manifest.json을 읽어 동적으로 SSL 핀을 적용합니다. 이 채널은 SSL pinning 없이 시스템 신뢰 저장소만 사용하므로, 메인 서버 인증서가 변경되어도 영향받지 않습니다.

## 엔드포인트

```
https://joonggoo.github.io/beauty-pos-config/manifest.json
```

## manifest.json 구조

```json
{
  "schema_version": 1,
  "generated_at": "ISO 8601 timestamp",
  "domain": "ecomsupports.com",
  "ssl_pins": [
    {
      "tier": "primary | safety_net | precision",
      "type": "intermediate_ca | root_ca | leaf",
      "subject": "...",
      "expires": "YYYY-MM-DD",
      "pin": "base64(sha256(SubjectPublicKeyInfo DER))"
    }
  ],
  "app": {
    "min_version": "string",
    "min_version_code": 301,
    "latest_version": "string",
    "latest_version_code": 301,
    "force_update": false,
    "apk_url": "https://...",
    "release_notes": "string"
  }
}
```

## 자동 갱신

GitHub Action이 매일 0시(UTC)에 ecomsupports.com 인증서 체인을 추출해 SPKI 핀을 계산하고, 변경이 발견되면 manifest.json을 자동으로 갱신/커밋/푸시합니다.

수동 갱신:
```bash
./scripts/update-manifest.sh
```

## 핀 갱신 정책

| Tier | 역할 | 변경 빈도 |
|------|------|----------|
| primary (Intermediate CA) | 메인 검증 핀 | 수년에 한 번 |
| safety_net (Root CA) | 차상위 fallback | 거의 영구 |
| precision (Leaf) | 정확성 보조 | 잦음 (매주~매월) |

## 보안

이 repo는 public이지만, manifest.json에 담긴 SSL 핀은 모두 인증서에서 추출한 **공개 정보**입니다. 비밀 정보는 포함되지 않습니다.

## 라이선스

Internal use only.
