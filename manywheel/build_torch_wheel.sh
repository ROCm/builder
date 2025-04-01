
# Require only one python installation
if [[ -z "$DESIRED_PYTHON" ]]; then
    echo "Need to set DESIRED_PYTHON env variable"
    exit 1
fi
if [[ -n "$BUILD_PYTHONLESS" && -z "$LIBTORCH_VARIANT" ]]; then
    echo "BUILD_PYTHONLESS is set, so need LIBTORCH_VARIANT to also be set"
    echo "LIBTORCH_VARIANT should be one of shared-with-deps shared-without-deps static-with-deps static-without-deps"
    exit 1
fi

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# TODO move this into the Docker images
OS_NAME=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
if [[ "$OS_NAME" == *"CentOS Linux"* ]]; then
    retry yum install -q -y zip openssl
elif [[ "$OS_NAME" == *"AlmaLinux"* ]]; then
    retry yum install -q -y zip openssl
elif [[ "$OS_NAME" == *"Red Hat Enterprise Linux"* ]]; then
    retry dnf install -q -y zip openssl
elif [[ "$OS_NAME" == *"Ubuntu"* ]]; then
    # TODO: Remove this once nvidia package repos are back online
    # Comment out nvidia repositories to prevent them from getting apt-get updated, see https://github.com/pytorch/pytorch/issues/74968
    # shellcheck disable=SC2046
    sed -i 's/.*nvidia.*/# &/' $(find /etc/apt/ -type f -name "*.list")

    retry apt-get update
    retry apt-get -y install zip openssl
fi

# We use the package name to test the package by passing this to 'pip install'
# This is the env variable that setup.py uses to name the package. Note that
# pip 'normalizes' the name first by changing all - to _
if [[ -z "$TORCH_PACKAGE_NAME" ]]; then
    TORCH_PACKAGE_NAME='torch'
fi

if [[ -z "$TORCH_NO_PYTHON_PACKAGE_NAME" ]]; then
    TORCH_NO_PYTHON_PACKAGE_NAME='torch_no_python'
fi

TORCH_PACKAGE_NAME="$(echo $TORCH_PACKAGE_NAME | tr '-' '_')"
TORCH_NO_PYTHON_PACKAGE_NAME="$(echo $TORCH_NO_PYTHON_PACKAGE_NAME | tr '-' '_')"
echo "Expecting the built wheels to all be called '$TORCH_PACKAGE_NAME' or '$TORCH_NO_PYTHON_PACKAGE_NAME'"

# Version: setup.py uses $PYTORCH_BUILD_VERSION.post$PYTORCH_BUILD_NUMBER if
# PYTORCH_BUILD_NUMBER > 1
build_version="$PYTORCH_BUILD_VERSION"
build_number="$PYTORCH_BUILD_NUMBER"
if [[ -n "$OVERRIDE_PACKAGE_VERSION" ]]; then
    # This will be the *exact* version, since build_number<1
    build_version="$OVERRIDE_PACKAGE_VERSION"
    build_number=0
fi
if [[ -z "$build_version" ]]; then
    build_version=1.0.0
fi
if [[ -z "$build_number" ]]; then
    build_number=1
fi
# TODO: Commenting for now so that the common wheel built does not have ".lw" in the name/version
#if [[ "$BUILD_LIGHTWEIGHT" == "1" ]]; then
#    build_version="${build_version}.lw"
#fi

if [[ -z "$PYTORCH_ROOT" ]]; then
    echo "Need to set PYTORCH_ROOT env variable"
    exit 1
fi
# Always append the pytorch commit to the build_version by querying Git
pushd "$PYTORCH_ROOT"
PYTORCH_COMMIT=$(git rev-parse HEAD)
popd

# Append the commit as a ".git<shortsha>" suffix
# This yields versions like: torch-2.5.0+rocm6.2.0.lw.gitabcd1234
short_commit=$(echo "$PYTORCH_COMMIT" | cut -c1-8)
build_version="${build_version}.git${short_commit}"

echo "Final build_version: $build_version"

export PYTORCH_BUILD_VERSION=$build_version
export PYTORCH_BUILD_NUMBER=$build_number

export CMAKE_LIBRARY_PATH="/opt/intel/lib:/lib:$CMAKE_LIBRARY_PATH"
export CMAKE_INCLUDE_PATH="/opt/intel/include:$CMAKE_INCLUDE_PATH"

if [[ -e /opt/openssl ]]; then
    export OPENSSL_ROOT_DIR=/opt/openssl
    export CMAKE_INCLUDE_PATH="/opt/openssl/include":$CMAKE_INCLUDE_PATH
fi

# If given a python version like 3.6m or 2.7mu, convert this to the format we
# expect. The binary CI jobs pass in python versions like this; they also only
# ever pass one python version, so we assume that DESIRED_PYTHON is not a list
# in this case
if [[ -n "$DESIRED_PYTHON" && "$DESIRED_PYTHON" != cp* ]]; then
    python_nodot="$(echo $DESIRED_PYTHON | tr -d m.u)"
    DESIRED_PYTHON="cp${python_nodot}-cp${python_nodot}"
fi

if [[ ${python_nodot} -ge 310 ]]; then
    py_majmin="${DESIRED_PYTHON:2:1}.${DESIRED_PYTHON:3:2}"
else
    py_majmin="${DESIRED_PYTHON:2:1}.${DESIRED_PYTHON:3:1}"
fi


pydir="/opt/python/$DESIRED_PYTHON"
export PATH="$pydir/bin:$PATH"
echo "Will build for Python version: ${DESIRED_PYTHON} with ${python_installation}"

mkdir -p /tmp/$WHEELHOUSE_DIR

export PATCHELF_BIN=/usr/local/bin/patchelf
patchelf_version=$($PATCHELF_BIN --version)
echo "patchelf version: " $patchelf_version
if [[ "$patchelf_version" == "patchelf 0.9" ]]; then
    echo "Your patchelf version is too old. Please use version >= 0.10."
    exit 1
fi

########################################################
# Compile wheels as well as libtorch
#######################################################

pushd "$PYTORCH_ROOT"
python setup.py clean
retry pip install -r requirements.txt
ver() {
    printf "%3d%03d%03d%03d" $(echo "$1" | tr '.' ' ');
}
case ${DESIRED_PYTHON} in
  cp38*)
    retry pip install -q numpy==1.15
    ;;
  cp31*)
    # CIRCLE_TAG contains the PyTorch version such as "1.13.0"
    if [[ $(ver ${CIRCLE_TAG}) -ge $(ver 2.4) ]]; then
      retry pip install -q --pre numpy==2.0.2
    else
      retry pip install -q "numpy<2.0.0"
    fi
    ;;
  # Should catch 3.9+
  *)
    if [[ $(ver ${CIRCLE_TAG}) -ge $(ver 2.4) ]]; then
      retry pip install -q --pre numpy==2.0.2
    else
      retry pip install -q "numpy<2.0.0"
    fi
    ;;
esac

# ROCm RHEL8 packages are built with cxx11 abi symbols
if [[ "$DESIRED_DEVTOOLSET" == *"cxx11-abi"* || "$DESIRED_CUDA" == *"rocm"* ]]; then
    export _GLIBCXX_USE_CXX11_ABI=1
else
    export _GLIBCXX_USE_CXX11_ABI=0
fi

if [[ "$DESIRED_CUDA" == *"rocm"* ]]; then
    echo "Calling build_amd.py at $(date)"
    python tools/amd_build/build_amd.py
fi

# This value comes from binary_linux_build.sh (and should only be set to true
# for master / release branches)
BUILD_DEBUG_INFO=${BUILD_DEBUG_INFO:=0}

if [[ $BUILD_DEBUG_INFO == "1" ]]; then
    echo "Building wheel and debug info"
else
    echo "BUILD_DEBUG_INFO was not set, skipping debug info"
fi

if [[ "$DISABLE_RCCL" = 1 ]]; then
    echo "Disabling NCCL/RCCL in pyTorch"
    USE_RCCL=0
    USE_NCCL=0
    USE_KINETO=0
else
    USE_RCCL=1
    USE_NCCL=1
    USE_KINETO=1
fi

echo "Calling setup.py bdist at $(date)"

if [[ "$USE_SPLIT_BUILD" == "true" ]]; then
    echo "Calling setup.py bdist_wheel for split build (BUILD_LIBTORCH_WHL)"
    time EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
    BUILD_LIBTORCH_WHL=1 BUILD_PYTHON_ONLY=0 \
    BUILD_LIBTORCH_CPU_WITH_DEBUG=$BUILD_DEBUG_INFO \
    USE_NCCL=${USE_NCCL} USE_RCCL=${USE_RCCL} USE_KINETO=${USE_KINETO} \
    python setup.py bdist_wheel -d /tmp/$WHEELHOUSE_DIR
    echo "Finished setup.py bdist_wheel for split build (BUILD_LIBTORCH_WHL)"
    echo "Calling setup.py bdist_wheel for split build (BUILD_PYTHON_ONLY)"
    time EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
    BUILD_LIBTORCH_WHL=0 BUILD_PYTHON_ONLY=1 \
    BUILD_LIBTORCH_CPU_WITH_DEBUG=$BUILD_DEBUG_INFO \
    USE_NCCL=${USE_NCCL} USE_RCCL=${USE_RCCL} USE_KINETO=${USE_KINETO} \
    python setup.py bdist_wheel -d /tmp/$WHEELHOUSE_DIR --cmake
    echo "Finished setup.py bdist_wheel for split build (BUILD_PYTHON_ONLY)"
else
    time CMAKE_ARGS=${CMAKE_ARGS[@]} \
        EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
        BUILD_LIBTORCH_CPU_WITH_DEBUG=$BUILD_DEBUG_INFO \
        USE_NCCL=${USE_NCCL} USE_RCCL=${USE_RCCL} USE_KINETO=${USE_KINETO} \
        python setup.py bdist_wheel -d /tmp/$WHEELHOUSE_DIR
fi
echo "Finished setup.py bdist at $(date)"

# Build libtorch packages
if [[ -n "$BUILD_PYTHONLESS" ]]; then
    # Now build pythonless libtorch
    # Note - just use whichever python we happen to be on
    python setup.py clean

    if [[ $LIBTORCH_VARIANT = *"static"* ]]; then
        STATIC_CMAKE_FLAG="-DTORCH_STATIC=1"
    fi

    mkdir -p build
    pushd build
    echo "Calling tools/build_libtorch.py at $(date)"
    time CMAKE_ARGS=${CMAKE_ARGS[@]} \
         EXTRA_CAFFE2_CMAKE_FLAGS="${EXTRA_CAFFE2_CMAKE_FLAGS[@]} $STATIC_CMAKE_FLAG" \
         python ../tools/build_libtorch.py
    echo "Finished tools/build_libtorch.py at $(date)"
    popd

    mkdir -p libtorch/{lib,bin,include,share}
    cp -r build/build/lib libtorch/

    # for now, the headers for the libtorch package will just be copied in
    # from one of the wheels (this is from when this script built multiple
    # wheels at once)
    ANY_WHEEL=$(ls /tmp/$WHEELHOUSE_DIR/torch*.whl | head -n1)
    unzip -d any_wheel $ANY_WHEEL
    if [[ -d any_wheel/torch/include ]]; then
        cp -r any_wheel/torch/include libtorch/
    else
        cp -r any_wheel/torch/lib/include libtorch/
    fi
    cp -r any_wheel/torch/share/cmake libtorch/share/
    rm -rf any_wheel

    echo $PYTORCH_BUILD_VERSION > libtorch/build-version
    echo "$(pushd $PYTORCH_ROOT && git rev-parse HEAD)" > libtorch/build-hash

    mkdir -p /tmp/$LIBTORCH_HOUSE_DIR

    if [[ "$DESIRED_DEVTOOLSET" == *"cxx11-abi"* ]]; then
        LIBTORCH_ABI="cxx11-abi-"
    else
        LIBTORCH_ABI=
    fi

    zip -rq /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-$PYTORCH_BUILD_VERSION.zip libtorch
    cp /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-$PYTORCH_BUILD_VERSION.zip \
       /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$LIBTORCH_ABI$LIBTORCH_VARIANT-latest.zip
fi
popd
echo 'Built this wheel:'
ls /tmp/$WHEELHOUSE_DIR
mkdir -p "/$WHEELHOUSE_DIR"
torch_wheel=$(ls /tmp/$WHEELHOUSE_DIR/torch*linux*.whl | head -n1)
# Place wheels in separate directories to distinguish them in build_common.sh
if [ "${BUILD_LIGHTWEIGHT}" == "1" ]; then
  mkdir -p "/${WHEELHOUSE_DIR}/${LIGHTWEIGHT_WHEELNAME_MARKER}/"
  cp $torch_wheel "/${WHEELHOUSE_DIR}/${LIGHTWEIGHT_WHEELNAME_MARKER}/"
fi
if [ "${BUILD_HEAVYWEIGHT}" == "1" ]; then
  cp $torch_wheel "/${WHEELHOUSE_DIR}/"
fi
rm $torch_wheel

if [[ "$USE_SPLIT_BUILD" == "true" ]]; then
    mv /tmp/$WHEELHOUSE_DIR/torch_no_python*.whl /$WHEELHOUSE_DIR/ || true
fi

if [[ -n "$BUILD_PYTHONLESS" ]]; then
    mkdir -p /$LIBTORCH_HOUSE_DIR
    mv /tmp/$LIBTORCH_HOUSE_DIR/*.zip /$LIBTORCH_HOUSE_DIR
    rm -rf /tmp/$LIBTORCH_HOUSE_DIR
fi
