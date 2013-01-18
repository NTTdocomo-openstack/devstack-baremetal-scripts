set -x

TOP_DIR=$(cd $(dirname "$0") && pwd)
source $TOP_DIR/stackrc
source $TOP_DIR/functions
DEST=${DEST:-/opt/stack}
source $TOP_DIR/openrc

NOVA_DIR=$DEST/nova
if [ -d $NOVA_DIR/bin ] ; then
    NOVA_BIN_DIR=$NOVA_DIR/bin
else
    NOVA_BIN_DIR=/usr/local/bin
fi
DATA_DIR=${DATA_DIR:-${DEST}/data}
NOVA_DATA_DIR=${NOVA_DATA_DIR:-${DATA_DIR}/nova}
MYSQL_USER=${MYSQL_USER:-root}
BM_PXE_INTERFACE=${BM_PXE_INTERFACE:-eth1}
BM_PXE_PER_NODE=`trueorfalse False $BM_PXE_PER_NODE`

# prevent vm instance types from going to bare-metal compute
for vmtype in `nova-manage instance_type list|cut -d : -f 1 |grep ^m1`; do
    nova-manage instance_type set_key --name=$vmtype --key hypervisor_type --value "s!= baremetal"
done

nova-manage instance_type create --name=baremetal.small --cpu=1 --memory=2048 --root_gb=10 --ephemeral_gb=20 --swap=1024 --rxtx_factor=1
nova-manage instance_type set_key --name=baremetal.small --key cpu_arch --value x86_64

nova-manage instance_type create --name=baremetal.medium --cpu=1 --memory=4096 --root_gb=10 --ephemeral_gb=20 --swap=1024 --rxtx_factor=1
nova-manage instance_type set_key --name=baremetal.medium --key cpu_arch --value x86_64

nova-manage instance_type create --name=baremetal.xlarge --cpu=8 --memory=16384 --root_gb=160 --ephemeral_gb=0 --swap=0 --rxtx_factor=1
nova-manage instance_type set_key --name=baremetal.xlarge --key cpu_arch --value x86_64

nova-manage instance_type create --name=baremetal.minimum --cpu=1 --memory=1 --root_gb=1 --ephemeral_gb=0 --swap=1 --rxtx_factor=1
nova-manage instance_type set_key --name=baremetal.minimum --key cpu_arch --value x86_64

apt_get install dnsmasq syslinux ipmitool qemu-kvm open-iscsi
apt_get install busybox tgt

BMIB_REPO=https://github.com/NTTdocomo-openstack/baremetal-initrd-builder.git
BMIB_DIR=$DEST/barematal-initrd-builder
BMIB_BRANCH=master
git_clone $BMIB_REPO $BMIB_DIR $BMIB_BRANCH

KERNEL_VER=`uname -r`
KERNEL_=/boot/vmlinuz-$KERNEL_VER
KERNEL=/tmp/deploy-kernel
sudo cp "$KERNEL_" "$KERNEL"
sudo chmod a+r "$KERNEL"
RAMDISK=/tmp/deploy-ramdisk.img

if [ ! -f "$RAMDISK" ]; then
(
	cd "$BMIB_DIR"
        ./baremetal-mkinitrd.sh "$RAMDISK" "$KERNEL_VER"
)
fi

GLANCE_HOSTPORT=${GLANCE_HOSTPORT:-$GLANCE_HOST:9292}

TOKEN=$(keystone  token-get | grep ' id ' | get_field 2)
KERNEL_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-deployment-kernel" --public --container-format aki --disk-format aki < "$KERNEL" | grep ' id ' | get_field 2)
echo "$KERNEL_ID"

RAMDISK_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-deployment-ramdisk" --public --container-format ari --disk-format ari < "$RAMDISK" | grep ' id ' | get_field 2)
echo "$RAMDISK_ID"

echo "building ubuntu image"
IMG=$DEST/ubuntu.img
./build-ubuntu-image.sh "$IMG" "$DEST"

REAL_KERNEL_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-real-kernel" --public --container-format aki --disk-format aki < "$DEST/kernel" | grep ' id ' | get_field 2)

REAL_RAMDISK_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-real-ramdisk" --public --container-format ari --disk-format ari < "$DEST/initrd" | grep ' id ' | get_field 2)

glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "Ubuntu" --public --container-format bare --disk-format raw --property kernel_id=$REAL_KERNEL_ID --property ramdisk_id=$REAL_RAMDISK_ID < "$IMG"

TFTPROOT=$DEST/tftproot

if [ -d "$TFTPROOT" ]; then
    rm -r "$TFTPROOT"
fi
mkdir "$TFTPROOT"
cp /usr/lib/syslinux/pxelinux.0 "$TFTPROOT"
mkdir $TFTPROOT/pxelinux.cfg

DNSMASQ_PID=/dnsmasq.pid
if [ -f "$DNSMASQ_PID" ]; then
    sudo kill `cat "$DNSMASQ_PID"`
    sudo rm "$DNSMASQ_PID"
fi
sudo /etc/init.d/dnsmasq stop
sudo sudo update-rc.d dnsmasq disable
if [ "$BM_PXE_PER_NODE" = "False" ]; then
    sudo dnsmasq --conf-file= --port=0 --enable-tftp --tftp-root=$TFTPROOT --dhcp-boot=pxelinux.0 --bind-interfaces --pid-file=$DNSMASQ_PID --interface=$BM_PXE_INTERFACE --dhcp-range=192.168.175.100,192.168.175.254
fi


mkdir -p $NOVA_DATA_DIR/baremetal/console
mkdir -p $NOVA_DATA_DIR/baremetal/dnsmasq

inicomment /etc/nova/nova.conf DEFAULT firewall_driver

function is() {
    iniset /etc/nova/nova.conf baremetal "$1" "$2"
}

iniset /etc/nova/nova.conf DEFAULT compute_driver nova.virt.baremetal.driver.BareMetalDriver
is sql_connection mysql://$MYSQL_USER:$MYSQL_PASSWORD@127.0.0.1/nova_bm
is driver nova.virt.baremetal.pxe.PXE
is power_manager nova.virt.baremetal.ipmi.IPMI
is instance_type_extra_specs cpu_arch:x86_64
is tftp_root $TFTPROOT
if [ -x /usr/local/bin/shellinaboxd ]; then
	is terminal /usr/local/bin/shellinaboxd
fi
is deploy_kernel $KERNEL_ID
is deploy_ramdisk $RAMDISK_ID
#is baremetal_pxe_vlan_per_host $BM_PXE_PER_NODE
#is baremetal_pxe_parent_interface $BM_PXE_INTERFACE

mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS nova_bm;'
mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE nova_bm CHARACTER SET latin1;'

# workaround for invalid compute_node that non-bare-metal nova-compute has left
mysql -u$MYSQL_USER -p$MYSQL_PASSWORD nova -e 'DELETE FROM compute_nodes;'

$NOVA_BIN_DIR/nova-baremetal-manage db sync
$NOVA_BIN_DIR/nova-baremetal-manage pxe_ip create --cidr 192.168.175.0/24

if [ -f ./bm-nodes.sh ]; then
    . ./bm-nodes.sh
fi

NL=`echo -ne '\015'`

echo "restarting nova-compute"
screen -S stack -p n-cpu -X kill
screen -S stack -X screen -t n-cpu
sleep 1.5
screen -S stack -p n-cpu -X stuff "cd $NOVA_DIR && sg libvirtd $NOVA_BIN_DIR/nova-compute $NL"

echo "starting bm_deploy_server"
screen -S stack -p n-bmd -X kill
screen -S stack -X screen -t n-bmd
sleep 1.5
screen -S stack -p n-bmd -X stuff "cd $NOVA_DIR && $NOVA_BIN_DIR/nova-baremetal-deploy-helper $NL"
