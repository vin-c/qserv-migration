#!/bin/bash

source credentials

BWLIMIT=200000 # kb/sec

MOUNTDIR=/qserv # Local
QSERVDATAPATH=/qserv/data # Remote

DEVICE=/dev/vdb # local device
VOLUME=qserv-data # volume name prefix
VOL_SIZE=1500 # in Gb

# Full paths
DEBUG=""    # replace with "echo " to activate or "" to disable
OS="/usr/bin/openstack"
CINDER="$DEBUG/usr/bin/cinder"
NOVA="$DEBUG/usr/bin/nova"
RSYNC="$DEBUG/usr/bin/rsync"
SSH="/usr/bin/ssh"

stop_quit() {
    echo -n "$1"
    exit 1
}

which_vol() {
    for f in $MOUNTDIR/$VOLUME-*; do
        [ -e "$f" ] && vol_name=$f
        echo "It seems that $vol_name is already mounted..."
        break
    done
}

create_volume() {
    ID=$1
    $CINDER create $VOL_SIZE --volume-type $VOL_TYPE --display-name $VOLUME-$ID
}

create_and_format() {

    # The sed script strips off all the comments so that we can 
    # document what we're doing in-line with the actual commands
    # Note that a blank line (commented as "default" will send a empty
    # line terminated with a newline to take the fdisk default.

    target_dev=$1

    while [ ! -b $target_dev ]; do
        sleep 1
    done

    echo "Creating partition (full disk size) on $target_dev"
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk $1
      o # clear the in memory partition table
      n # create new partition
        # default - primary
        # default - partition number 1
        # default - start at beginning of disk
        # default - extend partition to end of disk
      p # print the in-memory partition table
      w # write the partition table
EOF

    target_part=$target_dev"1"
    echo "Creating ext4 filesystem on $target_part"
    mkfs.ext4 $target_part
}

prep() {
    if [ ! -b $DEVICE ]; then
        echo "$DEVICE not mounted, continue..."
        create_volume $1

        sleep 2

        uuid=$($OS volume list | awk "/$VOLUME-$1/ "'{print $2}')

        echo "Attaching volume $VOLUME-$1 ($uuid) to instance"
        $NOVA volume-attach $VMID $uuid $DEVICE

        while [ ! -b $DEVICE ]; do
            sleep 1
        done

        create_and_format $DEVICE

        if [ ! -d $MOUNTDIR ]; then
            mkdir $MOUNTDIR
        fi

        mount $DEVICE"1" $MOUNTDIR
        touch $MOUNTDIR/$VOLUME-$1
    else
        stop_quit "The device /dev/vdb is already present on the system"
    fi
}

clean() {
    first="1"
    echo "Are you sure you want to DELETE ALL $VOLUME-$first* volumes ? [NO/yes]"
    echo -n "Please type exactly 'yes' to continue... "
    read input

    if [ "$input" == "yes" ]; then
        echo "Ok, you're the boss, processing your request..."
        umount $MOUNTDIR
        items=$($OS volume list | awk "/$VOLUME-$first/ "'{print $2}')
        for i in $items; do
            echo "Deleting volume $i"
            $NOVA volume-detach $VMID $i
            $OS volume delete $i
        done
    else
        stop_quit ""
    fi
}


detach() {
    which_vol
    echo "Detaching volume $VOLUME-$1 (can be attached again later...)"
    uuid=$($OS volume list | awk "/$VOLUME-$1/ "'{print $2}')
    umount $MOUNTDIR
    $NOVA volume-detach $VMID $uuid
}

attach() {
    if [ -b $DEVICE ]; then
        which_vol
        stop_quit ""
    fi

    echo "Attaching volume $VOLUME-$1 to instance..."
    uuid=$($OS volume list | awk "/$VOLUME-$1/ "'{print $2}')
    if [ "$uuid" == "" ]; then
        stop_quit "Volume not found ?!? Did you prepare it ?"
    fi
    $NOVA volume-attach $VMID $uuid
    while [ ! -b $DEVICE ]; do
        sleep 1
    done
    mount $DEVICE"1" $MOUNTDIR
}

sync() {
    echo "Checking if volume is prepared and mounted..."
    if [ ! -f $MOUNTDIR/$VOLUME-$1 ]; then
        echo "Check FAILED on volume $VOLUME-$1 !"

        which_vol
        stop_quit ""
       
    else echo "Volume $VOLUME-$1 seems to be OK :)"
    fi

    # Here is the trick...
    # Make a ssh connection with ExitOnForwardFailure and -f options activated
    # We have to run a command (sleep 10) and by this time, you can use the
    # forwarded tunnel and once terminated, the connection will drop :)

    echo "Please enter your password (twice) to connect to $CCUSER@$CCHOST then $CCUSER@ccqserv*"
    $SSH -f -o ExitOnForwardFailure=yes -L9$1:ccqserv$1.in2p3.fr:22 $CCUSER@$CCHOST sleep 10
    $RSYNC -aPhi --stats --bwlimit=$BWLIMIT \
        --exclude 'mysql.2*' \
        --exclude 'zookeeper' \
        --exclude 'export*' \
        -e "ssh -p 9$1" $CCUSER@127.0.0.1:$QSERVDATAPATH $MOUNTDIR/
 
}

usage() {
    echo -e "Options are \n $0 {prep|sync|attach|detach} {100..124}"
}

two-args-check() {
    if [[ -z $2 ]]; then
        echo "You must specify a volume id {100..124} !"
        usage
        exit 1
     else $1 $2
     fi
}

case "$1" in
    prep)
        two-args-check $1 $2
        ;;
    sync)
        two-args-check $1 $2
        ;;
    attach)
        two-args-check $1 $2
        ;;
    detach)
        two-args-check $1 $2
        ;;
    clean)
        clean
        ;;
    *)
        usage
        ;;
esac
