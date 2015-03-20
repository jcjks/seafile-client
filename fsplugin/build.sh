#!/bin/bash

set -x
set -e

PWD=$(dirname "${BASH_SOURCE[0]}")

if [ "$(uname -s)" != "Darwin" ]; then
  echo "don't run it if you are not using Mac OS X"
  exit -1
fi

export CC=$(xcrun -f clang)
export CXX=$(xcrun -f clang)
unset CFLAGS CXXFLAGS LDFLAGS

pushd $PWD
rm -rf CMakeCache.txt CMakeFiles
cmake -G Xcode -DCMAKE_BUILD_TYPE=Release
xcodebuild clean
xcodebuild -jobs "$(sysctl -n hw.ncpu)" -configuration Release
popd

