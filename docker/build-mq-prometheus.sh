#!/bin/bash
#
# Build the mq_prometheus exporter binary from
# https://github.com/ibm-messaging/mq-metric-samples
#
# The upstream Dockerfile handles both amd64 and arm64 via buildx
# platform detection. For arm64, IBM does not publish a redistributable
# MQ client, so the build needs the full MQ tar.gz staged inside the
# mq-metric-samples/MQINST/ directory. build.sh puts it there for us.
#
# Result: ./mq_prometheus, a native binary for the requested TARGETARCH,
# ready for the "docker build" step to COPY into the moov-mq image.
#
# Usage:
#   ./build-mq-prometheus.sh              # auto-detect host arch
#   ./build-mq-prometheus.sh amd64
#   ./build-mq-prometheus.sh arm64

set -eux

# ---------------------------------------------------------------------------
# Argument / architecture handling
# ---------------------------------------------------------------------------
case "${1:-}" in
  amd64|arm64) TARGETARCH="$1" ;;
  "")
    case "$(uname -m)" in
      x86_64|amd64)  TARGETARCH=amd64 ;;
      aarch64|arm64) TARGETARCH=arm64 ;;
      *) echo "unsupported host architecture: $(uname -m)"; exit 1 ;;
    esac
    ;;
  *) echo "unsupported TARGETARCH: $1 (want amd64 or arm64)"; exit 1 ;;
esac

export MQ_METRIC_VERSION=5.7.1
export MQ_VERSION=9.4.5.0
export DOCKER_DEFAULT_PLATFORM="linux/${TARGETARCH}"

# ---------------------------------------------------------------------------
# Clone or refresh the upstream tree
# ---------------------------------------------------------------------------
rm -rf mq-metric-samples
git clone -b v${MQ_METRIC_VERSION} \
  https://github.com/ibm-messaging/mq-metric-samples

# ---------------------------------------------------------------------------
# arm64: seed MQINST/ with the developer MQ archive downloaded by the
# base-image build (docker/build.sh downloads it via mq-container/make).
# ---------------------------------------------------------------------------
if [ "$TARGETARCH" = "arm64" ]; then
  mkdir -p mq-metric-samples/MQINST
  archive="mq-container/downloads/${MQ_VERSION}-IBM-MQ-Advanced-for-Developers-Non-Install-LinuxARM64.tar.gz"
  if [ ! -f "$archive" ]; then
    echo
    echo "ERROR: arm64 build needs the MQ Advanced for Developers archive at:"
    echo "  $archive"
    echo
    echo "Run docker/build.sh (which drives mq-container/make build-devserver)"
    echo "to download it, or place the file at that path manually."
    exit 1
  fi
  cp "$archive" mq-metric-samples/MQINST/
fi

# ---------------------------------------------------------------------------
# Build the exporter for TARGETARCH.
# buildx / BuildKit sets $TARGETARCH inside the upstream Dockerfile, so the
# right MQ client is fetched or unpacked automatically.
# ---------------------------------------------------------------------------
cd mq-metric-samples
docker buildx build --load \
  --platform "linux/${TARGETARCH}" \
  -t "mqprom:${TARGETARCH}" \
  -f Dockerfile \
  .
cd -

# ---------------------------------------------------------------------------
# Extract the compiled binary from the throwaway image
# ---------------------------------------------------------------------------
docker run --rm --platform "linux/${TARGETARCH}" \
  --entrypoint /bin/bash \
  -v "$PWD:/pwd" -w /pwd \
  "mqprom:${TARGETARCH}" \
  -c "install -m 755 /opt/bin/mq_prometheus ."

file mq_prometheus || true
