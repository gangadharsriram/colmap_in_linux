#!/bin/bash

#===============================================================================
# COLMAP Auto-Installation Script for Linux
#
# Features:
# - Auto-detects Linux distribution and version
# - Auto-detects CUDA installation and version
# - Auto-detects system resources (CPU cores, memory)
# - Installs to ~/colmap (no sudo for installation, only for dependencies)
# - CLI only (no GUI)
# - Stops and reports if CUDA issues are detected
#===============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Installation directory
INSTALL_DIR="$HOME/colmap"
BUILD_DIR="$HOME/colmap_build"
SOURCE_DIR="$HOME/colmap_source"

#===============================================================================
# Logging Functions
#===============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

#===============================================================================
# System Detection Functions
#===============================================================================

detect_os() {
    log_section "Detecting Operating System"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-$ID}"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS_NAME="$DISTRIB_ID"
        OS_ID="$(echo $DISTRIB_ID | tr '[:upper:]' '[:lower:]')"
        OS_VERSION="$DISTRIB_RELEASE"
        OS_CODENAME="$DISTRIB_CODENAME"
        OS_ID_LIKE="$OS_ID"
    else
        log_error "Cannot detect Linux distribution"
        log_error "This script requires /etc/os-release or /etc/lsb-release"
        exit 1
    fi

    # Detect package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="sudo apt-get update"
        PKG_INSTALL="sudo apt-get install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="sudo dnf check-update || true"
        PKG_INSTALL="sudo dnf install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="sudo yum check-update || true"
        PKG_INSTALL="sudo yum install -y"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_UPDATE="sudo pacman -Sy"
        PKG_INSTALL="sudo pacman -S --noconfirm"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="sudo zypper refresh"
        PKG_INSTALL="sudo zypper install -y"
    else
        log_error "No supported package manager found (apt, dnf, yum, pacman, zypper)"
        exit 1
    fi

    log_info "Distribution: $OS_NAME"
    log_info "Version: $OS_VERSION ($OS_CODENAME)"
    log_info "Base: $OS_ID_LIKE"
    log_info "Package Manager: $PKG_MANAGER"
}

detect_architecture() {
    log_section "Detecting System Architecture"

    ARCH=$(uname -m)

    case $ARCH in
        x86_64)
            log_info "Architecture: x86_64 (64-bit)"
            ;;
        aarch64|arm64)
            log_info "Architecture: ARM64"
            log_warning "ARM64 may have limited CUDA support"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

detect_system_resources() {
    log_section "Detecting System Resources"

    # CPU cores
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)

    # Memory in GB
    if [ -f /proc/meminfo ]; then
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    else
        TOTAL_MEM_GB=8  # Default assumption
    fi

    # Calculate optimal build parallelism (use N-1 cores, max based on memory)
    # Each compile job can use ~2GB RAM
    MAX_JOBS_BY_MEM=$((TOTAL_MEM_GB / 2))
    MAX_JOBS_BY_CPU=$((CPU_CORES > 1 ? CPU_CORES - 1 : 1))

    if [ $MAX_JOBS_BY_MEM -lt $MAX_JOBS_BY_CPU ]; then
        BUILD_JOBS=$MAX_JOBS_BY_MEM
    else
        BUILD_JOBS=$MAX_JOBS_BY_CPU
    fi

    # Minimum 1 job
    BUILD_JOBS=$((BUILD_JOBS > 0 ? BUILD_JOBS : 1))

    log_info "CPU Cores: $CPU_CORES"
    log_info "Total Memory: ${TOTAL_MEM_GB}GB"
    log_info "Build Parallelism: $BUILD_JOBS jobs"
}

detect_cuda() {
    log_section "Detecting CUDA Installation"

    CUDA_AVAILABLE=false
    CUDA_VERSION=""
    CUDA_PATH=""
    NVCC_PATH=""

    # Check for nvcc in common locations
    NVCC_CANDIDATES=(
        "/usr/local/cuda/bin/nvcc"
        "/usr/bin/nvcc"
        "$(command -v nvcc 2>/dev/null || echo '')"
    )

    # Also check versioned CUDA installations
    for cuda_dir in /usr/local/cuda-*; do
        if [ -d "$cuda_dir" ] && [ -f "$cuda_dir/bin/nvcc" ]; then
            NVCC_CANDIDATES+=("$cuda_dir/bin/nvcc")
        fi
    done

    for nvcc in "${NVCC_CANDIDATES[@]}"; do
        if [ -n "$nvcc" ] && [ -x "$nvcc" ]; then
            NVCC_PATH="$nvcc"
            break
        fi
    done

    if [ -z "$NVCC_PATH" ]; then
        log_warning "CUDA nvcc compiler not found"
        log_info "COLMAP will be built without GPU support"
        return
    fi

    # Get CUDA version
    CUDA_VERSION_OUTPUT=$("$NVCC_PATH" --version 2>/dev/null || echo "")
    if [ -z "$CUDA_VERSION_OUTPUT" ]; then
        log_error "Found nvcc at $NVCC_PATH but cannot get version"
        log_error "Please check your CUDA installation"
        exit 1
    fi

    CUDA_VERSION=$(echo "$CUDA_VERSION_OUTPUT" | grep -oP 'release \K[0-9]+\.[0-9]+' || echo "")

    if [ -z "$CUDA_VERSION" ]; then
        log_error "Cannot parse CUDA version from nvcc output"
        log_error "Output was: $CUDA_VERSION_OUTPUT"
        exit 1
    fi

    CUDA_MAJOR=$(echo $CUDA_VERSION | cut -d. -f1)
    CUDA_MINOR=$(echo $CUDA_VERSION | cut -d. -f2)

    # Determine CUDA path from nvcc location
    CUDA_PATH=$(dirname $(dirname "$NVCC_PATH"))

    log_info "CUDA Version: $CUDA_VERSION"
    log_info "CUDA Path: $CUDA_PATH"
    log_info "NVCC Path: $NVCC_PATH"

    # Validate CUDA version (minimum 7.0 for COLMAP)
    if [ "$CUDA_MAJOR" -lt 7 ]; then
        log_error "CUDA version $CUDA_VERSION is too old"
        log_error "COLMAP requires CUDA 7.0 or higher"
        exit 1
    fi

    # Check for required CUDA libraries
    log_info "Checking CUDA libraries..."

    CUDA_LIB_PATH=""
    if [ -d "$CUDA_PATH/lib64" ]; then
        CUDA_LIB_PATH="$CUDA_PATH/lib64"
    elif [ -d "$CUDA_PATH/lib" ]; then
        CUDA_LIB_PATH="$CUDA_PATH/lib"
    fi

    if [ -z "$CUDA_LIB_PATH" ]; then
        log_error "CUDA library directory not found in $CUDA_PATH"
        exit 1
    fi

    # Check for essential CUDA libraries
    REQUIRED_LIBS=("libcudart" "libcublas" "libcurand")
    MISSING_LIBS=()

    for lib in "${REQUIRED_LIBS[@]}"; do
        if ! ls "$CUDA_LIB_PATH"/${lib}* &>/dev/null; then
            MISSING_LIBS+=("$lib")
        fi
    done

    if [ ${#MISSING_LIBS[@]} -gt 0 ]; then
        log_error "Missing CUDA libraries: ${MISSING_LIBS[*]}"
        log_error "Please install the complete CUDA toolkit"
        exit 1
    fi

    # Check for NVIDIA driver
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi not found - NVIDIA driver may not be installed"
        exit 1
    fi

    NVIDIA_DRIVER_OUTPUT=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "")
    if [ -z "$NVIDIA_DRIVER_OUTPUT" ]; then
        log_error "Cannot query NVIDIA driver - no GPU detected or driver issue"
        exit 1
    fi

    log_info "NVIDIA Driver: $NVIDIA_DRIVER_OUTPUT"

    # Check GPU compute capability
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
    log_info "GPU: $GPU_NAME"

    CUDA_AVAILABLE=true
    log_success "CUDA is properly configured"
}

detect_existing_installation() {
    log_section "Checking for Existing Installation"

    if [ -d "$INSTALL_DIR" ]; then
        log_warning "Existing installation found at $INSTALL_DIR"
        log_info "It will be replaced during installation"
    fi

    if [ -d "$SOURCE_DIR" ]; then
        log_warning "Existing source directory found at $SOURCE_DIR"
        log_info "It will be removed and re-cloned"
    fi

    if [ -d "$BUILD_DIR" ]; then
        log_warning "Existing build directory found at $BUILD_DIR"
        log_info "It will be cleaned"
    fi
}

#===============================================================================
# Dependency Installation Functions
#===============================================================================

install_dependencies_apt() {
    log_section "Installing Dependencies (APT)"

    $PKG_UPDATE

    # Core build tools
    PACKAGES=(
        "git"
        "cmake"
        "ninja-build"
        "build-essential"
    )

    # Boost libraries
    PACKAGES+=(
        "libboost-program-options-dev"
        "libboost-filesystem-dev"
        "libboost-graph-dev"
        "libboost-system-dev"
        "libboost-iostreams-dev"
        "libboost-test-dev"
    )

    # Other dependencies
    PACKAGES+=(
        "libeigen3-dev"
        "libflann-dev"
        "libfreeimage-dev"
        "libmetis-dev"
        "libgoogle-glog-dev"
        "libgtest-dev"
        "libgmock-dev"
        "libsqlite3-dev"
        "libglew-dev"
        "libcgal-dev"
    )

    # Ceres Solver
    PACKAGES+=(
        "libatlas-base-dev"
        "libsuitesparse-dev"
        "libceres-dev"
    )

    # GCC version handling for CUDA on Ubuntu 22.04
    if [ "$CUDA_AVAILABLE" = true ] && [ "$OS_VERSION" = "22.04" ]; then
        PACKAGES+=("gcc-10" "g++-10")
        USE_GCC_10=true
    else
        USE_GCC_10=false
    fi

    log_info "Installing packages: ${PACKAGES[*]}"
    $PKG_INSTALL "${PACKAGES[@]}"

    log_success "Dependencies installed successfully"
}

install_dependencies_dnf() {
    log_section "Installing Dependencies (DNF/YUM)"

    $PKG_UPDATE

    # Enable PowerTools/CRB for some dependencies
    if command -v dnf &>/dev/null; then
        sudo dnf install -y epel-release || true
        sudo dnf config-manager --set-enabled crb || \
        sudo dnf config-manager --set-enabled powertools || true
    fi

    PACKAGES=(
        "git"
        "cmake"
        "ninja-build"
        "gcc"
        "gcc-c++"
        "boost-devel"
        "eigen3-devel"
        "flann-devel"
        "freeimage-devel"
        "metis-devel"
        "glog-devel"
        "gtest-devel"
        "gmock-devel"
        "sqlite-devel"
        "glew-devel"
        "CGAL-devel"
        "atlas-devel"
        "suitesparse-devel"
        "ceres-solver-devel"
    )

    log_info "Installing packages: ${PACKAGES[*]}"
    $PKG_INSTALL "${PACKAGES[@]}" || {
        log_warning "Some packages may not be available, continuing..."
    }

    USE_GCC_10=false
    log_success "Dependencies installed"
}

install_dependencies_pacman() {
    log_section "Installing Dependencies (Pacman)"

    $PKG_UPDATE

    PACKAGES=(
        "git"
        "cmake"
        "ninja"
        "base-devel"
        "boost"
        "eigen"
        "flann"
        "freeimage"
        "metis"
        "glog"
        "gtest"
        "sqlite"
        "glew"
        "cgal"
        "suitesparse"
        "ceres-solver"
    )

    log_info "Installing packages: ${PACKAGES[*]}"
    $PKG_INSTALL "${PACKAGES[@]}"

    USE_GCC_10=false
    log_success "Dependencies installed successfully"
}

install_dependencies_zypper() {
    log_section "Installing Dependencies (Zypper)"

    $PKG_UPDATE

    PACKAGES=(
        "git"
        "cmake"
        "ninja"
        "gcc"
        "gcc-c++"
        "boost-devel"
        "eigen3-devel"
        "flann-devel"
        "freeimage-devel"
        "metis-devel"
        "glog-devel"
        "gtest"
        "sqlite3-devel"
        "glew-devel"
        "cgal-devel"
        "suitesparse-devel"
    )

    log_info "Installing packages: ${PACKAGES[*]}"
    $PKG_INSTALL "${PACKAGES[@]}" || {
        log_warning "Some packages may not be available, continuing..."
    }

    USE_GCC_10=false
    log_success "Dependencies installed"
}

install_dependencies() {
    case $PKG_MANAGER in
        apt)
            install_dependencies_apt
            ;;
        dnf|yum)
            install_dependencies_dnf
            ;;
        pacman)
            install_dependencies_pacman
            ;;
        zypper)
            install_dependencies_zypper
            ;;
        *)
            log_error "Unsupported package manager: $PKG_MANAGER"
            exit 1
            ;;
    esac
}

#===============================================================================
# Build Functions
#===============================================================================

clone_colmap() {
    log_section "Cloning COLMAP Repository"

    # Remove existing source directory
    if [ -d "$SOURCE_DIR" ]; then
        log_info "Removing existing source directory..."
        rm -rf "$SOURCE_DIR"
    fi

    log_info "Cloning from https://github.com/colmap/colmap..."
    git clone https://github.com/colmap/colmap.git "$SOURCE_DIR"

    cd "$SOURCE_DIR"

    # Get latest release tag
    LATEST_TAG=$(git describe --tags $(git rev-list --tags --max-count=1) 2>/dev/null || echo "")

    if [ -n "$LATEST_TAG" ]; then
        log_info "Checking out latest release: $LATEST_TAG"
        git checkout "$LATEST_TAG"
    else
        log_warning "No release tags found, using main branch"
    fi

    log_success "Repository cloned successfully"
}

build_colmap() {
    log_section "Building COLMAP"

    # Create build directory
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Clean any previous build
    rm -rf "$BUILD_DIR"/*

    # Prepare CMake arguments
    CMAKE_ARGS=(
        "-GNinja"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_INSTALL_PREFIX=$INSTALL_DIR"
        "-DGUI_ENABLED=OFF"
    )

    # CUDA configuration
    if [ "$CUDA_AVAILABLE" = true ]; then
        log_info "Configuring with CUDA support"
        CMAKE_ARGS+=(
            "-DCUDA_ENABLED=ON"
            "-DCMAKE_CUDA_ARCHITECTURES=all"
        )

        if [ -n "$CUDA_PATH" ]; then
            CMAKE_ARGS+=("-DCMAKE_CUDA_COMPILER=$NVCC_PATH")
        fi

        # Use GCC 10 on Ubuntu 22.04 with CUDA
        if [ "${USE_GCC_10:-false}" = true ]; then
            log_info "Using GCC 10 for CUDA compatibility"
            CMAKE_ARGS+=(
                "-DCMAKE_C_COMPILER=/usr/bin/gcc-10"
                "-DCMAKE_CXX_COMPILER=/usr/bin/g++-10"
            )
        fi
    else
        log_info "Configuring without CUDA support"
        CMAKE_ARGS+=("-DCUDA_ENABLED=OFF")
    fi

    # Run CMake configuration
    log_info "Running CMake configuration..."
    log_info "CMake args: ${CMAKE_ARGS[*]}"

    cmake "${CMAKE_ARGS[@]}" "$SOURCE_DIR"

    if [ $? -ne 0 ]; then
        log_error "CMake configuration failed"
        exit 1
    fi

    log_success "CMake configuration complete"

    # Build
    log_info "Building with $BUILD_JOBS parallel jobs..."
    log_info "This may take 10-30 minutes depending on your system"

    ninja -j$BUILD_JOBS

    if [ $? -ne 0 ]; then
        log_error "Build failed"
        exit 1
    fi

    log_success "Build complete"
}

install_colmap() {
    log_section "Installing COLMAP"

    cd "$BUILD_DIR"

    # Remove existing installation
    if [ -d "$INSTALL_DIR" ]; then
        log_info "Removing existing installation..."
        rm -rf "$INSTALL_DIR"
    fi

    # Create installation directory
    mkdir -p "$INSTALL_DIR"

    # Install
    ninja install

    if [ $? -ne 0 ]; then
        log_error "Installation failed"
        exit 1
    fi

    log_success "COLMAP installed to $INSTALL_DIR"
}

setup_environment() {
    log_section "Setting Up Environment"

    # Determine shell configuration file
    SHELL_NAME=$(basename "$SHELL")
    case $SHELL_NAME in
        bash)
            SHELL_RC="$HOME/.bashrc"
            ;;
        zsh)
            SHELL_RC="$HOME/.zshrc"
            ;;
        *)
            SHELL_RC="$HOME/.profile"
            ;;
    esac

    # PATH export line
    EXPORT_LINE="export PATH=\"$INSTALL_DIR/bin:\$PATH\""

    # Check if already added
    if grep -qF "$INSTALL_DIR/bin" "$SHELL_RC" 2>/dev/null; then
        log_info "PATH already configured in $SHELL_RC"
    else
        log_info "Adding COLMAP to PATH in $SHELL_RC"
        echo "" >> "$SHELL_RC"
        echo "# COLMAP" >> "$SHELL_RC"
        echo "$EXPORT_LINE" >> "$SHELL_RC"
    fi

    # Add CUDA library path if needed
    if [ "$CUDA_AVAILABLE" = true ] && [ -n "$CUDA_LIB_PATH" ]; then
        LD_EXPORT="export LD_LIBRARY_PATH=\"$CUDA_LIB_PATH:\$LD_LIBRARY_PATH\""
        if ! grep -qF "$CUDA_LIB_PATH" "$SHELL_RC" 2>/dev/null; then
            echo "$LD_EXPORT" >> "$SHELL_RC"
        fi
    fi

    log_success "Environment configured"
    log_info "Run 'source $SHELL_RC' or start a new terminal to use COLMAP"
}

cleanup() {
    log_section "Cleanup"

    log_info "Removing build directory..."
    rm -rf "$BUILD_DIR"

    log_info "Source code kept at: $SOURCE_DIR"
    log_info "(You can delete it manually if not needed)"

    log_success "Cleanup complete"
}

verify_installation() {
    log_section "Verifying Installation"

    # Temporarily add to PATH for verification
    export PATH="$INSTALL_DIR/bin:$PATH"

    if [ "$CUDA_AVAILABLE" = true ] && [ -n "$CUDA_LIB_PATH" ]; then
        export LD_LIBRARY_PATH="$CUDA_LIB_PATH:$LD_LIBRARY_PATH"
    fi

    if command -v colmap &>/dev/null; then
        log_success "COLMAP is accessible"

        # Get version
        COLMAP_VERSION=$(colmap --version 2>&1 | head -1 || echo "Unknown")
        log_info "Version: $COLMAP_VERSION"

        # Check CUDA support in build
        if colmap --help 2>&1 | grep -qi "gpu\|cuda"; then
            log_success "GPU/CUDA support detected in COLMAP"
        elif [ "$CUDA_AVAILABLE" = true ]; then
            log_warning "CUDA was available but may not be enabled in COLMAP build"
        fi
    else
        log_error "COLMAP command not found after installation"
        exit 1
    fi
}

print_summary() {
    log_section "Installation Summary"

    echo -e "${GREEN}COLMAP has been successfully installed!${NC}"
    echo ""
    echo "Installation Details:"
    echo "  - Install Location: $INSTALL_DIR"
    echo "  - Binary: $INSTALL_DIR/bin/colmap"
    echo "  - CUDA Support: $( [ "$CUDA_AVAILABLE" = true ] && echo "Yes" || echo "No" )"
    echo "  - GUI Support: No (CLI only)"
    echo ""
    echo "To start using COLMAP:"
    echo "  1. Run: source ~/.bashrc  (or start a new terminal)"
    echo "  2. Test: colmap --help"
    echo ""
    echo "Quick Start Commands:"
    echo "  colmap feature_extractor --database_path db.db --image_path ./images"
    echo "  colmap exhaustive_matcher --database_path db.db"
    echo "  colmap mapper --database_path db.db --image_path ./images --output_path ./sparse"
    echo ""
    log_success "Installation complete!"
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           COLMAP Auto-Installation Script                     ║${NC}"
    echo -e "${CYAN}║           CLI Only | Home Directory Install                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Detection phase
    detect_os
    detect_architecture
    detect_system_resources
    detect_cuda
    detect_existing_installation

    # Print configuration summary
    log_section "Configuration Summary"
    echo "  OS: $OS_NAME $OS_VERSION"
    echo "  Package Manager: $PKG_MANAGER"
    echo "  Architecture: $ARCH"
    echo "  CPU Cores: $CPU_CORES"
    echo "  Memory: ${TOTAL_MEM_GB}GB"
    echo "  CUDA: $( [ "$CUDA_AVAILABLE" = true ] && echo "$CUDA_VERSION" || echo "Not available" )"
    echo "  Install Directory: $INSTALL_DIR"
    echo "  Build Jobs: $BUILD_JOBS"
    echo ""

    # Installation phase
    install_dependencies
    clone_colmap
    build_colmap
    install_colmap
    setup_environment
    cleanup
    verify_installation
    print_summary
}

# Run main function
main "$@"
