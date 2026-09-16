# Custom Trino image: the official release image with connector plugins rebuilt
# from the same release tag plus the patches that are still awaiting review
# upstream. See .audiense/README.md.
#
# The build context is assembled by .audiense/build.sh. plugins/ holds one
# directory per rebuilt connector, named as it is named under
# /usr/lib/trino/plugin in the official image.
#
# COPY merges into the existing plugin directory rather than replacing it, so a
# jar that the official build ships and ours does not would be left behind.
# build.sh compares both file lists and fails when that would happen, which keeps
# this Dockerfile free of RUN instructions: copying files needs no
# foreign-architecture emulation, so buildx produces every platform without qemu.

ARG BASE_TAG
FROM trinodb/trino:${BASE_TAG}

COPY --chown=trino:trino plugins/ /usr/lib/trino/plugin/
