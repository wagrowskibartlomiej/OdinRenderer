#!/usr/bin/env sh
set -e

odin build . \
  -define:BUILD_TARGET=PC \
  -define:VERBOSE_LOGGING=true \
  -define:TRACKING_ALLOCATOR=true \
  -define:BUILD_VARIANT=EDITOR \
  -debug

