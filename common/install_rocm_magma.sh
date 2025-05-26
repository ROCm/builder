#!/bin/bash

# TODO upstream differences from this file is into the (eventual) one in pytorch
# - (1) check for static lib mkl
# - (2) MKLROOT as env var

set -ex

# Magma build scripts need `python`
ln -sf /usr/bin/python3 /usr/bin/python

ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
case "$ID" in
  almalinux)
    yum install -y gcc-gfortran
    ;;
  *)
    echo "No preinstalls to build magma..."
    ;;
esac

# TODO (2)
MKLROOT=${MKLROOT:-/opt/intel}

# "install" hipMAGMA into /opt/rocm/magma by copying after build
git clone https://github.com/ROCm/utk-magma.git -b release/2.9.0_rocm70 magma
pushd magma
# version 2.9 + ROCm 7.0 related updates
git checkout 91c4f720a17e842b364e9de41edeef76995eb9ad

cp make.inc-examples/make.inc.hip-gcc-mkl make.inc
echo 'LIBDIR += -L$(MKLROOT)/lib' >> make.inc
# TODO (1)
if [[ -f "${MKLROOT}/lib/libmkl_core.a" ]]; then
    echo 'LIB = -Wl,--start-group -lmkl_gf_lp64 -lmkl_gnu_thread -lmkl_core -Wl,--end-group -lpthread -lstdc++ -lm -lgomp -lhipblas -lhipsparse' >> make.inc
fi
echo 'LIB += -Wl,--enable-new-dtags -Wl,--rpath,/opt/rocm/lib -Wl,--rpath,$(MKLROOT)/lib -Wl,--rpath,/opt/rocm/magma/lib -ldl' >> make.inc
echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' >> make.inc
export PATH="${PATH}:/opt/rocm/bin"
if [[ -n "$PYTORCH_ROCM_ARCH" ]]; then
  amdgpu_targets=`echo $PYTORCH_ROCM_ARCH | sed 's/;/ /g'`
else
  amdgpu_targets=`rocm_agent_enumerator | grep -v gfx000 | sort -u | xargs`
fi
for arch in $amdgpu_targets; do
  echo "DEVCCFLAGS += --offload-arch=$arch" >> make.inc
done
# hipcc with openmp flag may cause isnan() on __device__ not to be found; depending on context, compiler may attempt to match with host definition
sed -i 's/^FOPENMP/#FOPENMP/g' make.inc
make -f make.gen.hipMAGMA -j $(nproc)
LANG=C.UTF-8 make lib/libmagma.so -j $(nproc) MKLROOT="${MKLROOT}"
make testing/testing_dgemm -j $(nproc) MKLROOT="${MKLROOT}"
popd
mkdir -p /opt/rocm/magma
mv magma/include /opt/rocm/magma
mv magma/lib /opt/rocm/magma
rm -rf magma

