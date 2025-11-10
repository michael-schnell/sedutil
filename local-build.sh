#!/bin/bash
# Local build script for sedutil
# This mimics the GitHub Actions workflow for local testing
#
# Usage:
#   ./local-build.sh              - Full build (clean + binaries + rescue images)
#   ./local-build.sh --skip-clean - Skip clean, rebuild binaries and rescue images
#   ./local-build.sh --skip-rescue - Build binaries only, skip rescue images
#   ./local-build.sh --package-only - Only package existing artifacts (no build)

set -e  # Exit on error

echo "=========================================="
echo "sedutil Local Build Script"
echo "=========================================="
echo ""

# Parse command line arguments
SKIP_CLEAN=false
SKIP_RESCUE=false
PACKAGE_ONLY=false

for arg in "$@"; do
    case $arg in
        --skip-clean)
            SKIP_CLEAN=true
            echo "Mode: Skip clean (incremental build)"
            ;;
        --skip-rescue)
            SKIP_RESCUE=true
            echo "Mode: Skip rescue image build"
            ;;
        --package-only)
            PACKAGE_ONLY=true
            echo "Mode: Package only (no build)"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (no options)      Full build: clean + binaries + rescue images (20-40 min)"
            echo "  --skip-clean      Incremental build: rebuild binaries and rescue images"
            echo "  --skip-rescue     Build binaries only, skip rescue images (fast)"
            echo "  --package-only    Package existing artifacts without rebuilding (instant)"
            echo "  --help, -h        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                    # Full clean build with rescue images"
            echo "  $0 --skip-rescue      # Quick build, binaries only"
            echo "  $0 --package-only     # Re-package existing build artifacts"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--skip-clean] [--skip-rescue] [--package-only]"
            echo "Run '$0 --help' for more information"
            exit 1
            ;;
    esac
done
echo ""

# Check if running on Linux
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    echo "ERROR: This script must be run on Linux (native or WSL)"
    echo ""
    echo "Options:"
    echo "1. Use WSL (Windows Subsystem for Linux)"
    echo "2. Use a Linux VM"
    echo "3. Use Docker (see local-build-docker.sh)"
    echo ""
    exit 1
fi

# Check for required commands
echo "Checking prerequisites..."
MISSING_DEPS=()

for cmd in git make gcc g++ autoconf automake pkg-config nasm fakeroot dpkg-deb; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=($cmd)
    fi
done

# Check for libtool or libtoolize
if ! command -v libtool &> /dev/null && ! command -v libtoolize &> /dev/null; then
    MISSING_DEPS+=(libtool)
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "ERROR: Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them with:"
    echo "sudo apt-get update"
    echo "sudo apt-get install -y \\"
    echo "  build-essential autoconf pkg-config libc6-dev make g++-multilib m4 libtool \\"
    echo "  ncurses-dev unzip zip git python3 zlib1g-dev wget bsdmainutils automake \\"
    echo "  curl bc rsync cpio nasm fakeroot dpkg-dev uuid-dev libuuid1 mtools \\"
    echo "  genisoimage syslinux dosfstools gdisk kpartx"
    echo ""
    exit 1
fi

echo "✓ All prerequisites found"
echo ""

# Determine version
if git describe --tags --exact-match 2>/dev/null; then
    VERSION=$(git describe --tags --exact-match | sed 's/^v//')
    echo "Building tagged version: $VERSION"
elif git rev-parse --git-dir > /dev/null 2>&1; then
    VERSION="0.0.0-$(git rev-parse --short HEAD)"
    echo "Building from commit: $VERSION"
else
    VERSION="0.0.0-local"
    echo "Building local version: $VERSION"
fi
echo ""

# Skip to packaging if requested
if [ "$PACKAGE_ONLY" = true ]; then
    echo "Skipping build steps, going directly to packaging..."
    echo ""
    # Jump to Step 6
else
    # Clean previous build artifacts (unless --skip-clean)
    if [ "$SKIP_CLEAN" = false ]; then
        echo "Cleaning previous build artifacts..."
        rm -rf .ci_artifacts .ci_artifacts_backup
        rm -f sedutil-local-x86_64.tar.gz sedutil-local-x86_64.deb
        rm -f sedutil-1.15.1.tar.gz  # Clean dist tarball too
        mkdir -p .ci_artifacts
        echo ""
    else
        echo "Skipping clean (incremental build)..."
        mkdir -p .ci_artifacts .ci_artifacts_backup
        echo ""
    fi

    # Step 1: Prepare build
    echo "=========================================="
    echo "Step 1: Prepare build (autoreconf + configure)"
    echo "=========================================="
    autoreconf --install || true
    ./configure || {
        echo "ERROR: Configure failed. Check config.log:"
        cat config.log || true
        exit 1
    }
    echo ""

    # Step 2: Build binaries
    echo "=========================================="
    echo "Step 2: Build sedutil binaries"
    echo "=========================================="
    make -j$(nproc)
    echo ""

    # Step 3: Backup binaries
    echo "=========================================="
    echo "Step 3: Backup binaries before rescue image build"
    echo "=========================================="
    mkdir -p .ci_artifacts_backup
    cp sedutil-cli .ci_artifacts_backup/ 2>/dev/null || echo "WARNING: sedutil-cli not found"
    cp linuxpba .ci_artifacts_backup/ 2>/dev/null || echo "WARNING: linuxpba not found"
    ls -lah .ci_artifacts_backup/
    echo ""
fi

# Step 4: Build rescue image (optional, can be skipped with --skip-rescue)
if [ "$SKIP_RESCUE" = false ] && [ "$PACKAGE_ONLY" = false ]; then
    echo "=========================================="
    echo "Step 4: Build rescue image (UEFI 64-bit)"
    echo "=========================================="
    echo "NOTE: This step takes 20-40 minutes and requires sudo"
    echo "Press Ctrl+C within 5 seconds to skip rescue image build..."
    sleep 5
    
    cd images
    
    echo "=== Getting resources ==="
    ./getresources

    echo "=== Setting up buildroot (clone and copy configs) ==="
    cd scratch
    # Clone buildroot (completely fresh)
    echo "=== Removing old buildroot directory ==="
    rm -rf buildroot

    echo "=== Cloning buildroot ==="
    git clone ${BUILDROOT:-git://git.buildroot.net/buildroot}
    cd buildroot
    git checkout -b PBABUILD ${BUILDROOT_TAG:-2021.08.3}
    git reset --hard
    git clean -df

    # Add sedutil packages first
    echo "=== Adding sedutil packages ==="
    sed -i '/sedutil/d' package/Config.in
    sed -i '/menu "System tools"/a \\tsource "package/sedutil/Config.in"' package/Config.in
    cp -r ../../buildroot/packages/sedutil/ package/

    # Setup 64bit build directory
    echo "=== Setting up 64bit build directory ==="
    mkdir -p 64bit
    cp ../../buildroot/64bit/.config 64bit/.config.orig
    cp ../../buildroot/64bit/* 64bit/ 2>/dev/null || true
    cp -r ../../buildroot/64bit/overlay 64bit/ 2>/dev/null || true

    # Clean the 64bit config file - remove legacy/deprecated markers
    echo "Cleaning 64bit config..."
    grep -v "^BR2_DEPRECATED" 64bit/.config.orig | grep -v "^BR2_LEGACY" > 64bit/.config || cp 64bit/.config.orig 64bit/.config

    # Add BR2_EXTERNAL before running olddefconfig
    echo 'BR2_EXTERNAL=' >> 64bit/.config
    touch 64bit/.br-external.mk

    # Generate fresh config for 64bit
    echo "Generating fresh 64bit config..."
    make O=64bit olddefconfig

    # Remove any legacy markers that olddefconfig added
    echo "Removing legacy markers from 64bit config..."
    sed -i '/^BR2_LEGACY/d' 64bit/.config
    sed -i '/^BR2_DEPRECATED/d' 64bit/.config

    # Ensure BR2_EXTERNAL is still there
    if ! grep -q "^BR2_EXTERNAL" 64bit/.config; then
        echo 'BR2_EXTERNAL=' >> 64bit/.config
    fi

    # Create distribution tarball and extract it for buildroot override
    echo "=== Creating sedutil distribution tarball ==="
    cd ../../..
    autoreconf
    ./configure
    make dist
    mkdir -p images/scratch/buildroot/dl/
    # Only copy the distribution tarball (sedutil-1.15.1.tar.gz), not the local build tarball
    cp sedutil-1.15.1.tar.gz images/scratch/buildroot/dl/

    # Extract the distribution tarball for buildroot override
    echo "=== Extracting sedutil distribution for buildroot override ==="
    cd images/scratch/buildroot/dl
    tar xvfz sedutil-1.15.1.tar.gz
    cd ..

    echo "=== Cleaning up after dist creation ==="
    cd ../../..
    make distclean

    # Return to buildroot directory
    cd images/scratch/buildroot

    # Setup 32bit build directory
    echo "=== Setting up 32bit build directory ==="
    mkdir -p 32bit
    cp ../../buildroot/32bit/.config 32bit/.config.orig
    cp ../../buildroot/32bit/* 32bit/ 2>/dev/null || true
    cp -r ../../buildroot/32bit/overlay 32bit/ 2>/dev/null || true

    # Clean the 32bit config file - remove legacy/deprecated markers
    echo "Cleaning 32bit config..."
    grep -v "^BR2_DEPRECATED" 32bit/.config.orig | grep -v "^BR2_LEGACY" > 32bit/.config || cp 32bit/.config.orig 32bit/.config

    # Add BR2_EXTERNAL before running olddefconfig
    echo 'BR2_EXTERNAL=' >> 32bit/.config
    touch 32bit/.br-external.mk

    # Generate fresh config for 32bit
    echo "Generating fresh 32bit config..."
    make O=32bit olddefconfig

    # Remove any legacy markers that olddefconfig added
    echo "Removing legacy markers from 32bit config..."
    sed -i '/^BR2_LEGACY/d' 32bit/.config
    sed -i '/^BR2_DEPRECATED/d' 32bit/.config

    # Ensure BR2_EXTERNAL is still there
    if ! grep -q "^BR2_EXTERNAL" 32bit/.config; then
        echo 'BR2_EXTERNAL=' >> 32bit/.config
    fi

    echo "=== Config setup complete ==="

    echo "=== Building PBA root ==="
    echo "Building 64bit PBA Linux system..."
    # Use sequential build to avoid glibc parallel build race conditions
    MAKEFLAGS=-j1 make O=64bit 2>&1 | tee 64bit/build_output.txt
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "ERROR: 64bit build failed"
        tail -100 64bit/build_output.txt
        exit 1
    fi
    echo "Checking 64bit build outputs..."
    ls -lah 64bit/images/ || echo "64bit/images/ not found"
    ls -lah 64bit/target/sbin/ || echo "64bit/target/sbin/ not found"

    echo "Building 32bit PBA Linux system..."
    # Use sequential build to avoid glibc parallel build race conditions
    MAKEFLAGS=-j1 make O=32bit 2>&1 | tee 32bit/build_output.txt
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "ERROR: 32bit build failed"
        tail -100 32bit/build_output.txt
        exit 1
    fi
    echo "Checking 32bit build outputs..."
    ls -lah 32bit/images/ || echo "32bit/images/ not found"
    ls -lah 32bit/target/sbin/ || echo "32bit/target/sbin/ not found"
    cd ../.. || {
        echo "buildpbaroot failed, checking for BR2_EXTERNAL issue..."
        if [ -d scratch/buildroot ]; then
            cd scratch/buildroot
            for dir in 64bit 32bit; do
                if [ -f "$dir/.config" ]; then
                    if ! grep -q "^BR2_EXTERNAL" "$dir/.config"; then
                        echo "Adding BR2_EXTERNAL to $dir/.config"
                        echo 'BR2_EXTERNAL=' >> "$dir/.config"
                    fi
                fi
            done
            cd ../..
            echo "Retrying buildpbaroot..."
            ./buildpbaroot
        else
            echo "ERROR: scratch/buildroot not found, cannot fix"
            exit 1
        fi
    }
    
    echo "=== Verifying syslinux pre-built binaries ==="
    SYSLINUX_DIR=$(find scratch -maxdepth 1 -type d -name 'syslinux-*' | head -n 1)
    if [ -z "$SYSLINUX_DIR" ]; then
        echo "ERROR: syslinux directory not found"
        exit 1
    fi
    echo "Found syslinux at: $SYSLINUX_DIR"

    # NOTE: We use the pre-built syslinux binaries from the tarball
    # Building from source produces smaller, non-functional EFI binaries
    # The pre-built syslinux.efi is 196KB vs 122KB when built from source

    cd "$SYSLINUX_DIR"

    # Verify required pre-built files exist
    echo "Verifying required syslinux files..."
    if [ ! -f bios/mbr/mbr.bin ]; then
        echo "ERROR: bios/mbr/mbr.bin not found"
        exit 1
    fi
    if [ ! -f bios/extlinux/extlinux ]; then
        echo "ERROR: bios/extlinux/extlinux not found"
        exit 1
    fi
    if [ ! -f efi64/efi/syslinux.efi ]; then
        echo "ERROR: efi64/efi/syslinux.efi not found"
        exit 1
    fi
    if [ ! -f efi64/com32/elflink/ldlinux/ldlinux.e64 ]; then
        echo "ERROR: efi64/com32/elflink/ldlinux/ldlinux.e64 not found"
        exit 1
    fi

    echo "All required syslinux pre-built files found!"
    ls -lh bios/mbr/mbr.bin bios/extlinux/extlinux efi64/efi/syslinux.efi efi64/com32/elflink/ldlinux/ldlinux.e64
    cd ../..

    echo "=== Building BIOS32 ==="
    sudo ./buildbios

    echo "=== Building UEFI64 ==="
    sudo ./buildUEFI64

    echo "=== Building rescue images ==="
    ./buildrescue Rescue32
    ./buildrescue Rescue64
    
    echo "=== Listing built images ==="
    ls -lah *.img* 2>/dev/null || echo "No image files found"
    
    cd ..
    echo ""
else
    echo "=========================================="
    echo "Step 4: SKIPPED (--skip-rescue flag)"
    echo "=========================================="
    echo ""
fi

# Step 5: Restore binaries
echo "=========================================="
echo "Step 5: Restore binaries"
echo "=========================================="
cp .ci_artifacts_backup/* . 2>/dev/null || echo "WARNING: No binaries to restore"
ls -lah sedutil-cli linuxpba 2>/dev/null || echo "WARNING: Binaries not found"
echo ""

# Step 6: Collect artifacts
echo "=========================================="
echo "Step 6: Collect artifacts"
echo "=========================================="

# Find binaries (exclude .ci_artifacts to avoid copying to itself)
BINFILES=$(find . -type f \( -name 'sedutil-cli' -o -name 'linuxpba' \) -not -path './.ci_artifacts/*' 2>/dev/null | head -2 || true)
if [ -n "$BINFILES" ]; then
    echo "Found binaries:"
    echo "$BINFILES"
    for f in $BINFILES; do
        cp -f "$f" .ci_artifacts/ 2>/dev/null || true
    done
else
    echo "WARNING: No sedutil binaries found"
fi

# Find rescue images (look for all image types)
IMGFILES=$(find images -type f \( -name 'RESCUE*.img.gz' -o -name 'BIOS*.img.gz' -o -name 'UEFI*.img.gz' \) 2>/dev/null || true)
if [ -n "$IMGFILES" ]; then
    echo "Found rescue images:"
    echo "$IMGFILES"
    for f in $IMGFILES; do
        cp "$f" .ci_artifacts/
    done
else
    echo "WARNING: No rescue images found"
    echo "Searched for: RESCUE*.img.gz, BIOS*.img.gz, UEFI*.img.gz in images/"
fi

echo ""
echo "Artifacts in .ci_artifacts/:"
ls -lah .ci_artifacts/
echo ""

# Step 7: Create tarball
echo "=========================================="
echo "Step 7: Create tarball"
echo "=========================================="
TARBALL="sedutil-local-$(uname -m).tar.gz"
cd .ci_artifacts
tar -czf "../$TARBALL" *
cd ..
echo "Created: $TARBALL"
ls -lh "$TARBALL"
echo ""

# Step 8: Create .deb package
echo "=========================================="
echo "Step 8: Create Debian package"
echo "=========================================="

# Sanitize version for Debian
DEB_VERSION="${VERSION//\//-}"
DEB_VERSION="${DEB_VERSION//_/-}"

mkdir -p debpkg/DEBIAN debpkg/usr/local/bin

# Copy binaries
cp .ci_artifacts/sedutil-cli debpkg/usr/local/bin/ 2>/dev/null || echo "WARNING: sedutil-cli not found"
cp .ci_artifacts/linuxpba debpkg/usr/local/bin/ 2>/dev/null || echo "WARNING: linuxpba not found"

# Create control file
cat > debpkg/DEBIAN/control << EOF
Package: sedutil
Version: $DEB_VERSION
Section: base
Priority: optional
Architecture: amd64
Maintainer: Local Build <build@localhost>
Description: sedutil OPAL drive utilities
 Command-line tools for managing Self-Encrypting Drives (SEDs)
 that comply with the TCG OPAL 2.0 specification.
EOF

echo "Debian control file:"
cat debpkg/DEBIAN/control
echo ""

# Build .deb
DEBFILE="sedutil-local-$(uname -m).deb"
fakeroot dpkg-deb --build debpkg "$DEBFILE"
echo "Created: $DEBFILE"
ls -lh "$DEBFILE"
echo ""

# Cleanup
rm -rf debpkg

echo "=========================================="
echo "✓ Build Complete!"
echo "=========================================="
echo ""
echo "Artifacts created:"
echo "  - $TARBALL"
echo "  - $DEBFILE"
echo "  - .ci_artifacts/ (directory with all files)"
echo ""
echo "To install the .deb package:"
echo "  sudo dpkg -i $DEBFILE"
echo ""
echo "To extract the tarball:"
echo "  tar -xzf $TARBALL"
echo ""

