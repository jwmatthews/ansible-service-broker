#!/bin/bash

###
# This script is intended to fake out an environment simulating running inside a pod of the cluster
# to let us run the broker code locally for development & debugging
###
BROKER_CMD="../broker"
GENERATED_BROKER_CONFIG="../etc/generated_local_development.yaml"
ETCD_ROUTE_TEMPLATE="../templates/deploy-etcd-route-for-local-dev.yaml"
ASB_PROJECT="ansible-service-broker"
BROKER_SVC_ACCT_NAME="asb"
BROKER_SVC_ACCT="system:serviceaccount:${ASB_PROJECT}:${BROKER_SVC_ACCT_NAME}"
OC_CMD="$HOME/bin/oc"

# Faking out https://github.com/kubernetes/client-go/blob/master/rest/config.go#L309
export KUBERNETES_SERVICE_HOST=192.168.37.1
export KUBERNETES_SERVICE_PORT=8443
SVC_ACCT_CA_CRT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
SVC_ACCT_TOKEN_DIR=/var/run/secrets/kubernetes.io/serviceaccount
SVC_ACCT_TOKEN_FILE=$SVC_ACCT_TOKEN_DIR/token

which jq &> /dev/null
if [ "$?" -ne 0 ]; then 
  echo "Please ensure 'jq' is installed and in your path"
  exit 1
fi 

# Determine the name of the secret which has the 'asb' service account info
BROKER_SVC_ACCT_SECRET_NAME=`oc get serviceaccount asb -n ansible-service-broker -o json | jq -c '.secrets[] | select(.name | contains("asb-token"))' | jq -c '.name'`
# Remove quotes from variable
BROKER_SVC_ACCT_SECRET_NAME=( $(eval echo ${BROKER_SVC_ACCT_SECRET_NAME[@]}) )
echo "Broker Service Account Token is in secret: ${BROKER_SVC_ACCT_SECRET_NAME}"

###
# Fetch the service-ca.crt for the service account
###
SVC_ACCT_CA_CRT_DATA=`oc get secret ${BROKER_SVC_ACCT_SECRET_NAME} -n ${ASB_PROJECT} -o json | jq -c '.data["service-ca.crt"]'`
# Remove quotes from variable
SVC_ACCT_CA_CRT_DATA=( $(eval echo ${SVC_ACCT_CA_CRT_DATA[@]}) )
# Base64 Decode
SVC_ACCT_CA_CRT_DATA=`echo ${SVC_ACCT_CA_CRT_DATA} | base64 -D `
if [ "$?" -ne 0 ]; then 
  echo "Unable to determine service-ca.crt for secret '${BROKER_SVC_ACCT_SECRET_NAME}'"
  exit 1
fi 
echo "${SVC_ACCT_CA_CRT_DATA}" &> ${SVC_ACCT_CA_CRT}
if [ "$?" -ne "0" ]; then 
  echo "Unable to write the service-ca.crt data for ${BROKER_SVC_ACCT_SECRET_NAME} to: ${SVC_ACCT_CA_CRT}"
  exit 1 
fi 
echo "Service Account: ca.crt"
echo -e "Wrote \n${SVC_ACCT_CA_CRT_DATA}\n to: ${SVC_ACCT_CA_CRT}\n"

# Fetch the token for the service account
if [ ! -d $SVC_ACCT_TOKEN_DIR ]; then
  echo "Please create the directory: ${SVC_ACCT_TOKEN_DIR}"
  echo "Ensure your user can write to it."
  exit 1
fi
BROKER_SVC_ACCT_TOKEN=`oc get secret ${BROKER_SVC_ACCT_SECRET_NAME} -n ${ASB_PROJECT} -o json | jq -c '.data["token"]'`
BROKER_SVC_ACCT_TOKEN=( $(eval echo ${BROKER_SVC_ACCT_TOKEN[@]}) )
BROKER_SVC_ACCT_TOKEN=`echo ${BROKER_SVC_ACCT_TOKEN} | base64 -D`
###
# Note:
# It is important we do __not__ append the trailing newline in the token file
# Gocode will read in the newline as part of the token which break it...and causes confusion tracking down
###
echo -n "${BROKER_SVC_ACCT_TOKEN}" &> $SVC_ACCT_TOKEN_FILE
if [ "$?" -ne 0 ]; then 
  echo "Unable to write token to $SVC_ACCT_TOKEN_FILE"
  exit 1
fi
echo "Service Account: token"
echo -e "Wrote \n${BROKER_SVC_ACCT_TOKEN}\n to: ${SVC_ACCT_TOKEN_FILE}\n"


# To run broker locally need:
# - local instance must respond to route 
# - Service Catalog needs to talk to route and have it reach the local broker 
# - Broker needs to talk to etcd, outside of project so now it requires access through route 
# - Broker needs to read a configuration file 
# - Broker needs to access kubernetes.default to reach OpenShift cluster 
#   - Fake out DNS for kubernetes.default
#   - Path to cacert
#   - Needs to run oc login with the expected paths


# Need to create a route for the etcd instance 

${OC_CMD} process -f ${ETCD_ROUTE_TEMPLATE} -n ${ASB_PROJECT} | ${OC_CMD} create -n ${ASB_PROJECT} -f - 

etcd_route=`oc get route asb-etcd -n ${ASB_PROJECT} -o=jsonpath=\'\{.spec.host\}\'`

echo "etcd route is at: ${etcd_route}"

if [ -z "$DOCKERHUB_USERNAME" ]; then
  echo "Please set the environment variable DOCKERHUB_USERNAME and re-run"
  exit 1 
fi 
if [ -z "$DOCKERHUB_PASSWORD" ]; then
  echo "Please set the environment variable DOCKERHUB_PASSWORD and re-run"
  exit 1 
fi 

cat << EOF  > ${GENERATED_BROKER_CONFIG}
---
registry:
  name: dockerhub
  url: https://registry.hub.docker.com
  user: ${DOCKERHUB_USERNAME}
  pass: ${DOCKERHUB_PASSWORD}
  org: ansibleplaybookbundle
dao:
  etcd_host: ${etcd_route}
  etcd_port: 80
log:
  logfile: /tmp/ansible-service-broker-asb.log
  stdout: true
  level: debug
  color: true
openshift: {}
broker:
  dev_broker: true
  launch_apb_on_bind: false
  recovery: true
  output_request: true
EOF

${BROKER_CMD} -c ${GENERATED_BROKER_CONFIG} 

