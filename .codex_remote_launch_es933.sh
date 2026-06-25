#!/usr/bin/env bash
set -euo pipefail

group="${1:?usage: $0 rhel|ubuntu-sles}"
shift
wanted_labels=("$@")
session="${SESSION:-es933-full}"
bundle="${BUNDLE:-/tmp/es933-9.3.3-bundle.tgz}"

if [[ ! -f "$bundle" ]]; then
    echo "Missing bundle: $bundle" >&2
    exit 1
fi

engine="${ENGINE:-}"
if [[ -z "$engine" ]]; then
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
        engine="docker"
    elif command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then
        engine="podman"
    elif command -v docker >/dev/null 2>&1; then
        engine="docker"
    elif command -v podman >/dev/null 2>&1; then
        engine="podman"
    else
        echo "No docker or podman engine found on host" >&2
        exit 1
    fi
fi

case "$group" in
    rhel)
        specs=(
            "rhel810|registry1:5000/jenkins_slave_rhel:8.10"
            "rhel96|registry1:5000/jenkins_slave_rhel:9.6"
            "rhel97|registry1:5000/jenkins_slave_rhel:9.7"
        )
        ;;
    ubuntu-sles)
        specs=(
            "ubuntu2204|registry1:5000/jenkins_slave_ubuntu:22.04"
            "ubuntu2404|registry1:5000/jenkins_slave_ubuntu:24.04"
            "sles15sp7|registry1:5000/jenkins_slave_sles:15-sp7"
        )
        ;;
    *)
        echo "Unknown group: $group" >&2
        exit 1
        ;;
esac

tmux has-session -t "$session" 2>/dev/null || tmux new-session -d -s "$session" -n monitor
tmux set-option -t "$session" remain-on-exit on >/dev/null

echo "Launcher host: $(hostname)"
echo "Container engine: $engine"
echo "tmux session: $session"
echo "bundle: $bundle"

want_label() {
    local label="$1" wanted
    if [[ "${#wanted_labels[@]}" -eq 0 ]]; then
        return 0
    fi
    for wanted in "${wanted_labels[@]}"; do
        [[ "$wanted" == "$label" ]] && return 0
    done
    return 1
}

for spec in "${specs[@]}"; do
    IFS='|' read -r label image <<<"$spec"
    if ! want_label "$label"; then
        continue
    fi
    cname="es933-${label}"

    echo "Preparing $label from $image as $cname"
    tmux kill-window -t "$session:$label" 2>/dev/null || true
    "$engine" rm -f "$cname" >/dev/null 2>&1 || true
    "$engine" run --privileged=true -dit --name "$cname" "$image" bash -lc 'while true; do sleep 3600; done'
    "$engine" cp "$bundle" "$cname:/tmp/es933-9.3.3-bundle.tgz"
    "$engine" exec "$cname" bash -lc '
        set -e
        if ! id test >/dev/null 2>&1; then
            useradd -m -s /bin/bash test
        fi
        if command -v sudo >/dev/null 2>&1; then
            mkdir -p /etc/sudoers.d
            printf "%s\n" "test ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/99-test-nopasswd
            chmod 0440 /etc/sudoers.d/99-test-nopasswd
        fi
        rm -rf /home/test/scriptx
        mkdir -p /home/test/scriptx
        tar -xzf /tmp/es933-9.3.3-bundle.tgz -C /home/test/scriptx
        mkdir -p /home/test/scriptx/logs
        chown -R test:"$(id -gn test)" /home/test/scriptx
        chmod +x /home/test/scriptx/build_elasticsearch.sh
    '

    read -r -d '' inner <<EOF || true
set -o pipefail
cd /home/test/scriptx
run_log="codex-run-${label}-\$(date +%Y%m%d-%H%M%S).log"
echo "CODEX_RUN_START label=${label} container=${cname} distro=\$(. /etc/os-release && echo "\$ID-\$VERSION_ID") at \$(date -Iseconds)"
bash build_elasticsearch.sh -y 2>&1 | tee "\$run_log"
status=\${PIPESTATUS[0]}
echo "CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds)"

if [[ "\$status" -eq 0 ]]; then
    source "\$HOME/setenv.sh" 2>/dev/null || true
    export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF8"
    export RUNTIME_JAVA_HOME="\${RUNTIME_JAVA_HOME:-/opt/java/jdk}"
    cd /home/test/scriptx/elasticsearch
    ml_log="/home/test/scriptx/logs/ml-random-${label}-\$(date +%Y%m%d-%H%M%S).log"
    echo "CODEX_ML_TEST_DISCOVER label=${label}"
    mapfile -t test_classes < <(
        find x-pack/plugin/ml/src/test/java -name "*Tests.java" \
            | sed "s#^x-pack/plugin/ml/src/test/java/##; s#/#.#g; s#\\.java\$##" \
            | awk 'BEGIN{srand()} {print rand() "\t" \$0}' \
            | sort -n \
            | cut -f2- \
            | head -8
    )
    if [[ "\${#test_classes[@]}" -eq 0 ]]; then
        test_classes=(org.elasticsearch.xpack.ml.inference.adaptiveallocations.AdaptiveAllocationsScalerServiceTests)
    fi
    echo "CODEX_ML_TEST_CLASSES label=${label}"
    printf "%s\n" "\${test_classes[@]}"
    gradle_test_args=()
    for tc in "\${test_classes[@]}"; do
        gradle_test_args+=(--tests "\$tc")
    done
    set +e
    ./gradlew :x-pack:plugin:ml:test \
        "\${gradle_test_args[@]}" \
        \$ES9_OPTS \
        \$ML_CPP_GRADLE_OPTS \
        -Dtests.haltonfailure=false \
        -Dtests.jvm.argline="-Xss2m -Xmx2g" \
        -Dtests.jvms=1 \
        --max-workers=1 \
        2>&1 | tee "\$ml_log"
    ml_status=\${PIPESTATUS[0]}
    set -e
    echo "CODEX_ML_TEST_DONE label=${label} status=\$ml_status log=\$ml_log at \$(date -Iseconds)"
fi

exec bash
EOF

    quoted_inner="$(printf '%q' "$inner")"
    tmux new-window -t "$session:" -n "$label" "$engine exec -it -u test $cname bash -lc $quoted_inner"
    echo "Started tmux window $session:$label"
done

tmux list-windows -t "$session" -F '#{window_index}:#{window_name}:#{pane_current_command}'
