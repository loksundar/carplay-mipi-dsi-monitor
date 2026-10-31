FROM ubuntu:22.04
RUN apt-get update -qq && apt-get install -y -qq build-essential git liblzma-dev zlib1g-dev python3 >/dev/null
RUN cd /opt && git clone -q https://github.com/plougher/squashfs-tools.git && cd squashfs-tools && git checkout -q 31cd4d68c36531ed3a25c5fda583efcf03f4c0de
WORKDIR /opt/squashfs-tools/squashfs-tools
RUN perl -0pi -e 's/(unsigned int\s+s_magic;\n)\tunsigned int\t\tinodes;\n/$1/' squashfs_fs.h \
 && perl -0pi -e 's/(\tunsigned short\t\ts_minor;\n)(\tsquashfs_inode\t\troot_inode;)/$1\tunsigned int\t\tinodes;\n$2/' squashfs_fs.h \
 && grep -n -A14 'struct squashfs_super_block' squashfs_fs.h | head -16 \
 && sed -i 's/#XZ_SUPPORT/XZ_SUPPORT/' Makefile && make -j8 >/dev/null && cp mksquashfs unsquashfs /usr/local/bin/
WORKDIR /work
