#!/bin/bash
# Docker-based local build script for sedutil
# Works on Windows, macOS, and Linux

set -e

echo "=========================================="
echo "sedutil Docker Build Script"
echo "=========================================="
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not in PATH"
    echo ""
    echo "Please install Docker Desktop:"
    echo "  Windows/Mac: https://www.docker.com/products/docker-desktop"
    echo "  Linux: https://docs.docker.com/engine/install/"
    echo ""
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "ERROR: Docker is not running"
    echo ""
    echo "Please start Docker Desktop and try again"
    echo ""
    exit 1
fi

echo "✓ Docker is available"
echo ""

# Remove old Docker image if it exists
echo "Removing old Docker image (if exists)..."
docker rmi -f sedutil-builder 2>/dev/null || true
echo ""

# Build Docker image
echo "Building Docker image (this may take a few minutes)..."
docker build -t sedutil-builder -f- . << 'EOF'
FROM ubuntu:24.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies (from original repo, python3 instead of python for Ubuntu 24.04)
# Added linux-libc-dev for kernel headers (needed for linux/nvme.h and linux/version.h)
# Added dos2unix for fixing line endings
RUN apt-get update && apt-get install -y \
    build-essential autoconf pkg-config libc6-dev make g++-multilib m4 libtool \
    ncurses-dev unzip zip git python3 zlib1g-dev wget bsdmainutils automake \
    curl bc rsync cpio nasm linux-libc-dev dos2unix \
    && rm -rf /var/lib/apt/lists/*

# Fix git safe.directory issue
RUN git config --global --add safe.directory '*'

WORKDIR /workspace

CMD ["/bin/bash"]
EOF

echo "✓ Docker image built"
echo ""

# Get absolute path - Docker Desktop on Windows needs Unix-style paths
# Convert Windows path to Unix path for Docker
if command -v cygpath &> /dev/null; then
    # We're in Git Bash/Cygwin on Windows - convert to Unix path
    WORKSPACE_PATH="$(cygpath -u "$(pwd -W 2>/dev/null || pwd)")"
else
    WORKSPACE_PATH="$(pwd)"
fi

# Run build in Docker
echo "Running build in Docker container..."
echo "Mounting: ${WORKSPACE_PATH} -> /workspace"
echo ""

# Prevent Git Bash from converting /workspace to Windows path
export MSYS_NO_PATHCONV=1

docker run --rm --privileged \
    -v "${WORKSPACE_PATH}:/workspace" \
    -w /workspace \
    sedutil-builder \
    bash -c '
set -e
echo "=========================================="
echo "Building sedutil (Ubuntu 24.04)"
echo "=========================================="
echo ""

echo "Debug: Current directory:"
pwd
echo "Debug: Directory contents:"
ls -la | head -20
echo ""

echo "Step 1: Clean previous build artifacts"
make clean 2>/dev/null || true
rm -f linux/Version.h 2>/dev/null || true

echo ""
echo "Step 2: autoreconf --install"
autoreconf --install

echo ""
echo "Step 3: ./configure"
./configure

echo ""
echo "Step 4: make all"
make all || true  # Ignore error from rm -f linuxpba on Windows filesystem

# Check if binaries were created
if [ ! -f sedutil-cli ]; then
    echo "ERROR: sedutil-cli was not created!"
    exit 1
fi
echo "✓ sedutil-cli created successfully"

echo ""
echo "Step 5: cd images"
cd images

echo ""
echo "Step 6: Fix line endings for scripts and config files"
dos2unix getresources buildpbaroot buildbios buildUEFI64 buildrescue conf 2>/dev/null || sed -i "s/\r$//" getresources buildpbaroot buildbios buildUEFI64 buildrescue conf

echo ""
echo "Step 6b: Fix line endings for buildroot package files"
find buildroot/packages/sedutil/ -type f -exec dos2unix {} \; 2>/dev/null || find buildroot/packages/sedutil/ -type f -exec sed -i "s/\r$//" {} \;

echo ""
echo "Step 7: ./getresources"
./getresources

echo ""
echo "Step 8: ./buildpbaroot"
./buildpbaroot

echo ""
echo "Step 9: ./buildbios"
./buildbios

echo ""
echo "Step 10: ./buildUEFI64"
./buildUEFI64

echo ""
echo "Step 11: ./buildrescue Rescue32"
./buildrescue Rescue32

echo ""
echo "Step 12: ./buildrescue Rescue64"
./buildrescue Rescue64

echo ""
echo "=========================================="
echo "✓ Build Complete!"
echo "=========================================="
'

echo ""
echo "=========================================="
echo "✓ Docker Build Complete!"
echo "=========================================="
echo ""
echo "Build artifacts should be in images/ directory"
ls -lh images/*.img images/*.iso 2>/dev/null || echo "No rescue images found"
echo ""

