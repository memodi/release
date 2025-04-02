#!/usr/bin/env bash

set -o pipefail
# disable nounset as e2e-benchmarking needs several variables to be set,
# and we're selectively setting variables to get comparison sheets.
set +o nounset
set -x


ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)
export ES_PASSWORD
export ES_USERNAME
export GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export EMAIL_ID_FOR_RESULTS_SHEET="memodi@redhat.com"
# NOO_BUNDLE_VERSION=$(jq '.noo_bundle_info' < "$SHARED_DIR/$WORKLOAD-index_data.json")
NOO_BUNDLE_VERSION="v0.0.0-main" #debug-only
export NOO_BUNDLE_VERSION

export UUID="d933e616-9d78-49d6-ab50-bdcec9be76c1"
# export BASELINE_UUID="e7844924-6ac6-453f-804c-b3934cde9643"

# UUID=$(jq '.uuid' < "$SHARED_DIR/$WORKLOAD-index_data.json")
# START_TIME=$(jq '.startDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
# END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")

# INGRESS_PERF_END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/ingress-perf-index_data.json")

# # strip quotes
# UUID=${UUID//\"/}
# START_TIME=${START_TIME//\"/}
# END_TIME=${END_TIME//\"/}
# INGRESS_PERF_END_TIME=${INGRESS_PERF_END_TIME//\"/}

# # cluster-density-v2 takes longer to complete than ingress-perf
# if [[ $WORKLOAD == "node-density-heavy" ]]; then
#     END_TIME=$INGRESS_PERF_END_TIME
# fi

E2E_BENCHMARKING_REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"

function enable_venv() {
    python --version
    python3.9 --version
    python3.9 -m pip install virtualenv
    python3.9 -m virtualenv venv3
    source venv3/bin/activate
    python --version
}

function install_requirements(){
    python -m pip install -r "$1"
}


function upload_metrics(){
    install_requirements scripts/requirements.txt
    python scripts/nope.py --starttime "$START_TIME" --endtime "$END_TIME" --uuid "$UUID" --noo-bundle-version "$NOO_BUNDLE_VERSION"
    upload_metrics_rc=$?
    cp -r /tmp/data "$ARTIFACT_DIR"
    echo $upload_metrics_rc
}

function get_baseline(){
    pushd /scripts
    install_requirements requirements.txt
    python nope.py baseline --fetch "$WORKLOAD"
    BASELINE_UUID=$(jq '.BASELINE_UUID' < /tmp/data/baseline.json)
    export BASELINE_UUID
}

function generate_metrics_sheet(){
    pushd /tmp
    git clone -b master --depth=1 $E2E_BENCHMARKING_REPO_URL
    export CONFIG_LOC="/scripts/queries"
    export COMPARISON_CONFIG="netobserv_touchstone_statistics_config.json"
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    # NETWORK_TYPE=$(oc get network.config/cluster -o jsonpath='{.spec.networkType}')
    # export NETWORK_TYPE
    export NETWORK_TYPE="OVNKubernetes"
    export TOLERANCY_RULES=""
    export ES_SERVER_BASELINE=""
    export GEN_JSON=false
    export GEN_CSV=true
    pushd e2e-benchmarking/utils && source compare.sh
    # generate metrics sheet
    run_benchmark_comparison > "$ARTIFACT_DIR/benchmark_csv.log"
    cp "/tmp/$WORKLOAD-$UUID/$UUID.csv" "$ARTIFACT_DIR/${UUID}_metrics.csv"
}

function update_sheet(){
    pushd /scripts/sheets
    enable_venv
    install_requirements requirements.txt
    python noo_perfsheets_update.py --sheet-id "$1" --uuid1 "$UUID" --uuid2 "$BASELINE_UUID" --service-account "$GSHEET_KEY_LOCATION"
}

function do_comparison(){
    pushd /tmp
    rm -rf /tmp/$WORKLOAD-$UUID/$UUID.csv || true
    export TOLERANCE_LOC="/scripts/queries"
    export TOLERANCY_RULES="netobserv_touchstone_tolerancy_rules.yaml"
    export COMPARISON_CONFIG="netobserv_touchstone_tolerancy_config.json"
    export ES_SERVER_BASELINE="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    export GEN_CSV=true
    pushd e2e-benchmarking/utils && source compare.sh
    COMP_LOG="$ARTIFACT_DIR/benchmark_comp.log"
    run_benchmark_comparison > "$COMP_LOG"
    comp_rc=$?
    cp "/tmp/$WORKLOAD-$UUID/$UUID.csv" "$ARTIFACT_DIR/${UUID}_comparison.csv"
    # get the SHEET ID from the benchmark_comparison run logs
    if [[ -f $COMP_LOG ]]; then
        COMP_SHEET_ID=$(grep Google "$COMP_LOG" | awk -F'/' '{print $NF}' | awk '{print $1}')
        update_sheet "$COMP_SHEET_ID"
    fi
    echo $comp_rc
}

metrics_rc=$(upload_metrics)

if [[ $metrics_rc -gt 0 ]]; then
    echo "Metrics uploading to ES failed, exiting!!!"
    return "$metrics_rc"
fi

generate_metrics_sheet
get_baseline

if [[ -n $BASELINE_UUID ]]; then
    comparison_rc=$(do_comparison)
    if [[ $comparison_rc -gt 0 ]]; then
        echo "Comparison with Baseline failed!!!"
    fi
else
    echo "Couldn't fetch baseline UUID for workload $WORKLOAD from ES"
    return 1
fi
return "$comparison_rc"
