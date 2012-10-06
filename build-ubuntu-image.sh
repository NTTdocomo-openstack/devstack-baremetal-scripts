#!/bin/sh

IMG=$1
CACHE_DIR=$2

SRC_URL=http://cloud-images.ubuntu.com/precise/current/precise-server-cloudimg-amd64-root.tar.gz
SRC_CACHE=$CACHE_DIR/precise-server-cloudimg-amd64-root.tar.gz

if ! [ -f "$IMG" ]; then
    exit 0
fi

if ! [ -f "$SRC_CACHE" ]; then
    wget "$SRC_URL" -O - > "$SRC_CACHE"
fi

dd if=/dev/zero of="$IMG" bs=1M count=0 seek=1024
mkfs -F -t ext4 "$IMG"
MNT_DIR=`mktemp -d`
sudo mount -o loop "$IMG" "${MNT_DIR}"
sudo tar -C "${MNT_DIR}" -xzf "$SRC_CACHE"
sudo mv "${MNT_DIR}/etc/resolv.conf" "${MNT_DIR}/etc/resolv.conf_orig"
sudo cp /etc/resolv.conf "${MNT_DIR}/etc/resolv.conf"
sudo chroot "${MNT_DIR}" apt-get -y install linux-image-3.2.0-26-generic vlan open-iscsi
sudo mv "${MNT_DIR}/etc/resolv.conf_orig" "${MNT_DIR}/etc/resolv.conf"
sudo cp "${MNT_DIR}/boot/vmlinuz-3.2.0-26-generic" "$CACHE_DIR/kernel"
sudo chmod a+r "$CACHE_DIR/kernel"
cp "${MNT_DIR}/boot/initrd.img-3.2.0-26-generic" "$CACHE_DIR/initrd"
sudo umount "${MNT_DIR}"
