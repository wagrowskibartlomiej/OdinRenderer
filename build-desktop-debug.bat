@echo off
odin build . ^
  -define:BUILD_TARGET=PC ^
  -define:VERBOSE_LOGGING=true ^
  -define:TRACKING_ALLOCATOR=true ^
  -debug
