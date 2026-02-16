# 개요

`pesdekery`는 `pesde`를 대체하지 않고 감싸는 래퍼 CLI입니다.
목적은 StoryBakery 저장소들이 같은 절차로 의존성을 맞추고, `pesde` 생성물의 경로 문제를 설치 후 자동 보정하는 것입니다.
`setup-project-configs`는 별도 도구로 유지하고, `pesdekery`는 패키지 관리 흐름만 책임집니다.

# 목표

- `pesde`가 제공하는 명령을 그대로 실행할 수 있게 합니다.
- StoryBakery 정책이 필요한 지점에서만 후처리를 추가합니다.
- `rokit.toml`로 설치 가능한 단일 CLI 배포 경로를 제공합니다.
- 같은 명령으로 로컬과 CI에서 동일한 결과를 재현합니다.

# 비목표

- `pesde.lock` 파일을 직접 파싱해 임의로 수정하지 않습니다.
- `pesde`의 resolver나 lock 생성 로직을 재구현하지 않습니다.
- 프로젝트 템플릿/파일 스캐폴딩은 `setup-project-configs` 책임으로 남깁니다.

# 아키텍처-원칙

- 원본-정본은 `pesde`입니다.
- `pesdekery`는 오케스트레이션과 후처리만 담당합니다.
- 후처리는 항상 멱등성으로 구현합니다.
- 실패 시 중간 상태를 최소화하고, 다시 실행하면 수렴하도록 설계합니다.

# 아키텍처-구성

1. CLI-레이어.
`pesdekery <pesde-command...>` 입력을 파싱하고 `pesde`로 그대로 전달합니다.

2. 실행-오케스트레이터.
전달 명령 실행 뒤 StoryBakery 후처리 필요 여부를 판정합니다.

3. toml-업데이터.
StoryBakery 정책에 따라 `pesde.toml` 의존성 선언을 정규화합니다.
필요하면 git rev와 버전 제약을 함께 갱신합니다.

4. 설치-후-보정기.
`roblox_packages`와 `.pesde` 생성물을 스캔하고 StoryBakery 대상 require 경로를 최신 버전으로 보정합니다.
직접 설치하지 않은 전이 의존성의 wrapper 경로도 같이 보정합니다.

5. 감사-리포터.
보정 전후 변경 건수, 스킵 건수, 실패 파일을 요약 출력합니다.

# 명령-설계

## pesdekery-sync

`pesdekery sync [pesde.toml path]`는 기존 `pesde-gitrev` 동작을 수행합니다.

1. `pesde.toml`의 StoryBakery 대상 의존성 선언을 정책대로 갱신합니다.
2. 변경이 있으면 `pesde install`로 lock과 설치 결과를 동기화합니다.
3. 설치 생성물 경로 보정기를 실행합니다.
4. 변경 요약을 출력합니다.

## pesdekery-패스스루

`pesdekery <pesde-command...>`는 인자를 그대로 `pesde`에 전달합니다.

- `add`, `install`, `remove`, `update`가 성공하면 `pesdekery sync`를 자동으로 1회 추가 실행합니다.
- 그 외 명령은 `pesde` 실행 결과만 전달합니다.

이 구조로 `pesde`의 전체 명령면을 유지하면서, 의존성 변경 지점에는 StoryBakery 정책을 자동 적용합니다.

# pesde-연동-정책

- lock 생성과 검증은 항상 `pesde`에 위임합니다.
- `pesde.toml`을 수정한 뒤에는 반드시 `pesde install` 또는 `pesde update`를 같은 실행 흐름에서 즉시 수행합니다.
- `toml`과 lock 불일치 상태에서 alias 실행이 실패하는 문제를 회피하기 위해, `pesdekery`는 `rokit` 설치 바이너리로 직접 실행하는 것을 기본으로 둡니다.

# 버전-정책

- `pesdekery` 패키지 버전은 `0.0.1`부터 시작합니다.
- 초기 단계는 `0.0.x`에서 빠르게 반복하며 래퍼 안정성을 올립니다.
- StoryBakery git 의존성은 정책상 최신 커밋 또는 정책 버전으로 수렴시킵니다.
- 최종 설치 상태의 기준은 lock과 생성물 보정 완료 결과입니다.

# 배포-정책

- `pesdekery`는 GitHub Releases에 바이너리를 배포합니다.
- `rokit`은 릴리즈 아티팩트를 받아 설치하도록 설정합니다.
- 각 릴리즈에 지원 `pesde` 버전 범위와 변경 내역을 명시합니다.

# 커뮤니티-관점

- 패키지 매니저를 대체하지 않고 래핑하는 방식은 일반적인 운영 패턴입니다.
- 해석기와 lock 생성은 원도구에 맡기고 정책 보정만 확장하는 구조가 유지보수 비용을 낮춥니다.
- 따라서 `pesdekery` 분리 목적은 타당하고, 팀 공통 환경 통일 목적과도 일치합니다.

# 마이그레이션-단계

1. 기존 `pesde-gitrev` 핵심 동작을 `pesdekery sync`로 유지합니다.
2. 저장소 실행 명령을 `pesde run ...`에서 `pesdekery <pesde-command...>`로 전환합니다.
3. `rokit` 설치 문서와 최소 사용 예시를 추가합니다.
4. 릴리즈 자동화 워크플로를 추가해 태그마다 바이너리를 배포합니다.
