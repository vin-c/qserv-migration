#!/bin/bash

for i in `seq 100 124`; do

    ./qserv-sync.sh attach $i
    ./qserv-sync.sh sync $i 2>&1 | tee sync-log-$i
    ./qserv-sync.sh detach $i

done


