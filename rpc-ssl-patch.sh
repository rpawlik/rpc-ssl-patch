#!/bin/bash

#gen new certs
cd /etc/apache2/ssl
openssl req -new -x509 -nodes -out server.crt -keyout server.key -subj "/C=US/ST=TX/L=San Antonio/O=Rackspace"
echo "New certs generated"

#copy certs to controller02
if knife search "role:ha-controller2" | grep "1 items found" >/dev/null; then
  scp /etc/apache2/ssl/server.crt /etc/apache2/ssl/server.key $(knife search "role:ha-controller2" -a ipaddress | awk '/ipaddress/ {print $2}'):/etc/apache2/ssl/
else
  echo "Single controller, not attempting copy"
fi

#patch and restart controller services
knife ssh "role:*controller*" "apt-get update; apt-get install libssl1.0.0 ssl-cert; service apache2 restart"

#add cert override to environment
HASKEY=unset
if ! knife environment show rpcs | grep key_override >/dev/null; then
  knife exec -E '@e=Chef::Environment.load("rpcs"); a=@e.override_attributes; a.merge!({"horizon" => {"ssl" => {"key_override" => "/etc/apache2/ssl/server.key", "cert_override" => "/etc/apache2/ssl/server.crt"}}}); @e.override_attributes(a); @e.save'
  echo "added SSL override to environment, running chef-client on controllers"
else
  echo 'SSL override already exists! Not overriding.'
  HASKEY=yes
fi

sleep 4

#run chef-client
knife ssh "role:*controller*" "chef-client"

echo "Chef run complete for controllers"

sleep 2

echo "Ensuring compute nodes have proper run list"
for i in $(knife node list | grep -i compute); do knife node run_list add $i 'role[single-compute],role[rpc-support]'; done

sleep 1

echo "Patching compute nodes"

sleep 2
#update compute nodes
knife ssh "role:single-compute" "apt-get update; apt-get install -y libssl1.0.0 ssl-cert; if pgrep neutron >/dev/null; then service neutron-plugin-openvswitch-agent restart; elif pgrep quantum >/dev/null; then service quantum-plugin-openvswitch-agent restart; else echo 'Not running neutron/quantum'; fi; service monit restart"


echo "UPDATED Please verify everything still works"

if [ $HASKEY == "yes" ]; then
  echo -e "\033[1m***IMPORTANT*** Customer had an override set for Horizon's SSL keys. Please notify the customer that their custom cert needs to be renewed.\033[0m"
fi
