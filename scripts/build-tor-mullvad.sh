#!/usr/bin/env bash
set -eo pipefail

PRODUCT=${1:-}
VERSION=${2:-} # Set to use country-specific download mirror

if [[ -z "${PRODUCT}" || -z "${VERSION}" ]]; then
  echo "Usage: $0 <tor|mullvad> <version>"
  echo "Example: $0 tor 14.5.8"
  exit 1
fi

case "$PRODUCT" in
  tor)
    TAG_PREFIX="tbb-"
    PRODUCT_TARGET="torbrowser"
    NAME_PREFIX="tor-browser"
    OUTPUT_SUBDIR="tor"
    HUMAN_NAME="Tor Browser"
    ;;
  mullvad)
    TAG_PREFIX="mb-"
    PRODUCT_TARGET="mullvadbrowser"
    NAME_PREFIX="mullvad-browser"
    OUTPUT_SUBDIR="mullvad"
    HUMAN_NAME="Mullvad Browser"
    ;;
  *)
    echo "Error: product must be 'tor' or 'mullvad'" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/common/base.sh"

# Define directories
BUILD_DIR="$(pwd)/build"
WORK_DIR="$BUILD_DIR/tor-browser-build"
OUTPUT_DIR="$BUILD_DIR/out/${OUTPUT_SUBDIR}"

info "Building ${HUMAN_NAME} version: ${VERSION}"

# Create building directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone tor-browser-build repository
if [ ! -d "$WORK_DIR" ]; then
  info 'Cloning tor-browser-build repository…'
  mkdir -p "$WORK_DIR"
  git clone https://gitlab.torproject.org/tpo/applications/tor-browser-build.git "$WORK_DIR"
  success 'cloned'
fi
cd "$WORK_DIR"

# Check out the appropriate tag/branch for the version
info "Checking out version $VERSION…"
git fetch --tags
TAG=$(git for-each-ref --sort=-taggerdate --format='%(refname:short)' "refs/tags/${TAG_PREFIX}${VERSION}[^\.]*" | head -n 1)
[ -z "$TAG" ] && die "Error: Could not find exact tag for version $VERSION. Exiting."
git config advice.detachedHead false
git checkout -f "$TAG"
git submodule update --init --recursive
success "checked out tag $TAG"

# Replace https://ftp.gnu.org/ with a mirror to avoid ultralow download speeds
# If self-hosted runner is located in Russia, set to Russia-specific mirror, otherwise build may fail due to connection issues
info 'Replacing ftp.gnu.org with mirror in the following lines:'
grep -RI --line-number --color=auto --exclude-dir='.git' 'https://ftp\.gnu\.org/' ./projects/ || true
: "${COUNTRY_CODE:=$(curl -fsSL https://ipinfo.io/country || true)}"
if [[ "$COUNTRY_CODE" == "RU" ]]; then
  info "Detected IP country as Russia (RU). Using Russia-specific mirror for GNU downloads."
  grep -RIlZ --exclude-dir='.git' 'https://ftp\.gnu\.org/' ./projects/ | xargs -0 sed -i 's|https://ftp\.gnu\.org/|https://mirror.truenetwork.ru/|g'
else
  info "Using global mirror for GNU downloads. (https://ftpmirror.gnu.org/)"
  grep -RIlZ --exclude-dir='.git' 'https://ftp\.gnu\.org/' ./projects/ | xargs -0 sed -i 's|https://ftp\.gnu\.org/|https://ftpmirror.gnu.org/|g'
fi

# Start the build process
info "Starting ${HUMAN_NAME} build for ARM64…"
info "This may take several hours depending on system performance…"
export RBM_NO_DEBUG=1
./rbm/rbm build release --target release --target browser-single-platform --target browser-linux-aarch64 --target "${PRODUCT_TARGET}"

# Show build artifacts in log
success 'Build process finished. Artifacts tree:'
tree "${PRODUCT_TARGET}/" || true

# Create output dir, clean it from previous builds
mkdir -p -- "$OUTPUT_DIR"
rm -rf "${OUTPUT_DIR:?}/"*

# Find relevant artifacts and move them with normalized names:
# - Only handle: .deb(.asc), .rpm(.asc), .tar.xz(.asc)
# - Only files that contain "${NAME_PREFIX}"
# - Ignore: "*debug-symbols*", "*.orig.tar.xz*", "*.debian.tar.xz*"
# - Normalize to: ${NAME_PREFIX}-linux-<arch>-<X.Y.Z>.<ext>
#   where version is the first X.Y or X.Y.Z found in the filename (drops packaging suffixes)
info "Looking for built packages…"
while IFS= read -r -d '' f; do
  b=$(basename "$f")

  # Only product-specific artifacts
  [[ "$b" == *"${NAME_PREFIX}"* ]] || continue

  # Ignore unwanted archives
  if [[ "$b" == *debug-symbols* ]] || [[ "$b" == *".orig.tar.xz"* ]] || [[ "$b" == *".debian.tar.xz"* ]]; then
    continue
  fi

  # Determine extension (handle multi-part extensions and signatures)
  ext=""
  if [[ "$b" == *.tar.xz.asc ]]; then
    ext="tar.xz.asc"
  elif [[ "$b" == *.tar.xz ]]; then
    ext="tar.xz"
  elif [[ "$b" == *.deb.asc ]]; then
    ext="deb.asc"
  elif [[ "$b" == *.deb ]]; then
    ext="deb"
  elif [[ "$b" == *.rpm.asc ]]; then
    ext="rpm.asc"
  elif [[ "$b" == *.rpm ]]; then
    ext="rpm"
  else
    continue
  fi

  # Extract version: first X.Y or X.Y.Z occurrence
  if ! version=$(printf "%s" "$b" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1); then
    warn "Could not extract version from '$b', skipping." >&2
    continue
  fi

  # Determine architecture
  arch=""
  # Prefer linux-<arch>-<version>
  if [[ "$b" =~ linux-([A-Za-z0-9_]+)-[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then
    arch="${BASH_REMATCH[1]}"
  # deb: *_<arch>.deb(.asc)
  elif [[ "$b" =~ _([A-Za-z0-9_]+)\.deb(\.asc)?$ ]]; then
    arch="${BASH_REMATCH[1]}"
  # rpm: .<arch>.rpm(.asc)
  elif [[ "$b" =~ \.([A-Za-z0-9_]+)\.rpm(\.asc)?$ ]]; then
    arch="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$arch" ]]; then
    warn "Could not determine architecture for '$b', skipping."
    continue
  fi

  new_name="${NAME_PREFIX}-linux-${arch}-${version}.${ext}"
  dest="${OUTPUT_DIR}/${new_name}"

  echo "✓ Moving: $f -> $dest"
  mv -f -- "$f" "$dest"
done < <(find "./${PRODUCT_TARGET}/release" -type f \( -name '*.deb' -o -name '*.deb.asc' -o -name '*.rpm' -o -name '*.rpm.asc' -o -name '*.tar.xz' -o -name '*.tar.xz.asc' \) -print0)

# Optional warning if aarch64 artifact is missing
if ! ls "$OUTPUT_DIR"/"${NAME_PREFIX}"-*linux-aarch64*.tar.xz 1> /dev/null 2>&1; then
  warn "No ARM64 package found in $OUTPUT_DIR"
fi

success "${HUMAN_NAME} ${VERSION} build completed!"
info "Output files:"
tree "$OUTPUT_DIR" || true
