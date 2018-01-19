#!/bin/bash

#SETTINGS
SSHKEY="/root/.ssh/example.key" #key used to connect from master to the other nodes
SSHUSER="example-user" # username used to connect from master to the other nodes
SEARCHHEAD="127.0.0.1" #Searchhead ipadress. if there is an searchhead cluster this ip is used to get the other Nodes
SEARCHHEADCLUSTER="no" #set to yes/no
DEPLOYER="127.0.0.1" #deployserver ipadress. if empty this is skipped
SPLUNKINSTALLDIR="/opt" #root dir for the splunk installation
SPLUNKHOMEDIR="/opt/splunk/bin" #splunk executable location
SPLUNKUPGRADEDIR="/home/example-user" #dir where the upgradepackage is stored
SPLUNKUPGRADEPACK="splunk-tarball.tgz" #upgradepackage name

#Check if root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
#Test if pass4SymmKey is set
if [ `cat /opt/splunk/etc/system/local/server.conf | grep pass4SymmKey | head -n1 |awk '{print $3}' | awk '{print length}'` -ge "1" ]; then
  #Get Currectversion
  SPLUNKVERSION=`$SPLUNKHOMEDIR/splunk version | awk '{print $2}' | awk -F. '{print $1$2$3}'`
  #Testversion
  if [ $SPLUNKVERSION -ge "650" ]; then
     echo "Splunk version is oke $SPLUNKVERSION"
  else
     echo "Splunk version is to low for use with this script $SPLUNKVERSION"
     exit 1
  fi
else
   echo "pass4SymmKey is not set. please set this in the server.conf within the whole platform"
   exit 1
fi

#SET USER & PASS:
clear
echo please enter your splunk credentials:
read -p "Username: " SPLUNKUSER
read -sp "Password: " SPLUNKPASS
clear

#Create session on master:
$SPLUNKHOMEDIR/splunk logout #step is needed because there can be a session active with the wrong accesslevel.
$SPLUNKHOMEDIR/splunk search 'index=_internal | fields _time | head 1 ' -auth $SPLUNKUSER':'$SPLUNKPASS >/dev/null

#Get Indexers
INDEXERS=`$SPLUNKHOMEDIR/splunk list cluster-peers | grep host_port_pair | awk -F\: '{ print $2 }'`

#get Searchheads
if [ "$SEARCHHEADCLUSTER" == "yes" ]; then
      SEARCHHEADS=`ssh -oStrictHostKeyChecking=no -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo $SPLUNKHOMEDIR/splunk search 'index=_internal | fields _time | head 1 ' -auth $SPLUNKUSER':'$SPLUNKPASS >/dev/null; sudo $SPLUNKHOMEDIR/splunk list shcluster-members | grep host_port_pair "| /usr/bin/awk -F\: '{ print $2 }'  `
fi
#REPORT STARTPOINT
echo ""
echo "Start overview:"
echo "Master:"
echo "Status: `/opt/splunk/bin/splunk status | grep splunkd` Version `/opt/splunk/bin/splunk version`"
echo ""
echo "Searchhead(s):"
if [ "$SEARCHHEADCLUSTER" == "yes" ]; then
  for i in ${SEARCHHEADS[@]};
  do
    echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk version"`"
  done
else
  echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo /opt/splunk/bin/splunk version"`"
fi
if [ "$DEPLOYER" != "" ]; then
  echo ""
  echo "Deployer:"
  echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo /opt/splunk/bin/splunk version"`"
fi
echo ""
echo "Indexers:"
for i in ${INDEXERS[@]};
do
echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk version"`"
done


#ASK TO CONTINUE
echo ""
echo "Continue upgrade?"
read -p "please enter y or n " CONTINUE
if [ "$CONTINUE" == "n" ]; then
  exit 0
else
  echo ""
  echo "Upgrade starting"
fi

#STOP SPLUNK SERVICES
#STOP MASTER
echo ""
echo "Stopping Splunk on Master"
$SPLUNKHOMEDIR/splunk stop >/dev/null
$SPLUNKHOMEDIR/splunk status
#STOP SEARCHHEADS
echo ""
echo "Stopping Splunk on Searchhead(s)"
if [ "$SEARCHHEADCLUSTER" == "yes" ]; then
  for i in ${SEARCHHEADS[@]};
    do echo $i
    ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo $SPLUNKHOMEDIR/splunk stop >/dev/null; sudo $SPLUNKHOMEDIR/splunk status";
  done
else
  echo $SEARCHHEAD
  ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo $SPLUNKHOMEDIR/splunk stop >/dev/null; sudo $SPLUNKHOMEDIR/splunk status";
fi
#STOP DEPLOYER
if [ "$DEPLOYER" != "" ]; then
  echo ""
  echo "Stopping Splunk on Deployer"
  ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo $SPLUNKHOMEDIR/splunk stop >/dev/null; sudo $SPLUNKHOMEDIR/splunk status";
else
  echo "no deployer found $DEPLOYER"
fi
#STOP INDEXERS
echo ""
echo "Stopping Splunk on Indexers"
for i in ${INDEXERS[@]};
  do echo $i
  ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo $SPLUNKHOMEDIR/splunk stop >/dev/null; sudo $SPLUNKHOMEDIR/splunk status";
done


#UPDATING
#INSTALL UPDATE ON MASTER
#check if splunk is active
if [ "`/opt/splunk/bin/splunk status | grep splunkd`" != "splunkd is not running." ]; then
  echo "Splunk still running."
  exit 1
fi
#check if file is present
if [ ! -f $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK ]; then
    echo "File not found!"
    exit 1
fi
#extract file
echo ""
echo "Extrating update on Master"
tar xzf $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK -C $SPLUNKINSTALLDIR
chown splunk:splunk -R $SPLUNKINSTALLDIR/splunk

#START MASTER
echo ""
echo "Starting Splunk on Master"
$SPLUNKHOMEDIR/splunk start --accept-license --answer-yes
echo "Enable maintenance-mode on Master"
$SPLUNKHOMEDIR/splunk search 'index=_internal | fields _time | head 1 ' -auth $SPLUNKUSER':'$SPLUNKPASS >/dev/null
$SPLUNKHOMEDIR/splunk enable maintenance-mode --answer-yes

#START UPDATING SEARCHHEAD(S)
if [ "$SEARCHHEADCLUSTER" == "yes" ]; then
  for i in ${SEARCHHEADS[@]};
  do
    echo ""
    echo "Starting update on Searchhead $i"
    scp -i $SSHKEY $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK $SSHUSER@$i:~/$SPLUNKUPGRADEPACK
    #check if splunk is active
    if [ "`ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"`" != "splunkd is not running." ]; then
      echo "Splunk still running."
      exit 1
    fi
    ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo tar xzf $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK -C $SPLUNKINSTALLDIR; sudo chown splunk:splunk -R $SPLUNKINSTALLDIR/splunk; sudo $SPLUNKHOMEDIR/splunk start --accept-license --answer-yes"
  done
else
  echo ""
  echo "Starting update on Searchhead $SEARCHHEAD"
  scp -i $SSHKEY $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK $SSHUSER@$SEARCHHEAD:~/$SPLUNKUPGRADEPACK
  #check if splunk is active
  if [ "`ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo /opt/splunk/bin/splunk status | grep splunkd"`" != "splunkd is not running." ]; then
    echo "Splunk still running."
    exit 1
  fi
  ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo tar xzf $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK -C $SPLUNKINSTALLDIR; sudo chown splunk:splunk -R $SPLUNKINSTALLDIR/splunk; sudo $SPLUNKHOMEDIR/splunk start --accept-license --answer-yes"
fi
#START UPDATING DEPLOYER IF SET
if [ "$DEPLOYER" != "" ]; then
  echo ""
  echo "Starting update on indexer $DEPLOYER"
  scp -i $SSHKEY $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK $SSHUSER@$DEPLOYER:~/$SPLUNKUPGRADEPACK
  #check if splunk is active
  if [ "`ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo /opt/splunk/bin/splunk status | grep splunkd"`" != "splunkd is not running." ]; then
    echo "Splunk still running."
    exit 1
  fi
  ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo tar xzf $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK -C $SPLUNKINSTALLDIR; sudo chown splunk:splunk -R $SPLUNKINSTALLDIR/splunk; sudo $SPLUNKHOMEDIR/splunk start --accept-license --answer-yes"
fi
#START UPDATING INDEXERS
for i in ${INDEXERS[@]};
do
echo ""
echo "Starting update on indexer $i"
scp -i $SSHKEY $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK $SSHUSER@$i:~/$SPLUNKUPGRADEPACK
#check if splunk is active
if [ "`ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"`" != "splunkd is not running." ]; then
  echo "Splunk still running."
  exit 1
fi
ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo tar xzf $SPLUNKUPGRADEDIR/$SPLUNKUPGRADEPACK -C $SPLUNKINSTALLDIR; sudo chown splunk:splunk -R $SPLUNKINSTALLDIR/splunk; sudo $SPLUNKHOMEDIR/splunk start --accept-license --answer-yes"
done

#DISABLE MAINTENANCE MODE ON MASTER
echo ""
echo "Enable maintenance-mode on Master"
$SPLUNKHOMEDIR/splunk disable maintenance-mode --answer-yes

#FINAL REPORT
echo ""
echo "Upgrade Report:"
echo "Master:"
echo "Status: `/opt/splunk/bin/splunk status | grep splunkd` Version `/opt/splunk/bin/splunk version`"
echo ""
echo "Searchhead(s):"
if [ "$SEARCHHEADCLUSTER" == "yes" ]; then
  for i in ${SEARCHHEADS[@]};
  do
    echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk version"`"
  done
else
  echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$SEARCHHEAD "sudo /opt/splunk/bin/splunk version"`"
fi
if [ "$DEPLOYER" != "" ]; then
  echo ""
  echo "Deployer:"
  echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$DEPLOYER "sudo /opt/splunk/bin/splunk version"`"
fi
echo ""
echo "Indexers:"
for i in ${INDEXERS[@]};
do
echo "Status: `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk status | grep splunkd"` Version `ssh -oStrictHostKeyChecking=no -q -i $SSHKEY $SSHUSER@$i "sudo /opt/splunk/bin/splunk version"`"
done

unset SPLUNKUSER
unset SPLUNKPASS
unset SSHKEY
unset SSHUSER
unset SEARCHHEAD
unset DEPLOYER
unset SPLUNKINSTALLDIR
unset SPLUNKHOMEDIR
unset SPLUNKUPGRADEDIR
unset SPLUNKUPGRADEPACK
