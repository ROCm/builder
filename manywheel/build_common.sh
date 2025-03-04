#!/usr/bin/env bash
# meant to be called only from the neighboring build.sh and build_cpu.sh scripts

set -ex
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

for pkg in /$WHEELHOUSE_DIR/torch_no_python*.whl /$WHEELHOUSE_DIR/torch*linux*.whl /$LIBTORCH_HOUSE_DIR/libtorch*.zip; do

    # if the glob didn't match anything
    if [[ ! -e $pkg ]]; then
        continue
    fi

    rm -rf tmp
    mkdir -p tmp
    cd tmp
    cp $pkg .

    unzip -q $(basename $pkg)
    rm -f $(basename $pkg)

    if [[ -d torch ]]; then
        PREFIX=torch
    else
        PREFIX=libtorch
    fi

    if [[ $pkg != *"without-deps"* ]]; then
        # copy over needed dependent .so files over and tag them with their hash
        patched=()
        for filepath in "${DEPS_LIST[@]}"; do
            filename=$(basename $filepath)
            destpath=$PREFIX/lib/$filename
            if [[ "$filepath" != "$destpath" ]]; then
                cp $filepath $destpath
            fi

            # ROCm workaround for roctracer dlopens
            if [[ "$DESIRED_CUDA" == *"rocm"* ]]; then
                patchedpath=$(fname_without_so_number $destpath)
            else
                patchedpath=$(fname_with_sha256 $destpath)
            fi
            patchedname=$(basename $patchedpath)
            if [[ "$destpath" != "$patchedpath" ]]; then
                mv $destpath $patchedpath
            fi
            patched+=("$patchedname")
            echo "Copied $filepath to $patchedpath"
        done

        echo "patching to fix the so names to the hashed names"
        for ((i=0;i<${#DEPS_LIST[@]};++i)); do
            replace_needed_sofiles $PREFIX ${DEPS_SONAME[i]} ${patched[i]}
            # do the same for caffe2, if it exists
            if [[ -d caffe2 ]]; then
                replace_needed_sofiles caffe2 ${DEPS_SONAME[i]} ${patched[i]}
            fi
        done

        # copy over needed auxiliary files
        for ((i=0;i<${#DEPS_AUX_SRCLIST[@]};++i)); do
            srcpath=${DEPS_AUX_SRCLIST[i]}
            dstpath=$PREFIX/${DEPS_AUX_DSTLIST[i]}
            mkdir -p $(dirname $dstpath)
            cp $srcpath $dstpath
        done
    fi

    # set RPATH of _C.so and similar to $ORIGIN, $ORIGIN/lib
    find $PREFIX -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to ${C_SO_RPATH:-'$ORIGIN:$ORIGIN/lib'}"
        $PATCHELF_BIN --set-rpath ${C_SO_RPATH:-'$ORIGIN:$ORIGIN/lib'} ${FORCE_RPATH:-} $sofile
        $PATCHELF_BIN --print-rpath $sofile
    done

    # set RPATH of lib/ files to $ORIGIN
    find $PREFIX/lib -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to ${LIB_SO_RPATH:-'$ORIGIN'}"
        $PATCHELF_BIN --set-rpath ${LIB_SO_RPATH:-'$ORIGIN'} ${FORCE_RPATH:-} $sofile
        $PATCHELF_BIN --print-rpath $sofile
    done

    # regenerate the RECORD file with new hashes
    record_file=$(echo $(basename $pkg) | sed -e 's/-cp.*$/.dist-info\/RECORD/g')
    if [[ -e $record_file ]]; then
        echo "Generating new record file $record_file"
        : > "$record_file"
        # generate records for folders in wheel
        find * -type f | while read fname; do
            make_wheel_record "$fname" >>"$record_file"
        done
    fi

    if [[ $BUILD_DEBUG_INFO == "1" ]]; then
        pushd "$PREFIX/lib"

        # Duplicate library into debug lib
        cp libtorch_cpu.so libtorch_cpu.so.dbg

        # Keep debug symbols on debug lib
        strip --only-keep-debug libtorch_cpu.so.dbg

        # Remove debug info from release lib
        strip --strip-debug libtorch_cpu.so

        objcopy libtorch_cpu.so --add-gnu-debuglink=libtorch_cpu.so.dbg

        # Zip up debug info
        mkdir -p /tmp/debug
        mv libtorch_cpu.so.dbg /tmp/debug/libtorch_cpu.so.dbg
        CRC32=$(objcopy --dump-section .gnu_debuglink=>(tail -c4 | od -t x4 -An | xargs echo) libtorch_cpu.so)

        pushd /tmp
        PKG_NAME=$(basename "$pkg" | sed 's/\.whl$//g')
        zip /tmp/debug-whl-libtorch-"$PKG_NAME"-"$CRC32".zip /tmp/debug/libtorch_cpu.so.dbg
        cp /tmp/debug-whl-libtorch-"$PKG_NAME"-"$CRC32".zip "$PYTORCH_FINAL_PACKAGE_DIR"
        popd

        popd
    fi

    # zip up the wheel back
    zip -rq $(basename $pkg) $PREIX*

    # replace original wheel
    rm -f $pkg
    mv $(basename $pkg) $pkg
    cd ..
    rm -rf tmp
done

# Copy wheels to host machine for persistence before testing
if [[ -n "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
    mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true
    if [[ -n "$BUILD_PYTHONLESS" ]]; then
        cp /$LIBTORCH_HOUSE_DIR/libtorch*.zip "$PYTORCH_FINAL_PACKAGE_DIR"
    else
        cp /$WHEELHOUSE_DIR/torch*.whl "$PYTORCH_FINAL_PACKAGE_DIR"
    fi
fi

# remove stuff before testing
rm -rf /opt/rh
if ls /usr/local/cuda* >/dev/null 2>&1; then
    rm -rf /usr/local/cuda*
fi


# Test that all the wheels work
if [[ -z "$BUILD_PYTHONLESS" ]]; then
  export OMP_NUM_THREADS=4 # on NUMA machines this takes too long
  pushd $PYTORCH_ROOT/test

  # Install the wheel for this Python version
  if [[ "$USE_SPLIT_BUILD" == "true" ]]; then
    pip uninstall -y "$TORCH_NO_PYTHON_PACKAGE_NAME" || true
  fi

  pip uninstall -y "$TORCH_PACKAGE_NAME"
  
  if [[ "$USE_SPLIT_BUILD" == "true" ]]; then
    pip install "$TORCH_NO_PYTHON_PACKAGE_NAME" --no-index -f /$WHEELHOUSE_DIR --no-dependencies -v
  fi
  
  pip install "$TORCH_PACKAGE_NAME" --no-index -f /$WHEELHOUSE_DIR --no-dependencies -v

  # Print info on the libraries installed in this wheel
  # Rather than adjust find command to skip non-library files with an embedded *.so* in their name,
  # since this is only for reporting purposes, we add the || true to the ldd command.
  installed_libraries=($(find "$pydir/lib/python${py_majmin}/site-packages/torch/" -name '*.so*'))
  echo "The wheel installed all of the libraries: ${installed_libraries[@]}"
  for installed_lib in "${installed_libraries[@]}"; do
      ldd "$installed_lib" || true
  done

  # Run the tests
  echo "$(date) :: Running tests"
  pushd "$PYTORCH_ROOT"
  LD_LIBRARY_PATH=/usr/local/nvidia/lib64 \
          "${SOURCE_DIR}/../run_tests.sh" manywheel "${py_majmin}" "$DESIRED_CUDA"
  popd
  echo "$(date) :: Finished tests"
fi
