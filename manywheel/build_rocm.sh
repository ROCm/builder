#!/usr/bin/env bash

set -ex

export ROCM_HOME=/opt/rocm
export MAGMA_HOME=$ROCM_HOME/magma
# TODO: libtorch_cpu.so is broken when building with Debug info
export BUILD_DEBUG_INFO=0

# TODO Are these all used/needed?
export TH_BINARY_BUILD=1
export USE_STATIC_CUDNN=1
export USE_STATIC_NCCL=1
export ATEN_STATIC_CUDA=1
export USE_CUDA_STATIC_LINK=1
export INSTALL_TEST=0 # dont install test binaries into site-packages
# Set RPATH instead of RUNPATH when using patchelf to avoid LD_LIBRARY_PATH override
export FORCE_RPATH="--force-rpath"

# Keep an array of cmake variables to add to
if [[ -z "$CMAKE_ARGS" ]]; then
    # These are passed to tools/build_pytorch_libs.sh::build()
    CMAKE_ARGS=()
fi
if [[ -z "$EXTRA_CAFFE2_CMAKE_FLAGS" ]]; then
    # These are passed to tools/build_pytorch_libs.sh::build_caffe2()
    EXTRA_CAFFE2_CMAKE_FLAGS=()
fi

# Determine ROCm version and architectures to build for
#
# NOTE: We should first check `DESIRED_CUDA` when determining `ROCM_VERSION`
if [[ -n "$DESIRED_CUDA" ]]; then
    if ! echo "${DESIRED_CUDA}"| grep "^rocm" >/dev/null 2>/dev/null; then
        export DESIRED_CUDA="rocm${DESIRED_CUDA}"
    fi
    # rocm3.7, rocm3.5.1
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
        PYTORCH_FINAL_PACKAGE_DIR="/remote/wheelhouse$ROCM_VERSION"
    else
        PYTORCH_FINAL_PACKAGE_DIR="/remote/libtorch_house$ROCM_VERSION"
    fi
fi
mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true

# To make version comparison easier, create an integer representation.
ROCM_VERSION_CLEAN=$(echo ${ROCM_VERSION} | sed s/rocm//)
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
ROCM_VERSION_WITH_PATCH=rocm${ROCM_VERSION_MAJOR}.${ROCM_VERSION_MINOR}.${ROCM_VERSION_PATCH}
ROCM_INT=$(($ROCM_VERSION_MAJOR * 10000 + $ROCM_VERSION_MINOR * 100 + $ROCM_VERSION_PATCH))

# Required ROCm libraries
LIGHTWEIGHT_ROCM_SO_FILES=(
    # Minimal set for lightweight
    "libmagma.so"
)

HEAVYWEIGHT_ROCM_SO_FILES=(
    # Full set for heavyweight
    "libMIOpen.so"
    "libamdhip64.so"
    "libhipblas.so"
    "libhipblaslt.so"
    "libhipfft.so"
    "libhiprand.so"
    "libhipsolver.so"
    "libhipsparse.so"
    "libhsa-runtime64.so"
    "libhiprtc.so"
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
if [[ $ROCM_INT -ge 60100 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocprofiler-register.so")
fi
if [[ $ROCM_INT -ge 60200 ]]; then
    HEAVYWEIGHT_ROCM_SO_FILES+=("librocm-core.so")
fi

# Select which set of ROCm libraries to use
if [[ "$BUILD_LIGHTWEIGHT" == "1" ]]; then
    ROCM_SO_FILES=( "${LIGHTWEIGHT_ROCM_SO_FILES[@]}" )
fi

if [[ "$BUILD_HEAVYWEIGHT" == "1" ]]; then
    ROCM_SO_FILES=( "${HEAVYWEIGHT_ROCM_SO_FILES[@]}" )
fi


OS_NAME=`awk -F= '/^NAME/{print $2}' /etc/os-release`
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
        # Below libs are direct dependencies of libhipsolver
        LIBSUITESPARSE_CONFIG_PATH="/lib64/libsuitesparseconfig.so.4"
        if [[ "$OS_NAME" == *"CentOS Linux"* ]]; then
            LIBCHOLMOD_PATH="/lib64/libcholmod.so.2"
            # Below libs are direct dependencies of libsatlas
            LIBGFORTRAN_PATH="/lib64/libgfortran.so.3"
        else
            LIBCHOLMOD_PATH="/lib64/libcholmod.so.3"
            # Below libs are direct dependencies of libsatlas
            LIBGFORTRAN_PATH="/lib64/libgfortran.so.5"
        fi
            # Below libs are direct dependencies of libcholmod
            LIBAMD_PATH="/lib64/libamd.so.2"
            LIBCAMD_PATH="/lib64/libcamd.so.2"
            LIBCCOLAMD_PATH="/lib64/libccolamd.so.2"
            LIBCOLAMD_PATH="/lib64/libcolamd.so.2"
            LIBSATLAS_PATH="/lib64/atlas/libsatlas.so.3"
            # Below libs are direct dependencies of libsatlas
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
        # Below libs are direct dependencies of libhipsolver
        LIBCHOLMOD_PATH="/lib/x86_64-linux-gnu/libcholmod.so.3"
        # Below libs are direct dependencies of libcholmod
        LIBSUITESPARSE_CONFIG_PATH="/lib/x86_64-linux-gnu/libsuitesparseconfig.so.5"
        LIBAMD_PATH="/lib/x86_64-linux-gnu/libamd.so.2"
        LIBCAMD_PATH="/lib/x86_64-linux-gnu/libcamd.so.2"
        LIBCCOLAMD_PATH="/lib/x86_64-linux-gnu/libccolamd.so.2"
        LIBCOLAMD_PATH="/lib/x86_64-linux-gnu/libcolamd.so.2"
        LIBMETIS_PATH="/lib/x86_64-linux-gnu/libmetis.so.5"
        LIBLAPACK_PATH="/lib/x86_64-linux-gnu/liblapack.so.3"
        LIBBLAS_PATH="/lib/x86_64-linux-gnu/libblas.so.3"
        # Below libs are direct dependencies of libblas
        LIBGFORTRAN_PATH="/lib/x86_64-linux-gnu/libgfortran.so.5"
        LIBQUADMATH_PATH="/lib/x86_64-linux-gnu/libquadmath.so.0"
    fi
    MAYBE_LIB64=lib
fi
OS_SO_PATHS=($LIBGOMP_PATH $LIBNUMA_PATH\
             $LIBELF_PATH $LIBTINFO_PATH\
             $LIBDRM_PATH $LIBDRM_AMDGPU_PATH\
             $LIBSUITESPARSE_CONFIG_PATH\
             $LIBCHOLMOD_PATH $LIBAMD_PATH\
             $LIBCAMD_PATH $LIBCCOLAMD_PATH\
             $LIBCOLAMD_PATH $LIBSATLAS_PATH\
             $LIBGFORTRAN_PATH $LIBQUADMATH_PATH\
             $LIBMETIS_PATH $LIBLAPACK_PATH\
             $LIBBLAS_PATH)
OS_SO_FILES=()
for lib in "${OS_SO_PATHS[@]}"
do
    file_name="${lib##*/}" # Substring removal of path to get filename
    OS_SO_FILES[${#OS_SO_FILES[@]}]=$file_name # Append lib to array
done

# rocBLAS library files
ROCBLAS_LIB_SRC=$ROCM_HOME/lib/rocblas/library
ROCBLAS_LIB_DST=lib/rocblas/library
ARCH=$(echo $PYTORCH_ROCM_ARCH | sed 's/;/|/g') # Replace ; seperated arch list to bar for grep
ARCH_SPECIFIC_FILES=$(ls $ROCBLAS_LIB_SRC | grep -E $ARCH)
OTHER_FILES=$(ls $ROCBLAS_LIB_SRC | grep -v gfx)
ROCBLAS_LIB_FILES=($ARCH_SPECIFIC_FILES $OTHER_FILES)

# hipblaslt library files
HIPBLASLT_LIB_SRC=$ROCM_HOME/lib/hipblaslt/library
HIPBLASLT_LIB_DST=lib/hipblaslt/library
ARCH_SPECIFIC_FILES=$(ls $HIPBLASLT_LIB_SRC | grep -E $ARCH)
OTHER_FILES=$(ls $HIPBLASLT_LIB_SRC | grep -v gfx)
HIPBLASLT_LIB_FILES=($ARCH_SPECIFIC_FILES $OTHER_FILES)

# ROCm library files
# Overwrite ROCM_SO_FILES to contain only libmagma.so if BUILD_LIGHTWEIGHT is enabled
if [[ "$BUILD_LIGHTWEIGHT" == "1" ]]; then
    LIGHTWEIGHT_ROCM_SO_FILES=(
        "libmagma.so"
    )
fi

do_lightweight_build() {
    echo "=== Building LIGHTWEIGHT variant ==="

    # First, gather actual file paths for the minimal set
    ROCM_SO_PATHS_LIGHTWEIGHT=()
    for lib in "${LIGHTWEIGHT_ROCM_SO_FILES[@]}"; do
        file_path="$(find "$ROCM_HOME/lib" -name "$lib" 2>/dev/null | head -n1)"
        if [[ -z $file_path && -d "$ROCM_HOME/lib64" ]]; then
            file_path="$(find "$ROCM_HOME/lib64" -name "$lib" 2>/dev/null | head -n1)"
        fi
        if [[ -z $file_path ]]; then
            file_path="$(find "$ROCM_HOME" -name "$lib" 2>/dev/null | head -n1)"
        fi
        if [[ -z $file_path ]]; then
            echo "Error: Lightweight library $lib is not found." >&2
            exit 1
        fi
        ROCM_SO_PATHS_LIGHTWEIGHT+=("$file_path")
    done

    # Set environment so build_common.sh (or build_libtorch.sh) sees it
    DEPS_LIST=( "${ROCM_SO_PATHS_LIGHTWEIGHT[*}" )
    DEPS_SONAME=( "${LIGHTWEIGHT_ROCM_SO_FILES[*]}" )
    DEPS_AUX_SRCLIST=()
    DEPS_AUX_DSTLIST=()

    # Because original script doesn't add OS libraries or arch-specific .co
    # files for "lightweight", we skip them here

    # Finally, source the main build script
    SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
    if [[ -z "$BUILD_PYTHONLESS" ]]; then
        BUILD_SCRIPT=build_common.sh
    else
        BUILD_SCRIPT=build_libtorch.sh
    fi
    source "$SCRIPTPATH/${BUILD_SCRIPT}"

    echo "=== Done building LIGHTWEIGHT variant ==="
}

# 2) HEAVYWEIGHT BUILD
do_heavyweight_build() {
    echo "=== Building HEAVYWEIGHT variant ==="

    # Gather file paths for the full set
    ROCM_SO_PATHS_HEAVYWEIGHT=()
    for lib in "${HEAVYWEIGHT_ROCM_SO_FILES[@]}"; do
        file_path="$(find "$ROCM_HOME/lib" -name "$lib" 2>/dev/null | head -n1)"
        if [[ -z $file_path && -d "$ROCM_HOME/lib64" ]]; then
            file_path="$(find "$ROCM_HOME/lib64" -name "$lib" 2>/dev/null | head -n1)"
        fi
        if [[ -z $file_path ]]; then
            file_path="$(find "$ROCM_HOME" -name "$lib" 2>/dev/null | head -n1)"
        fi
        if [[ -z $file_path ]]; then
            echo "Error: Heavyweight library $lib not found." >&2
            exit 1
        fi
        ROCM_SO_PATHS_HEAVYWEIGHT+=("$file_path")
    done

    # Add OS libraries
    DEPS_LIST=( "${ROCM_SO_PATHS_HEAVYWEIGHT[@]}" "${OS_SO_PATHS[*]}" )
    DEPS_SONAME=( "${HEAVYWEIGHT_ROCM_SO_FILES[@]}" "${OS_SO_FILES[*]}" )

    # Add architecture-specific files
    DEPS_AUX_SRCLIST=(
        "${ROCBLAS_LIB_FILES[@]/#/$ROCBLAS_LIB_SRC/}"
        "${HIPBLASLT_LIB_FILES[@]/#/$HIPBLASLT_LIB_SRC/}"
        "/opt/amdgpu/share/libdrm/amdgpu.ids"
    )
    DEPS_AUX_DSTLIST=(
        "${ROCBLAS_LIB_FILES[@]/#/$ROCBLAS_LIB_DST/}"
        "${HIPBLASLT_LIB_FILES[@]/#/$HIPBLASLT_LIB_DST/}"
        "share/libdrm/amdgpu.ids"
    )

    # Finally, source the main build script
    SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
    if [[ -z "$BUILD_PYTHONLESS" ]]; then
        BUILD_SCRIPT=build_common.sh
    else
        BUILD_SCRIPT=build_libtorch.sh
    fi
    source "$SCRIPTPATH/${BUILD_SCRIPT}"

    echo "=== Done building HEAVYWEIGHT variant ==="
}

################################################################################
# Helper for version comparison
################################################################################

ver() {
    # Convert dotted version string "x.y.z" into zero-padded numeric for comparison
    printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ')
}

# Add triton install dependency
# No triton dependency till pytorch 2.3 on 3.12
# since torch.compile doesn't work.
PYTORCH_VERSION=$(cat $PYTORCH_ROOT/version.txt | grep -oP "[0-9]+\.[0-9]+\.[0-9]+")
# Assuming PYTORCH_VERSION=x.y.z, if x >= 2
if [ ${PYTORCH_VERSION%%\.*} -ge 2 ]; then
    if [[ $(uname) == "Linux" ]] && [[ "$DESIRED_PYTHON" != "3.12" || $(ver $PYTORCH_VERSION) -ge $(ver 2.4) ]]; then
	# Triton commit got unified in PyTorch 2.5
	if [[ $(ver $PYTORCH_VERSION) -ge $(ver 2.5) ]]; then
            TRITON_SHORTHASH=$(cut -c1-8 $PYTORCH_ROOT/.ci/docker/ci_commit_pins/triton.txt)
	else
            TRITON_SHORTHASH=$(cut -c1-8 $PYTORCH_ROOT/.ci/docker/ci_commit_pins/triton-rocm.txt)
	fi
        TRITON_VERSION=$(cat $PYTORCH_ROOT/.ci/docker/triton_version.txt)
	# Only linux Python < 3.13 are supported wheels for triton
	TRITON_CONSTRAINT="platform_system == 'Linux' and platform_machine == 'x86_64'$(if [[ $(ver "$PYTORCH_VERSION") -le $(ver "2.5") ]]; then echo " and python_version < '3.13'"; fi)"

        if [[ -z "$PYTORCH_EXTRA_INSTALL_REQUIREMENTS" ]]; then
            export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="pytorch-triton-rocm==${TRITON_VERSION}+${ROCM_VERSION_WITH_PATCH}.git${TRITON_SHORTHASH}; ${TRITON_CONSTRAINT}"
        else
            export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="${PYTORCH_EXTRA_INSTALL_REQUIREMENTS} | pytorch-triton-rocm==${TRITON_VERSION}+${ROCM_VERSION_WITH_PATCH}.git${TRITON_SHORTHASH}; ${TRITON_CONSTRAINT}"
        fi
    fi
fi


echo "PYTORCH_ROCM_ARCH: ${PYTORCH_ROCM_ARCH}"

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
if [[ -z "$BUILD_PYTHONLESS" ]]; then
    BUILD_SCRIPT=build_torch_wheel.sh	
fi
source $SCRIPTPATH/${BUILD_SCRIPT}
if [[ "$BUILD_LIGHTWEIGHT" == "1" ]]; then
    do_lightweight_build
fi

if [[ "$BUILD_HEAVYWEIGHT" == "1" ]]; then
    do_heavyweight_build
fi

