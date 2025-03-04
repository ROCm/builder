#!/usr/bin/env bash

set -ex

################################################################################
# Environment variables and initial checks
################################################################################

export ROCM_HOME=/opt/rocm
export MAGMA_HOME="$ROCM_HOME/magma"

# TODO: libtorch_cpu.so is broken when building with Debug info
export BUILD_DEBUG_INFO=0

# These are used in PyTorch builds
export TH_BINARY_BUILD=1
export USE_STATIC_CUDNN=1
export USE_STATIC_NCCL=1
export ATEN_STATIC_CUDA=1
export USE_CUDA_STATIC_LINK=1
export INSTALL_TEST=0  # don't install test binaries into site-packages
# Set RPATH instead of RUNPATH when using patchelf to avoid LD_LIBRARY_PATH override
export FORCE_RPATH="--force-rpath"

# Keep an array of cmake variables to add to
if [[ -z "$CMAKE_ARGS" ]]; then
    # Passed to tools/build_pytorch_libs.sh::build()
    CMAKE_ARGS=()
fi
if [[ -z "$EXTRA_CAFFE2_CMAKE_FLAGS" ]]; then
    # Passed to tools/build_pytorch_libs.sh::build_caffe2()
    EXTRA_CAFFE2_CMAKE_FLAGS=()
fi

# Exactly one of BUILD_LIGHTWEIGHT or BUILD_HEAVYWEIGHT must be set
if [[ "$BUILD_LIGHTWEIGHT" == "1" && "$BUILD_HEAVYWEIGHT" == "1" ]]; then
    echo "Error: Both BUILD_LIGHTWEIGHT and BUILD_HEAVYWEIGHT are set. Choose only one."
    exit 1
elif [[ "$BUILD_LIGHTWEIGHT" != "1" && "$BUILD_HEAVYWEIGHT" != "1" ]]; then
    echo "Error: Neither BUILD_LIGHTWEIGHT nor BUILD_HEAVYWEIGHT is set. Must set exactly one."
    exit 1
fi

################################################################################
# Determine ROCm version and architectures to build for
################################################################################

if [[ -n "$DESIRED_CUDA" ]]; then
    if ! echo "${DESIRED_CUDA}" | grep "^rocm" >/dev/null 2>/dev/null; then
        export DESIRED_CUDA="rocm${DESIRED_CUDA}"
    fi
    # e.g., rocm3.7, rocm3.5.1
    ROCM_VERSION="$DESIRED_CUDA"
    echo "Using $ROCM_VERSION as determined by DESIRED_CUDA"
else
    echo "Must set DESIRED_CUDA"
    exit 1
fi

# Package directories
WHEELHOUSE_DIR="wheelhouse$ROCM_VERSION"
LIBTORCH_HOUSE_DIR="libtorch_house$ROCM_VERSION"
if [[ -z "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
    if [[ -z "$BUILD_PYTHONLESS" ]]; then
        PYTORCH_FINAL_PACKAGE_DIR="/remote/$WHEELHOUSE_DIR"
    else
        PYTORCH_FINAL_PACKAGE_DIR="/remote/$LIBTORCH_HOUSE_DIR"
    fi
fi
mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true

# Parse ROCM_VERSION into major.minor.patch and integer form
ROCM_VERSION_CLEAN=$(echo "${ROCM_VERSION}" | sed s/rocm//)
save_IFS="$IFS"
IFS=. ROCM_VERSION_ARRAY=(${ROCM_VERSION_CLEAN})
IFS="$save_IFS"

if [[ ${#ROCM_VERSION_ARRAY[@]} == 2 ]]; then
    ROCM_VERSION_MAJOR=${ROCM_VERSION_ARRAY[0]}
    ROCM_VERSION_MINOR=${ROCM_VERSION_ARRAY[1]}
    ROCM_VERSION_PATCH=0
elif [[ ${#ROCM_VERSION_ARRAY[@]} == 3 ]]; then
    ROCM_VERSION_MAJOR=${ROCM_VERSION_ARRAY[0]}
    ROCM_VERSION_MINOR=${ROCM_VERSION_ARRAY[1]}
    ROCM_VERSION_PATCH=${ROCM_VERSION_ARRAY[2]}
else
    echo "Unhandled ROCM_VERSION ${ROCM_VERSION}"
    exit 1
fi

ROCM_VERSION_WITH_PATCH="rocm${ROCM_VERSION_MAJOR}.${ROCM_VERSION_MINOR}.${ROCM_VERSION_PATCH}"
ROCM_INT=$((ROCM_VERSION_MAJOR * 10000 + ROCM_VERSION_MINOR * 100 + ROCM_VERSION_PATCH))

################################################################################
# Define LIGHTWEIGHT vs HEAVYWEIGHT ROCm .so libraries
################################################################################

LIGHTWEIGHT_ROCM_SO_FILES=(
    # Minimal set for lightweight
    "libmagma.so"
)

HEAVYWEIGHT_ROCM_SO_FILES=(
    # Full set for heavyweight
    "libMIOpen.so"
    "libamdhip64.so"
    "libhipblas.so"
    "libhipfft.so"
    "libhiprand.so"
    "libhipsolver.so"
    "libhipsparse.so"
    "libhsa-runtime64.so"
    "libamd_comgr.so"
    "libmagma.so"
    "librccl.so"
    "librocblas.so"
    "librocfft.so"
    "librocm_smi64.so"
    "librocrand.so"
    "librocsolver.so"
    "librocsparse.so"
    "libroctracer64.so"
    "libroctx64.so"
)

# Adjust list based on ROCm version
if [[ $ROCM_INT -ge 50600 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("libhipblaslt.so")
fi
if [[ $ROCM_INT -lt 50500 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocfft-device-0.so")
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocfft-device-1.so")
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocfft-device-2.so")
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocfft-device-3.so")
fi
if [[ $ROCM_INT -ge 50400 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("libhiprtc.so")
fi
if [[ $ROCM_INT -ge 60100 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocprofiler-register.so")
fi
if [[ $ROCM_INT -ge 60200 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocm-core.so")
fi

# Select which set of ROCm libraries to use
if [[ "$BUILD_LIGHTWEIGHT" == "1" ]]; then
    ROCM_SO_FILES=( "${LIGHTWEIGHT_ROCM_SO_FILES[@]}" )
else
    # Must be BUILD_HEAVYWEIGHT=1
    ROCM_SO_FILES=( "${HEAVYWEIGHT_ROCM_SO_FILES[@]}" )
fi

################################################################################
# Detect OS and define OS-level libraries
################################################################################

OS_NAME="$(awk -F= '/^NAME/{print $2}' /etc/os-release)"
if [[ "$OS_NAME" == *"CentOS Linux"* || "$OS_NAME" == *"AlmaLinux"* ]]; then
    LIBGOMP_PATH="/usr/lib64/libgomp.so.1"
    LIBNUMA_PATH="/usr/lib64/libnuma.so.1"
    LIBELF_PATH="/usr/lib64/libelf.so.1"
    if [[ "$OS_NAME" == *"CentOS Linux"* ]]; then
        LIBTINFO_PATH="/usr/lib64/libtinfo.so.5"
    else
        LIBTINFO_PATH="/usr/lib64/libtinfo.so.6"
    fi
    LIBDRM_PATH="/opt/amdgpu/lib64/libdrm.so.2"
    LIBDRM_AMDGPU_PATH="/opt/amdgpu/lib64/libdrm_amdgpu.so.1"
    if [[ $ROCM_INT -ge 60100 && $ROCM_INT -lt 60300 ]]; then
        # Dependencies for libhipsolver
        LIBSUITESPARSE_CONFIG_PATH="/lib64/libsuitesparseconfig.so.4"
        if [[ "$OS_NAME" == *"CentOS Linux"* ]]; then
            LIBCHOLMOD_PATH="/lib64/libcholmod.so.2"
            # Dependencies for libsatlas
            LIBGFORTRAN_PATH="/lib64/libgfortran.so.3"
        else
            LIBCHOLMOD_PATH="/lib64/libcholmod.so.3"
            # Dependencies for libsatlas
            LIBGFORTRAN_PATH="/lib64/libgfortran.so.5"
        fi
        LIBAMD_PATH="/lib64/libamd.so.2"
        LIBCAMD_PATH="/lib64/libcamd.so.2"
        LIBCCOLAMD_PATH="/lib64/libccolamd.so.2"
        LIBCOLAMD_PATH="/lib64/libcolamd.so.2"
        LIBSATLAS_PATH="/lib64/atlas/libsatlas.so.3"
        LIBQUADMATH_PATH="/lib64/libquadmath.so.0"
    fi
    MAYBE_LIB64=lib64
elif [[ "$OS_NAME" == *"Ubuntu"* ]]; then
    LIBGOMP_PATH="/usr/lib/x86_64-linux-gnu/libgomp.so.1"
    LIBNUMA_PATH="/usr/lib/x86_64-linux-gnu/libnuma.so.1"
    LIBELF_PATH="/usr/lib/x86_64-linux-gnu/libelf.so.1"
    if [[ $ROCM_INT -ge 50300 ]]; then
        LIBTINFO_PATH="/lib/x86_64-linux-gnu/libtinfo.so.6"
    else
        LIBTINFO_PATH="/lib/x86_64-linux-gnu/libtinfo.so.5"
    fi
    LIBDRM_PATH="/usr/lib/x86_64-linux-gnu/libdrm.so.2"
    LIBDRM_AMDGPU_PATH="/usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1"
    if [[ $ROCM_INT -ge 60100 && $ROCM_INT -lt 60300 ]]; then
        LIBCHOLMOD_PATH="/lib/x86_64-linux-gnu/libcholmod.so.3"
        LIBSUITESPARSE_CONFIG_PATH="/lib/x86_64-linux-gnu/libsuitesparseconfig.so.5"
        LIBAMD_PATH="/lib/x86_64-linux-gnu/libamd.so.2"
        LIBCAMD_PATH="/lib/x86_64-linux-gnu/libcamd.so.2"
        LIBCCOLAMD_PATH="/lib/x86_64-linux-gnu/libccolamd.so.2"
        LIBCOLAMD_PATH="/lib/x86_64-linux-gnu/libcolamd.so.2"
        LIBMETIS_PATH="/lib/x86_64-linux-gnu/libmetis.so.5"
        LIBLAPACK_PATH="/lib/x86_64-linux-gnu/liblapack.so.3"
        LIBBLAS_PATH="/lib/x86_64-linux-gnu/libblas.so.3"
        LIBGFORTRAN_PATH="/lib/x86_64-linux-gnu/libgfortran.so.5"
        LIBQUADMATH_PATH="/lib/x86_64-linux-gnu/libquadmath.so.0"
    fi
    MAYBE_LIB64=lib
fi

# Convert them to "OS_SO_FILES" array for convenience
OS_SO_PATHS=(
    "$LIBGOMP_PATH" "$LIBNUMA_PATH" "$LIBELF_PATH" "$LIBTINFO_PATH"
    "$LIBDRM_PATH" "$LIBDRM_AMDGPU_PATH" "$LIBSUITESPARSE_CONFIG_PATH"
    "$LIBCHOLMOD_PATH" "$LIBAMD_PATH" "$LIBCAMD_PATH" "$LIBCCOLAMD_PATH"
    "$LIBCOLAMD_PATH" "$LIBSATLAS_PATH" "$LIBGFORTRAN_PATH"
    "$LIBQUADMATH_PATH" "$LIBMETIS_PATH" "$LIBLAPACK_PATH" "$LIBBLAS_PATH"
)

OS_SO_FILES=()
for lib in "${OS_SO_PATHS[@]}"; do
    file_name="${lib##*/}"  # strip path to get filename
    OS_SO_FILES+=("$file_name")
done

################################################################################
# rocBLAS library files (for copying arch-specific libs)
################################################################################

if [[ $ROCM_INT -ge 50200 ]]; then
    ROCBLAS_LIB_SRC="$ROCM_HOME/lib/rocblas/library"
    ROCBLAS_LIB_DST="lib/rocblas/library"
else
    ROCBLAS_LIB_SRC="$ROCM_HOME/rocblas/lib/library"
    ROCBLAS_LIB_DST="lib/library"
fi

ARCH=$(echo "$PYTORCH_ROCM_ARCH" | sed 's/;/|/g')  # e.g. gfx906;gfx908 => "gfx906|gfx908"
ARCH_SPECIFIC_FILES=$(ls "$ROCBLAS_LIB_SRC" | grep -E "$ARCH" || true)
OTHER_FILES=$(ls "$ROCBLAS_LIB_SRC" | grep -v gfx || true)
ROCBLAS_LIB_FILES=($ARCH_SPECIFIC_FILES $OTHER_FILES)

################################################################################
# hipBLASLt library files
################################################################################

HIPBLASLT_LIB_SRC="$ROCM_HOME/lib/hipblaslt/library"
HIPBLASLT_LIB_DST="lib/hipblaslt/library"
if [[ -d "$HIPBLASLT_LIB_SRC" ]]; then
    HIPBLASLT_ARCH_SPECIFIC_FILES=$(ls "$HIPBLASLT_LIB_SRC" | grep -E "$ARCH" || true)
    HIPBLASLT_OTHER_FILES=$(ls "$HIPBLASLT_LIB_SRC" | grep -v gfx || true)
    HIPBLASLT_LIB_FILES=($HIPBLASLT_ARCH_SPECIFIC_FILES $HIPBLASLT_OTHER_FILES)
else
    HIPBLASLT_LIB_FILES=()
fi

################################################################################
# Build final list of ROCm shared libraries (ROCM_SO_FILES were chosen above)
# Then find them on the filesystem
################################################################################

ROCM_SO_PATHS=()
for lib in "${ROCM_SO_FILES[@]}"; do
    file_path=($(find "$ROCM_HOME/lib/" -name "$lib"))
    if [[ -z $file_path && -d "$ROCM_HOME/lib64/" ]]; then
        file_path=($(find "$ROCM_HOME/lib64/" -name "$lib"))
    fi
    if [[ -z $file_path ]]; then
        file_path=($(find "$ROCM_HOME/" -name "$lib"))
    fi
    if [[ -z $file_path ]]; then
        echo "Error: Library file $lib is not found." >&2
        exit 1
    fi
    ROCM_SO_PATHS+=("$file_path")
done

################################################################################
# Build DEPS lists (the dynamic libraries we want to package).
# If BUILD_LIGHTWEIGHT=1, we typically exclude OS libs to keep minimal, etc.
################################################################################

DEPS_LIST=("${ROCM_SO_PATHS[@]}")
DEPS_SONAME=("${ROCM_SO_FILES[@]}")

DEPS_AUX_SRCLIST=()
DEPS_AUX_DSTLIST=()

# If building "lightweight," one might skip many additional dependencies...
if [[ "$BUILD_LIGHTWEIGHT" != "1" ]]; then

    # Add OS libraries
    DEPS_LIST+=("${OS_SO_PATHS[@]}")
    DEPS_SONAME+=("${OS_SO_FILES[@]}")

    # Add rocblas library files
    for f in "${ROCBLAS_LIB_FILES[@]}"; do
        DEPS_AUX_SRCLIST+=("$ROCBLAS_LIB_SRC/$f")
        DEPS_AUX_DSTLIST+=("$ROCBLAS_LIB_DST/$f")
    done

    # Add hipblaslt library files (if any exist)
    for f in "${HIPBLASLT_LIB_FILES[@]}"; do
        DEPS_AUX_SRCLIST+=("$HIPBLASLT_LIB_SRC/$f")
        DEPS_AUX_DSTLIST+=("$HIPBLASLT_LIB_DST/$f")
    done

    # Some additional logic for MIOpen, RCCL, etc. based on ROCm versions
    if [[ $ROCM_INT -ge 50500 ]]; then
        # MIOpen shared data files
        MIOPEN_SHARE_SRC="$ROCM_HOME/share/miopen/db"
        MIOPEN_SHARE_DST="share/miopen/db"
        if [[ -d "$MIOPEN_SHARE_SRC" ]]; then
            MIOPEN_SHARE_FILES=($(ls "$MIOPEN_SHARE_SRC"))
            for f in "${MIOPEN_SHARE_FILES[@]}"; do
                DEPS_AUX_SRCLIST+=("$MIOPEN_SHARE_SRC/$f")
                DEPS_AUX_DSTLIST+=("$MIOPEN_SHARE_DST/$f")
            done
        fi
    fi

    if [[ $ROCM_INT -ge 50600 ]]; then
        # RCCL shared data files
        if [[ $ROCM_INT -ge 50700 ]]; then
            RCCL_SHARE_SRC="$ROCM_HOME/share/rccl/msccl-algorithms"
            RCCL_SHARE_DST="share/rccl/msccl-algorithms"
        else
            RCCL_SHARE_SRC="$ROCM_HOME/lib/msccl-algorithms"
            RCCL_SHARE_DST="lib/msccl-algorithms"
        fi
        if [[ -d "$RCCL_SHARE_SRC" ]]; then
            RCCL_SHARE_FILES=($(ls "$RCCL_SHARE_SRC"))
            for f in "${RCCL_SHARE_FILES[@]}"; do
                DEPS_AUX_SRCLIST+=("$RCCL_SHARE_SRC/$f")
                DEPS_AUX_DSTLIST+=("$RCCL_SHARE_DST/$f")
            done
        fi
    fi
fi

################################################################################
# Helper for version comparison
################################################################################

ver() {
    # Convert dotted version string "x.y.z" into zero-padded numeric for comparison
    printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ')
}

################################################################################
# Possibly add Triton install dependency
################################################################################

PYTORCH_VERSION=$(cat "$PYTORCH_ROOT/version.txt" | grep -oP "[0-9]+\.[0-9]+\.[0-9]+")
if [[ "${PYTORCH_VERSION%%.*}" -ge 2 ]]; then
    # e.g., for PyTorch 2.x
    if [[ $(uname) == "Linux" ]] && [[ "$DESIRED_PYTHON" != "3.12" || $(ver "$PYTORCH_VERSION") -ge $(ver 2.4) ]]; then
        # For PyTorch 2.5 and above, unify the Triton commit
        if [[ $(ver "$PYTORCH_VERSION") -ge $(ver 2.5) ]]; then
            TRITON_SHORTHASH=$(cut -c1-8 "$PYTORCH_ROOT/.ci/docker/ci_commit_pins/triton.txt")
        else
            TRITON_SHORTHASH=$(cut -c1-8 "$PYTORCH_ROOT/.ci/docker/ci_commit_pins/triton-rocm.txt")
        fi
        TRITON_VERSION=$(cat "$PYTORCH_ROOT/.ci/docker/triton_version.txt")
        TRITON_CONSTRAINT="platform_system == 'Linux' and platform_machine == 'x86_64'"
        if [[ $(ver "$PYTORCH_VERSION") -le $(ver "2.5") ]]; then
            # Restrict to python < 3.13 for older versions
            TRITON_CONSTRAINT="${TRITON_CONSTRAINT} and python_version < '3.13'"
        fi

        if [[ -z "$PYTORCH_EXTRA_INSTALL_REQUIREMENTS" ]]; then
            export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="pytorch-triton-rocm==${TRITON_VERSION}+${ROCM_VERSION_WITH_PATCH}.git${TRITON_SHORTHASH}; ${TRITON_CONSTRAINT}"
        else
            export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="${PYTORCH_EXTRA_INSTALL_REQUIREMENTS} | pytorch-triton-rocm==${TRITON_VERSION}+${ROCM_VERSION_WITH_PATCH}.git${TRITON_SHORTHASH}; ${TRITON_CONSTRAINT}"
        fi
    fi
fi

################################################################################
# Final: print arch and source the main build script
################################################################################

echo "PYTORCH_ROCM_ARCH: ${PYTORCH_ROCM_ARCH}"

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

if [[ -z "$BUILD_PYTHONLESS" ]]; then
    BUILD_SCRIPT="build_common.sh"
else
    BUILD_SCRIPT="build_libtorch.sh"
fi

source "$SCRIPTPATH/$BUILD_SCRIPT"
