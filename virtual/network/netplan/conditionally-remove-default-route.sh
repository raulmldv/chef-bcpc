#!/bin/sh

ON_EDGE=@on_edge_flag@

# Remove default routing from vagrant's management network when not on an edge
# In those cases (i.e., non-spines), default route should be learned via bird
if [ "$ON_EDGE" -eq 0 ] && [ "$IFACE"="eth0" ]; then
	ip route del default dev $IFACE
fi
