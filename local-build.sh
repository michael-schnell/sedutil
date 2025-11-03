#!/bin/bash
# Local build script for sedutil
# This mimics the GitHub Actions workflow for local testing

set -e  # Exit on error

echo "=========================================="
echo "sedutil Local Build Script"
echo "=========================================="
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

# Clean previous build artifacts
echo "Cleaning previous build artifacts..."
rm -rf .ci_artifacts .ci_artifacts_backup
mkdir -p .ci_artifacts
echo ""

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

# Step 4: Build rescue image (optional, can be skipped with --skip-rescue)
if [[ "$1" != "--skip-rescue" ]]; then
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
    # Clone buildroot
    rm -rf buildroot
    git clone ${BUILDROOT:-git://git.buildroot.net/buildroot}
    cd buildroot
    git checkout -b PBABUILD ${BUILDROOT_TAG:-2021.08.3}
    git reset --hard
    git clean -df

    # Copy config files for 64bit
    mkdir 64bit
    cp ../../buildroot/64bit/.config 64bit/
    cp ../../buildroot/64bit/* 64bit/ 2>/dev/null || true
    cp -r ../../buildroot/64bit/overlay 64bit/ 2>/dev/null || true

    # Copy config files for 32bit
    mkdir 32bit
    cp ../../buildroot/32bit/.config 32bit/
    cp ../../buildroot/32bit/* 32bit/ 2>/dev/null || true
    cp -r ../../buildroot/32bit/overlay 32bit/ 2>/dev/null || true

    # Add sedutil packages
    sed -i '/sedutil/d' package/Config.in
    sed -i '/menu "System tools"/a \\tsource "package/sedutil/Config.in"' package/Config.in
    cp -r ../../buildroot/packages/sedutil/ package/

    echo "=== Fixing BR2_EXTERNAL in buildroot configs ==="
    # Add BR2_EXTERNAL to config files and create .br-external.mk files
    for dir in 64bit 32bit; do
        config="$dir/.config"
        if [ -f "$config" ]; then
            echo "Found config: $config"
            if ! grep -q "^BR2_EXTERNAL" "$config"; then
                echo "Adding BR2_EXTERNAL to $config"
                echo 'BR2_EXTERNAL=' >> "$config"
            else
                echo "BR2_EXTERNAL already exists in $config"
            fi
            # Create empty .br-external.mk file
            echo "Creating $dir/.br-external.mk"
            touch "$dir/.br-external.mk"

            # Check for legacy options and try to fix
            echo "Checking for legacy options in $config..."
            if make O=$dir olddefconfig 2>&1 | tee /tmp/olddefconfig_$dir.log | grep -q "legacy"; then
                echo "Legacy options detected, attempting to clean config..."
                # Extract key settings we want to keep
                grep "^BR2_x86_64=y" "$config" > "$config.new" || echo "BR2_x86_64=y" > "$config.new"
                grep "^BR2_PACKAGE_SEDUTIL=y" "$config" >> "$config.new" || echo "BR2_PACKAGE_SEDUTIL=y" >> "$config.new"
                grep "^BR2_PACKAGE_GNU_EFI=y" "$config" >> "$config.new" || echo "BR2_PACKAGE_GNU_EFI=y" >> "$config.new"
                grep "^BR2_PACKAGE_BUSYBOX=y" "$config" >> "$config.new" || echo "BR2_PACKAGE_BUSYBOX=y" >> "$config.new"
                grep "^BR2_PACKAGE_UTIL_LINUX=y" "$config" >> "$config.new" || echo "BR2_PACKAGE_UTIL_LINUX=y" >> "$config.new"
                grep "^BR2_PACKAGE_ZIP=y" "$config" >> "$config.new" || echo "BR2_PACKAGE_ZIP=y" >> "$config.new"
                grep "^BR2_PACKAGE_OVERRIDE_FILE=" "$config" >> "$config.new" || true
                grep "^BR2_ROOTFS_OVERLAY=" "$config" >> "$config.new" || true
                grep "^BR2_LINUX_KERNEL" "$config" >> "$config.new" || true
                echo 'BR2_EXTERNAL=' >> "$config.new"
                mv "$config.new" "$config"
                echo "Regenerating config with olddefconfig..."
                make O=$dir olddefconfig
            fi
        else
            echo "Config not found: $config"
        fi
    done

    echo "=== Building PBA root ==="
    echo "Building 64bit PBA Linux system..."
    make -j$(nproc) O=64bit 2>&1 | tee 64bit/build_output.txt
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "ERROR: 64bit build failed"
        tail -100 64bit/build_output.txt
        exit 1
    fi
    echo "Checking 64bit build outputs..."
    ls -lah 64bit/images/ || echo "64bit/images/ not found"
    ls -lah 64bit/target/sbin/ || echo "64bit/target/sbin/ not found"

    echo "Building 32bit PBA Linux system..."
    make -j$(nproc) O=32bit 2>&1 | tee 32bit/build_output.txt
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
    
    echo "=== Building syslinux for UEFI ==="
    SYSLINUX_DIR=$(find scratch -maxdepth 1 -type d -name 'syslinux-*' | head -n 1)
    if [ -z "$SYSLINUX_DIR" ]; then
        echo "ERROR: syslinux directory not found"
        exit 1
    fi
    echo "Found syslinux at: $SYSLINUX_DIR"

    # Fix for GCC 10+ (syslinux 6.03 multiple definition errors)
    echo "Applying GCC 10+ compatibility patch..."
    cd "$SYSLINUX_DIR"
    patch -p1 < ../../syslinux-gcc10-muldefs.patch

    make -j$(nproc) efi64
    cd ../..
    
    echo "=== Building UEFI64 ==="
    sudo ./buildUEFI64
    
    echo "=== Building rescue image ==="
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

# Find binaries
BINFILES=$(find . -type f \( -name 'sedutil-cli' -o -name 'linuxpba' \) 2>/dev/null || true)
if [ -n "$BINFILES" ]; then
    echo "Found binaries:"
    echo "$BINFILES"
    for f in $BINFILES; do
        cp "$f" .ci_artifacts/
    done
else
    echo "WARNING: No sedutil binaries found"
fi

# Find rescue images
IMGFILES=$(find images -type f -name '*Rescue*64*.img.gz' 2>/dev/null || true)
if [ -n "$IMGFILES" ]; then
    echo "Found rescue images:"
    echo "$IMGFILES"
    for f in $IMGFILES; do
        cp "$f" .ci_artifacts/
    done
else
    echo "WARNING: No rescue images found"
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

