#!/bin/bash

# This file uninstalls RCCL and install specific RCCL 2.12 version

set -ex

# Disable SDMA by default
export HSA_ENABLE_SDMA=0

# Config the RCCL IB relaxed ordering
export NCCL_IB_PCI_RELAXED_ORDERING=1
export NCCL_NET_GDR_LEVEL=3

# clean up dependencies no longer needed for RCCL 2.12
cd / && find /usr -name librccl-net.so* | xargs rm -rf

#install cmake 3.8 version
ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
case "$ID" in
  ubuntu)
    apt update -y
    ;;
  centos)
    yum autoremove -y cmake
    yum update -y
    rpm -e --nodeps rccl rccl-devel
    yum -y install gcc gcc-c++ wget make vim perl-core pcre-devel zlib-devel
    wget https://ftp.openssl.org/source/openssl-1.1.1k.tar.gz
    tar -xzvf openssl-1.1.1k.tar.gz
    cd openssl-1.1.1k
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib no-shared zlib-dynamic
    make && make install
    cd ~
    wget https://cmake.org/files/v3.20/cmake-3.20.1.tar.gz
    tar -zxvf cmake-3.20.1.tar.gz
    cd cmake-3.20.1
    ./bootstrap
    make install
    cp -f ./bin/cmake ./bin/cpack ./bin/ctest /bin
    ;;
  *)
    echo "Unable to determine OS..."
    exit 1
    ;;
esac


cd ~ && git clone https://github.com/ROCmSoftwarePlatform/rccl.git
cd ~/rccl && git reset --hard 8c3c8b7 && ./install.sh -id && cd build/release && make package

ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
case "$ID" in
  ubuntu)
    apt purge ucx openmpi -y 
    dpkg -i *.deb
    ;;
  centos)
    yum autoremove -y ucx openmpi
    rpm -ivh *.rpm
    ;;
  *)
    echo "Unable to determine OS..."
    exit 1
    ;;
esac

