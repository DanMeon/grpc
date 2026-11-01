#!/bin/sh
# carenode 수정판 grpcio 휠 하나를 만든다.
#
# 쓰는 법 — 이 포크 체크아웃의 루트에서, 만들 플랫폼과 같은 아키텍처의 기계 위에서:
#   carenode/build-wheel.sh <linux-x86_64|linux-aarch64|macos-arm64> <출력 디렉터리>
# 얕은 체크아웃으로 시작할 때:
#   git clone --depth 1 --branch <이 브랜치나 태그> --filter=blob:none --sparse https://github.com/DanMeon/grpc.git
#   cd grpc && git sparse-checkout add carenode && git fetch --depth 1 origin tag v1.83.0
#
# 소스는 PyPI 공식 sdist(grpcio-1.83.0.tar.gz, sha256 고정)에 `git diff v1.83.0 HEAD`(carenode/ 제외)를
# 얹은 것이다. sdist 에는 git 체크아웃에 없는 third_party 소스와 미리 생성된 cython 코드가 들어 있어,
# PyPI 휠과 같은 입력에서 이 브랜치의 수정분만 다르다. 작업 트리가 아니라 커밋된 HEAD 를 빌드한다.
#
# linux 는 PyPA manylinux_2_28 이미지(digest 고정)의 CPython 3.13 으로 빌드하고, grpc 공식 릴리스
# 스크립트(tools/run_tests/artifacts/build_artifact_python.sh)처럼 `auditwheel repair --strip` 으로
# manylinux 태그를 붙인다 — glibc 2.28 이상(Amazon Linux 2023, Debian trixie 등)에서 돈다.
# x86_64 는 실제 x86_64 docker 에서 돌린다. Apple Silicon 의 Rosetta 로 돌리면 컴파일 도중 멈춘 적이 있다.
# macos 는 uv 가 고른 CPython 3.13 으로 빌드한다.
# 병렬 수는 JOBS(기본: CPU 수).
set -eu

BASE_TAG=v1.83.0
SDIST_NAME=grpcio-1.83.0
SDIST_URL=https://files.pythonhosted.org/packages/0c/98/304898ac4e04e2d5e4e4c2eadc178b1f2a16d5f4bc2f91306c87d64680b9/grpcio-1.83.0.tar.gz
SDIST_SHA256=7674587248fbbb2ac6e4eecf83a8a0f3d91a928f941de571acfd3a2f007fbc24
MANYLINUX_X86_64=quay.io/pypa/manylinux_2_28_x86_64@sha256:43f7ce12d79ed98b6dbfa3291d5afe389efd40a7e76de089959ffe99501b6edf
MANYLINUX_AARCH64=quay.io/pypa/manylinux_2_28_aarch64@sha256:724b504247662e1cf122590957c857211ec2d16b113ec134f92c570a2d01250f

usage="쓰는 법: carenode/build-wheel.sh <linux-x86_64|linux-aarch64|macos-arm64> <출력 디렉터리>"
platform=${1:?$usage}
out=${2:?$usage}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

sha256() {
  if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

root=$(git rev-parse --show-toplevel)
git -C "$root" rev-parse -q --verify "refs/tags/$BASE_TAG^{commit}" > /dev/null || {
  echo "기준 태그 $BASE_TAG 가 없다 — git fetch --depth 1 origin tag $BASE_TAG" >&2
  exit 2
}
case "$platform" in
  linux-x86_64) image=$MANYLINUX_X86_64 arch=x86_64 ;;
  linux-aarch64) image=$MANYLINUX_AARCH64 arch=aarch64 ;;
  macos-arm64) image='' arch=arm64 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ -n "$image" ]; then
  docker_arch=$(docker info --format '{{.Architecture}}')
  [ "$docker_arch" = "$arch" ] || {
    echo "docker 가 $docker_arch 다 — $arch 기계의 docker 에서 돌린다(에뮬레이션 빌드는 하지 않는다)" >&2
    exit 2
  }
else
  [ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "macos-arm64 는 Apple Silicon macOS 에서 돌린다" >&2; exit 2; }
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

# 1. 소스 — 공식 sdist + 이 브랜치의 수정분
curl -fsSL -o "$work/sdist.tar.gz" "$SDIST_URL"
[ "$(sha256 "$work/sdist.tar.gz" | cut -d' ' -f1)" = "$SDIST_SHA256" ] || { echo "sdist sha256 불일치" >&2; exit 1; }
tar -xzf "$work/sdist.tar.gz" -C "$work"
src=$work/$SDIST_NAME
git -C "$root" diff --binary "$BASE_TAG" HEAD -- . ':(exclude)carenode' > "$work/carenode.patch"
# ^ sdist 디렉터리는 git 저장소가 아니다. 상위에서 저장소를 찾아 그 기준으로 적용하지 않게 막는다.
(cd "$src" && GIT_CEILING_DIRECTORIES="$work" git apply -p1 "$work/carenode.patch")
echo "base=$BASE_TAG head=$(git -C "$root" rev-parse HEAD) patch_sha256=$(sha256 "$work/carenode.patch" | cut -d' ' -f1)"

# 2. 빌드
if [ -n "$image" ]; then
  docker run --rm -e JOBS="$jobs" -e HOST_IDS="$(id -u):$(id -g)" \
    -v "$src:/src:ro" -v "$out:/out" "$image" sh -euc '
      cp -a /src /tmp/grpcio
      cd /tmp/grpcio
      GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS="$JOBS" /opt/python/cp313-cp313/bin/python -m pip wheel -q --no-deps -w /tmp/raw .
      auditwheel repair --strip --plat "$AUDITWHEEL_PLAT" -w /tmp/repaired /tmp/raw/grpcio-*.whl
      auditwheel show /tmp/repaired/grpcio-*.whl
      cp /tmp/repaired/grpcio-*.whl /out/
      chown "$HOST_IDS" /out/grpcio-*.whl'
else
  GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS="$jobs" uv build --wheel --python 3.13 --out-dir "$out" "$src"
fi

# 3. 결과
for wheel in "$out"/grpcio-*.whl; do
  sha256 "$wheel"
done
