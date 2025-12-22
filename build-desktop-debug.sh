#!/usr/bin/env sh
set -e

odin build . \
  -define:DESKTOP_BUILD=true \
  -define:VERBOSE_LOG=true \
  -define:TRACKING_ALLOCATOR=true \
  -debug

