#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

set -ex

BINDIR=`dirname "$0"`
PULSAR_HOME=`cd ${BINDIR}/..;pwd`
FUNCTION_MESH_HOME=${PULSAR_HOME}
OUTPUT_BIN=${FUNCTION_MESH_HOME}/output/bin
KIND_BIN=$OUTPUT_BIN/kind
HELM=${OUTPUT_BIN}/helm
KUBECTL=${OUTPUT_BIN}/kubectl
NAMESPACE=default
CLUSTER=sn-platform
CLUSTER_ID=$(uuidgen | tr "[:upper:]" "[:lower:]")

FUNCTION_NAME=$1

function ci::create_cluster() {
    echo "Creating a kind cluster ..."
    ${FUNCTION_MESH_HOME}/hack/kind-cluster-build.sh --name sn-platform-"${CLUSTER_ID}" -c 3 -v 10
    echo "Successfully created a kind cluster."
}

function ci::delete_cluster() {
    echo "Deleting a kind cluster ..."
    kind delete cluster --name=sn-platform-"${CLUSTER_ID}"
    echo "Successfully delete a kind cluster."
}

function ci::cleanup() {
    echo "Clean up kind clusters ..."
    clusters=( $(kind get clusters | grep sn-platform) )
    for cluster in "${clusters[@]}"
    do
       echo "Deleting a kind cluster ${cluster}"
       kind delete cluster --name=${cluster}
    done
    echo "Successfully clean up a kind cluster."
}

function ci::install_storage_provisioner() {
    echo "Installing the local storage provisioner ..."
    ${HELM} repo add streamnative https://charts.streamnative.io
    ${HELM} repo update
    ${HELM} install local-storage-provisioner streamnative/local-storage-provisioner --debug --wait --set namespace=default
    echo "Successfully installed the local storage provisioner."
}

function ci::install_metrics_server() {
    echo "install metrics-server"
    ${KUBECTL} apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.3.7/components.yaml
    ${KUBECTL} patch deployment metrics-server -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"metrics-server","args":["--cert-dir=/tmp", "--secure-port=4443", "--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP"]}]}}}}'
    echo "Successfully installed the metrics-server."
    WC=$(${KUBECTL} get pods -n kube-system --field-selector=status.phase=Running | grep metrics-server | wc -l)
    while [[ ${WC} -lt 1 ]]; do
        echo ${WC};
        sleep 20
        ${KUBECTL} get pods -n kube-system
        WC=$(${KUBECTL} get pods -n kube-system --field-selector=status.phase=Running | grep metrics-server | wc -l)
    done
}

function ci::install_pulsar_charts() {
    echo "Installing the pulsar charts ..."
    values=${1:-".ci/clusters/values.yaml"}
    echo $values
    if [ -d "pulsar-charts" ]; then
        rm -rf pulsar-charts
    fi
    git clone https://github.com/streamnative/charts.git pulsar-charts
    cp ${values} pulsar-charts/charts/pulsar/mini_values.yaml
    cd pulsar-charts
    cd charts
    helm repo add loki https://grafana.github.io/loki/charts
    helm dependency update pulsar
    ${HELM} install sn-platform --set initialize=true --values ./pulsar/mini_values.yaml ./pulsar --debug

    echo "wait until pulsar init job is completed"
    succeeded_num=0
    while [[ ${succeeded_num} -lt 1 ]]; do
        sleep 10s
        kubectl get pods -n ${NAMESPACE}
        succeeded_num=$(kubectl get jobs -n ${NAMESPACE} sn-platform-pulsar-pulsar-init -o jsonpath='{.status.succeeded}')
    done
    # start bookkeeper after the pulsar init job is completed
    kubectl scale statefulset --replicas=1 -n ${NAMESPACE} sn-platform-pulsar-bookie

    echo "wait until pulsar cluster is active"
    kubectl wait --for=condition=Ready -n ${NAMESPACE} -l app=pulsar pods --timeout=5m
    kubectl get service -n ${NAMESPACE}
}

function ci::test_pulsar_producer() {
    # broker
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-toolset-0 -- bash -c 'until nslookup sn-platform-pulsar-broker; do sleep 3; done'
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin tenants create sn-platform
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin namespaces create sn-platform/test
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -m "test-message" sn-platform/test/test-topic
    # bookkeeper
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-bookie-0 -- df -h
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-bookie-0 -- cat conf/bookkeeper.conf
    ${KUBECTL} exec -n ${NAMESPACE} ${CLUSTER}-pulsar-bookie-0 -- nc -zv 127.0.0.1 4181
}

function ci::verify_function_mesh() {
    FUNCTION_NAME=$1

    num=0
    while [[ ${num} -lt 1 ]]; do
        sleep 5s
        kubectl get pods
        num=$(kubectl get pods -l name="${FUNCTION_NAME}" | wc -l)
    done

    kubectl wait -l name="${FUNCTION_NAME}" --for=condition=Ready pod --timeout=2m && true

    num=0
    while [[ ${num} -lt 1 ]]; do
        sleep 5s
        kubectl get pods -l name="${FUNCTION_NAME}"
        kubectl logs -l name="${FUNCTION_NAME}" --all-containers=true --tail=50 || true
        num=$(kubectl logs -lname="${FUNCTION_NAME}" --all-containers=true --tail=-1 | grep "Created producer\|Created consumer\|Subscribed to topic" | wc -l)
    done
}

function ci::verify_hpa() {
    FUNCTION_NAME=$1
    ${KUBECTL} get function
    ${KUBECTL} get function ${FUNCTION_NAME} -o yaml
    ${KUBECTL} get hpa.v2beta2.autoscaling
    ${KUBECTL} get hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function -o yaml
    ${KUBECTL} describe hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function
    WC=$(${KUBECTL} get hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' | grep False | wc -l)
    while [[ ${WC} -lt 0 ]]; do
        echo ${WC};
        sleep 20
        ${KUBECTL} get hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function -o yaml
        ${KUBECTL} describe hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function
        ${KUBECTL} get hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}'
        WC=$(${KUBECTL} get hpa.v2beta2.autoscaling ${FUNCTION_NAME}-function -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].status}' | grep False | wc -l)
    done
}

function ci::test_function_runners() {
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions create --tenant public --namespace default --name test-java --className org.apache.pulsar.functions.api.examples.ExclamationFunction --inputs persistent://public/default/test-java-input --jar /pulsar/examples/api-examples.jar --cpu 0.1
    function_num=0
    while [[ ${function_num} -lt 1 ]]; do
        sleep 5s
        kubectl get pods -n ${NAMESPACE}
        function_num=$(kubectl get pods -n ${NAMESPACE} -l name=test-java --no-headers | wc -l)
    done
    kubectl wait --for=condition=Ready -n ${NAMESPACE} -l name=test-java pods && true
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo "java runner test done"
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions delete --tenant public --namespace default --name test-java

    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions create --tenant public --namespace default --name test-python --classname exclamation_function.ExclamationFunction --inputs persistent://public/default/test-python-input --py /pulsar/examples/python-examples/exclamation_function.py --cpu 0.1
    function_num=0
    while [[ ${function_num} -lt 1 ]]; do
        sleep 5s
        kubectl get pods -n ${NAMESPACE}
        function_num=$(kubectl get pods -n ${NAMESPACE} -l name=test-python --no-headers | wc -l)
    done
    kubectl wait --for=condition=Ready -n ${NAMESPACE} -l name=test-python pods && true
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo "python runner test done"
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions delete --tenant public --namespace default --name test-python

    kubectl cp "${FUNCTION_MESH_HOME}/.ci/examples/go-examples" "${NAMESPACE}/${CLUSTER}-pulsar-broker-0:/pulsar/"
    sleep 1
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions create --tenant public --namespace default --name test-go --inputs persistent://public/default/test-go-input --go /pulsar/go-examples/exclamationFunc --cpu 0.1
    function_num=0
    while [[ ${function_num} -lt 1 ]]; do
        sleep 5s
        kubectl get pods -n ${NAMESPACE}
        function_num=$(kubectl get pods -n ${NAMESPACE} -l name=test-go --no-headers | wc -l)
    done
    kubectl wait --for=condition=Ready -n ${NAMESPACE} -l name=test-go pods && true
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo "golang runner test done"
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-admin functions delete --tenant public --namespace default --name test-go
}

function ci::verify_go_function() {
    ci::verify_exclamation_function "persistent://public/default/input-go-topic" "persistent://public/default/output-go-topic" "test-message" "test-message!" 10
}

function ci::verify_download_go_function() {
    ci::verify_exclamation_function "persistent://public/default/input-download-go-topic" "persistent://public/default/output-download-go-topic" "test-message" "test-message!" 10
}

function ci::verify_java_function() {
    ci::verify_exclamation_function "persistent://public/default/input-java-topic" "persistent://public/default/output-java-topic" "test-message" "test-message!" 10
}

function ci::verify_download_java_function() {
    ci::verify_exclamation_function "persistent://public/default/input-download-java-topic" "persistent://public/default/output-download-java-topic" "test-message" "test-message!" 10
}

function ci::verify_python_function() {
    ci::verify_exclamation_function "persistent://public/default/input-python-topic" "persistent://public/default/output-python-topic" "test-message" "test-message!" 10
}

function ci::verify_download_python_function() {
    ci::verify_exclamation_function "persistent://public/default/input-download-python-topic" "persistent://public/default/output-download-python-topic" "test-message" "test-message!" 10
}

function ci::verify_download_python_zip_function() {
    ci::verify_exclamation_function "persistent://public/default/input-download-python-zip-topic" "persistent://public/default/output-download-python-zip-topic" "test-message" "test-message!" 10
}

function ci::verify_download_python_pip_function() {
    ci::verify_exclamation_function "persistent://public/default/input-download-python-pip-topic" "persistent://public/default/output-download-python-pip-topic" "test-message" "test-message!" 10
}

function ci::verify_stateful_function() {
    ci::verify_wordcount_function "persistent://public/default/python-function-stateful-input-topic" "persistent://public/default/logging-stateful-function-logs" "apple apple apple" "The value is 3" 10
}

function ci::verify_mesh_function() {
    ci::verify_exclamation_function "persistent://public/default/functionmesh-input-topic" "persistent://public/default/functionmesh-python-topic" "test-message" "test-message!!!" 10
}

function ci::verify_sink() {
    ci::verify_elasticsearch_sink "persistent://public/default/input-sink-topic" "{\"a\":1}" 10
}

function ci::verify_source() {
    ci::verify_mongodb_source 30
}

function ci::verify_crypto_function() {
    ci::verify_function_with_encryption "persistent://public/default/java-function-crypto-input-topic" "persistent://public/default/java-function-crypto-output-topic" "test-message" "test-message!" 10
}

function ci::verify_exclamation_function() {
    inputtopic=$1
    outputtopic=$2
    inputmessage=$3
    outputmessage=$4
    timesleep=$5
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -m "${inputmessage}" -n 1 "${inputtopic}"
    sleep "$timesleep"
    MESSAGE=$(kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client consume -n 1 -s "sub" --subscription-position Earliest "${outputtopic}")
    echo "$MESSAGE"
    if [[ "$MESSAGE" == *"$outputmessage"* ]]; then
        return 0
    fi
    return 1
}

function ci::verify_wordcount_function() {
    inputtopic=$1
    outputtopic=$2
    inputmessage=$3
    outputmessage=$4
    timesleep=$5
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -m "${inputmessage}" -n 1 "${inputtopic}"
    sleep "$timesleep"
    MESSAGE=$(kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client consume -n 3 -s "sub" --subscription-position Earliest "${outputtopic}")
    echo "$MESSAGE"
    if [[ "$MESSAGE" == *"$outputmessage"* ]]; then
        return 0
    fi
    return 1
}

function ci::verify_functionmesh_reconciliation() {
    MESH_NAME=$1
    POSTFIX=$2

    function_name="${MESH_NAME}"-function-"${POSTFIX}"
    find=false
    while ! ${find}; do
        sleep 5s
        num=$(kubectl get functions.compute.functionmesh.io --no-headers | wc -l)
        if [[ ${num} -ne 1 ]]; then
            continue
        fi
        kubectl get functions.compute.functionmesh.io "${function_name}" > /dev/null 2>&1 && true
        if [ $? -eq 0 ]; then
            find=true
        fi
    done

    sink_name="${MESH_NAME}"-sink-"${POSTFIX}"
    find=false
    while ! ${find}; do
        sleep 5s
        num=$(kubectl get sinks.compute.functionmesh.io --no-headers | wc -l)
        if [[ ${num} -ne 1 ]]; then
            continue
        fi
        kubectl get sinks.compute.functionmesh.io "${sink_name}" > /dev/null 2>&1 && true
        if [ $? -eq 0 ]; then
            find=true
        fi
    done

    source_name="${MESH_NAME}"-source-"${POSTFIX}"
    find=false
    while ! ${find}; do
        sleep 5s
        num=$(kubectl get sources.compute.functionmesh.io --no-headers | wc -l)
        if [[ ${num} -ne 1 ]]; then
            continue
        fi
        kubectl get sources.compute.functionmesh.io "${source_name}" > /dev/null 2>&1 && true
        if [ $? -eq 0 ]; then
            find=true
        fi
    done
}

function ci::verify_elasticsearch_sink() {
    inputtopic=$1
    inputmessage=$2
    timesleep=$3
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -m "${inputmessage}" -n 1 "${inputtopic}"
    sleep "$timesleep"
    kubectl logs --all-containers=true --tail=-1 quickstart-es-default-0 | grep "creating index"
    if [ $? -eq 0 ]; then
        return 0
    fi
    return 1
}

function ci::verify_mongodb_source() {
    timesleep=$1
    kubectl exec mongo-dbz-0 -c mongo -- mongo -u debezium -p dbz --authenticationDatabase admin localhost:27017/inventory --eval 'db.products.update({"_id":NumberLong(104)},{$set:{weight:1.25}})'
    sleep "$timesleep"
    kubectl logs --all-containers=true --tail=-1 -l name=source-sample | grep "records sent"
    if [ $? -eq 0 ]; then
        return 0
    fi
    return 1
}

function ci::verify_function_with_encryption() {
    inputtopic=$1
    outputtopic=$2
    inputmessage=$3
    outputmessage=$4
    timesleep=$5

    # correct pubkey
    correct_pubkey="LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUZZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUFvRFFnQUUvZ0cxbko0SHBHVnB0WWR2YjRUWUVCUVRpS3kwSmF1TApqa0FXalpqTE5WVW5JaEtCUkttV1M3cjA1MWU1VHRwdFRvOWZEVDR3L29zMmVTTUhpWVl5dEE9PQotLS0tLUVORCBQVUJMSUMgS0VZLS0tLS0K"
    # incorrect pubkey
    incorrect_pubkey="LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUlJQ1hUQ0NBZEFHQnlxR1NNNDlBZ0V3Z2dIREFnRUJNRTBHQnlxR1NNNDlBUUVDUWdILy8vLy8vLy8vLy8vLwovLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vCi8vLy8vLy8vL3pDQm53UkNBZi8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8KLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vOEJFSUFVWlUrdVdHT0hKb2ZrcG9ob0xhRgpRTzZpMm5KYm1iTVY4N2kwaVpHTzhRbmhWaGs1VWV4K2szc1dVc0M5TzdHL0J6VnozNGc5TERUeDcwVWYxR3RRClB3QURGUURRbm9nQUtSeTRVNWJNWnhjNU1vU3FvTnBrdWdTQmhRUUF4b1dPQnJjRUJPbk5uajdMWmlPVnRFS2MKWklFNUJUKzFJZmdvcjJCclRUMjZvVXRlZCsvbldTaitIY0Vub3YrbzNqTklzOEdGYWtLYitYNStNY0xsdldZQgpHRGtwYW5pYU84QUVYSXBmdEN4OUc5bVk5VVJKVjV0RWFCZXZ2UmNuUG1Zc2wrNXltVjcwSmtERlVMa0JQNjBICllUVThjSWFpY3NKQWlMNlVkcC9SWmxBQ1FnSC8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8vLy8KLy8vLy8vcFJob2VEdnkrV2EzL01BVWozQ2FYUU83WEp1SW1jUjY2N2I3Y2VrVGhrQ1FJQkFRT0JoZ0FFQWF3QwpXb2NQMTBndWJsb0hkYnJDNnVlSEpzM1VDNVRvbUZWanlCdWIvZHBjRVZ3VGZpOW54R1Jsa3lPZkZvM0NTZnVWCjVidE5wVXZveXhSMG1VZ0FDTWZrQWVzS2JkSkdyWHR5Tk1VTHVKeWtYNDBoSllmNDZRbzc2VlV1UUFCaXRrei8KMjhWNHlTbGcvZHZUbmVkMkIydUtyNHUrUjZzbHVNbWJYYi8xZ0lkUENZcDIKLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tCg=="

    # incorrect pubkey test
    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -ekn "myapp1" -ekv "data:application/x-pem-file;base64,${incorrect_pubkey}" -m "${inputmessage}" -n 1 "${inputtopic}"
    sleep "$timesleep"
    kubectl logs --all-containers=true --tail=-1 -l name=java-function-crypto-sample | grep "Message delivery failed since unable to decrypt incoming message"
    if [ $? -ne 0 ]; then
        return 1
    fi

    kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client produce -ekn "myapp1" -ekv "data:application/x-pem-file;base64,${correct_pubkey}" -m "${inputmessage}" -n 1 "${inputtopic}"
    sleep "$timesleep"
    MESSAGE=$(kubectl exec -n ${NAMESPACE} ${CLUSTER}-pulsar-broker-0 -- bin/pulsar-client consume -n 1 -s "sub" --subscription-position Earliest "${outputtopic}")
    echo "$MESSAGE"
    if [[ "$MESSAGE" == *"$outputmessage"* ]]; then
        return 0
    fi
    return 1
}
